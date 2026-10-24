-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Inventory and auction spawn data can be a .pc file or an inline tuned build.
local M = {}

local function nonempty(value)
  return type(value) == 'table' and next(value) ~= nil
end

function M.configFile(config)
  local path = type(config) == 'table' and config.partConfigFilename
  if type(path) ~= 'string' or path == '' then return nil end
  if FS:fileExists(path) then return path end
  local absolute = '/' .. path:gsub('^/', '')
  if FS:fileExists(absolute) then return absolute end
end

function M.canBuild(config)
  return type(config) == 'table' and
    (M.configFile(config) ~= nil or nonempty(config.parts) or nonempty(config.partsTree))
end

function M.prepare(config, copy, model)
  if not M.canBuild(config) then return nil end
  local result = copy(config)
  local file = M.configFile(config)
  if not nonempty(config.parts) and not nonempty(config.partsTree) then
    -- Without inline parts, build from the .pc file and reapply saved overrides.
    local loaded = core_vehicle_partmgmt.buildConfigFromString('/vehicles/' .. model .. '/', file)
    if type(loaded) ~= 'table' then return nil end
    result = copy(loaded)
    for key, value in pairs(copy(config)) do
      if key == 'vars' and type(value) == 'table' then
        result.vars = result.vars or {}
        for name, setting in pairs(value) do result.vars[name] = setting end
      elseif key ~= 'parts' and key ~= 'partsTree' then
        result[key] = value
      end
    end
  end
  result.partConfigFilename = file
  if nonempty(result.partsTree) then
    result.parts = core_vehicle_partmgmt.partsTreeToPartsMap(result.partsTree)
  end
  result.partsTree = nil
  return result
end

return M
