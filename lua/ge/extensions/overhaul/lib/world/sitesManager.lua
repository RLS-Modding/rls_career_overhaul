-- Outside a level the stock sites manager is loaded on demand.
-- Resolve each call so a level change or Lua reload cannot leave a stale owner.
local M = {}

function M.sitesManager()
  if not gameplay_sites_sitesManager then extensions.load('gameplay_sites_sitesManager') end
  return gameplay_sites_sitesManager
end

return M
