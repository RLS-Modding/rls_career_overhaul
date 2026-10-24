-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Economy umbrella sections and type aliases, read from /gameplay/overhaul/economy/sections/<id>.json by the
-- economy policy and adjuster. Require-only: every call scans the folder; callers cache the result per instance.
local manifests = require("overhaul/lib/platform/manifests")

-- The main menu reads canonical types before career modules activate.
local M = {}

M.dir = "/gameplay/overhaul/economy/sections/"

local TAG = "overhaul_career_economyManifest"
-- Manifest-only fields: not part of the section the policy and the UI see.
local MANIFEST_ONLY = {order = true, aliases = true}

local function warn(message)
  log("W", TAG, message)
end

local function validChild(child)
  return type(child) == "table" and manifests.isNonEmptyString(child.id) and manifests.isNonEmptyString(child.label)
    and manifests.isStringList(child.economyKeys)
    and (child.skillKey == nil or manifests.isNonEmptyString(child.skillKey))
    and (child.expandable == nil or manifests.isStringList(child.expandable, true))
end

local function validAliases(aliases)
  if type(aliases) ~= "table" then return false end
  for alias, canonical in pairs(aliases) do
    if not manifests.isNonEmptyString(alias) or not manifests.isNonEmptyString(canonical) then return false end
  end
  return true
end

local function validate(data)
  if not manifests.isNonEmptyString(data.label) then return nil, "missing label" end
  if type(data.children) ~= "table" or #data.children == 0 then return nil, "children must be a non-empty list" end
  for index, child in ipairs(data.children) do
    if not validChild(child) then
      return nil, string.format("child %d needs id, label and a list of economyKeys (skillKey, expandable optional)", index)
    end
  end
  if data.aliases ~= nil and not validAliases(data.aliases) then
    return nil, "aliases must map a key to its canonical key"
  end
  return data
end

-- The usable section manifests (sorted by order, then id) and the rejected files.
function M.scan()
  return manifests.scan({dir = M.dir, tag = TAG, validate = validate})
end

-- Keep umbrella section order consistent between policy and UI.
function M.sections(scanned)
  local result = {}
  for _, manifest in ipairs(scanned or M.scan()) do
    local section = {}
    for key, value in pairs(manifest) do
      if not MANIFEST_ONLY[key] then section[key] = value end
    end
    result[#result + 1] = section
  end
  return result
end

-- The first declared alias wins so later sections cannot replace its meaning.
function M.typeAliases(scanned)
  local aliasToCanonical, aliasOwner = {}, {}
  for _, manifest in ipairs(scanned or M.scan()) do
    if type(manifest.aliases) == "table" then
      local keys = {}
      for alias in pairs(manifest.aliases) do keys[#keys + 1] = alias end
      table.sort(keys)
      for _, alias in ipairs(keys) do
        local key, canonical = string.lower(alias), manifest.aliases[alias]
        if aliasToCanonical[key] == nil then
          aliasToCanonical[key], aliasOwner[key] = canonical, manifest.id
        elseif aliasToCanonical[key] ~= canonical then
          warn(string.format("%s: alias %s already maps to %s (section %s)", manifest.id, key, aliasToCanonical[key], aliasOwner[key]))
        end
      end
    end
  end
  return aliasToCanonical
end

-- Canonical economy keys of the manifest (aliases left out), in manifest order.
function M.canonicalTypes(scanned)
  scanned = scanned or M.scan()
  local aliases = M.typeAliases(scanned)
  local types = {}
  for _, section in ipairs(M.sections(scanned)) do
    for _, child in ipairs(section.children or {}) do
      for _, economyKey in ipairs(child.economyKeys or {}) do
        if not aliases[economyKey:lower()] then
          table.insert(types, economyKey)
        end
      end
    end
  end
  return types
end

return M
