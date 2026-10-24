-- Warns when files in the user folder's levels/<map>/ override a map Overhaul ships, since those files win over the mod's.
-- Helpers find the overriding files, checkLevels reports them once per profile, and the hook at the bottom runs that check.
local M = {}

local LOG_TAG = "clearLevels"
local LEVELS_ROOT = "levels/"

-- One check per session: the first profile that sets a save path runs it.
local checked = false

local function getMapDevMode()
  if not overhaul_shell_settings or type(overhaul_shell_settings.getSetting) ~= "function" then
    return nil
  end
  if type(overhaul_shell_settings.isLoaded) == "function" and not overhaul_shell_settings.isLoaded() then
    -- Settings load lazily; ask once before deciding the mode is unknown.
    if type(overhaul_shell_settings.loadSettings) == "function" then
      overhaul_shell_settings.loadSettings()
    end
    if not overhaul_shell_settings.isLoaded() then
      return nil
    end
  end
  return overhaul_shell_settings.getSetting("mapDevMode") == true
end

local function normalizePath(path)
  return (tostring(path or ""):gsub("\\", "/"))
end

-- Resolves the real user folder, following current -> updating junctions to where the files live.
local function getResolvedUserRoot()
  local settingsReal = normalizePath(FS:getFileRealPath("settings"))
  if settingsReal ~= "" then
    local idx = settingsReal:find("/settings/?$") or settingsReal:find("/settings/")
    if idx then
      return settingsReal:sub(1, idx)
    end
  end
  local user = normalizePath(FS:getUserPath())
  if user ~= "" and not string.endswith(user, "/") then
    user = user .. "/"
  end
  return user
end

-- Only files on disk under <userfolder>/levels/<map>/... (not mods/ or game mounts).
local function isUserLevelsOverlayFile(vpath, map, userRoot)
  local real = normalizePath(FS:getFileRealPath(vpath))
  if real == "" then
    return false
  end
  if real:find("/mods/") then
    return false
  end
  local mapPrefix = userRoot .. "levels/" .. map .. "/"
  return string.startswith(real, mapPrefix)
end

local function collectUserOverlayFiles(map)
  local userRoot = getResolvedUserRoot()
  if userRoot == "" then
    return nil, "user folder could not be resolved"
  end
  local files = FS:findFiles(LEVELS_ROOT .. map, "*.*", -1, true, false) or {}
  local userFiles = {}
  for _, vpath in ipairs(files) do
    vpath = normalizePath(vpath):gsub("^/", "")
    if isUserLevelsOverlayFile(vpath, map, userRoot) then
      table.insert(userFiles, vpath)
    end
  end
  return userFiles
end

-- Files in the user folder's levels/<map>/ win over the mod's; they are the player's, so only report them.
local function checkLevels()
  local devMode = getMapDevMode()
  if devMode == nil then
    log("W", LOG_TAG, "RLS settings not loaded yet; skipping userfolder level check")
    return
  end
  if devMode then
    log("I", LOG_TAG, "mapDevMode on, skipping")
    return
  end

  if not FS:directoryExists(LEVELS_ROOT) then
    return
  end
  if not overhaul_world_maps or type(overhaul_world_maps.getCompatibleMaps) ~= "function" then
    log("W", LOG_TAG, "overhaul_world_maps unavailable; skipping userfolder level check")
    return
  end

  local found = {}
  for map, _ in pairs(overhaul_world_maps.getCompatibleMaps() or {}) do
    if FS:directoryExists(LEVELS_ROOT .. map) then
      local userFiles, reason = collectUserOverlayFiles(map)
      if not userFiles then
        log("W", LOG_TAG, string.format("[%s] cannot tell user files from mod files (%s)", map, tostring(reason)))
      elseif #userFiles > 0 then
        log("W", LOG_TAG, string.format("[%s] %d file(s) in the user folder levels/%s/ override the map: %s", map, #userFiles, map, table.concat(userFiles, ", ")))
        found[#found + 1] = string.format("levels/%s/ (%d)", map, #userFiles)
      end
    end
  end
  if #found > 0 then
    table.sort(found)
    guihooks.trigger("toastrMsg", {type = "warning", title = "Career Overhaul", msg = "Files in your user folder override Overhaul maps: " .. table.concat(found, ", ") .. ". Move them out if a map looks wrong.", config = {timeOut = 15000}})
  end
end

-- Kept for callers; dev mode is read again when the check runs, so nothing to update here.
M.changeDevMode = function(_devMode)
end

M.checkLevels = checkLevels

local function onOverhaulSetProfile(savePath)
  if checked or not savePath then return end
  checked = true
  checkLevels()
end

M.onOverhaulSetProfile = onOverhaulSetProfile

return M
