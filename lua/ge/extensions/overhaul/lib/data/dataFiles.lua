-- Overhaul data lives under /gameplay/overhaul/. Lookups also see the game's own folder, and an
-- Overhaul file replaces the game file with the same relative path.
local M = {}

-- The Overhaul twin of a game data path, or nil when the path is not under gameplay/ or already is Overhaul's.
local function overhaulPath(path)
  local lead, rest = string.match(path, "^(/?)gameplay/(.*)$")
  if not rest or string.sub(rest, 1, 9) == "overhaul/" then return nil end
  return lead .. "gameplay/overhaul/" .. rest
end

-- The path under gameplay/ without the overhaul/ folder, so both twins of one file share a key.
local function relativeKey(file)
  local rest = string.match(file, "gameplay/(.*)$")
  if not rest then return file end
  if string.sub(rest, 1, 9) == "overhaul/" then rest = string.sub(rest, 10) end
  return rest
end

-- Files from the game folder and the Overhaul folder, one per relative key (Overhaul wins), sorted by key.
function M.findFiles(dir, pattern, depth, includeDirs, addRoot)
  local files = FS:findFiles(dir, pattern, depth, includeDirs, addRoot) or {}
  local overhaulTwin = overhaulPath(dir)
  if not overhaulTwin then return files end
  local byKey, keys = {}, {}
  for _, list in ipairs({files, FS:findFiles(overhaulTwin, pattern, depth, includeDirs, addRoot) or {}}) do
    for _, file in ipairs(list) do
      local key = relativeKey(file)
      if not byKey[key] then table.insert(keys, key) end
      byKey[key] = file
    end
  end
  table.sort(keys)
  local result = {}
  for i, key in ipairs(keys) do result[i] = byKey[key] end
  return result
end

-- The Overhaul file when it exists, else the path as given.
function M.resolve(path)
  local overhaulTwin = overhaulPath(path)
  if overhaulTwin and FS:fileExists(overhaulTwin) then return overhaulTwin end
  return path
end

-- The game's own path for an Overhaul path.
function M.toVanilla(path)
  return (string.gsub(path, "gameplay/overhaul/", "gameplay/", 1))
end

-- Asset folders next to a data file (covers, thumbnails) stay in the game's folder when it has one.
function M.assetDir(dir)
  local vanilla = M.toVanilla(dir)
  if vanilla ~= dir and FS:directoryExists(vanilla) then return vanilla end
  return dir
end

return M
