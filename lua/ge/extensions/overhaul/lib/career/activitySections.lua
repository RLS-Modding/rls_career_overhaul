-- Economy adjuster activity sections, discovered from /gameplay/overhaul/economy/activities/<id>.json.
-- Require-only library: reads files and keeps no state; callers cache the list per extension instance.
local manifests = require("overhaul/lib/platform/manifests")

local M = {}

M.dir = "/gameplay/overhaul/economy/activities/"

local TAG = "overhaul_career_activitySections"

local function validate(data)
  if not manifests.isNonEmptyString(data.source) then return nil, "missing source" end
  if not manifests.isStringList(data.keys) then return nil, "keys must be a non-empty list of economy keys" end
  for _, field in ipairs({"extension", "activity"}) do
    if data[field] ~= nil and not manifests.isNonEmptyString(data[field]) then return nil, field .. " must be a string" end
  end
  for _, field in ipairs({"whenLoaded", "passengerTypes"}) do
    if data[field] ~= nil and type(data[field]) ~= "boolean" then return nil, field .. " must be true or false" end
  end
  if data.whenLoaded and not data.extension then return nil, "whenLoaded needs the owner extension" end
  if data.passengerTypes and not data.whenLoaded then return nil, "passengerTypes needs whenLoaded" end
  return data
end

-- The sections in declared order (then id), and the rejected files.
function M.sections()
  return manifests.scan({dir = M.dir, tag = TAG, validate = validate})
end

-- Published owner keys override manifest keys only when the owner supplies a list.
function M.keys(section, owner)
  local definition = type(owner) == "table" and owner.activity or nil
  if type(definition) == "table" and section.activity and definition.id ~= section.activity then
    definition = definition[section.activity]
  end
  local keys = type(definition) == "table" and definition.economyKeys or nil
  if type(keys) == "table" and #keys > 0 then return keys end
  return section.keys
end

return M
