-- Reads the data grammar written by serialize, without compiling a fleet into one Lua function.
-- Read in order: tokens, strings, tables, values, then the public decoder. Each decode owns its cursor.
local M = {}

local ESCAPES = {a = '\a', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', v = '\v'}
local MAX_DEPTH = 256
local CONSTRUCTOR_ARITY = {vec3 = 3, quat = 4, QuatF = 4}
local readers = {}

local function invalid(reader, reason)
  error('Unreadable serialized save at byte ' .. reader.position .. ': ' .. reason, 0)
end

local function skipSpace(reader)
  local _, last = reader.text:find('^%s*', reader.position)
  reader.position = last + 1
end

local function take(reader, token)
  skipSpace(reader)
  if reader.text:sub(reader.position, reader.position + #token - 1) ~= token then
    invalid(reader, 'expected ' .. token)
  end
  reader.position = reader.position + #token
end

local function readString(reader)
  local text, position = reader.text, reader.position
  local quote, pieces = text:sub(position, position), {}
  position = position + 1
  while true do
    local boundary = text:find('[\\' .. quote .. '\r\n]', position)
    if not boundary then invalid(reader, 'unfinished string') end
    pieces[#pieces + 1] = text:sub(position, boundary - 1)
    local char = text:sub(boundary, boundary)
    if char == quote then
      reader.position = boundary + 1
      return table.concat(pieces)
    end
    if char ~= '\\' then invalid(reader, 'unescaped newline') end
    char = text:sub(boundary + 1, boundary + 1)
    position = boundary + 2
    if char == '' then invalid(reader, 'unfinished escape') end
    if char:match('%d') then
      local digits = text:match('^%d%d?%d?', boundary + 1)
      local number = tonumber(digits)
      if number > 255 then invalid(reader, 'invalid decimal escape') end
      pieces[#pieces + 1] = string.char(number)
      position = boundary + 1 + #digits
    elseif char == 'x' then
      local digits = text:sub(position, position + 1)
      if not digits:match('^%x%x$') then invalid(reader, 'invalid hex escape') end
      pieces[#pieces + 1] = string.char(tonumber(digits, 16))
      position = position + 2
    elseif char == 'z' then
      local _, last = text:find('^%s*', position)
      position = last + 1
    elseif char == '\r' or char == '\n' then
      pieces[#pieces + 1] = '\n'
      if char == '\r' and text:sub(position, position) == '\n' then position = position + 1 end
    else
      local escaped = ESCAPES[char]
      if not escaped and char ~= '\\' and char ~= '"' and char ~= "'" then
        invalid(reader, 'invalid escape')
      end
      pieces[#pieces + 1] = escaped or char
    end
  end
end

local function readNumber(reader)
  local token = reader.text:match('^[%+%-]?[%w%.%+%-]+', reader.position)
  local number = token and tonumber(token)
  if token and token:match('U?LL$') then
    -- Converting through a double would round saved 64-bit counters above 2^53.
    local digits, suffix = token:match('^([%+%-]?%d+)(U?LL)$')
    if not digits then invalid(reader, 'invalid integer') end
    local ffi = require('ffi')
    local value = ffi.new('uint64_t', 0)
    for digit in digits:gmatch('%d') do value = value * 10 + tonumber(digit) end
    if digits:sub(1, 1) == '-' then value = -value end
    number = suffix == 'ULL' and value or ffi.cast('int64_t', value)
  end
  if not number then invalid(reader, 'invalid number') end
  reader.position = reader.position + #token
  return number
end

local function readConstructor(reader, name, depth)
  local arity, constructor = CONSTRUCTOR_ARITY[name], _G[name]
  if not arity or type(constructor) ~= 'function' then invalid(reader, 'unsupported value ' .. name) end
  take(reader, '(')
  local arguments = {}
  for index = 1, arity do
    if index > 1 then take(reader, ',') end
    local value = readers.value(reader, depth + 1)
    if type(value) ~= 'number' then invalid(reader, 'expected numeric constructor argument') end
    arguments[index] = value
  end
  take(reader, ')')
  return constructor(unpack(arguments))
end

local function setEntry(reader, result, key, value)
  if key == nil or key ~= key then invalid(reader, 'invalid table key') end
  result[key] = value
end

local function readTable(reader, depth, keyedSequence)
  take(reader, '{')
  local result, arrayIndex = {}, 1
  while true do
    skipSpace(reader)
    local char = reader.text:sub(reader.position, reader.position)
    if char == '}' then reader.position = reader.position + 1; return result end
    if keyedSequence then
      local key = readers.value(reader, depth + 1)
      take(reader, ';')
      setEntry(reader, result, key, readers.value(reader, depth + 1))
    elseif char == '[' then
      reader.position = reader.position + 1
      local key = readers.value(reader, depth + 1)
      take(reader, ']'); take(reader, '=')
      setEntry(reader, result, key, readers.value(reader, depth + 1))
    else
      -- Named fields also occur in historical saves written by older serializers.
      local name, last = reader.text:match('^([%a_][%w_]*)%s*=()', reader.position)
      if name then
        reader.position = last
        result[name] = readers.value(reader, depth + 1)
      else
        result[arrayIndex] = readers.value(reader, depth + 1)
        arrayIndex = arrayIndex + 1
      end
    end
    skipSpace(reader)
    char = reader.text:sub(reader.position, reader.position)
    if char == ',' or char == ';' then reader.position = reader.position + 1
    elseif char ~= '}' then invalid(reader, 'expected table separator') end
  end
end

readers.value = function(reader, depth)
  if depth > MAX_DEPTH then invalid(reader, 'table nesting is too deep') end
  skipSpace(reader)
  local char = reader.text:sub(reader.position, reader.position)
  if char == '{' then return readTable(reader, depth, false) end
  if char == '"' or char == "'" then return readString(reader) end
  if char:match('[%d%+%-%.]') then return readNumber(reader) end
  local word = reader.text:match('^[%a_][%w_]*', reader.position)
  if not word then invalid(reader, 'expected value') end
  reader.position = reader.position + #word
  if word == 'true' then return true end
  if word == 'false' then return false end
  if word == 'nil' then return nil end
  if word == '_kv' then return readTable(reader, depth, true) end
  return readConstructor(reader, word, depth)
end

-- Missing optional conditions retain deserialize(nil)'s behavior. Malformed data throws before a caller
-- can replace its live inventory or write a migrated file; no partial result escapes this function.
function M.decode(text)
  if text == nil then return nil end
  assert(type(text) == 'string', 'Serialized save must be a string')
  local reader = {text = text, position = 1}
  local value = readers.value(reader, 0)
  skipSpace(reader)
  if reader.position <= #text then invalid(reader, 'trailing data') end
  return value
end

return M
