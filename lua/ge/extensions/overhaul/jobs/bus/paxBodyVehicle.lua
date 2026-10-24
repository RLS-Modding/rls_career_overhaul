-- Pooled unicycle walker bodies driven by the stock player controller.
-- Read private RNG isolation, steering, pool ownership, movement, visibility and teardown.
return function(config, upDirection, token)
  local OWNER_FIELD = 'ovhBusPaxOwner'
  local vehicleTuning = config.vehicle or {}
  local bodyBackend = {name = 'vehicle', doorGapM = vehicleTuning.doorGapM or 0.45}
  local CMD = "local c = controller.getControllerSafe('playerController') if c then"
    .. " c.setCameraControlData({cameraRotation = quat(%.5f, %.5f, %.5f, %.5f)})"
    .. " c.walkLeftRightRaw(0) c.walkUpDownRaw(%.4f) c.setSpeedCoef(%.4f) end"

  local function vehicle(id) return id and be:getObjectByID(id) or nil end

  -- Walker spawning uses a private RNG stream because stock camera hooks draw random values.
  local seed = 1234567
  local function privateRandom(m, n)
    seed = seed * 16807 % 2147483647
    local x = (seed - 1) / 2147483646
    if m == nil then return x end
    if n == nil then m, n = 1, m end
    return math.floor(m + x * (n - m + 1))
  end

  local function isolated(fn, ...)
    local lib = math
    local shared = lib.random
    if shared == privateRandom then return fn(...) end -- already inside an isolated call
    lib.random = privateRandom
    local results = {pcall(fn, ...)}
    lib.random = shared
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, table.maxn(results))
  end
  bodyBackend.isolated = isolated

  local function dirFromYaw(yaw) return vec3(-math.sin(yaw), -math.cos(yaw), 0) end -- the inverse of paxWalkers' yawOf

  -- One input change for the unicycle's playerController: face `dir`, move at `speed` m/s.
  local function command(bodyHandle, dir, speed)
    local veh = vehicle(bodyHandle.vehId)
    if not veh then return end
    local walkSpeed, sprintSpeed = vehicleTuning.walkSpeed or 1.8, vehicleTuning.sprintSpeed or 5.0
    local walk, coef = 0, 0
    if speed > 0.01 then
      if speed <= walkSpeed then walk = speed / walkSpeed
      else walk, coef = 1, math.min(1, (speed - walkSpeed) / math.max(sprintSpeed - walkSpeed, 0.01)) end
    end
    local rotation = quatFromDir(dir, upDirection) -- the controller walks along its camera's +Y
    veh:queueLuaCommand(string.format(CMD, rotation.x, rotation.y, rotation.z, rotation.w, walk, coef))
    bodyHandle.cmdDir, bodyHandle.cmdSpeed, bodyHandle.steerT = dir, speed, 0
  end


  -- Remove other owners from the walking blacklist before deleting their pooled vehicles.
  function bodyBackend.sweep()
    local doomed = {}
    for i = 0, (be.getObjectCount and be:getObjectCount() or 0) - 1 do
      local veh = be:getObject(i)
      local owner = veh and veh.getDynDataFieldbyName and veh:getDynDataFieldbyName(OWNER_FIELD, 0)
      if owner and owner ~= '' and owner ~= token then doomed[#doomed + 1] = {vehId = veh:getID()} end
    end
    bodyBackend.destroy(doomed)
  end

  local function faceSkin(rng)
    local faces = vehicleTuning.faceSkins or {}
    if #faces == 0 or not rng then return nil end
    return faces[rng.int(1, #faces)]
  end

  -- Ghost walkers collide with ground while leaving vehicles and players undisturbed.
  local GHOST = 'obj:setGhostEnabled(true)'

  local function create(count, anchor, rng, pool)
    local base = anchor and vec3(anchor) or vec3(0, 0, 0)
    for i = 1, count do
      local config = {model = 'unicycle', format = 2, parts = {unicycle_meshes = vehicleTuning.meshPart or 'unicycle_character',
        skin_character_face = faceSkin(rng)}}
      local pos = base + vec3((i - 1) * (vehicleTuning.spawnSpacingM or 1.5), 0, vehicleTuning.spawnLiftM or 0.3)
      local veh = core_vehicles.spawnNewVehicle('unicycle', {config = config, pos = pos,
        rot = quat(0, 0, 0, 1), autoEnterVehicle = false, removeTraffic = false, canSpawnAnotherVehicleCheck = false,
        vehicleName = Sim.getUniqueName('ovhBusPaxWalker'), licenseText = ' '})
      if not veh then break end
      local id = veh:getID()
      pool[i] = {vehId = id, active = true} -- recorded the moment it exists
      veh.playerUsable = false
      veh.canSave = false
      veh:setDynDataFieldbyName(OWNER_FIELD, 0, token)
      if gameplay_walk and gameplay_walk.addVehicleToBlacklist then gameplay_walk.addVehicleToBlacklist(id) end
      veh:queueLuaCommand(GHOST)
      veh:setActive(0)
      pool[i].active = false
    end
  end

  -- A failure part-way deletes what was made (and its blacklist entries) and rethrows.
  function bodyBackend.create(count, anchor, rng)
    local pool = {}
    local ok, err = pcall(isolated, create, count, anchor, rng, pool)
    if not ok then
      bodyBackend.destroy(pool)
      error(err, 0)
    end
    if #pool == 0 then return nil end
    return pool
  end

  function bodyBackend.alive(pool)
    if not pool or #pool == 0 then return false end
    for _, bodyHandle in ipairs(pool) do if not vehicle(bodyHandle.vehId) then return false end end
    return true
  end

  function bodyBackend.poolId(pool) return pool and pool[1] and pool[1].vehId end

  local function activate(bodyHandle, veh)
    if bodyHandle.active then return end
    isolated(veh.setActive, veh, 1)
    bodyHandle.active = true
  end

  -- Standing at pos facing yaw: placed there upright (initial node layout) and told to stand still.
  function bodyBackend.place(bodyHandle, pos, yaw)
    local veh = vehicle(bodyHandle.vehId)
    if not veh then return end
    activate(bodyHandle, veh)
    local rotation = quatFromAxisAngle(upDirection, yaw)
    -- Avoid a vehicle reset because its later camera hook would escape RNG isolation.
    isolated(veh.setPositionRotation, veh, pos.x, pos.y, pos.z + (vehicleTuning.spawnLiftM or 0.3), rotation.x, rotation.y, rotation.z, rotation.w)
    veh:queueLuaCommand(GHOST) -- again after every placement, in case the vehicle was reset meanwhile
    bodyHandle.pos = pos
    command(bodyHandle, dirFromYaw(yaw), 0)
  end

  -- Only reissue steering when heading or speed changes enough to matter.
  function bodyBackend.move(bodyHandle, pos, yaw, roll, bob, dir, speed, dt)
    bodyHandle.pos = pos
    bodyHandle.steerT = (bodyHandle.steerT or 0) + (dt or 0)
    if bodyHandle.cmdSpeed and bodyHandle.cmdSpeed > 0 and bodyHandle.steerT < (vehicleTuning.steerIntervalS or 0.25) then return end
    bodyHandle.steerT = 0
    local veh = vehicle(bodyHandle.vehId)
    if not veh then return end
    local actual = vec3(veh:getPosition())
    local ahead = dir and (pos + dir * (vehicleTuning.lookAheadM or 0.8)) or pos
    local to = (ahead - actual):z0()
    local aim = to:length() > 0.05 and to:normalized() or dir or bodyHandle.cmdDir
    if not aim then return end
    local behind = dir and (pos - actual):z0():dot(dir) or 0
    local want = math.max(0, math.min(vehicleTuning.sprintSpeed or 5.0, speed + (vehicleTuning.catchUpGain or 1.0) * behind))
    local turned = not bodyHandle.cmdDir or bodyHandle.cmdDir:dot(aim) < math.cos(math.rad(vehicleTuning.headingDeg or 8))
    if turned or math.abs(want - (bodyHandle.cmdSpeed or -1)) > (vehicleTuning.speedStep or 0.1) then command(bodyHandle, aim, want) end
  end

  -- The end of the path: stand still facing yaw.
  function bodyBackend.arrive(bodyHandle, pos, yaw)
    bodyHandle.pos = pos
    command(bodyHandle, dirFromYaw(yaw), 0)
  end

  -- A reused walker gets fresh standing inputs before its last movement can resume.
  function bodyBackend.setHidden(bodyHandle, hidden)
    local veh = vehicle(bodyHandle.vehId)
    if not veh then return end
    if hidden then
      if bodyHandle.active then
        isolated(veh.setActive, veh, 0)
        bodyHandle.active = false
      end
    else
      activate(bodyHandle, veh)
    end
  end

  -- A colour per passenger, as stock walk.lua colours the player's walker.
  function bodyBackend.paint(bodyHandle, rng)
    local veh = vehicle(bodyHandle.vehId)
    if not veh or not rng then return end
    local r, g, b = rng.range(0.25, 0.95), rng.range(0.25, 0.95), rng.range(0.25, 0.95)
    if ColorF then
      local linear = ColorF(r, g, b, 1):asLinear4F()
      veh.color, veh.colorPalette0, veh.colorPalette1 = linear, linear, linear
    end
    if createVehiclePaint and veh.setMetallicPaintData then
      local paint = createVehiclePaint({x = r, y = g, z = b, w = 1})
      veh:setMetallicPaintData({paint, paint, paint})
    end
  end

  function bodyBackend.position(bodyHandle)
    local veh = vehicle(bodyHandle.vehId)
    return veh and vec3(veh:getPosition()) or bodyHandle.pos
  end

  function bodyBackend.ids(bodyHandle) return {bodyId = bodyHandle.vehId} end

  function bodyBackend.describe(pool)
    local ids = {}
    for i, bodyHandle in ipairs(pool or {}) do ids[i] = tostring(bodyHandle.vehId) end
    return 'unicycles ' .. table.concat(ids, ',')
  end

  -- Remove walking blacklist entries before deleting the owned walker vehicles.
  function bodyBackend.destroy(pool)
    for _, bodyHandle in pairs(pool or {}) do
      if type(bodyHandle) == 'table' and bodyHandle.vehId then
        if gameplay_walk and gameplay_walk.removeVehicleFromBlacklist then gameplay_walk.removeVehicleFromBlacklist(bodyHandle.vehId) end
        local veh = vehicle(bodyHandle.vehId)
        if veh then isolated(veh.delete, veh) end
      end
    end
  end

  return bodyBackend
end
