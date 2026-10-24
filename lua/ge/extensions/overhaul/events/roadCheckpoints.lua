-- Road geometry, curvature checkpoints and stationary/off-road race monitoring.
-- Read geometry and named segmentation/joining steps, monitoring timers, route loading and public services.
local M = {}
require("overhaul/lib/events/course/roadCheckpoints").create({exports = M})

function M.onExtensionLoaded() end

return M
