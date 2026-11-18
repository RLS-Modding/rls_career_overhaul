local M={}
local opponent,npc,contactSent,readySent
local collisionIds={}
local originalRecoveryStart,originalRecoveryStop,originalLoadHome
local function restoreRecovery()
  if originalRecoveryStart then
    recovery.startRecovering=originalRecoveryStart;recovery.stopRecovering=originalRecoveryStop
    originalRecoveryStart=nil;originalRecoveryStop=nil
  end
  if originalLoadHome then recovery.loadHome=originalLoadHome;originalLoadHome=nil end
end
function M.configure(otherId,isNpc)
  restoreRecovery();opponent=otherId;npc=isNpc;contactSent=false;readySent=false
  if npc then
    if not partCondition.getConditions() then partCondition.initConditions() end
    electrics.setLightsState(1)
    electrics.setIgnitionLevel((electrics.values.engineRunning or 0)>0 and 2 or 3)
  else
    originalRecoveryStart,originalRecoveryStop=recovery.startRecovering,recovery.stopRecovering
    recovery.startRecovering=function(alternate)
      obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('streetKnightsRecovery',obj:getID()..','..tostring(alternate==true)))
    end
    recovery.stopRecovering=function() end
    originalLoadHome=recovery.loadHome
    recovery.loadHome=function()
      obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('streetKnightsHomeRecovery',tostring(obj:getID())))
    end
  end
end
function M.stop() restoreRecovery();opponent=nil;npc=false end
function M.updateGFX()
  if opponent and not contactSent then
    table.clear(collisionIds);obj:getObjectCollisionIds(collisionIds)
    for _,id in ipairs(collisionIds) do if id==opponent then
      contactSent=true
      obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('streetKnightsContact',obj:getID()..','..opponent))
    end end
  end
  if npc and not readySent and (electrics.values.engineRunning or 0)>0 then
    readySent=true;electrics.setIgnitionLevel(2)
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('streetKnightsOpponentReady',tostring(obj:getID())))
  end
end
M.onExtensionUnloaded=M.stop
return M
