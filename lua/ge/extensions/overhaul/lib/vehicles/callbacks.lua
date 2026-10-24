-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Vehicle callbacks: the GE side of answers that vehicle Lua sends back, routed through owner-declared rows.
-- Vehicle Lua reaches GE modules through these rows, so the vehicle side never names a GE extension.
local lifecycle = require('overhaul/lib/lifecycle/host')
local manifests = require('overhaul/lib/platform/manifests')
local optional = require('overhaul/lib/platform/optional')

local M = {}

-- Discover callback owners lazily so requiring this library reads no filesystem state.
M.dir = "/gameplay/overhaul/vehicleCallbacks/"
local TAG = "vehicleCallbacks"
local GUARDS = {none = true, ["function"] = true, module = true, lazy = true}
local DEFAULT_TIMEOUT = 300   -- seconds; a leak bound, far above any vehicle round trip
local FINISHED_KEEP = 256     -- answered and failed ids remembered, to tell duplicates from unknown ids

-- id -> {extension, fn, guard, owner}, filled by M.load(); tests may add rows before the first load.
M.callbacks = {}
M.rejected = {}
local scanned = false
local requests = {}
local finished, finishedOrder, finishedHead = {}, {}, 0
local careerEpoch, generations = 1, {}
-- IDs are registry-local and can repeat in a fresh VM, so cross-VM receivers must authenticate an independent identity such as the business UI nonce.
local nextRequestId = (math.floor(os.time()) % 100000) * 1000
local nextSweep = 0
local stats = {opened = 0, accepted = {}, dropped = {}, failed = {}}
M.stats = stats

local function validate(data, file)
  if type(data.callbacks) ~= "table" or #data.callbacks == 0 then return nil, "callbacks must be a non-empty list" end
  for i, row in ipairs(data.callbacks) do
    if type(row) ~= "table" or not manifests.isNonEmptyString(row.id) or not manifests.isNonEmptyString(row.extension)
      or not manifests.isNonEmptyString(row.fn) or not GUARDS[row.guard] then
      return nil, string.format("callback %d needs id, extension, fn and a guard (none, function, module or lazy)", i)
    end
  end
  data.file = file
  return data
end

local function now() return os.clockhp and os.clockhp() or os.clock() end

-- Lazy declarations must not load an owner just to open a request.
local function loadedOwner(entry)
  if entry.guard == "lazy" then return rawget(extensions, entry.extension) end
  return optional(entry.extension)
end

local function dispatchTarget(entry)
  if not entry then return nil end
  return entry.guard == "lazy" and extensions[entry.extension] or optional(entry.extension)
end

local function dispatch(id, entry, target, ...)
  if not entry then
    log("E", "vehicleCallbacks", "Unknown vehicle callback: " .. tostring(id))
    return
  end
  local fn, guard = entry.fn, entry.guard
  if guard == "none" then return target[fn](...) end
  if not target or (guard == "function" and not target[fn]) then return end
  return target[fn](...)
end

local function count(map, key) map[key] = (map[key] or 0) + 1 end

-- Only pending requests finish, once each; the oldest remembered outcome makes room (ring buffer).
local function finish(requestId, outcome)
  local request = requests[requestId]
  requests[requestId] = nil
  if request then lifecycle.done(request.host) end
  finishedHead = finishedHead % FINISHED_KEEP + 1
  local oldest = finishedOrder[finishedHead]
  if oldest ~= nil then finished[oldest] = nil end
  finishedOrder[finishedHead] = requestId
  finished[requestId] = outcome
  return request
end

-- discard: the owner's state went with the career session, so its failure path must not run.
local function fail(requestId, reason, discard)
  local pending = requests[requestId]
  if not pending then return end -- already finished (a failure path may finish others)
  -- Every completion path can win before a late reply; closures must still belong to the live owner.
  discard = discard or pending.careerEpoch ~= careerEpoch
    or (pending.instance ~= nil and loadedOwner(M.load()[pending.id]) ~= pending.instance)
  local request = finish(requestId, "failed (" .. reason .. ")")
  count(stats.failed, reason)
  log(reason == "timed out" and "D" or "I", "vehicleCallbacks", string.format("Request %s for %s (%s) failed: %s",
    tostring(requestId), request.id, tostring(request.owner), reason))
  if request.onFail and not discard then
    local ok, err = pcall(request.onFail, requestId, reason)
    if not ok then log("E", "vehicleCallbacks", "Request failure path raised: " .. tostring(err)) end
  end
end

-- Fails every pending request `match` selects; collected first so failure paths may open new requests.
local function failWhere(match, reason, discard)
  local ids = {}
  for requestId, request in pairs(requests) do
    if match(request) then ids[#ids + 1] = requestId end
  end
  table.sort(ids)
  for _, requestId in ipairs(ids) do fail(requestId, reason, discard) end
  return #ids
end

local function sweep(t)
  if t < nextSweep then return end
  nextSweep = t + 1
  failWhere(function(request) return request.deadline and t >= request.deadline end, "timed out")
end

local function drop(requestId, id, reason)
  count(stats.dropped, reason)
  log("W", "vehicleCallbacks", string.format("Dropped reply %s to request %s: %s", tostring(id), tostring(requestId), reason))
end

-- Why a pending request can no longer take its answer, or nil.
local function staleReason(request)
  if request.careerEpoch ~= careerEpoch then return "career changed" end
  if request.vehId and (generations[request.vehId] or 0) ~= request.vehicleGeneration then return "vehicle changed" end
  if request.deadline and now() >= request.deadline then return "timed out" end
  return nil
end

-- Delay the scan until first use so callers can require this module before filesystem setup.
function M.load()
  if scanned then return M.callbacks end
  scanned = true
  local owners, rejected = manifests.scan({dir = M.dir, tag = TAG, validate = validate})
  M.rejected = rejected
  for _, owner in ipairs(owners) do
    for _, row in ipairs(owner.callbacks) do
      if M.callbacks[row.id] then
        local reason = "duplicate callback id " .. row.id
        M.rejected[#M.rejected + 1] = {file = owner.file, reason = reason}
        log("W", TAG, string.format("Ignoring %s in %s: %s", row.id, owner.file, reason))
      else
        M.callbacks[row.id] = {extension = row.extension, fn = row.fn, guard = row.guard, owner = owner.id}
      end
    end
  end
  return M.callbacks
end

function M.call(id, ...)
  local entry = M.load()[id]
  return dispatch(id, entry, dispatchTarget(entry), ...)
end

-- Only the request id crosses VMs; captured owner and vehicle identity reject stale replies.
function M.open(id, opts)
  if not M.load()[id] then
    log("E", "vehicleCallbacks", "Request for unknown vehicle callback: " .. tostring(id))
    return nil
  end
  opts = opts or {}
  local t = now()
  sweep(t)
  if opts.supersede then
    local older = {}
    for requestId, request in pairs(requests) do
      if request.id == id and request.owner == opts.owner then older[#older + 1] = requestId end
    end
    for _, requestId in ipairs(older) do finish(requestId, "superseded") end
  end
  local vehId = tonumber(opts.vehId)
  local timeout = opts.timeout
  if timeout == nil then timeout = not opts.repeats and DEFAULT_TIMEOUT end
  nextRequestId = nextRequestId + 1
  local requestId = nextRequestId
  -- Requests are tracked per owner; only the lifetimes in opts.endsWith end them, so other owners keep theirs.
  local host = lifecycle.track(opts.owner, opts.endsWith, {callback = id, onEnded = function(_, scope)
    fail(requestId, scope .. " changed")
  end})
  requests[requestId] = {id = id, owner = opts.owner, instance = loadedOwner(M.load()[id]), careerEpoch = careerEpoch,
    vehId = vehId, vehicleGeneration = vehId and (generations[vehId] or 0), deadline = timeout and (t + timeout) or nil,
    repeats = opts.repeats and true or nil, answers = opts.answers, onFail = opts.onFail, host = host,
    mapEpoch = host.map, profileEpoch = host.profile}
  stats.opened = stats.opened + 1
  return nextRequestId
end

-- Query helper: opens a request for `veh` and queues build(requestId), the vehicle Lua that answers it.
function M.query(veh, id, opts, build)
  if not veh then return nil end
  local options = {}
  for key, value in pairs(opts or {}) do options[key] = value end
  options.vehId = options.vehId or veh:getID()
  local requestId = M.open(id, options)
  if requestId then veh:queueLuaCommand(build(requestId)) end
  return requestId
end

-- Called by the vehicle's answer (see vehicle/overhaul/geCallback.reply).
function M.reply(requestId, id, ...)
  local request = requests[requestId]
  if not request then
    drop(requestId, id, finished[requestId] and ("already " .. finished[requestId]) or "unknown request")
    return
  end
  if request.id ~= id and not (request.answers and request.answers[id]) then
    drop(requestId, id, "request is for " .. request.id)
    return
  end
  local reason = staleReason(request)
  local entry, target = nil, nil
  if not reason then
    entry = M.load()[id]
    -- Lazy resolution may load a replacement, so invoke this exact target and never look it up again.
    target = dispatchTarget(entry)
    if target ~= nil and request.instance ~= nil and target ~= request.instance then reason = "owner changed" end
  end
  if reason then
    -- Failure paths of a changed career or owner close over state that ended, so they do not run.
    fail(requestId, reason, reason == "career changed" or reason == "owner changed")
    drop(requestId, id, reason)
    return
  end
  if request.instance == nil and target ~= nil and entry
    and (entry.guard ~= "function" or target[entry.fn]) then
    request.instance = target
  end
  if not request.repeats then finish(requestId, "answered") end
  count(stats.accepted, id)
  return dispatch(id, entry, target, ...)
end

-- Ends a request without a failure (repeating requests, or an owner that no longer wants the answer).
function M.close(requestId)
  if requests[requestId] then finish(requestId, "closed") end
end

-- Fails every pending request of `owner` (the owner released its activity).
function M.cancelOwner(owner, reason)
  return failWhere(function(request) return request.owner == owner end, reason or "cancelled")
end

-- Discard prior-session requests without invoking callbacks from the discarded owner lifetime.
function M.advanceCareerEpoch(reason)
  careerEpoch = careerEpoch + 1
  return failWhere(function(request) return request.careerEpoch ~= careerEpoch end, "career " .. tostring(reason or "changed"), true)
end

-- Fail pending requests before a destroyed or replaced vehicle id can be reused.
function M.vehicleChanged(vehId, reason)
  vehId = tonumber(vehId)
  if not vehId then return 0 end
  generations[vehId] = (generations[vehId] or 0) + 1
  local failed = failWhere(function(request) return request.vehId == vehId end, "vehicle " .. tostring(reason or "changed"))
  if reason == "destroyed" then generations[vehId] = nil end
  return failed
end

function M.getCareerEpoch() return careerEpoch end
function M.getVehicleGeneration(vehId) return generations[tonumber(vehId)] or 0 end
function M.getPending(requestId) return requests[requestId] end

-- Pending requests of `owner` (host owner tracking).
function M.pendingFor(owner)
  return lifecycle.pending(owner)
end

function M.pendingCount()
  local n = 0
  for _ in pairs(requests) do n = n + 1 end
  return n
end

-- {extension, fn, guard} of a callback id, or nil: the row as the owner manifests state it.
function M.resolve(id)
  local entry = M.load()[id]
  if not entry then return nil end
  return {extension = entry.extension, fn = entry.fn, guard = entry.guard}
end

return M
