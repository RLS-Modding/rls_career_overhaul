-- Per-producer in-memory run/result ids for lap, finish and abort notifications.
-- Create one instance per load; consumers reject duplicate results without storing ids in player saves.
local M = {}

function M.create(source)
  local runs = 0
  local instance = {}

  -- A new run for raceName; returns the run handle the producer keeps until the race ends.
  function instance.beginRun(raceName)
    runs = runs + 1
    return { source = source, raceName = raceName, run = runs }
  end

  function instance.id(run, part)
    if type(run) ~= "table" then return nil end
    return string.format("%s:%s:%d:%s", tostring(run.source), tostring(run.raceName), run.run, tostring(part))
  end

  function instance.runCount()
    return runs
  end

  return instance
end

return M
