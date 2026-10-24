-- Held wages, surge bonuses, damage strikes and company drop-off settlement.
-- Reading order: held-wage ledger, payout, surge, damage, employment end and drop-off settlement.
local part = {}

-- Escrow ledger ----------------------------------------------------------------------------------

local function addEscrowLedgerApi(api, inputs)
  local M, projections, runtime, shared, state = inputs.M, inputs.projections, inputs.runtime, inputs.shared, inputs.state

  api.resetEscrow = function()
    state.escrow = { money = 0, legs = {} }
    local mapId = state.activeMapId
    if mapId and state.employments and state.employments[mapId] then
      state.employments[mapId].escrow = state.escrow
    end
  end

  api.escrowKeepSum = function()
    local sum = 0
    for _, leg in ipairs((state.escrow and state.escrow.legs) or {}) do
      sum = sum + (tonumber(leg.keep) or 0)
    end
    return shared.roundMoney(sum)
  end

  api.reconcileEscrowMoney = function(reason)
    state.escrow = state.escrow or { money = 0, legs = {} }
    -- Recorded legs are authoritative when the cached held-pay total drifts.
    local recordedLegMoney = api.escrowKeepSum()
    local cachedEscrowMoney = shared.roundMoney(state.escrow.money)
    if recordedLegMoney ~= cachedEscrowMoney then
      shared.shiftLog("escrow reconcile", string.format("%s money=%d legsSum=%d → using legs",
        tostring(reason or "sync"), cachedEscrowMoney, recordedLegMoney))
      state.escrow.money = recordedLegMoney
    end
    return recordedLegMoney
  end

  -- tags: an add-on kind's earning tags (built-in legs have none); payEscrow carries them to the payout.
  api.recordEscrowLeg = function(label, gross, keep, share, kind, tags, finance)
    state.escrow = state.escrow or { money = 0, legs = {} }
    state.escrow.legs = state.escrow.legs or {}
    table.insert(state.escrow.legs, {
      label = label,
      gross = shared.roundMoney(gross),
      keep = shared.roundMoney(keep),
      companyShare = share,
      kind = kind,
      tags = tags and deepcopy(tags) or nil,
      finance = finance and require("overhaul/lib/finance/metadata").copy(finance) or nil,
      at = shared.nowSim(),
    })
  end

  api.registerWageHolder = function()
    if runtime.disposeWageHolder then runtime.disposeWageHolder() end
    runtime.wageHolder, runtime.disposeWageHolder = overhaul_career_economy_payment.registerWageHolder(M, {
      hold = function(price, reason)
        local keep = price.money.amount
        -- Signed damage deductions use addEscrowKeep's existing local primitive. A payment opt-in must not silently turn this earnings holder into a debit API.
        if keep < 0 then return false, 'employment wages cannot hold a net debit' end
        state.escrow = state.escrow or { money = 0, legs = {} }
        state.escrow.money = shared.roundMoney((state.escrow.money or 0) + keep)
        local finance = require("overhaul/lib/finance/metadata").capture(reason, os.time(), keep)
        api.recordEscrowLeg(reason.label, reason.gross, keep, reason.companyShare, reason.kind, reason.tags, finance)
        return true
      end,
    })
  end

  -- tags is only passed by the kind wage contract (kindContract.lua); built-in callers post the same reason as before.
  api.addEscrowKeep = function(label, gross, share, kind, tags, finance)
    share = tonumber(share) or projections.getCompanyShare()
    gross = tonumber(gross) or 0
    local keep = shared.roundMoney(gross * (1 - share))
    -- A non-finite amount would poison the escrow total and lose every wage held today: refuse it untouched.
    if keep ~= keep or keep == math.huge or keep == -math.huge then
      shared.shiftLog("escrow refused", string.format("%s: non-finite amount (gross=%s share=%s)", tostring(label), tostring(gross), tostring(share)), "W")
      return 0
    end
    if keep == 0 and gross == 0 then return 0 end
    if keep >= 0 then
      -- Refresh the handle at the accrual boundary after a map/profile epoch changes.
      api.registerWageHolder()
      local accepted = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({amount = keep,
        reason = {label = label, gross = gross, companyShare = share, kind = kind, tags = tags, finance = finance},
        destination = {kind = 'heldWages', holder = runtime.wageHolder}}, "activity:" ..
          (finance and finance.source or (type(tags) == "table" and kind or (kind == "roleplay" and "employment" or "delivery")))))
      if accepted ~= true then return 0 end
    else
      -- Damage deductions retain their signed held-pay primitive.
      state.escrow = state.escrow or { money = 0, legs = {} }
      state.escrow.money = shared.roundMoney((state.escrow.money or 0) + keep)
      api.recordEscrowLeg(label, gross, keep, share, kind)
    end
    return keep
  end
end

-- Payout -----------------------------------------------------------------------------------------

local function addPayoutApi(api, inputs)
  local shared, state = inputs.shared, inputs.state

  api.formatTodaysWagesMessage = function(total, wages, bonus, opts)
    wages = shared.roundMoney(wages or total or 0)
    bonus = shared.roundMoney(bonus or 0)
    total = shared.roundMoney(total or (wages + bonus))
    if opts and opts.kindUnavailable then
      local ended = "Shift ended: its job type is no longer available."
      local fine = shared.roundMoney(opts.abandonFine or 0)
      local penalty = fine > 0 and string.format(" Penalty: $%d.", fine) or ""
      if total <= 0 then return ended .. " No wages were held." .. penalty end
      return string.format("%s Held wages paid: $%d.%s", ended, total, penalty)
    end
    if total <= 0 then
      if opts and opts.openEnded then
        return "Shift ended."
      end
      return "Shift ended. No wages held this shift."
    end
    if bonus > 0 then
      return string.format("Shift ended. Today's wages: $%d (includes $%d high-demand bonus).", total, bonus)
    end
    return string.format("Shift ended. Today's wages: $%d.", total)
  end

  function api.escrowSurgeBonusTotal()
    local total = 0
    for _, leg in ipairs((state.escrow and state.escrow.legs) or {}) do
      if leg and leg.kind == "surgeBonus" then
        total = total + math.max(0, tonumber(leg.keep) or 0)
      end
    end
    return shared.roundMoney(total)
  end

  -- The End Day payout's tags. Built-in work is delivery pay. When today's wages hold an add-on kind's deposits (their legs carry a tag list), the payout is that kind's pay instead: the delivery tag would make Market Watch file it under Parcels, so it goes, and the kind's tags come in.
  api.escrowPayoutTags = function()
    local kindTags, fromKind = {}, false
    for _, leg in ipairs((state.escrow and state.escrow.legs) or {}) do
      if type(leg.tags) == "table" then
        fromKind = true
        for _, tag in ipairs(leg.tags) do kindTags[#kindTags + 1] = tag end
      end
    end
    if not fromKind then return { "gameplay", "deliveryReward", "employment" } end
    return api.kindEarningTags(kindTags)
  end

  -- Employment's general earning tags, then a kind's own, each once: the one rule for an add-on kind's pay, held or paid at once.
  api.kindEarningTags = function(kindTags)
    local tags, seen = { "gameplay", "employment" }, { gameplay = true, employment = true }
    for _, tag in ipairs(kindTags or {}) do
      if type(tag) == "string" and not seen[tag] then seen[tag] = true; tags[#tags + 1] = tag end
    end
    return tags
  end

  -- Built-in escrow legs are delivery money. Add-on legs carry their kind;
  -- mixed kinds stay explicit instead of inheriting whichever shift ends last.
  api.escrowWorkSource = function()
    local source
    for _, leg in ipairs((state.escrow and state.escrow.legs) or {}) do
      if (tonumber(leg.keep) or 0) > 0 and leg.kind ~= "surgeBonus" then
        local candidate = leg.finance and leg.finance.source or (type(leg.tags) == "table" and leg.kind or (leg.kind == "roleplay" and "employment" or "delivery"))
        candidate = type(candidate) == "string" and candidate or "employment"
        if source and source ~= candidate then return "employment" end
        source = candidate
      end
    end
    return source or "delivery"
  end

  api.escrowFinance = function()
    local identity, unknown = nil, false
    for _, leg in ipairs((state.escrow and state.escrow.legs) or {}) do
      if (tonumber(leg.keep) or 0) > 0 and leg.kind ~= "surgeBonus" then
        local finance = leg.finance
        local key = finance and (finance.vehicleKey or finance.vehicleId)
        if not key then unknown = true
        elseif identity and (identity.vehicleKey or identity.vehicleId) ~= key then unknown = true
        else identity = finance end
      end
    end
    local result = {locationId = state.homeFacId}
    if identity and not unknown then
      for _, key in ipairs({'vehicleId', 'vehicleKey', 'vehicleName', 'vehicleRelated'}) do result[key] = identity[key] end
    end
    return result
  end

  function api.payEscrow()
    local amount = api.reconcileEscrowMoney("payEscrow")
    local bonus = api.escrowSurgeBonusTotal()
    if amount > 0 then
      state.completedAssignments = (tonumber(state.completedAssignments) or 0) + 1
    end
    local total = amount
    if total > 0 then
      local accepted, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({amount = total,
        tags = api.escrowPayoutTags(),
        label = bonus > 0 and string.format("Today's wages + $%d high-demand bonus", bonus) or "Today's wages",
      }, "activity:" .. api.escrowWorkSource(), api.escrowFinance()))
      if accepted ~= true then
        state.completedAssignments = state.completedAssignments - 1
        return nil, problem
      end
    end
    api.resetEscrow()
    return total, math.max(0, amount - bonus), bonus
  end
end

-- Surge bonus ------------------------------------------------------------------------------------

local function addSurgeApi(api, inputs)
  local config, dispatch, projections = inputs.config, inputs.dispatch, inputs.projections

  api.isJobKindSurged = function(kind, cargoType)
    local heat = overhaul_career_economy_activityHeat
    if not heat then return false end
    local leaf = dispatch.surgeLeaf(kind, cargoType)
    if not leaf then return false end
    local factor = tonumber(heat.getDemandFactor(leaf)) or 1
    local threshold = tonumber(heat.HOT_THRESHOLD) or 1.10
    return factor >= threshold
  end

  api.maybeApplySurgeAssignmentBonus = function(shift)
    if not shift or not shift.surgeBonusEligible then return 0 end
    shift.surgeBonusEligible = nil
    local bonus = math.max(0, math.floor(tonumber(config.EMPLOYMENT_SURGE_BONUS_AMOUNT) or 0))
    if bonus <= 0 then return 0 end
    api.addEscrowKeep("High-demand assignment bonus", bonus, 0, "surgeBonus")
    ui_message(string.format("High-demand bonus: +$%d held with today's wages.", bonus), 6, "success")
    projections.notifyUi()
    return bonus
  end
end

-- Damage strikes ---------------------------------------------------------------------------------

local function addDamageApi(api, inputs)
  local config, eligibility, shared, state = inputs.config, inputs.eligibility, inputs.shared, inputs.state

  api.getDamageStrikeCount = function()
    state.damageRecord = state.damageRecord or { strikes = 0 }
    return math.max(0, math.floor(tonumber(state.damageRecord.strikes) or 0))
  end

  api.resetDamageStrikes = function()
    state.damageRecord = { strikes = 0 }
  end

  api.incrementDamageStrike = function()
    local strikeCount = api.getDamageStrikeCount() + 1
    state.damageRecord = { strikes = strikeCount }
    return strikeCount
  end

  api.handleCompanyVehicleDamaged = function()
    if not state.shift then return end
    if eligibility.isRoleplayProfile(state.shift.jobKind) then
      return
    end
    local strikeCount = api.incrementDamageStrike()
    if strikeCount <= config.DAMAGE_STRIKE_WARN_COUNT then
      if strikeCount == 1 then
        api.recordEscrowLeg("Equipment damage warning", 0, 0, 0, "damageWarning")
        ui_message("Be careful with the equipment or we will have to dock you.", 8, "warning")
      else
        api.recordEscrowLeg("Final equipment damage warning", 0, 0, 0, "damageWarning")
        ui_message("Final warning: the next damaged return comes out of your held pay.", 8, "warning")
      end
    elseif strikeCount <= (config.DAMAGE_STRIKE_WARN_COUNT + config.DAMAGE_STRIKE_DOCK_COUNT) then
      local withheldMoney = shared.roundMoney(math.max(0, (state.escrow.money or 0) * config.DAMAGE_STRIKE_DOCK_PERCENT))
      if withheldMoney > 0 then
        state.escrow.money = math.max(0, shared.roundMoney((state.escrow.money or 0) - withheldMoney))
        api.recordEscrowLeg("Equipment damage dock", withheldMoney, -withheldMoney, 0, "damageDock")
        api.reconcileEscrowMoney("damageDock")
      else
        api.recordEscrowLeg("Equipment damage dock (no held pay)", 0, 0, 0, "damageDock")
      end
      ui_message(
        string.format("Equipment damage: $%d withheld from held pay%s.", withheldMoney, strikeCount >= (config.DAMAGE_STRIKE_WARN_COUNT + config.DAMAGE_STRIKE_DOCK_COUNT) and " — one more incident and you're fired" or ""),
        8,
        "warning"
      )
    else
      api.terminateEmploymentForDamage()
      return
    end
    inputs.projections.notifyUi()
  end

  api.assessCompanyDamageBeforePayout = function()
    for _, inventoryId in ipairs(inputs.equipment.collectCompanyInventoryIds()) do
      if overhaul_career_repair_insurance.inventoryVehNeedsRepair(inventoryId) then
        api.handleCompanyVehicleDamaged()
        break
      end
    end
  end
end

-- Ending employment ------------------------------------------------------------------------------

local function addEmploymentEndApi(api, inputs)
  local persistence, projections, shared, state = inputs.persistence, inputs.projections, inputs.shared, inputs.state

  api.cancelEmploymentRepoJob = function()
    local repo = shared.repoJob()
    if repo then
      repo.cancelEmploymentJob()
    end
  end

  -- Repossession and bundle shifts hold a repo job, and delivery mode must not outlive the shift.
  local function endRepoAndDelivery(shift)
    if shift and (shared.kindPolicy(shift.jobKind).repossession or inputs.dropOff.isBundleShift(shift)) then
      api.cancelEmploymentRepoJob()
    end
    if shared.general() and shared.general().isDeliveryModeActive() then
      shared.general().exitDeliveryMode()
    end
  end

  function api.terminateEmploymentForDamage()
    if state.shift then
      state.shift.pendingDamageTermination = true
      ui_message('Equipment damage deductions still apply. Finish or explicitly abandon the current assignment before employment ends.', 8, 'warning')
      return
    end
    local organization = inputs.eligibility.getOrg(state.employerOrgId)
    local orgName = inputs.eligibility.getOrgDisplayName(organization, state.employerOrgId)
    local shift = state.shift
    if shift and shared.kindPolicy(shift.jobKind).materialContract and shared.materials() then
      shared.materials().abandonContract(nil, { noFine = true, silent = true })
    end
    endRepoAndDelivery(shift)
    state.ignoreCompanyDamageStrikes = true
    inputs.equipment.returnIssuedVehicles()
    shared.emptyShift()
    api.resetEscrow()
    persistence.setRehireBlock(state.employerOrgId)
    persistence.clearEmploymentCache()
    persistence.flushEmploymentCache()
    api.resetDamageStrikes()
    projections.firePhoneNotification(
      "employment.shiftEnded",
      "Terminated",
      string.format("%s let you go after repeated equipment damage. You cannot reapply for %d sim days.", orgName, inputs.config.REHIRE_COOLDOWN_DAYS),
      "error"
    )
    ui_message(string.format("%s terminated your employment after repeated equipment damage.", orgName), 8, "error")
    projections.notifyUi()
  end

  api.fireEmploymentForInactivity = function(mapId, employment)
    if persistence.employmentShiftBlocksInactivity(mapId, employment) then return end
    local orgId = employment and employment.employerOrgId
    if not orgId then return end
    local organization = inputs.eligibility.getOrg(orgId)
    local orgName = inputs.eligibility.getOrgDisplayName(organization, orgId)
    local hasCompletedAssignments = (tonumber(employment.completedAssignments) or 0) > 0
    if hasCompletedAssignments then
      persistence.setRehireBlock(orgId)
    else
      persistence.clearRehireBlock(orgId)
    end
    state.employments[mapId] = nil
    if mapId == (state.activeMapId or shared.currentMapId()) and state.employerOrgId == orgId then
      endRepoAndDelivery(state.shift)
      inputs.equipment.returnIssuedVehicles()
      shared.emptyShift()
      api.resetEscrow()
      persistence.clearEmploymentCache()
    end
    if hasCompletedAssignments then
      projections.firePhoneNotification(
        "employment.shiftEnded",
        "Let go for inactivity",
        string.format("%s ended your employment — no company work in %d sim days. Reapply in %d sim days.",
          orgName, inputs.config.INACTIVITY_FIRE_DAYS, inputs.config.REHIRE_COOLDOWN_DAYS),
        "error"
      )
    else
      projections.firePhoneNotification(
        "employment.shiftEnded",
        "Employment lapsed",
        string.format("%s dropped the hire — no shifts were started. You can apply again anytime.", orgName),
        "info"
      )
    end
    projections.notifyUi()
  end

  api.checkEmploymentInactivity = function()
    local nowWorldMinute = shared.nowWorldMinutes()
    if nowWorldMinute == nil then return end
    local now = shared.nowSim()
    if now <= 0 then return end
    if (tonumber(state.nextEmploymentInactivityCheckAt) or 0) > now then return end
    state.nextEmploymentInactivityCheckAt = now + 1
    persistence.applyPendingLastWorkRefresh(nowWorldMinute)
    if state.shift then
      state.lastWorkAt = now
      state.lastWorkWorldMinute = nowWorldMinute
    end
    persistence.flushEmploymentCache()
    for mapId, employment in pairs(state.employments or {}) do
      if employment and employment.employerOrgId then
        if persistence.employmentShiftBlocksInactivity(mapId, employment) then
          employment.lastWorkAt = now
          employment.lastWorkWorldMinute = nowWorldMinute
          if mapId == (state.activeMapId or "") then
            state.lastWorkAt = now
            state.lastWorkWorldMinute = nowWorldMinute
          end
        else
          if not tonumber(employment.lastWorkWorldMinute) and not tonumber(employment.hiredWorldMinute) then
            employment.lastWorkWorldMinute = nowWorldMinute
            employment.hiredWorldMinute = nowWorldMinute
          end
          local lastWorkWorldMinute = tonumber(employment.lastWorkWorldMinute or employment.hiredWorldMinute) or 0
          if lastWorkWorldMinute > 0 and lastWorkWorldMinute <= nowWorldMinute and (nowWorldMinute - lastWorkWorldMinute) >= shared.inactivityFireWorldMinutes() then
            api.fireEmploymentForInactivity(mapId, employment)
          end
        end
      end
    end
  end
end

-- Drop-off settlement ----------------------------------------------------------------------------

local function addDropOffSettlementApi(api, inputs)
  local dropOff, projections, shared, state = inputs.dropOff, inputs.projections, inputs.shared, inputs.state

  api.cargoMatchesEmployerOrg = function(cargo)
    if not cargo or not state.employerOrgId then return false end
    if cargo.organization and cargo.organization == state.employerOrgId then return true end
    for orgId, _ in pairs(cargo.loanerOrganisations or {}) do
      if orgId == state.employerOrgId then return true end
    end
    local facId = (cargo.origin and cargo.origin.facId) or (cargo.location and cargo.location.facId)
    return facId and dropOff.facilityMatchesEmployer(facId) or false
  end

  api.offerMatchesEmployerOrg = function(offer)
    if not offer or not state.employerOrgId then return false end
    if offer.organization and offer.organization == state.employerOrgId then return true end
    local facId = offer.origin and offer.origin.facId
    return facId and dropOff.facilityMatchesEmployer(facId) or false
  end

  api.dropOffAssignedToShift = function(dropOffData)
    local shift = state.shift
    if not shift then return false end
    if shared.kindPolicy(shift.jobKind).materialContract then return true end
    local offerIds = dropOff.shiftVehicleOfferIdSet(shift)
    for _, cargo in ipairs((dropOffData and dropOffData.cargo) or {}) do
      if dropOff.cargoIsAssigned(cargo) then return true end
    end
    if next(offerIds) then
      for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
        local offer = offerData.offer or offerData
        if offer and offer.id and offerIds[offer.id] then return true end
      end
    end
    return false
  end

  api.dropOffMatchesEmployerOrg = function(dropOffData)
    if not inputs.lifecycle.isOnShift() or not state.employerOrgId then return false end
    for _, cargo in ipairs((dropOffData and dropOffData.cargo) or {}) do
      if api.cargoMatchesEmployerOrg(cargo) then return true end
    end
    for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
      if api.offerMatchesEmployerOrg(offerData.offer or offerData) then return true end
    end
    return false
  end

  api.vanillaDeliveryDamageMoney = function(dropOffData)
    local total, label = 0, nil
    for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
      for _, rewardBreakdown in ipairs(offerData.breakdown or {}) do
        if rewardBreakdown and (rewardBreakdown.damageLevel == "slight" or rewardBreakdown.damageLevel == "excessive") then
          local money = tonumber(rewardBreakdown.rewards and rewardBreakdown.rewards.money) or 0
          if money < 0 then
            total = total + money
            if rewardBreakdown.damageLevel == "excessive" or not label then
              label = rewardBreakdown.label
            end
          end
        end
      end
    end
    return total, label or "Cargo damage"
  end

  -- A held delivery resumes driving once the drop-off is settled.
  local function resumeHeldDelivery(shift)
    if not shift.paused then return end
    shift.paused = false
    if shared.general() then
      shared.general().startDeliveryMode()
    end
  end

  -- Books the delivery pay and any cargo damage into held wages, then empties the reward money.
  local function holdDropOffMoney(shift, rewardSum, dropOffData)
    local share = projections.getCompanyShare()
    local gross = tonumber(rewardSum.money) or 0
    local damageMoney, damageLabel = api.vanillaDeliveryDamageMoney(dropOffData)
    local deliveryGross = gross - damageMoney
    if deliveryGross ~= 0 then
      local finance = require("overhaul/lib/finance/vehicleContext").single(dropOffData.financeVehicleIds,
        dropOffData.financeVehicles, dropOffData.financeHasUnknownVehicle, #(dropOffData.offers or {}))
      for key, value in pairs(dropOffData.financeLocation or {}) do finance[key] = value end
      local keep = api.addEscrowKeep("Delivery", deliveryGross, share, "delivery", nil, finance)
      local total = api.reconcileEscrowMoney("afterDropOffAdd")
      if not shift.stringMode and keep > 0 and damageMoney >= 0 then
        ui_message(string.format("+$%d to today's held wages ($%d total).", keep, total), 5, "info")
      end
    end
    if damageMoney < 0 then
      local withheldEmployeeMoney = api.addEscrowKeep(damageLabel, damageMoney, share, "cargoDamage")
      local total = api.reconcileEscrowMoney("afterDropOffDamage")
      ui_message(string.format("%s: $%d withheld from held pay ($%d remaining).", damageLabel, math.abs(withheldEmployeeMoney), total), 8, "warning")
    end
    rewardSum.money = 0
  end

  local function advanceBundleAfterDropOff(shift)
    if shift.assignments and shift.assignments.vehicle and not shift.assignments.vehicle.complete then
      shift.assignments.vehicle.complete = true
      ui_message("Car hauling assignment complete.", 6, "success")
      if shift.assignments.repo and not shift.assignments.repo.complete then
        inputs.routing.beginBundleRepoLeg()
      else
        dropOff.maybeCompleteBundleShift()
      end
    elseif shift.assignments and shift.assignments.repo and not shift.assignments.repo.complete then
      shift.assignments.repo.complete = true
      ui_message("Car hauling complete.", 6, "success")
      dropOff.maybeCompleteBundleShift({ atYard = true })
    end
  end

  local function advanceDistributorAfterDropOff(shift, dropOffData)
    shift.deliveredOfferIds = shift.deliveredOfferIds or {}
    local deliveredOfferIdSet = {}
    for _, id in ipairs(shift.deliveredOfferIds) do deliveredOfferIdSet[id] = true end
    for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
      local offer = offerData.offer or offerData
      if offer and offer.id and dropOff.shiftVehicleOfferIdSet(shift)[offer.id] and not deliveredOfferIdSet[offer.id] then
        table.insert(shift.deliveredOfferIds, offer.id)
        deliveredOfferIdSet[offer.id] = true
      end
    end
    local remaining = dropOff.distributorHaulRemaining(shift)
    if remaining > 0 then
      ui_message(string.format("%d vehicle%s left on this haul.", remaining, remaining == 1 and "" or "s"), 6, "info")
      inputs.routing.routeCurrentAssignment()
      projections.refreshTaskGuidance(true)
    else
      dropOff.afterOutboundDelivered()
    end
  end

  local function advanceFreightAfterDropOff(shift, dropOffData)
    if dropOff.isDistributorHaulShift(shift) and shift.phase == "outbound" then
      advanceDistributorAfterDropOff(shift, dropOffData)
    elseif shift.phase == "outbound" then
      inputs.parcelStrings.pruneDelivered(shift, dropOffData)
      dropOff.afterOutboundDelivered()
    elseif shift.phase == "return" then
      dropOff.afterReturnDelivered()
    end
  end

  -- Moves the shift on after a drop-off that belongs to it: bundle legs, or the freight phase.
  local function advanceShiftAfterDropOff(shift, dropOffData)
    api.maybeApplySurgeAssignmentBonus(shift)
    if dropOff.isBundleShift(shift) then
      advanceBundleAfterDropOff(shift)
    elseif not shared.kindPolicy(shift.jobKind).materialContract then
      advanceFreightAfterDropOff(shift, dropOffData)
    end
  end

  function api.consumeDropOffMoneyForEscrow(rewardSum, dropOffData)
    if type(rewardSum) ~= "table" or not state.shift then
      inputs.screen.dropOffEscrowPending = false
      return rewardSum
    end
    local shift = state.shift
    local isOutboundDelivery = (shared.kindPolicy(shift.jobKind).trailerDelivery or shared.kindPolicy(shift.jobKind).parcels)
      and shift.phase == "outbound"
    local hasAssignedDropOff = api.dropOffAssignedToShift(dropOffData)
    local hasEmployerDropOff = api.dropOffMatchesEmployerOrg(dropOffData)
    if not hasAssignedDropOff and not hasEmployerDropOff then
      inputs.screen.dropOffEscrowPending = false
      projections.notifyUi()
      return rewardSum
    end

    resumeHeldDelivery(shift)
    holdDropOffMoney(shift, rewardSum, dropOffData)
    if hasAssignedDropOff then
      advanceShiftAfterDropOff(shift, dropOffData)
    end
    inputs.screen.dropOffEscrowPending = false
    api.reconcileEscrowMoney("afterDropOff")
    inputs.persistence.flushEmploymentCache()
    projections.notifyUi()
    if isOutboundDelivery and state.shift == shift
        and (shift.phase == "return" or shift.phase == "loopComplete") and inputs.screen.dropOffOpen then
      projections.closeDropOffUi()
    end
    return rewardSum
  end
end

-- Constructor ------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}

  addEscrowLedgerApi(api, inputs)
  addPayoutApi(api, inputs)
  addSurgeApi(api, inputs)
  addDamageApi(api, inputs)
  addEmploymentEndApi(api, inputs)
  addDropOffSettlementApi(api, inputs)
  return api
end

return part
