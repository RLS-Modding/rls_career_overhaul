-- Course helpers for the shared Dakar controller in ../dakar.lua.
-- Owns sites, route generation, headings and placements; vehicle.lua owns kits and money.
-- Construct with new(config); the controller uses the returned course functions.
local M = {}

function M.new(config)
  local sites
  local spotsByName = {}
  local checkpointPool = {}
  local enrichRoute

  local function startsWith(value, prefix)
    return type(value) == "string" and value:sub(1, #prefix) == prefix
  end

  local function isDakarCheckpointSpot(spot)
    return spot and startsWith(spot.id, config.checkpointNamePrefix or "dakarCheckpoint")
  end

  local function asVec3(pos)
    if type(pos) == "table" then return vec3(pos[1] or 0, pos[2] or 0, pos[3] or 0) end
    return pos or vec3()
  end

  local function getFirstTag(spot)
    local tags = spot.customFields and spot.customFields.tags
    if type(tags) == "table" then
      return tags[1] or tags[0]
    end
    return nil
  end

  local function resolveCheckpointImage(label)
    local dir = config.checkpointImageDir or ""
    local extension = config.checkpointImageExtension or ".png"
    local fallback = dir .. label .. extension
    if not FS or not FS.fileExists then return fallback end

    local extensions = { extension, ".jpg", ".jpeg", ".png" }
    local checked = {}
    for _, ext in ipairs(extensions) do
      if ext and not checked[ext] then
        checked[ext] = true
        local path = dir .. label .. ext
        if FS:fileExists(path) then return path end
      end
    end

    return fallback
  end

  local function sanitizeSpot(spot)
    local label = getFirstTag(spot) or spot.name
    return {
      id = spot.name,
      name = label,
      pos = asVec3(spot.pos),
      image = resolveCheckpointImage(label)
    }
  end

  local function loadSites()
    if sites then return end
    sites = jsonReadFile(config.sitesFile) or {}
    spotsByName = {}
    checkpointPool = {}
    for _, raw in ipairs(sites.parkingSpots or {}) do
      local spot = sanitizeSpot(raw)
      spotsByName[spot.id] = spot
      if startsWith(spot.id, config.checkpointNamePrefix or "dakarCheckpoint") then
        table.insert(checkpointPool, spot)
      end
    end
  end

  local function dist(a, b)
    return (a.pos - b.pos):length()
  end

  local function normalizedDegrees(degrees)
    degrees = tonumber(degrees) or 0
    degrees = degrees % 360
    if degrees < 0 then degrees = degrees + 360 end
    return math.floor(degrees + 0.5) % 360
  end

  local function bearingBetween(fromSpot, toSpot)
    if not fromSpot or not toSpot then return nil end
    local delta = toSpot.pos - fromSpot.pos
    return normalizedDegrees(math.deg(math.atan2(delta.x, delta.y)))
  end

  local function headingFromVector(vec)
    if not vec then return nil end
    -- The needle needs fractional degrees; only labels and route clues are rounded.
    return math.deg(math.atan2(vec.x, vec.y)) % 360
  end

  local function formatHeading(degrees)
    if degrees == nil then return "---" end
    return string.format("%03d\194\176", normalizedDegrees(degrees))
  end

  enrichRoute = function(route)
    loadSites()
    local enriched = {}
    local last = spotsByName[config.startSpot]
    for _, raw in ipairs(route or {}) do
      local cp = deepcopy(raw)
      cp.headingDegrees = bearingBetween(last, cp)
      cp.headingText = formatHeading(cp.headingDegrees)
      table.insert(enriched, cp)
      last = cp
    end
    return enriched
  end

  local function shuffleCopy(list)
    local copy = deepcopy(list)
    arrayShuffle(copy)
    return copy
  end

  local function buildRoute(classRule)
    loadSites()
    local startSpot = spotsByName[config.startSpot]
    local finishSpot = spotsByName[config.finishSpot]
    local minSpacing = classRule.minSpacingMeters or 1000
    local endpointMinSpacing = classRule.endpointMinSpacingMeters or minSpacing
    local checkpointCount = classRule.checkpointCount or 3

    for _ = 1, 100 do
      local picked = {}
      for _, cp in ipairs(shuffleCopy(checkpointPool)) do
        local ok = dist(cp, startSpot) >= endpointMinSpacing and dist(cp, finishSpot) >= endpointMinSpacing
        for _, prior in ipairs(picked) do
          ok = ok and dist(cp, prior) >= minSpacing
        end
        if ok then table.insert(picked, cp) end
        if #picked >= checkpointCount then break end
      end
      if #picked >= checkpointCount then
        table.insert(picked, finishSpot)
        return enrichRoute(picked)
      end
    end
  end

  local function routeDistance(route)
    local startSpot = spotsByName[config.startSpot]
    local last = startSpot
    local total = 0
    for _, cp in ipairs(route or {}) do
      total = total + dist(last, cp)
      last = cp
    end
    return total
  end

  local function targetTime(distanceMeters)
    local first = config.rewards and config.rewards.placements and config.rewards.placements[1] or {}
    local secondsPerKm = first.secondsPerKm or config.rewards.targetSecondsPerKm or 45
    return (distanceMeters / 1000) * secondsPerKm
  end

  local function placementFor(finalSeconds, distanceMeters, targetSeconds)
    local distanceKm = math.max(0, (tonumber(distanceMeters) or 0) / 1000)
    for _, placement in ipairs(config.rewards.placements or {}) do
      if placement.secondsPerKm then
        if finalSeconds <= distanceKm * placement.secondsPerKm then return placement end
      elseif finalSeconds <= (targetSeconds or 0) + (placement.lateSeconds or 0) then
        return placement
      end
    end
    return { id = "top10", label = "Finished", bonusFactor = 0 }
  end


  return {
    loadSites = loadSites,
    getSpots = function() return spotsByName end,
    resolveCheckpointImage = resolveCheckpointImage,
    isDakarCheckpointSpot = isDakarCheckpointSpot,
    enrichRoute = enrichRoute,
    buildRoute = buildRoute,
    routeDistance = routeDistance,
    targetTime = targetTime,
    placementFor = placementFor,
    headingFromVector = headingFromVector,
    formatHeading = formatHeading
  }
end

return M
