-- Vehicle-file stamps retained between careers and invalidated by VFS changes.
-- Exhaustive file stamps detect in-place edits that directory modification times miss.
local M = {}

local cachedKey, cachedStamp
local gameVersion, gameVersionMounts
local generation = 0
-- Startup VFS events cannot invalidate a stamp until this VM has issued its first exhaustive scan.
local issued = false

local function invalidate()
  cachedKey, cachedStamp = nil, nil
  if issued then generation = generation + 1 end
  local vc = overhaul_career_market_valueCalculator
  if vc and vc.clearVehiclePcPartsCatalogSumCache then vc.clearVehiclePcPartsCatalogSumCache() end
end

-- Activation notifications repeat during career startup even when the VFS is
-- unchanged. Retain the parsed game identity across those catalog resets.
function M.getGameVersion(build)
  local mounts = {}
  for name, mod in pairs(core_modmanager.getMods() or {}) do
    if type(mod) == "table" and mod.active ~= false then
      local stat = type(mod.stat) == "table" and mod.stat or {}
      mounts[#mounts + 1] = table.concat({tostring(name), tostring(mod.fullpath),
        tostring(stat.filesize), tostring(stat.modtime)}, "|")
    end
  end
  table.sort(mounts)
  local key = table.concat(mounts, "\n")
  if gameVersionMounts ~= key then
    gameVersion = build()
    gameVersionMounts = key
  end
  return gameVersion
end

function M.getStamp(key, build)
  if cachedKey ~= key then
    local stamp = build()
    -- A delivered change event must invalidate even when size/mtime were
    -- preserved. Generation is session-local; a new VM still scans all files.
    cachedStamp = stamp .. (generation > 0 and ('|vfs=' .. generation) or '')
    cachedKey = key
  end
  issued = true
  return cachedStamp
end

function M.onFileChanged(filename)
  if type(filename) ~= 'string' then gameVersionMounts = nil; invalidate(); return end
  local path = filename:lower():gsub('\\', '/')
  if path:match('^/?integrity%.json$') then gameVersionMounts = nil; invalidate(); return end
  if path:match('%.jbeam$') or path:match('%.pc$') or path:match('%.zip$')
      or path:match('^/?vehicles/') or path:match('^/?vehicles$') then invalidate() end
end

M.onModActivated = invalidate
M.onModDeactivated = invalidate
M.onModManagerReady = invalidate
function M.onExtensionUnloaded()
  gameVersionMounts = nil
  invalidate()
end
return M
