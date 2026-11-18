-- Commit confirmed fuel state without capturing a temporary dyno build's
-- native conditions. Only installed physical parts may receive their state.
local copy=require('common/rlsFuelModel').copy
return function(conditions,snapshot,inventoryId,businessVehicle)
  if type(conditions)~='table' or type(snapshot)~='table' then return false end
  if businessVehicle then
    local changed=false
    for path,condition in pairs(conditions) do
      local integrity=type(condition)=='table' and condition.integrityState
      if type(integrity)=='table' then
        for name,engine in pairs(snapshot.engines or {}) do
          local state=engine.state
          local device=integrity.powertrain and integrity.powertrain[name]
          local previous=type(device)=='table' and device.rlsFuelEngineState
          local origin=state and state.partOrigin
          if origin and origin~='' and origin~='mainEngine' and origin~=name and (tostring(path):match('([^/]+)$')==origin or
              (previous and previous.partOrigin==origin and previous.engineOwner==state.engineOwner)) then
            integrity.powertrain=integrity.powertrain or {}
            device=type(device)=='table' and device or {}
            integrity.powertrain[name]=device
            device.rlsFuelEngineState=copy(state)
            device.rlsFuelEngineState.deviceName=name
            changed=true
          end
        end
        for name,device in pairs(integrity.energyStorage or {}) do
          local tank=snapshot.tanks and snapshot.tanks[name]
          if type(device)=='table' and tank and tank.energyType~='diesel' then
            device.rlsFuelTank={version=3,name=name,blend=copy(tank.blend),liters=tank.liters}
            changed=true
          end
        end
      end
    end
    return changed
  end
  local inventory=overhaul_career_parts_partInventory
  if not inventory or not inventory.getInventory then return false end
  local changed=false
  for partId,part in pairs(inventory.getInventory() or {}) do
    local condition=conditions[part.partPath]
    if part.location==inventoryId and type(condition)=='table' then
      for name,engine in pairs(snapshot.engines or {}) do
        local state=engine.state
        if state and state.partOrigin==part.name and state.engineOwner=='part:'..tostring(part.id or partId) then
          condition.integrityState=type(condition.integrityState)=='table' and condition.integrityState or {}
          local integrity=condition.integrityState
          integrity.powertrain=type(integrity.powertrain)=='table' and integrity.powertrain or {}
          local device=integrity.powertrain[name]
          if type(device)~='table' then device={};integrity.powertrain[name]=device end
          device.rlsFuelEngineState=copy(state)
          device.rlsFuelEngineState.deviceName=name
          changed=true
        end
      end
      local storages=type(condition.integrityState)=='table' and condition.integrityState.energyStorage
      for name,device in pairs(type(storages)=='table' and storages or {}) do
        local tank=snapshot.tanks and snapshot.tanks[name]
        if type(device)=='table' and tank and tank.energyType~='diesel' then
          device.rlsFuelTank={version=3,name=name,blend=copy(tank.blend),liters=tank.liters}
          changed=true
        end
      end
    end
  end
  return changed
end
