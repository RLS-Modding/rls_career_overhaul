-- Inert tutorial facade: the driving tutorial is not part of Overhaul by owner decision.
-- Callers still ask whether it runs, so it always answers no; it has no hooks and no save file.
local M = {}

function M.isActive() return false end
function M.getCurrentStep() return nil end

return M
