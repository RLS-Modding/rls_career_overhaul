local M = {}

-- ============================================================================
-- LOCAL VARIABLES AND CONSTANTS
-- ============================================================================

-- Extended character set for Base90 encoding
local baseChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/!@#$%^&=()[]{}|\\:;\"'<>,.?~`"

-- Binary markers for different data types
local MARKER_WIN_CONDITION_DATA = 0x01
local MARKER_LOANS = 0x02
local MARKER_ECONOMY_ADJUSTER = 0x03
local MARKER_STARTING_GARAGES = 0x04
local MARKER_DIFFICULTY = 0x05
local MARKER_MAP = 0x06
local MARKER_VARIABLE_NUMBER = 0x10
local MARKER_VARIABLE_INTEGER = 0x11
local MARKER_VARIABLE_BOOLEAN = 0x12
local MARKER_VARIABLE_STRING = 0x13
local MARKER_VARIABLE_TABLE = 0x14
local MARKER_RUN_LENGTH = 0x20
local MARKER_END = 0xFF

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

local function simpleHash(str)
  local hash = 0
  for i = 1, #str do
    hash = (hash * 31 + string.byte(str, i)) % 65536
  end
  return hash
end

local function randomChoice(list)
  if not list or #list == 0 then
    return nil
  end
  return list[math.random(1, #list)]
end

local function safeCall(func)
  if type(func) ~= "function" then
    return nil
  end
  local ok, result = pcall(func)
  if ok then
    return result
  end
  print("Warning: challengeSeedEncoder call failed: " .. tostring(result))
  return nil
end

local function roundEconomyMultiplier(value)
  if not value or type(value) ~= "number" then
    return 1.0
  end
  
  local step = 0.25
  local min = 0.0  -- Allow 0 for disabled modules
  local max = 10.0
  
  local rounded = math.floor((value / step) + 0.5) * step
  rounded = math.max(min, math.min(max, rounded))
  return rounded
end

local function roundLoanAmount(value)
  if not value or type(value) ~= "number" then
    return 10000
  end
  
  local step = 1000
  local min = 10000
  local max = 10000000
  
  local rounded = math.floor((value / step) + 0.5) * step
  rounded = math.max(min, math.min(max, rounded))
  return rounded
end

local function roundStartingCapital(value)
  if not value or type(value) ~= "number" then
    return 0
  end
  
  local step = 500
  local rounded = math.floor((value / step) + 0.5) * step
  return math.max(0, rounded)
end

-- ============================================================================
-- BASE ENCODING/DECODING FUNCTIONS
-- ============================================================================

local function encodeBase90(bytes)
  local result = {}
  local len = #bytes
  
  local i = 1
  while i <= len do
    local b1 = string.byte(bytes, i)
    local b2 = i + 1 <= len and string.byte(bytes, i + 1) or 0
    local b3 = i + 2 <= len and string.byte(bytes, i + 2) or 0
    
    -- Pack 3 bytes into 4 base-90 characters (90^4 = 65,610,000 > 16,777,216 = 2^24)
    local n = b1 * 65536 + b2 * 256 + b3
    
    table.insert(result, string.sub(baseChars, (math.floor(n / 729000) % 90) + 1, (math.floor(n / 729000) % 90) + 1))
    table.insert(result, string.sub(baseChars, (math.floor(n / 8100) % 90) + 1, (math.floor(n / 8100) % 90) + 1))
    table.insert(result, string.sub(baseChars, (math.floor(n / 90) % 90) + 1, (math.floor(n / 90) % 90) + 1))
    table.insert(result, string.sub(baseChars, (n % 90) + 1, (n % 90) + 1))
    
    i = i + 3
  end
  
  return table.concat(result)
end

local function decodeBase90(str)
  local bytes = {}
  local len = #str
  
  local charToNum = {}
  for i = 1, #baseChars do
    charToNum[string.sub(baseChars, i, i)] = i - 1
  end
  
  local i = 1
  while i <= len do
    local c1 = charToNum[string.sub(str, i, i)] or 0
    local c2 = charToNum[string.sub(str, i + 1, i + 1)] or 0
    local c3 = charToNum[string.sub(str, i + 2, i + 2)] or 0
    local c4 = charToNum[string.sub(str, i + 3, i + 3)] or 0
    
    local n = c1 * 729000 + c2 * 8100 + c3 * 90 + c4
    
    table.insert(bytes, string.char(math.floor(n / 65536) % 256))
    if i + 1 <= len then
      table.insert(bytes, string.char(math.floor(n / 256) % 256))
    end
    if i + 2 <= len then
      table.insert(bytes, string.char(n % 256))
    end
    
    i = i + 4
  end
  
  return table.concat(bytes)
end

-- ============================================================================
-- BINARY READ/WRITE FUNCTIONS
-- ============================================================================

local function writeUint16(buffer, value)
  table.insert(buffer, string.char(math.floor(value / 256) % 256))
  table.insert(buffer, string.char(value % 256))
end

local function readUint16(bytes, offset)
  local b1 = string.byte(bytes, offset)
  local b2 = string.byte(bytes, offset + 1)
  return b1 * 256 + b2, offset + 2
end

local function writeUint32(buffer, value)
  table.insert(buffer, string.char(math.floor(value / 16777216) % 256))
  table.insert(buffer, string.char(math.floor(value / 65536) % 256))
  table.insert(buffer, string.char(math.floor(value / 256) % 256))
  table.insert(buffer, string.char(value % 256))
end

local function readUint32(bytes, offset)
  local b1 = string.byte(bytes, offset)
  local b2 = string.byte(bytes, offset + 1)
  local b3 = string.byte(bytes, offset + 2)
  local b4 = string.byte(bytes, offset + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4, offset + 4
end

local function writeVarInt(buffer, value)
  if value < 0 then
    error("VarInt does not support negative values")
  end
  
  if value <= 255 then
    table.insert(buffer, string.char(0)) -- 1-byte marker
    table.insert(buffer, string.char(value))
  elseif value <= 65535 then
    table.insert(buffer, string.char(1)) -- 2-byte marker
    table.insert(buffer, string.char(math.floor(value / 256)))
    table.insert(buffer, string.char(value % 256))
  else
    table.insert(buffer, string.char(2)) -- 4-byte marker
    writeUint32(buffer, value)
  end
end

local function readVarInt(bytes, offset)
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
    local b1 = string.byte(bytes, offset)
    local b2 = string.byte(bytes, offset + 1)
    return b1 * 256 + b2, offset + 2
  elseif marker == 2 then
    return readUint32(bytes, offset)
  else
    return nil, offset, "Invalid VarInt marker"
  end
end

local function writeFloat(buffer, value)
  local sign = value < 0 and 1 or 0
  value = math.abs(value)
  
  local mantissa = math.floor(value * 1000)
  mantissa = math.min(2147483647, mantissa)
  
  local encoded = (sign * 2147483648) + mantissa
  writeVarInt(buffer, encoded)
end

local function readFloat(bytes, offset)
  local encoded, newOffset, err = readVarInt(bytes, offset)
  if err then
    return nil, newOffset, err
  end
  
  local sign = math.floor(encoded / 2147483648) % 2
  local mantissa = encoded % 2147483648
  
  local value = mantissa / 1000
  if sign == 1 then
    value = -value
  end
  
  return value, newOffset
end

-- ============================================================================
-- COMPRESSION FUNCTIONS
-- ============================================================================

local function encodeRunLength(buffer, value, count)
  if count >= 3 then
    table.insert(buffer, string.char(MARKER_RUN_LENGTH))
    writeVarInt(buffer, value)
    writeVarInt(buffer, count)
    return true
  end
  return false
end

-- ============================================================================
-- DATA RETRIEVAL FUNCTIONS
-- ============================================================================

local function getWinConditionIds()
  if career_challengeModes and career_challengeModes.getWinConditions then
    local list = safeCall(function()
      return career_challengeModes.getWinConditions()
    end)
    if list then
      local ids = {}
      for _, entry in ipairs(list) do
        local id = type(entry) == "table" and entry.id or entry
        if type(id) == "string" and id ~= "" then
          table.insert(ids, id)
        end
      end
      return ids
    end
  end
  return {}
end

local function getWinConditionVariableDefinitions(winConditionId)
  if not winConditionId then return {} end
  
  if career_challengeModes and career_challengeModes.getWinConditions then
    local list = safeCall(function()
      return career_challengeModes.getWinConditions()
    end)
    if list then
      for _, entry in ipairs(list) do
        if entry.id == winConditionId and entry.variables then
          return entry.variables
        end
      end
    end
  end
  
  return {}
end

local function getActivityTypeIds()
  if career_challengeModes and career_challengeModes.getChallengeEditorData then
    local editorData = safeCall(function()
      return career_challengeModes.getChallengeEditorData()
    end)
    if editorData and editorData.activityTypes then
      local ids = {}
      for _, entry in ipairs(editorData.activityTypes) do
        local id = type(entry) == "table" and (entry.id or entry.name) or entry
        if type(id) == "string" and id ~= "" then
          table.insert(ids, id)
        end
      end
      return ids
    end
  end
  
  if career_economyAdjuster and career_economyAdjuster.getAvailableTypes then
    local list = safeCall(function()
      return career_economyAdjuster.getAvailableTypes()
    end)
    if list then
      return list
    end
  end
  
  return {}
end

local function getModuleHierarchy()
  if career_economyAdjuster and career_economyAdjuster.getTypesBySource then
    local typesBySource = safeCall(function()
      return career_economyAdjuster.getTypesBySource()
    end)
    if typesBySource then
      local hierarchy = {}
      
      -- Build hierarchy from source mapping
      for sourceName, types in pairs(typesBySource) do
        if sourceName:match("_module$") then
          local parentModule = sourceName:gsub("_module$", "")
          hierarchy[parentModule] = {}
          
          -- Find child modules for this parent
          for _, typeName in ipairs(types) do
            if typeName ~= parentModule then
              table.insert(hierarchy[parentModule], typeName)
            end
          end
        end
      end
      
      return hierarchy
    end
  end
  
  return {}
end

local function getAvailableGarageIds()
  local ids = {}
  
  -- Use the shared function from challengeModes if available
  if career_challengeModes and career_challengeModes.getAvailableGarages then
    local garages = career_challengeModes.getAvailableGarages()
    for _, garage in ipairs(garages) do
      if garage.id and type(garage.id) == "string" and garage.id ~= "" then
        table.insert(ids, garage.id)
      end
    end
    return ids
  end
  
  -- Fallback: Get all available career maps
  local compatibleMaps = {}
  if overhaul_maps and overhaul_maps.getCompatibleMaps then
    compatibleMaps = overhaul_maps.getCompatibleMaps() or {}
  end
  
  local careerMaps = {}
  -- Convert compatible maps to the format we need
  for mapId, mapName in pairs(compatibleMaps) do
    table.insert(careerMaps, {id = mapId, name = mapName})
  end
  
  -- Parse facility files for each career map
  for _, map in ipairs(careerMaps) do
    local levelInfo = core_levels.getLevelByName(map.id)
    if levelInfo then
      -- Parse info.json of the level
      local infoFile = levelInfo.dir .. "/info.json"
      if FS:fileExists(infoFile) then
        local data = jsonReadFile(infoFile)
        if data and data.garages then
          for _, garage in ipairs(data.garages) do
            if garage.id and type(garage.id) == "string" and garage.id ~= "" then
              table.insert(ids, garage.id)
            end
          end
        end
      end
      
      -- Parse any other facility files inside the levels /facilities folder
      local facilitiesDir = levelInfo.dir .. "/facilities/"
      for _, file in ipairs(FS:findFiles(facilitiesDir, '*.facilities.json', -1, false, true)) do
        local data = jsonReadFile(file)
        if data and data.garages then
          for _, garage in ipairs(data.garages) do
            if garage.id and type(garage.id) == "string" and garage.id ~= "" then
              table.insert(ids, garage.id)
            end
          end
        end
      end
    end
  end
  
  return ids
end

local function filterDisabledSubModules(economyAdjuster)
  if not economyAdjuster or type(economyAdjuster) ~= "table" then
    return economyAdjuster
  end
  
  local filtered = {}
  local hierarchy = getModuleHierarchy()
  
  for activityType, multiplier in pairs(economyAdjuster) do
    -- If multiplier is 0, check if this is a parent module
    if multiplier == 0 then
      local children = hierarchy[activityType]
      if children then
        -- This is a parent module being disabled, don't include child modules
        filtered[activityType] = multiplier
        -- Skip any child modules that might be in the adjuster
        for _, childType in ipairs(children) do
          -- Don't add child modules if parent is disabled
        end
      else
        -- This is a standalone module or child module, include it
        filtered[activityType] = multiplier
      end
    else
      -- Multiplier is not 0, check if parent module is disabled
      local isChildOfDisabledParent = false
      for parentType, children in pairs(hierarchy) do
        for _, childType in ipairs(children) do
          if childType == activityType and economyAdjuster[parentType] == 0 then
            isChildOfDisabledParent = true
            break
          end
        end
        if isChildOfDisabledParent then break end
      end
      
      -- Only include if not a child of a disabled parent
      if not isChildOfDisabledParent then
        filtered[activityType] = multiplier
      end
    end
  end
  
  return filtered
end

-- ============================================================================
-- VARIABLE ENCODING/DECODING FUNCTIONS
-- ============================================================================

local function encodeVariable(buffer, variableName, definition, value)
  if value == nil then
    return
  end

  local typeName = definition and definition.type or "number"
  local marker
  if typeName == "boolean" then
    marker = MARKER_VARIABLE_BOOLEAN
  elseif typeName == "string" then
    marker = MARKER_VARIABLE_STRING
  elseif typeName == "integer" then
    marker = MARKER_VARIABLE_INTEGER
  elseif typeName == "multiselect" or typeName == "array" then
    marker = MARKER_VARIABLE_TABLE
  else
    marker = MARKER_VARIABLE_NUMBER
  end

  table.insert(buffer, string.char(marker))
  writeUint16(buffer, simpleHash(variableName))

  if marker == MARKER_VARIABLE_BOOLEAN then
    table.insert(buffer, string.char(value and 1 or 0))
  elseif marker == MARKER_VARIABLE_STRING then
    writeUint16(buffer, #value)
    table.insert(buffer, value)
  elseif marker == MARKER_VARIABLE_TABLE then
    -- Encode table as array of values
    if type(value) == "table" then
      writeUint16(buffer, #value)
      for _, item in ipairs(value) do
        if type(item) == "string" then
          writeUint16(buffer, #item)
          table.insert(buffer, item)
        else
          -- Convert non-string items to string
          local strItem = tostring(item)
          writeUint16(buffer, #strItem)
          table.insert(buffer, strItem)
        end
      end
    else
      -- Single value, wrap in table
      writeUint16(buffer, 1)
      local strValue = tostring(value)
      writeUint16(buffer, #strValue)
      table.insert(buffer, strValue)
    end
  else
    -- Enforce min/max constraints
    if definition then
      if definition.min and value < definition.min then
        value = definition.min
      end
      if definition.max and value > definition.max then
        value = definition.max
      end
    end
    
    local step = definition and definition.step or 1
    local normalizedValue = math.floor((value / step) + 0.5)
    writeFloat(buffer, normalizedValue)
  end
end

local function decodeVariable(challengeData, variableDefinitions, marker, bytes, offset)
  if offset + 2 > #bytes then
    return nil, offset, "Incomplete variable data"
  end
  local nameHash
  nameHash, offset = readUint16(bytes, offset)
  local value

  if marker == MARKER_VARIABLE_BOOLEAN then
    if offset > #bytes then
      return nil, offset, "Incomplete variable data"
    end
    value = string.byte(bytes, offset) ~= 0
    offset = offset + 1
  elseif marker == MARKER_VARIABLE_STRING then
    if offset + 1 > #bytes then
      return nil, offset, "Incomplete variable data"
    end
    local length
    length, offset = readUint16(bytes, offset)
    if offset + length - 1 > #bytes then
      return nil, offset, "Incomplete variable data"
    end
    value = bytes:sub(offset, offset + length - 1)
    offset = offset + length
  elseif marker == MARKER_VARIABLE_TABLE then
    if offset + 1 > #bytes then
      return nil, offset, "Incomplete table data"
    end
    local count
    count, offset = readUint16(bytes, offset)
    value = {}
    
    for i = 1, count do
      if offset + 1 > #bytes then
        return nil, offset, "Incomplete table item data"
      end
      local itemLength
      itemLength, offset = readUint16(bytes, offset)
      if offset + itemLength - 1 > #bytes then
        return nil, offset, "Incomplete table item data"
      end
      local item = bytes:sub(offset, offset + itemLength - 1)
      offset = offset + itemLength
      table.insert(value, item)
    end
  else
    local decoded
    decoded, offset = readFloat(bytes, offset)
    value = decoded
    if marker == MARKER_VARIABLE_INTEGER then
      value = math.floor(value + 0.5)
    end
  end

  local variableName
  local definition
  for name, def in pairs(variableDefinitions or {}) do
    if simpleHash(name) == nameHash then
      variableName = name
      definition = def
      break
    end
  end

  if not variableName then
    variableName = "_var_" .. tostring(nameHash)
  end

  if definition and definition.step and definition.step ~= 1 and type(value) == "number" then
    value = value * definition.step
  end

  -- Enforce min/max constraints after decoding (only for numeric values)
  if definition and type(value) == "number" then
    if definition.min and value < definition.min then
      value = definition.min
    end
    if definition.max and value > definition.max then
      value = definition.max
    end
  end

  challengeData[variableName] = value
  return challengeData, offset
end

-- ============================================================================
-- MAIN ENCODING FUNCTION
-- ============================================================================

local function encodeChallengeToSeed(challengeData)
  if not challengeData then
    return nil, "No challenge data provided"
  end
  
  local buffer = {}
  
  local version = challengeData.version or "1.0"
  local major, minor = version:match("(%d+)%.(%d+)")
  major = tonumber(major) or 1
  minor = tonumber(minor) or 0
  
  local startingCapital = roundStartingCapital(challengeData.startingCapital or 10000)
  
  local winConditionIds = getWinConditionIds()
  if #winConditionIds == 0 then
    return nil, "No win conditions available"
  end
  
  local winCondition = challengeData.winCondition or winConditionIds[1]
  if not winCondition or winCondition == "" then
    return nil, "Invalid win condition"
  end
  
  local winConditionHash = simpleHash(winCondition)
  
  -- Bit-packed header: version(8) + winConditionHash(16) + startingCapital(32) = 7 bytes
  local header1 = (major * 16 + minor) % 256
  local header2 = math.floor(winConditionHash / 256) % 256
  local header3 = winConditionHash % 256
  
  table.insert(buffer, string.char(header1))
  table.insert(buffer, string.char(header2))
  table.insert(buffer, string.char(header3))
  
  writeUint32(buffer, startingCapital)

  local difficultyMap = { Easy = 0, Medium = 1, Hard = 2, Impossible = 3 }
  local difficulty = challengeData.difficulty or "Medium"
  local difficultyValue = difficultyMap[difficulty] or 1
  local success, err = pcall(function()
    table.insert(buffer, string.char(MARKER_DIFFICULTY))
    table.insert(buffer, string.char(difficultyValue))
  end)
  if not success then
    print("Warning: ChallengeSeedEncoder failed to encode difficulty: " .. tostring(err))
  end

  local success, err = pcall(function()
    local variableDefinitions = getWinConditionVariableDefinitions(winCondition)
    if variableDefinitions then
      for variableName, definition in pairs(variableDefinitions) do
        local value = challengeData[variableName]
        -- Only encode if value is different from default
        if value ~= nil and (definition.default == nil or value ~= definition.default) then
          encodeVariable(buffer, variableName, definition, value)
        end
      end
    end
  end)
  if not success then
    print("Warning: ChallengeSeedEncoder failed to encode variables: " .. tostring(err))
  end
  
  if challengeData.loans and challengeData.loans.amount and challengeData.loans.amount > 0 then
    local success, err = pcall(function()
      table.insert(buffer, string.char(MARKER_LOANS))
      
      -- Round loan amount to step increments
      local roundedAmount = roundLoanAmount(challengeData.loans.amount)
      writeVarInt(buffer, roundedAmount)
      
      writeFloat(buffer, challengeData.loans.interest or 0.10)
      
      table.insert(buffer, string.char(math.min(255, challengeData.loans.payments or 12)))
    end)
    if not success then
      print("Warning: ChallengeSeedEncoder failed to encode loans: " .. tostring(err))
    end
  end
  
  if challengeData.economyAdjuster and type(challengeData.economyAdjuster) == "table" then
    local success, err = pcall(function()
      -- Filter out disabled sub-modules based on parent module hierarchy
      local filteredAdjuster = filterDisabledSubModules(challengeData.economyAdjuster)
      
      for activityType, multiplier in pairs(filteredAdjuster) do
        if multiplier ~= 1.0 then
          table.insert(buffer, string.char(MARKER_ECONOMY_ADJUSTER))
          local activityHash = simpleHash(activityType)
          writeVarInt(buffer, activityHash)
          
          -- Round multiplier to step increments and encode as step multiple
          local roundedMultiplier = roundEconomyMultiplier(multiplier)
          local stepMultiple = math.floor((roundedMultiplier / 0.25) + 0.5)
          writeVarInt(buffer, stepMultiple)
        end
      end
    end)
    if not success then
      print("Warning: ChallengeSeedEncoder failed to encode economy adjuster: " .. tostring(err))
    end
  end
  
  if challengeData.startingGarages and type(challengeData.startingGarages) == "table" and #challengeData.startingGarages > 0 then
    local success, err = pcall(function()
      table.insert(buffer, string.char(MARKER_STARTING_GARAGES))
      
      -- Encode number of garages
      writeVarInt(buffer, #challengeData.startingGarages)
      
      -- Encode each garage ID as hash
      for _, garageId in ipairs(challengeData.startingGarages) do
        local garageHash = simpleHash(garageId)
        writeVarInt(buffer, garageHash)
      end
    end)
    if not success then
      print("Warning: ChallengeSeedEncoder failed to encode starting garages: " .. tostring(err))
    end
  end
  
  if challengeData.map and challengeData.map ~= "" then
    local success, err = pcall(function()
      table.insert(buffer, string.char(MARKER_MAP))
      local mapHash = simpleHash(challengeData.map)
      writeVarInt(buffer, mapHash)
    end)
    if not success then
      print("Warning: ChallengeSeedEncoder failed to encode map: " .. tostring(err))
    end
  end
  
  table.insert(buffer, string.char(MARKER_END))
  
  local binaryData = table.concat(buffer)
  local seed = encodeBase90(binaryData)
  
  if not seed or seed == "" then
    return nil, "Encoding produced empty seed"
  end
  
  return seed
end

-- ============================================================================
-- MAIN DECODING FUNCTION
-- ============================================================================

local function decodeSeedToChallenge(seed)
  if not seed or seed == "" then
    return nil, "Invalid seed"
  end
  
  local success, binaryData = pcall(decodeBase90, seed)
  if not success then
    return nil, "Failed to decode seed"
  end
  
  local offset = 1
  local challengeData = {}
  
  if offset + 6 > #binaryData then
    return nil, "Seed too short"
  end
  
  -- Decode bit-packed header: version(8) + winConditionHash(16) + startingCapital(32) = 7 bytes
  local header1 = string.byte(binaryData, offset)
  local header2 = string.byte(binaryData, offset + 1)
  local header3 = string.byte(binaryData, offset + 2)
  offset = offset + 3
  
  local major = math.floor(header1 / 16)
  local minor = header1 % 16
  challengeData.version = string.format("%d.%d", major, minor)
  
  local winConditionHash = header2 * 256 + header3
  
  -- Decode starting capital
  if offset <= #binaryData then
    challengeData.startingCapital, offset = readUint32(binaryData, offset)
  else
    challengeData.startingCapital = 10000
  end
  
  challengeData._winConditionHash = winConditionHash

  local variableDefinitions = {}
  local resolvedWinCondition

  while offset <= #binaryData do
    local marker = string.byte(binaryData, offset)
    offset = offset + 1
    
    if marker == MARKER_END then
      break
    elseif marker == MARKER_LOANS then
      if offset + 2 > #binaryData then
        return nil, "Incomplete loan data"
      end
      challengeData.loans = {}
      
      -- Decode loan amount
      if offset <= #binaryData then
        challengeData.loans.amount, offset, err = readVarInt(binaryData, offset)
        if err then
          return nil, "Failed to read loan amount: " .. err
        end
      end
      
      -- Decode interest rate
      if offset <= #binaryData then
        challengeData.loans.interest, offset, err = readFloat(binaryData, offset)
        if err then
          return nil, "Failed to read loan interest: " .. err
        end
      end
      
      if offset > #binaryData then
        return nil, "Incomplete loan payments data"
      end
      challengeData.loans.payments = string.byte(binaryData, offset)
      offset = offset + 1
    elseif marker == MARKER_DIFFICULTY then
      if offset > #binaryData then
        return nil, "Incomplete difficulty data"
      end
      local difficultyValue = string.byte(binaryData, offset)
      offset = offset + 1
      local difficultyMap = { [0] = "Easy", [1] = "Medium", [2] = "Hard", [3] = "Impossible" }
      challengeData.difficulty = difficultyMap[difficultyValue] or "Medium"
    elseif marker == MARKER_STARTING_GARAGES then
      if offset + 2 > #binaryData then
        return nil, "Incomplete starting garages data"
      end
      challengeData.startingGarages = {}
      
      -- Decode number of garages
      local garageCount, newOffset, err = readVarInt(binaryData, offset)
      if err then
        return nil, "Failed to read garage count: " .. err
      end
      offset = newOffset
      
      -- Decode each garage hash
      for i = 1, garageCount do
        local garageHash, newOffset, err = readVarInt(binaryData, offset)
        if err then
          return nil, "Failed to read garage hash " .. i .. ": " .. err
        end
        offset = newOffset
        table.insert(challengeData.startingGarages, "_hash_" .. garageHash)
      end
    elseif marker == MARKER_MAP then
      if offset + 1 > #binaryData then
        return nil, "Incomplete map data"
      end
      local mapHash, newOffset, err = readVarInt(binaryData, offset)
      if err then
        return nil, "Failed to read map hash: " .. err
      end
      offset = newOffset
      challengeData.map = "_hash_" .. mapHash
    elseif marker == MARKER_ECONOMY_ADJUSTER then
      if offset + 2 > #binaryData then
        return nil, "Incomplete economy adjuster data"
      end
      challengeData.economyAdjuster = challengeData.economyAdjuster or {}
      local activityHash, newOffset, err = readVarInt(binaryData, offset)
      if err then
        return nil, "Failed to read activity hash: " .. err
      end
      offset = newOffset
      
      local stepMultiple, newOffset, err = readVarInt(binaryData, offset)
      if err then
        return nil, "Failed to read step multiple: " .. err
      end
      offset = newOffset
      
      local multiplier = stepMultiple * 0.25
      
      challengeData.economyAdjuster["_hash_" .. activityHash] = multiplier
    elseif marker == MARKER_RUN_LENGTH then
      local value, newOffset, err = readVarInt(binaryData, offset)
      if err then
        return nil, "Failed to read run length value: " .. err
      end
      offset = newOffset
      
      local count, newOffset, err = readVarInt(binaryData, offset)
      if err then
        return nil, "Failed to read run length count: " .. err
      end
      offset = newOffset
      
      -- Expand run-length encoded economy multipliers
      challengeData.economyAdjuster = challengeData.economyAdjuster or {}
      for i = 1, count do
        challengeData.economyAdjuster["_run_" .. i] = value * 0.25
      end
    elseif marker >= MARKER_VARIABLE_NUMBER and marker <= MARKER_VARIABLE_TABLE then
      if not resolvedWinCondition then
        resolvedWinCondition = true
        local availableConditions = getWinConditionIds()
        for _, conditionName in ipairs(availableConditions or {}) do
          if simpleHash(conditionName) == challengeData._winConditionHash then
            challengeData.winCondition = conditionName
            break
          end
        end
        if not challengeData.winCondition then
          challengeData.winCondition = availableConditions and availableConditions[1] or "payOffLoan"
        end
        variableDefinitions = getWinConditionVariableDefinitions(challengeData.winCondition)
      end
      local _, newOffset, decodeErr = decodeVariable(challengeData, variableDefinitions, marker, binaryData, offset)
      if decodeErr then
        return nil, decodeErr
      end
      offset = newOffset
    else
      return nil, "Unknown marker: " .. tostring(marker)
    end
  end
  
  if not resolvedWinCondition then
    local availableConditions = getWinConditionIds()
    for _, conditionName in ipairs(availableConditions or {}) do
      if simpleHash(conditionName) == challengeData._winConditionHash then
        challengeData.winCondition = conditionName
        break
      end
    end
    if not challengeData.winCondition then
      challengeData.winCondition = availableConditions and availableConditions[1] or "payOffLoan"
    end
  end
  
  challengeData._winConditionHash = nil
  
  return challengeData
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function resolveHashesToNames(decodedChallenge)
  if not decodedChallenge then
    return nil, "No challenge data"
  end

  local winConditions = getWinConditionIds()
  for _, conditionName in ipairs(winConditions) do
    if simpleHash(conditionName) == decodedChallenge._winConditionHash then
      decodedChallenge.winCondition = conditionName
      break
    end
  end

  if not decodedChallenge.winCondition then
    decodedChallenge.winCondition = winConditions[1]
  end
  decodedChallenge._winConditionHash = nil

  local variableDefinitions = getWinConditionVariableDefinitions(decodedChallenge.winCondition)
  if variableDefinitions then
    for variableName, definition in pairs(variableDefinitions) do
      if decodedChallenge[variableName] == nil and definition.default ~= nil then
        decodedChallenge[variableName] = definition.default
      end
    end
  end

  if decodedChallenge.economyAdjuster then
    local availableTypes = getActivityTypeIds()
    local resolvedAdjuster = {}
    for key, multiplier in pairs(decodedChallenge.economyAdjuster) do
      if key:sub(1, 6) == "_hash_" then
        local hash = tonumber(key:sub(7))
        local resolved = false

        for _, activityType in ipairs(availableTypes) do
          if simpleHash(activityType) == hash then
            resolvedAdjuster[activityType] = multiplier
            resolved = true
            break
          end
        end

        if not resolved then
          print("Warning: Could not resolve economy adjuster hash: " .. hash)
        end
      else
        resolvedAdjuster[key] = multiplier
      end
    end

    decodedChallenge.economyAdjuster = resolvedAdjuster
  end

  -- Resolve starting garage hashes
  if decodedChallenge.startingGarages then
    local availableGarages = getAvailableGarageIds()
    local resolvedGarages = {}
    
    for _, garageEntry in ipairs(decodedChallenge.startingGarages) do
      if garageEntry:sub(1, 6) == "_hash_" then
        local hash = tonumber(garageEntry:sub(7))
        local resolved = false
        
        for _, garageId in ipairs(availableGarages) do
          if simpleHash(garageId) == hash then
            table.insert(resolvedGarages, garageId)
            resolved = true
            break
          end
        end
        
        if not resolved then
          print("Warning: Could not resolve starting garage hash: " .. hash)
        end
      else
        table.insert(resolvedGarages, garageEntry)
      end
    end
    
    decodedChallenge.startingGarages = resolvedGarages
  end

  -- Resolve map hash
  if decodedChallenge.map and decodedChallenge.map:sub(1, 6) == "_hash_" then
    local hash = tonumber(decodedChallenge.map:sub(7))
    local availableMaps = {}
    if overhaul_maps and overhaul_maps.getCompatibleMaps then
      availableMaps = overhaul_maps.getCompatibleMaps() or {}
    end
    
    local resolved = false
    for mapId, mapName in pairs(availableMaps) do
      if simpleHash(mapId) == hash then
        decodedChallenge.map = mapId
        resolved = true
        break
      end
    end
    
    if not resolved then
      print("Warning: Could not resolve map hash: " .. hash)
      decodedChallenge.map = nil
    end
  end

  -- Resolve targetGarages hashes for ownSpecificGarage win condition
  if decodedChallenge.winCondition == "ownSpecificGarage" and decodedChallenge.targetGarages then
    local availableGarages = getAvailableGarageIds()
    local resolvedGarages = {}
    
    for _, garageEntry in ipairs(decodedChallenge.targetGarages) do
      local isKnownGarage = false
      if type(garageEntry) == "string" then
        for _, garageId in ipairs(availableGarages) do
          if garageEntry == garageId then
            table.insert(resolvedGarages, garageEntry)
            isKnownGarage = true
            break
          end
        end
      end
      
      if not isKnownGarage then
        local hash = nil
        if type(garageEntry) == "string" then
          if garageEntry:sub(1, 6) == "_hash_" then
            hash = tonumber(garageEntry:sub(7))
          elseif tonumber(garageEntry) then
            hash = tonumber(garageEntry)
          end
        elseif type(garageEntry) == "number" then
          hash = garageEntry
        end
        
        if hash then
          local resolved = false
          for _, garageId in ipairs(availableGarages) do
            if simpleHash(garageId) == hash then
              table.insert(resolvedGarages, garageId)
              resolved = true
              break
            end
          end
          
          if not resolved then
            print("Warning: Could not resolve target garage hash: " .. hash)
          end
        else
          table.insert(resolvedGarages, garageEntry)
        end
      end
    end
    
    decodedChallenge.targetGarages = resolvedGarages
  end

  return decodedChallenge
end

local function createChallengeFromSeed(seed, challengeName, challengeDescription)
  local decodedChallenge, decodeError = decodeSeedToChallenge(seed)
  if not decodedChallenge then
    return nil, decodeError or "Failed to decode seed"
  end

  local resolvedChallenge, resolveError = resolveHashesToNames(decodedChallenge)
  if not resolvedChallenge then
    return nil, resolveError or "Failed to resolve challenge data"
  end

  resolvedChallenge.name = challengeName or "Challenge from Seed"
  resolvedChallenge.description = challengeDescription or "A challenge created from a seed code"
  resolvedChallenge.id = "seed_" .. os.time()
  resolvedChallenge.category = "custom"
  resolvedChallenge.createdBy = "seed"
  resolvedChallenge.createdDate = os.date("%Y-%m-%d %H:%M:%S")

  if career_challengeModes and career_challengeModes.createChallengeFromUI then
    return career_challengeModes.createChallengeFromUI(resolvedChallenge)
  end

  return nil, "Challenge modes module not available"
end

local function generateRandomChallengeData(options)
  options = options or {}

  local winConditionList = getWinConditionIds()
  local winCondition = options.winCondition or randomChoice(winConditionList)
  if not winCondition then
    return nil, "No win conditions available"
  end

  local data = {
    version = options.version or "1.0",
    startingCapital = options.startingCapital or math.random(2000, 150000),
    winCondition = winCondition
  }

  -- Add win condition variables
  local variableDefinitions = getWinConditionVariableDefinitions(winCondition)
  for variableName, definition in pairs(variableDefinitions) do
    if options[variableName] ~= nil then
      data[variableName] = options[variableName]
    else
      local varType = definition.type or "number"
      if varType == "boolean" then
        data[variableName] = math.random() < 0.5
      elseif varType == "string" then
        data[variableName] = definition.default or "random_" .. variableName
      elseif varType == "multiselect" or varType == "array" then
        if variableName == "targetGarages" then
          local availableGarages = getAvailableGarageIds()
          if #availableGarages > 0 then
            local garageCount = math.random(1, math.min(3, #availableGarages))
            local selectedGarages = {}
            local garagePool = {}
            for _, gid in ipairs(availableGarages) do
              table.insert(garagePool, gid)
            end
            
            for i = 1, garageCount do
              if #garagePool == 0 then break end
              local garageIndex = math.random(1, #garagePool)
              local garageId = garagePool[garageIndex]
              table.insert(selectedGarages, garageId)
              table.remove(garagePool, garageIndex)
            end
            
            data[variableName] = selectedGarages
          end
        else
          data[variableName] = {}
        end
      else
        local minVal = definition.min or 1
        local maxVal = definition.randomMax or definition.max or 1000000
        data[variableName] = math.random(minVal, maxVal)
      end
    end
  end

  -- Add loans if specified or random
  if options.hasLoans ~= false and (options.hasLoans or math.random() < 0.7) then
    data.loans = {
      amount = options.loanAmount or math.random(10000, 250000),
      interest = options.loanInterest or math.random(50, 250) / 1000,
      payments = options.loanPayments or math.random(6, 60)
    }
  end

  -- Add economy adjustments
  local availableTypes = getActivityTypeIds()
  if #availableTypes > 0 then
    local adjuster = {}
    local hierarchy = getModuleHierarchy()
    
    for _, typeName in ipairs(availableTypes) do
      if options.economyAdjuster and options.economyAdjuster[typeName] ~= nil then
        adjuster[typeName] = options.economyAdjuster[typeName]
      elseif math.random() < 0.35 then
        -- 10% chance to disable module (set to 0)
        if math.random() < 0.1 then
          adjuster[typeName] = 0.0
        else
          adjuster[typeName] = math.random(25, 300) / 100 -- 0.25 to 3.0 in 0.25 steps
        end
      end
    end
    
    -- Filter out disabled sub-modules based on parent module hierarchy
    local filteredAdjuster = filterDisabledSubModules(adjuster)
    if next(filteredAdjuster) then
      data.economyAdjuster = filteredAdjuster
    end
  end

  -- Add starting garages if specified or random
  if options.startingGarages ~= nil then
    data.startingGarages = options.startingGarages
  elseif math.random() < 0.3 then -- 30% chance to have starting garages
    local availableGarages = getAvailableGarageIds()
    if #availableGarages > 0 then
      local garageCount = math.random(1, math.min(3, #availableGarages))
      local selectedGarages = {}
      
      for i = 1, garageCount do
        local garageIndex = math.random(1, #availableGarages)
        local garageId = availableGarages[garageIndex]
        table.insert(selectedGarages, garageId)
        table.remove(availableGarages, garageIndex) -- Remove to avoid duplicates
      end
      
      data.startingGarages = selectedGarages
    end
  end

  return data
end

local function generateRandomSeed(options)
  local data, challengeError = generateRandomChallengeData(options)
  if not data then
    return nil, challengeError
  end

  local seed, err = encodeChallengeToSeed(data)
  if not seed then
    return nil, err
  end
  return seed, data
end

-- ============================================================================
-- EXPORTS
-- ============================================================================

M.encodeChallengeToSeed = encodeChallengeToSeed
M.decodeSeedToChallenge = decodeSeedToChallenge
M.resolveHashesToNames = resolveHashesToNames
M.createChallengeFromSeed = createChallengeFromSeed
M.generateRandomChallengeData = generateRandomChallengeData
M.generateRandomSeed = generateRandomSeed

return M