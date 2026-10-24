-- Spreads a long UI list build over several frames with the stock job system (core_jobsystem), so one frame
-- never holds the whole build. run(work) calls work(pace); pace() yields once the budget is spent. Stateless.
local M = {}

-- Half a 60 Hz frame: the game keeps rendering smoothly while a list is built.
local FRAME_BUDGET_SECONDS = 0.008

function M.run(work)
  core_jobsystem.create(function(job) work(job.yield) end, FRAME_BUDGET_SECONDS)
end

return M
