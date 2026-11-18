-- Owns in-memory event state and career capture persistence.
-- motorsportEvents.lua calls load/save; overhaul/lib/save/store.lua tracks requests and target-slot writes.
local M = {}
local FILE = '/career/motorsportEvents/activeEvent.json'
local saveStore = require('overhaul/lib/save/store')
saveStore.registerKeys({{key = 'events.motorsport', owner = 'overhaul_events_motorsportEvents',
  files = {'career/motorsportEvents/activeEvent.json'}, phase = 'profile', required = false}})
local state, loadedProfile

local function currentProfile()
  if not overhaul_career_saveSystem then return nil end
  return overhaul_career_saveSystem.getCurrentProfile()
end

function M.load()
  local path
  loadedProfile, path = currentProfile()
  state = path and jsonReadFile(path .. FILE) or nil
  if type(state) ~= 'table' or state.version ~= 1 then
    state = {version = 1, nextEventId = 1, history = {}}
  end
  state.history = state.history or {}
  if state.event then state.event.inFlight = nil end
  return state
end

function M.get()
  if not state or loadedProfile ~= currentProfile() then return M.load() end
  return state
end

function M.save(path, writer)
  if not state then return false end
  if not path then
    if not overhaul_career_saveSystem then return false end
    return saveStore.request('motorsport:stateChanged')
  end
  local dir = path .. '/career/motorsportEvents'
  writer = writer or saveStore.writer()
  if not writer.exists(dir) then writer.mkdir(dir, true) end
  return writer.json(path .. FILE, state, true)
end

function M.replace(event)
  local s = M.get()
  if s.event and s.event.phase == 'complete' then
    table.insert(s.history, {id = s.event.id, name = s.event.name, winnerId = s.event.winnerId, reward = s.event.reward})
    if #s.history > 20 then table.remove(s.history, 1) end
  end
  event.id = 'motorsport-' .. tostring(s.nextEventId)
  s.nextEventId = s.nextEventId + 1
  s.event = event
  return event
end

return M
