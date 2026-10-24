-- Activity resource: ground-marker route. A thin per-activity wrapper over routeLease, labelled with the activity id.
-- set, isCurrent and clear are unchanged.
local routeLease = require('overhaul/lib/activity/routeLease')

local M = {}

function M.create(owner)
  return routeLease.new(owner)
end

return M
