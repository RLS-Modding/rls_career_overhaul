-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Build GE-to-vehicle Lua calls from export names and literal arguments.
-- Arguments are data, so quotes, control bytes and nested tables cannot become executable code.
local M = {}

local RESERVED_WORDS = {
  ['and'] = true, ['break'] = true, ['do'] = true, ['else'] = true, ['elseif'] = true,
  ['end'] = true, ['false'] = true, ['for'] = true, ['function'] = true, ['goto'] = true,
  ['if'] = true, ['in'] = true, ['local'] = true, ['nil'] = true, ['not'] = true,
  ['or'] = true, ['repeat'] = true, ['return'] = true, ['then'] = true,
  ['true'] = true, ['until'] = true, ['while'] = true,
}

local function quotedString(value)
  local escaped = value:gsub('[%z\1-\31\127-\255\\"]', function(byte)
    if byte == '\\' then return '\\\\' end
    if byte == '"' then return '\\"' end
    return string.format('\\%03d', string.byte(byte))
  end)
  return '"' .. escaped .. '"'
end

local function scalarLiteral(value)
  local kind = type(value)
  if kind == 'nil' then return 'nil' end
  if kind == 'string' then return quotedString(value) end
  if kind == 'boolean' then return tostring(value) end
  if kind == 'number' then
    assert(value == value and value ~= math.huge and value ~= -math.huge, 'Lua command numbers must be finite')
    return string.format('%.17g', value)
  end
  assert(kind == 'table', 'Unsupported Lua command value: ' .. kind)
end

local function literal(value, visiting)
  local scalar = scalarLiteral(value)
  if scalar then return scalar end
  assert(not visiting[value], 'Lua command tables must not contain cycles')
  visiting[value] = true
  local fields = {}
  for key, item in pairs(value) do
    local kind = type(key)
    assert(kind == 'string' or kind == 'number' or kind == 'boolean', 'Unsupported Lua command table key: ' .. kind)
    fields[#fields + 1] = '[' .. literal(key, visiting) .. ']=' .. literal(item, visiting)
  end
  table.sort(fields)
  visiting[value] = nil
  return '{' .. table.concat(fields, ',') .. '}'
end

local function identifier(value)
  return type(value) == 'string' and value:match('^[_%a][_%w]*$') ~= nil and not RESERVED_WORDS[value]
end

function M.luaLiteral(value)
  return literal(value, {})
end

function M.call(extensionName, functionName, ...)
  assert(identifier(extensionName), 'Invalid vehicle extension name')
  assert(identifier(functionName), 'Invalid vehicle export name')
  local arguments = {}
  for index = 1, select('#', ...) do arguments[index] = M.luaLiteral(select(index, ...)) end
  return extensionName .. '.' .. functionName .. '(' .. table.concat(arguments, ',') .. ')'
end

function M.queue(vehicle, extensionName, functionName, ...)
  return vehicle:queueLuaCommand(M.call(extensionName, functionName, ...))
end

return M
