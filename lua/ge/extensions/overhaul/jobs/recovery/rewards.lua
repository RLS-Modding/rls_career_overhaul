-- Recovery quotes, skill rewards and incremental damage penalties.
-- Accepted quotes stay on the contract; completion charges only damage added during recovery.
return function(arrayToVec3, economyMultiplier, getPayoutBonus, getSkillLevel, routeDistance)
  local function difficultyRewardScale()
    local economyMultiplierValue = economyMultiplier()
    local difficultyMultiplier = 1
    local modeName
    return economyMultiplierValue * difficultyMultiplier, economyMultiplierValue, difficultyMultiplier, modeName
  end

  -- Quote both legs from the chosen lot, never from the player's moving position. Site authors can specify difficultyFee; otherwise minLevel defines the tier.
  local function recoveryDifficultyFee(offer)
    if tonumber(offer.difficultyFee) then return math.max(0, math.min(3000, tonumber(offer.difficultyFee))) end
    local level = tonumber(offer.minLevel) or 1
    return level >= 30 and 3000 or (level >= 10 and 1500 or 0)
  end

  local function fixedCashQuote(offer, yard)
    local targetPosition = arrayToVec3(offer.targetPos)
    local loadedDistanceMeters = routeDistance(targetPosition, yard.spot.pos)
    local outboundDistanceMeters = routeDistance(yard.spot.pos, targetPosition)
    local skillLevel = getSkillLevel()
    local skillBonusFraction = getPayoutBonus(skillLevel)
    local difficultyFee = recoveryDifficultyFee(offer)
    local outboundPay = outboundDistanceMeters / 1000 * 100
    local loadedPay = loadedDistanceMeters / 1000 * 250
    local baseCashReward = 1500 + outboundPay + loadedPay + difficultyFee
    local rewardMultiplier, economyMultiplierValue, difficultyMultiplier, modeName = difficultyRewardScale()
    local cashReward = math.max(0, math.floor(baseCashReward * (1 + skillBonusFraction) * rewardMultiplier + 0.5))
    local breakdown = {
      {label = "Callout", money = 1500},
      {label = "Lot to target", detail = string.format("%.1f km at $100/km", outboundDistanceMeters / 1000), money = outboundPay},
      {label = "Loaded return to lot", detail = string.format("%.1f km at $250/km", loadedDistanceMeters / 1000), money = loadedPay},
      {label = "Recovery difficulty", money = difficultyFee},
      {label = string.format("Recovery L%d skill", skillLevel), detail = string.format("%+d%%", math.floor(skillBonusFraction * 100 + 0.5))}
    }
    if rewardMultiplier ~= 1 then
      local label = modeName and modeName ~= "" and modeName ~= "normal" and string.format("Difficulty (%s)", modeName) or "Economy adjust"
      breakdown[#breakdown + 1] = {label = label, detail = string.format("×%.2f", rewardMultiplier)}
    end
    breakdown[#breakdown + 1] = {label = "Quoted cash", money = cashReward, isTotal = true}
    return cashReward, loadedDistanceMeters, breakdown, outboundDistanceMeters
  end

  local function formatBreakdownLine(line)
    if not line then return "" end
    if line.xp ~= nil then
      return string.format("%s: +%d", line.label or "XP", tonumber(line.xp) or 0)
    end
    if line.money ~= nil and line.detail then
      return string.format("%s (%s): $%s", line.label or "", line.detail, tostring(math.floor(tonumber(line.money) or 0)))
    end
    if line.money ~= nil then
      local amount = math.floor(tonumber(line.money) or 0)
      if amount < 0 then
        return string.format("%s: −$%s", line.label or "", tostring(math.abs(amount)))
      end
      return string.format("%s: $%s", line.label or "", tostring(amount))
    end
    if line.detail then
      return string.format("%s: %s", line.label or "", line.detail)
    end
    return tostring(line.label or "")
  end

  local function openRecoveryApp()
    local function navigate()
      if overhaul_phone_phone then
        overhaul_phone_phone.openRoute("phone-offroad-recovery")
      elseif extensions.ui_router then
        extensions.ui_router.navigate("phone-offroad-recovery")
      end
    end
    core_jobsystem.create(function(jobHandle)
      jobHandle.sleep(0.2)
      navigate()
    end)
  end

  local function buildCompletionBreakdown(job, finalCash, finalXp, damagePenaltyFraction)
    local lines = {}
    if job.rewardType == "cash" then
      if type(job.payBreakdown) == "table" then
        for _, line in ipairs(job.payBreakdown) do
          lines[#lines + 1] = deepcopy(line)
        end
      else
        lines[#lines + 1] = {
          label = "Quoted cash",
          money = math.max(0, math.floor(tonumber(job.cashReward) or 0)),
          isTotal = true
        }
      end
      local quotedCash = math.max(0, math.floor(tonumber(job.cashReward) or 0))
      local paidCash = math.max(0, math.floor(tonumber(finalCash) or 0))
      local penaltyPercent = math.floor((tonumber(damagePenaltyFraction) or 0) * 100 + 0.5)
      if penaltyPercent > 0 then
        lines[#lines + 1] = {
          label = "Damage penalty",
          detail = string.format("−%d%%", penaltyPercent),
          money = paidCash - quotedCash,
          isPenalty = true
        }
      end
      lines[#lines + 1] = {label = "Paid", money = paidCash, isTotal = true}
    else
      lines[#lines + 1] = {label = "Reward", detail = "Vehicle awarded", isTotal = true}
      local penaltyPercent = math.floor((tonumber(damagePenaltyFraction) or 0) * 100 + 0.5)
      if penaltyPercent > 0 then
        lines[#lines + 1] = {
          label = "Damage penalty",
          detail = string.format("−%d%% XP", penaltyPercent),
          isPenalty = true
        }
      end
    end
    lines[#lines + 1] = {label = "Recovery XP", xp = math.max(0, math.floor(tonumber(finalXp) or 0))}
    return lines
  end

  local function fixedSkillXp(offer, loadedDistanceMeters)
    return math.max(1, math.floor((5 + (tonumber(offer.baseXp) or 0) + math.floor((loadedDistanceMeters or 0) / 2000 + 0.5)) * 4 + 0.5))
  end

  local function conditionIntegrity(condition)
    return math.min(1, math.max(0, tonumber(condition and condition.integrityValue) or 1))
  end

  local function damagePenalty(job, finalConditions)
    local baseline = job.baselineConditions or {}
    local vehicleData = job.vehicleId and core_vehicle_manager.getVehicleData(job.vehicleId)
    local activeParts = vehicleData and vehicleData.vdata and vehicleData.vdata.activeParts or {}
    local activePartsData = vehicleData and vehicleData.vdata and vehicleData.vdata.activePartsData or {}
    local valueLost = 0
    for partPath, baseCondition in pairs(baseline) do
      local finalCondition = finalConditions and finalConditions[partPath]
      local integrityLostFraction = math.max(0, conditionIntegrity(baseCondition) - (finalCondition and conditionIntegrity(finalCondition) or 0))
      if integrityLostFraction > 0 then
        local partName = activeParts[partPath]
        local partData = partName and activePartsData[partName]
        local partValue = partData and partData.information and tonumber(partData.information.value) or 700
        valueLost = valueLost + partValue * integrityLostFraction
      end
    end
    -- Parts absent from the baseline may already have been damaged when spawned. Only charge deterioration of parts whose starting condition was captured.
    local catalogValue = math.max(tonumber(job.vehicleValue) or 1000, 1)
    return math.min(valueLost / catalogValue, 0.5), valueLost
  end

  return {buildCompletionBreakdown = buildCompletionBreakdown, damagePenalty = damagePenalty,
      fixedCashQuote = fixedCashQuote, fixedSkillXp = fixedSkillXp,
      formatBreakdownLine = formatBreakdownLine, openRecoveryApp = openRecoveryApp,
      recoveryDifficultyFee = recoveryDifficultyFee}
end
