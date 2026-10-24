-- Racing team dev log: a capped buffer of team diagnostics, mirrored to the game log and the dev console.
-- Entries are kept only while the dev console is enabled; scanIssues reads the live team state for problems.
local M = {}

local devScope = require("overhaul/lib/lifecycle/scopes/dev")
local optional = require("overhaul/lib/platform/optional")
local rtState = require("overhaul/career/business/racingTeam/racingTeam/runtimeState")

local REFRESH_THRESHOLD_SECONDS = 3600
local MAX_LINES = 200

local buffer = {}
local seq = 0


-- Use the scope until the later-loading console can answer the shared team gate.
local function consoleOwner()
  return optional("overhaul_dev_devConsole")
end

local function consoleEnabled()
  local console = consoleOwner()
  if console then
    return console.isEnabled()
  end
  return devScope.consoleEnabled()
end
M.consoleEnabled = consoleEnabled

function M.requireEnabled()
  return consoleOwner().requireEnabled()
end

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function formatContext(logFields)
  if type(logFields) ~= "table" then
    return ""
  end
  local parts = {}
  for k, v in pairs(logFields) do
    local t = type(v)
    if t ~= "table" and t ~= "function" then
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  if #parts == 0 then
    return ""
  end
  return " (" .. table.concat(parts, ", ") .. ")"
end

local function formatEntry(entry)
  local lvl = string.upper(tostring(entry.level or "info"))
  local src = entry.source and ("[" .. tostring(entry.source) .. "] ") or ""
  return src .. "[" .. lvl .. "] " .. tostring(entry.message or "") .. formatContext(entry.context)
end

local function pushUi(payload)
  guihooks.trigger("racingTeam:devLog", payload)
end

local function scanOfferBoard(businessId, parts)
  local board = parts.raceOffers.getBoard(businessId)
  local offerCount = board and #(board.offers or {}) or 0
  if offerCount == 0 then
    M.append(businessId, "warn", "Race offer board is empty", "scan")
  end
  if board and board.nextRefreshAt then
    local now = parts.board.getCareerSimTime() or 0
    local refreshAt = tonumber(board.nextRefreshAt) or 0
    if refreshAt > now + REFRESH_THRESHOLD_SECONDS then
      M.append(businessId, "warn", "Race board refresh far in future (" .. tostring(math.floor(refreshAt - now)) .. "s sim)", "scan")
    end
  end
end

local function scanLeagueInvite(businessId)
  -- Required at scan time, so loading the log does not load the league module.
  local invMod = require("overhaul/career/business/racingTeam/racingTeam/leagueInvite")
  local inv = invMod.getInviteTable(businessId)
  if inv and inv.declined then
    M.append(businessId, "warn", "League invite was declined (target " .. tostring(inv.targetLeague) .. ")", "scan")
  end
  if inv and inv.offeredAt and not inv.declined and inv.targetLeague then
    M.append(businessId, "info", "Pending league invite to " .. tostring(inv.targetLeague), "scan")
  end
end

local function scanGoals(businessId, internals, league)
  -- Required at scan time, so loading the log does not load the goal modules.
  local goalsMod = require("overhaul/career/business/racingTeam/racingTeam/goals")
  local def = goalsMod.loadDefinition()
  local leagueGoals = goalsMod.getSortedForLeague(def, league)
  local headGoal = nil
  for _, g in ipairs(leagueGoals or {}) do
    if g and g.id and not goalsMod.idCompleted(businessId, g.id) then
      headGoal = g.id
      break
    end
  end
  if not headGoal and leagueGoals and #leagueGoals > 0 then
    if internals.allGoalsCompleteForLeague(businessId, league) then
      M.append(businessId, "info", "All goals complete for " .. tostring(league), "scan")
    else
      M.append(businessId, "warn", "No head goal but league not fully complete", "scan")
    end
  end
end

function M.append(businessId, level, message, source, context)
  if not consoleEnabled() then
    return
  end
  if not message or message == "" then
    return
  end
  seq = seq + 1
  local entry = {
    seq = seq,
    level = level or "info",
    message = tostring(message),
    source = source,
    context = type(context) == "table" and context or nil,
    businessId = businessId and tostring(normalizeBusinessId(businessId)) or nil,
  }
  buffer[#buffer + 1] = entry
  while #buffer > MAX_LINES do
    table.remove(buffer, 1)
  end
  local text = formatEntry(entry)
  log("I", "racingTeamDev", text)
  pushUi({ text = text, level = entry.level })
end

function M.getFormattedLines()
  local out = {}
  for i = 1, #buffer do
    out[i] = formatEntry(buffer[i])
  end
  return out
end

function M.clear()
  buffer = {}
  seq = 0
  if consoleEnabled() then
    pushUi({ clear = true })
  end
end

function M.scanIssues(businessId)
  if not consoleEnabled() or not businessId then
    return
  end
  businessId = normalizeBusinessId(businessId)
  local internals = rtState.rtInternal
  -- The log can be loaded before the team constructs its league hooks.
  if not internals.getCurrentLeague then
    return
  end

  local league = internals.getCurrentLeague(businessId)
  scanOfferBoard(businessId, rtState.parts)
  scanLeagueInvite(businessId)
  if rtState.pendingRematchOfferByBusiness[tostring(businessId)] then
    M.append(businessId, "info", "Pending rematch offer stored", "scan")
  end
  scanGoals(businessId, internals, league)
end

rtState.rtInternal.devLog = M

return M
