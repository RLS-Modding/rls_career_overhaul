-- Customer-job race proof and reconciliation of active job vehicles.
-- Read part hashing, race identifiers, proof/time checks and vehicle restoration.
local installer = {}
local capabilities = require('overhaul/lib/platform/capabilities')

function installer.new(inputs)

  local parts = inputs.parts

  local jobCompletion = {}

  function jobCompletion.hashPartList(partList)
    if not partList or type(partList) ~= "table" then return nil end

    local keys = {}
    for slotPath, partName in pairs(partList) do
      if partName and partName ~= "" then
        table.insert(keys, tostring(slotPath))
      end
    end
    table.sort(keys)

    local parts = {}
    for _, slotPath in ipairs(keys) do
      table.insert(parts, slotPath .. "=" .. tostring(partList[slotPath]))
    end
    return table.concat(parts, "|")
  end

  function jobCompletion.extractPartListFromPartsTree(partsTree, partList, path)
    partList = partList or {}
    path = path or "/"
    if not partsTree then return partList end

    if partsTree.chosenPartName and partsTree.path then
      partList[partsTree.path] = partsTree.chosenPartName
    elseif partsTree.chosenPartName then
      partList[path] = partsTree.chosenPartName
    end

    if partsTree.children then
      for slotName, child in pairs(partsTree.children) do
        local childPath = path .. slotName .. "/"
        jobCompletion.extractPartListFromPartsTree(child, partList, childPath)
      end
    end
    return partList
  end

  function jobCompletion.getPartListHashFromVehicle(businessId, vehicle)
    if not vehicle then return nil end

    local partList = vehicle.partList
    if (not partList or not next(partList)) and vehicle.vehicleId then
      local targetId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
      local pulledVehicles = overhaul_career_business_fleet.getPulledOutVehicles(businessId) or {}
      for _, pulled in ipairs(pulledVehicles) do
        local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
        if pulledId == targetId and pulled.partList and next(pulled.partList) then
          partList = pulled.partList
          break
        end
      end
    end

    if (not partList or not next(partList)) and vehicle.config and vehicle.config.partsTree then
      partList = jobCompletion.extractPartListFromPartsTree(vehicle.config.partsTree, {})
    end

    return jobCompletion.hashPartList(partList)
  end

  function jobCompletion.resolveJobFromLeaderboardId(inventoryId)
    if not inventoryId or type(inventoryId) ~= "string" then return nil, nil end

    local businessId, jobId = inventoryId:match("^business_(.+)_job_(%d+)$")
    if businessId and jobId then return businessId, tonumber(jobId) or jobId end

    if not inventoryId:find("_job_", 1, true) then
      local businessIdFromVehicle, vehicleId = inventoryId:match("^business_(.+)_(%d+)$")
      if businessIdFromVehicle and vehicleId and overhaul_career_career.isActive() then
        local resolvedJobId = overhaul_career_business_fleet.getJobIdFromVehicle(businessIdFromVehicle,
          vehicleId)
        if resolvedJobId then return businessIdFromVehicle, tonumber(resolvedJobId) or resolvedJobId end
      end
    end

    return nil, nil
  end

  function jobCompletion.captureProof(businessId, jobId)
    local job = parts.persist.getJobById(businessId, jobId)
    if not job or job.status ~= "active" then return end

    local evalResult = jobCompletion.evaluateGoalTime(businessId, job)
    if not evalResult or not evalResult.goalTimeMet then return end

    local vehicle = parts.settlement.getVehicleByJobId(businessId, jobId)
    local partHash = vehicle and jobCompletion.getPartListHashFromVehicle(businessId, vehicle)
    if partHash and partHash ~= "" then
      job.completionPartHash = partHash
      job.buildInvalidated = false
    end
  end

  function jobCompletion.captureFromLeaderboardId(inventoryId)
    local businessId, jobId = jobCompletion.resolveJobFromLeaderboardId(inventoryId)
    if businessId and jobId then
      jobCompletion.captureProof(businessId, jobId)
    end
  end

  function jobCompletion.clearLeaderboardEntry(businessId, jobId, vehicleId)
    local leaderboardManager = capabilities.get('raceRecords')
    local inv = overhaul_career_business_fleet

    -- Clear both legacy job and fleet identifiers so reused IDs cannot inherit times.
    local ids = {}
    if jobId ~= nil then
      ids[#ids + 1] = inv.getBusinessJobIdentifier(businessId, jobId)
    end
    local fleetVid = vehicleId
    if fleetVid == nil and jobId ~= nil then
      fleetVid = inv.getInventoryVehicleIdForJobId(businessId, jobId)
    end
    if fleetVid == nil then
      local job = parts.persist.getJobById(businessId, jobId)
      if job and job.storedVehicleId ~= nil then
        fleetVid = job.storedVehicleId
      end
    end
    if fleetVid ~= nil then
      ids[#ids + 1] = inv.getBusinessVehicleIdentifier(businessId, fleetVid)
    end

    if leaderboardManager.clearLeaderboardInventoriesBatchAtAllLevels and #ids > 0 then
      pcall(leaderboardManager.clearLeaderboardInventoriesBatchAtAllLevels, ids)
    else
      for _, inventoryId in ipairs(ids) do
        leaderboardManager.clearLeaderboardForVehicle(inventoryId)
      end
    end

    local job = parts.persist.getJobById(businessId, jobId)
    if job then
      job.completionPartHash = nil
      job.buildInvalidated = nil
    end
  end

  function jobCompletion.invalidateProof(businessId, jobId)
    local job = parts.persist.getJobById(businessId, jobId)
    if not job or not job.completionPartHash or job.completionPartHash == "" then return end

    job.buildInvalidated = true
    job.completionPartHash = nil
  end

  function jobCompletion.getLeaderboardBestTime(businessId, job)
    if not job or not job.raceLabel then return nil end

    local lbVehicleId = job.jobId
    local invVid = overhaul_career_business_fleet.getInventoryVehicleIdForJobId(businessId, job.jobId)
    if invVid ~= nil then
      lbVehicleId = invVid
    end

    local proof, mapId = parts.persist.getBusinessProof(businessId, job.raceId or job.raceType)
    if not proof then return nil end
    local labels = proof.leaderboardLabels or {job.raceLabel}
    local best
    for _, label in ipairs(labels) do
      local time = require('overhaul/lib/business/helpers').getBestLeaderboardTime(businessId, lbVehicleId, nil, label, mapId and {mapId} or nil)
      if time and (not best or time < best) then best = time end
    end
    return best
  end

  function jobCompletion.normalizeTargetTime(job)
    local factors = {s = 1, min = 60, ms = 0.001}
    local factor = factors[job.targetTimeUnit or "s"]
    return factor and job.targetTime and job.targetTime * factor or nil
  end

  function jobCompletion.evaluateGoalTime(businessId, job)
    if not job then return nil end

    local bestTime = jobCompletion.getLeaderboardBestTime(businessId, job)
    if not bestTime then return nil end

    local targetTime = jobCompletion.normalizeTargetTime(job)
    if not targetTime then return nil end
    local decimalPlaces = job.decimalPlaces or 0
    local multiplier = 10 ^ decimalPlaces
    local currentTime = math.floor(bestTime * multiplier + 0.5) / multiplier
    return {
      bestTime = bestTime,
      targetTime = targetTime,
      currentTime = currentTime,
      goalTimeMet = currentTime <= targetTime,
    }
  end

  local function blockChangedBuild(status, message)
    status.buildChanged = true
    status.blockedMessage = message
    return status
  end

  local function meetsJobGoalTime(businessId, job, status)
    local evaluated = jobCompletion.evaluateGoalTime(businessId, job)
    if evaluated then status.goalTimeMet = evaluated.goalTimeMet end
    if not evaluated or not status.goalTimeMet then
      if job.buildInvalidated then job.buildInvalidated = false end
      return false
    end
    return true
  end

  local function verifyCurrentJobBuild(businessId, jobId, job, status)
    if job.buildInvalidated then return blockChangedBuild(status, "Build changed — re-run the event to complete") end
    if not job.completionPartHash or job.completionPartHash == "" then
      jobCompletion.captureProof(businessId, jobId)
    end
    if not job.completionPartHash or job.completionPartHash == "" then return blockChangedBuild(status, "Re-run the event to verify this build") end
    local vehicle = parts.settlement.getVehicleByJobId(businessId, jobId)
    if not vehicle then return blockChangedBuild(status, "Re-run the event to verify this build") end
    local currentHash = jobCompletion.getPartListHashFromVehicle(businessId, vehicle)
    if not currentHash or currentHash == "" or currentHash ~= job.completionPartHash then return blockChangedBuild(status, "Build changed — re-run the event to complete") end
    status.canComplete = parts.persist.getBusinessProof(businessId, job.raceId or job.raceType) ~= nil
    return status
  end

  function jobCompletion.getStatus(businessId, jobId)
    local status = {canComplete = false, goalTimeMet = false, buildChanged = false, blockedMessage = nil}
    if not businessId or not jobId then return status end
    jobId = tonumber(jobId) or jobId
    local job = parts.persist.getJobById(businessId, jobId)
    if not job or job.status ~= "active" then return status end
    if not job.raceType or not job.targetTime then return status end
    if not meetsJobGoalTime(businessId, job, status) then return status end
    return verifyCurrentJobBuild(businessId, jobId, job, status)
  end

  function jobCompletion.canComplete(businessId, jobId)
    return jobCompletion.getStatus(businessId, jobId).canComplete
  end

  -- Restore missing fleet rows so active jobs remain available for pull-out and completion.
  local function ensureActiveJobVehicles(businessId, jobs)
    if not businessId or not jobs then return false end

    local changed = false
    for _, job in ipairs(jobs.active or {}) do
      if job.vehicleConfig then
        local existing = nil
        if job.jobId ~= nil then
          existing = parts.settlement.getVehicleByJobId(businessId, job.jobId)
        end
        if existing then
          local existingId = tonumber(existing.vehicleId) or existing.vehicleId
          if job.storedVehicleId == nil or (tonumber(job.storedVehicleId) or job.storedVehicleId) ~= existingId then
            job.storedVehicleId = existingId
            changed = true
          end
        else
          local okStore, storedVehicleId = overhaul_career_business_fleet.storeVehicle(businessId, {
            vehicleConfig = job.vehicleConfig,
            jobId = job.jobId,
            mileage = job.mileage or 0,
            storedTime = os.time()
          })
          if okStore and storedVehicleId ~= nil then
            job.storedVehicleId = storedVehicleId
            changed = true
            -- New fleet id may reuse a slot that still has another job's race times.
            jobCompletion.clearLeaderboardEntry(businessId, job.jobId, storedVehicleId)
            log('I', 'tuningShop.ensureActiveJobVehicles',
              string.format('restored fleet vehicle businessId=%s jobId=%s vehicleId=%s',
                tostring(businessId), tostring(job.jobId), tostring(storedVehicleId)))
          end
        end
      end
    end
    return changed
  end

  return {
    ensureActiveJobVehicles = ensureActiveJobVehicles,
    jobCompletion = jobCompletion,
  }
end

return installer
