-- Burnout level metadata and legacy embedded event normalization.
-- Read defaults, level discovery and public lookup; loaded documents remain untouched.
local M = {}
local catalog = require("overhaul/lib/platform/jsonCatalog")
local TAG = "burnoutConfig"

local CONFIG_FILENAME = "overhaul/burnout.json"
local SITES_FILENAME = "burnout.sites.json"
local DEFAULT_SCORE_GOAL = 6000
local DEFAULT_REWARD = 200
local DEFAULT_TIME = 60

local cache = nil

local function normalizeEvent(event)
  if type(event) ~= "table" then return nil end

  local zoneId = event.zoneId
  if not catalog.validId(zoneId) or not catalog.validId(event.eventId) then return nil end
  local zoneName = event.zoneName or event.siteZoneName
  local triggerName = event.triggerName
  if zoneName ~= nil and (type(zoneName) ~= "string" or zoneName == "") then return nil end
  if triggerName ~= nil and (type(triggerName) ~= "string" or triggerName == "") then return nil end
  if not zoneName and not triggerName then return nil end
  local scoreGoal = event.driftGoal or event.scoreGoal or DEFAULT_SCORE_GOAL
  local normalized = {
    eventId = event.eventId,
    zoneId = zoneId,
    zoneName = zoneName,
    label = event.label or event.name or ("Burnout " .. zoneId),
    types = event.types or { "burnout", "freeroam" },
    triggerName = triggerName,
    thumbnail = event.thumbnail,
    driftGoal = scoreGoal,
    scoreGoal = event.scoreGoal or event.driftGoal or scoreGoal,
    driftTargetTime = event.driftTargetTime or DEFAULT_TIME,
    bestTime = event.bestTime or DEFAULT_TIME,
    reward = event.reward or DEFAULT_REWARD,
  }
  if type(normalized.label) ~= "string" or type(normalized.types) ~= "table" then return nil end
  for _, discipline in ipairs(normalized.types) do
    if type(discipline) ~= "string" or discipline == "" then return nil end
  end
  for _, key in ipairs({"driftGoal", "scoreGoal", "driftTargetTime", "bestTime", "reward"}) do
    if not catalog.finite(normalized[key]) or normalized[key] < 0 then return nil end
    if key ~= "reward" and normalized[key] == 0 then return nil end
  end
  return normalized
end

local function loadLevelData(level)
  if not level or level == "" then
    return { level = level, events = {}, zonesByName = {}, sitesFile = SITES_FILENAME, sites = nil }
  end
  if cache and cache.level == level then return cache end

  local config = jsonReadFile("levels/" .. level .. "/" .. CONFIG_FILENAME)
  local sitesFile = type(config) == "table" and config.sitesFile or nil
  if type(sitesFile) ~= "string" or sitesFile == "" then sitesFile = SITES_FILENAME end
  local sites = jsonReadFile("levels/" .. level .. "/" .. sitesFile)

  -- Keep embedded legacy burnout events when the separate metadata file is absent.
  local source = type(config) == "table" and (config.events or config.burnouts) or nil
  if type(source) ~= "table" and type(sites) == "table" then source = sites.events or sites.burnouts end
  source = type(source) == "table" and source or {}
  local zonesByName = {}
  for _, zone in ipairs(type(sites) == "table" and sites.zones or {}) do
    if type(zone) == "table" and type(zone.name) == "string" and zone.name ~= ""
      and type(zone.vertices) == "table" and #zone.vertices >= 3 then
      local valid = true
      for _, vertex in ipairs(zone.vertices) do
        if type(vertex) ~= "table" or not catalog.finite(vertex[1])
          or not catalog.finite(vertex[2]) or not catalog.finite(vertex[3]) then valid = false; break end
      end
      if valid then zonesByName[zone.name] = zone end
    end
  end
  local events, eventIds, zoneIds, triggers = {}, {}, {}, {}
  for _, event in ipairs(source) do
    local normalized = normalizeEvent(event)
    local reason
    if not normalized then reason = "requires eventId, zoneId and zoneName or triggerName"
    elseif normalized.zoneName and not zonesByName[normalized.zoneName] then reason = "missing or invalid sites zone"
    elseif eventIds[normalized.eventId] or zoneIds[normalized.zoneId]
      or (normalized.triggerName and triggers[normalized.triggerName]) then reason = "duplicate event, zone or trigger" end
    if reason then
      log("W", TAG, "Burnout event disabled on " .. level .. ": " .. reason)
    else
      events[#events + 1] = normalized
      eventIds[normalized.eventId], zoneIds[normalized.zoneId] = true, true
      if normalized.triggerName then triggers[normalized.triggerName] = true end
    end
  end
  if #events == 0 then log("D", TAG, "Burnout unavailable on " .. level .. ": no valid configured events") end

  cache = {
    level = level,
    events = events,
    zonesByName = zonesByName,
    sitesFile = sitesFile,
    sites = sites,
  }
  return cache
end

M.normalizeEvent = normalizeEvent
M.loadLevelData = loadLevelData
function M.invalidate() cache = nil end

function M.raceData(event)
  return {label = event.label, type = event.types, burnoutComp = true, zoneId = event.zoneId,
    driftGoal = event.driftGoal, driftTargetTime = event.driftTargetTime, bestTime = event.bestTime, reward = event.reward}
end

return M
