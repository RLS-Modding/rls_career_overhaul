-- Player vehicle membership through couplers and nearby inventory vehicles for world interaction.
-- Read coupler traversal, player membership, interaction queries, then public API and hooks.
local M = {}

-- Uncoupled job trailers sit in the stall next to the truck; 50 m covers a yard without pulling in a distant garage.
local INTERACTION_NEAR_SQ = 50 * 50

local dirty = true
local seatedId = nil
local playerIds = {}
local couplerGroups, leadGroups = {}, {}
-- Scratch for group near queries (callers must not retain).
local nearScratch = {}

local function markDirty()
  dirty = true
  table.clear(couplerGroups)
  table.clear(leadGroups)
end

local function idInList(list, vehId)
  for i = 1, #list do
    if list[i] == vehId then return true end
  end
  return false
end

-- B-trains can have more than one trailer between the queried vehicle and the tow vehicle, so walk to the cab.
local function resolveLeadId(rootVehId, resolveLead)
  local leadId = rootVehId
  if resolveLead and core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer then
    local visited = {}
    while leadId and not visited[leadId] do
      visited[leadId] = true
      local parentId = core_trailerRespawn.getAttachedNonTrailer(leadId)
      if not parentId or parentId == leadId or visited[parentId] then break end
      leadId = parentId
    end
  end
  return leadId
end

-- Membership only needs vehicle ids; the stock tree also resolves every coupler's
-- node names for placement, which is costly and directional from trailer roots.
local function buildCouplerGroup(rootVehId)
  local ids, seen = {rootVehId}, {[rootVehId] = true}
  local coreVeh = extensions.core_vehicles
  local links = coreVeh and coreVeh.attachedCouplers or {}
  local index = 1
  while index <= #ids do
    local vehId = ids[index]
    for _, link in ipairs(links) do
      local neighborId
      if link[1] == vehId then neighborId = link[2]
      elseif link[2] == vehId then neighborId = link[1] end
      if neighborId and not seen[neighborId] and getObjectByID(neighborId) then
        seen[neighborId] = true
        ids[#ids + 1] = neighborId
      end
    end
    index = index + 1
  end
  couplerGroups[rootVehId] = ids
  return ids
end

local function couplerGroup(rootVehId, resolveLead)
  local cache = resolveLead and leadGroups or couplerGroups
  local ids = cache[rootVehId]
  if ids then return ids end
  local leadId = resolveLeadId(rootVehId, resolveLead)
  ids = couplerGroups[leadId] or buildCouplerGroup(leadId)
  if rootVehId ~= leadId and not idInList(ids, rootVehId) then
    local withRoot = {}
    for i, id in ipairs(ids) do withRoot[i] = id end
    withRoot[#withRoot + 1] = rootVehId
    ids = withRoot
  end
  cache[rootVehId] = ids
  return ids
end

--- Coupler group for any root vehicle (lead + attached). Does not touch player cache.
local function fillCouplerGroup(rootVehId, into, opts)
  into = into or {}
  table.clear(into)
  if not rootVehId then return into end
  local ids = couplerGroup(rootVehId, opts and opts.resolveLead)
  for i, id in ipairs(ids) do into[i] = id end
  return into
end

local function rebuildPlayerVehicles()
  table.clear(playerIds)
  local pid = be:getPlayerVehicleID(0)
  if not pid or pid == -1 then
    seatedId = nil
    dirty = false
    return
  end

  seatedId = pid
  -- Seated vehicle + everything coupled to it = player vehicles.
  fillCouplerGroup(pid, playerIds)
  dirty = false
end

local function ensurePlayerVehicles()
  local pid = be:getPlayerVehicleID(0)
  if dirty or pid ~= seatedId then
    rebuildPlayerVehicles()
  end
end

--- Ids that currently count as the player (seated + coupled). Do not mutate.
local function getPlayerVehicleIds()
  ensurePlayerVehicles()
  return playerIds
end

local function fillPlayerVehicleIds(into)
  ensurePlayerVehicles()
  table.clear(into)
  for i = 1, #playerIds do
    into[i] = playerIds[i]
  end
  return into
end

local function getPlayerVehicleCount()
  ensurePlayerVehicles()
  return #playerIds
end

local function isPlayerVehicle(vehId)
  if not vehId then
    return false
  end
  ensurePlayerVehicles()
  for _, id in ipairs(playerIds) do
    if id == vehId then
      return true
    end
  end
  return false
end

-- The origin for proximity: the seated vehicle, else the player's vehicle, else the camera.
local function interactionOriginPosition()
  local originId = seatedId
  if not originId or originId == -1 then
    originId = be:getPlayerVehicleID(0)
  end
  local originObj = originId and originId ~= -1 and getObjectByID(originId) or nil
  local originPos = originObj and originObj:getPosition() or nil
  if not originPos then
    originPos = core_camera.getPosition()
  end
  return originPos
end

-- Seated + coupler group + nearby spawned inventory vehicles (owned/loaner). Use this for parking markers and cargo scans, not for task state machines.
local function fillInteractionVehicleIds(into)
  fillPlayerVehicleIds(into)

  local originPos = interactionOriginPosition()
  if not originPos then
    return into
  end

  local inv = overhaul_career_garage_inventory
  local map = inv and inv.getMapInventoryIdToVehId and inv.getMapInventoryIdToVehId()
  if not map then
    return into
  end

  for _, vehId in pairs(map) do
    if vehId and not idInList(into, vehId) then
      local obj = getObjectByID(vehId)
      if obj and obj:getJBeamFilename() ~= "unicycle"
          and (obj:getPosition() - originPos):squaredLength() <= INTERACTION_NEAR_SQ then
        into[#into + 1] = vehId
      end
    end
  end
  return into
end

--- True if any vehicle in rootVehId's coupler group is within thresholdSq of pos.
local function anyInGroupNear(rootVehId, pos, thresholdSq, opts)
  if not pos then
    return false
  end
  fillCouplerGroup(rootVehId, nearScratch, opts)
  for _, id in ipairs(nearScratch) do
    local obj = scenetree.findObjectById(id)
    if obj and (obj:getPosition() - pos):squaredLength() <= thresholdSq then
      return true
    end
  end
  return false
end

-- Coupler is the membership key.
M.onCouplerAttached = markDirty
M.onCouplerDetached = markDirty
M.onVehicleSwitched = markDirty
M.onVehicleDestroyed = markDirty
M.onVehicleSpawned = markDirty
M.onClientEndMission = markDirty
M.onExtensionLoaded = markDirty

M.getPlayerVehicleIds = getPlayerVehicleIds
M.fillPlayerVehicleIds = fillPlayerVehicleIds
M.fillInteractionVehicleIds = fillInteractionVehicleIds
M.getPlayerVehicleCount = getPlayerVehicleCount
M.isPlayerVehicle = isPlayerVehicle
M.fillCouplerGroup = fillCouplerGroup
M.anyInGroupNear = anyInGroupNear
M.invalidate = markDirty

return M
