local M={}
-- Saved photos live in the save slot and are deleted with the vehicle, so keep a copy beside the slots.
local function keepThumbnail(env,inventory,record)
  local source=inventory.getVehicleThumbnail and inventory.getVehicleThumbnail(record.race.carId)
  if type(source)~='string' then return end
  local root=source:match('^(.*)/[^/]+/career/vehicles/[^/]+%.jpg$')
  if not root then return source end
  local dir=root..'/lostVehicleThumbnails/'
  if not env.FS:directoryExists(dir) then env.FS:directoryCreate(dir) end
  local target=dir..record.id..'.jpg'
  if env.FS:copyFile(source,target)==0 then return target end
end
function M.transfer(env,journal,record)
  local inventory=env.overhaul_career_garage_inventory
  local car=inventory.getVehicles()[record.race.carId]
  if car and not record.lostVehicle then
    local config=car.config
    local sceneId=inventory.getVehicleIdFromInventoryId and inventory.getVehicleIdFromInventoryId(record.race.carId)
    local data=sceneId and env.core_vehicle_manager.getVehicleData(sceneId)
    if data and data.config then config=data.config end
    if type(car.model)~='string' or car.model=='' or type(config)~='table' then
      return nil,'Could not preserve your car for a future rematch. Your keys have not transferred.'
    end
    local mileage=tonumber(car.mileage) or 0
    for _,condition in pairs(car.partConditions or {})do mileage=math.max(mileage,tonumber(condition.odometer) or 0)end
    local updated=env.deepcopy(record)
    updated.lostVehicle={vehicle={model=car.model,config=env.deepcopy(config),niceName=car.niceName or car.model,
      mileage=mileage,year=car.year,configBaseValue=car.configBaseValue,originalParts=env.deepcopy(car.originalParts),
      changedSlots=env.deepcopy(car.changedSlots),thumbnail=keepThumbnail(env,inventory,record)},lostAt=env.os.time(),
      ownerId=record.race.winBackOwnerId or record.race.opponent.id,
      ownerName=record.race.opponent.owner or record.race.opponent.name or 'Rival'}
    local savedConfig=updated.lostVehicle.vehicle.config
    savedConfig.partConfigFilename=savedConfig.partConfigFilename or (car.config and car.config.partConfigFilename)
    local saved,err=journal:write(updated)
    if not saved then return nil,err end
    record=saved
  end
  if car then
    inventory.removeVehicle(record.race.carId,true)
    if inventory.getVehicles()[record.race.carId] then return nil,'Could not remove the pink-slip car (clear cargo or work first).' end
  end
  if record.lostVehicle and not record.lostVehicle.transferred then
    local updated=env.deepcopy(record);updated.lostVehicle.transferred=true
    return journal:write(updated)
  end
  return record
end
-- Losses saved before 2.8.0.3 kept no parts baseline, so rebuild the parts the factory config
-- ships with, priced the way the part inventory prices them. Without it, upgrades count as stock.
-- Returns the parts, or nil and why: 'unread' (try again on a later load) or 'unresolved' (do not retry).
local function factoryParts(env,model,filename)
  if type(model)~='string' or model=='' or type(filename)~='string' or filename=='' then return nil,'unread' end
  local pc=env.jsonReadFile(filename)
  if type(pc)~='table' then return nil,'unread' end
  local jbeamIO=require('jbeam/io')
  local ioCtx
  local ok,parts=pcall(function()
    ioCtx=jbeamIO.startLoading({'/vehicles/'..model..'/','/vehicles/common/'})
    pc=env.deepcopy(pc)
    -- As the game's config loader does: a file older than format 2 is a flat slot-to-part map.
    -- Format 4 lists several vehicles, not one car's parts.
    if pc.format==4 then return end
    if pc.format~=2 and pc.parts==nil and pc.partsTree==nil then pc={parts=pc} end
    pc.mainPartName=pc.mainPartName or jbeamIO.getMainPartName(ioCtx)
    pc.mainPartPath=pc.mainPartPath or '/'..pc.mainPartName
    local _,_,_,tree=require('jbeam/slotSystem').findParts(ioCtx,pc)
    if not tree then return end
    local result={}
    local function visit(node)
      local name=node.chosenPartName
      if type(name)=='string' and name~='' and node.path then
        local part=jbeamIO.getPart(ioCtx,name)
        result[node.path]={name=name,value=part and part.information and part.information.value or 100}
      end
      for _,child in pairs(node.children or {}) do visit(child) end
    end
    visit(tree)
    return next(result) and result or nil
  end)
  if ioCtx then jbeamIO.finishLoading() end
  if ok and parts then return parts end
  log('W','pinkSlipWinBack','Could not rebuild factory parts for '..model..' from '..filename..': '..tostring(ok and 'no parts' or parts))
  return nil,'unresolved'
end
-- Saved on the car: true when rebuilt, false when its config could not be resolved, unset to try again.
local function baselineState(parts,failure)
  if parts then return true end
  if failure=='unresolved' then return false end
end
local function lostConfigFilename(original,vehicle)
  local filename=original.config and original.config.partConfigFilename
  if type(filename)=='string' and filename~='' then return filename end
  return vehicle.config and vehicle.config.partConfigFilename
end
function M.restoreValue(env,vehicle,original)
  if type(original)~='table' then return end
  if type(original.originalParts)=='table' then
    vehicle.originalParts=env.deepcopy(original.originalParts)
    vehicle.changedSlots=env.deepcopy(original.changedSlots or {})
  else
    local parts,failure=factoryParts(env,original.model or vehicle.model,lostConfigFilename(original,vehicle))
    if parts then vehicle.originalParts=parts;vehicle.changedSlots={} end
    vehicle.factoryBaselineRestored=baselineState(parts,failure)
  end
  local filename=original.config and original.config.partConfigFilename
  if vehicle.config and type(filename)=='string' and filename~='' then vehicle.config.partConfigFilename=filename end
end
-- Cars won back from such a loss before this fix took their upgrades as stock parts; rebuild once.
function M.repairReclaimed(env,journal,transactionField)
  local inventory=env.overhaul_career_garage_inventory
  for id,vehicle in pairs(inventory.getVehicles()) do
    local record=vehicle[transactionField] and journal.records[vehicle[transactionField]]
    local original=record and record.race.winBackId and record.race.opponent and record.race.opponent.originalVehicle
    if type(original)=='table' and type(original.originalParts)~='table' and vehicle.factoryBaselineRestored==nil then
      local parts,failure=factoryParts(env,original.model or vehicle.model,lostConfigFilename(original,vehicle))
      if parts then vehicle.originalParts=parts end
      vehicle.factoryBaselineRestored=baselineState(parts,failure)
      if vehicle.factoryBaselineRestored~=nil and inventory.setVehicleDirty then inventory.setVehicleDirty(id) end
    end
  end
end
function M.list(journal,level)
  local claimed,result={},{}
  for _,record in pairs(journal.records)do
    if record.state=='locked' and record.outcome=='win' and record.race.winBackId then claimed[record.race.winBackId]=true end
  end
  for _,record in ipairs(journal:ordered())do
    local lost=record.lostVehicle
    if lost and lost.transferred and not claimed[record.id] and record.race.venue.level==level then
      result[#result+1]={id=record.id,order=record.race.order,night=record.race.night,lostAt=lost.lostAt,
        ownerId=lost.ownerId,ownerName=lost.ownerName,vehicle=lost.vehicle}
    end
  end
  return result
end
function M.opponent(lost)
  return {id='winback:'..lost.id,name=lost.ownerName,model=lost.vehicle.model,config=lost.vehicle.config,
    thumbnail=lost.vehicle.thumbnail or '/vehicles/'..lost.vehicle.model..'/default.jpg',description='Your former '..lost.vehicle.niceName,
    winBackId=lost.id,winBackOwnerId=lost.ownerId,originalVehicle=lost.vehicle}
end
return M
