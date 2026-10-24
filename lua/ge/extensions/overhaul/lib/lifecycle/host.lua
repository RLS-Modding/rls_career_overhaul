-- Overhaul's shared lifecycle host: existing orchestration reports each transition here as it happens.
-- It keeps the epochs and request lifetimes and tells observers; it dispatches no owner hook and changes no outcome.

local M = {}

-- Transition kinds and their names. Observers get "begin", "phase", "finish" and "advance" (an epoch advanced).
M.KINDS = {save = "T-SAVE", reload = "T-RELOAD", exit = "T-EXIT", profile = "T-PROFILE", travel = "T-TRAVEL",
  unload = "T-UNLOAD", activate = "T-ACTIVATE"}

local validScope = {career = true, map = true, profile = true}

-- Epochs and tracked requests of one host; `new()` gives each host its own.
local Epochs = {}
Epochs.__index = Epochs

local function newEpochs()
  return setmetatable({epoch = {career = 0, map = 0, profile = 0}, requests = {}, nextId = 0}, Epochs)
end

-- Whether the request declared this lifetime as one that ends it.
local function declaresScope(token, scope)
  for _, declared in ipairs(token.scopes) do
    if declared == scope then return true end
  end
  return false
end

-- The current epochs, as a copy.
function Epochs:current()
  return {career = self.epoch.career, map = self.epoch.map, profile = self.epoch.profile}
end

function Epochs:get(scope)
  return self.epoch[scope]
end

-- Capture declared epochs so later lifetime changes invalidate only matching requests.
function Epochs:track(owner, scopes, info)
  self.nextId = self.nextId + 1
  local token = {id = self.nextId, owner = owner, scopes = {}, info = info,
    career = self.epoch.career, map = self.epoch.map, profile = self.epoch.profile}
  for _, scope in ipairs(scopes or {}) do
    assert(validScope[scope], "unknown lifetime scope " .. tostring(scope))
    token.scopes[#token.scopes + 1] = scope
  end
  self.requests[token.id] = token
  return token
end

-- Whether the request is still tracked and none of its lifetimes ended since it started.
function Epochs:isCurrent(token)
  if type(token) ~= "table" or self.requests[token.id] ~= token then return false end
  for _, scope in ipairs(token.scopes) do
    if token[scope] ~= self.epoch[scope] then return false end
  end
  return true
end

-- The request finished on its own (answered, closed or failed by its owner).
function Epochs:finish(token)
  if type(token) == "table" and self.requests[token.id] == token then
    self.requests[token.id] = nil
    return true
  end
  return false
end

-- A request expires only when a declared scope advances beyond its captured epoch.
function Epochs:advance(scope)
  assert(validScope[scope], "unknown lifetime scope " .. tostring(scope))
  local endedEpoch = self.epoch[scope]
  self.epoch[scope] = endedEpoch + 1
  local endedRequests = {}
  for _, token in pairs(self.requests) do
    if token[scope] == endedEpoch and declaresScope(token, scope) then endedRequests[#endedRequests + 1] = token end
  end
  table.sort(endedRequests, function(a, b) return a.id < b.id end)
  for _, token in ipairs(endedRequests) do self.requests[token.id] = nil end
  return endedRequests
end

-- Tracked requests, optionally only those of `owner`.
function Epochs:pending(owner)
  local count = 0
  for _, token in pairs(self.requests) do
    if owner == nil or token.owner == owner then count = count + 1 end
  end
  return count
end

local epochs = newEpochs()
local observers = {}
local activeByKind = {}
local sequence = 0

-- Calls every observer with the event; one failing observer is logged and does not stop the others.
local function notify(event, transition, data)
  if #observers == 0 then return end
  -- Copy first, so an observer that adds or removes observers does not change this round.
  local snapshot = {}
  for i, observer in ipairs(observers) do snapshot[i] = observer end
  for _, observer in ipairs(snapshot) do
    local ok, err = pcall(observer, event, transition, data)
    if not ok then log("E", "lifecycle", "Lifecycle observer failed: " .. tostring(err)) end
  end
end

-- Registers fn(event, transition, data); returns a function that removes it.
function M.observe(fn)
  observers[#observers + 1] = fn
  return function()
    for i, observer in ipairs(observers) do
      if observer == fn then table.remove(observers, i); return true end
    end
    return false
  end
end

-- A transition started. info: what the reporting site knows (kept on the record).
function M.begin(kind, info)
  assert(M.KINDS[kind], "unknown transition " .. tostring(kind))
  sequence = sequence + 1
  local transition = {kind = kind, name = M.KINDS[kind], id = sequence, info = info or {}, phase = "begin",
    phases = {}, epochs = epochs:current()}
  activeByKind[kind] = transition
  notify("begin", transition, info)
  return transition
end

-- The transition reached one of its existing steps (for example "capture" or "join" in a save).
function M.phase(transition, name, data)
  if type(transition) ~= "table" then return end
  transition.phase = name
  transition.phases[#transition.phases + 1] = name
  notify("phase", transition, data)
end

-- The transition ended: outcome "done", "failed", "refused", "bypassed" or "replaced".
function M.finish(transition, outcome, data)
  if type(transition) ~= "table" or transition.outcome then return end
  transition.outcome = outcome or "done"
  transition.phase = "finished"
  if activeByKind[transition.kind] == transition then activeByKind[transition.kind] = nil end
  notify("finish", transition, data)
end

-- The newest unfinished transition of a kind, or nil.
function M.current(kind)
  return activeByKind[kind]
end

-- Host epochs: {career, map, profile}.
function M.epochs()
  return epochs:current()
end

-- Notify each expired request through its owner's cancellation callback.
function M.advance(scope, reason)
  local ended = epochs:advance(scope)
  for _, token in ipairs(ended) do
    local onEnded = type(token.info) == "table" and token.info.onEnded
    if onEnded then
      local ok, err = pcall(onEnded, token, scope, reason)
      if not ok then log("E", "lifecycle", "Request end handler failed: " .. tostring(err)) end
    end
  end
  notify("advance", nil, {scope = scope, reason = reason, ended = ended, epochs = epochs:current()})
  return ended
end

-- Host-owned request tracking. scopes: lifetimes that end the request (default none).
function M.track(owner, scopes, info)
  return epochs:track(owner, scopes, info)
end

function M.isCurrent(token)
  return epochs:isCurrent(token)
end

function M.done(token)
  return epochs:finish(token)
end

function M.pending(owner)
  return epochs:pending(owner)
end

-- Tests only: a fresh host.
function M._reset()
  epochs = newEpochs()
  observers, activeByKind, sequence = {}, {}, 0
end

return M
