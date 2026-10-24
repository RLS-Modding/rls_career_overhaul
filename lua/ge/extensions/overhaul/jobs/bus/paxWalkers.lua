-- Bus stop walkers, curb positions and timed boarding visuals for one bus instance.
-- Read data and owned pools, waiting positions, movement, stop hooks, frame update and public API.
return function(ctx)
  local function createStaticBody(config, upDirection, token)
    local POOL_PREFIX = 'ovhBusPaxPool'
    local OWNER_FIELD = 'ovhBusPaxOwner'
    local bodyBackend = {name = 'static', doorGapM = 0, refreshAfterCreate = true}

    local function object(id) return id and scenetree.findObjectById(id) or nil end

    local function newStatic(shape, name)
      local objectInstance = createObject('TSStatic')
      objectInstance:setField('shapeName', 0, shape)
      objectInstance:setField('collisionType', 0, 'None')
      objectInstance:setField('decalType', 0, 'None')
      objectInstance.useInstanceRenderData = true
      objectInstance.canSave = false
      objectInstance.hidden = true
      objectInstance:registerObject(Sim.getUniqueName(name))
      return objectInstance
    end

    -- Removes static walker pools of other owners (a replaced bus extension, a Lua reload).
    function bodyBackend.sweep(keepId)
      local names = scenetree.findClassObjects('SimGroup') or {}
      for _, name in ipairs(names) do
        if type(name) == 'string' and name:sub(1, #POOL_PREFIX) == POOL_PREFIX then
          local group = scenetree.findObject(name)
          local owner = group and group.getDynDataFieldbyName and group:getDynDataFieldbyName(OWNER_FIELD, 0)
          if group and owner ~= token and group:getId() ~= keepId then group:delete() end
        end
      end
    end

    -- Every object is recorded the moment it exists; a failure part-way deletes what was made and rethrows.
    function bodyBackend.create(count)
      local pool = {}
      local ok, err = pcall(function()
        local group = createObject('SimGroup')
        group.canSave = false
        group:registerObject(Sim.getUniqueName(POOL_PREFIX))
        pool.groupId = group:getId()
        group:setDynDataFieldbyName(OWNER_FIELD, 0, token)
        for i = 1, count do
          local bodyHandle = {}
          pool[i] = bodyHandle
          local body = newStatic(config.shapes.body, 'ovhBusPaxBody')
          bodyHandle.bodyId = body:getId()
          group:addObject(body)
          local ball = newStatic(config.shapes.ball, 'ovhBusPaxBall')
          bodyHandle.ballId = ball:getId()
          group:addObject(ball)
        end
      end)
      if not ok then
        bodyBackend.destroy(pool)
        error(err, 0)
      end
      return pool
    end

    -- The level can take the objects with it.
    function bodyBackend.alive(pool) return pool ~= nil and object(pool.groupId) ~= nil end
    function bodyBackend.poolId(pool) return pool and pool.groupId end

    local function setPose(bodyHandle, pos, yaw, roll, bob)
      local body, ball = object(bodyHandle.bodyId), object(bodyHandle.ballId)
      if not body or not ball then return end
      local rotation = quatFromAxisAngle(upDirection, yaw)
      body:setPosRot(pos.x, pos.y, pos.z + (bob or 0), rotation.x, rotation.y, rotation.z, rotation.w)
      local rot = quatFromAxisAngle(vec3(1, 0, 0), roll or 0) * rotation -- roll about the walker's own side axis, then yaw
      ball:setPosRot(pos.x, pos.y, pos.z + config.shapes.ballRadius, rot.x, rot.y, rot.z, rot.w)
      -- instance-rendered statics draw their uploaded transform (stock groundMarkerArrows does the same)
      if body.updateInstanceRenderData then body:updateInstanceRenderData() end
      if ball.updateInstanceRenderData then ball:updateInstanceRenderData() end
      bodyHandle.pos = pos
    end

    -- Standing at pos facing yaw (shown, snapped back to a spot, refreshed); the ball keeps its roll.
    function bodyBackend.place(bodyHandle, pos, yaw, roll) setPose(bodyHandle, pos, yaw, roll or 0) end
    -- One walking frame: the walker logic has advanced pos, yaw, the ball roll and the bob.
    function bodyBackend.move(bodyHandle, pos, yaw, roll, bob) setPose(bodyHandle, pos, yaw, roll, bob) end
    -- Reached the end of the path.
    function bodyBackend.arrive(bodyHandle, pos, yaw, roll) setPose(bodyHandle, pos, yaw, roll) end

    -- Upload visibility changes because static instances draw their last uploaded render data.
    function bodyBackend.setHidden(bodyHandle, hidden)
      for _, id in ipairs({bodyHandle.bodyId, bodyHandle.ballId}) do
        local objectInstance = object(id)
        if objectInstance then
          objectInstance.hidden = hidden
          if objectInstance.updateInstanceRenderData then objectInstance:updateInstanceRenderData() end
        end
      end
    end

    function bodyBackend.paint(bodyHandle, rng)
      local body = object(bodyHandle.bodyId)
      if not body then return end
      local function paint() return string.format('%.3f %.3f %.3f 1', rng.range(0.25, 0.95), rng.range(0.25, 0.95), rng.range(0.25, 0.95)) end
      body:setField('instanceColor', 0, paint())
      body:setField('instanceColor1', 0, paint())
      body:setField('instanceColor2', 0, paint())
      if body.updateInstanceRenderData then body:updateInstanceRenderData() end
    end

    function bodyBackend.position(bodyHandle) return bodyHandle.pos end
    function bodyBackend.ids(bodyHandle) return {bodyId = bodyHandle.bodyId, ballId = bodyHandle.ballId} end

    -- For the pool log line: what the figures are made of and whether the game can draw them.
    function bodyBackend.describe(pool)
      local first = pool and pool[1]
      return string.format('group %s, first body %s ball %s, shape %s exists %s, %s', tostring(pool and pool.groupId),
        tostring(first and first.bodyId), tostring(first and first.ballId), config.shapes.body,
        tostring(FS:fileExists(config.shapes.body)),
        scenetree.findObject('character_primary') ~= nil and 'materials loaded' or 'character materials NOT loaded')
    end

    -- Deletes this pool's own objects only.
    function bodyBackend.destroy(pool)
      for _, bodyHandle in ipairs(pool or {}) do
        for _, id in ipairs({bodyHandle.bodyId, bodyHandle.ballId}) do
          local objectInstance = object(id)
          if objectInstance then objectInstance:delete() end
        end
      end
      local group = pool and object(pool.groupId)
      if group then group:delete() end
    end

    return bodyBackend
  end

  local DATA_DIR = '/gameplay/overhaul/bus/'
  local BACKENDS = {static = createStaticBody, vehicle = function(...)
    return require('overhaul/jobs/bus/paxBodyVehicle')(...)
  end}
  local token = tostring({}):match('0x%x+') or tostring(math.floor(os.clock() * 1e6))
  local frame = 0 -- counted by update(), for figures made and shown in the same frame
  local retired = false
  local paused = false

  local disabled = false
  local pool -- {groupId, walkers = {...}}
  local scene -- the stop the walkers belong to
  local visible = 0
  local moving = 0
  local pollTimer = 0
  local clock = 0
  local seedCounter = 0

  -- ------------------------------------------------------------------------------------- data
  local function mergeInto(dst, src)
    for k, v in pairs(src or {}) do
      if type(v) == 'table' and type(dst[k]) == 'table' and v[1] == nil then mergeInto(dst[k], v) else dst[k] = v end
    end
    return dst
  end

  local function defaultConfig()
    return {
      enabled = true, maxWalkers = 12, backend = 'static',
      shapes = {body = '/art/shapes/overhaul/bus_passenger/passenger_body.dae',
        ball = '/art/shapes/overhaul/bus_passenger/passenger_ball.dae', ballRadius = 0.307},
      walk = {speed = 1.3, speedJitter = 0.15, maxSpeed = 2.0, turnRateDeg = 360, bobHeightM = 0.02, bobHz = 2},
      waiting = {min = 2, max = 8, approachM = 120, hideM = 150, stripLengthM = 8, spacingM = 0.8, jitterM = 0.3,
        curbOffsetM = {1.0, 2.0}, depthJitterM = 0.6, stripForward = 0.35, faceJitterDeg = 10, faceApproach = 0.35,
        depthM = 1.6, levelToleranceM = 0.3, clearanceM = 1.8, shelterMarginM = 0.35, candidates = 8},
      door = {approachM = 0.9, stepM = 0.2, arriveEarlyS = 0.3},
      alight = {outM = 1.5, dispersalM = {4, 10}},
      finalStop = {maxWalkers = 8, staggerS = 0.3},
      shelters = {radiusM = 20, shapes = {}, cluster = 3},
      road = {searchM = 20},
      ground = {bandM = 1.5, levelM = 3.0},
      sideByLevel = {default = 'right'},
    }
  end
  local DEFAULTS = defaultConfig()

  -- Built with the data on first use, so creating the bus extension needs no math library yet.
  local path
  local upDirection
  local body -- the chosen body backend
  local config
  local doorModels
  local doorFallback

  local function loadData()
    if config then return config end
    path = require('overhaul/jobs/bus/paxPath')()
    upDirection = path.UP
    config = mergeInto(mergeInto({}, DEFAULTS), jsonReadFile(DATA_DIR .. 'walkers.json') or {})
    doorModels, doorFallback = {}, {frontInsetM = 1.6, rearFraction = 0.55}
    local files = FS:findFiles(DATA_DIR, 'doors*.json', 0, false, false) or {}
    table.sort(files) -- doors.json first, then add-on files in name order
    for _, file in ipairs(files) do
      local data = jsonReadFile(file) or {}
      for model, def in pairs(data.models or {}) do doorModels[model] = def end
      if data.fallback then mergeInto(doorFallback, data.fallback) end
    end
    body = (BACKENDS[config.backend] or BACKENDS.static)(config, upDirection, token)
    return config
  end

  -- A separate random stream keeps cosmetic placement from changing job rewards.
  local function newRng(seed)
    local state = math.floor(math.abs(seed)) % 2147483646 + 1
    local rng = {}
    function rng.next()
      state = state * 16807 % 2147483647
      return (state - 1) / 2147483646
    end
    function rng.range(lo, hi) return lo + (hi - lo) * rng.next() end
    function rng.int(lo, hi) return math.min(hi, lo + math.floor(rng.next() * (hi - lo + 1))) end
    return rng
  end

  local function hashText(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
    return h
  end

  -- ------------------------------------------------------------------------------------- pool
  local function live() return not retired and (not ctx.isCurrent or ctx.isCurrent()) end

  -- Lifecycle log lines (tag busWalkers) for in-game checks; `once` logs a reason a single time per key.
  local logged = {}
  local function info(msg) log('I', 'busWalkers', msg) end
  local function once(key, msg)
    if logged[key] then return end
    logged[key] = true
    info(msg)
  end
  local function xyz(p) return p and string.format('%.1f,%.1f,%.1f', p.x, p.y, p.z) or '?' end

  -- Startup only: removes walker pools of other owners (a replaced bus extension, a Lua reload).
  local function sweep()
    if not live() then return end
    local keepId = pool and body and body.poolId(pool.body)
    for _, part in pairs(BACKENDS) do -- either backend's leftovers, so a changed setting leaves nothing behind
      part(config or DEFAULTS, upDirection or vec3(0, 0, 1), token).sweep(keepId)
    end
  end

  local function ensurePool(anchor, rng)
    if pool then
      if body.alive(pool.body) then return pool end
      -- the level took (some of) the objects with it: every figure is gone, and so are the counts
      info('walker pool ' .. tostring(body.poolId(pool.body)) .. ' is gone from the scene; building a new one')
      body.destroy(pool.body)
      pool, visible, moving = nil, 0, 0
      if scene then scene.waiting, scene.boarders, scene.alighters = {}, {}, {} end
    end
    if not live() then return nil end
    loadData()
    local bodies = body.create(config.maxWalkers, anchor, rng)
    if not bodies then info('walker pool could not be made (' .. body.name .. ' backend)') return nil end
    pool = {body = bodies, walkers = {}, createdFrame = frame}
    for i, h in ipairs(bodies) do
      pool.walkers[i] = {index = i, h = h, state = 'free', yaw = 0, roll = 0, createdFrame = frame}
    end
    info(string.format('walker pool created: %d figures (%s backend), %s', #pool.walkers, body.name, body.describe(bodies)))
    return pool
  end

  -- Keep the character's negative-Y facing convention when converting a route direction into yaw.
  local function yawOf(dir) return math.atan2(-dir.x, -dir.y) end

  local function place(walker, pos)
    body.place(walker.h, pos, walker.yaw, walker.roll)
    walker.pos = pos
  end

  local function setHidden(walker, hidden) body.setHidden(walker.h, hidden) end

  -- New static figures need a later transform upload to avoid a white slab in their creation frame.
  local fresh = {}
  local FRESH_FRAMES = 3
  local function markFresh(walker)
    if body.refreshAfterCreate and walker.createdFrame == frame then fresh[walker] = FRESH_FRAMES end
  end

  -- Only visual state transitions show, hide or recycle a walker; the job retains passenger accounting.
  local SHOWN = {waiting = true, boarding = true, atDoor = true, alighting = true, dispersed = true}
  local MOVING = {boarding = true, alighting = true}

  local function setState(walker, state)
    if SHOWN[walker.state] then visible = visible - 1 end
    if MOVING[walker.state] then moving = moving - 1 end
    walker.state = state
    if SHOWN[state] then visible = visible + 1 end
    if MOVING[state] then moving = moving + 1 end
  end

  local function show(walker, pos, yaw, rng)
    walker.yaw, walker.roll = yaw, 0
    if rng then body.paint(walker.h, rng) end
    setHidden(walker, false)
    place(walker, pos) -- the upload comes last, with the figure visible
    markFresh(walker)
  end

  local function release(walker)
    if walker.state == 'free' then return end
    setHidden(walker, true)
    setState(walker, 'free')
    walker.path, walker.boarder, walker.attempt, walker.spot = nil, nil, nil, nil
  end

  local function releaseAll()
    for _, walker in ipairs(pool and pool.walkers or {}) do release(walker) end
    scene = nil
    paused = false
  end

  -- Job passengers follow the Overhaul toggle independently of the stock seat occupant setting.
  local function allowed()
    if not loadData().enabled then return false, 'turned off in walkers.json' end
    local shell = overhaul_shell_settings
    if shell and shell.getSetting('showBusPassengers') == false then
      return false, 'turned off by the Bus Stop Passengers setting'
    end
    return true
  end

  -- Recycle the longest-idle eligible walker so a full pool does not steal an active passenger.
  local function takeWalker(stop)
    if not ensurePool(stop and stop.stripCenter, stop and stop.rng) then return nil end
    local best, bestRank
    for _, walker in ipairs(pool.walkers) do
      if walker.state == 'free' then return walker end
      local rank = walker.state == 'dispersed' and 1 or (walker.state == 'waiting' and not walker.boarder) and 2 or nil
      if rank and (not best or rank < bestRank or (rank == bestRank and walker.since < best.since)) then best, bestRank = walker, rank end
    end
    if best then release(best) end
    return best
  end

  -- ------------------------------------------------------------------------------------- stop layout
  local function fieldOf(obj, name)
    for _, getter in ipairs({'getDynDataFieldbyName', 'getField'}) do
      if obj[getter] then
        local ok, value = pcall(obj[getter], obj, name, 0)
        if ok and value ~= nil and value ~= '' then return value end
      end
    end
  end

  local function shapeMatches(shape)
    shape = string.lower(tostring(shape or ''))
    for _, wanted in ipairs(config.shelters.shapes or {}) do
      if shape:sub(-#wanted) == string.lower(wanted) then return true end
    end
    return false
  end

  -- Cast scene objects to their real class before reading mesh or field-specific methods.
  local function upcast(o)
    if not o then return nil end
    local sim = Sim
    if sim and sim.upcast then
      local ok, typed = pcall(sim.upcast, o)
      if ok and typed then return typed end
    end
    local id = (o.getId and o:getId()) or (o.getID and o:getID())
    return id and scenetree.findObjectById(id) or o
  end

  -- The nearest shelter or stop sign in the trigger's own group (the level's bus stop group).
  local function findShelter(trigger, center)
    local group = upcast(trigger.getGroup and trigger:getGroup())
    if not group or not group.getCount then return nil end
    local best, bestDist, bestBox = nil, config.shelters.radiusM, nil
    for i = 0, group:getCount() - 1 do
      local o = upcast(group:getObject(i))
      if o and o.getClassName and o:getClassName() == 'TSStatic' and o.getPosition and shapeMatches(fieldOf(o, 'shapeName')) then
        local p = vec3(o:getPosition())
        local d = (p - center):length()
        if d < bestDist then
          best, bestDist = p, d
          local ok, box = pcall(function() return o:getWorldBox() end)
          bestBox = ok and box and box.minExtents and box.maxExtents
            and {min = vec3(box.minExtents), max = vec3(box.maxExtents)} or nil
        end
      end
    end
    return best, bestBox
  end

  -- The road edge under the stop from the map's road graph: its centreline point and curb distance.
  local function findRoad(center, groundZ)
    local n1, n2, dist = map.findClosestRoad(vec3(center.x, center.y, groundZ or center.z))
    if not n1 or not n2 or (dist and dist > config.road.searchM) then return nil end
    local gp = map.getGraphpath()
    local a, b = gp and gp.positions and gp.positions[n1], gp and gp.positions and gp.positions[n2]
    if not a or not b then return nil end
    local ab = b - a
    local t = math.min(math.max((center - a):dot(ab) / math.max(ab:squaredLength(), 1e-6), 0), 1)
    local radius = (gp.radius[n1] or 0) + ((gp.radius[n2] or 0) - (gp.radius[n1] or 0)) * t
    local centre = a + ab * t
    -- an overpass or an underpass is another level: not this stop's curb
    if groundZ and math.abs(centre.z - groundZ) > config.ground.levelM then return nil end
    return {centre = centre, curb = path.sidewalkOffset(radius)}
  end

  local function sideWord(word)
    word = string.lower(tostring(word or ''))
    if word == 'right' then return 1 elseif word == 'left' then return -1 end
  end

  -- Curb rules retain their priority: explicit side, shelter, road graph, then driving side.
  local function resolveCurbSide(trigger, center, right, groundZ)
    -- A lookup that fails only skips its own curb rule.
    local function try(name, fn, ...)
      local ok, result = pcall(fn, ...)
      if ok then return result end
      log('W', 'busWalkers', name .. ' skipped at ' .. tostring(trigger.getName and trigger:getName()) .. ': ' .. tostring(result))
      return nil
    end
    local shelterOk, shelter, shelterBox = pcall(findShelter, trigger, center)
    if not shelterOk then
      log('W', 'busWalkers', 'shelter lookup skipped at ' .. tostring(trigger.getName and trigger:getName()) .. ': ' .. tostring(shelter))
      shelter, shelterBox = nil, nil
    end
    local roadInfo = try('road lookup', findRoad, center, groundZ)
    if shelter and math.abs(shelter.z - groundZ) > config.ground.levelM then shelter, shelterBox = nil, nil end -- another level
    local side = sideWord(fieldOf(trigger, 'paxSide'))
    local sideFrom = side and 'paxSide'
    if not side and shelter then
      local lateral = right:dot(shelter - center)
      if math.abs(lateral) > 0.5 then side, sideFrom = lateral > 0 and 1 or -1, 'shelter' end
    end
    if not side and roadInfo then
      local lateral = right:dot(center - roadInfo.centre)
      if math.abs(lateral) > 0.5 then side, sideFrom = lateral > 0 and 1 or -1, 'road' end
    end
    if not side then
      local level = getCurrentLevelIdentifier()
      side = sideWord(config.sideByLevel[level] or config.sideByLevel.default) or 1
      sideFrom = 'level'
    end
    return shelter, shelterBox, roadInfo, side, sideFrom
  end

  local function layoutStop(stopIndex, trigger, nextTrigger, busPos)
    local center = vec3(trigger:getPosition())
    local rot = quat(trigger:getRotation())
    local scale = trigger:getScale()
    local ax, ay = (rot * vec3(1, 0, 0)):z0(), (rot * vec3(0, 1, 0)):z0()
    local halfLen, halfWidth, road = scale.x * 0.5, scale.y * 0.5, ax
    if scale.y > scale.x then halfLen, halfWidth, road = scale.y * 0.5, scale.x * 0.5, ay end
    road = road:normalized()
    local ref = nextTrigger and (vec3(nextTrigger:getPosition()) - center) or (busPos and center - busPos)
    if ref and road:dot(ref) < 0 then road = -road end
    local right = road:cross(upDirection):normalized()

    -- Raycast below the bus's road height so an overpass cannot become this stop's curb.
    local levelFrom = busPos and busPos.z or (center.z - scale.z * 0.5)
    local below = be:getSurfaceHeightBelow(vec3(center.x, center.y, levelFrom + config.ground.bandM))
    local groundKnown = type(below) == 'number' and below > levelFrom - 50
    local groundZ = groundKnown and below or levelFrom

    local name = tostring(trigger.getName and trigger:getName() or stopIndex)
    seedCounter = seedCounter + 1
    local rng = newRng(hashText(name) + seedCounter * 7919)
    local shelter, shelterBox, roadInfo, side, sideFrom = resolveCurbSide(trigger, center, right, groundZ)
    local outward = right * side

    -- Use a nearby road curb only when it lies just outside the trigger box.
    local offset = halfWidth + rng.range(config.waiting.curbOffsetM[1], config.waiting.curbOffsetM[2])
    if roadInfo then
      local curbLine = roadInfo.centre + outward * roadInfo.curb
      local fromBox = outward:dot(curbLine - center)
      if fromBox >= halfWidth + 0.3 and fromBox <= halfWidth + 8 then offset = fromBox + rng.range(0.2, 0.8) end
    end
    local stripCenter = center + road * (halfLen * config.waiting.stripForward)
    if shelter then stripCenter = center + road * road:dot(shelter - center) end

    return {stopIndex = stopIndex, name = name, center = center, groundZ = groundZ, road = road, right = right, side = side,
      sideFrom = sideFrom, outward = outward, offset = offset, stripCenter = stripCenter, shelter = shelter, shelterBox = shelterBox,
      groundKnown = groundKnown,
      halfLen = halfLen, rng = rng, waiting = {}, boarders = {}, alighters = {}, attempt = 0}
  end

  local function stripPoint(stop, along, depth)
    local p = stop.center + stop.road * (stop.road:dot(stop.stripCenter - stop.center) + along) + stop.outward * (stop.offset + (depth or 0))
    return vec3(p.x, p.y, stop.groundZ)
  end

  -- Ground at a point, on the stop's level.
  local function ground(stop, p) return path.snapToGround(p, stop and stop.groundZ, config.ground.bandM) end

  -- Is p (horizontally) inside the stop's shelter, with a margin?
  local function inShelter(stop, p)
    local box = stop.shelterBox
    if not box then return false end
    local m = config.waiting.shelterMarginM
    return p.x > box.min.x - m and p.x < box.max.x + m and p.y > box.min.y - m and p.y < box.max.y + m
  end

  -- Require the stop's ground level and clear head space so figures avoid props and drop-offs.
  local function standable(stop, p, why)
    local walker = config.waiting
    if inShelter(stop, p) then if why then why.shelter = (why.shelter or 0) + 1 end return nil end
    -- without ground data under the stop (no collision loaded), spots sit on the stop level
    if stop.groundKnown == false then return vec3(p.x, p.y, stop.groundZ) end
    local h = path.groundAt(p, stop.groundZ, config.ground.bandM)
    if not h or math.abs(h - stop.groundZ) > walker.levelToleranceM then
      if why then why.level = (why.level or 0) + 1 why.lastH = h end
      return nil
    end
    local top = path.groundAt(vec3(p.x, p.y, h), h + walker.clearanceM * 0.5, walker.clearanceM * 0.5)
    if top and top > h + 0.1 then if why then why.blocked = (why.blocked or 0) + 1 end return nil end
    return vec3(p.x, p.y, h)
  end

  -- Try the next privately shuffled spot when a candidate is blocked; tight stops admit fewer figures.
  local function waitingSpots(stop, count)
    local walker = config.waiting
    local half = walker.stripLengthM * 0.5
    local spots, why = {}, {}
    for _ = 1, count * walker.candidates do
      if #spots >= count then break end
      local p = standable(stop, stripPoint(stop, stop.rng.range(-half, half), stop.rng.range(0, walker.depthM)), why)
      if p then
        local apart = true
        for _, q in ipairs(spots) do
          if (vec3(q.x - p.x, q.y - p.y, 0)):length() < walker.spacingM then apart = false break end
        end
        if apart then spots[#spots + 1] = p else why.crowded = (why.crowded or 0) + 1 end
      end
    end
    if #spots < count then
      info(string.format('stop %s: %d of %d waiting spots found (rejected: shelter %d, other level %d%s, blocked %d, crowded %d; stop level %.2f)',
        tostring(stop.stopIndex), #spots, count, why.shelter or 0, why.level or 0,
        why.lastH and string.format(' e.g. %.2f', why.lastH) or '', why.blocked or 0, why.crowded or 0, stop.groundZ))
    end
    return spots
  end

  -- People face the road where the bus will stop, turned a little toward where it comes from.
  local function faceRoad(stop)
    local walker = config.waiting
    local dir = (-stop.outward + -stop.road * walker.faceApproach):z0():normalized()
    local jitter = math.rad(walker.faceJitterDeg)
    return yawOf(dir) + stop.rng.range(-jitter, jitter)
  end

  local function spawnWaiting(stop)
    local count = stop.rng.int(config.waiting.min, config.waiting.max)
    local spots = waitingSpots(stop, count)
    for i = 1, #spots do
      local walker = takeWalker(stop)
      if not walker then break end
      show(walker, spots[i], faceRoad(stop), stop.rng)
      setState(walker, 'waiting')
      walker.spot, walker.spotYaw, walker.since = spots[i], walker.yaw, clock
      stop.waiting[#stop.waiting + 1] = walker
    end
  end

  -- ------------------------------------------------------------------------------------- doors
  local function nodeCids(vehId)
    local data = core_vehicle_manager.getVehicleData(vehId)
    local nodes = data and data.vdata and data.vdata.nodes
    if not nodes then return nil end
    local cids = {}
    for key, node in pairs(nodes) do
      if type(node) == 'table' and node.name then cids[node.name] = node.cid or key end
    end
    return cids
  end

  local function doorFromNodes(veh, cids, door)
    local sum, n = vec3(0, 0, 0), 0
    local base = vec3(veh:getPosition())
    for _, name in ipairs(door.nodes or {}) do
      local cid = cids[name]
      if cid == nil then return nil end
      sum = sum + base + vec3(veh:getNodePosition(cid))
      n = n + 1
    end
    return n > 0 and sum / n or nil
  end

  local function oobbDoors(vehId, veh, side)
    local c = vec3(be:getObjectOOBBCenterXYZ(vehId))
    local fwd = vec3(veh:getDirectionVector()):z0():normalized()
    local right = fwd:cross(upDirection):normalized()
    local halfLen, halfWidth = 0, 0
    for i = 0, 2 do
      local axis = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, i))
      local horizontal = axis:z0():length()
      if horizontal > 0.1 then
        local along = math.abs(axis:z0():dot(fwd))
        if along > horizontal * 0.7 then halfLen = math.max(halfLen, horizontal) else halfWidth = math.max(halfWidth, horizontal) end
      end
    end
    if halfLen <= 0 then return nil end
    local front = c + fwd * (halfLen - doorFallback.frontInsetM) + right * (side * halfWidth)
    local rear = front - fwd * (doorFallback.rearFraction * 2 * halfLen)
    return front, rear
  end

  -- World door points of the stopped bus for boarding and alighting, with the outward direction.
  local function busDoors(vehId, side)
    local veh = be:getObjectByID(vehId)
    if not veh then return nil end
    local model = veh.JBeam or (veh.getJBeamFilename and veh:getJBeamFilename())
    local def = doorModels[model]
    local board, alight
    local cids = def and nodeCids(vehId)
    if cids then
      for _, door in ipairs(def.doors or {}) do
        local p = doorFromNodes(veh, cids, door)
        if p then
          if not board and (door.role == 'board' or door.role == 'both') then board = p end
          if not alight and (door.role == 'alight' or door.role == 'both') then alight = p end
        end
      end
    end
    if not board and not alight then board, alight = oobbDoors(vehId, veh, side) end
    board, alight = board or alight, alight or board
    if not board then return nil end
    local busPos = vec3(veh:getPosition())
    local right = vec3(veh:getDirectionVector()):z0():normalized():cross(upDirection):normalized()
    local function outward(p) return right:dot(p - busPos) >= 0 and right or -right end
    return {board = board, boardOut = outward(board), alight = alight, alightOut = outward(alight)}
  end

  -- ------------------------------------------------------------------------------------- movement
  local function walkAlong(walker, points, speed, delay, nextState)
    walker.path = path.buildPath(points, nil, scene and scene.groundZ, config.ground.bandM)
    walker.dist, walker.speed, walker.delay, walker.after = 0, speed, delay or 0, nextState
    setState(walker, nextState == 'dispersed' and 'alighting' or 'boarding')
  end

  local function baseSpeed(rng)
    local walk = config.walk
    return walk.speed * (1 + rng.range(-walk.speedJitter, walk.speedJitter))
  end

  local function stepWalker(walker, dt)
    if walker.delay > 0 then
      walker.delay = walker.delay - dt
      if walker.delay > 0 then return end
      dt = -walker.delay
      walker.delay = 0
    end
    walker.dist = math.min(walker.dist + walker.speed * dt, walker.path.length)
    local pos, dir = path.sample(walker.path, walker.dist)
    if dir then
      local target = yawOf(dir)
      local diff = (target - walker.yaw + math.pi) % (2 * math.pi) - math.pi
      local maxTurn = math.rad(config.walk.turnRateDeg) * dt
      walker.yaw = walker.yaw + math.max(-maxTurn, math.min(maxTurn, diff))
    end
    walker.roll = -walker.dist / config.shapes.ballRadius
    local bob = config.walk.bobHeightM * math.sin(2 * math.pi * config.walk.bobHz * clock)
    if walker.dist >= walker.path.length then
      body.arrive(walker.h, pos, walker.yaw, walker.roll)
      walker.pos = pos
      if walker.after == 'atDoor' then
        setState(walker, 'atDoor')
      else
        -- off the bus and out of the way: stand facing the road like the people waiting
        if scene then
          walker.yaw = faceRoad(scene)
          body.arrive(walker.h, pos, walker.yaw, walker.roll)
        end
        setState(walker, 'dispersed')
        walker.since = clock
      end
      return
    end
    body.move(walker.h, pos, walker.yaw, walker.roll, bob, dir, walker.speed, dt)
    walker.pos = pos
  end

  -- Stop hooks follow the bus countdown without delaying the job for a cosmetic walker.
  local function currentStop()
    local stopIndex, trigger, nextTrigger = ctx.stop()
    if not stopIndex or not trigger or not trigger.getPosition or not trigger.getScale then return nil end
    if nextTrigger and not nextTrigger.getPosition then nextTrigger = nil end
    return stopIndex, trigger, nextTrigger
  end

  -- Every hook is guarded: a failure turns walkers off for this bus instance and never reaches the job.
  local function guard(name, fn)
    return function(...)
      if disabled or not live() then return end
      local ok, err = pcall(fn, ...)
      if not ok then
        disabled = true
        log('E', 'busWalkers', 'walking passengers turned off after an error in ' .. name .. ': ' .. tostring(err))
        pcall(releaseAll)
      end
    end
  end

  -- Every half second while the route runs: people appear at the next stop once the bus is close.
  local function poll(busPos)
    local ok, why = allowed()
    if not ok then once('off:' .. why, 'no walkers: ' .. why) return end
    once('on', 'walkers on (' .. tostring(body and body.name or config.backend) .. ' figures; Bus Stop Passengers setting on; the game seat occupant setting does not apply)')
    local stopIndex, trigger, nextTrigger = currentStop()
    if not stopIndex then
      local index, raw = ctx.stop()
      once('nostop:' .. tostring(index), 'no walkers at stop ' .. tostring(index) .. ': ' .. (raw and 'its trigger has no position or scale' or 'no stop trigger'))
      return
    end
    if not busPos then once('nobus:' .. stopIndex, 'no walkers at stop ' .. stopIndex .. ': no bus position') return end
    busPos = vec3(busPos)
    local poolAlive = pool ~= nil and body ~= nil and body.alive(pool.body)
    if scene and scene.stopIndex == stopIndex and not scene.served and poolAlive then return end
    local d = (vec3(trigger:getPosition()) - busPos):length()
    if d > config.waiting.approachM then
      once('far:' .. stopIndex, string.format('stop %d (%s): waiting people appear within %d m, the bus is %.0f m away',
        stopIndex, tostring(trigger.getName and trigger:getName()), config.waiting.approachM, d))
      return
    end
    if not poolAlive or pool.createdFrame == frame then
      -- make the figures now and show them from the next poll on, never in the frame they are made
      if not poolAlive then scene = nil end -- a vanished pool took its figures with it
      if not ensurePool(vec3(trigger:getPosition()), newRng(hashText(tostring(trigger.getName and trigger:getName())))) then return end
      info('stop ' .. stopIndex .. ': walker pool ready, waiting people appear on the next poll')
      return
    end
    releaseAll()
    scene = layoutStop(stopIndex, trigger, nextTrigger, busPos)
    spawnWaiting(scene)
    local spots = {}
    for _, walker in ipairs(scene.waiting) do spots[#spots + 1] = xyz(walker.spot) end
    info(string.format('stop %d (%s): %d waiting on the %s side (from %s) at %s; bus %.0f m away',
      stopIndex, scene.name, #scene.waiting, scene.side == 1 and 'right' or 'left', tostring(scene.sideFrom),
      table.concat(spots, ' '), d))
  end

  local function currentScene(vehId)
    local stopIndex, trigger, nextTrigger = currentStop()
    if not stopIndex then return nil end
    if scene and scene.stopIndex == stopIndex and not scene.served then return scene end
    releaseAll()
    local veh = be:getObjectByID(vehId)
    scene = layoutStop(stopIndex, trigger, nextTrigger, veh and vec3(veh:getPosition()))
    return scene
  end

  -- The countdown started: the boarders set off so each reaches the door as its tick ends.
  local function stopStarted(vehId, leaving, boarding, tick)
    if not allowed() then return end
    local stop = currentScene(vehId)
    if not stop then return end
    stop.inStop, stop.attempt = true, stop.attempt + 1
    stop.doors = busDoors(vehId, stop.side)
    if not stop.doors then info('stop ' .. tostring(stop.stopIndex) .. ': no door points for this bus, nobody walks') return end
    info(string.format('stop %d: countdown, %d leaving, %d boarding, %d waiting; doors board %s alight %s',
      stop.stopIndex, leaving, boarding, #stop.waiting, xyz(stop.doors.board), xyz(stop.doors.alight)))
    local boardStep = ground(stop, stop.doors.board + stop.doors.boardOut * math.max(config.door.stepM, body.doorGapM))
    local approach = stop.doors.board + stop.doors.boardOut * config.door.approachM
    local candidates = {}
    for _, walker in ipairs(stop.waiting) do if walker.state == 'waiting' then candidates[#candidates + 1] = walker end end
    table.sort(candidates, function(a, b) return (a.spot - boardStep):length() < (b.spot - boardStep):length() end)
    stop.boarders = {}
    for i = 1, math.min(boarding, #candidates) do
      local walker = candidates[i]
      local route = path.buildPath({walker.spot, approach, boardStep}, nil, stop.groundZ, config.ground.bandM)
      local arrive = math.max(tick * (leaving + i) - config.door.arriveEarlyS, 0.1)
      local speed = baseSpeed(stop.rng)
      local start = arrive - route.length / speed
      if start < 0 then
        start = 0
        speed = math.min(config.walk.maxSpeed, route.length / math.max(arrive, 0.1))
      end
      walker.boarder = i
      walkAlong(walker, route.points, speed, start, 'atDoor')
      stop.boarders[i] = walker
    end
  end

  -- A seat emptied: that passenger steps out of the alighting door and walks off along the curb.
  local function spawnAlighter(stop, delay)
    if not stop or not stop.doors then return end
    local walker = takeWalker(stop)
    if not walker then return end
    local doors = stop.doors
    local step = doors.alight + doors.alightOut * math.max(config.door.stepM, body.doorGapM)
    local out = doors.alight + doors.alightOut * config.alight.outM
    -- a standable spot along the curb behind the door (outside the shelter, on the stop's level)
    local dispersal
    for _ = 1, config.waiting.candidates do
      local along = stop.road:dot(doors.alight - stop.stripCenter) - stop.rng.range(config.alight.dispersalM[1], config.alight.dispersalM[2])
      local p = stripPoint(stop, along, stop.rng.range(0, config.waiting.depthM))
      dispersal = standable(stop, p)
      if dispersal then break end
      dispersal = p -- the last try stands in when no candidate is free
    end
    show(walker, ground(stop, step), yawOf(doors.alightOut), stop.rng)
    walker.attempt = stop.attempt
    walkAlong(walker, {step, out, dispersal}, baseSpeed(stop.rng), delay, 'dispersed')
    stop.alighters[#stop.alighters + 1] = walker
  end

  local function passengerLeft()
    if scene and scene.inStop then spawnAlighter(scene, 0) end
  end

  -- A seat filled: that passenger is inside. A late walker is taken in anyway.
  local function passengerBoarded(i)
    local walker = scene and scene.boarders[i]
    if walker and walker.boarder == i and walker.state ~= 'inside' then
      setHidden(walker, true)
      setState(walker, 'inside')
    end
  end

  -- The stop committed: the boarders are passengers now and their figures go back to the pool.
  local function stopEnded()
    if not scene then return end
    for _, walker in pairs(scene.boarders) do if walker.boarder then release(walker) end end
    scene.boarders, scene.inStop, scene.served = {}, false, true
  end

  -- The last stop of a loop or shift: everyone gets off at once, a few at a time through the door.
  local function finalDrop(vehId, count)
    if count <= 0 or not allowed() then return end
    local stop = currentScene(vehId)
    if not stop then return end
    stop.attempt = stop.attempt + 1
    stop.doors = busDoors(vehId, stop.side)
    for k = 1, math.min(count, config.finalStop.maxWalkers) do spawnAlighter(stop, (k - 1) * config.finalStop.staggerS) end
    stop.served = true
  end

  -- The stop was interrupted: the boarders are back where they waited, the leavers never left.
  local function stopCancelled()
    if not scene or not scene.inStop then return end
    for _, walker in pairs(scene.boarders) do
      if walker.boarder then
        setState(walker, 'waiting')
        walker.yaw, walker.roll, walker.boarder, walker.path = walker.spotYaw, 0, nil, nil
        place(walker, walker.spot)
        setHidden(walker, paused) -- after placing (a vehicle body wakes up to be placed): hidden while the driver is out
      end
    end
    for _, walker in ipairs(scene.alighters) do
      if walker.attempt == scene.attempt and walker.state ~= 'free' then release(walker) end
    end
    scene.boarders, scene.alighters, scene.inStop = {}, {}, false
  end

  -- Per frame: only moving walkers are touched; with nobody visible this returns at once.
  local function update(dt)
    frame = frame + 1
    if next(fresh) then
      for walker, left in pairs(fresh) do
        if walker.state ~= 'free' and walker.state ~= 'inside' and walker.pos and not MOVING[walker.state] then place(walker, walker.pos) end
        fresh[walker] = left > 1 and left - 1 or nil
      end
    end
    if visible == 0 then return end
    dt = dt or 0
    if paused then
      -- nothing moves or shows while the driver is out; the setting still takes effect
      pollTimer = pollTimer + dt
      if pollTimer >= 0.5 then
        pollTimer = 0
        if not allowed() then releaseAll() end
      end
      return
    end
    clock = clock + dt
    if moving > 0 then
      for _, walker in ipairs(pool.walkers) do
        if MOVING[walker.state] then stepWalker(walker, dt) end
      end
    end
    pollTimer = pollTimer + dt
    if pollTimer < 0.5 then return end
    pollTimer = 0
    if not allowed() then releaseAll() return end -- the player turned them off
    if scene and not scene.inStop then
      local veh = be:getPlayerVehicle(0)
      local far = not veh or (vec3(veh:getPosition()) - scene.center):length() > config.waiting.hideM
      if far then releaseAll() end
    end
  end

  local function hide() releaseAll() end

  -- Pause visuals with the roleplay countdown and restore the same path on resume.
  local function pause()
    if paused or not scene then return end
    paused = true
    for _, walker in ipairs(pool and pool.walkers or {}) do if SHOWN[walker.state] then setHidden(walker, true) end end
  end

  local function resume()
    if not paused then return end
    paused = false
    if not allowed() then releaseAll() return end
    for _, walker in ipairs(pool and pool.walkers or {}) do if SHOWN[walker.state] then setHidden(walker, false) end end
  end

  -- Deletes this instance's own objects only.
  local function destroy()
    scene = nil
    visible, moving, paused = 0, 0, false
    table.clear(fresh) -- refresh work belongs to the figures being deleted (and to this backend)
    if pool then body.destroy(pool.body) end
    pool = nil
  end

  local function createApi()
    local api = {
      poll = guard('poll', poll), update = guard('update', update),
      stopStarted = guard('stopStarted', stopStarted), passengerLeft = guard('passengerLeft', passengerLeft),
      passengerBoarded = guard('passengerBoarded', passengerBoarded), stopEnded = guard('stopEnded', stopEnded),
      finalDrop = guard('finalDrop', finalDrop), stopCancelled = guard('stopCancelled', stopCancelled),
      hide = guard('hide', hide), pause = guard('pause', pause), resume = guard('resume', resume),
    }
    -- Cleanup always runs, even after an error turned walkers off.
    api.destroy = function()
      local ok, err = pcall(destroy)
      if not ok then log('E', 'busWalkers', tostring(err)) end
    end
    api.sweep = function() pcall(sweep) end
    -- The owning bus extension is going away: nothing of this instance runs again except destroy.
    api.retire = function() retired = true end
    -- Drop only this instance's pool before the next-use configuration reload.
    api.reload = function()
      api.destroy()
      config, body, disabled = nil, nil, false
    end
    -- The diagnostic figure bypasses route and settings while retaining owned-pool cleanup.
    api.debugSpawn = function(pos, yaw)
      if not live() then return {error = 'this bus instance was replaced'} end
      loadData()
      local walker = takeWalker()
      if not walker then return {error = 'no walker pool (see the log)'} end
      local rng = newRng(os.time())
      show(walker, path.snapToGround(vec3(pos)), yaw or 0, rng)
      setState(walker, 'dispersed')
      walker.since = clock
      local ids = body.ids(walker.h)
      local o = ids.bodyId and scenetree.findObjectById(ids.bodyId)
      local out = {bodyId = ids.bodyId, ballId = ids.ballId, pos = xyz(walker.pos), backend = body.name, shape = config.shapes.body,
        hidden = o and o.hidden, materials = scenetree.findObject('character_primary') ~= nil}
      info('debug walker at ' .. out.pos .. ' (body ' .. tostring(out.bodyId) .. ', materials loaded ' .. tostring(out.materials) .. ')')
      return out
    end
    -- Read-only views for tests and scenarios.
    api.state = function()
      local out = {visible = visible, moving = moving, disabled = disabled, paused = paused, retired = retired,
        backend = body and body.name, poolId = pool and body.poolId(pool.body), scene = scene and {
        stopIndex = scene.stopIndex, side = scene.side, sideFrom = scene.sideFrom, served = scene.served, inStop = scene.inStop,
        waiting = #scene.waiting, boarders = tableSize(scene.boarders), alighters = #scene.alighters} or nil, walkers = {}}
      for i, walker in ipairs(pool and pool.walkers or {}) do
        local ids = body.ids(walker.h)
        local actual = body.position(walker.h)
        out.walkers[i] = {state = walker.state, bodyId = ids.bodyId, ballId = ids.ballId, boarder = walker.boarder,
          pos = walker.pos and vec3(walker.pos) or nil, actual = actual and vec3(actual) or nil}
      end
      return out
    end
    return api
  end
  return createApi()
end
