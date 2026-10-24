-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Loads and unloads an owner's child extensions from explicit name lists, never from a folder scan.
-- Copies each list before sorting so the owner can reuse its declaration order.
local M = {}

-- Owner lists are copied and sorted so a batch always loads in the same order.
local function sortedCopy(names)
  local copy = {}
  for _, name in ipairs(names or {}) do copy[#copy + 1] = name end
  table.sort(copy)
  return copy
end

-- The `preserved` child is not unloaded first, so an owner can keep one child running.
function M.load(childNames, preserved)
  local names = sortedCopy(childNames)
  local removed = {}
  for _, name in ipairs(names) do
    local keep = name == preserved or type(preserved) == "table" and preserved[name] == true
    if not keep then removed[#removed + 1] = name end
  end
  local manager = rawget(_G, "overhaul_shell_extensionManager")
  if manager and not manager.prepareForUnload(removed) then return nil end
  local owned = {}
  for _, name in ipairs(names) do
    local keep = name == preserved or type(preserved) == "table" and preserved[name] == true
    if not keep then extensions.unload(name) end
    setExtensionUnloadMode(name, "manual")
    owned[#owned + 1] = name
  end
  if #names > 0 then extensions.load(names) end
  return owned
end

function M.unload(names)
  local manager = rawget(_G, "overhaul_shell_extensionManager")
  if manager and not manager.prepareForUnload(names) then return false end
  for _, name in ipairs(names) do setExtensionUnloadMode(name, "auto") end
  for _, name in ipairs(names) do extensions.unload(name) end
  return true
end

return M
