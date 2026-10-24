-- The player's vehicles inside a garage's zones, and a picker for choosing one of them.
-- Callers say what the vehicle is for and why one can't be used; the picker UI
-- (useZoneVehiclePicker.js + HouseVehiclePicker.vue) only renders the view pushed here.
-- Reading order: config, state, listing, the view, the picker session, per-frame refresh, hooks.

local M = {}

-- Config ------------------------------------------------------------------------------------------

local REFRESH_INTERVAL_SECONDS = 0.5
local SHOW_EVENT = "OverhaulZoneVehiclePickerShow"
local HIDE_EVENT = "OverhaulZoneVehiclePickerHide"
local DEFAULT_LEFT_ZONE_NOTICE = "That vehicle is no longer here."

-- State -------------------------------------------------------------------------------------------

-- One picker at a time. request holds the caller's options and callbacks; the view is rebuilt from it.
-- details caches names and thumbnails per vehicle so the half-second refresh skips file and locale work.
local picker
local nextTicket = 0

local function resetPicker()
  picker = nil
end

-- Listing -----------------------------------------------------------------------------------------

local function resolveGarage(garageOrId)
  if type(garageOrId) == "table" then return garageOrId end
  return garageOrId and overhaul_world_facilities.getFacility("garage", garageOrId) or nil
end

local function permissionReason(tags, inventoryId)
  if not tags then return nil end
  local status = overhaul_career_permissions.getStatusForTag(tags, {inventoryId = inventoryId})
  if status.allow then return nil end
  return status.label or "Not available right now"
end

-- Every spawned inventory vehicle that overlaps the garage's zones, eligible ones first:
-- the one the player is in, then nearest. options.blockedReason(inventoryId, vehicleInfo) and
-- options.permissionTags add caller rules; a vehicle with a reason is listed but can't be chosen.
local function list(garageOrId, options)
  options = options or {}
  local garage = resolveGarage(garageOrId)
  if not garage then return {} end

  local inventory = overhaul_career_garage_inventory
  local vehicles = inventory.getVehicles()
  local vehIds = inventory.getMapInventoryIdToVehId()
  local playerVehicle = getPlayerVehicle(0)
  local playerVehId = playerVehicle and playerVehicle:getID()
  local playerPos = playerVehicle and playerVehicle:getPosition()

  local entries = {}
  for inventoryId in pairs(inventory.getVehiclesInGarage(garage, true)) do
    local vehicleInfo = vehicles[inventoryId]
    local vehObj = vehIds[inventoryId] and getObjectByID(vehIds[inventoryId])
    if vehicleInfo and vehObj then
      local reason = options.blockedReason and options.blockedReason(inventoryId, vehicleInfo)
      table.insert(entries, {
        inventoryId = inventoryId,
        isCurrent = vehIds[inventoryId] == playerVehId,
        distanceMeters = playerPos and vehObj:getPosition():distance(playerPos) or nil,
        blockedReason = reason or permissionReason(options.permissionTags, inventoryId),
      })
    end
  end

  table.sort(entries, function(a, b)
    if (a.blockedReason == nil) ~= (b.blockedReason == nil) then return a.blockedReason == nil end
    if a.isCurrent ~= b.isCurrent then return a.isCurrent end
    local distanceA, distanceB = a.distanceMeters or math.huge, b.distanceMeters or math.huge
    if distanceA ~= distanceB then return distanceA < distanceB end
    return a.inventoryId < b.inventoryId
  end)
  return entries
end

local function eligibleIds(entries)
  local ids = {}
  for _, entry in ipairs(entries) do
    if not entry.blockedReason then table.insert(ids, entry.inventoryId) end
  end
  return ids
end

local function findEntry(entries, inventoryId)
  for _, entry in ipairs(entries) do
    if entry.inventoryId == inventoryId then return entry end
  end
end

-- The view ----------------------------------------------------------------------------------------

local function details(inventoryId)
  local cached = picker.details[inventoryId]
  if cached then return cached end
  local inventory = overhaul_career_garage_inventory
  local vehicleInfo = inventory.getVehicles()[inventoryId] or {}
  local thumbnail = inventory.getVehicleThumbnail(inventoryId)
  cached = {
    name = inventory.getVehicleNiceNameTranslated(inventoryId) or tostring(inventoryId),
    thumbnail = thumbnail and (thumbnail .. "?" .. tostring(vehicleInfo.dirtyDate or "")) or nil,
  }
  picker.details[inventoryId] = cached
  return cached
end

local function entryForUi(entry)
  local described = details(entry.inventoryId)
  return {
    inventoryId = tostring(entry.inventoryId),
    name = described.name,
    thumbnail = described.thumbnail,
    isCurrent = entry.isCurrent,
    distanceMeters = entry.distanceMeters and math.floor(entry.distanceMeters + 0.5) or nil,
    blockedReason = entry.blockedReason,
    canChoose = entry.blockedReason == nil,
  }
end

local function buildView()
  local vehicles = {}
  for _, entry in ipairs(picker.entries) do table.insert(vehicles, entryForUi(entry)) end
  return {
    ticket = picker.ticket,
    title = picker.request.title,
    placeName = picker.request.placeName,
    actionLabel = picker.request.actionLabel,
    blockedCaption = picker.request.blockedCaption,
    notice = picker.notice,
    vehicles = vehicles,
  }
end

-- Distances shown in whole metres, so walking only re-pushes the view when a number changes.
local function viewSignature(entries)
  local parts = {}
  for _, entry in ipairs(entries) do
    local metres = entry.distanceMeters and math.floor(entry.distanceMeters + 0.5)
    table.insert(parts, table.concat({entry.inventoryId, tostring(entry.isCurrent), tostring(metres), entry.blockedReason or ""}, ":"))
  end
  return table.concat(parts, "|")
end

local function pushView()
  picker.signature = viewSignature(picker.entries)
  guihooks.trigger(SHOW_EVENT, buildView())
end

-- The picker session ------------------------------------------------------------------------------

local function close(ticket)
  if not picker or (ticket and ticket ~= picker.ticket) then return false end
  resetPicker()
  guihooks.trigger(HIDE_EVENT, {ticket = ticket})
  return true
end

local function closeAny()
  if picker then close(picker.ticket) end
end

-- Every usable vehicle left (or turned blocked) while open: the caller explains with what remains.
local function closeEmpty()
  local request, entries = picker.request, picker.entries
  close(picker.ticket)
  if request.onNoneUsable then request.onNoneUsable(entries) end
end

-- A blocked vehicle the player is sitting in would be skipped silently by an automatic choice.
local function blocksAutomaticChoice(entries)
  for _, entry in ipairs(entries) do
    if entry.isCurrent and entry.blockedReason then return true end
  end
  return false
end

-- request = {garageId | garage, onChosen(inventoryId), onNoneUsable(entries), title, placeName,
--   actionLabel, blockedCaption, leftZoneNotice, blockedReason, permissionTags}
-- One usable vehicle runs onChosen straight away; none runs onNoneUsable with the listing.
local function choose(request)
  closeAny()
  local garage = resolveGarage(request.garage or request.garageId)
  local entries = list(garage, request)
  local ids = eligibleIds(entries)
  if #ids == 0 then
    if request.onNoneUsable then request.onNoneUsable(entries) end
    return {success = false, reason = "no_eligible_vehicle", entries = entries}
  end
  if #ids == 1 and not blocksAutomaticChoice(entries) then
    request.onChosen(ids[1])
    return {success = true, chosen = ids[1]}
  end

  nextTicket = nextTicket + 1
  picker = {ticket = nextTicket, request = request, garage = garage, entries = entries, details = {}, refreshTimer = 0}
  pushView()
  return {success = true, pending = true, ticket = picker.ticket}
end

-- The UI's choice. The list is rebuilt first: the vehicle may have left or been despawned since.
local function pick(ticket, inventoryId)
  ticket, inventoryId = tonumber(ticket), tonumber(inventoryId)
  if not picker or ticket ~= picker.ticket then return {success = false, reason = "stale_picker"} end
  picker.entries = list(picker.garage, picker.request)
  local entry = findEntry(picker.entries, inventoryId)
  if not entry or entry.blockedReason then
    if #eligibleIds(picker.entries) == 0 then
      closeEmpty()
      return {success = false, reason = "no_eligible_vehicle"}
    end
    picker.notice = entry and entry.blockedReason or picker.request.leftZoneNotice or DEFAULT_LEFT_ZONE_NOTICE
    pushView()
    return {success = false, reason = entry and "vehicle_blocked" or "vehicle_left_zone"}
  end
  local onChosen = picker.request.onChosen
  close(ticket)
  onChosen(inventoryId)
  return {success = true}
end

local function cancel(ticket)
  return {success = close(tonumber(ticket))}
end

local function refresh()
  if not picker then return end
  picker.entries = list(picker.garage, picker.request)
  if #eligibleIds(picker.entries) == 0 then return closeEmpty() end
  if viewSignature(picker.entries) ~= picker.signature then pushView() end
end

-- Per-frame refresh -------------------------------------------------------------------------------

local function onUpdate(dtReal)
  if not picker then return end
  picker.refreshTimer = picker.refreshTimer + (dtReal or 0)
  if picker.refreshTimer < REFRESH_INTERVAL_SECONDS then return end
  picker.refreshTimer = 0
  refresh()
end

-- Public API --------------------------------------------------------------------------------------

M.list = list
M.eligibleIds = eligibleIds
M.choose = choose
M.pick = pick
M.cancel = cancel
M.isOpen = function() return picker ~= nil end

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onVehicleDestroyed = function() if picker then picker.refreshTimer = REFRESH_INTERVAL_SECONDS end end
M.onClientEndMission = closeAny
M.onOverhaulActive = function(active) if not active then closeAny() end end

return M
