-- Garage config export. This shell owner survives Career and map lifetimes.
-- Copyright (C) RLS Modding; SPDX-License-Identifier: AGPL-3.0-only
local M = {}
-- Native pause content can mount during the map handoff, after auto extensions
-- unload but before its route lifecycle runs again. Keep its provider in this
-- persistent owner's dependency graph so those real UI callbacks remain valid.
-- Earlier 0.40 builds without this provider also lack the corresponding UI.
if FS:fileExists('/lua/ge/extensions/ui/pause/providers/vehicleTabInteractions.lua') then
  M.dependencies={'ui_pause_providers_vehicleTabInteractions'}
end
local payloadRules = require('overhaul/lib/vehicles/configExport')
local configPartValues = require('overhaul/lib/vehicles/configPartValues')
local couplingRules = require('overhaul/lib/vehicles/exportCouplings')
local fuelRules = require('common/rlsFuelConfig')
local copy = require('common/rlsFuelModel').copy
local ROOT, JOURNAL = '/settings/RLS/vehicleExports/', '/settings/RLS/configExport/'
local HOLD_OWNER='rlsConfigExport'
local checkpointSessions=require('overhaul/lib/career/checkpointSessions')
local unregisterSession
local function writer() return require('overhaul/lib/save/store').immediateWriter() end
local exportManifest
local function settings()
  if not exportManifest then exportManifest=assert(jsonReadFile('/gameplay/overhaul/vehicles/configExport.json'),'Missing export manifest') end
  return exportManifest
end
local job, elapsed, journalSequence, optionsCache = nil, 0, 0, nil
local phaseStarted, workerVehicle, pendingCapture, hold
local journalUnavailable=false
local recoveryStorageError
local checkpointCleanup={}
local dependencyCache=setmetatable({}, {__mode='k'})
local TERMINAL = {done=true,failed=true,cancelled=true}
local messages = {
  prepare='Getting your build ready…', checkpoint='Saving your career…',
  loadTests='Loading the test track…', tests='Running performance tests on a copy of your vehicle…',
  loadShowroom='Loading the showroom…', thumbnail='Taking the showroom photo…',
  returning='Returning to your career…', restoring='Loading your career…', verify='Checking your vehicle is unchanged…',
  writing='Saving the export…', recovery='Return to your career to keep playing.',
}
local function active() return overhaul_career_career and overhaul_career_career.isActive() end
local function inventory() return overhaul_career_garage_inventory end
local function saveSystem() return overhaul_career_saveSystem end
local function object(id) return id and be:getObjectByID(id) end
local function busy() return job and not TERMINAL[job.phase] end
local function blockInput(block)
  local filter=core_input_actionFilter
  if not filter then return end
  local actions=filter.createActionTemplate({'competitive','walkingMode','resetPhysics','vehicleTriggers','setShifterMode','couplers','radialMenuActivate','bigMap','photoMode'},nil,
    {'throttle','brake','steering','throttleBrake','parkingbrake','clutch','shiftUp','shiftDown','toggleIgnition','toggleStarter','activateNitrous'})
  filter.setGroup('rlsConfigExport',actions)
  filter.addAction(0,'rlsConfigExport',block)
end
-- The player reads `message`. `detail` is for the log only: playerMessage() never shows past the first line.
local function fail(message,detail) error(detail and (message..'\n'..detail) or message, 0) end
-- Anything with a source position is a code error: the log keeps it, the player gets a plain line.
local function playerMessage(err,fallback)
  if err==nil then return fallback end
  local text=tostring(err):match('^[^\n]+') or ''
  if text:find('%.lua:%d+:') then return fallback or 'Something went wrong during the export.' end
  return text
end
local function returnWarning(vehicleId,detail)
  job.returnWarnings=job.returnWarnings or {}
  local id=inventory() and inventory().getInventoryIdFromVehicleId(vehicleId)
  job.returnWarnings[#job.returnWarnings+1]={inventoryId=id,message='Some vehicle details could not be restored exactly.',detail=tostring(detail or '')}
  log('W','vehicleExport','return notice ('..tostring(id or vehicleId)..'): '..tostring(detail))
end
local function ensureDir(dir) if not FS:directoryExists(dir) then writer().mkdir(dir, true) end end
local function journal()
  -- A failed recovery write aborts the job. Allow the already-authorized return
  -- to finish in memory; never recurse through another failing journal write.
  if journalUnavailable then return end
  journalSequence = journalSequence + 1
  local file = JOURNAL .. (journalSequence % 2 == 0 and 'current_a.json' or 'current_b.json')
  local state = {version=1,sequence=journalSequence,job=job,checkpointCleanup=checkpointCleanup}
  local ok,checked=pcall(function()
    ensureDir(JOURNAL)
    if writer().json(file,state,true)==false then return nil end
    return jsonReadFile(file)
  end)
  if not ok or not checked or checked.sequence ~= journalSequence or (job and (not checked.job or checked.job.id ~= job.id or checked.job.phase ~= job.phase)) then
    journalUnavailable=true
    fail('The export could not save its safety copy of your career.')
  end
end
local function publish()
  if guihooks then guihooks.trigger('RlsVehicleExportJob', M.getStatus()) end
end
local function phase(nextPhase, message)
  local previousPhase=job.phase
  job.phase, job.message = nextPhase, message or messages[nextPhase]
  job.changedAt = os.time()
  job.revision=(job.revision or 0)+1
  phaseStarted, elapsed = nil, 0
  if nextPhase=='restoring' then job.returnSpawns={} end
  local ok,err=pcall(journal)
  if not ok then job.phase=previousPhase;error(err,0) end
  publish()
end
local function stage()
  return settings().phases[job and job.phase or 'prepare'].stage
end
function M.getStatus()
  if not job then return {busy=false,sequence=journalSequence,error=recoveryStorageError} end
  -- Inventory numbers are local to a Career. A different save can also own #1.
  if not busy() and active() and saveSystem().getCurrentProfile()~=job.profile then return {busy=false,sequence=journalSequence} end
  local result=copy(job.result)
  if result and result.ok and job.request.runTests then result.tests=job.testReport or payloadRules.testReport(job.payload.info) end
  return {id=job.id,profile=job.profile,model=job.payload.model,sequence=journalSequence,revision=job.revision or 0,busy=busy() == true,phase=job.phase,stage=stage(),message=job.message,
    inventoryId=job.inventoryId,request=copy(job.request),vehicle=copy(job.vehicle),result=result,
    error=job.error,returnWarnings=copy(job.returnWarnings),careerRestored=job.careerRestored==true,recoveryRequired=job.phase=='recovery',cancelled=job.cancelled==true and job.manualReturn~=true,manualReturn=job.manualReturn==true,
    canContinueCareer=job.phase=='recovery' and active() and saveSystem().getCurrentProfile()==job.profile and getCurrentLevelIdentifier()==job.returnLevel or false,
    sessionVisible=busy()==true and job.departed==true and not job.careerRestored
      and (job.phase=='tests' or job.phase=='thumbnail' or job.phase=='verify' or job.phase=='stoppingThumbnail' or job.phase=='recovery')
      and (not active() or saveSystem().getCurrentProfile()==job.profile)}
end
function M.requestState()
  publish()
  -- A UI reload during departure can lose the native loading-screen event.
  -- The overlay boot resync runs after the new UI bridge is listening again.
  if busy() and core_gamestate and core_gamestate.getLoadingStatus and core_gamestate.getLoadingStatus('freeroam') then
    guihooks.trigger('LoadingScreen',{active=true})
  end
end
local function releaseHold() if hold then hold.release(); hold=nil end end
local function releaseRecoveryControls()
  if not job or not active() or saveSystem().getCurrentProfile()~=job.profile or getCurrentLevelIdentifier()~=job.returnLevel then return end
  releaseHold();blockInput(false)
  be:setPhysicsRunning(not job.originalPhysics or job.originalPhysics.running~=false)
end
local function returnUi()
  if job and job.skipReturnUi then return end
  local id,computerId=job and job.id,job and job.request.computerId
  if not computerId then return end
  core_jobsystem.create(function(wait)
    wait.sleep(.05)
    if not job or job.id~=id or not TERMINAL[job.phase] or not active() or not job.careerRestored then return end
    local computer=overhaul_career_garage_computer
    computer.openComputerMenuById(computerId)
    computer.computerButtonCallback('rls-vehicleExport',job.inventoryId)
  end)
end
local function releasePhysics()
  if job and job.originalPhysics then
    be:setPhysicsSpeedFactor(job.originalPhysics.speed)
    be:setPhysicsRunning(job.originalPhysics.running)
  end
end
local function cleanupFixtures()
  if not job then return end
  if workerVehicle and object(workerVehicle) and not active() then object(workerVehicle):delete() end
  workerVehicle=nil
  for _, file in ipairs(job.fixtures or {}) do
    if file:sub(1,#('/vehicles/'..job.payload.model..'/__rls_export_')) == '/vehicles/'..job.payload.model..'/__rls_export_' then
      writer().remove(file)
    end
  end
end
local function removeWorker()
  if workerVehicle and object(workerVehicle) and not active() then object(workerVehicle):delete() end
  workerVehicle=nil
end
local function retireCheckpoint()
  if job.keepCheckpoint then return end
  if not job.checkpointReady or not job.careerRestored or job.checkpointRetired or job.checkpointName~='export_'..job.id then return end
  for _,entry in ipairs(checkpointCleanup) do if type(entry)=='table' and entry.profile==job.profile and entry.name==job.checkpointName then return end end
  checkpointCleanup[#checkpointCleanup+1]={profile=job.profile,name=job.checkpointName,id=job.id}
end
local function recoverArchive()
  if not job or not job.destination then return true end
  if type(job.payload.slug)~='string' or not job.payload.slug:match('^rls_shared_[%w_%-]+$') then return false,'The export folder could not be checked. Your career is safe.' end
  local expected=ROOT..job.payload.model..'/'..job.payload.slug..'.zip'
  if job.destination~=expected then return false,'The export folder could not be checked. Your career is safe.' end
  local backup=job.destination..'.previous'
  if FS:fileExists(backup) and not FS:fileExists(job.destination) then
    if writer().rename(backup,job.destination)~=0 then return false,'The earlier export could not be put back. Its backup and the new copy were both kept in the exports folder.' end
  end
  return true
end
local function removeStage()
  if job and type(job.id)=='string' and job.id:match('^%d+_%d+$') and FS.directoryRemove then
    local directory=ROOT..'.staging/'..job.id..'/'
    if FS:directoryExists(directory) then writer().removeDir(directory) end
  end
end
-- How an export that was stopped on purpose ends: by Cancel export, or by Return to career after a failed return.
local function stoppedMessage()
  local details=next(job.returnWarnings or {}) and 'Your career is ready. Some vehicle details could not be restored exactly.' or 'Your career is ready.'
  return (job.manualReturn and 'You are back in your career\nNothing was exported. ' or 'Export cancelled\nNothing was exported. ')..details
end
local function finishFailure(message, cancelled)
  if not job.departed then job.careerRestored=true end
  cleanupFixtures(); releaseHold(); releasePhysics();blockInput(false)
  retireCheckpoint()
  local recovered,recoveryError=recoverArchive()
  if recovered then removeStage() else recoveryStorageError=recoveryError;message=message..' '..recoveryError end
  if active() and saveSystem().getCurrentProfile()==job.profile then overhaul_career_career.setAutosaveEnabled(job.originalAutosave) end
  job.error = message
  job.result = {ok=false,code=cancelled and 'cancelled' or nil,message=message,careerRestored=job.careerRestored==true,returnWarnings=copy(job.returnWarnings)}
  phase(cancelled and 'cancelled' or 'failed',message)
  returnUi()
end
local function beginReturn(message)
  job.error = message or job.error
  if job.thumbnailAttempted and not job.thumbnailCleaned then
    local capture=require('overhaul/lib/vehicles/exportThumbnail')
    if capture.cancel and capture.cancel()==false then phase('stoppingThumbnail','Stopping the showroom photo before returning…');return end
    capture.restore();job.thumbnailCleaned=true
  end
  removeWorker()
  if not job.departed then
    job.careerRestored=true
    return finishFailure(job.error or stoppedMessage(),job.cancelled)
  end
  phase('returning')
end
local function sourceInfo(record)
  local model = core_vehicles.getModel(record.model)
  local info = copy(type(model)=='table' and type(model.model)=='table' and model.model or {})
  local filename = record.config and record.config.partConfigFilename
  if type(filename)=='string' and #filename<512 and filename:sub(-3)=='.pc' then
    local name=filename:gsub('\\','/'):match('([^/]+)%.pc$')
    local config=name and jsonReadFile('/vehicles/'..record.model..'/info_'..name..'.json')
    for key,value in pairs(type(config)=='table' and config or {}) do info[key]=value end
  end
  return info
end
local function metadataOptions()
  if optionsCache then return optionsCache end
  local sets={['Config Type']={},['Body Style']={}}
  local function collect(data)
    if type(data)~='table' then return end
    for key, set in pairs(sets) do
      local value=data[key]
      if type(value)=='string' and #value<=80 then set[value]=true end
      local aggregate=type(data.aggregates)=='table' and data.aggregates[key]
      if type(aggregate)=='table' then
        for item in pairs(aggregate) do if type(item)=='string' and #item<=80 then set[item]=true end end
      end
    end
  end
  for _,source in ipairs({{core_vehicles.getModelList,'models'},{core_vehicles.getConfigList,'configs'}}) do
    local ok,result=pcall(source[1])
    local entries=ok and type(result)=='table' and result[source[2]]
    if type(entries)=='table' then for _,data in pairs(entries) do collect(data) end end
  end
  optionsCache={configTypes={},bodyStyles={}}
  for key, name in pairs({['Config Type']='configTypes',['Body Style']='bodyStyles'}) do
    for value in pairs(sets[key]) do optionsCache[name][#optionsCache[name]+1]=value end
    table.sort(optionsCache[name])
  end
  return optionsCache
end
local function validateParts(record,runtime)
  if not core_vehicles.getModel(record.model) then return nil,'The mod for this vehicle is missing or broken. Turn it back on or repair it, then press Try again.' end
  -- Check saved choices too: native spawning can silently substitute defaults
  -- when an installed mod part disappeared before this vehicle was loaded.
  if not runtime or not runtime.ioCtx then return nil,'The parts on this vehicle are not loaded yet. Bring the vehicle out, then press Try again.' end
  local io=require('jbeam/io')
  local names=payloadRules.partNames(record.config or {})
  for name in pairs(payloadRules.partNames(runtime.config or {})) do names[name]=true end
  local missing={}
  for name in pairs(names) do
    local ok,part=pcall(io.getPart,runtime.ioCtx,name)
    if not ok or type(part)~='table' then missing[#missing+1]=name end
  end
  table.sort(missing)
  if #missing>0 then return nil,'Some parts are missing. Turn on or reinstall their mods, then press Try again.\nMissing parts: '..table.concat(missing,', ',1,math.min(#missing,5))..(#missing>5 and (' and '..(#missing-5)..' more') or '') end
  return true
end
local function fuelFor(id)
  local vehId=inventory().getVehicleIdFromInventoryId(id)
  local fuel=overhaul_career_maintenance_fuelSystem
  return fuel and vehId and fuel.getSnapshot(vehId)
end
local function dependenciesFor(id)
  local vehId=inventory().getVehicleIdFromInventoryId(id)
  local runtime=vehId and core_vehicle_manager.getVehicleData(vehId)
  local config=runtime and runtime.config
  if not config or not runtime.ioCtx then return {} end
  if dependencyCache[config] then return copy(dependencyCache[config]) end
  local jbeam=require('jbeam/io')
  local seenParts,seenFiles,mods={},{},{}
  for name in pairs(payloadRules.partNames(config)) do
    if type(name)=='string' and name~='' and #name<160 and not seenParts[name] then
      seenParts[name]=true
      local ok,_,file=pcall(jbeam.getPart,runtime.ioCtx,name)
      if ok and file and not seenFiles[file] then
        seenFiles[file]=true
        local found,mod=pcall(core_modmanager.getModFromPath,file)
        if found and mod and mod.modname then
          local data=mod.modData or {}
          local label=data.title or data.name
          mods[mod.modname]=type(label)=='string' and label or tostring(mod.modname)
        end
      end
    end
  end
  local names={};for _,label in pairs(mods) do names[#names+1]=label end;table.sort(names)
  dependencyCache[config]=names
  return copy(names)
end
local function selectedVehicle(id)
  local record=inventory() and inventory().getVehicle(id)
  if not record or record.owned~=true then return nil end
  local info=sourceInfo(record)
  local setup=fuelRules.pack(fuelFor(id))
  local engineNames={}
  if setup then
    local vehicleId=inventory().getVehicleIdFromInventoryId(id)
    local runtime=vehicleId and core_vehicle_manager.getVehicleData(vehicleId)
    for _,state in pairs(setup.engines) do
      local ok,part=pcall(function() return runtime and runtime.ioCtx and require('jbeam/io').getPart(runtime.ioCtx,state.partOrigin) end)
      local name=ok and type(part)=='table' and type(part.information)=='table' and part.information.name
      if type(name)=='string' and name~='' then engineNames[state.partOrigin]=translateLanguage and translateLanguage(name,name,true) or name end
    end
  end
  return {inventoryId=id,model=record.model,name=record.niceName or info.Configuration or record.model,
    modelName=((info.Brand or '')..' '..(info.Name or record.model)):match('^%s*(.-)%s*$'),
    description=translateLanguage and translateLanguage(info.Description or '',info.Description or '',true) or info.Description or '',thumbnail=inventory().getVehicleThumbnail(id),
    metadata={['Config Type']=info['Config Type'],['Body Style']=info['Body Style']},
    testsAvailable=info.Type~='Trailer' and info.Type~='Prop',
    testUnavailableReason='Trailers and props cannot run performance tests.',
    fuel=setup and {summary=payloadRules.fuelSummary(setup,engineNames)} or nil,dependencies=dependenciesFor(id)}
end
function M.getView(id)
  id=tonumber(id)
  local status=M.getStatus()
  local selectedId=busy() and job.inventoryId or id
  local vehicle=active() and selectedVehicle(selectedId) or nil
  if not busy() and job and (not vehicle or id~=job.inventoryId or vehicle.model~=job.payload.model) then status={busy=false,sequence=journalSequence} end
  if not vehicle and (busy() or not active()) then vehicle=job and copy(job.vehicle) end
  return {vehicle=vehicle,profile=active() and saveSystem().getCurrentProfile() or nil,metadataOptions=metadataOptions(),job=status}
end
local function preflight(request)
  if recoveryStorageError then return nil,recoveryStorageError end
  if busy() then return nil,'Another export is still running. Wait for it to finish or cancel it first.' end
  if not active() then return nil,'Open Export configuration from a garage computer in your career.' end
  if saveSystem().isSaveBusy() or require('overhaul/lib/save/store').isHeld() then return nil,'Your career is still saving. Wait a moment, then try again.' end
  local id=tonumber(request.inventoryId)
  local record=id and inventory().getVehicle(id)
  if not record or record.owned~=true then return nil,'Pick a vehicle you own.' end
  if record.loanType or record.timeToAccess or record.listedForAuction then return nil,'This vehicle is busy with a service, loan or auction. Finish that first.' end
  local found=false
  for _,garageId in ipairs(inventory().getInventoryIdsInClosestGarage() or {}) do if tonumber(garageId)==id then found=true end end
  if not found then return nil,'Park this vehicle in the garage first.' end
  if inventory().isTransientBuild(id) or inventory().isDamageRestorePending(id) then return nil,'This vehicle is still being worked on. Finish that first.' end
  local name,err=payloadRules.name(request.name)
  if not name then return nil,err end
  local mode=request.thumbnailMode or (request.includePreview and 'garage' or 'none')
  if mode~='garage' and mode~='showroom' and mode~='none' then return nil,'Choose a photo option.' end
  local travelling=request.runTests==true or mode=='showroom'
  if travelling then
    -- Names only what the player chose: turning that off exports right away.
    local away=request.runTests==true and (mode=='showroom' and 'a showroom photo and performance tests' or 'performance tests') or 'a showroom photo'
    local driving=overhaul_career_police_playerDriving
    if driving and driving.playerPursuitActive() then return nil,'Finish the police pursuit first, or export without '..away..'.' end
    local block=overhaul_career_work_employment and overhaul_career_work_employment.getMapTravelBlockMessage()
    if block then return nil,block end
    local missions=gameplay_missions_missionManager
    if missions and missions.getForegroundMissionId and missions.getForegroundMissionId() then return nil,'Finish your current mission first, or export without '..away..'.' end
    for inventoryId in pairs(inventory().getMapInventoryIdToVehId()) do
      local logistics=overhaul_career_logistics_general
      if logistics and not logistics.canRemoveLogisticsVehicle(inventoryId,true) then return nil,'Finish or unload your deliveries first, or export without '..away..'.' end
    end
  end
  local profile,path=saveSystem().getCurrentProfile()
  if not profile or not path then return nil,'Your career save could not be found.' end
  local vehId=inventory().getVehicleIdFromInventoryId(id)
  local runtime=vehId and core_vehicle_manager.getVehicleData(vehId)
  local partsReady,partsError=validateParts(record,runtime)
  if not partsReady then return nil,partsError end
  local payload;payload,err=payloadRules.build(record,runtime and runtime.config,sourceInfo(record),request,fuelFor(id))
  if not payload then return nil,err end
  local priced,stats,catalogValue=pcall(function()
    local jbeam=require('jbeam/io')
    local values=configPartValues.sum(payload.pc,function(name)
      local part=jbeam.getPart(runtime.ioCtx,name)
      return part and part.information and part.information.value
    end)
    return values,overhaul_career_market_valueCalculator.getVehiclePartsCatalogValue(values.total)
  end)
  if not priced then return nil,'The installed part prices could not be read. Check this vehicle\'s mods, then try again.' end
  local valued;valued,err=payloadRules.applyPartValues(payload,stats,catalogValue)
  if not valued then return nil,err end
  local destination=ROOT..payload.model..'/'..payload.slug..'.zip'
  if FS:fileExists(destination) and request.replace~=true then return nil,nil,{ok=false,code='exists'} end
  local vehicle=selectedVehicle(id)
  payload.info.rlsExport.sourceMods=copy(vehicle.dependencies)
  if request.runTests and not vehicle.testsAvailable then return nil,vehicle.testUnavailableReason end
  if mode=='garage' and not vehicle.thumbnail then return nil,'This vehicle has no garage photo. Choose another photo option.' end
  return {id=id,profile=profile,path=path,payload=payload,vehicle=vehicle,mode=mode,
    travelling=travelling,destination=destination,vehId=vehId}
end
function M.start(request)
  if type(request)~='table' then return {ok=false,message='The export could not start. Try again.'} end
  local accepted,err,response=preflight(request)
  if not accepted then
    response=response or {ok=false,message=err}
    response.started=false -- validation refused the job; Career never departed
    return response
  end
  journalUnavailable=false
  local token=tostring(os.time())..'_'..tostring(math.random(100000,999999))
  job={version=1,id=token,phase='prepare',request=copy(request),inventoryId=accepted.id,
    profile=accepted.profile,originalSavePath=accepted.path,returnLevel=getCurrentLevelIdentifier(),
    originalAutosave=overhaul_career_career.isAutosaveEnabled(),
    originalPhysics={running=be:getPhysicsRunning(),speed=be:getPhysicsSpeedFactor()},
    payload=accepted.payload,vehicle=accepted.vehicle,thumbnailMode=accepted.mode,
    destination=accepted.destination,travelling=accepted.travelling,careerRestored=not accepted.travelling,
    checkpointName='export_'..token,fixtures={},sourceVehicleId=accepted.vehId,
    camera={position=copy(core_camera.getPosition()),rotation=copy(core_camera.getQuat()),fov=core_camera.getFovDeg(),mode=core_camera.getActiveCamName(0)},
    spawned={}}
  -- Convert engine userdata explicitly. Raw vec3/quaternion objects serialize to null.
  local p,q=core_camera.getPosition(),core_camera.getQuat()
  job.camera.position={x=p.x,y=p.y,z=p.z};job.camera.rotation={x=q.x,y=q.y,z=q.z,w=q.w}
  for inventoryId,vehId in pairs(inventory().getMapInventoryIdToVehId()) do
    local veh=object(vehId)
    if veh then
      local pos,rot=veh:getPosition(),quat(veh:getRotation())
      job.spawned[tostring(inventoryId)]={vehicleId=vehId,pos={x=pos.x,y=pos.y,z=pos.z},rot={x=rot.x,y=rot.y,z=rot.z,w=rot.w}}
    end
  end
  if unregisterSession then unregisterSession() end
  unregisterSession=checkpointSessions.register(HOLD_OWNER,{canSuspend=M.canSuspendCareer,isReturning=M.isReturningToCareer})
  phase('prepare')
  if job.travelling then blockInput(true) end
  return {ok=true,jobId=job.id,status=M.getStatus()}
end
function M.cancel(id)
  if not busy() or id~=job.id then return {ok=false,message='This export has already finished.'} end
  job.cancelled=true;journal()
  if job.phase~='returning' and job.phase~='restoring' and job.phase~='verify' and job.phase~='checkpoint' and job.phase~='stoppingThumbnail' then beginReturn() end
  return {ok=true,status=M.getStatus()}
end
function M.restoreCareer(id)
  if not job or id~=job.id or job.phase~='recovery' then return {ok=false,message='There is no interrupted export to return from.'} end
  if not job.checkpointReady then return {ok=false,message='The export stopped before it saved your career, so you never left the garage.'} end
  if active() and saveSystem().getCurrentProfile()~=job.profile then return {ok=false,message='Close the other career first, then return to this one.'} end
  job.cancelled=true;job.manualReturn=true;job.error=nil
  -- A loaded Career must not be suspended and reloaded just because a detailed
  -- condition comparison failed. Finish the normal restore in place instead.
  local _,currentPath=saveSystem().getCurrentProfile()
  local ownsCheckpoint=currentPath and currentPath:match('([^/\\]+)$')==job.checkpointName
  if active() and ownsCheckpoint and getCurrentLevelIdentifier()==job.returnLevel then
    if not hold then hold=require('overhaul/lib/save/store').hold(HOLD_OWNER,'Finishing export career return') end
    phase('restoring')
  else beginReturn() end
  return {ok=true,status=M.getStatus()}
end
function M.continueCareer(id)
  if not job or id~=job.id or not M.getStatus().canContinueCareer then return {ok=false,message='Load this career before continuing.'} end
  -- Continuing keeps the currently loaded Career, not an older checkpoint's
  -- runtime values. Retain its recovery data without holding gameplay hostage.
  job.keepCheckpoint=true;job.skipReturnUi=true
  local saved,err=pcall(function()
    ensureDir(JOURNAL)
    assert(writer().json(JOURNAL..'recovery_'..job.id..'.json',{version=1,job=job},true)~=false)
  end)
  if not saved then log('W','vehicleExport','Recovery archive: '..tostring(err)) end
  returnWarning(nil,'Automatic restoration was incomplete. The named Career checkpoint was kept.')
  job.cancelled=true;job.manualReturn=true;job.careerRestored=true;job.error=nil
  local running,speed=be:getPhysicsRunning(),be:getPhysicsSpeedFactor()
  finishFailure(stoppedMessage(),true)
  be:setPhysicsRunning(running);be:setPhysicsSpeedFactor(speed)
  return {ok=true,status=M.getStatus()}
end
function M.canSuspendCareer(id)
  return job and id==job.id and busy() and job.checkpointReady==true
    and saveSystem().getCurrentProfile()==job.profile and not saveSystem().isSaveBusy()
    and (job.phase=='depart' or job.phase=='returning') or false
end
function M.isReturningToCareer()
  return busy()==true and job.checkpointReady==true and job.departed==true
    and (job.phase=='restoring' or job.phase=='verify')
    and saveSystem().getCurrentProfile()==job.profile or false
end
local function commandWorker(veh,kind)
  if kind~='preflight' then workerVehicle=veh:getID() end
  veh:queueLuaCommand("extensions.load('overhaulExportWorker'); extensions.overhaulExportWorker.start("..serialize({jobId=job.id,kind=kind})..")")
end
local function loadMap(level,nextPhase)
  phase(nextPhase)
  spawn.preventPlayerSpawning=true
  freeroam_freeroam.startFreeroam(path.getPathLevelMain(level),nil,false)
end
local function nextAfterTests()
  if job.thumbnailMode=='showroom' then loadMap(settings().maps.thumbnail,'loadShowroom') else phase('returning') end
end
function M.onWorkerResult(result)
  if not busy() or type(result)~='table' or result.jobId~=job.id then return end
  if result.kind=='preflight' and job.phase=='prepare' then
    if not job.preflightPending or not job.preflightPending[tostring(result.vehicleId)] then return end
    job.preflightPending[tostring(result.vehicleId)]=nil
    local inventoryId=inventory().getInventoryIdFromVehicleId(result.vehicleId)
    if result.returnState and inventoryId and job.spawned[tostring(inventoryId)] then job.spawned[tostring(inventoryId)].runtime=result.returnState end
    if not result.ok then pendingCapture={ok=false,message=playerMessage(result.message)}
    elseif not pendingCapture or pendingCapture.ok then
      pendingCapture=pendingCapture or {ok=true}
      if result.vehicleId==job.sourceVehicleId then pendingCapture.measurements=result.measurements end
    end
  elseif result.kind=='couplings' and job.phase=='verify' and job.couplingStage=='couplings' then
    if result.round~=job.couplingRound or not job.couplingPending or not job.couplingPending[tostring(result.vehicleId)] then return end
    job.couplingPending[tostring(result.vehicleId)]=nil
    if not result.ok then
      be:setPhysicsRunning(false)
      log('W','vehicleExport','coupling return check: '..tostring(result.message))
      job.error=playerMessage(result.message,'The game could not restore a parked coupling.');phase('recovery');releaseRecoveryControls()
    else job.couplingsReady=job.couplingsReady and result.couplingsReady==true end
  elseif result.kind=='restore' and job.phase=='verify' and job.couplingStage~='couplings' then
    if not job.restorePending or not job.restorePending[tostring(result.vehicleId)] then return end
    job.restorePending[tostring(result.vehicleId)]=nil
    -- Older installed workers send ok=false for a comparison mismatch too.
    -- The Career identity/spawn checks already passed: this is diagnostic only.
    if not result.ok or result.returnStateMatched==false then returnWarning(result.vehicleId,result.message or table.concat(result.restoreWarnings or {},', ')) end
  elseif result.kind=='tests' and job.phase=='tests' and result.vehicleId==workerVehicle then
    if not result.ok then beginReturn(playerMessage(result.message,'The performance tests could not finish.'));return end
    payloadRules.applyMeasurements(job.payload,result.measurements,job.payload.pc.rlsFuel and 'overhaul-career-fuel' or 'native')
    job.testReport=payloadRules.testReport(job.payload.info,result.testIssues)
    job.payload.info.rlsExport.tests=copy(job.testReport)
    job.performance=result.display;nextAfterTests()
  end
end
function M.resetWorkerVehicle(vehicleId,position)
  if not busy() or job.phase~='tests' or vehicleId~=workerVehicle or type(position)~='table' or #position~=7 then return false end
  local vehicle=object(vehicleId)
  if not vehicle then return false end
  be:resetVehicle(vehicleId)
  vehicle:setPositionRotation(unpack(position))
  vehicle:autoplace(false)
  return true
end
local function spawnCopy()
  local veh=core_vehicles.spawnNewVehicle(job.payload.model,{config=job.tempConfig,autoEnterVehicle=true})
  if not veh then fail('The game could not bring out a copy of your vehicle for the export.') end
  workerVehicle=veh:getID()
  return veh
end
local function restoreCamera()
  local c=job.camera
  core_camera.setByName(0,'free')
  core_camera.setPosRot(0,c.position.x,c.position.y,c.position.z,c.rotation.x,c.rotation.y,c.rotation.z,c.rotation.w)
  core_camera.setFOV(0,c.fov)
  if c.mode and c.mode~='free' then core_camera.setByName(0,c.mode) end
end
local function restoreRuntime()
  be:setPhysicsRunning(false)
  job.couplingStage='runtime';job.restorePending={};job.runtimeStartedAt=elapsed
  for id,expected in pairs(job.spawned) do
    local vehId=inventory().getVehicleIdFromInventoryId(tonumber(id))
    local veh=object(vehId)
    if not veh then fail('A saved vehicle is not loaded yet.','vehicle '..id) end
    if not expected.runtime then returnWarning(vehId,'The detailed return snapshot is unavailable; the normal Career checkpoint was loaded.')
    else
      job.restorePending[tostring(vehId)]=true
      local queued,err=pcall(function()veh:queueLuaCommand("extensions.load('overhaulExportWorker'); extensions.overhaulExportWorker.start("..serialize({jobId=job.id,kind='restore',state=expected.runtime})..")")end)
      if not queued then job.restorePending[tostring(vehId)]=nil;returnWarning(vehId,err) end
    end
  end
end
local function checkCouplings(attach)
  job.couplingPending={};job.couplingsReady=true
  job.couplingRound=(job.couplingRound or 0)+1;job.couplingCheckedAt=elapsed
  for id,entry in pairs(job.couplingPlan) do
    local veh=object(entry.vehicleId)
    if not veh or inventory().getVehicleIdFromInventoryId(tonumber(id))~=entry.vehicleId then fail('A parked vehicle disappeared while reconnecting your garage.') end
    job.couplingPending[tostring(entry.vehicleId)]=true
    veh:queueLuaCommand("extensions.load('overhaulExportWorker'); extensions.overhaulExportWorker.start("..serialize({jobId=job.id,kind='couplings',round=job.couplingRound,edges=entry.edges,attach=attach})..")")
  end
end
local function publishBundle()
  local stageRoot=ROOT..'.staging/'..job.id..'/'
  local target=stageRoot..job.payload.relative
  ensureDir(target)
  if writer().json(target..job.payload.slug..'.pc',job.payload.pc,true)==false or writer().json(target..'info_'..job.payload.slug..'.json',job.payload.info,true)==false then fail('The export files could not be saved. Try again.') end
  local checked=jsonReadFile(target..job.payload.slug..'.pc')
  if not checked or not checked.parts and not checked.partsTree then fail('The saved export could not be read back. Try again.') end
  local files=copy(job.payload.files)
  local image=job.thumbnailMode=='showroom' and job.thumbnailSource or job.thumbnailMode=='garage' and job.vehicle.thumbnail
  if image then
    image=image:gsub('%?.*$','')
    if writer().copy(image,target..job.payload.slug..'.jpg')~=0 then fail('The photo could not be added to the export. Try again, or pick another photo option.') end
    files[#files+1]=job.payload.slug..'.jpg'
  end
  local zipPath=stageRoot..'export.zip'
  local zip=ZipArchive()
  zip:openArchiveName(zipPath,'w')
  if not tostring(zip:getModeString()):find('write',1,true) then zip:close();fail('The export ZIP could not be created. Try again.') end
  for _,file in ipairs(files) do zip:addFile(target..file,job.payload.relative..file) end
  zip:close()
  local verify=ZipArchive();verify:openArchiveName(zipPath,'r')
  local members=verify:getFileList();verify:close()
  local found={};for _,member in ipairs(members or {}) do found[member:gsub('^/+','')]=true end
  for _,file in ipairs(files) do if not found[job.payload.relative..file] then fail('The export ZIP came out incomplete. Try again.','missing: '..file) end end
  ensureDir(ROOT..job.payload.model..'/')
  -- Preserve an earlier complete export until the new candidate has been checked.
  local backup=job.destination..'.previous'
  if FS:fileExists(job.destination) then
    if job.request.replace~=true then fail('Another export took this name while yours was running. Pick another name.') end
    if FS:fileExists(backup) then fail('An earlier export with this name left a backup behind. Pick another name.') end
    if writer().rename(job.destination,backup)~=0 then fail('The earlier export with this name could not be kept safe, so it was not replaced.') end
  end
  if writer().rename(zipPath,job.destination)~=0 then
    local recovered,recoveryError=recoverArchive()
    if not recovered then fail(recoveryError) end
    fail('The finished export could not be moved into the exports folder. Try again.')
  end
  if FS:fileExists(backup) then writer().remove(backup) end
  job.result={ok=true,name=job.payload.name,files=files,archive=job.destination,folder=ROOT..job.payload.model..'/',
    careerRestored=true,performance=job.performance,tests=copy(job.testReport),returnWarnings=copy(job.returnWarnings)}
  cleanupFixtures();releaseHold();releasePhysics();blockInput(false);retireCheckpoint();removeStage();phase('done','Export ready');returnUi()
end
local function tick()
  if not busy() or job.phase=='recovery' then return end
  local first=not phaseStarted
  if first then phaseStarted=true end
  local p=job.phase
  if p=='prepare' then
    if first then
      if job.travelling then be:setPhysicsRunning(false) end
      pendingCapture=nil
      local veh=object(job.sourceVehicleId)
      if not veh then fail('The vehicle left the garage. Park it in the garage and try again.') end
      job.preflightPending={}
      for _,id in pairs(inventory().getMapInventoryIdToVehId()) do
        local car=object(id)
        if car then job.preflightPending[tostring(id)]=true;commandWorker(car,'preflight') end
      end
    end
    if pendingCapture and not next(job.preflightPending or {}) then
      if not pendingCapture.ok then finishFailure(pendingCapture.message);return end
      local measured=copy(pendingCapture.measurements or {})
      -- The source can have an active Career tune even when fuel is excluded.
      -- Power figures are measured on the temporary build only, with its chosen context.
      measured.Power,measured.Torque,measured['Weight/Power']=nil,nil,nil
      payloadRules.applyMeasurements(job.payload,measured,'native-static')
      if job.cancelled then beginReturn();return end
      if not job.travelling then phase('writing');return end
      local graph,couplingError=couplingRules.capture(job.spawned)
      if not graph then finishFailure(couplingError);return end
      job.couplings=graph
      overhaul_career_career.setAutosaveEnabled(false)
      phase('checkpoint')
      if not saveSystem().requestSave('vehicleExport:checkpoint',nil,{force=true,manual=true,saveName=job.checkpointName}) then fail('Your career could not be saved right now. Try again in a moment.') end
    end
  elseif p=='checkpoint' then
    -- The success hook, not an idle save queue, authorizes map departure.
  elseif p=='depart' then
    if journalUnavailable then fail('The export could not save its safety copy, so you never left the garage.') end
    if job.cancelled then job.careerRestored=true;finishFailure(stoppedMessage(),true);return end
    job.tempName='__rls_export_'..job.id
    job.tempConfig='/vehicles/'..job.payload.model..'/'..job.tempName..'.pc'
    job.tempImage='/vehicles/'..job.payload.model..'/'..job.tempName..'.jpg'
    if FS:fileExists(job.tempConfig) or FS:fileExists(job.tempImage) then fail('The export could not prepare a copy of your build. Try again.') end
    ensureDir('/vehicles/'..job.payload.model..'/')
    if writer().json(job.tempConfig,job.payload.pc,true)==false then fail('The export could not get your build ready. Try again.') end
    job.fixtures={job.tempConfig,job.tempImage}
    job.departed=true;journal()
    if not overhaul_career_career.suspendForCheckpoint(HOLD_OWNER,job.id) then fail('The export could not safely leave your career. Try again.') end
    be:setPhysicsSpeedFactor(1);be:setPhysicsRunning(true)
    if core_vehicles.clearCache then core_vehicles.clearCache() end
    if job.request.runTests then loadMap(settings().maps.tests,'loadTests') else loadMap(settings().maps.thumbnail,'loadShowroom') end
  elseif p=='loadTests' or p=='loadShowroom' then
    local level=p=='loadTests' and settings().maps.tests or settings().maps.thumbnail
    if getCurrentLevelIdentifier()==level and job.worldReady then
      job.worldReady=nil
      local veh=spawnCopy()
      if p=='loadTests' then
        local fuel=overhaul_career_maintenance_fuelSystem
        if not fuel or not fuel.beginExportTest(veh:getID(),job.payload.pc.rlsFuel) then fail('The fuel setup of the test vehicle could not be prepared.') end
        phase('tests');commandWorker(veh,'tests')
      else
        local capture=require('overhaul/lib/vehicles/exportThumbnail')
        job.thumbnailAttempted=true;phase('thumbnail');capture.start(job,veh)
      end
    end
  elseif p=='tests' then
    -- Worker returns bounded, partial measurements; every phase has a deadline.
  elseif p=='thumbnail' then
    local capture=require('overhaul/lib/vehicles/exportThumbnail')
    local ok,err=capture.poll(job)
    if ok then job.thumbnailSource=job.tempImage;capture.restore();job.thumbnailCleaned=true;phase('returning') elseif err then beginReturn(err) end
  elseif p=='stoppingThumbnail' then
    local capture=require('overhaul/lib/vehicles/exportThumbnail')
    if not capture.cancel or capture.cancel()~=false then capture.restore();job.thumbnailCleaned=true;removeWorker();phase('returning') end
  elseif p=='returning' then
    if first then
      if active() and saveSystem().getCurrentProfile()~=job.profile then fail('Close the other career first, then return to this one.') end
      removeWorker();releaseHold()
      be:setPhysicsSpeedFactor(1);be:setPhysicsRunning(true)
      -- Never resume a different profile implicitly. This path is the job's own checkpoint.
      if active() then
        overhaul_career_career.setAutosaveEnabled(false)
        if not overhaul_career_career.suspendForCheckpoint(HOLD_OWNER,job.id) then fail('The game could not load your saved career.') end
      end
      if not saveSystem().setProfile(job.profile,job.checkpointName) then fail('The game could not load your saved career.') end
      phase('restoring')
      overhaul_career_career.activateCareer(true,job.returnLevel)
      hold=require('overhaul/lib/save/store').hold(HOLD_OWNER,'Verifying export career return')
    end
  elseif p=='restoring' then
    if active() and getCurrentLevelIdentifier()==job.returnLevel then
      local restored=true
      for id,expected in pairs(job.spawned) do
        local vehId=inventory().getVehicleIdFromInventoryId(tonumber(id))
        local veh=object(vehId)
        if not veh and not job.returnSpawns[id] then
          job.returnSpawns[id]=true
          -- Career can omit a previously spawned parked car during its async
          -- load. Bring that owned record back through the normal damage loader.
          local record=inventory().getVehicle(tonumber(id))
          if record and record.owned then
            inventory().spawnVehicle(tonumber(id),nil,nil,{pos=vec3(expected.pos),rot=quat(expected.rot)})
          end
        end
        if not veh or inventory().isDamageRestorePending(tonumber(id)) then restored=false;break end
        -- Fuel hydration runs after the normal damage restore. Its reply proves
        -- tank chemistry and physical-engine records have reached the vehicle VM.
        local needsFuel=false
        for _,tank in pairs(expected.runtime and expected.runtime.tanks or {}) do if next(tank.blend or {}) then needsFuel=true;break end end
        local fuel=overhaul_career_maintenance_fuelSystem
        if needsFuel and (not fuel or not fuel.getSnapshot(vehId) or not fuel.getSnapshot(vehId).career) then restored=false;break end
      end
      if restored and elapsed>1 then
        be:setPhysicsRunning(false)
        phase('verify')
        if next(job.couplings or {}) then
          local plan,couplingError=couplingRules.resolve(job.spawned,job.couplings,inventory().getVehicleIdFromInventoryId,core_vehicle_manager.getVehicleData)
          if not plan then fail(couplingError) end
          job.couplingPlan=plan;job.couplingStage='couplings';job.couplingAttempted=false
          -- Inspect every partner before attaching. Native vehicle queues and
          -- damage/placement callbacks still need physics to make progress.
          checkCouplings(false)
          be:setPhysicsRunning(true)
        else restoreRuntime() end
      end
    end
  elseif p=='verify' then
    if job.couplingStage=='couplings' then
      if not next(job.couplingPending or {}) then
        if job.couplingsReady then restoreRuntime()
        elseif elapsed-job.couplingCheckedAt>=settings().couplingReturn.checkIntervalS then
          checkCouplings(not job.couplingAttempted);job.couplingAttempted=true
          -- Native couplers latch during physics steps. Put exact runtime values
          -- back only after both vehicle VMs confirm the saved connections.
          be:setPhysicsRunning(true)
        end
      end
      if elapsed>settings().couplingReturn.timeoutS then fail('The game could not reconnect a parked rig. Your recovery checkpoint was kept.') end
    else
      local timeout=settings().runtimeReturn and settings().runtimeReturn.timeoutS or 10
      if elapsed-(job.runtimeStartedAt or 0)>timeout then
        for id in pairs(job.restorePending or {}) do returnWarning(tonumber(id),'The vehicle did not answer the final restoration request.') end
        job.restorePending={}
      end
      if not next(job.restorePending or {}) then
        job.careerRestored=true
        overhaul_career_career.setAutosaveEnabled(job.originalAutosave)
        restoreCamera();releaseHold();releasePhysics();blockInput(false)
        if job.cancelled or job.error then finishFailure(job.error or stoppedMessage(),job.cancelled)
        else phase('writing') end
      end
    end
  elseif p=='writing' then publishBundle() end
  local timeout=settings().phases[p] and settings().phases[p].timeoutS or settings().defaultTimeoutS
  if elapsed>timeout and job.phase==p then fail('The export took too long and was stopped.','step: '..p) end
end
local function handleError(err)
  if busy() then
    log('E','vehicleExport',tostring(err))
    local message=playerMessage(err)
    local ok,cleanupError=pcall(function()
      if job.departed and not job.careerRestored then
        if job.phase=='returning' or job.phase=='restoring' or job.phase=='verify' or job.phase=='stoppingThumbnail' then
          job.error=message;releaseHold();phase('recovery');releaseRecoveryControls()
        else beginReturn(message) end
      else finishFailure(message) end
    end)
    if not ok then
      -- A broken native provider can fail again while being stopped/restored.
      -- Keep the durable ticket, and retry cleanup before any recovery departure.
      log('E','vehicleExport','cleanup failed: '..tostring(cleanupError))
      job.error=job.departed and not job.careerRestored and 'Something went wrong while the game was bringing you back.' or 'Something went wrong while the export was stopping.'
      job.phase=job.departed and not job.careerRestored and 'recovery' or 'failed'
      job.message=job.phase=='recovery' and messages.recovery or job.error
      job.revision=(job.revision or 0)+1
      pcall(releaseHold)
      if job.phase=='failed' then
        job.result={ok=false,message=job.error,careerRestored=job.careerRestored==true}
        pcall(releasePhysics);pcall(blockInput,false)
      end
      if job.phase=='recovery' then pcall(releaseRecoveryControls) end
      pcall(journal);pcall(publish)
    end
  else log('E','vehicleExport',tostring(err)) end
end
function M.onUpdate(dtReal)
  if not busy() then return end
  elapsed=elapsed+math.min(tonumber(dtReal) or 0,1)
  local ok,err=xpcall(tick,debug.traceback)
  if not ok then handleError(err) end
end
function M.onOverhaulSaveFinished()
  local profile,path=saveSystem().getCurrentProfile()
  local currentFolder=path and path:match('([^/\\]+)$')
  local cleaned=false
  for i=#checkpointCleanup,1,-1 do
    local entry=checkpointCleanup[i]
    if type(entry)=='table' and type(entry.id)=='string' and entry.profile==profile and currentFolder and currentFolder~=entry.name and entry.name=='export_'..entry.id
      and saveSystem().removeSaveFolder and saveSystem().removeSaveFolder(entry.profile,entry.name) then
      if job and job.id==entry.id then job.checkpointRetired=true end
      table.remove(checkpointCleanup,i);cleaned=true
    end
  end
  if cleaned then journal() end
  if not job or job.phase~='checkpoint' then return end
  if profile~=job.profile or not path or path:match('([^/]+)$')~=job.checkpointName then return end
  job.checkpointReady=true
  if job.cancelled then job.careerRestored=true;finishFailure(stoppedMessage(),true);return end
  -- Leave on the next owner update, outside the save-completion hook iteration.
  phase('depart','Leaving the garage…')
end
function M.onOverhaulSaveFailed() if job and job.phase=='checkpoint' then finishFailure('Your career could not be saved, so the export did not start.') end end
function M.onWorldReadyState(state) if job and state==2 then job.worldReady=true end end
function M.openFolder(id)
  if not job or id~=job.id or not job.result or not job.result.ok then return {ok=false} end
  Engine.Platform.exploreFolder(job.result.folder);return {ok=true}
end
function M.canLeaveComputer() return not busy() end
function M.backToComputer(computerId)
  if busy() then return {ok=false,message='Wait for the export to finish, or cancel it, before leaving.'} end
  if not active() then return {ok=false,message='Load your career first.'} end
  if computerId then overhaul_career_garage_computer.openComputerMenuById(computerId)
  else overhaul_career_career.closeAllMenus() end
  return {ok=true}
end
function M.prepareForUnload() if busy() then M.cancel(job.id);return false end;return true end
local function registerSession()
  if unregisterSession then unregisterSession() end
  unregisterSession=checkpointSessions.register(HOLD_OWNER,{canSuspend=M.canSuspendCareer,isReturning=M.isReturningToCareer})
end
local function cancelBeforeDeparture(message)
  if busy() and not job.departed then
    job.cancelled=true
    finishFailure(message,true)
    return true
  end
  return false
end
function M.onExtensionLoaded()
  registerSession()
  blockInput(false)
  require('overhaul/lib/save/store').releaseHolds(HOLD_OWNER)
  local latest,latestFile,sawJournal,highestSequence
  local function sequence(value) return type(value)=='number' and value>=0 and value<1e12 and value%1==0 end
  local function valid(state)
    if type(state)~='table' or state.version~=1 or not sequence(state.sequence) then return false end
    local data=state.job
    return type(data)=='table' and type(data.id)=='string' and data.id:match('^%d+_%d+$') and #data.id<64
      and type(data.profile)=='string' and data.profile~='' and data.checkpointName=='export_'..data.id
      and type(data.phase)=='string' and (TERMINAL[data.phase] or messages[data.phase] or data.phase=='depart' or data.phase=='stoppingThumbnail')
      and type(data.payload)=='table' and payloadRules.model(data.payload.model) and type(data.spawned)=='table' and type(data.request)=='table'
  end
  for _,file in ipairs({'current_a.json','current_b.json'}) do
    local ok,state=pcall(jsonReadFile,JOURNAL..file)
    sawJournal=sawJournal or state~=nil or not ok or FS:fileExists(JOURNAL..file)
    if ok and type(state)=='table' and sequence(state.sequence) then highestSequence=math.max(highestSequence or 0,state.sequence) end
    if ok and valid(state) and (not latest or state.sequence>latest.sequence) then latest,latestFile=state,file end
  end
  if latest then
    job,journalSequence,checkpointCleanup=latest.job,highestSequence or latest.sequence,type(latest.checkpointCleanup)=='table' and latest.checkpointCleanup or {}
    local recovered,recoveryError=recoverArchive()
    if not recovered then recoveryStorageError=recoveryError end
    cancelBeforeDeparture('Export interrupted\nThe game never left the garage. Nothing changed.')
    if busy() then
      job.phase='recovery';job.message=messages.recovery
      if job.careerRestored then job.phase='failed';job.message='The export was interrupted, but you are back in your career. Press Try again to export.'
      elseif not job.departed then job.careerRestored=true;job.phase='cancelled';job.message='Export interrupted\nThe game never left the garage. Nothing changed.' end
      job.error=job.error or (job.phase=='recovery' and 'The export was interrupted.' or job.message)
      if TERMINAL[job.phase] then job.result={ok=false,message=job.message,careerRestored=job.careerRestored==true,code=job.phase=='cancelled' and 'cancelled' or nil} end
      job.revision=(job.revision or 0)+1
      -- Preserve the surviving copy even if the rejected file's sequence was corrupt.
      local nextFile=(journalSequence+1)%2==0 and 'current_a.json' or 'current_b.json'
      if nextFile==latestFile then journalSequence=journalSequence+1 end
      local ok,err=pcall(journal)
      if not ok then log('E','vehicleExport','Recovered in memory; recovery storage needs repair: '..tostring(err)) end
    end
    if job and TERMINAL[job.phase] then retireCheckpoint() end
  elseif sawJournal then
    recoveryStorageError='The safety records of an earlier export could not be read, so exports are paused. Your career save is untouched. Ask the mod\'s support for help and mention this message.'
  end
  if job and job.phase=='recovery' then releaseRecoveryControls() end
  publish()
end
function M.onExtensionUnloaded()
  cancelBeforeDeparture('Export cancelled\nThe game never left the garage. Nothing changed.')
  if unregisterSession then unregisterSession();unregisterSession=nil end
  releaseHold();require('overhaul/lib/save/store').releaseHolds(HOLD_OWNER);blockInput(false)
  local ok,err=pcall(function()
    local capture=require('overhaul/lib/vehicles/exportThumbnail')
    if capture.cancel then capture.cancel() end
    capture.restore()
  end)
  if not ok then log('E','vehicleExport','Thumbnail cleanup needs recovery: '..tostring(err)) end
end
function M.onSerialize() return {job=copy(job),sequence=journalSequence,checkpointCleanup=copy(checkpointCleanup)} end
function M.onDeserialized(data)
  job,journalSequence,checkpointCleanup=data.job,data.sequence or 0,data.checkpointCleanup or {}
  registerSession()
  local recovered,recoveryError=recoverArchive()
  if not recovered then recoveryStorageError=recoveryError end
  if not cancelBeforeDeparture('Export interrupted\nThe game never left the garage. Nothing changed.') and busy() then job.error=job.error or 'The export was interrupted.';phase('recovery') end
  if job and job.phase=='recovery' then releaseRecoveryControls() end
end
-- Native hooks and UI callbacks are entry points too. Filesystem failures must
-- return a usable error, without breaking the save hook or allowing departure.
for _,name in ipairs({'start','cancel','restoreCareer','continueCareer','onWorkerResult','onOverhaulSaveFinished','onOverhaulSaveFailed','onDeserialized'}) do
  local callback=M[name]
  M[name]=function(...)
    local previousJob=job
    local ok,result=xpcall(callback,debug.traceback,...)
    if ok then return result end
    handleError(result)
    local response={ok=false,message=playerMessage(result,'Something went wrong during the export.'),status=M.getStatus(),careerRestored=job and job.careerRestored==true}
    if name=='start' and (job==previousJob or not busy()) then response.started=false end
    return response
  end
end
return M
