-- Owns numerical NPC qualifying and elimination results.
-- drag/qualifying.lua and drag/bracket.lua retain progress; the coordinator applies completion and rewards.
local M = {}
local qualifying = require('overhaul/events/motorsportEvents/drag/qualifying')
local bracket = require('overhaul/events/motorsportEvents/drag/bracket')
local roster = require('overhaul/events/motorsportEvents/drag/roster')

local function result(entrant)
  local base = entrant.qualifying and entrant.qualifying.valid and entrant.qualifying.time or tonumber(entrant.dial) or 10
  return {entrantId = entrant.id, time = math.max(1, base + (math.random() - .5) * .6),
    reaction = .05 + math.random() * .2, valid = true, simulated = true}
end

function M.qualify(eventState)
  local count = 0
  for _, entrant in ipairs(eventState.entrants) do
    while not entrant.player and not qualifying.isDone(entrant) do
      local row = result(entrant)
      if eventState.activeClassId then
        row = require('overhaul/events/motorsportEvents/drag/classes').applyResult(eventState.activeClassId, {rows = {row}}, 'qualifying', eventState).rows[1]
      end
      qualifying.record(entrant, row)
      count = count + 1
    end
  end
  return count
end

function M.race(eventState)
  local count = 0
  while true do
    local match = bracket.nextMatch(eventState.bracket)
    if not match then return count, true end
    local a, b = roster.find(eventState.entrants, match.a), roster.find(eventState.entrants, match.b)
    if a.player or b.player then return count, false end
    local rows = {result(a), result(b)}
    local winner = rows[1].time + rows[1].reaction <= rows[2].time + rows[2].reaction and a.id or b.id
    local pass = {winnerId = winner, rows = rows}
    if eventState.activeClassId then pass = require('overhaul/events/motorsportEvents/drag/classes').applyResult(eventState.activeClassId, pass, 'eliminations', eventState) end
    if not bracket.record(match, pass) then return count, false end
    match.simulated = true
    count = count + 1
  end
end

return M
