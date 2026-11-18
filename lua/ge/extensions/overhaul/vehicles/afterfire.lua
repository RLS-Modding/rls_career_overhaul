-- Native BeamNG afterfire only. Owns lifecycle, not rendering.
-- The player-only compatibility facade exposes fuel-owned native adjustments.
-- Traffic does not need this extension; there is no supplemental renderer.
local M={}
local scheduled,vehicles={},{}
local clock,epoch=0,0
local previous=package.loaded['ge/extensions/overhaul/afterfireVolume']
if previous and previous.destroy then previous.destroy() end
package.loaded['ge/extensions/overhaul/afterfireVolume']=nil

-- Never touch extensions.rlsAfterfire in a boolean check: that auto-loads the
-- vehicle ext and is how leftovers "leak" onto traffic after a probe/reload.
local UNLOAD_CMD=[[if type(extensions.isExtensionLoaded)=='function' and extensions.isExtensionLoaded('rlsAfterfire') then extensions.unload('rlsAfterfire') end]]

local function playerId()
  return be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
end

local function isPlayer(id)
  local pid=playerId()
  return id and pid and id==pid
end

local function unload(id)
  scheduled[id]=nil
  vehicles[id]=nil
  local v=be:getObjectByID(id)
  if v then
    v:queueLuaCommand(UNLOAD_CMD)
  end
end

local function sweepNonPlayer()
  local pid=playerId()
  for i=0,be:getObjectCount()-1 do
    local v=be:getObject(i)
    if v then
      local id=v:getID()
      if not pid or id~=pid then
        scheduled[id]=nil
        vehicles[id]=nil
        v:queueLuaCommand(UNLOAD_CMD)
      end
    end
  end
end

local function init(id)
  if not isPlayer(id) then return end
  local v=be:getObjectByID(id);if not v then return end
  epoch=epoch+1;vehicles[id]=epoch
  v:queueLuaCommand(UNLOAD_CMD..";extensions.load('rlsAfterfire');extensions.rlsAfterfire.configure("..epoch..")")
end

local function schedulePlayer(id)
  id=id or playerId()
  if not id or id<=0 then return end
  scheduled[id]=clock+.2
end

function M.onUpdate(dtReal,dtSim)
  local dt=dtSim or dtReal or 0;if dt<=0 then return end;clock=clock+dt
  for id,t in pairs(scheduled)do if clock>=t then scheduled[id]=nil;init(id) end end
end

function M.onVehicleSpawned(id)
  if isPlayer(id) then
    schedulePlayer(id)
  else
    -- Drop any leftover from older all-vehicle inits or accidental auto-loads.
    unload(id)
  end
end

function M.onVehicleResetted(id)
  if isPlayer(id) then schedulePlayer(id) end
end

function M.onVehicleSwitched(_,id)
  id=id or playerId()
  for tracked in pairs(vehicles) do
    if tracked~=id then unload(tracked) end
  end
  for tracked in pairs(scheduled) do
    if tracked~=id then scheduled[tracked]=nil end
  end
  schedulePlayer(id)
end

function M.onVehicleDestroyed(id)scheduled[id]=nil;vehicles[id]=nil end

function M.onExtensionLoaded()
  -- Prior all-vehicles builds (and MCP probes) leave traffic holding the ext
  -- even after GE is player-scoped; sweep once on load before re-init player.
  sweepNonPlayer()
  schedulePlayer()
end

function M.onExtensionUnloaded()
  for i=0,be:getObjectCount()-1 do
    local v=be:getObject(i)
    if v then v:queueLuaCommand(UNLOAD_CMD) end
  end
  vehicles={};scheduled={}
end
M.onClientEndMission=M.onExtensionUnloaded
function M.debugState()
  local count=0;for _ in pairs(vehicles)do count=count+1 end
  return {renderer='native',revision=7,vehicles=count,volumes=0,lights=0}
end
return M
