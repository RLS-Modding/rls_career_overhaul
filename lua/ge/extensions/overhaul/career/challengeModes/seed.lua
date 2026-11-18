-- Shareable career challenge seeds: binary codec, name resolution, random generation and import.
-- Map: format, binary values, catalogs, name hashes, variables, codec, generation, import and public API.
local M = {}
local challengeRounding = require('overhaul/lib/career/challengeRounding')
local levelData = require('overhaul/lib/world/levelData')
local seedStartSections = require('overhaul/career/challengeModes/seedStartSections')

-- Parts ---------------------------------------------------------------------------------------------

local parts = {}

-- Format --------------------------------------------------------------------------------------------

do
  local format = {}

  -- Reserved: no writer emits these yet.
  format.MARKER_WIN_CONDITION_DATA = 0x01
  format.MARKER_RUN_LENGTH = 0x20

  format.MARKER_LOANS = 0x02
  format.MARKER_ECONOMY_ADJUSTER = 0x03
  format.MARKER_STARTING_GARAGES = 0x04
  format.MARKER_DIFFICULTY = 0x05
  format.MARKER_MAP = 0x06
  -- Named-format only: older readers reject these markers, so seeds without them stay readable everywhere.
  format.MARKER_STARTER_VEHICLES = 0x07
  format.MARKER_STARTING_GARAGE_MODE = 0x08
  format.MARKER_VARIABLE_NUMBER = 0x10
  format.MARKER_VARIABLE_INTEGER = 0x11
  format.MARKER_VARIABLE_BOOLEAN = 0x12
  format.MARKER_VARIABLE_STRING = 0x13
  format.MARKER_VARIABLE_TABLE = 0x14
  format.MARKER_END = 0xFF

  format.MAX_SEED_LENGTH = 8192
  format.MAX_UINT16 = 65535

  parts.format = format
end

-- Binary --------------------------------------------------------------------------------------------

do
  local binary = {}

  local BASE_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/!@#$%^&=()[]{}|\\:;\"'<>,.?~`"
  local CHAR_VALUES = {}
  for index = 1, #BASE_CHARS do
    CHAR_VALUES[BASE_CHARS:sub(index, index)] = index - 1
  end

  -- Base90 --------------------------------------------------------------------------------------------

  -- One output character: the base-90 digit of `packed` at `place`.
  local function digitChar(packed, place)
    local digit = math.floor(packed / place) % 90 + 1
    return BASE_CHARS:sub(digit, digit)
  end

  -- Packs 3 bytes into 4 characters (90^4 = 65,610,000 > 16,777,216 = 2^24); a short tail is zero-padded.
  function binary.encodeBase90(bytes)
    local chars = {}
    for start = 1, #bytes, 3 do
      local first = string.byte(bytes, start)
      local second = start + 1 <= #bytes and string.byte(bytes, start + 1) or 0
      local third = start + 2 <= #bytes and string.byte(bytes, start + 2) or 0
      local packed = first * 65536 + second * 256 + third
      table.insert(chars, digitChar(packed, 729000))
      table.insert(chars, digitChar(packed, 8100))
      table.insert(chars, digitChar(packed, 90))
      table.insert(chars, digitChar(packed, 1))
    end
    return table.concat(chars)
  end

  function binary.isBase90Char(char)
    return CHAR_VALUES[char] ~= nil
  end

  local function charValueAt(text, position)
    return CHAR_VALUES[text:sub(position, position)] or 0
  end

  -- Unpacks 4 characters into up to 3 bytes; a short tail yields only the bytes it carries.
  function binary.decodeBase90(text)
    local bytes = {}
    for start = 1, #text, 4 do
      local packed = charValueAt(text, start) * 729000 + charValueAt(text, start + 1) * 8100
        + charValueAt(text, start + 2) * 90 + charValueAt(text, start + 3)
      table.insert(bytes, string.char(math.floor(packed / 65536) % 256))
      if start + 1 <= #text then table.insert(bytes, string.char(math.floor(packed / 256) % 256)) end
      if start + 2 <= #text then table.insert(bytes, string.char(packed % 256)) end
    end
    return table.concat(bytes)
  end

  -- Fixed-width integers ------------------------------------------------------------------------------

  function binary.writeUint16(buffer, value)
    table.insert(buffer, string.char(math.floor(value / 256) % 256))
    table.insert(buffer, string.char(value % 256))
  end

  function binary.readUint16(bytes, offset)
    if offset + 1 > #bytes then
      return nil, offset, "Unexpected end of seed data"
    end
    local high, low = string.byte(bytes, offset, offset + 1)
    return high * 256 + low, offset + 2
  end

  function binary.writeUint32(buffer, value)
    table.insert(buffer, string.char(math.floor(value / 16777216) % 256))
    table.insert(buffer, string.char(math.floor(value / 65536) % 256))
    table.insert(buffer, string.char(math.floor(value / 256) % 256))
    table.insert(buffer, string.char(value % 256))
  end

  function binary.readUint32(bytes, offset)
    if offset + 3 > #bytes then
      return nil, offset, "Unexpected end of seed data"
    end
    local first, second, third, fourth = string.byte(bytes, offset, offset + 3)
    return first * 16777216 + second * 65536 + third * 256 + fourth, offset + 4
  end

  -- Names: a 16-bit length, then the text. Empty and oversized names cannot be written.
  function binary.writeName(buffer, name)
    if type(name) ~= "string" or #name == 0 or #name > parts.format.MAX_UINT16 then error("Invalid seed name") end
    binary.writeUint16(buffer, #name)
    table.insert(buffer, name)
  end

  function binary.readName(bytes, offset)
    local length, nextOffset = binary.readUint16(bytes, offset)
    if not length or length == 0 or nextOffset + length - 1 > #bytes then
      return nil, offset, "Incomplete seed name"
    end
    return bytes:sub(nextOffset, nextOffset + length - 1), nextOffset + length
  end

  -- Variable-length integers --------------------------------------------------------------------------

  -- A marker byte picks the width: 0 = one byte, 1 = two bytes, 2 = four bytes.
  function binary.writeVarInt(buffer, value)
    if value < 0 then
      error("VarInt does not support negative values")
    end
    if value <= 255 then
      table.insert(buffer, string.char(0))
      table.insert(buffer, string.char(value))
    elseif value <= parts.format.MAX_UINT16 then
      table.insert(buffer, string.char(1))
      table.insert(buffer, string.char(math.floor(value / 256)))
      table.insert(buffer, string.char(value % 256))
    else
      table.insert(buffer, string.char(2))
      binary.writeUint32(buffer, value)
    end
  end

  function binary.readVarInt(bytes, offset)
    if offset > #bytes then
      return nil, offset, "Incomplete VarInt data"
    end
    local marker = string.byte(bytes, offset)
    offset = offset + 1
    if marker == 0 then
      if offset > #bytes then
        return nil, offset, "Incomplete VarInt data"
      end
      return string.byte(bytes, offset), offset + 1
    elseif marker == 1 then
      if offset + 1 > #bytes then
        return nil, offset, "Incomplete VarInt data"
      end
      local high, low = string.byte(bytes, offset, offset + 1)
      return high * 256 + low, offset + 2
    elseif marker == 2 then
      return binary.readUint32(bytes, offset)
    end
    return nil, offset, "Invalid VarInt marker"
  end

  -- Decimals are stored as a sign bit plus a thousandths mantissa, inside one var-int.
  function binary.writeFloat(buffer, value)
    local sign = value < 0 and 1 or 0
    local mantissa = math.min(2147483647, math.floor(math.abs(value) * 1000))
    binary.writeVarInt(buffer, sign * 2147483648 + mantissa)
  end

  function binary.readFloat(bytes, offset)
    local encoded, nextOffset, err = binary.readVarInt(bytes, offset)
    if err or not encoded then
      return nil, nextOffset, err or "Invalid number data"
    end
    local sign = math.floor(encoded / 2147483648) % 2
    local value = (encoded % 2147483648) / 1000
    if sign == 1 then
      value = -value
    end
    return value, nextOffset
  end

  parts.binary = binary
end

-- Catalog -------------------------------------------------------------------------------------------

do
  local catalog = {}

  -- Both catalog owners are boot-loaded; query them directly and validate their returned data.

  -- Win conditions ------------------------------------------------------------------------------------

  function catalog.getWinConditionIds()
    local list = overhaul_career_challengeModes.getWinConditions()
    if not list then
      return {}
    end
    local ids = {}
    for _, entry in ipairs(list) do
      local entryId = type(entry) == "table" and entry.id or entry
      if type(entryId) == "string" and entryId ~= "" then
        table.insert(ids, entryId)
      end
    end
    return ids
  end

  function catalog.getWinConditionVariableDefinitions(winConditionId)
    if not winConditionId then
      return {}
    end
    for _, entry in ipairs(overhaul_career_challengeModes.getWinConditions() or {}) do
      if entry.id == winConditionId and entry.variables then
        return entry.variables
      end
    end
    return {}
  end

  function catalog.winConditionRequiresLoans(winConditionId)
    for _, entry in ipairs(overhaul_career_challengeModes.getWinConditions() or {}) do
      if type(entry) == "table" and entry.id == winConditionId then
        return entry.requiresLoans == true
      end
    end
    return false
  end

  -- Activity types and module hierarchy ---------------------------------------------------------------

  function catalog.getActivityTypeIds()
    local list = overhaul_career_economyAdjuster.getAvailableTypes()
    if type(list) == "table" then
      return list
    end

    local editorData = overhaul_career_challengeModes.getChallengeEditorData()
    if not (editorData and editorData.activityTypes) then
      return {}
    end
    local ids = {}
    for _, entry in ipairs(editorData.activityTypes) do
      local entryId = type(entry) == "table" and (entry.id or entry.name) or entry
      if type(entryId) == "string" and entryId ~= "" then
        table.insert(ids, entryId)
      end
    end
    return ids
  end

  -- Maps each parent module ("<name>_module" source) to its child activity types.
  function catalog.getModuleHierarchy()
    local typesBySource = overhaul_career_economyAdjuster.getTypesBySource()
    if not typesBySource then
      return {}
    end
    local hierarchy = {}
    for sourceName, types in pairs(typesBySource) do
      if sourceName:match("_module$") then
        local parentModule = sourceName:gsub("_module$", "")
        hierarchy[parentModule] = {}
        for _, typeName in ipairs(types) do
          if typeName ~= parentModule then
            table.insert(hierarchy[parentModule], typeName)
          end
        end
      end
    end
    return hierarchy
  end

  -- A child is disabled when some parent module with a 0 multiplier lists it.
  local function hasDisabledParent(activityType, hierarchy, economyAdjuster)
    for parentType, children in pairs(hierarchy) do
      for _, childType in ipairs(children) do
        if childType == activityType and economyAdjuster[parentType] == 0 then return true end
      end
    end
    return false
  end

  -- Drops children that a disabled parent already covers; a child changed from 1.0 is kept as an explicit override.
  function catalog.filterDisabledSubModules(economyAdjuster)
    if not economyAdjuster or type(economyAdjuster) ~= "table" then
      return economyAdjuster
    end
    local filtered = {}
    local hierarchy = catalog.getModuleHierarchy()
    for activityType, multiplier in pairs(economyAdjuster) do
      if multiplier == 0 then
        filtered[activityType] = multiplier
        for _, childType in ipairs(hierarchy[activityType] or {}) do
          local childMultiplier = economyAdjuster[childType]
          if childMultiplier and childMultiplier ~= 1.0 then
            filtered[childType] = childMultiplier
          end
        end
      elseif not hasDisabledParent(activityType, hierarchy, economyAdjuster) or multiplier ~= 1.0 then
        filtered[activityType] = multiplier
      end
    end
    return filtered
  end

  -- Garages -------------------------------------------------------------------------------------------

  -- mapId limits the list to one map's garages; without it every compatible map is included.
  function catalog.getAvailableGarageIds(mapId)
    local ids = {}
    -- challengeModes is always loaded at boot, so its garage list needs no guard.
    local garages = overhaul_career_challengeModes.getAvailableGarages()
    for _, garage in ipairs(garages) do
      if garage.id and type(garage.id) == "string" and garage.id ~= "" and (not mapId or garage.mapId == mapId) then
        table.insert(ids, garage.id)
      end
    end
    return ids
  end

  parts.catalog = catalog
end

-- NameHash ------------------------------------------------------------------------------------------

do
  local nameHash = {}

  local HASH_PREFIX = "_hash_"

  function nameHash.simpleHash(text)
    local hash = 0
    for index = 1, #text do
      hash = (hash * 31 + string.byte(text, index)) % 65536
    end
    return hash
  end

  -- Returns the hash carried by a "_hash_<n>" placeholder, or nil when the text is not one.
  local function placeholderHash(text)
    if text:sub(1, #HASH_PREFIX) == HASH_PREFIX then
      return tonumber(text:sub(#HASH_PREFIX + 1))
    end
    return nil
  end

  local function firstNameWithHash(names, hash)
    for _, name in ipairs(names) do
      if nameHash.simpleHash(name) == hash then
        return name
      end
    end
    return nil
  end

  -- Win condition -------------------------------------------------------------------------------------

  function nameHash.resolveWinConditionFromHash(challengeData)
    local available = parts.catalog.getWinConditionIds()
    for _, conditionName in ipairs(available) do
      if nameHash.simpleHash(conditionName) == challengeData._winConditionHash then
        challengeData.winCondition = conditionName
        break
      end
    end
    if not challengeData.winCondition then
      challengeData.winCondition = available[1] or "payOffLoan"
    end
  end

  local function resolveWinConditionName(decodedChallenge)
    local winConditions = parts.catalog.getWinConditionIds()
    local matched = firstNameWithHash(winConditions, decodedChallenge._winConditionHash)
    if matched then
      decodedChallenge.winCondition = matched
    end
    if not decodedChallenge.winCondition then
      decodedChallenge.winCondition = winConditions[1]
    end
  end

  local function fillMissingVariableDefaults(decodedChallenge)
    local definitions = parts.catalog.getWinConditionVariableDefinitions(decodedChallenge.winCondition)
    for variableName, definition in pairs(definitions) do
      if decodedChallenge[variableName] == nil and definition.default ~= nil then
        decodedChallenge[variableName] = definition.default
      end
    end
  end

  -- Economy, garages and map --------------------------------------------------------------------------

  local function resolveEconomyAdjusterKeys(adjuster)
    local availableTypes = parts.catalog.getActivityTypeIds()
    local resolved = {}
    for key, multiplier in pairs(adjuster) do
      if key:sub(1, #HASH_PREFIX) == HASH_PREFIX then
        local activityType = firstNameWithHash(availableTypes, tonumber(key:sub(#HASH_PREFIX + 1)))
        if activityType then
          resolved[activityType] = multiplier
        end
      else
        resolved[key] = multiplier
      end
    end
    return resolved
  end

  local function resolveStartingGarages(entries)
    local availableGarages = parts.catalog.getAvailableGarageIds()
    local resolved = {}
    for _, entry in ipairs(entries) do
      if entry:sub(1, #HASH_PREFIX) == HASH_PREFIX then
        local garageId = firstNameWithHash(availableGarages, tonumber(entry:sub(#HASH_PREFIX + 1)))
        if garageId then
          table.insert(resolved, garageId)
        end
      else
        table.insert(resolved, entry)
      end
    end
    return resolved
  end

  -- Unknown maps are cleared rather than kept as a placeholder.
  local function resolveMapHash(decodedChallenge)
    if not (decodedChallenge.map and decodedChallenge.map:sub(1, #HASH_PREFIX) == HASH_PREFIX) then
      return
    end
    local hash = tonumber(decodedChallenge.map:sub(#HASH_PREFIX + 1))
    local mapId = nil
    for candidateId in pairs(overhaul_world_maps.getCompatibleMaps() or {}) do
      if nameHash.simpleHash(candidateId) == hash then
        mapId = candidateId
        break
      end
    end
    decodedChallenge.map = mapId
  end

  -- Target garages keep names the catalog knows, resolve hashes, and keep anything else as written.
  local function targetGarageHash(entry)
    if type(entry) == "string" then
      if entry:sub(1, #HASH_PREFIX) == HASH_PREFIX then
        return tonumber(entry:sub(#HASH_PREFIX + 1))
      end
      return tonumber(entry)
    elseif type(entry) == "number" then
      return entry
    end
    return nil
  end

  local function resolveTargetGarages(entries)
    local availableGarages = parts.catalog.getAvailableGarageIds()
    local resolved = {}
    for _, entry in ipairs(entries) do
      local isKnownGarage = false
      if type(entry) == "string" then
        for _, garageId in ipairs(availableGarages) do
          if entry == garageId then
            table.insert(resolved, entry)
            isKnownGarage = true
            break
          end
        end
      end
      if not isKnownGarage then
        local hash = targetGarageHash(entry)
        if hash then
          local garageId = firstNameWithHash(availableGarages, hash)
          if garageId then
            table.insert(resolved, garageId)
          end
        else
          table.insert(resolved, entry)
        end
      end
    end
    return resolved
  end

  -- Full resolution -----------------------------------------------------------------------------------

  -- Turns the hashes of a decoded challenge into names. Named-format seeds stop after the defaults.
  function nameHash.resolveHashesToNames(decodedChallenge)
    if not decodedChallenge then
      return nil, "No challenge data"
    end

    resolveWinConditionName(decodedChallenge)
    decodedChallenge._winConditionHash = nil
    fillMissingVariableDefaults(decodedChallenge)

    if decodedChallenge._seedFormatVersion == 2 then
      decodedChallenge._seedFormatVersion = nil
      return decodedChallenge
    end

    if decodedChallenge.economyAdjuster then
      decodedChallenge.economyAdjuster = resolveEconomyAdjusterKeys(decodedChallenge.economyAdjuster)
    end
    if decodedChallenge.startingGarages then
      decodedChallenge.startingGarages = resolveStartingGarages(decodedChallenge.startingGarages)
    end
    resolveMapHash(decodedChallenge)
    if decodedChallenge.winCondition == "ownSpecificGarage" and decodedChallenge.targetGarages then
      decodedChallenge.targetGarages = resolveTargetGarages(decodedChallenge.targetGarages)
    end

    return decodedChallenge
  end

  parts.nameHash = nameHash
end

-- Variables -----------------------------------------------------------------------------------------

do
  local variables = {}

  local function coerceVariableValue(marker, value)
    if marker == parts.format.MARKER_VARIABLE_BOOLEAN then
      return value == true or value == 1 or value == "true"
    elseif marker == parts.format.MARKER_VARIABLE_STRING then
      local text = tostring(value)
      if #text > parts.format.MAX_UINT16 then return nil end
      return text
    elseif marker == parts.format.MARKER_VARIABLE_TABLE then
      local items = type(value) == "table" and value or { value }
      local out = {}
      for _, item in ipairs(items) do
        local text = tostring(item)
        if #text <= parts.format.MAX_UINT16 then
          table.insert(out, text)
        end
        if #out >= parts.format.MAX_UINT16 then break end
      end
      return out
    end
    local number = tonumber(value)
    if not challengeRounding.isFiniteNumber(number) then return nil end
    return number
  end

  local function variableMarkerForType(typeName)
    if typeName == "boolean" then
      return parts.format.MARKER_VARIABLE_BOOLEAN
    elseif typeName == "string" then
      return parts.format.MARKER_VARIABLE_STRING
    elseif typeName == "integer" then
      return parts.format.MARKER_VARIABLE_INTEGER
    elseif typeName == "multiselect" or typeName == "array" then
      return parts.format.MARKER_VARIABLE_TABLE
    end
    return parts.format.MARKER_VARIABLE_NUMBER
  end

  local function clampToLimits(value, definition)
    if definition.min and value < definition.min then
      value = definition.min
    end
    if definition.max and value > definition.max then
      value = definition.max
    end
    return value
  end

  -- Encoding ------------------------------------------------------------------------------------------

  function variables.encodeVariable(buffer, variableName, definition, value)
    if value == nil then
      return
    end

    local typeName = definition and definition.type or "number"
    local marker = variableMarkerForType(typeName)
    value = coerceVariableValue(marker, value)
    if value == nil then
      return
    end

    table.insert(buffer, string.char(marker))
    parts.binary.writeName(buffer, variableName)

    if marker == parts.format.MARKER_VARIABLE_BOOLEAN then
      table.insert(buffer, string.char(value and 1 or 0))
    elseif marker == parts.format.MARKER_VARIABLE_STRING then
      parts.binary.writeUint16(buffer, #value)
      table.insert(buffer, value)
    elseif marker == parts.format.MARKER_VARIABLE_TABLE then
      parts.binary.writeUint16(buffer, #value)
      for _, item in ipairs(value) do
        parts.binary.writeUint16(buffer, #item)
        table.insert(buffer, item)
      end
    else
      if definition then
        value = clampToLimits(value, definition)
      end
      local step = definition and tonumber(definition.step) or 1
      if step <= 0 then step = 1 end
      parts.binary.writeFloat(buffer, math.floor((value / step) + 0.5))
    end
  end

  -- Decoding ------------------------------------------------------------------------------------------

  -- Returns the value, the next offset, or nil, offset and the reason when the bytes are short.
  local function readVariableValue(marker, bytes, offset)
    if marker == parts.format.MARKER_VARIABLE_BOOLEAN then
      if offset > #bytes then
        return nil, offset, "Incomplete variable data"
      end
      return string.byte(bytes, offset) ~= 0, offset + 1
    elseif marker == parts.format.MARKER_VARIABLE_STRING then
      local length = nil
      length, offset = parts.binary.readUint16(bytes, offset)
      if not length or offset + length - 1 > #bytes then
        return nil, offset, "Incomplete variable data"
      end
      return bytes:sub(offset, offset + length - 1), offset + length
    elseif marker == parts.format.MARKER_VARIABLE_TABLE then
      local count = nil
      count, offset = parts.binary.readUint16(bytes, offset)
      if not count then
        return nil, offset, "Incomplete table data"
      end
      local value = {}
      for _ = 1, count do
        local itemLength = nil
        itemLength, offset = parts.binary.readUint16(bytes, offset)
        if not itemLength or offset + itemLength - 1 > #bytes then
          return nil, offset, "Incomplete table item data"
        end
        table.insert(value, bytes:sub(offset, offset + itemLength - 1))
        offset = offset + itemLength
      end
      return value, offset
    end

    local decoded, nextOffset, err = parts.binary.readFloat(bytes, offset)
    if decoded == nil then
      return nil, nextOffset, "Failed to read variable value: " .. tostring(err)
    end
    if marker == parts.format.MARKER_VARIABLE_INTEGER then
      decoded = math.floor(decoded + 0.5)
    end
    return decoded, nextOffset
  end

  -- Finds the definition whose name (or name hash, for older seeds) matches the key read from the seed.
  local function findVariableDefinition(variableDefinitions, namedFormat, nameKey)
    for name, definition in pairs(variableDefinitions or {}) do
      if (namedFormat and name == nameKey) or (not namedFormat and parts.nameHash.simpleHash(name) == nameKey) then
        return name, definition
      end
    end
    return nil, nil
  end

  -- Stores one decoded variable on the challenge; unknown older-seed keys are kept under a "_var_" name.
  function variables.decodeVariable(challengeData, variableDefinitions, marker, bytes, offset, namedFormat)
    local nameKey = nil
    if namedFormat then
      nameKey, offset = parts.binary.readName(bytes, offset)
    else
      nameKey, offset = parts.binary.readUint16(bytes, offset)
    end
    if not nameKey then
      return nil, offset, "Incomplete variable data"
    end

    local value, valueError = nil, nil
    value, offset, valueError = readVariableValue(marker, bytes, offset)
    if valueError then
      return nil, offset, valueError
    end

    local variableName, definition = findVariableDefinition(variableDefinitions, namedFormat, nameKey)
    variableName = variableName or (namedFormat and nameKey or ("_var_" .. tostring(nameKey)))

    if definition and definition.step and definition.step ~= 1 and type(value) == "number" then
      value = value * definition.step
    end
    if definition and type(value) == "number" then
      value = clampToLimits(value, definition)
    end

    challengeData[variableName] = value
    return challengeData, offset
  end

  parts.variables = variables
end

-- Codec ---------------------------------------------------------------------------------------------

do
  local codec = {}

  local SEED_PREFIX = "RLS-SEED:2:"
  local DEFAULT_STARTING_CAPITAL = 10000
  local DIFFICULTY_VALUES = { Easy = 0, Medium = 1, Hard = 2, Impossible = 3 }
  local DIFFICULTY_NAMES = { [0] = "Easy", [1] = "Medium", [2] = "Hard", [3] = "Impossible" }
  local DEFAULT_LOAN_INTEREST = 0.10

  -- Encoding ------------------------------------------------------------------------------------------

  -- Stage each section separately so failed writes cannot corrupt the seed.
  local function appendSection(buffer, sectionName, writer)
    local section = {}
    local succeeded, err = pcall(writer, section)
    if not succeeded then
      return false, string.format("Failed to encode %s: %s", sectionName, tostring(err))
    end
    for _, chunk in ipairs(section) do
      table.insert(buffer, chunk)
    end
    return true
  end

  -- Version "major.minor" as one byte: a nibble each, both capped at 15.
  local function encodeVersionByte(versionText)
    local major, minor = versionText:match("(%d+)%.(%d+)")
    major = math.min(15, tonumber(major) or 1)
    minor = math.min(15, tonumber(minor) or 0)
    return (major * 16 + minor) % 256
  end

  -- Header: version byte, 16-bit win condition hash, then the 32-bit starting capital.
  local function encodeHeader(buffer, challengeData, startingCapital, winCondition)
    local winConditionHash = parts.nameHash.simpleHash(winCondition)
    local versionByte = encodeVersionByte(tostring(challengeData.version or "1.0"))
    table.insert(buffer, string.char(versionByte))
    table.insert(buffer, string.char(math.floor(winConditionHash / 256) % 256))
    table.insert(buffer, string.char(winConditionHash % 256))
    parts.binary.writeUint32(buffer, startingCapital)
  end

  local function encodeDifficulty(buffer, challengeData)
    local difficultyValue = DIFFICULTY_VALUES[challengeData.difficulty or "Medium"] or 1
    table.insert(buffer, string.char(parts.format.MARKER_DIFFICULTY))
    table.insert(buffer, string.char(difficultyValue))
  end

  -- A variable is written only when it differs from its definition's default.
  local function encodeVariableSections(buffer, challengeData, winCondition)
    local variableDefinitions = parts.catalog.getWinConditionVariableDefinitions(winCondition) or {}
    for variableName, definition in pairs(variableDefinitions) do
      local value = challengeData[variableName]
      if value ~= nil and (definition.default == nil or value ~= definition.default) then
        local succeeded, err = appendSection(buffer, "variable " .. tostring(variableName), function(section)
          parts.variables.encodeVariable(section, variableName, definition, value)
        end)
        if not succeeded then return false, err end
      end
    end
    return true
  end

  local function encodeLoanSection(buffer, challengeData)
    local loans = type(challengeData.loans) == "table" and challengeData.loans or nil
    local loanAmount = loans and challengeRounding.roundLoanAmount(tonumber(loans.amount)) or 0
    if not (loanAmount > 0) then return true end

    local interest = tonumber(loans.interest)
    if not challengeRounding.isFiniteNumber(interest) then interest = DEFAULT_LOAN_INTEREST end
    local payments = math.max(0, math.min(255, math.floor(tonumber(loans.payments) or 12)))
    return appendSection(buffer, "loans", function(section)
      table.insert(section, string.char(parts.format.MARKER_LOANS))
      parts.binary.writeVarInt(section, loanAmount)
      parts.binary.writeFloat(section, interest)
      table.insert(section, string.char(payments))
    end)
  end

  -- Only multipliers other than 1.0 are written; each is stored as a whole number of economy steps.
  local function encodeEconomySections(buffer, challengeData)
    if type(challengeData.economyAdjuster) ~= "table" then return true end
    local filtered = parts.catalog.filterDisabledSubModules(challengeData.economyAdjuster)
    for activityType, multiplier in pairs(filtered) do
      local numeric = tonumber(multiplier)
      if type(activityType) == "string" and challengeRounding.isFiniteNumber(numeric) and numeric ~= 1.0 then
        local stepMultiple = challengeRounding.economyMultiplierToSteps(numeric)
        local succeeded, err = appendSection(buffer, "economy multiplier " .. activityType, function(section)
          table.insert(section, string.char(parts.format.MARKER_ECONOMY_ADJUSTER))
          parts.binary.writeName(section, activityType)
          parts.binary.writeVarInt(section, stepMultiple)
        end)
        if not succeeded then return false, err end
      end
    end
    return true
  end

  local function encodeGarageSection(buffer, challengeData)
    local garages = challengeData.startingGarages
    if type(garages) ~= "table" or #garages == 0 then return true end
    return appendSection(buffer, "starting garages", function(section)
      table.insert(section, string.char(parts.format.MARKER_STARTING_GARAGES))
      parts.binary.writeVarInt(section, #garages)
      for _, garageId in ipairs(garages) do
        parts.binary.writeName(section, tostring(garageId))
      end
    end)
  end

  local startSections = seedStartSections.create({
    binary = parts.binary,
    format = parts.format,
    appendSection = appendSection,
  })

  local function encodeMapSection(buffer, challengeData)
    local map = challengeData.map
    if type(map) ~= "string" or map == "" then return true end
    return appendSection(buffer, "map", function(section)
      table.insert(section, string.char(parts.format.MARKER_MAP))
      parts.binary.writeName(section, map)
    end)
  end

  -- Encodes a challenge table as a seed string; returns nil and a reason when it cannot be encoded.
  function codec.encodeChallengeToSeed(challengeData)
    if type(challengeData) ~= "table" then
      return nil, "No challenge data provided"
    end

    local rawCapital = challengeData.startingCapital
    if rawCapital == nil then rawCapital = DEFAULT_STARTING_CAPITAL end
    local startingCapital = challengeRounding.roundStartingCapital(tonumber(rawCapital))

    local winConditionIds = parts.catalog.getWinConditionIds()
    if #winConditionIds == 0 then
      return nil, "No win conditions available"
    end
    local winCondition = challengeData.winCondition or winConditionIds[1]
    if type(winCondition) ~= "string" or winCondition == "" then
      return nil, "Invalid win condition"
    end

    local buffer = {}
    encodeHeader(buffer, challengeData, startingCapital, winCondition)
    local nameOk, nameErr = appendSection(buffer, "win condition", function(section)
      parts.binary.writeName(section, winCondition)
    end)
    if not nameOk then return nil, nameErr end
    encodeDifficulty(buffer, challengeData)

    local succeeded, err = encodeVariableSections(buffer, challengeData, winCondition)
    if not succeeded then return nil, err end
    succeeded, err = encodeLoanSection(buffer, challengeData)
    if not succeeded then return nil, err end
    succeeded, err = encodeEconomySections(buffer, challengeData)
    if not succeeded then return nil, err end
    succeeded, err = encodeGarageSection(buffer, challengeData)
    if not succeeded then return nil, err end
    succeeded, err = encodeMapSection(buffer, challengeData)
    if not succeeded then return nil, err end
    succeeded, err = startSections.encode(buffer, challengeData)
    if not succeeded then return nil, err end

    table.insert(buffer, string.char(parts.format.MARKER_END))
    local seed = SEED_PREFIX .. parts.binary.encodeBase90(table.concat(buffer))
    if #seed > parts.format.MAX_SEED_LENGTH then return nil, "Seed is too long" end
    return seed
  end

  -- Decoding ------------------------------------------------------------------------------------------

  -- Strips whitespace and checks the text framing. Returns the base90 payload and whether it is named-parts.format.
  local function parseSeedText(seedText)
    if type(seedText) ~= "string" then
      return nil, nil, "Invalid seed"
    end
    local text = seedText:gsub("%s+", "")
    if text == "" then
      return nil, nil, "Invalid seed"
    end
    if #text > parts.format.MAX_SEED_LENGTH then
      return nil, nil, "Seed is too long"
    end
    if text:sub(1, 9) ~= "RLS-SEED:" then
      return text, false
    end

    local formatVersion, payload = text:match("^RLS%-SEED:(%d+):(.*)$")
    if formatVersion ~= "2" then return nil, nil, "Unsupported seed format version" end
    if #payload == 0 or #payload % 4 ~= 0 then return nil, nil, "Invalid seed payload" end
    for index = 1, #payload do
      if not parts.binary.isBase90Char(payload:sub(index, index)) then
        return nil, nil, "Invalid seed character"
      end
    end
    return payload, true
  end

  local function readLoanSection(challengeData, bytes, offset)
    if offset + 2 > #bytes then
      return nil, "Incomplete loan data"
    end
    challengeData.loans = {}
    local amount, nextOffset, err = parts.binary.readVarInt(bytes, offset)
    if amount == nil then
      return nil, "Failed to read loan amount: " .. tostring(err)
    end
    challengeData.loans.amount = amount

    local interest = nil
    interest, nextOffset, err = parts.binary.readFloat(bytes, nextOffset)
    if interest == nil then
      return nil, "Failed to read loan interest: " .. tostring(err)
    end
    challengeData.loans.interest = interest

    if nextOffset > #bytes then
      return nil, "Incomplete loan payments data"
    end
    challengeData.loans.payments = string.byte(bytes, nextOffset)
    return nextOffset + 1
  end

  local function readDifficultySection(challengeData, bytes, offset)
    if offset > #bytes then
      return nil, "Incomplete difficulty data"
    end
    challengeData.difficulty = DIFFICULTY_NAMES[string.byte(bytes, offset)] or "Medium"
    return offset + 1
  end

  -- Reads a hashed or named entry; older seeds keep the hash behind a "_hash_" prefix for later resolution.
  local function readEntry(namedFormat, bytes, offset)
    if namedFormat then
      return parts.binary.readName(bytes, offset)
    end
    return parts.binary.readVarInt(bytes, offset)
  end

  local function readGarageSection(challengeData, decodeState, bytes, offset)
    if offset + 2 > #bytes then
      return nil, "Incomplete starting garages data"
    end
    challengeData.startingGarages = {}
    local garageCount, nextOffset, err = parts.binary.readVarInt(bytes, offset)
    if garageCount == nil then
      return nil, "Failed to read garage count: " .. tostring(err)
    end
    if garageCount * 2 > (#bytes - nextOffset + 1) then
      return nil, "Invalid garage count"
    end
    for index = 1, garageCount do
      local garageEntry = nil
      garageEntry, nextOffset, err = readEntry(decodeState.namedFormat, bytes, nextOffset)
      if garageEntry == nil then
        return nil, "Failed to read garage hash " .. index .. ": " .. tostring(err)
      end
      table.insert(challengeData.startingGarages, decodeState.namedFormat and garageEntry or ("_hash_" .. garageEntry))
    end
    return nextOffset
  end

  local function readMapSection(challengeData, decodeState, bytes, offset)
    if offset + 1 > #bytes then
      return nil, "Incomplete map data"
    end
    local mapEntry, nextOffset, err = readEntry(decodeState.namedFormat, bytes, offset)
    if mapEntry == nil then
      return nil, "Failed to read map hash: " .. tostring(err)
    end
    challengeData.map = decodeState.namedFormat and mapEntry or ("_hash_" .. mapEntry)
    return nextOffset
  end

  local function readEconomySection(challengeData, decodeState, bytes, offset)
    if offset + 2 > #bytes then
      return nil, "Incomplete economy adjuster data"
    end
    challengeData.economyAdjuster = challengeData.economyAdjuster or {}
    local activityEntry, nextOffset, err = readEntry(decodeState.namedFormat, bytes, offset)
    if activityEntry == nil then
      return nil, "Failed to read activity hash: " .. tostring(err)
    end
    local stepMultiple = nil
    stepMultiple, nextOffset, err = parts.binary.readVarInt(bytes, nextOffset)
    if stepMultiple == nil then
      return nil, "Failed to read step multiple: " .. tostring(err)
    end
    local key = decodeState.namedFormat and activityEntry or ("_hash_" .. activityEntry)
    challengeData.economyAdjuster[key] = challengeRounding.stepsToEconomyMultiplier(stepMultiple)
    return nextOffset
  end

  -- The first variable section fixes the win condition, because older seeds store only its hash.
  local function readVariableSection(challengeData, decodeState, marker, bytes, offset)
    if not decodeState.winConditionResolved then
      decodeState.winConditionResolved = true
      if not decodeState.namedFormat then
        parts.nameHash.resolveWinConditionFromHash(challengeData)
      end
      decodeState.variableDefinitions = parts.catalog.getWinConditionVariableDefinitions(challengeData.winCondition)
    end
    local decoded, nextOffset, decodeErr = parts.variables.decodeVariable(
      challengeData, decodeState.variableDefinitions, marker, bytes, offset, decodeState.namedFormat)
    if not decoded then
      return nil, decodeErr or "Invalid variable data"
    end
    return nextOffset
  end

  -- Reads the section that starts with `marker`; returns the offset after it, or nil and the reason.
  local function readSection(challengeData, decodeState, marker, bytes, offset)
    if marker == parts.format.MARKER_LOANS then
      return readLoanSection(challengeData, bytes, offset)
    elseif marker == parts.format.MARKER_DIFFICULTY then
      return readDifficultySection(challengeData, bytes, offset)
    elseif marker == parts.format.MARKER_STARTING_GARAGES then
      return readGarageSection(challengeData, decodeState, bytes, offset)
    elseif marker == parts.format.MARKER_MAP then
      return readMapSection(challengeData, decodeState, bytes, offset)
    elseif marker == parts.format.MARKER_STARTING_GARAGE_MODE then
      return startSections.readStartingGarageMode(challengeData, decodeState, bytes, offset)
    elseif marker == parts.format.MARKER_STARTER_VEHICLES then
      return startSections.readStarterVehicles(challengeData, decodeState, bytes, offset)
    elseif marker == parts.format.MARKER_ECONOMY_ADJUSTER then
      return readEconomySection(challengeData, decodeState, bytes, offset)
    elseif marker >= parts.format.MARKER_VARIABLE_NUMBER and marker <= parts.format.MARKER_VARIABLE_TABLE then
      return readVariableSection(challengeData, decodeState, marker, bytes, offset)
    end
    return nil, "Unknown marker: " .. tostring(marker)
  end

  -- Trailing bytes after the end marker must be zero padding.
  local function checkNamedTrailer(bytes, offset)
    local padding = bytes:sub(offset)
    if #padding > 2 or padding:find("[^%z]") then
      return "Unexpected trailing seed data"
    end
    return nil
  end

  -- Reads the version, win condition hash and starting capital; returns the offset after them.
  local function readHeader(challengeData, bytes)
    local header1, header2, header3 = string.byte(bytes, 1, 3)
    challengeData.version = string.format("%d.%d", math.floor(header1 / 16), header1 % 16)
    local startingCapital, offset = parts.binary.readUint32(bytes, 4)
    if not startingCapital then
      return nil, "Incomplete starting capital data"
    end
    challengeData.startingCapital = startingCapital
    challengeData._winConditionHash = header2 * 256 + header3
    return offset
  end

  local function decodeSeedToChallengeUnsafe(seedText)
    local payload, namedFormat, err = parseSeedText(seedText)
    if not payload then
      return nil, err
    end
    local binaryData = parts.binary.decodeBase90(payload)
    if namedFormat and parts.binary.encodeBase90(binaryData) ~= payload then
      return nil, "Invalid seed payload"
    end
    if #binaryData < 7 then
      return nil, "Seed too short"
    end

    local challengeData = {}
    local offset, headerErr = readHeader(challengeData, binaryData)
    if not offset then
      return nil, headerErr
    end

    if namedFormat then
      local name, nextOffset, nameErr = parts.binary.readName(binaryData, offset)
      if not name then return nil, nameErr end
      challengeData.winCondition = name
      challengeData._seedFormatVersion = 2
      offset = nextOffset
    end

    local decodeState = { namedFormat = namedFormat, winConditionResolved = false, variableDefinitions = {} }
    local foundEnd = false
    while offset <= #binaryData do
      local marker = string.byte(binaryData, offset)
      offset = offset + 1
      if marker == parts.format.MARKER_END then
        foundEnd = true
        break
      end
      local nextOffset, sectionErr = readSection(challengeData, decodeState, marker, binaryData, offset)
      if not nextOffset then
        return nil, sectionErr
      end
      offset = nextOffset
    end

    if namedFormat and not foundEnd then return nil, "Incomplete seed data" end
    if namedFormat then
      local trailerErr = checkNamedTrailer(binaryData, offset)
      if trailerErr then return nil, trailerErr end
    end
    if not decodeState.winConditionResolved and not namedFormat then
      parts.nameHash.resolveWinConditionFromHash(challengeData)
    end
    challengeData._winConditionHash = nil
    return challengeData
  end

  -- Decodes a seed string into challenge data; malformed input returns nil and a reason, never an error.
  function codec.decodeSeedToChallenge(seedText)
    local succeeded, result, err = pcall(decodeSeedToChallengeUnsafe, seedText)
    if not succeeded then
      return nil, "Invalid seed: " .. tostring(result)
    end
    return result, err
  end

  parts.codec = codec
end

-- Generator -----------------------------------------------------------------------------------------

do
  local generator = {}

  local MAX_RANDOM_GARAGES = 3

  -- Random rolls --------------------------------------------------------------------------------------

  local function randomChoice(list)
    if not list or #list == 0 then
      return nil
    end
    return list[math.random(1, #list)]
  end

  -- Rounds a random number to the variable's step, then clamps it to its limits.
  local function snapToDefinitionStep(value, definition)
    local step = tonumber(definition.step) or 1
    if step <= 0 then step = 1 end
    value = math.floor((value / step) + 0.5) * step
    if definition.min and value < definition.min then value = definition.min end
    if definition.max and value > definition.max then value = definition.max end
    return value
  end

  -- Up to three distinct garages from one map; nil when the map offers none.
  local function randomGarageSelection(mapId)
    local available = parts.catalog.getAvailableGarageIds(mapId)
    if #available == 0 then return nil end
    local count = math.random(1, math.min(MAX_RANDOM_GARAGES, #available))
    local selected = {}
    for _ = 1, count do
      local index = math.random(1, #available)
      table.insert(selected, available[index])
      table.remove(available, index)
    end
    return selected
  end

  local function randomVariableValue(variableName, definition, options)
    if options[variableName] ~= nil then
      return options[variableName]
    end
    local varType = definition.type or "number"
    if varType == "boolean" then
      return math.random() < 0.5
    elseif varType == "string" then
      return definition.default or "random_" .. variableName
    elseif varType == "multiselect" or varType == "array" then
      if variableName == "targetGarages" then
        return randomGarageSelection(options.map or levelData.defaultMap())
      end
      return {}
    end
    local minValue = definition.min or 1
    local maxValue = definition.randomMax or definition.max or 1000000
    return snapToDefinitionStep(math.random(minValue, maxValue), definition)
  end

  local function addRandomVariables(data, options, winCondition)
    for variableName, definition in pairs(parts.catalog.getWinConditionVariableDefinitions(winCondition)) do
      local value = randomVariableValue(variableName, definition, options)
      if value ~= nil then
        data[variableName] = value
      end
    end
  end

  -- Loans follow the win condition when it needs them; otherwise 70% of challenges get one.
  local function randomLoans(options, winCondition)
    local needsLoan = parts.catalog.winConditionRequiresLoans(winCondition)
    if not (needsLoan or (options.hasLoans ~= false and (options.hasLoans or math.random() < 0.7))) then
      return nil
    end
    return {
      amount = math.max(challengeRounding.LOAN_AMOUNT_STEP,
        challengeRounding.roundLoanAmount(options.loanAmount or math.random(10000, 250000))),
      interest = options.loanInterest or math.random(50, 250) / 1000,
      payments = options.loanPayments or math.random(6, 60),
    }
  end

  -- A type is changed 35% of the time: disabled 10% of those, otherwise set to 0.25 to 3.0 in 0.25 steps.
  local function randomEconomyMultiplier()
    if math.random() < 0.1 then
      return 0.0
    end
    return challengeRounding.roundEconomyMultiplier(math.random(25, 300) / 100)
  end

  local function randomEconomyAdjuster(options)
    local availableTypes = parts.catalog.getActivityTypeIds()
    if #availableTypes == 0 then return nil end
    local adjuster = {}
    -- Preserve the initial catalog read before any random economy draws.
    parts.catalog.getModuleHierarchy()
    for _, typeName in ipairs(availableTypes) do
      if options.economyAdjuster and options.economyAdjuster[typeName] ~= nil then
        adjuster[typeName] = options.economyAdjuster[typeName]
      elseif math.random() < 0.35 then
        adjuster[typeName] = randomEconomyMultiplier()
      end
    end
    local filtered = parts.catalog.filterDisabledSubModules(adjuster)
    if next(filtered) then
      return filtered
    end
    return nil
  end

  -- An explicit option wins, even when false; otherwise 30% of challenges get starting garages.
  local function randomStartingGarages(options)
    if options.startingGarages ~= nil then
      return options.startingGarages
    end
    if math.random() < 0.3 then
      return randomGarageSelection(options.map or levelData.defaultMap())
    end
    return nil
  end

  -- Public API ----------------------------------------------------------------------------------------

  -- Builds a challenge table from the options; returns nil and a reason when no win condition exists.
  function generator.generateRandomChallengeData(options)
    options = options or {}

    local winCondition = options.winCondition or randomChoice(parts.catalog.getWinConditionIds())
    if not winCondition then
      return nil, "No win conditions available"
    end

    local data = {
      version = options.version or "1.0",
      startingCapital = challengeRounding.roundStartingCapital(options.startingCapital or math.random(2000, 150000)),
      winCondition = winCondition,
    }
    addRandomVariables(data, options, winCondition)

    local loans = randomLoans(options, winCondition)
    if loans ~= nil then
      data.loans = loans
    end
    local economyAdjuster = randomEconomyAdjuster(options)
    if economyAdjuster ~= nil then
      data.economyAdjuster = economyAdjuster
    end
    local startingGarages = randomStartingGarages(options)
    if startingGarages ~= nil then
      data.startingGarages = startingGarages
    end
    return data
  end

  function generator.generateRandomSeed(options)
    local data, challengeError = generator.generateRandomChallengeData(options)
    if not data then
      return nil, challengeError
    end
    local seed, err = parts.codec.encodeChallengeToSeed(data)
    if not seed then
      return nil, err
    end
    return seed, data
  end

  parts.generator = generator
end

-- Seed import ---------------------------------------------------------------------------------------

-- Time alone collides when seeds are imported in the same second.
local function uniqueSeedChallengeId()
  local base = "seed_" .. os.time()
  local challengeId = base
  local attempt = 1
  local function taken(candidate)
    if FS:fileExists("challenges/custom/" .. candidate .. ".json") then return true end
    return overhaul_career_challengeModes.getSingleChallengeForUI(candidate) ~= nil
  end
  while taken(challengeId) do
    attempt = attempt + 1
    challengeId = base .. "_" .. attempt
  end
  return challengeId
end

-- Decodes, resolves and hands a seed to the challenge UI as a custom challenge.
local function createChallengeFromSeed(seed, challengeName, challengeDescription)
  local decodedChallenge, decodeError = parts.codec.decodeSeedToChallenge(seed)
  if not decodedChallenge then
    return { ok = false, msg = decodeError or "Failed to decode seed" }
  end

  local resolvedChallenge, resolveError = parts.nameHash.resolveHashesToNames(decodedChallenge)
  if not resolvedChallenge then
    return { ok = false, msg = resolveError or "Failed to resolve challenge data" }
  end

  resolvedChallenge.name = challengeName or "Challenge from Seed"
  resolvedChallenge.description = challengeDescription or "A challenge created from a seed code"
  resolvedChallenge.id = uniqueSeedChallengeId()
  resolvedChallenge.category = "custom"
  resolvedChallenge.createdBy = "seed"
  resolvedChallenge.createdDate = os.date("%Y-%m-%d %H:%M:%S")

  return overhaul_career_challengeModes.createChallengeFromUI(resolvedChallenge)
end

-- Public API ----------------------------------------------------------------------------------------

M.encodeChallengeToSeed = parts.codec.encodeChallengeToSeed
M.decodeSeedToChallenge = parts.codec.decodeSeedToChallenge
M.resolveHashesToNames = parts.nameHash.resolveHashesToNames
M.createChallengeFromSeed = createChallengeFromSeed
M.generateRandomChallengeData = parts.generator.generateRandomChallengeData
M.generateRandomSeed = parts.generator.generateRandomSeed

return M
