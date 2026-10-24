-- Racer staging-plan execution, pool spawning and live power matching.
-- Read spawn primitives, ordered proxy/matched/fallback phases and the public staging entry points.
local lib = {}

function lib.create(ownerServices)
  local M = ownerServices.M
  local DEFAULT_CONFIG = ownerServices.DEFAULT_CONFIG
  local PROXY_BRACKET_SOFT_PW_BELOW_PLAYER = ownerServices.PROXY_BRACKET_SOFT_PW_BELOW_PLAYER
  local racerState = ownerServices.racerState

  -- Execute a staging plan: pool rows { model, config, matchPw? }. Config path uses merged race subdir when basename-only.
  local function initializeSpawnedRacer(vehId, cfg)
    pcall(function()
      ownerServices.parts.config.applyAiBasePaintOnly(vehId, ownerServices.parts.config.pickRandomAiColor())
    end)
    local vehObj = be:getObjectByID(vehId)
    if vehObj then
      vehObj:queueLuaCommand("if not overhaulDriver then extensions.load('overhaulDriver') end")
      -- race* parameters require overhaulAi to be installed explicitly.
      if overhaul_shell_extensionManager and overhaul_shell_extensionManager.applyOverrideAI then
        overhaul_shell_extensionManager.applyOverrideAI(vehId)
      else
        vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
      end
      vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
      vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
      if cfg.startEngineOnSpawn ~= false then racerState.queueEngineStart(vehObj) end
    end
  end

  local function spawnStagingPlan(raceName, race, facilityName, slotPlan)
    local cfg = ownerServices.parts.config.getMergedConfigForRace(race, raceName)
    if cfg.enabled == false then return 0 end
    if type(slotPlan) ~= "table" or #slotPlan == 0 then return 0 end
    racerState.cancelDelayedDespawn()
    local spots = ownerServices.parts.config.loadStagingSpots(race, raceName)
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local n = math.max(0, math.min(#spots, requestedCount, #slotPlan))
    if n <= 0 then return 0 end

    local spawned = 0
    local spawnedLineup = {}
    for i = 1, n do
      local spec = slotPlan[i]
      local spot = spots[i]
      if spec and spot and spot.pos and spot.rot then
        local modelKey, configForSpawn
        if
          type(spec.model) == "string"
          and spec.model ~= ""
          and type(spec.config) == "string"
          and spec.config ~= ""
        then
          modelKey = spec.model
          local rel = ownerServices.parts.config.poolConfigRelPathForSpawn(spec, modelKey, spec.config, cfg)
          if rel then configForSpawn = "vehicles/" .. modelKey .. "/" .. rel .. ".pc" end
        end
        if modelKey and configForSpawn then
          local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
          local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
          local spawnOptions = { pos = pos, rot = rot, config = configForSpawn, autoEnterVehicle = false }
          local ok, veh = pcall(function()
            return core_vehicles.spawnNewVehicle(modelKey, spawnOptions)
          end)
          if ok and veh and veh.getID then
            local vehId = veh:getID()
            table.insert(racerState.mSpawnedAiVehicleIds, vehId)
            racerState.mEverSpawnedAiVehicleIdsSweep[vehId] = true
            spawned = spawned + 1
            table.insert(spawnedLineup, {
              model = modelKey,
              config = spec.config or "default",
              matchPw = tonumber(spec.matchPw) or tonumber(spec.powerHp) or nil,
            })
            initializeSpawnedRacer(vehId, cfg)
          end
        end
      end
    end
    ownerServices.parts.config.setLastSpawnedLineupSnapshot(spawnedLineup)
    return spawned
  end

  local function buildCircularPlanFromPoolRows(avail, requestedCount)
    local plan = {}
    if type(avail) ~= "table" or #avail == 0 or type(requestedCount) ~= "number" or requestedCount < 1 then
      return plan
    end
    for i = 1, requestedCount do
      local r = avail[((i - 1) % #avail) + 1]
      local model = type(r) == "table" and (r.model or r.vehicleModel) or nil
      local config = type(r) == "table" and r.config or nil
      if type(model) == "string" and type(config) == "string" and config ~= "" then
        plan[#plan + 1] = {
          model = model,
          config = config,
          matchPw = ownerServices.parts.planner.getMatchPwForPoolEntry(r, model, config),
        }
      end
    end
    return plan
  end

  -- Last-resort: spawn from first non-empty vehiclePool tier (subdir-prefixed when merged). Returns spawned count.
  local function spawnFromStructuredPoolLastResort(raceName, race, facilityName, cfg, requestedCount)
    if type(cfg) ~= "table" or type(cfg.vehiclePool) ~= "table" then return 0 end
    local merged = ownerServices.parts.planner.mergeVehiclePoolFromFirstAvailableTier(cfg.vehiclePool)
    local avail = ownerServices.parts.planner.filterVehiclePoolToAvailable(merged)
    if #avail == 0 then return 0 end
    local plan = buildCircularPlanFromPoolRows(avail, requestedCount)
    if #plan == 0 then return 0 end
    return spawnStagingPlan(raceName, race, facilityName, plan)
  end

  -- Pick N entries from class pool: sort by closest power to playerHp, then one per model first, then fill. Random among ties. Returns list of { model, config }.
  local function decoratePoolWithPower(classPool, playerPowerHp)
    local withPower = {}
    for _, entry in ipairs(classPool) do
      local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
      local config = type(entry) == "table" and entry.config or nil
      if type(model) == "string" and type(config) == "string" then
        local hp = ownerServices.parts.planner.getPowerForModelConfig(model, config)
        if type(hp) == "number" and hp > 0 then
          table.insert(withPower, { model = model, config = config, powerHp = hp })
        else
          table.insert(withPower, { model = model, config = config, powerHp = playerPowerHp or 200 })
        end
      end
    end
    return withPower
  end

  local function pickVehiclePoolByClosestWithVariety(classPool, playerPowerHp, requestedCount)
    if type(classPool) ~= "table" or #classPool == 0 or type(requestedCount) ~= "number" or requestedCount < 1 then
      return {}
    end
    local withPower = decoratePoolWithPower(classPool, playerPowerHp)
    if #withPower == 0 then return {} end
    local ph = type(playerPowerHp) == "number" and playerPowerHp or 200
    for i = #withPower, 2, -1 do
      local j = math.random(1, i)
      withPower[i], withPower[j] = withPower[j], withPower[i]
    end
    table.sort(withPower, function(a, b)
      local ahp = a.powerHp or ph
      local bhp = b.powerHp or ph
      local da = math.abs(ahp - ph)
      local db = math.abs(bhp - ph)
      local aClose = da <= ownerServices.parts.planner.CLOSE_HP_TOLERANCE
      local bClose = db <= ownerServices.parts.planner.CLOSE_HP_TOLERANCE
      if aClose and not bClose then return true end
      if not aClose and bClose then return false end
      if aClose and bClose then return da < db end
      -- After "within 25 HP": prefer next closest but always higher (power >= player), then below player by closest
      local aAbove = ahp >= ph
      local bAbove = bhp >= ph
      if aAbove and not bAbove then return true end
      if not aAbove and bAbove then return false end
      if aAbove and bAbove then return (ahp - ph) < (bhp - ph) end
      return da < db
    end)
    local picked = {}
    local usedModel = {}
    for _, e in ipairs(withPower) do
      if not usedModel[e.model] then
        usedModel[e.model] = true
        table.insert(picked, { model = e.model, config = e.config })
        if #picked >= requestedCount then return picked end
      end
    end
    for _, e in ipairs(withPower) do
      if #picked >= requestedCount then break end
      local already = 0
      for _, p in ipairs(picked) do
        if p.model == e.model then already = already + 1 end
      end
      if already < 2 then table.insert(picked, { model = e.model, config = e.config }) end
    end
    while #picked < requestedCount and #withPower > 0 do
      table.insert(picked, { model = withPower[1].model, config = withPower[1].config })
    end
    return picked
  end

  local function pickRandomVehicleModel(pool)
    if type(pool) ~= "table" or #pool == 0 then return DEFAULT_CONFIG.defaultVehiclePool[1] end
    local pick = pool[math.random(1, #pool)]
    if type(pick) == "table" then return pick.model or pick.vehicleModel or DEFAULT_CONFIG.defaultVehiclePool[1] end
    return pick
  end

  -- Internal: spawn AI using model-only pool keys; config path uses aiRaceConfigSubdir (merged cfg) or rls_race_ai/default.pc.
  local function spawnAvailablePoolCandidate(pool, maxRetries, subdir, pos, rot)
    local veh = nil
    local chosenModel = nil
    local chosenRel = nil
    local candidates = {}
    local seen = {}
    for _ = 1, maxRetries do
      local model = pickRandomVehicleModel(pool)
      if model and not seen[model] then
        seen[model] = true
        candidates[#candidates + 1] = model
      end
    end
    for _, model in ipairs(candidates) do
      local rel = (subdir ~= "" and (subdir .. "/default")) or "default"
      local configPath = "vehicles/" .. model .. "/" .. rel .. ".pc"
      local spawnOptions = { pos = pos, rot = rot, config = configPath, autoEnterVehicle = false }
      local ok, result = pcall(function()
        return core_vehicles.spawnNewVehicle(model, spawnOptions)
      end)
      if ok and result and result.getID then
        veh = result
        chosenModel = model
        chosenRel = rel
        break
      end
    end
    return veh, chosenModel, chosenRel, candidates
  end

  local function spawnWithPool(raceName, race, facilityName, rawPool, spawnCfg)
    local cfg = (type(spawnCfg) == "table" and spawnCfg) or ownerServices.parts.config.getMergedConfigForRace(race, raceName)
    if cfg.enabled == false then return 0 end
    racerState.cancelDelayedDespawn()
    local spots = ownerServices.parts.config.loadStagingSpots(race, raceName)
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local spawnCount = math.max(0, math.min(#spots, requestedCount))
    if spawnCount <= 0 then return 0 end
    local pool = ownerServices.parts.planner.filterPoolToAvailableModels(rawPool or cfg.defaultVehiclePool)
    local subdir = ownerServices.parts.config.aiRaceConfigSubdirForFallbackSpawn(cfg)
    local spawned = 0
    local spawnedLineup = {}
    local maxRetries = 3
    for i = 1, spawnCount do
      local spot = spots[i]
      if spot and spot.pos and spot.rot then
        local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
        local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
        local veh, chosenModel, chosenRel, candidates = spawnAvailablePoolCandidate(pool, maxRetries, subdir, pos, rot)
        if veh then
          local vehId = veh:getID()
          table.insert(racerState.mSpawnedAiVehicleIds, vehId)
          racerState.mEverSpawnedAiVehicleIdsSweep[vehId] = true
          spawned = spawned + 1
          table.insert(
            spawnedLineup,
            { model = chosenModel or candidates[1] or "unknown", config = chosenRel or "default" }
          )
          initializeSpawnedRacer(vehId, cfg)
        end
      end
    end
    ownerServices.parts.config.setLastSpawnedLineupSnapshot(spawnedLineup)
    return spawned
  end

  -- Internal: spawn AI at staging spots using a pre-ordered list of { model, config }. One entry per spot. Returns spawned count.
  local function spawnWithModelConfigList(raceName, race, facilityName, list)
    local cfg = ownerServices.parts.config.getMergedConfigForRace(race, raceName)
    if cfg.enabled == false then return 0 end
    if type(list) ~= "table" or #list == 0 then return 0 end
    racerState.cancelDelayedDespawn()
    local spots = ownerServices.parts.config.loadStagingSpots(race, raceName)
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local spawnCount = math.max(0, math.min(#spots, requestedCount, #list))
    if spawnCount <= 0 then return 0 end
    local spawned = 0
    local spawnedLineup = {}
    for i = 1, spawnCount do
      local spot = spots[i]
      local entry = list[i]
      if spot and spot.pos and spot.rot and entry and entry.model and entry.config then
        local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
        local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
        local rel = ownerServices.parts.config.poolConfigRelPathForSpawn(entry, entry.model, entry.config, cfg) or entry.config
        local configPath = "vehicles/" .. entry.model .. "/" .. rel .. ".pc"
        local spawnOptions = { pos = pos, rot = rot, config = configPath, autoEnterVehicle = false }
        local ok, veh = pcall(function()
          return core_vehicles.spawnNewVehicle(entry.model, spawnOptions)
        end)
        if ok and veh and veh.getID then
          local vehId = veh:getID()
          table.insert(racerState.mSpawnedAiVehicleIds, vehId)
          racerState.mEverSpawnedAiVehicleIdsSweep[vehId] = true
          spawned = spawned + 1
          table.insert(spawnedLineup, {
            model = tostring(entry.model),
            config = tostring(rel),
            matchPw = tonumber(entry.matchPw) or tonumber(entry.powerHp) or nil,
          })
          pcall(function()
            ownerServices.parts.config.applyAiBasePaintOnly(vehId, ownerServices.parts.config.pickRandomAiColor())
          end)
          local vehObj = be:getObjectByID(vehId)
          if vehObj then
            vehObj:queueLuaCommand("if not overhaulDriver then extensions.load('overhaulDriver') end")
            -- race* parameters require overhaulAi to be installed explicitly.
            if overhaul_shell_extensionManager and overhaul_shell_extensionManager.applyOverrideAI then
              overhaul_shell_extensionManager.applyOverrideAI(vehId)
            else
              vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
            end
            vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
            vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
            if cfg.startEngineOnSpawn ~= false then racerState.queueEngineStart(vehObj) end
          end
        end
      end
    end
    ownerServices.parts.config.setLastSpawnedLineupSnapshot(spawnedLineup)
    return spawned
  end

  -- Spawn AI vehicles at AI staging spots for this facility/race. They remain stopped until releaseAndDrive().
  function M.spawnForStaging(raceName, race, facilityName)
    local cfg = ownerServices.parts.config.getMergedConfigForRace(race, raceName)
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    if type(cfg.vehiclePool) == "table" then
      local n = spawnFromStructuredPoolLastResort(raceName, race, facilityName, cfg, requestedCount)
      if n > 0 then return n end
    end
    local rawPool = ownerServices.parts.config.getVehiclePoolForRace(raceName, race, facilityName, cfg)
    return spawnWithPool(raceName, race, facilityName, rawPool, cfg)
  end

  local MAX_POOL_REFERENCE_PW = 3.6 -- ignore mistaken crank-HP values passed where hp/kg is expected (~0.05–1.2 typical; modded higher)

  local function resolveCloseAbovePw(cfg)
    local cap = tonumber(cfg.aiPoolCloseAbovePw)
    if cap and cap > 0 then return cap end
    local leg = tonumber(cfg.aiPoolCloseAboveHp)
    if leg and leg > 10 then
      -- Legacy aiPoolCloseAboveHp (HP): old hp/lb heuristic was leg/2700; ×2.2046226218 → same window in hp/kg.
      return (leg / 2700) * 2.2046226218
    end
    return tonumber(DEFAULT_CONFIG.aiPoolCloseAbovePw) or 0.0617
  end

  -- request: { raceName, race, facilityName, cfg, callback, poolReferenceHpMin, sanctionedSpawnCtx }, built once per
  -- spawnForStagingWithPlayerHp call and passed to spawnFromPlayerPw on every path.
  local function resolveProxyBracketMaximum(sanctionedSpawnCtx, playerPowerToWeight, bmin, bmax)
    local skillT = 1
    if type(sanctionedSpawnCtx) == "table" and sanctionedSpawnCtx.racingTeamProxyAiDifficultyT ~= nil then
      skillT = tonumber(sanctionedSpawnCtx.racingTeamProxyAiDifficultyT) or 1
    end
    skillT = math.max(0, math.min(1, skillT))
    local span = bmax - bmin
    local effectiveBmax = bmax
    if span > 0 then
      if playerPowerToWeight > 0 then
        local softCap = math.max(bmin, math.min(bmax, playerPowerToWeight - PROXY_BRACKET_SOFT_PW_BELOW_PLAYER))
        effectiveBmax = softCap + (bmax - softCap) * skillT
      else
        local frac = 0.2 + 0.8 * skillT
        effectiveBmax = bmin + span * frac
      end
      effectiveBmax = math.max(bmin, math.min(bmax, effectiveBmax))
    end
    return effectiveBmax
  end

  local function trySpawnProxyBracket(request, playerPowerToWeight, requestedCount, powerDbg)
    local raceName, race, facilityName = request.raceName, request.race, request.facilityName
    local cfg, callback = request.cfg, request.callback
    local sanctionedSpawnCtx = request.sanctionedSpawnCtx
    local bracketOnly = type(sanctionedSpawnCtx) == "table" and sanctionedSpawnCtx.racingTeamProxyBracketOnlyAi == true
    local bmin = bracketOnly and (tonumber(sanctionedSpawnCtx.classPwMin) or tonumber(sanctionedSpawnCtx.classHpMin))
      or nil
    local bmax = bracketOnly and (tonumber(sanctionedSpawnCtx.classPwMax) or tonumber(sanctionedSpawnCtx.classHpMax))
      or nil
    if bracketOnly and bmin and bmax and bmax > 0 and bmin > 0 and bmax >= bmin then
      local effectiveBmax = resolveProxyBracketMaximum(sanctionedSpawnCtx, playerPowerToWeight, bmin, bmax)
      if type(cfg.vehiclePool) == "table" then
        local merged = ownerServices.parts.planner.mergeVehiclePoolFromFirstAvailableTier(cfg.vehiclePool)
        local availableBase = ownerServices.parts.planner.filterVehiclePoolToAvailable(merged)
        local available = ownerServices.parts.planner.filterPoolByBracketMin(availableBase, bmin)
        available = ownerServices.parts.planner.filterPoolByBracketMax(available, effectiveBmax)
        if #available > 0 then
          local plan = ownerServices.parts.planner.buildBracketMaxBiasedPlan(available, bmin, effectiveBmax, requestedCount)
          if #plan > 0 then
            local spawned = spawnStagingPlan(raceName, race, facilityName, plan)
            if ownerServices.parts.config.aiSpawnDebugEnabled(cfg) then
              ownerServices.parts.config.showAiSpawnDebugUi(cfg, ownerServices.parts.planner.buildStagingSpawnDebugLinesFromPlan(powerDbg, plan))
            end
            callback(spawned)
            return true
          end
        end
      end
      if ownerServices.parts.config.aiSpawnDebugEnabled(cfg) then
        ownerServices.parts.config.showAiSpawnDebugUi(cfg, {
          "racing team proxy: bracket pool empty — falling through to main pool spawn",
          string.format("effectiveBmax=%s (bracket %s–%s)", tostring(effectiveBmax), tostring(bmin), tostring(bmax)),
        })
      end
    end

    return false
  end

  local function selectPowerMatchedPlan(availablePw, available, effectivePowerToWeight, requestedCount, cfg, sanctionedBracketMax, businessSanctionedOffer, closeAbove, minimumPowerToWeight)
    local plan = ownerServices.parts.planner.buildNearestRandomVarietyPlan(
      availablePw,
      effectivePowerToWeight,
      requestedCount,
      cfg,
      sanctionedBracketMax
    )
    if #plan == 0 then
      if businessSanctionedOffer then
        plan = select(
          1,
          ownerServices.parts.planner.buildBusinessSanctionedPlan(
            available,
            effectivePowerToWeight,
            requestedCount,
            closeAbove,
            sanctionedBracketMax
          )
        )
      else
        plan = select(
          1,
          ownerServices.parts.planner.buildCloseAbovePlan(
            available, effectivePowerToWeight, requestedCount, closeAbove, sanctionedBracketMax
          )
        )
      end
    end
    if businessSanctionedOffer and #plan == 0 then
      local tierClass = ownerServices.parts.planner.getClassFromHpForVehiclePool(effectivePowerToWeight)
      local strictPlan = ownerServices.parts.planner.buildStrictClassFallbackPlanFromVehiclePool(
        cfg,
        tierClass,
        requestedCount,
        minimumPowerToWeight,
        sanctionedBracketMax
      )
      if #strictPlan > 0 then plan = strictPlan end
    end
    return plan
  end

  local function trySpawnPowerMatchedPool(request, playerPowerToWeight, minimumPowerToWeight, requestedCount, closeAbove, businessSanctionedOffer, sanctionedBracketMax, powerDbg)
    local raceName, race, facilityName = request.raceName, request.race, request.facilityName
    local cfg, callback = request.cfg, request.callback
    local sanctionedSpawnCtx = request.sanctionedSpawnCtx
    if type(cfg.vehiclePool) == "table" and type(cfg.vehiclePool.stock) == "table" then
      local effectivePowerToWeight = playerPowerToWeight
      if effectivePowerToWeight <= 0 and type(sanctionedSpawnCtx) == "table" then
        local hi = tonumber(sanctionedSpawnCtx.classPwMax) or tonumber(sanctionedSpawnCtx.classHpMax)
        if hi and hi > 0 then effectivePowerToWeight = hi end
      end
      if effectivePowerToWeight > 0 then
        local startClass = ownerServices.parts.planner.getClassFromHpForVehiclePool(effectivePowerToWeight)
        local merged = ownerServices.parts.planner.mergeVehiclePoolFromClassUpward(cfg.vehiclePool, startClass)
        local availableBase = ownerServices.parts.planner.filterVehiclePoolToAvailable(merged)
        local available = ownerServices.parts.planner.filterPoolByBracketMin(availableBase, minimumPowerToWeight)
        if #available == 0 then available = availableBase end
        if sanctionedBracketMax then
          available = ownerServices.parts.planner.filterPoolByBracketMax(available, sanctionedBracketMax, true)
        end
        if #available > 0 then
          local availablePw = ownerServices.parts.planner.filterPoolByPowerWeight(available, effectivePowerToWeight, cfg)
          if type(availablePw) ~= "table" or #availablePw == 0 then availablePw = available end
          local plan = selectPowerMatchedPlan(availablePw, available, effectivePowerToWeight, requestedCount,
            cfg, sanctionedBracketMax, businessSanctionedOffer, closeAbove, minimumPowerToWeight)
          if #plan > 0 then
            local spawned = spawnStagingPlan(raceName, race, facilityName, plan)
            if ownerServices.parts.config.aiSpawnDebugEnabled(cfg) then
              ownerServices.parts.config.showAiSpawnDebugUi(cfg, ownerServices.parts.planner.buildStagingSpawnDebugLinesFromPlan(powerDbg, plan))
            end
            callback(spawned)
            return true
          end
        end
      end
    end
    return false
  end

  local function spawnPowerMatchedFallback(request, playerPowerToWeight, minimumPowerToWeight, requestedCount, sanctionedBracketMax, powerDbg)
    local raceName, race, facilityName = request.raceName, request.race, request.facilityName
    local cfg, callback = request.cfg, request.callback
    local spawned = spawnFromStructuredPoolLastResort(raceName, race, facilityName, cfg, requestedCount)
    if spawned <= 0 then
      local class = ownerServices.parts.planner.getDcbaClassFromPlayerPw(playerPowerToWeight)
      local rawPool = ownerServices.parts.planner.getVehiclePoolForHpClass(cfg, class)
      local pool = ownerServices.parts.planner.filterPoolByPowerWeight(rawPool, playerPowerToWeight, cfg)
      pool = ownerServices.parts.planner.filterPoolByBracketMin(pool, minimumPowerToWeight)
      if type(pool) ~= "table" or #pool == 0 then
        pool = ownerServices.parts.planner.filterPoolByPowerWeight(rawPool, playerPowerToWeight, cfg)
      end
      if type(pool) ~= "table" or #pool == 0 then pool = rawPool end
      if sanctionedBracketMax then
        local capped = ownerServices.parts.planner.filterPoolByBracketMax(pool, sanctionedBracketMax, true)
        if #capped > 0 then
          pool = capped
        else
          local wide = ownerServices.parts.planner.filterPoolByBracketMin(rawPool, minimumPowerToWeight)
          capped = ownerServices.parts.planner.filterPoolByBracketMax(wide, sanctionedBracketMax, true)
          if #capped > 0 then pool = capped end
        end
      end
      spawned = spawnWithPool(raceName, race, facilityName, pool, cfg)
    end
    if ownerServices.parts.config.aiSpawnDebugEnabled(cfg) then
      ownerServices.parts.config.showAiSpawnDebugUi(
        cfg, ownerServices.parts.planner.buildStagingSpawnDebugLinesFromRecentSpawned(powerDbg, spawned)
      )
    end
    callback(spawned)
  end

  local function spawnFromPlayerPw(request, playerPw, powerDbg)
    local race = request.race
    local cfg = request.cfg
    local poolReferenceMinimumPowerToWeight, sanctionedSpawnCtx = request.poolReferenceHpMin, request.sanctionedSpawnCtx
    powerDbg = type(powerDbg) == "table" and powerDbg or {}
    local playerPowerToWeight = type(playerPw) == "number" and playerPw or 0
    local minimumPowerToWeight = type(poolReferenceMinimumPowerToWeight) == "number"
        and poolReferenceMinimumPowerToWeight > 0
        and poolReferenceMinimumPowerToWeight
      or nil
    if minimumPowerToWeight and minimumPowerToWeight > MAX_POOL_REFERENCE_PW then minimumPowerToWeight = nil end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 4
    local closeAbove = resolveCloseAbovePw(cfg)
    local businessSanctionedOffer = type(sanctionedSpawnCtx) == "table"
      and sanctionedSpawnCtx.racingTeamBusinessOffer == true

    if trySpawnProxyBracket(request, playerPowerToWeight, requestedCount, powerDbg) then return end
    local sanctionedBracketMax = nil
    if businessSanctionedOffer and type(sanctionedSpawnCtx) == "table" then
      local sm = tonumber(sanctionedSpawnCtx.classPwMax) or tonumber(sanctionedSpawnCtx.classHpMax)
      if sm and sm > 0 then sanctionedBracketMax = sm end
    end

    if trySpawnPowerMatchedPool(request, playerPowerToWeight, minimumPowerToWeight, requestedCount,
      closeAbove, businessSanctionedOffer, sanctionedBracketMax, powerDbg) then return end
    spawnPowerMatchedFallback(request, playerPowerToWeight, minimumPowerToWeight, requestedCount,
      sanctionedBracketMax, powerDbg)
  end

  -- Use the staging hp/kg resolver before live refresh; legacy hp-named arguments remain caller-facing.
  local function resolvePlayerPwFromStagingUi()
    if type(M.getPlayerVehiclePwForStagingUi) ~= "function" then return nil, nil end
    return M.getPlayerVehiclePwForStagingUi()
  end

  local function completePowerMatchedRequest(request, poolReferencePowerToWeight, powerWatts, weight)
    local sanctionedSpawnCtx = request.sanctionedSpawnCtx
      local powerHp = (type(powerWatts) == "number" and powerWatts > 0)
        and ownerServices.parts.planner.powerWattsToHp(powerWatts) or nil
      local wkg = tonumber(weight)
      local playerPw = (powerHp and wkg and wkg > 0) and ownerServices.parts.planner.hpPerKgFromHpAndWeightKg(powerHp, wkg) or nil
      local powerDbg = {
        liveWatts = powerWatts,
        playerPwDbg = playerPw,
        usedPoolRefHp = false,
      }
      local sanctionedBracket = sanctionedSpawnCtx
      local sanctionedActive = type(sanctionedBracket) == "table"
        and ((tonumber(sanctionedBracket.classPwMax) or tonumber(sanctionedBracket.classHpMax) or 0) > 0)
      local playerPowerToWeight = playerPw
      if not playerPowerToWeight or playerPowerToWeight <= 0 then
        local pwUi, srcUi = resolvePlayerPwFromStagingUi()
        if type(pwUi) == "number" and pwUi > 0 then
          playerPowerToWeight = pwUi
          powerDbg.usedStagingUiPw = true
          powerDbg.stagingUiSource = srcUi
          powerDbg.playerPwDbg = pwUi
        end
      end
      if
        (not playerPowerToWeight or playerPowerToWeight <= 0)
        and not sanctionedActive
        and type(poolReferencePowerToWeight) == "number"
        and poolReferencePowerToWeight > 0
      then
        if poolReferencePowerToWeight <= MAX_POOL_REFERENCE_PW then
          playerPowerToWeight = poolReferencePowerToWeight
          powerDbg.usedPoolRefHp = true
        end
      end
      spawnFromPlayerPw(request, playerPowerToWeight or 0, powerDbg)
  end

  function M.spawnForStagingWithPlayerHp(
    raceName,
    race,
    facilityName,
    callback,
    poolReferencePowerToWeight,
    poolReferenceMinimumPowerToWeight,
    sanctionedSpawnCtx
  )
    if type(callback) ~= "function" then return end
    local cfg = ownerServices.parts.config.getMergedConfigForRace(race, raceName)
    if cfg.enabled == false then
      callback(0)
      return
    end
    local request = {
      raceName = raceName,
      race = race,
      facilityName = facilityName,
      cfg = cfg,
      callback = callback,
      poolReferenceHpMin = poolReferenceMinimumPowerToWeight,
      sanctionedSpawnCtx = sanctionedSpawnCtx,
    }

    local pwStaging, srcStaging = resolvePlayerPwFromStagingUi()
    if type(pwStaging) == "number" and pwStaging > 0 then
      spawnFromPlayerPw(request, pwStaging, {
        liveWatts = nil,
        playerPwDbg = pwStaging,
        usedPoolRefHp = false,
        usedStagingUiPw = true,
        stagingUiSource = srcStaging,
      })
      return
    end

    M.getPlayerVehiclePowerReliable(function(powerWatts, weight)
      completePowerMatchedRequest(request, poolReferencePowerToWeight, powerWatts, weight)
    end, { preferLive = true })
  end

  return {
    spawnWithModelConfigList = spawnWithModelConfigList,
  }
end

return lib
