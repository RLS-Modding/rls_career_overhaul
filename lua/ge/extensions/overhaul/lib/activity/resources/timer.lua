-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Activity resource: delayed callbacks with cancellation. after(seconds, fn, ...) runs fn on a job after `seconds`,
-- unless cancelAll ran since it was scheduled. Cancellation releases sleeping jobs and callback state.
local M = {}

function M.create(owner)
  local timer = {}
  local generation = 0
  local pending = 0
  local entries = {}

  local function finish(entry)
    if not entries[entry] then return end
    entries[entry] = nil
    pending = pending - 1
    entry.fn, entry.args, entry.job = nil, nil, nil
  end

  function timer.getOwner() return owner end
  function timer.generation() return generation end
  function timer.pending() return pending end

  -- Returns the generation the callback belongs to, or nil when fn is not a function.
  function timer.after(seconds, fn, ...)
    if type(fn) ~= 'function' then return nil end
    local stamp = generation
    local entry = {fn = fn, args = {n = select('#', ...), ...}}
    entries[entry] = true
    pending = pending + 1
    entry.job = core_jobsystem.create(function(job)
      if not entries[entry] then return end
      if seconds and seconds > 0 then job.sleep(seconds) end
      if not entries[entry] then return end
      local callback, args = entry.fn, entry.args
      finish(entry)
      if stamp == generation then callback(unpack(args, 1, args.n)) end
    end)
    return stamp
  end

  function timer.cancelAll()
    generation = generation + 1
    for entry in pairs(entries) do
      local job = entry.job
      finish(entry)
      if job and core_jobsystem.cancelJob then core_jobsystem.cancelJob(job) end
    end
  end

  return timer
end

return M
