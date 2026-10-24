-- Real seconds spent while the simulation is paused, for career timers that must skip normal play time.
-- The counter only runs after enablePauseCounter(true); enabling or resetting clears the total.
local M = {}

local totalPauseTime = 0
local countPausedTime = false

-- A zero sim delta means the simulation is paused, so the real frame time counts.
function M.onUpdate(dt, dtSim)
  if countPausedTime and dtSim == 0 then
    totalPauseTime = totalPauseTime + dt
  end
end

function M.enablePauseCounter(enable)
  countPausedTime = enable
  totalPauseTime = 0
end

function M.getTotalPauseTime() return totalPauseTime end
function M.resetPauseTime() totalPauseTime = 0 end

return M
