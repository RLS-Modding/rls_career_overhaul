-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/gameplay/police.lua (BeamNG 0.40).

-- Owns police pursuits, roadblocks and teleport/recovery speeding grace in Overhaul.
local M = {}
M.dependencies = {'gameplay_police', 'gameplay_traffic'}

local logTag = 'police'

-- Mode thresholds: stretch early escalation so soft follow lasts longer.
local defaultScoreLevels = {150, 900, 2800}
local loudspeakerByMode = {
  [1] = 'Police: Please pull over at the next safe opportunity.',
  [2] = 'Police: This is the police — reduce speed and stop now.',
  [3] = 'Police: Stop the car or we will stop it for you!',
}
-- Wanted 0..1 → AI aggression (chase still starts at mode 2; heat ramps with time/score).
local WANTED_AGGRESSION_MIN = 0.50
local WANTED_AGGRESSION_MAX = 1.05
-- Chase closing relative crash speed (m/s). Soft floor; mode caps keep early chase from maxing out.
local WANTED_CRASH_SPEED_MIN = 4
local WANTED_CRASH_SPEED_MODE2_MAX = 6
local WANTED_CRASH_SPEED_MODE3_MAX = 10
local policeVehs = {}
local policePropIds = {}
local vars
local suspectActive = false
local suspectTimer = math.huge
-- Fast travel / big-map teleport zeros physics velocity, but map.objects.vel
-- still reports the position jump for a frame or two. Instant speeding tickets
-- that off as 10+ mph over and starts a chase.
local SPEEDING_TELEPORT_IMMUNITY_SEC = 2.5
local SPEEDING_RECOVERY_IMMUNITY_SEC = 4
local defaultSpeedingGraceDuration = 2.5
local TELEPORT_JUMP_M = 80
local speedingImmuneRemaining = 0
local lastPlayerPos = vec3()
local hasLastPlayerPos = false
-- Walking players leave the pursuit attached to their previous car.
local walkHandoffVehId

local vecY = vec3(0, 1, 0)
local tempPos, tempFwd, tempFwd2, tempUp, tempRight = vec3(), vec3(), vec3(), vec3(), vec3()

-- common functions --
local min = math.min
local max = math.max
local random = math.random

M.enabled = true -- if false, runtime police logic won't run

local function applySuspectOverrideAI(vehId)
  if overhaul_shell_extensionManager and overhaul_shell_extensionManager.applyOverrideAI then
    overhaul_shell_extensionManager.applyOverrideAI(vehId)
  end
end

local function shrinkPoliceRespawnRadius(veh)
  if not veh or not veh.respawn then return end
  -- Undo pursuit keep-alive boosts so wrecked / cleared units can despawn.
  veh.respawn.activeRadius = math.min(veh.respawn.activeRadius or 160, 160)
  veh.respawn.innerRadius = math.min(veh.respawn.innerRadius or 50, 50)
  veh.respawn.finalRadius = math.min(veh.respawn.finalRadius or 160, 160)
end

local function onTrafficSpecialVehiclesProviders()
  gameplay_traffic.registerSpecialVehicleProvider({
    name = 'police',
    priority = 10,
    minTotalAmount = 0,
    getDesiredCount = function(totalAmount, options)
      if not options.police then return 0 end
      return math.ceil(totalAmount * 0.05)
    end,
    buildGroup = function(count, options)
      local fileData, fileName
      local fileMode = options.autoLoadFromFile or settings.getValue('trafficSmartSelections')
      if fileMode then
        fileData, fileName = gameplay_traffic_trafficUtils.getTrafficGroupFromFile({name = 'police'})
        if fileData then
          for i = #fileData, 2, -1 do
            local j = random(i)
            fileData[i], fileData[j] = fileData[j], fileData[i]
          end
          fileData = core_multiSpawn.fitGroup(fileData, count)
          log('I', 'police', string.format('Loaded police group from file: %s', fileName or ''))
        end
      end
      local group = fileData or gameplay_traffic_trafficUtils.createPoliceGroup(count)
      if not group[1] then
        for i = 1, count do
          table.insert(group, {model = 'fullsize', config = 'police'})
        end
      end
      return group
    end,
  })
end

local function checkRoadblock(vehIds, remainingWidthMeters, useLength) -- checks how many of the input vehicles can fit in a roadblock
  -- A nil axis preference uses the larger vehicle dimension.
  if type(vehIds) ~= 'table' then return end
  remainingWidthMeters = remainingWidthMeters or 10 -- maximum roadblock width

  local validVehIds = {}
  local vehiclesByLength = {}
  local totalLengthMeters = 0

  for _, id in ipairs(vehIds) do
    local veh = getObjectByID(id)
    if veh then
      local lengthMeters
      if useLength == nil then
        lengthMeters = max(veh.initialNodePosBB:getExtents().x, veh.initialNodePosBB:getExtents().y) -- automatically uses best axis
      else
        lengthMeters = useLength and veh.initialNodePosBB:getExtents().y or veh.initialNodePosBB:getExtents().x
      end
      table.insert(vehiclesByLength, {id, lengthMeters})
    end

    table.sort(vehiclesByLength, function(a, b) return a[2] < b[2] end) -- smallest to largest length
  end

  for _, vehicleLength in ipairs(vehiclesByLength) do
    remainingWidthMeters = remainingWidthMeters - vehicleLength[2]

    if remainingWidthMeters < 0 then break end
    totalLengthMeters = totalLengthMeters + vehicleLength[2]
    table.insert(validVehIds, vehicleLength[1])
  end

  return validVehIds, totalLengthMeters
end

local function placeRoadblock(vehIds, pos, rot, placeData) -- places a roadblock
  if type(vehIds) ~= 'table' or not pos or not rot then return end
  placeData = placeData or {}
  placeData.width = placeData.width or 10 -- available width of roadblock
  placeData.angle = placeData.angle or 0 -- angle offset for vehicles, in degrees

  tempFwd:set(vecY:rotated(rot)) -- expected to be parallel to the road
  tempUp:set(map.surfaceNormal(pos, 1))
  tempRight:setCross(tempFwd, tempUp)
  local vehicleCount = #vehIds
  local transforms = {}
  local vehicleRotation = quat()

  for i, id in ipairs(vehIds) do
    local veh = getObjectByID(id)
    if veh then
      tempPos:set(veh:getInitialNodePosition(veh:getRefNodeId())) -- position offset of vehicle

      -- make sure that the available space is validated
      local segmentWidthMeters = placeData.width / vehicleCount
      local lateralOffsetMeters = lerp(segmentWidthMeters * (i - 1), segmentWidthMeters * i, 0.5) - placeData.width * 0.5
      local sideSign = sign2(lateralOffsetMeters)

      tempFwd:setScaled2(tempRight, lateralOffsetMeters)
      tempFwd2:setScaled2(tempRight, sideSign)

      local angle = placeData.angle
      if placeData.centerAngle and lateralOffsetMeters == 0 then -- unique rotation for center object
        angle = placeData.centerAngle
      end

      -- calculate transform and offset for vehicle
      vehicleRotation:setFromDir(tempFwd2, tempUp)
      vehicleRotation:setMul2(vehicleRotation, quatFromAxisAngle(tempUp, math.rad(angle * sideSign)))
      tempFwd2:set(tempPos:rotated(vehicleRotation)) -- actual direction vector for vehicle
      local x, y, z = -tempFwd2.x, -tempFwd2.y, tempPos.z
      tempPos:setAdd2(pos, tempFwd) -- actual position for vehicle
      tempPos:setAddXYZ(x, y, z) -- offset adjustment
      table.insert(transforms, {pos = vec3(tempPos), rot = quat(vehicleRotation)})
    end
  end

  core_multiSpawn.placeGroup(vehIds, {ignoreAdjust = true, ignoreSafe = true, customTransforms = transforms}) -- delays some frames to improve performance
end

local function setupRoadblock(targetId, roadblockVehIds, roadblockPropIds, originPos, originDirVec, activeDist, spawnDist)
  local roadblock = {vehIds = {}, propIds = {}}
  local spawnData

  targetId = targetId or be:getPlayerVehicleID(0)
  roadblockVehIds = roadblockVehIds or tableKeysSorted(policeVehs)
  roadblockPropIds = roadblockPropIds or policePropIds
  originPos = originPos or core_camera.getPosition()
  originDirVec = originDirVec or core_camera.getForward()
  activeDist = activeDist or 100 -- radial distance for keeping nearby vehicles active (and preventing sudden vanishing)
  spawnDist = spawnDist or 120 -- minimum spawn distance for the roadblock

  -- set activeDist to 0 to skip distance and direction checks
  -- set spawnDist to 0 to force spawn roadblock at the origin

  local validCount = 0
  for _, vehId in ipairs(roadblockVehIds) do
    local vehObj = getObjectByID(vehId)
    if vehObj then
      validCount = validCount + 1
      tempPos:set(be:getObjectPositionXYZ(vehId))
      tempFwd:setSub2(tempPos, originPos)
      local dotValue = activeDist > 0 and 0 or math.huge
      if vehObj:getActive() and originPos:squaredDistance(tempPos) > square(activeDist) and originDirVec:dot(tempFwd) < dotValue then
        local vehData = policeVehs[vehId]
        if not vehData or (vehData and vehData.role and vehData.role.validTargets and vehData.role.validTargets[targetId]) then
          table.insert(roadblock.vehIds, vehId)
        end
      end
    elseif policeVehs[vehId] then
      policeVehs[vehId] = nil
    end
  end

  if validCount > 0 and roadblock.vehIds[min(2, validCount)] then -- at least 2 vehicles, or 1 if it is the only one available
    if spawnDist > 0 then
      spawnData = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(originPos, originDirVec, spawnDist, max(300, spawnDist * 3), 240, {pathRandomization = 0}) -- spawn point ahead of the target vehicle
    else
      spawnData = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(originPos, originDirVec, 0, 100, 0) -- spawn point at the origin
    end
    if spawnData and spawnData.n1 then
      local mapNodes = map.getMap().nodes
      local roadWidthMeters = math.min(mapNodes[spawnData.n1].radius, mapNodes[spawnData.n2].radius) * 2 + 1 -- road width, plus a small margin
      local fittingVehicleIds, totalVehicleLengthMeters = checkRoadblock(roadblock.vehIds, roadWidthMeters) -- returns vehicles that can fit in the roadblock
      if fittingVehicleIds[1] then -- at least one vehicle was valid
        roadblock.vehIds = fittingVehicleIds

        local fittingPropIds
        local maxPropLengthMeters = 0

        if roadblockPropIds[1] then
          fittingPropIds = checkRoadblock(roadblockPropIds, roadWidthMeters, false) -- TODO: optimize
          for _, propId in ipairs(fittingPropIds) do
            local propObj = getObjectByID(propId)
            if propObj then
              local extents = propObj.initialNodePosBB:getExtents()
              maxPropLengthMeters = max(maxPropLengthMeters, max(extents.x, extents.y))
              table.insert(roadblock.propIds, propId)
            end
          end
        end

        for _, vehId in ipairs(roadblock.vehIds) do
          local vehData = policeVehs[vehId]
          if vehData then
            if vehData.state == 'fadeIn' or vehData.state == 'fadeOut' then -- ensures that vehicles have full mesh alpha
              local vehObj = getObjectByID(vehId)
              if vehObj then
                vehObj:setMeshAlpha(1, '')
                vehData.alpha = 1
                vehData.state = 'active'
              end
            end
            vehData:modifyRespawnValues(500) -- prevents the vehicles from respawning too quickly
            vehData.role:setAction('roadblock')
          end
        end

        local angle = 0 -- roughly calculated angles (good enough for most cases)
        if roadWidthMeters - totalVehicleLengthMeters > 2 then
          angle = random(-20, 20)
        elseif roadWidthMeters - totalVehicleLengthMeters < 1 then
          angle = random(30, 50) * sign2(random() - 0.5)
        else
          angle = random(-5, 5)
        end

        placeRoadblock(roadblock.vehIds, spawnData.pos, quatFromDir(spawnData.dir, spawnData.normal), {angle = angle, centerAngle = 0, width = roadWidthMeters})
        if roadblock.propIds[1] then
          tempFwd:setScaled2(spawnData.dir, maxPropLengthMeters * 0.5 + 2)
          tempPos:setSub2(spawnData.pos, tempFwd)
          spawnData.pos2 = vec3(tempPos)
          placeRoadblock(roadblock.propIds, spawnData.pos2, quatFromDir(spawnData.dir, spawnData.normal), {angle = -90, width = roadWidthMeters})
        end

        return roadblock
      end
    end
  end

  return -- nil if failed
end

local function setPropsActive(active, reset)
  local validPropIds = {}
  for _, v in ipairs(policePropIds) do
    local veh = getObjectByID(v)
    if veh then
      veh:setActive(active and 1 or 0)
      if reset then
        veh:queueLuaCommand("recovery.loadHome()")
      end
      table.insert(validPropIds, v)
    end
  end
  policePropIds = validPropIds
end

local function insertProp(propId) -- adds a prop to use for roadblocks
  local veh = getObjectByID(propId or 0)
  if veh and not gameplay_traffic.getTrafficData()[propId] and not arrayFindValueIndex(policePropIds, propId) then
    table.insert(policePropIds, propId)
  end
end

local function removeProp(propId) -- removes a prop from the props list
  local idx = arrayFindValueIndex(policePropIds, propId or 0)
  if idx then
    table.remove(policePropIds, idx)
  end
end

local function resetPursuitVars() -- resets pursuit variables to default
  vars = {
    scoreLevels = deepcopy(defaultScoreLevels),
    strictness = 0.32, -- offense detection / score drip (lower = harder to register faults)
    offenseScoreScale = 0.75, -- scales ticket/hit scores so stacked offenses don't skip soft chase
    speedingOverSpeed = 4.4704,
    speedingScore = 200,
    arrestTime = 5,
    arrestRadius = 20,
    evadeTime = 40,
    evadeRadius = 80,
    suspectFrequency = 1.0, -- doubled interaction frequency; disabled if traffic random events are disabled
    roadblockFrequency = 0.5, -- roadblock frequency modifier (mode 3 only)
    useVisibility = true, -- set to false to disable visibility checks for pursuit targets
    autoRelease = true -- set to false to manually control the vehicle after an arrest
  }
end
resetPursuitVars()

local function setPursuitVars(data) -- sets various traffic variables
  if type(data) ~= 'table' then
    if not data then resetPursuitVars() end
    return
  end
  vars = tableMerge(vars, data)
end

-- Continuous wanted heat from mode + time spent fleeing + score progress.
local function getWantedLevel(pursuit)
  if not pursuit or not pursuit.mode or pursuit.mode <= 0 then
    return 0
  end
  local mode = clamp(pursuit.mode, 1, 3)
  local evadeTime = max(1e-12, vars.evadeTime or 40)
  local mainTimer = (pursuit.timers and pursuit.timers.main) or 0
  local scoreMax = (vars.scoreLevels and vars.scoreLevels[3]) or defaultScoreLevels[3]
  return clamp(
    (mode - 1) / 2 * 0.55
      + mainTimer / evadeTime * 0.35
      + (pursuit.score or 0) / max(1e-12, scoreMax) * 0.10,
    0,
    1
  )
end

local function getPursuitAggression(pursuit)
  local wanted01 = getWantedLevel(pursuit)
  return WANTED_AGGRESSION_MIN + wanted01 * (WANTED_AGGRESSION_MAX - WANTED_AGGRESSION_MIN)
end

local function getPursuitCrashSpeed(pursuit)
  local mode = (pursuit and pursuit.mode) or 0
  if mode < 2 then
    return WANTED_CRASH_SPEED_MIN
  end
  local modeMax = mode >= 3 and WANTED_CRASH_SPEED_MODE3_MAX or WANTED_CRASH_SPEED_MODE2_MAX
  local wanted01 = getWantedLevel(pursuit)
  return WANTED_CRASH_SPEED_MIN + wanted01 * (modeMax - WANTED_CRASH_SPEED_MIN)
end

local function getPoliceVehicles()
  return policeVehs
end

local function getNearestPoliceVehicle(targetId, isVisible, isUsable) -- returns the nearest police car from the given vehicle, with a few options
  local bestId
  local bestDist, bestInterDist = math.huge, math.huge -- best distance, best interactive distance (police driver looking ahead)

  for id, veh in pairs(policeVehs) do
    if be:getObjectActive(id) then
      local target = veh.role.validTargets[targetId or 0] -- gets cached data
      if target then
        if (not vars.useVisibility or not isVisible or target.visible) and (not isUsable or veh.role.state ~= 'disabled') then
          if target.dist < bestDist then
            bestDist = target.dist
            bestInterDist = target.interDist
            bestId = id
          end
        end
      end
    end
  end

  return bestId, bestDist, bestInterDist
end

local function suppressSpeedingOffense(vehId, duration)
  if not vehId then return end
  local traffic = gameplay_traffic.getTrafficData()
  local veh = traffic[vehId]
  if not veh then return end
  duration = duration or defaultSpeedingGraceDuration
  veh.speedingGraceTimer = max(veh.speedingGraceTimer or 0, duration)
end

local function isSpeedingOffenseSuppressed(veh)
  return veh and veh.speedingGraceTimer and veh.speedingGraceTimer > 0
end

local function stripTeleportSpeedingTicket(veh)
  if not veh or not veh.pursuit then return end
  local pursuit = veh.pursuit
  if (pursuit.mode or 0) > 0 then return end
  if type(pursuit.offenses) == "table" then
    for _, key in ipairs({"speeding", "racing"}) do
      if pursuit.offenses[key] then
        pursuit.offenses[key] = nil
        if type(pursuit.offensesList) == "table" then
          for i = #pursuit.offensesList, 1, -1 do
            if pursuit.offensesList[i] == key then
              table.remove(pursuit.offensesList, i)
            end
          end
        end
        pursuit.uniqueOffensesCount = math.max(0, (pursuit.uniqueOffensesCount or 1) - 1)
        pursuit.offensesCount = math.max(0, (pursuit.offensesCount or 1) - 1)
      end
    end
  end
  local hasRemaining = false
  if type(pursuit.offenses) == "table" then
    for _ in pairs(pursuit.offenses) do
      hasRemaining = true
      break
    end
  end
  if not hasRemaining then
    pursuit.addScore = 0
    pursuit.score = 0
    pursuit.offenseFlag = false
  end
  if veh.queuedFuncs then
    veh.queuedFuncs.pursuitStart = nil
  end
  if veh.tracking and veh.tracking.faults then
    veh.tracking.faults.overSpeed = 0
  end
end

local function ignoreSpeedingAfterTeleport(seconds)
  speedingImmuneRemaining = tonumber(seconds) or SPEEDING_TELEPORT_IMMUNITY_SEC
  local playerId = be:getPlayerVehicleID(0)
  if not playerId then return end
  local traffic = gameplay_traffic.getTrafficData()
  local veh = traffic and traffic[playerId]
  if veh then
    stripTeleportSpeedingTicket(veh)
    if veh.pos then
      lastPlayerPos:set(veh.pos)
      hasLastPlayerPos = true
    end
  end
end

local function ignoreSpeedingAfterRecovery(vehIds, seconds)
  seconds = tonumber(seconds) or SPEEDING_RECOVERY_IMMUNITY_SEC
  ignoreSpeedingAfterTeleport(seconds)
  local ids = vehIds
  if type(ids) ~= "table" then
    ids = ids and {ids} or nil
  end
  if not ids then
    local playerId = be:getPlayerVehicleID(0)
    ids = playerId and {playerId} or {}
  end
  for _, id in ipairs(ids) do
    suppressSpeedingOffense(id, seconds)
    local traffic = gameplay_traffic.getTrafficData()
    local veh = traffic and traffic[id]
    if veh then
      stripTeleportSpeedingTicket(veh)
      if veh.pos then
        local playerId = be:getPlayerVehicleID(0)
        if playerId and id == playerId then
          lastPlayerPos:set(veh.pos)
          hasLastPlayerPos = true
        end
      end
    end
  end
end

local function detectPlayerTeleportJump(veh)
  if not veh or veh.isAi then return end
  local playerId = be:getPlayerVehicleID(0)
  if not playerId or veh.id ~= playerId or not veh.pos then return end
  if hasLastPlayerPos and veh.pos:squaredDistance(lastPlayerPos) > TELEPORT_JUMP_M * TELEPORT_JUMP_M then
    ignoreSpeedingAfterTeleport()
  end
  lastPlayerPos:set(veh.pos)
  hasLastPlayerPos = true
end

local function isVehicleInPursuit(id, targetId) -- returns the pursuit status of a vehicle (targetId is optional, to filter the suspect)
  id = id or be:getPlayerVehicleID(0)

  local state, isPolice = false, false
  local traffic = gameplay_traffic.getTrafficData()
  local currVeh = traffic[id]
  if currVeh then
    if currVeh.roleName == 'police' then
      isPolice = true
      if currVeh.role.targetPursuitMode > 0 then
        if targetId then
          state = currVeh.role.targetId == targetId
        else
          state = true
        end
      end
    elseif currVeh.roleName == 'suspect' then
      if currVeh.pursuit.mode > 0 then
        state = true
      end
    end
  end

  return state, isPolice
end

local function setPursuitMode(mode, targetId, policeIds) -- sets pursuit mode; -1 = busted, 0 = off, 1 and higher = pursuit level
  targetId = targetId or be:getPlayerVehicleID(0) -- if targetId is not provided, uses player vehicle (intended as a backwards compatibility measure)
  if not targetId then return end

  local traffic = gameplay_traffic.getTrafficData()
  local targetVeh = traffic[targetId]
  if not traffic[targetId] or traffic[targetId].ignorePursuit then return end
  local pursuit = targetVeh.pursuit

  if not policeIds then
    policeIds = tableKeys(policeVehs) -- use all police vehicles
  elseif type(policeIds) == 'number' then -- backwards compatibility
    policeIds = {policeIds}
  end

  mode = clamp(mode or 0, -1, 3)
  local lastMode = pursuit.mode

  if mode == -1 then
    if targetVeh.role.name == 'suspect' then
      targetVeh.role:setAction('arrest')
    end
    pursuit.timers.main = 0
    pursuit.timers.arrest = 0

    for id, veh in pairs(traffic) do
      if id ~= targetId and veh.pursuit.mode >= 1 and veh.pos:squaredDistance(targetVeh.pos) < 6400 then -- during active arrest, clear pursuit level of nearby suspects
        setPursuitMode(0, id)
      end
    end
  elseif mode == 0 then -- reset pursuit data
    if targetVeh.role.name == 'suspect' then
      targetVeh.role:setAction('clear')
      suspectActive = false
    end
    pursuit.mode = 0
    targetVeh.role:resetAction()
    targetVeh:resetAll()
    -- resetAll replaces the pursuit table; keep the live reference.
    pursuit = targetVeh.pursuit

    if targetVeh.role.name == 'suspect' then
      targetVeh:setRole(targetVeh.autoRole)
    end
  else
    if targetVeh.role.name ~= 'suspect' then
      targetVeh:setRole('suspect')
      applySuspectOverrideAI(targetId)
    end

    if targetVeh.role.state ~= 'flee' then
      suspectTimer = math.huge
      suspectActive = true

      if targetVeh.role.state == 'wanted' then -- "wanted" vehicles will always try to flee
        local policePlayer = policeVehs[be:getPlayerVehicleID(0)]
        if gameplay_traffic.showMessages and policePlayer and not policePlayer.role.flags.busy then
          ui_message(string.format('%s %s', _tr('ui.traffic.suspectFlee', 'A suspect is fleeing from you! Vehicle:'), targetVeh.modelName), 5, 'traffic', 'traffic')
        end

        targetVeh.role.keepActionOnRefresh = false
        targetVeh.role:setAction('fleePolice')
      else
        if targetVeh.isAi then
          targetVeh.role.keepActionOnRefresh = false
          targetVeh.role:setAction('fleePolice')
        else
          targetVeh.role:setAction('fleePolice')
          -- Loudspeaker lines fire below on mode-up (replaces generic policePursuit toast).
        end
      end
    end

    if lastMode <= 0 then
      pursuit.initialSpeed = targetVeh.speed
      extensions.hook('onPursuitAction', targetId, 'start', pursuit)
      local reason = pursuit.offensesList[1] or 'undefined'
      log('D', logTag, string.format('Pursuit started for vehicle: %d . Reason: %s', targetId, reason))
    end
  end

  pursuit.mode = mode

  -- Player-as-suspect: lore loudspeaker when pursuit starts or escalates.
  if mode >= 1 and mode > lastMode and be:getPlayerVehicleID(0) == targetId and gameplay_traffic.showMessages then
    local msg = loudspeakerByMode[mode]
    if msg then
      ui_message(msg, 6, 'policeLoudspeaker', 'warning')
    end
  end

  for _, id in ipairs(policeIds) do
    local veh = policeVehs[id]
    if not veh then goto continuePolice end

    if mode == -1 then -- player is busted
      if veh.role.state ~= 'disabled' and veh.role.targetId == targetId then
        veh.role:setAction('pursuitEnd')
      end
    elseif mode == 0 then
      -- Include disabled/wrecked units, and pursuit-flagged units that lost their targetId.
      local targetingSuspect = veh.role.targetId == targetId
      local orphanPursuit = veh.role.flags and veh.role.flags.pursuit and not veh.role.targetId
      if targetingSuspect or orphanPursuit then
        if be:getObjectActive(id) then -- important, vehicle object must be active (inactive ones will self resolve later)
          veh.role:resetAction()
        end
        shrinkPoliceRespawnRadius(veh)
      end
    elseif mode >= 1 then
      if veh.role.state ~= 'disabled' then
        veh.role:setTarget(targetId)
        veh.role:setAction('pursuitStart', {mode = mode, targetId = targetId})
        pursuit.score = lastMode <= mode and max(pursuit.score, vars.scoreLevels[mode]) or min(pursuit.score, vars.scoreLevels[mode])
      end
    end
    ::continuePolice::
  end

  extensions.hook('onPursuitModeUpdate', targetId, {mode = mode})
end

local function setSuspect(id) -- changes a traffic vehicle's role to 'suspect'
  local veh = gameplay_traffic.getTrafficData()[id or 0]
  if veh then
    veh:setRole('suspect')
    applySuspectOverrideAI(id or 0)
    veh.role:setAction('watchPolice')
    veh.role.keepActionOnRefresh = true
  end
end

local function setSuspectTimer(time) -- sets the time until the next suspect will be queued
  if time then
    suspectTimer = time
  else
    local coef = 2 -- timer multiplier
    local playerPolice = policeVehs[be:getPlayerVehicleID(0)]
    if playerPolice then
      if playerPolice.role.targetLastState == 'arrest' then
        coef = 1 -- short delay
      elseif playerPolice.role.targetLastState == 'evade' then
        coef = 5 -- long delay
      end
    end
    suspectTimer = 120 * coef * square(1 - vars.suspectFrequency) + random(15, 45) -- time until next suspect gets queued
  end
end

local function arrestVehicle(id, showMessages) -- instantly sets a vehicle as arrested
  local veh = gameplay_traffic.getTrafficData()[id]
  if not veh then return end
  -- works as intended if the target vehicle role is 'suspect'

  if showMessages then
    if be:getPlayerVehicleID(0) == id then
      local str = veh.pursuit.mode == 1 and 'ui.traffic.policeTicket' or 'ui.traffic.policeArrest'
      ui_message(str, 4, 'traffic', 'traffic')

      if veh.pursuit.offensesList[1] then
        local offensesTranslated = {}
        for _, v in ipairs(veh.pursuit.offensesList) do
          table.insert(offensesTranslated, _tr(string.format('ui.traffic.infractions.%s', v), v))
        end

        ui_message(string.format('%s %s', _tr('ui.traffic.infractions.title', 'Offenses:'), table.concat(offensesTranslated, ', ')), 5, 'trafficInfractions', 'traffic')
      end
    elseif be:getPlayerVehicleID(0) == veh.role.targetId or policeVehs[be:getPlayerVehicleID(0)] then
      if veh.role.targetLastState then veh.role.targetLastState = 'arrest' end
      ui_message('ui.traffic.suspectArrest', 5, 'traffic', 'traffic')
    end
  end

  suspectActive = false

  extensions.hook('onPursuitAction', id, 'arrest', veh.pursuit)

  local tempIds = {}
  for pid, p in pairs(policeVehs) do
    if p.role.targetId == id then
      table.insert(tempIds, pid)
    end
  end
  setPursuitMode(-1, id, tempIds)
end

local function evadeVehicle(id, showMessages) -- instantly sets a vehicle as evaded
  local veh = gameplay_traffic.getTrafficData()[id]
  if not veh then return end

  if showMessages then
    if be:getPlayerVehicleID(0) == id then
      ui_message('ui.traffic.policeEvade', 5, 'traffic', 'traffic')
    elseif be:getPlayerVehicleID(0) == veh.role.targetId or policeVehs[be:getPlayerVehicleID(0)] then
      if veh.role.targetLastState then veh.role.targetLastState = 'evade' end
      ui_message('ui.traffic.suspectEvade', 5, 'traffic', 'traffic')
    end
  end

  suspectActive = false

  extensions.hook('onPursuitAction', id, 'evade', veh.pursuit)

  -- Pass nil so all police are considered; mode 0 clears by targetId or pursuit flag.
  setPursuitMode(0, id)
end

local function recycleArrestedAiSuspect(id)
  local traffic = gameplay_traffic.getTrafficData()
  local veh = traffic[id]
  if not veh or not veh.isAi then return end

  local obj = getObjectByID(id)
  if obj then
    obj:queueLuaCommand('controller.setFreeze(0)')
    obj:queueLuaCommand('obj:requestReset(RESET_PHYSICS)')
    obj:resetBrokenFlexMesh()
  end

  if veh.role and veh.role.name == 'suspect' then
    veh.role.keepActionOnRefresh = false
    veh:setRole(veh.autoRole or 'standard')
  end

  if gameplay_traffic.forceTeleport then
    gameplay_traffic.forceTeleport(id)
  elseif veh._teleport ~= nil then
    veh._teleport = true
  end
end

local function releaseVehicle(id, showMessages) -- unfreezes controls and lets a vehicle continue after an arrest
  local obj = getObjectByID(id)
  if not obj then return end

  local veh = gameplay_traffic.getTrafficData()[id]
  if not veh then
    obj:queueLuaCommand('controller.setFreeze(0)')
    return
  end

  if showMessages and be:getPlayerVehicleID(0) == id then
    ui_message('ui.traffic.driveAway', 5, 'traffic', 'traffic')
  end

  extensions.hook('onPursuitAction', id, 'release', veh.pursuit)

  -- Same as evade: clear every police unit still tied to this suspect.
  setPursuitMode(0, id)

  local playerId = be:getPlayerVehicleID(0)
  if veh.isAi and playerId and policeVehs[playerId] then
    recycleArrestedAiSuspect(id)
  end
end

local function setupPursuitGameplay(suspectId, policeIds, options) -- helper function for setting up pursuit gameplay
  -- sets traffic data for suspect and police vehicles; prevents the suspect from respawning
  options = options or {}
  options.playerId = options.playerId or be:getPlayerVehicleID(0)
  options.pursuitMode = options.pursuitMode or 2 -- default pursuit mode
  options.preventAutoStart = options.preventAutoStart and true or false -- prevents the pursuit from automatically starting

  if not suspectId then
    suspectId = be:getPlayerVehicleID(0) -- assumes that the player vehicle should be the suspect
  end

  gameplay_traffic.insertTraffic(suspectId, suspectId == options.playerId, true) -- the third argument prevents the vehicle from becoming deactivated due to the vehicle pooling system
  local veh = gameplay_traffic.getTrafficData()[suspectId]
  if veh then
    veh.enableRespawn = false
    veh:setRole('suspect')
    applySuspectOverrideAI(suspectId)
    veh.role.pursuitMode = options.pursuitMode

    if veh.pursuit.mode ~= 0 then
      setPursuitMode(0, suspectId) -- resets the pursuit mode if it was active
    end

    if not options.preventAutoStart then
      veh.role:setAction('watchPolice')
      veh.role.flags.driveCheck = 1 -- special flag that delays the pursuit if the vehicle is not driving
    end
  else
    log('W', logTag, string.format('Failed to start pursuit gameplay, suspect vehicle not found: %d', suspectId))
    return false
  end

  -- if policeIds is not provided, uses current existing police vehicles
  if policeIds then
    for _, id in ipairs(policeIds) do
      gameplay_traffic.insertTraffic(id, id == options.playerId, true)
      veh = gameplay_traffic.getTrafficData()[id]
      if veh then
        veh:setRole('police') -- force sets police role
      end
    end
  end

  if not next(policeVehs) then
    log('W', logTag, 'Failed to start pursuit gameplay, no police vehicles exist!')
    return false
  end

  return true
end

local function getPursuitData(id) -- returns pursuit data from the given vehicle, or the player vehicle by default
  -- exists for backwards compatibility
  id = id or be:getPlayerVehicleID(0)
  local veh = id and gameplay_traffic.getTrafficData()[id]
  if veh then
    return veh.pursuit
  end
end

local function getPursuitVars()
  return vars
end

local function onTrafficAction(id, action, data)
  if gameplay_traffic.getTrafficData()[id] then
    if action == 'changeRole' then
      if data.name == 'police' then
        if not policeVehs[id] then
          policeVehs[id] = gameplay_traffic.getTrafficData()[id]
        end
      elseif data.prevName == 'police' then
        if policeVehs[id] then
          policeVehs[id] = nil
        end
      end
    end
  end
end

local function onTrafficVehicleAdded(id)
  if gameplay_traffic.getTrafficData()[id].role.name == 'police' then
    policeVehs[id] = gameplay_traffic.getTrafficData()[id]
  end
end

local function onTrafficVehicleRemoved(id)
  if policeVehs[id] then
    policeVehs[id] = nil
  end
end

local function onTrafficStarted()
  local policeAmount, propAmount = tableSize(policeVehs), #policePropIds
  if policeAmount > 0 or propAmount > 0 then
    log('I', logTag, string.format('Activated %d police vehicles and %d police props', policeAmount, propAmount))
  end
end

local function onTrafficStopped()
  table.clear(policeVehs)
  walkHandoffVehId = nil
end

local function onVehicleSwitched(oldId, newId)
  if gameplay_traffic.getState() ~= 'on' then return end

  local obj = getObjectByID(newId)
  if obj and obj:isPlayerControlled() then
    local traffic = gameplay_traffic.getTrafficData()
    if not traffic[newId] then
      gameplay_traffic.insertTraffic(newId, true)
    end

    local prevObj = getObjectByID(oldId)
    local inVeh = (prevObj and prevObj.jbeam == 'unicycle')
    local outVeh = (obj and obj.jbeam == 'unicycle')

    if traffic[oldId] and traffic[newId] then
      if outVeh and traffic[oldId].role.name == 'police' then
        traffic[newId].ignorePolice = true -- prevents self arrest
      end

      if not outVeh then
        suppressSpeedingOffense(newId, 1.5)
      end

      if traffic[oldId].pursuit and traffic[oldId].pursuit.mode > 0 then
        if traffic[newId].role.name ~= 'suspect' then
          traffic[newId]:setRole('suspect')
          applySuspectOverrideAI(newId)
        end

        local mode = traffic[oldId].pursuit.mode
        traffic[newId].pursuit = deepcopy(traffic[oldId].pursuit)
        setPursuitMode(0, oldId)
        traffic[newId].queuedFuncs.pursuitChange = {timer = 0.1, func = overhaul_integration_services_police.setPursuitMode, args = {mode, newId}}

        if inVeh and traffic[newId].pursuit.policeVisible then
          traffic[newId].queuedFuncs.autoArrest = {timer = 0.2, func = overhaul_integration_services_police.arrestVehicle, args = {newId, gameplay_traffic.showMessages}}
        end
      end
    elseif outVeh and traffic[oldId] then
      walkHandoffVehId = oldId
    elseif inVeh and traffic[newId] then
      suppressSpeedingOffense(newId, 1.5)

      local handoffVeh = walkHandoffVehId and traffic[walkHandoffVehId]
      if handoffVeh and handoffVeh.pursuit and handoffVeh.pursuit.mode > 0 then
        if walkHandoffVehId ~= newId then
          if traffic[newId].role.name ~= 'suspect' then
            traffic[newId]:setRole('suspect')
            applySuspectOverrideAI(newId)
          end

          local mode = handoffVeh.pursuit.mode
          traffic[newId].pursuit = deepcopy(handoffVeh.pursuit)
          setPursuitMode(0, walkHandoffVehId)
          traffic[newId].queuedFuncs.pursuitChange = {timer = 0.1, func = overhaul_integration_services_police.setPursuitMode, args = {mode, newId}}
        end

        if traffic[newId].pursuit.policeVisible then
          traffic[newId].queuedFuncs.autoArrest = {timer = 0.2, func = overhaul_integration_services_police.arrestVehicle, args = {newId, gameplay_traffic.showMessages}}
        end
      end
    end

    if not outVeh then
      walkHandoffVehId = nil
    end
  end
end

local function getWalkHandoffVehId()
  return walkHandoffVehId
end

local function onVehicleResetted(id)
  if gameplay_traffic.getState() ~= 'on' or not next(policeVehs) then return end

  local traffic = gameplay_traffic.getTrafficData()
  if traffic[id] and traffic[id].isAi then
    if not suspectActive and suspectTimer <= 0 and traffic[id].role.name == 'standard' then
      setSuspect(id)
      suspectTimer = math.huge
      suspectActive = true
    elseif suspectActive and traffic[id].role.name == 'suspect' then
      local obj = getObjectByID(id)
      if obj then
        obj:queueLuaCommand('controller.setFreeze(0)')
      end
      traffic[id]:setRole(traffic[id].autoRole or 'standard')
      traffic[id].role.keepActionOnRefresh = false
      suspectActive = false
    end
  end
end

local function onVehicleDestroyed(id)
  local i = arrayFindValueIndex(policePropIds, id)
  if i then
    table.remove(policePropIds, i)
  end
  if walkHandoffVehId == id then
    walkHandoffVehId = nil
  end
end

local function onClientEndMission()
  table.clear(policeVehs)
  resetPursuitVars()
  speedingImmuneRemaining = 0
  hasLastPlayerPos = false
  walkHandoffVehId = nil
end

local function onUpdate(dt, dtSim)
  if speedingImmuneRemaining > 0 then
    speedingImmuneRemaining = math.max(0, speedingImmuneRemaining - (dtSim or 0))
  end
  if not M.enabled or not be:getEnabled() then return end
  if gameplay_traffic.getState() ~= 'on' or not next(policeVehs) then
    suspectActive = false
    suspectTimer = math.huge
    return
  else
    if suspectTimer == math.huge and not suspectActive then
      setSuspectTimer()
    end
  end

  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    if veh.speedingGraceTimer and veh.speedingGraceTimer > 0 then
      veh.speedingGraceTimer = max(0, veh.speedingGraceTimer - dtSim)
    end
    detectPlayerTeleportJump(veh)
    local pursuit = veh.pursuit

    -- pursuit mode processing
    if pursuit.mode >= 0 then
      for i, score in ipairs(vars.scoreLevels) do
        if pursuit.mode < i and pursuit.score >= score then
          if pursuit.mode == 0 then -- activates only nearest police vehicle at start of pursuit
            if not veh.queuedFuncs.pursuitStart then
              local delay = clamp(15 / max(1e-12, veh.speed), 0, 1)
              veh.queuedFuncs.pursuitStart = {timer = delay, func = setPursuitMode, args = {i, id, pursuit.sight and pursuit.sight.policeId}} -- small delay for lights & sirens
            end
          else
            setPursuitMode(i, id)
          end
          break
        end
      end
    end
  end

  if gameplay_traffic.getTrafficVars().enableRandomEvents and vars.suspectFrequency > 0 then
    if not suspectActive then
      suspectTimer = max(0, suspectTimer - dtSim)
    end
  else
    suspectActive = false
    suspectTimer = math.huge
  end
end

local function onSerialize()
  local data = {vars = deepcopy(vars), propIds = deepcopy(policePropIds)} -- no need to cache police ids, they should automatically get reprocessed
  onTrafficStopped()
  return data
end

local function onDeserialized(data)
  vars = tableMerge(deepcopy(vars), data.vars or {})
  policePropIds = data.propIds or {}
end

-- public interface
M.insertProp = insertProp
M.removeProp = removeProp
M.setPropsActive = setPropsActive
M.checkRoadblock = checkRoadblock
M.placeRoadblock = placeRoadblock
M.setupRoadblock = setupRoadblock
M.setPursuitMode = setPursuitMode
M.setPursuitVars = setPursuitVars
M.setPoliceVars = setPursuitVars
M.setSuspect = setSuspect
M.setSuspectTimer = setSuspectTimer
M.arrestVehicle = arrestVehicle
M.evadeVehicle = evadeVehicle
M.releaseVehicle = releaseVehicle
M.setupPursuitGameplay = setupPursuitGameplay

M.getPursuitData = getPursuitData
M.getPursuitVars = getPursuitVars
M.getPoliceVars = getPursuitVars
M.getPoliceVehicles = getPoliceVehicles
M.getPolice = getPoliceVehicles
M.getNearestPoliceVehicle = getNearestPoliceVehicle
M.isVehicleInPursuit = isVehicleInPursuit
M.getWalkHandoffVehId = getWalkHandoffVehId
M.getWantedLevel = getWantedLevel
M.getPursuitAggression = getPursuitAggression
M.getPursuitCrashSpeed = getPursuitCrashSpeed

M.onTrafficAction = onTrafficAction
M.onTrafficVehicleAdded = onTrafficVehicleAdded
M.onTrafficVehicleRemoved = onTrafficVehicleRemoved
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission
M.onUpdate = onUpdate
M.onTrafficSpecialVehiclesProviders = onTrafficSpecialVehiclesProviders
M.ignoreSpeedingAfterTeleport = ignoreSpeedingAfterTeleport
M.ignoreSpeedingAfterRecovery = ignoreSpeedingAfterRecovery
M.isPlayerSpeedingImmune = function()
  return speedingImmuneRemaining > 0
end
M.teleportedFromBigmap = ignoreSpeedingAfterTeleport
M.onRecoveryPromptButtonPressed = function(buttonId)
  if buttonId == "flipUpright" or buttonId == "towToRoad"
      or buttonId == "flipMission" or buttonId == "recoverMission" then
    ignoreSpeedingAfterRecovery()
  end
end
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized


M.onTeleportedToGarage = function(_, veh)
  if veh then
    suppressSpeedingOffense(veh:getID(), defaultSpeedingGraceDuration)
  end
end

M.suppressSpeedingOffense = suppressSpeedingOffense

-- Explicit exports keep unrelated helpers outside the service activation gate.
local guardedExports = {
  "insertProp", "removeProp", "setPropsActive", "checkRoadblock", "placeRoadblock",
  "setupRoadblock", "setPursuitMode", "setPursuitVars", "setPoliceVars", "setSuspect",
  "setSuspectTimer", "arrestVehicle", "evadeVehicle", "releaseVehicle", "setupPursuitGameplay",
  "getPursuitData", "getPursuitVars", "getPoliceVars", "getPoliceVehicles", "getPolice",
  "getNearestPoliceVehicle", "isVehicleInPursuit", "getWalkHandoffVehId", "getWantedLevel", "getPursuitAggression",
  "getPursuitCrashSpeed", "onTrafficAction", "onTrafficVehicleAdded", "onTrafficVehicleRemoved", "onTrafficStarted",
  "onTrafficStopped", "onVehicleSwitched", "onVehicleResetted", "onVehicleDestroyed", "onClientEndMission",
  "onUpdate", "onTrafficSpecialVehiclesProviders", "ignoreSpeedingAfterTeleport", "ignoreSpeedingAfterRecovery", "isPlayerSpeedingImmune",
  "teleportedFromBigmap", "onRecoveryPromptButtonPressed", "onSerialize", "onDeserialized", "onTeleportedToGarage",
  "suppressSpeedingOffense",
}

M = require('overhaul/lib/shell/serviceGuard')(M, function(data)
  resetPursuitVars()
  onDeserialized({propIds = data and data.propIds})
  for id in pairs(gameplay_traffic.getTrafficData()) do onTrafficVehicleAdded(id) end
end, function()
  local data = onSerialize()
  onClientEndMission()
  return data
end, guardedExports)

-- A disabled service still owns this notification, as its guarded direct API did.
-- Mark it handled outside the guard so recovery never falls through to stock police.
function M.onOverhaulRecoverySpeedSpike(ids, answer)
  answer.handled = true
  if M.ignoreSpeedingAfterRecovery then
    M.ignoreSpeedingAfterRecovery(ids)
  elseif M.ignoreSpeedingAfterTeleport then
    M.ignoreSpeedingAfterTeleport()
  end
end

return M
