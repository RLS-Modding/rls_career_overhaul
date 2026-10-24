-- A read-only quote binds the picker to loaded cargo. Validate the entire selection
-- again before moving anything, so stale jobs or loading operations cannot spill over.
local M = {}

function M.new(ctx, kindForJob)
  local quote, serial = nil, 0

  local function isCargoForJob(job, cargo)
    if cargo.data and cargo.data.brokerId then return cargo.data.brokerId == job.id end
    local handler = kindForJob(job)
    return handler.isCargoForJob and handler.isCargoForJob(ctx, job, cargo)
  end

  local function jobForCargo(jobs, cargo)
    if cargo.data and cargo.data.brokerId then return jobs[cargo.data.brokerId] end
    for _, job in pairs(jobs) do
      if isCargoForJob(job, cargo) then return job end
    end
  end

  local function hasCargo(jobs)
    for _, cargo in ipairs(ctx.parcels().getAllCargoInVehicles(true) or {}) do
      if jobForCargo(jobs, cargo) then return true end
    end
    return false
  end

  local function containerLabels(location)
    local general = ctx.general()
    for _, container in ipairs(general.getMostRecentCargoContainerData and general.getMostRecentCargoContainerData() or {}) do
      if container.vehId == location.vehId and container.containerId == location.containerId then
        return container.vehName, container.name
      end
    end
    return "Vehicle " .. tostring(location.vehId), "Cargo container " .. tostring(location.containerId)
  end

  local function penaltyFor(job, cargo)
    local handler = kindForJob(job)
    if handler.cargoDiscardPenalty then return handler.cargoDiscardPenalty(ctx, job, cargo) end
    return ctx.general().getDeliveryModePenalty(nil, false, function(item) return item.id == cargo.id end)
  end

  local function amountOf(cargo) return cargo.materialType and cargo.slots or 1 end
  local function fingerprint(cargo, penalty)
    local attributes = {}
    for key, value in pairs(penalty) do attributes[#attributes + 1] = key .. "=" .. tostring(value) end
    table.sort(attributes)
    return table.concat({tostring(cargo.location.vehId), tostring(cargo.location.containerId),
      tostring(amountOf(cargo)), table.concat(attributes, ",")}, ":")
  end

  local function prepare(jobs)
    quote = nil
    if #ctx.parcels().getTransientMoveCargo() > 0 then
      return {ok = false, message = "Finish the existing loading operation first."}
    end
    local groups, byKey, records = {}, {}, {}
    for _, cargo in ipairs(ctx.parcels().getAllCargoInVehicles(true) or {}) do
      local job = jobForCargo(jobs, cargo)
      if job then
        local penalty = penaltyFor(job, cargo)
        local amount = amountOf(cargo)
        if amount > 0 then
          -- Keep differing fines, contracts and containers apart even if their names match.
          local key = table.concat({tostring(cargo.groupId or cargo.id), tostring(cargo.location.vehId),
            tostring(cargo.location.containerId), tostring(job.kind), tostring(cargo.data.materialContractId or ""),
            tostring((penalty.money or 0) / amount)}, "|")
          local group = byKey[key]
          if not group then
            local vehicleName, containerName = containerLabels(cargo.location)
            group = {id = tostring(cargo.id), name = ctx.text(cargo.name), ids = {}, amount = 0,
              unit = cargo.materialType and job.unit or "items", penalty = -(penalty.money or 0) / amount,
              vehicleName = vehicleName, containerName = containerName}
            groups[#groups + 1], byKey[key] = group, group
          end
          group.ids[#group.ids + 1] = cargo.id
          group.amount = group.amount + amount
          records[cargo.id] = {cargo = cargo, job = job, penalty = penalty, amount = amount,
            fingerprint = fingerprint(cargo, penalty)}
        end
      end
    end
    table.sort(groups, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    serial = serial + 1
    quote = {token = serial, groups = groups, records = records}
    return {ok = true, token = serial, groups = deepcopy(groups)}
  end

  local function commit(token, selections)
    if not quote or token ~= quote.token then return false, "Reopen the discard picker to refresh this load." end
    if #ctx.parcels().getTransientMoveCargo() > 0 then return false, "Finish the existing loading operation first." end
    local wanted, moves, total, hasSelection = {}, {}, {money = 0}, false
    for _, selection in ipairs(selections or {}) do
      if wanted[selection.id] ~= nil then return false, "Choose each cargo group once." end
      local amount = tonumber(selection.amount)
      if not amount or amount ~= amount or amount < 0 or amount == math.huge then return false, "Choose a valid discard quantity." end
      wanted[selection.id] = amount
    end
    for _, group in ipairs(quote.groups) do
      local remaining = wanted[group.id] or 0
      wanted[group.id] = nil
      if remaining > group.amount or (group.unit == "items" and remaining % 1 ~= 0) then
        return false, "This discard quantity is no longer available."
      end
      for _, id in ipairs(group.ids) do
        local record = quote.records[id]
        local cargo = ctx.parcels().getCargoById(id)
        if not cargo or cargo ~= record.cargo or cargo.location.type ~= "vehicle" or record.job.status ~= "active"
          or record.job.map ~= ctx.mapId() or not isCargoForJob(record.job, cargo)
          or fingerprint(cargo, penaltyFor(record.job, cargo)) ~= record.fingerprint then
          return false, "The load changed. Reopen the discard picker."
        end
        local amount = math.min(remaining, record.amount)
        if amount > 0 then
          hasSelection = true
          moves[#moves + 1] = {cargo = cargo, amount = amount}
          for key, value in pairs(record.penalty) do total[key] = (total[key] or 0) + value * amount / record.amount end
          remaining = remaining - amount
        end
      end
    end
    if next(wanted) then return false, "This cargo group is no longer available." end
    if not hasSelection then return false, "Choose cargo to discard." end

    quote = nil -- A confirmation can only be charged once.
    for _, move in ipairs(moves) do ctx.parcels().discardCargo(move.cargo.id, move.amount) end
    ctx.playerAttributes().addAttributes(total, {category = "fine", tags = {"gameplay", "delivery", "fine"}, label = "Cargo abandonment"})
    ctx.general().requestUpdateContainerWeights()
    ctx.syncJobs()
    ctx.general().checkExitDeliveryMode()
    ctx.tasklist().sendCargoToTasklist()
    ctx.general().requestDeliveryPoiRefresh(true)
    return true, "Selected cargo discarded. Remaining work stays active."
  end

  return {prepare = prepare, commit = commit, hasCargo = hasCargo, clear = function() quote = nil end}
end

return M
