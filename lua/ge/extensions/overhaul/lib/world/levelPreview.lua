-- Resolves installed level artwork for saved-career cards without loading world services.
-- Read the level's authored info first, then conventional filenames. Missing art stays unset.
local M = {}

function M.resolve(levelId)
  if type(levelId) ~= 'string' or levelId == '' then return nil end
  local level = core_levels and core_levels.getLevelByName(levelId)
  if not level or type(level.dir) ~= 'string' then return nil end
  local root = level.dir:gsub('/+$', '') .. '/'
  local info = jsonReadFile(root .. 'info.json')
  if type(info) ~= 'table' then info = {} end
  local function existing(value)
    if type(value) ~= 'string' or value == '' then return nil end
    local path = value:sub(1, 1) == '/' and value or root .. value
    if FS:fileExists(path) then return path end
  end
  local preview = existing(info.preview)
  if preview then return preview end
  for _, value in ipairs(type(info.previews) == 'table' and info.previews or {}) do
    preview = existing(value)
    if preview then return preview end
  end
  for _, filename in ipairs({'preview.png', 'preview.jpg'}) do
    preview = existing(filename)
    if preview then return preview end
  end
  -- core_levels normalizes level ids case-insensitively and preserves the installed directory.
  local name = root:match('/([^/]+)/$')
  for _, suffix in ipairs({'_preview.jpg', '_preview.png', '.jpg', '.png'}) do
    preview = existing(name .. suffix)
    if preview then return preview end
  end
end

return M
