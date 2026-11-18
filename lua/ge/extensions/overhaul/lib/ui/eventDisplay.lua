-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Overhaul Event display: one structured HUD card plus a short toast stack, drawn by OverhaulEventDisplay.vue (coreUi).
-- Event owners call set(owner, view) while their event needs the card and clear(owner) when it does not; the most
-- recently started owner is shown. toast(owner, text, opts) replaces the stock ui_message for event calls and results.
-- Owners call tick(dt) from their update: it expires toasts and re-sends what is shown every HEARTBEAT seconds, so a
-- reloaded UI gets it back. Every field of a view is optional; empty ones are dropped so the UI lays out only what is present.
--
-- view = {
--   id, title, phase, status,                     -- strings; eyebrow and icon are accepted but not drawn
--   tag,                                           -- highlighted label before the phase, e.g. the class
--   matchups = {{label = 'Now', names = {...}}},  -- head-to-head rows, in order
--   timeslip = {strip, tree, distance, raceType, lanes = {{lane, name, player, winner, result, timers = {{label, value}}}}},
--   countdown = {label = 'Next pass', seconds = 90} or {label, text},
--   meta = {{label = 'Day', value = '1/2', icon = 'calendar', tone = 'accent'}},  -- key/value facts; {text} alone works
--   call, hold, note,                             -- next step (banner), blocked reason (banner), secondary line
--   wait = {label = 'Eliminations in', seconds = 1795},  -- a timed one-row wait, drawn as label and time
--   tone = 'idle' | 'called' | 'armed' | 'racing' | 'hold' | 'done',
--   dock = 'left' | 'right',
-- }
-- payload = {visible, owner, display = view or nil, toasts = {{id, text, kind, seconds}}, dock}
local statePush = require('overhaul/lib/ui/statePush')

local M = {EVENT = 'OverhaulEventDisplay', HEARTBEAT = 3, TOAST_SECONDS = 8, MAX_TOASTS = 3}
local TONES = {idle = true, called = true, armed = true, racing = true, hold = true, done = true}
local KINDS = {info = true, good = true, warn = true, bad = true}
local CALL_KINDS = {wait = true, act = true, go = true, blocked = true, done = true}
local views, started, sequence, sinceBeat = {}, {}, 0, 0
local toasts, toastSequence, clock, lastDock = {}, 0, 0, 'left'

local function text(value)
  if type(value) == 'number' then value = tostring(value) end
  return type(value) == 'string' and value ~= '' and value or nil
end

local function names(list)
  local out = {}
  for _, name in ipairs(type(list) == 'table' and list or {}) do out[#out + 1] = text(name) end
  return #out > 0 and out or nil
end

-- Drops empty fields and anything the card cannot draw.
function M.normalize(view)
  if type(view) ~= 'table' then return nil end
  local out = {id = text(view.id), title = text(view.title), eyebrow = text(view.eyebrow), icon = text(view.icon), tag = text(view.tag),
    phase = text(view.phase), status = text(view.status), call = text(view.call), hold = text(view.hold), note = text(view.note),
    tone = TONES[view.tone] and view.tone or (text(view.hold) and 'hold' or 'idle'),
    callKind = CALL_KINDS[view.callKind] and view.callKind or 'wait',
    holdKind = CALL_KINDS[view.holdKind] and view.holdKind or 'blocked',
    compact = view.compact == true, oneRow = view.oneRow == true,
    dock = view.dock == 'right' and 'right' or 'left'}
  if type(view.result) == 'table' and text(view.result.text) then
    out.result = {text = text(view.result.text), reward = tonumber(view.result.reward) or 0}
  end
  local waitSeconds = type(view.wait) == 'table' and tonumber(view.wait.seconds)
  if waitSeconds and text(view.wait.label) then
    out.wait = {label = text(view.wait.label), seconds = math.max(0, math.ceil(waitSeconds))}
  end
  local matchups = {}
  for _, block in ipairs(type(view.matchups) == 'table' and view.matchups or {}) do
    local list = type(block) == 'table' and names(block.names)
    if list then matchups[#matchups + 1] = {label = text(block.label), names = list} end
  end
  out.matchups = #matchups > 0 and matchups or nil
  local countdown = view.countdown
  if type(countdown) == 'table' then
    local seconds = tonumber(countdown.seconds)
    seconds = seconds and math.max(0, math.ceil(seconds)) or nil
    if (seconds and seconds > 0) or text(countdown.text) then
      out.countdown = {label = text(countdown.label), seconds = seconds, text = text(countdown.text)}
    end
  end
  local meta = {}
  for _, item in ipairs(type(view.meta) == 'table' and view.meta or {}) do
    local value = type(item) == 'table' and (text(item.value) or text(item.text))
    if value then meta[#meta + 1] = {icon = text(item.icon), label = text(item.label), value = value, tone = item.tone == 'accent' and 'accent' or nil} end
  end
  out.meta = #meta > 0 and meta or nil
  local slip = view.timeslip
  if type(slip) == 'table' then
    local lanes = {}
    for _, lane in ipairs(type(slip.lanes) == 'table' and slip.lanes or {}) do
      if type(lane) == 'table' then
        local timers = {}
        for _, timer in ipairs(type(lane.timers) == 'table' and lane.timers or {}) do
          if type(timer) == 'table' and text(timer.label) then
            timers[#timers + 1] = {label = text(timer.label), value = text(timer.value) or '—'}
          end
        end
        lanes[#lanes + 1] = {lane = text(lane.lane), name = text(lane.name), player = lane.player == true,
          winner = lane.winner == true, result = text(lane.result), timers = timers}
      end
    end
    if #lanes > 0 then out.timeslip = {graded = slip.graded == true, strip = text(slip.strip), tree = text(slip.tree), distance = text(slip.distance), raceType = text(slip.raceType), lanes = lanes} end
  end
  return out
end

local function current()
  local owner, newest
  for name in pairs(views) do
    if not newest or started[name] > newest then owner, newest = name, started[name] end
  end
  if owner then lastDock = views[owner].dock end
  local list = {}
  for index, toast in ipairs(toasts) do list[index] = {id = toast.id, text = toast.text, kind = toast.kind, seconds = toast.seconds} end
  if not owner and #list == 0 then return {visible = false} end
  return {visible = true, owner = owner, display = owner and views[owner] or nil, toasts = #list > 0 and list or nil, dock = lastDock}
end

function M.publish() return statePush.refresh(M.EVENT, current()) end

function M.set(owner, view)
  assert(type(owner) == 'string' and owner ~= '', 'eventDisplay.set needs an owner name')
  local normalized = M.normalize(view)
  if not normalized then return M.clear(owner) end
  if not views[owner] then sequence = sequence + 1; started[owner] = sequence end
  views[owner] = normalized
  return M.publish()
end

function M.clear(owner)
  if owner == nil or views[owner] == nil then return false end
  views[owner], started[owner] = nil, nil
  return M.publish()
end

function M.get(owner) return owner and views[owner] or current().display end

-- A short message above the card, styled like its banner. The same text again restarts its timer instead of stacking.
-- opts = {kind = 'info' | 'good' | 'warn' | 'bad', seconds = TOAST_SECONDS}
function M.toast(owner, message, opts)
  assert(type(owner) == 'string' and owner ~= '', 'eventDisplay.toast needs an owner name')
  local body = text(message)
  if not body then return false end
  opts = type(opts) == 'table' and opts or {}
  for index = #toasts, 1, -1 do if toasts[index].text == body then table.remove(toasts, index) end end
  toastSequence = toastSequence + 1
  local seconds = math.max(1, tonumber(opts.seconds) or M.TOAST_SECONDS)
  table.insert(toasts, 1, {id = toastSequence, owner = owner, text = body, kind = KINDS[opts.kind] and opts.kind or 'info',
    seconds = seconds, expires = clock + seconds})
  while #toasts > M.MAX_TOASTS do table.remove(toasts) end
  return M.publish()
end

-- Expires toasts and re-sends what is shown on a slow beat, so a UI reload is not left blank until the next change.
function M.tick(dt)
  clock = clock + (dt or 0)
  local expired = false
  for index = #toasts, 1, -1 do
    if toasts[index].expires <= clock then table.remove(toasts, index); expired = true end
  end
  if expired then M.publish() end
  if next(views) == nil and #toasts == 0 then sinceBeat = 0; return end
  sinceBeat = sinceBeat + (dt or 0)
  if sinceBeat < M.HEARTBEAT then return end
  sinceBeat = 0
  statePush.send(M.EVENT, current())
end

return M
