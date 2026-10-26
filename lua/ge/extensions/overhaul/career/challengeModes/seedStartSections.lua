-- Seed sections for how a challenge starts: the starter vehicle list and the starting garage mode.
-- Named-format only; seed.lua owns the markers, the framing and the section dispatch.
local M = {}

-- Parts are seed.lua's binary helpers and format constants, plus the codec's staged section writer.
function M.create(parts)
  local binary = parts.binary
  local format = parts.format
  local appendSection = parts.appendSection

  local STARTING_GARAGE_MODE_VALUES = { default = 0, none = 1 }
  local STARTING_GARAGE_MODE_NAMES = { [0] = "default", [1] = "none" }

  -- The default mode is implied by a missing section.
  local function encodeStartingGarageModeSection(buffer, challengeData)
    local modeValue = STARTING_GARAGE_MODE_VALUES[challengeData.startingGarageMode]
    if not modeValue or modeValue == 0 then return true end
    return appendSection(buffer, "starting garage mode", function(section)
      table.insert(section, string.char(format.MARKER_STARTING_GARAGE_MODE))
      table.insert(section, string.char(modeValue))
    end)
  end

  local function encodeStarterVehicleSection(buffer, challengeData)
    local vehicles = challengeData.starterVehicles
    if type(vehicles) ~= "table" or #vehicles == 0 then return true end
    return appendSection(buffer, "starter vehicles", function(section)
      table.insert(section, string.char(format.MARKER_STARTER_VEHICLES))
      binary.writeVarInt(section, #vehicles)
      for _, vehicleId in ipairs(vehicles) do
        binary.writeName(section, tostring(vehicleId))
      end
    end)
  end

  -- Writes both optional sections; a challenge with neither adds no bytes.
  local function encode(buffer, challengeData)
    local succeeded, err = encodeStartingGarageModeSection(buffer, challengeData)
    if not succeeded then return false, err end
    return encodeStarterVehicleSection(buffer, challengeData)
  end

  local function readStartingGarageModeSection(challengeData, decodeState, bytes, offset)
    if not decodeState.namedFormat then
      return nil, "Starting garage mode needs a named seed"
    end
    if offset > #bytes then
      return nil, "Incomplete starting garage mode data"
    end
    local modeName = STARTING_GARAGE_MODE_NAMES[string.byte(bytes, offset)]
    if not modeName then
      return nil, "Invalid starting garage mode"
    end
    challengeData.startingGarageMode = modeName
    return offset + 1
  end

  local function readStarterVehicleSection(challengeData, decodeState, bytes, offset)
    if not decodeState.namedFormat then
      return nil, "Starter vehicles need a named seed"
    end
    if offset + 1 > #bytes then
      return nil, "Incomplete starter vehicle data"
    end
    local vehicleCount, nextOffset, err = binary.readVarInt(bytes, offset)
    if vehicleCount == nil then
      return nil, "Failed to read starter vehicle count: " .. tostring(err)
    end
    if vehicleCount * 2 > (#bytes - nextOffset + 1) then
      return nil, "Invalid starter vehicle count"
    end
    challengeData.starterVehicles = {}
    for index = 1, vehicleCount do
      local vehicleId = nil
      vehicleId, nextOffset, err = binary.readName(bytes, nextOffset)
      if vehicleId == nil then
        return nil, "Failed to read starter vehicle " .. index .. ": " .. tostring(err)
      end
      table.insert(challengeData.starterVehicles, vehicleId)
    end
    return nextOffset
  end

  return {
    encode = encode,
    readStartingGarageMode = readStartingGarageModeSection,
    readStarterVehicles = readStarterVehicleSection,
  }
end

return M
