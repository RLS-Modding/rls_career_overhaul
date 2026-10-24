-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Installation identity shared by the shell and readers, independent of extension load/unload order.
local M = {}

local OWN_FILE = "/lua/ge/extensions/overhaul/shell/extensionManager.lua"
-- Release ZIPs, Repository installs and unpacked dev copies have their own mod-manager names.
local LEGACY_MOD_NAME, LEGACY_MOD_ID = "rls_career_overhaul", "RLSCO24"
local ourModName, ourModId

local function findOwnMod()
  local modManager = rawget(_G, "core_modmanager")
  local ok, mod = pcall(modManager.getModFromPath, OWN_FILE)
  if ok and type(mod) == "table" and mod.modname then return mod end
  local mods = modManager.getMods() or {}
  local real = tostring(FS:getFileRealPath(OWN_FILE) or ""):gsub("\\", "/"):lower()
  if real ~= "" then
    for _, mod in pairs(mods) do
      local suffix = mod.unpackedPath and (mod.unpackedPath:gsub("/+$", "") .. OWN_FILE):lower()
      if suffix and real:sub(-#suffix) == suffix then return mod end
    end
  end
  for name, mod in pairs(mods) do
    if name == LEGACY_MOD_NAME or (mod.modData and mod.modData.tagid == LEGACY_MOD_ID) then return mod end
  end
  return nil
end

function M.identifyOwnMod()
  local mod = findOwnMod()
  if mod then
    ourModName = mod.modname
    ourModId = mod.modID or (mod.modData and mod.modData.tagid) or nil
  end
  return mod
end

function M.isOwnMod(modData)
  if type(modData) ~= "table" then return false end
  if ourModName then return modData.modname == ourModName end
  return modData.modname == LEGACY_MOD_NAME or (modData.modData ~= nil and modData.modData.tagid == LEGACY_MOD_ID)
end

function M.getModData()
  return {name = ourModName, id = ourModId}
end

return M
