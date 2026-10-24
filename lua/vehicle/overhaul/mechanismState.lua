-- Actuator controls own mechanism pose; loaded node geometry belongs only to damage snapshots.
-- Map: data capture and beam identity, target restoration, bounded motion and completion.
local M = {}
local TIMEOUT_SECONDS = 20
local LENGTH_TOLERANCE = 0.002
local MOTION_TOLERANCE = 0.00005
local SETTLE_SECONDS = 0.1
local APPROACH_RATE = 10
local HYDRO_TOLERANCE = 0.001
local FALLBACK_SPEED = 0.1

local function copy(value, seen)
  if type(value) ~= 'table' then return type(value) ~= 'function' and value or nil end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child, seen) end
  seen[value] = nil
  return result
end

function M.new(context)
  local owner, pending, result, remembered = {}, nil, {complete=true}, {}

  local function observeControls()
    for cid, saved in pairs(remembered) do
      local device = saved.device
      local input = device.directionElectricsName
      if (input and (context.electrics()[input] or 0) ~= 0)
        or device.targetPosition ~= saved.command
        or (device.valveMode == 'position' and saved.mode ~= 'position') then remembered[cid] = nil end
    end
  end

  local function remember(cid, device, length)
    if device and device.stateDataNameTargetPosition then
      remembered[cid] = {device=device,length=length,command=device.targetPosition,mode=device.valveMode}
    end
  end

  local function devices()
    local roots, byBeam, visited = context.devices(), {}, {}
    local function visit(device, root)
      if type(device) ~= 'table' or visited[device] then return end
      visited[device] = true
      for _, list in ipairs({device.beamCids or {}, device.actuatorBeams or {}}) do
        for _, cid in pairs(list) do byBeam[cid] = {device=device, root=root} end
      end
      for _, consumer in pairs(device.connectedConsumers or {}) do visit(consumer, root) end
    end
    for _, device in pairs(roots) do visit(device, device) end
    return roots, byBeam
  end

  local function findBeam(cid, saved)
    local data = context.vehicle().data
    local function matches(beam)
      if not beam or (saved.partPath and saved.partPath ~= beam.partPath) then return false end
      local ids = saved.idents
      if not ids then return true end
      local first, second = data.nodes[beam.id1], data.nodes[beam.id2]
      local function same(node, index, savedId)
        return type(savedId) == 'number' and index == savedId or (node and node.name == savedId)
      end
      return (same(first,beam.id1,ids[1]) and same(second,beam.id2,ids[2]))
        or (same(first,beam.id1,ids[2]) and same(second,beam.id2,ids[1]))
    end
    if matches(data.beams[tonumber(cid)]) then return tonumber(cid) end
    for _, beam in pairs(data.beams) do if matches(beam) then return beam.cid end end
  end

  function owner.capture()
    if pending and pending.pose then return copy(pending.pose) end
    observeControls()
    local data, object = context.vehicle().data, context.object()
    local pose = {format='rls_pose_v2', model=data.model, targets={}, devices={}, controllers={}, hydros={}, inputs={}}
    local roots, byBeam = devices()
    for cid in pairs(context.drivenIds) do
      local beam = data.beams[cid]
      if beam and not object:beamIsBroken(cid) then
        local first, second = data.nodes[beam.id1], data.nodes[beam.id2]
        local device = byBeam[cid] and byBeam[cid].device
        local saved = remembered[cid]
        -- A closed valve can sag under load without changing the player's requested pose.
        local length = saved and saved.device == device and saved.length or object:getBeamRestLength(cid)
        if not saved and device and device.valveMode == 'position' and device.targetPosition then
          length = device.minExtend+device.targetPosition*(device.maxExtend-device.minExtend)
        end
        pose.targets[cid] = {length=length, partPath=beam.partPath,
          idents={first and first.name or beam.id1, second and second.name or beam.id2}}
        remember(cid, device, length)
      end
    end
    for _, root in pairs(roots) do
      if root.name and root.getState and root.setState then
        local owned = false
        for cid, binding in pairs(byBeam) do if binding.root == root and pose.targets[cid] then owned = true end end
        if owned then pose.devices[root.name] = copy(root:getState()) end
      end
    end
    for cid, binding in pairs(byBeam) do
      local input = binding.device.directionElectricsName
      if input and pose.targets[cid] then pose.inputs[input] = context.electrics()[input] or 0 end
      local key = binding.device.stateDataNameTargetPosition
      local state = pose.devices[binding.root.name]
      if key and state and pose.targets[cid] then
        local device = binding.device
        state[key] = (pose.targets[cid].length-device.minExtend)/(device.maxExtend-device.minExtend)
      end
    end
    for _, control in pairs(context.controllers()) do
      if control.name and control.getState and control.setState then
        local state = copy(control.getState())
        -- Suspension's currentPosition setter writes length in one step; restore only its target.
        for key, value in pairs(copy(state)) do
          if type(key) == 'string' and key:sub(-16) == '_currentPosition' then
            state[key:sub(1,-17)..'_targetPosition'] = value
            state[key] = nil
          end
        end
        pose.controllers[control.name] = state
      end
    end
    for _, hydro in pairs(context.hydros()) do
      local cid = hydro.center ~= 0 and (hydro.beamCID or hydro.cid)
      if cid and context.initialHydros[cid] and math.abs(hydro.state-context.initialHydros[cid]) > 0.0001 then
        local beam = data.beams[cid]
        if beam then
          pose.hydros[cid] = {state=hydro.state, partPath=beam.partPath}
        end
      end
    end
    if not next(pose.targets) and not next(pose.hydros) and not next(pose.controllers) then return nil end
    pose.latches = context.captureLatches()
    return pose
  end

  local function legacyTargets(pose)
    local targets, hydroTargets = {}, {}
    local nodeNames = {}
    for _, part in pairs(pose.partStates or {}) do
      for cid, node in pairs(part.nodes or {}) do nodeNames[tonumber(cid)] = node.name end
    end
    for _, part in pairs(pose.partStates or {}) do
      for cid, beam in pairs(part.beams or {}) do
        local id = tonumber(cid)
        if context.actuatorIds[id] then
          local ids = beam.idents
          targets[id] = {length=beam.length, idents=ids and {nodeNames[ids[1]] or ids[1],nodeNames[ids[2]] or ids[2]}}
        end
      end
      for cid, hydro in pairs(part.hydros or {}) do hydroTargets[tonumber(cid)] = {state=hydro.state} end
    end
    return targets, hydroTargets
  end

  local function warnFailure(reason)
    if not context.warn then return end
    local object, actuators = context.object(), {}
    for cid, target in pairs(pending.targets) do
      local device = target.binding and target.binding.device
      local current = object.getBeamLength and object:getBeamLength(cid) or object:getBeamRestLength(cid)
      actuators[#actuators+1] = string.format('%s beam %s target=%.5f m actual=%.5f m error=%.3f mm',
        device and (device.name or device.stateDataNameTargetPosition) or 'actuator',tostring(cid),
        target.length,current,math.abs(current-target.length)*1000)
    end
    for _, entry in ipairs(pending.hydros) do
      actuators[#actuators+1] = string.format('hydro %s target=%.5f actual=%.5f',
        tostring(entry.hydro.beamCID or entry.hydro.cid),entry.target,entry.hydro.state)
    end
    table.sort(actuators)
    context.warn(string.format('mechanismFailed: vehicle %s (id %s), %s after %.2f s; %s',
      tostring(context.vehicle().data.model),tostring(object.getID and object:getID() or 'unknown'),
      reason or 'restore failed',pending.elapsed,table.concat(actuators,'; ')))
  end

  local function finish(failed, reason)
    if pending then
      if failed then warnFailure(reason) end
      for device, control in pairs(pending.cylinders) do
        device.valveMode = 'direct'
        control.close()
        device.updateGFX, device.maxSpeed = control.updateGFX, control.maxSpeed
      end
      if not failed then
        for cid, target in pairs(pending.targets) do
          remember(cid, target.binding and target.binding.device, target.length)
        end
      end
      for _, pump in ipairs(pending.pumps) do pump.device:setState(pump.state) end
      for input, value in pairs(pending.inputs) do context.electrics()[input] = value end
    end
    result = {complete=true, failed=failed == true}
    pending = nil
  end

  local function actuatorReady(target, current, dt)
    local motion = target.motion
    motion.low, motion.high = math.min(motion.low,current), math.max(motion.high,current)
    motion.elapsed = motion.elapsed+dt
    if motion.high-motion.low >= MOTION_TOLERANCE then
      motion.low, motion.high, motion.elapsed = current, current, 0
    end
    if math.abs(current-target.length) <= LENGTH_TOLERANCE then return true end
    local device = target.binding and target.binding.device
    if not device or not device.stateDataNameTargetPosition then return false end
    -- A saved loaded length can lie beyond a stop. A stationary actuator far from its command is still a failure.
    local command = math.max(device.minExtend,math.min(device.maxExtend,target.length))
    local atStop = command == device.minExtend or command == device.maxExtend
    return atStop and math.abs(current-command) <= LENGTH_TOLERANCE and motion.elapsed >= SETTLE_SECONDS
  end

  local function driveCylinder(device)
    if pending.cylinders[device] or not device.updateGFX or not device.positionModeTargetPositionPID then return end
    local control = {updateGFX=device.updateGFX,maxSpeed=device.maxSpeed}
    local function valve(dt, closing)
      local values, input = context.electrics(), device.directionElectricsName
      local previous = values[input]
      local error = (device.targetPosition-device.currentExtendPercent)*(device.maxExtend-device.minExtend)
      local command = 0
      if not closing and math.abs(error) > LENGTH_TOLERANCE then
        command = device.positionModeTargetPositionPID:get(device.currentExtendPercent,device.targetPosition,dt)
      else device.positionModeTargetPositionPID:reset() end
      -- Use stock valve shaping and stage areas, bypassing only its stroke-sized stopping deadband.
      device.valveMode = 'direct'
      values[input] = command/(device.direction or 1)
      control.updateGFX(device,dt)
      values[input] = previous
    end
    control.close = function() valve(0,true) end
    device.updateGFX = function(_,dt) valve(dt,false) end
    pending.cylinders[device] = control
  end

  function owner.restore(pose, skipLatches)
    finish(false)
    if type(pose) ~= 'table' or pose.model ~= context.vehicle().data.model then return false end
    if pose.format ~= 'rls_pose_v1' and pose.format ~= 'rls_pose_v2' then return false end
    local targets, hydroTargets = pose.targets or {}, pose.hydros or {}
    if pose.format == 'rls_pose_v1' then targets, hydroTargets = legacyTargets(pose) end
    local roots, byBeam = devices()
    remembered = {}
    pending = {targets={}, hydros={}, pumps={}, cylinders={}, inputs={}, elapsed=0,settled=0,
      pose={format='rls_pose_v2',model=pose.model,targets={},devices={},controllers=copy(pose.controllers or {}),
        hydros=copy(hydroTargets),inputs={},latches=copy(pose.latches)}}
    for cid, target in pairs(targets) do
      local id = findBeam(cid, target)
      if id and context.actuatorIds[id] and not context.object():beamIsBroken(id) then
        local object = context.object()
        local current = object.getBeamLength and object:getBeamLength(id) or object:getBeamRestLength(id)
        pending.targets[id] = {length=target.length, binding=byBeam[id],motion={low=current,high=current,elapsed=0}}
        pending.pose.targets[id] = copy(target)
      end
    end
    for _, root in pairs(roots) do
      local state = pose.devices and pose.devices[root.name]
      if root.getState and root.setState then
        state = copy(state or root:getState())
        local owned = false
        for _, target in pairs(pending.targets) do
          local binding = target.binding
          if binding and binding.root == root and binding.device.stateDataNameTargetPosition then
            local cylinder = binding.device
            local range = cylinder.maxExtend-cylinder.minExtend
            state[cylinder.stateDataNameTargetPosition] = math.max(0,math.min(1,(target.length-cylinder.minExtend)/range))
            local input = cylinder.directionElectricsName
            if input then
              if pending.inputs[input] == nil then
                -- A saved button press is history, not a new request to move after arrival.
                pending.inputs[input] = context.electrics()[input] or 0
              end
              context.electrics()[input] = 0
            end
            owned = true
          end
        end
        if owned then
          pending.pose.devices[root.name] = copy(state)
          root:setState(state)
          for _, target in pairs(pending.targets) do
            if target.binding and target.binding.root == root then driveCylinder(target.binding.device) end
          end
          local oilKey = root.stateDataNameAccumulatorOilVolume
          if oilKey then pending.pumps[#pending.pumps+1] = {device=root,state={[oilKey]=state[oilKey]}} end
        end
      end
    end
    pending.pose.inputs = copy(pending.inputs)
    for _, control in pairs(context.controllers()) do
      local state = pose.controllers and pose.controllers[control.name]
      if state and control.setState then control.setState(copy(state)) end
    end
    for cid, saved in pairs(hydroTargets) do
      for _, hydro in pairs(context.hydros()) do
        local id = hydro.center ~= 0 and (hydro.beamCID or hydro.cid)
        if id == tonumber(cid) and not context.object():beamIsBroken(id) then
          pending.hydros[#pending.hydros+1] = {hydro=hydro,target=saved.state}
          if hydro.inputSource and hydro.multIn and hydro.multOut then
            local mult = saved.state >= hydro.center and hydro.multOut or hydro.multIn
            context.electrics()[hydro.inputSource] = (hydro.inputCenter+(saved.state-hydro.center)/mult)/(hydro.inputFactor or 1)
          end
        end
      end
    end
    if not skipLatches then context.restoreLatches(pose.latches) end
    result = {complete=false,failed=false}
    if not next(pending.targets) and #pending.hydros == 0 and not next(pose.controllers or {}) then finish(false) end
    return true
  end

  function owner.update(dt)
    if not pending then observeControls(); return end
    if dt <= 0 then return end
    pending.elapsed = pending.elapsed + dt
    local object, complete = context.object(), true
    for _, pump in ipairs(pending.pumps) do
      -- A parked engine supplies no flow. Prime only the pose operation, then return the saved accumulator state.
      if not pump.device.isBroken then
        pump.device.accumulatorOilVolume = math.max(pump.device.accumulatorOilVolume, pump.device.accumulatorMaxVolume)
      end
    end
    for cid, target in pairs(pending.targets) do
      local binding = target.binding
      local nativeCylinder = binding and binding.device.stateDataNameTargetPosition
      if object:beamIsBroken(cid) then finish(true,'broken actuator'); return end
      local current = object.getBeamLength and object:getBeamLength(cid) or object:getBeamRestLength(cid)
      local error = math.abs(current-target.length)
      local control = nativeCylinder and pending.cylinders[binding.device]
      if control and control.maxSpeed then
        -- Slow the final approach at physics rate so a graphics frame cannot overshoot the target.
        binding.device.maxSpeed = math.min(control.maxSpeed,error*APPROACH_RATE)
      end
      if not actuatorReady(target,current,dt) then
        complete = false
        if not nativeCylinder and not context.controllerIds[cid] then
          local rest = object:getBeamRestLength(cid)
          local step = FALLBACK_SPEED*dt
          object:setBeamLength(cid, rest+math.max(-step,math.min(step,target.length-rest)))
        end
      end
    end
    for _, entry in ipairs(pending.hydros) do
      local hydro = entry.hydro
      if math.abs(hydro.state-entry.target) > HYDRO_TOLERANCE then
        complete = false
        -- Controller inputs can change between frames; apply the hydro target at its own rate until reached.
        local step = (hydro.inRate or FALLBACK_SPEED)*dt
        hydro.state = hydro.state+math.max(-step,math.min(step,entry.target-hydro.state))
        hydro.cmd = entry.target
        if hydro.fsetRelDisplacement then hydro.fsetRelDisplacement(object,hydro.bcid,hydro.state) end
      end
    end
    pending.settled = complete and pending.settled+dt or 0
    if pending.settled >= SETTLE_SECONDS or pending.elapsed >= TIMEOUT_SECONDS then
      finish(pending.settled < SETTLE_SECONDS,'timeout')
    end
  end

  function owner.state() return copy(result) end
  function owner.cancel() finish(false); remembered = {} end
  return owner
end

return M
