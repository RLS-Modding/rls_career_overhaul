-- Save JSON: detached captures of save values, and a writer that yields between slices.
-- The bytes written are fixed by the save format; the writer keeps one frame's work within its budget.

local M = {}
local buffer = require('string.buffer')
local byte, find, gsub, sub = string.byte, string.find, string.gsub, string.sub

-- Sequences -----------------------------------------------------------------------------------------

-- A table is a JSON array when its keys are exactly 1..n, wherever they sit in the table.
local function isSequence(value)
  local n = #value
  if n == 0 then return false end
  if next(value) == 1 and next(value, n) == nil then return true end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
    if count > n then return false end
  end
  if count ~= n then return false end
  for i = 1, n do
    if value[i] == nil then return false end
  end
  return true
end
M.isSequence = isSequence

-- Escaping ------------------------------------------------------------------------------------------

-- Same output as the stock escapeString for every byte, in one pass.
local ESCAPES = {['\\'] = '\\\\', ['\n'] = '\\n', ['\t'] = '\\t', ['"'] = '\\"', ['\r'] = '\\r'}

local function escape(text)
  if #text > 64 then
    if not find(text, '[%z\1-\31"\\]') then return text end
  else
    local plain = true
    for i = 1, #text do
      local code = byte(text, i)
      if code < 32 or code == 34 or code == 92 then plain = false; break end
    end
    if plain then return text end
  end
  return (gsub(text, '[\\\n\t"\r]', ESCAPES))
end
M.escape = escape

-- Snapshots and captures ----------------------------------------------------------------------------

-- A deep Lua copy of a save value; cdata is copied through ffi.
function M.snapshot(value, seen)
  local kind = type(value)
  if kind == "cdata" then
    local ffi = require('ffi')
    return ffi.new(ffi.typeof(value), value)
  end
  if kind ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for k, child in pairs(value) do copy[k] = M.snapshot(child, seen) end
  return copy
end

-- Split large roots for bounded decoding; serializer-rejected values retain the snapshot fallback.
local TAG_VALUE, TAG_ARRAY, TAG_OBJECT, TAG_COPY = 0, 1, 2, 3
-- Tables near the root split by entry count; anything larger than SPLIT_BYTES splits down to SPLIT_DEPTH.
local SPLIT_ENTRIES, COUNT_DEPTH, SPLIT_BYTES, SPLIT_DEPTH = 64, 4, 131072, 12
local Captured = {}
local canStream = type(buffer.new().encode) == 'function'
local captureOut, captureScratch = buffer.new(), buffer.new()

local captures = {}

local function split(out, scratch, node, depth, copies)
  if isSequence(node) then
    local n = #node
    out:encode(TAG_ARRAY); out:encode(n)
    for i = 1, n do captures.value(out, scratch, node[i], depth + 1, copies) end
    return
  end
  local keys, n = {}, 0
  for k in pairs(node) do n = n + 1; keys[n] = k end
  scratch:reset()
  if not pcall(scratch.encode, scratch, keys) then
    copies[#copies + 1] = M.snapshot(node); out:encode(TAG_COPY)
    return
  end
  out:encode(TAG_OBJECT); out:put(scratch)
  for i = 1, n do captures.value(out, scratch, node[keys[i]], depth + 1, copies) end
end

captures.value = function(out, scratch, node, depth, copies)
  local kind = type(node)
  if kind ~= 'table' then
    if kind == 'string' or kind == 'number' or kind == 'boolean' then
      out:encode(TAG_VALUE); out:encode(node)
    else
      copies[#copies + 1] = M.snapshot(node); out:encode(TAG_COPY)
    end
    return
  end
  if depth == 0 then return split(out, scratch, node, depth, copies) end
  if depth < COUNT_DEPTH then
    local n = 0
    for _ in pairs(node) do
      n = n + 1
      if n > SPLIT_ENTRIES then return split(out, scratch, node, depth, copies) end
    end
  end
  scratch:reset()
  local ok = pcall(scratch.encode, scratch, node)
  if ok and (#scratch <= SPLIT_BYTES or depth >= SPLIT_DEPTH) then
    out:encode(TAG_VALUE); out:put(scratch)
  elseif depth < SPLIT_DEPTH then
    split(out, scratch, node, depth, copies)
  else
    copies[#copies + 1] = M.snapshot(node); out:encode(TAG_COPY)
  end
end

-- Serialized value, or nil when the serializer refuses it (cdata, functions, cycles).
function M.encode(value)
  if not canStream then return nil end
  local ok, blob = pcall(buffer.encode, value)
  return ok and blob or nil
end

-- Omit fields from serialized copies without mutating live records.
function M.encodeWithout(records, field)
  if not canStream then return nil end
  local held = {}
  for id, record in pairs(records) do
    if type(record) == 'table' and record[field] ~= nil then held[id] = record[field]; record[field] = nil end
  end
  local ok, blob = pcall(buffer.encode, records)
  for id, value in pairs(held) do records[id][field] = value end
  return ok and blob or nil
end

-- Compiled traces crash after a serializer error unwinds through them; the C serializer does the heavy work anyway.
if jit and jit.off then jit.off(captures.value); jit.off(split); jit.off(M.encodeWithout); jit.off(M.encode) end

-- Detached copy of a save value for a later write; mutations after this call are not seen.
function M.capture(value)
  if type(value) ~= 'table' or not canStream then return M.snapshot(value) end
  local copies = {}
  captureOut:reset()
  captures.value(captureOut, captureScratch, value, 0, copies)
  local blob = captureOut:tostring()
  captureOut:reset(); captureScratch:reset()
  return setmetatable({blob = blob, copies = copies[1] and copies or nil}, Captured)
end

function M.isCaptured(value) return getmetatable(value) == Captured end

local function restoreValue(reader, copies, cursor)
  local tag = reader:decode()
  if tag == TAG_VALUE then return reader:decode() end
  if tag == TAG_COPY then
    cursor.copyIndex = cursor.copyIndex + 1
    return M.snapshot(copies[cursor.copyIndex])
  end
  local result = {}
  if tag == TAG_ARRAY then
    for i = 1, reader:decode() do result[i] = restoreValue(reader, copies, cursor) end
  else
    for _, k in ipairs(reader:decode()) do result[k] = restoreValue(reader, copies, cursor) end
  end
  return result
end

-- A fresh Lua table equal to a captured value.
function M.restore(captured)
  if getmetatable(captured) ~= Captured then return M.snapshot(captured) end
  return restoreValue(buffer.new():set(captured.blob), captured.copies, {copyIndex = 0})
end

-- Sliced writer -------------------------------------------------------------------------------------

local CHUNK = 32768
local STRING_PIECE = 8192
-- The clock is read every this many nodes while a slice is open.
local NODES_PER_CLOCK_CHECK = 256

-- Yields to the caller, then starts a fresh frame budget.
local function pauseWriter(job)
  coroutine.yield()
  job.deadline = job.clock() + job.budget
end

-- A quoted string. Long strings are escaped in pieces, so the buffer can flush between pieces.
local function writeString(job, text)
  local buf = job.buf
  local length = #text
  if length <= STRING_PIECE then
    buf:put('"', escape(text), '"')
    return
  end
  buf:put('"')
  for i = 1, length, STRING_PIECE do
    buf:put(escape(sub(text, i, i + STRING_PIECE - 1)))
    if #buf >= CHUNK or job.clock() >= job.deadline then pauseWriter(job) end
  end
  buf:put('"')
end

-- Without a precision option, non-finite numbers use the stock 9e999 spelling.
local function writeNumber(job, number)
  if job.precision then job.buf:put(job.encode(number, job.precision))
  elseif number * 0 == 0 then job.buf:put(number)
  else job.buf:put(number > 0 and '9e999' or '-9e999') end
end

local function writeScalar(job, value)
  local kind = type(value)
  if kind == 'string' then
    writeString(job, value)
  elseif kind == 'number' then
    writeNumber(job, value)
  elseif kind == 'boolean' then
    job.buf:put(value and 'true' or 'false')
  else
    job.buf:put(job.encode(value, job.precision))
  end
end

local values = {}

local function writeSequence(job, sequence)
  job.buf:put('[')
  for i = 1, #sequence do
    if i > 1 then job.buf:put(',') end
    values.write(job, sequence[i])
  end
  job.buf:put(']')
end

local function writeObject(job, object)
  job.buf:put('{')
  local first = true
  for key, child in pairs(object) do
    if first then first = false else job.buf:put(',') end
    writeString(job, type(key) == 'string' and key or tostring(key))
    job.buf:put(':')
    values.write(job, child)
  end
  job.buf:put('}')
end

-- One value of the live tree. Cycles are refused; each finished value counts toward the slice.
values.write = function(job, value)
  if type(value) ~= 'table' then
    writeScalar(job, value)
  else
    assert(not job.active[value], 'Cyclic save data')
    job.active[value] = true
    if isSequence(value) then writeSequence(job, value) else writeObject(job, value) end
    job.active[value] = nil
  end
  job.nodes = job.nodes + 1
  if #job.buf >= CHUNK or (job.nodes % NODES_PER_CLOCK_CHECK == 0 and job.clock() >= job.deadline) then
    pauseWriter(job)
  end
end

-- A captured snapshot, written in the order it was captured. Copied subtrees come from the copy list in order.
local function writeCapturedBlob(job, captured)
  local reader, copies, copied = buffer.new():set(captured.blob), captured.copies, 0
  local function writeNext()
    local tag = reader:decode()
    if tag == TAG_VALUE then return values.write(job, reader:decode()) end
    if tag == TAG_COPY then
      copied = copied + 1
      return values.write(job, copies[copied])
    end
    if tag == TAG_ARRAY then
      job.buf:put('[')
      for i = 1, reader:decode() do
        if i > 1 then job.buf:put(',') end
        writeNext()
      end
      job.buf:put(']')
    else
      job.buf:put('{')
      for i, k in ipairs(reader:decode()) do
        if i > 1 then job.buf:put(',') end
        writeString(job, type(k) == 'string' and k or tostring(k))
        job.buf:put(':')
        writeNext()
      end
      job.buf:put('}')
    end
  end
  writeNext()
end

-- The first step of a job: the frame budget starts here, then the snapshot is written.
local function encodeSnapshot(job)
  job.nodes, job.deadline = 0, job.clock() + job.budget
  local snapshot = job.snapshot
  if getmetatable(snapshot) ~= Captured then return values.write(job, snapshot) end
  return writeCapturedBlob(job, snapshot)
end

local function closeFile(job)
  if job.file then
    local file = job.file
    job.file = nil
    return file:close()
  end
  return true
end

-- Writes the buffered bytes after one resume of the encoder, then reports the step to the timing hook.
local function stepJob(job, budgetMs)
  if job.done then return true end
  if budgetMs then job.budget = budgetMs end
  local started = job.clock()
  local ok, err = coroutine.resume(job.thread)
  local elapsed = job.clock() - started
  job.encodeMs, job.slices = job.encodeMs + elapsed, job.slices + 1
  if not ok then closeFile(job); error(err) end
  started = job.clock()
  job.file = job.file or assert(job.options.open(job.filename, 'wb'))
  local n = #job.buf
  if n > 0 then assert(job.file:write(job.buf:get())) end
  job.bytes = job.bytes + n
  job.done = coroutine.status(job.thread) == 'dead'
  if job.done then assert(closeFile(job)); job.thread, job.snapshot = nil, nil end
  local written = job.clock() - started
  job.writeMs = job.writeMs + written
  if job.options.timing then
    job.options.timing(job.filename, elapsed, written, n, job.done, job.encodeMs, job.writeMs, job.slices, job.bytes)
  end
  return job.done
end

-- Each slice retains the existing clock checks and byte stream while allowing the caller to yield.
function M.writer(filename, snapshot, options)
  local job = {
    filename = filename, snapshot = snapshot, options = options,
    clock = options.clock, encode = options.encode, precision = options.precision,
    budget = options.budgetMs or 2, buf = buffer.new(CHUNK + STRING_PIECE * 2), active = {},
    encodeMs = 0, writeMs = 0, bytes = 0, slices = 0, done = false,
  }
  job.thread = coroutine.create(function() encodeSnapshot(job) end)
  local handle = {}
  function handle.cancel()
    closeFile(job)
    job.thread, job.snapshot = nil, nil
  end
  function handle.step(budgetMs)
    return stepJob(job, budgetMs)
  end
  return handle
end

return M
