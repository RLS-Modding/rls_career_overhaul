-- Export worker: native static data, bounded driving measurements and return snapshots.
-- Test tuning and track positions: gameplay/overhaul/vehicles/configExport.json.
-- Copyright (C) RLS Modding; SPDX-License-Identifier: AGPL-3.0-only
local M = {}
local request, measurements, testIssues, workerCoroutine, workerError
local timer=0
local tuning
local function settings()
  if not tuning then tuning=assert(jsonReadFile('/gameplay/overhaul/vehicles/configExport.json')).worker end
  return tuning
end
local function sendResult(ok,message,extra)
  if not request then return end
  local result={jobId=request.jobId,kind=request.kind,vehicleId=obj:getID(),ok=ok,message=message,measurements=measurements or {},testIssues=testIssues}
  if request.kind=='tests' then
    result.display={}
    for _,entry in ipairs(settings().displayMeasurements) do
      local value=measurements[entry.key]
      if type(value)=='number' and value>0 and value<math.huge then result.display[#result.display+1]={label=entry.label,value=string.format(entry.format,value*entry.factor)} end
    end
  end
  for key,value in pairs(extra or {}) do result[key]=value end
  result.round=request.round
  request=nil
  obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('configExportResult',serialize(result)))
end
local function wait(seconds)
  local deadline=timer+seconds
  repeat coroutine.yield() until timer>deadline
end
local function speed()
  local value=electrics.values.airspeed
  if type(value)=='number' and value==value and math.abs(value)<math.huge then return math.max(0,value) end
end
local function hasPower()
  for _,engine in pairs(powertrain.getDevicesByCategory('engine') or {}) do
    local data=engine:getTorqueData()
    if data and (data.maxPower or 0)>0 then return true end
  end
  return false
end
local function stopControllers()
  if perfectLaunch and perfectLaunch.stop then perfectLaunch.stop() end
  if cruiseControl and cruiseControl.setEnabled then cruiseControl.setEnabled(false) end
  if straightLine and straightLine.stop then straightLine.stop() end
  input.event('throttle',0,1);input.event('brake',0,1);input.event('parkingbrake',1,1)
end
local function cannotDriveReason()
  return wheels.wheelCount<=0 and 'The vehicle has no working wheels to test.' or 'The vehicle has no engine power to test.'
end
local function canDrive(stage)
  if wheels.wheelCount>0 and hasPower() then return true end
  testIssues[stage]=cannotDriveReason()
  if stage=='acceleration' then testIssues.topSpeed=testIssues[stage] end
  return false
end
local function accelerationUnavailable(reason)
  testIssues.acceleration=reason;testIssues.topSpeed=reason
  perfectLaunch.stop()
  return false
end
local function resetVehicle(position)
  local id=obj:getID()
  obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('configExportReset',tostring(id)..','..serialize(position)))
  wait(settings().resetWaitS)
end
local function configureDrive(range,target,surface)
  controller.mainController.setGearboxMode('arcade')
  local esc=controller.getController('esc')
  if esc then esc.pauseESCAction=true end
  for kind,mode in pairs({differential='locked',shaft='connected',rangeBox=range}) do
    for _,device in pairs(powertrain.getDevicesByType(kind) or {}) do if device.mode~=mode then device:setMode(mode) end end
  end
  extensions.load('straightLine')
  straightLine.onInit();straightLine.setTargetDirection(vec3(unpack(target)),surface)
end
local function staticMeasurements()
  measurements.Weight=math.ceil(obj:calcBeamStats().total_weight/settings().weightStepKg)*settings().weightStepKg
  extensions.load('vehiclePerformanceData')
  local native=vehiclePerformanceData.getStaticData()
  local layout=native.powertrainLayout
  if layout then
    local front,rear=(layout.poweredWheelsFront or 0)>0,(layout.poweredWheelsRear or 0)>0
    measurements.Drivetrain=front and rear and 'AWD' or front and 'FWD' or rear and 'RWD' or nil
  end
  for _,entry in ipairs({{native.transmissionStyle,settings().transmissions,'Transmission'},{native.fuelType,settings().fuels,'Fuel Type'}}) do
    local selected
    for key in pairs(entry[1] or {}) do
      local label=entry[2][key]
      if label then selected=selected and selected~=label and 'Other' or label end
    end
    measurements[entry[3]]=selected
  end
  local power,torque=0,0
  for _,engine in pairs(powertrain.getDevicesByCategory('engine') or {}) do
    local data=engine:getTorqueData()
    if data then power=power+(data.maxPower or 0);torque=torque+(data.maxTorque or 0) end
  end
  if power>0 then measurements.Power=power;measurements.Torque=torque;measurements['Weight/Power']=measurements.Weight/power end
end
local function accelerationTests()
  if not canDrive('acceleration') then return false end
  local limits=settings()
  resetVehicle(limits.roadPosition)
  configureDrive('high',limits.roadTarget,'road')
  extensions.load('perfectLaunch');perfectLaunch.onInit();perfectLaunch.prepare(vec3(unpack(limits.roadTarget)))
  wait(limits.launchWaitS);perfectLaunch.go()
  local startedAt=timer
  while true do
    local currentSpeed=speed()
    if not currentSpeed then return accelerationUnavailable('The vehicle did not report its speed.') end
    if perfectLaunch.launchFailed then return accelerationUnavailable('The launch failed before a result could be measured.') end
    if currentSpeed>=limits.minStartSpeedMps then break end
    coroutine.yield()
    if timer-startedAt>limits.launchTimeoutS then
      return accelerationUnavailable('The vehicle could not accelerate from a standstill.')
    end
  end
  startedAt=timer
  local maximumSpeed,progressAt,sixtyAt,hundredAt=0,timer
  local verifiedTopSpeed=false
  repeat
    coroutine.yield()
    local currentSpeed=speed()
    local elapsedS=timer-startedAt
    if not currentSpeed then return accelerationUnavailable('The vehicle did not report its speed.') end
    if elapsedS>limits.stallTimeoutS and currentSpeed<=limits.stallSpeedMps then
      return accelerationUnavailable('The vehicle stalled or could not accelerate. Check its tune, fuel and drivetrain.')
    end
    if perfectLaunch.launchFailed then
      testIssues.topSpeed='The run ended before top speed was reached.'
      break
    end
    for _,target in ipairs(limits.accelerationTargets) do
      if currentSpeed>=target.speedMps and not measurements[target.key] then measurements[target.key]=math.floor(elapsedS*10)/10 end
    end
    sixtyAt=sixtyAt or measurements['0-60 mph'];hundredAt=hundredAt or measurements['0-100 km/h']
    if sixtyAt and measurements['0-100 mph'] then measurements['60-100 mph']=measurements['0-100 mph']-sixtyAt end
    if hundredAt and measurements['0-200 km/h'] then measurements['100-200 km/h']=measurements['0-200 km/h']-hundredAt end
    if currentSpeed>maximumSpeed+limits.topSpeedDeltaMps then maximumSpeed,progressAt=currentSpeed,timer end
    -- A plateau verifies top speed only while the launch sustains full throttle.
    if input.throttle<limits.minVerificationThrottle then progressAt=timer end
    if elapsedS<limits.accelerationTimeoutS and currentSpeed>limits.stallSpeedMps and timer-progressAt>limits.topSpeedSettleS then
      verifiedTopSpeed=true
      break
    end
  until timer-startedAt>=limits.accelerationTimeoutS
  perfectLaunch.stop()
  if verifiedTopSpeed then measurements['Top Speed']=maximumSpeed end
  if not sixtyAt then testIssues.acceleration='The vehicle did not reach 60 mph.' end
  if timer-startedAt>=limits.accelerationTimeoutS then testIssues.topSpeed='The test reached its time limit while the vehicle was still gaining speed.' end
  return maximumSpeed>=limits.brakingTargetSpeedMps
end
local function brakingTests()
  if not canDrive('braking') then return end
  local limits=settings()
  resetVehicle(limits.roadPosition);configureDrive('high',limits.roadTarget,'road')
  if wheels.setABSBehavior then wheels.setABSBehavior('arcade') end
  extensions.load('cruiseControl');cruiseControl.setSpeed(limits.brakingTargetSpeedMps)
  local deadline=timer+limits.brakingTimeoutS
  local startedAt,progressAt,maximumSpeed=timer,timer,0
  while true do
    local currentSpeed=speed()
    if not currentSpeed then testIssues.braking='The vehicle did not report its speed.';return end
    if currentSpeed>=limits.brakingTargetSpeedMps then break end
    if timer-startedAt>limits.stallTimeoutS and currentSpeed<=limits.stallSpeedMps then
      testIssues.braking='The vehicle could not reach the speed needed for the braking test.';return
    end
    if currentSpeed-maximumSpeed>=limits.topSpeedDeltaMps then maximumSpeed,progressAt=currentSpeed,timer end
    if timer-progressAt>limits.brakingProgressTimeoutS then testIssues.braking='The vehicle could not reach the speed needed for the braking test.';return end
    coroutine.yield()
    if timer>deadline then testIssues.braking='The vehicle could not reach the speed needed for the braking test.';return end
  end
  cruiseControl.setEnabled(false);input.event('throttle',0,1);input.event('brake',1,1)
  local starts={}
  deadline=timer+limits.brakeStopTimeoutS
  while true do
    local currentSpeed=speed()
    if not currentSpeed then testIssues.braking='The vehicle did not report its speed.';return end
    if currentSpeed<=limits.stopSpeedMps then break end
    for _,target in ipairs(limits.brakingTargets) do
      if currentSpeed<=target.speedMps and not starts[target.key] then starts[target.key]=obj:getPosition() end
    end
    coroutine.yield()
    if timer>deadline then testIssues.braking='The vehicle did not stop within the braking time limit.';return end
  end
  local finish=obj:getPosition()
  for _,target in ipairs(limits.brakingTargets) do
    if starts[target.key] then
      local distanceM=(finish-starts[target.key]):length()
      if distanceM>0 then measurements[target.key]=distanceM*target.unitsPerM end
    end
  end
  local distanceM=measurements['100-0 km/h']
  if distanceM and distanceM>0 then measurements['Braking G']=limits.brakingTargets[1].speedMps^2/(2*distanceM*math.max(limits.minGravityMps2,math.abs(obj:getGravity()))) end
  input.event('brake',0,1)
end
local function offroadTests()
  if not canDrive('offroad') then return end
  local limits=settings()
  resetVehicle(limits.offroadPosition);configureDrive('low',limits.offroadTarget,'offroad')
  extensions.load('cruiseControl');cruiseControl.minimumSpeed=limits.offroadSpeedMps;cruiseControl.setSpeed(limits.offroadSpeedMps)
  local start=obj:getPosition()
  wait(limits.settleWaitS)
  local initialBroken=obj:calcBeamStats().beams_broken
  local distanceM,maximumDistanceM,breakDistanceM=0,0,nil
  local startedAt,progressAt=timer,timer
  repeat
    coroutine.yield()
    distanceM=(obj:getPosition()-start):length()
    if not breakDistanceM and obj:calcBeamStats().beams_broken>initialBroken then breakDistanceM=distanceM end
    if distanceM-maximumDistanceM>=limits.minProgressM then maximumDistanceM,progressAt=distanceM,timer end
    if timer-progressAt>limits.progressTimeoutS then break end
  until distanceM>=limits.offroadDistanceM or timer-startedAt>limits.offroadTimeoutS
  cruiseControl.setEnabled(false);straightLine.stop()
  if distanceM<limits.minOffroadDistanceM then testIssues.offroad='The vehicle could not finish the off-road course.';return end
  measurements['Off-Road Score']=math.ceil((3*distanceM+(breakDistanceM or distanceM))/limits.offroadDistanceM/4*100)
end
local function performTests()
  workerCoroutine=coroutine.create(function()
    staticMeasurements()
    if not hasPower() or wheels.wheelCount<=0 then
      for _,key in ipairs({'acceleration','topSpeed','braking','offroad'}) do testIssues[key]=cannotDriveReason() end
      return
    end
    local canBrake=false
    local stages={offroad=offroadTests,acceleration=function()canBrake=accelerationTests() end,
      braking=function()
        if canBrake then brakingTests() else testIssues.braking='The vehicle could not reach the speed needed for the braking test.' end
      end}
    for _,stage in ipairs(settings().stages) do assert(stages[stage],'Unknown export test stage')() end
  end)
end
function M.start(value)
  if request or type(value)~='table' or type(value.jobId)~='string' then return false end
  request=value;measurements={};testIssues={};workerError=nil;timer=0
  if value.kind=='preflight' then
    local ok,state=pcall(function()staticMeasurements();return require('vehicle/overhaul/exportState').capture() end)
    sendResult(ok,not ok and tostring(state) or nil,{returnState=ok and state or nil})
  elseif value.kind=='couplings' then
    local ran,ok,message,ready=pcall(function()return require('vehicle/overhaul/exportCouplings').restore(value.edges,value.attach) end)
    if not ran then message=tostring(ok);ok=false end
    sendResult(ok,message,{couplingsReady=ran and ready==true})
  elseif value.kind=='restore' then
    local ran,matched,differences=pcall(function()return require('vehicle/overhaul/exportState').restore(value.state)end)
    if not ran then differences={tostring(matched)};matched=false end
    sendResult(true,nil,{returnStateMatched=matched==true,restoreWarnings=differences})
  elseif value.kind=='tests' then performTests()
  else sendResult(false,'The export could not run on this vehicle.') end
  return true
end
function M.updateGFX(dt)
  timer=timer+dt
  if not workerCoroutine then return end
  local ok,err=coroutine.resume(workerCoroutine)
  if not ok then workerError=tostring(err) end
  if not ok or coroutine.status(workerCoroutine)=='dead' then
    workerCoroutine=nil;stopControllers();sendResult(not workerError,workerError)
  end
end
function M.onExtensionUnloaded() if request then stopControllers();request=nil;workerCoroutine=nil end end
return M
