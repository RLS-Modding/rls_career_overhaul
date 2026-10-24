-- Makes core_jobsystem safe to cancel from inside its own update while Overhaul runs.
-- Defers cancellation until the frame finishes traversing the current jobs.
local M = {}

M.dependencies = { "overhaul_shell_patches" }

local PATCH_ID = "jobsystem"

local updating = false

local function finished() end

-- Turns a running job into a finished stand-in; the update loop drops it without its exit callback.
local function retire(job)
  job.t = coroutine.create(finished)
  job.args = nil
  job.exitcbl = nil
  job.running = false
end

-- An exit callback that throws is logged instead of breaking the update loop.
local function protectExitCallback(callback)
  return function(job)
    local ok, err = xpcall(function() return callback(job) end, debug.traceback)
    if not ok then log("E", "jobsystem", "job exit callback error: " .. tostring(err)) end
  end
end

local wrappers = {
  onUpdate = function(original)
    return function(...)
      updating = true
      local ok, err = xpcall(original, debug.traceback, ...)
      updating = false
      if not ok then error(err, 0) end
    end
  end,

  cancelJob = function(original)
    return function(job)
      if updating and type(job) == "table" then
        if not job.running then return false end
        retire(job)
        return true
      end
      return original(job)
    end
  end,

  create = function(original)
    return function(...)
      local job = original(...)
      if type(job) == "table" and type(job.setExitCallback) == "function" then
        local setExitCallback = job.setExitCallback
        job.setExitCallback = function(callback)
          if type(callback) == "function" then callback = protectExitCallback(callback) end
          return setExitCallback(callback)
        end
      end
      return job
    end
  end,
}

M.isUpdating = function() return updating end

M.onExtensionLoaded = function()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return core_jobsystem end, wrappers)
end

M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
