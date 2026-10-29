-- Resolve save JSON by actual filename spelling without changing source files.
local M = {}

function M.readJson(file)
  local source = file:gsub('\\', '/'):gsub('/+$', '')
  local normalized = source:gsub('^/+', '')
  local directory = source:match('^(.*)/[^/]+$')
  local found
  for _, candidate in ipairs(FS:findFiles(directory, '*', 0, true, false) or {}) do
    local path = candidate:gsub('\\', '/'):gsub('^/+', ''):gsub('/+$', '')
    if path:lower() == normalized:lower() then
      if found then return nil end
      found = candidate
    end
  end
  return found and jsonReadFile(found) or nil
end

return M
