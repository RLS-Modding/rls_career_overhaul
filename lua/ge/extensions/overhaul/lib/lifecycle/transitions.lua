-- Exit and reload continuations: they report host transitions around the save system's flush before exit.
-- Each patched call waits for the pending career save, then runs the original call unchanged.
local lifecycle = require('overhaul/lib/lifecycle/host')
local temporaryVehicles = require('overhaul/lib/vehicles/temporary')

local M = {}

-- Leaving the game or the level waits for the pending career save (saveSystem's exit wrappers).
M.EXIT_PATCHES = {"saveExitGlobals", "saveExitTorqueQuit", "saveExitStartFreeroam"}

function M.unregisterExitPatches(globalTable)
  local patches = globalTable.overhaul_shell_patches
  if not patches then return end
  for _, id in ipairs(M.EXIT_PATCHES) do patches.unregister(id) end
end

-- save: the save system ({flushSaveForExit = fn}).
local function flushThenCall(save, kind, via)
  return function(original)
    if type(original) ~= "function" then return end
    return function(...)
      local args = {...}
      local transition = lifecycle.begin(kind, {via = via})
      save.flushSaveForExit(function() lifecycle.finish(transition, "done"); original(unpack(args)) end)
    end
  end
end

function M.registerExitPatches(save, globalTable)
  M.unregisterExitPatches(globalTable)
  local patches = globalTable.overhaul_shell_patches
  patches.registerFields("saveExitGlobals", function() return globalTable end, {
    returnToMainMenu = flushThenCall(save, "unload", "returnToMainMenu"),
    quit = flushThenCall(save, "exit", "quit"),
  })
  patches.registerFields("saveExitTorqueQuit", function() return rawget(globalTable, "TorqueScript") end, {
    eval = function(original)
      if type(original) ~= "function" then return end
      return function(command, ...)
        local args = {...}
        if type(command) == "string" and command:match("^%s*quit%(%s*%)%s*;?%s*$") then
          local transition = lifecycle.begin("exit", {via = "TorqueScript quit"})
          save.flushSaveForExit(function() lifecycle.finish(transition, "done"); original(command, unpack(args)) end)
        else
          return original(command, unpack(args))
        end
      end
    end,
  })
  patches.registerFields("saveExitStartFreeroam", function() return rawget(globalTable, "freeroam_freeroam") end, {
    startFreeroam = function(original)
      if type(original) ~= "function" then return end
      return function(...)
        local args, count = {...}, select('#', ...)
        local transition = lifecycle.begin("unload", {via = "startFreeroam"})
        return save.flushSaveForExit(function() lifecycle.finish(transition, "done"); original(unpack(args, 1, count)) end)
      end
    end,
  })
end

-- The game is closing: finish the exit save, including its fresh capture.
function M.preExit(save)
  local transition = lifecycle.begin("exit", {via = "onPreExit"})
  local finished = save.flushSaveForExit()
  lifecycle.finish(transition, finished and "done" or "incomplete")
end

-- Repeated requests join the save; a stalled reload has an explicit timeout escape.
function M.newReload(save, globalTable)
  local waitTimeoutSeconds = 45
  local time = (globalTable.os or os).time
  local pendingReload = false
  local pendingSince = nil
  local transition = nil
  local reload = {}
  local function doReload()
    pendingReload = false
    pendingSince = nil
    -- Temporary vehicles go before the engine serializes stock checkpoints and traffic; see the library.
    temporaryVehicles.releaseAll()
    lifecycle.finish(transition, "done")
    globalTable.Lua:requestReload()
    globalTable.ui_message('engine.lua.reloaded', 2, 'lua', 'refresh')
  end
  function reload.request()
    if pendingReload then
      if time() - pendingSince < waitTimeoutSeconds then
        return save.flushSaveForExit(doReload)
      end
      -- Only another request after the timeout may abandon a stuck save.
      save.cancelPendingExit()
      lifecycle.phase(transition, "bypass")
      return doReload()
    end
    transition = lifecycle.begin("reload")
    globalTable.extensions.hook("onOverhaulBeforeLuaReload")
    if save.shouldSaveBeforeReload() then save.saveCurrent(nil, {force = true}) end
    pendingReload = true
    pendingSince = time()
    if save.flushSaveForExit(doReload) then return end
    lifecycle.phase(transition, "waiting")
    globalTable.guihooks.trigger('toastrMsg', {type='info', title='Lua reload waiting for save', msg='If saving stalls for 45 seconds, press again to reload without saving.'})
  end
  -- Career stopped: a waiting reload is forgotten (its continuation went with the exit wait).
  function reload.reset()
    if pendingReload then lifecycle.finish(transition, "replaced") end
    pendingReload = false
    pendingSince = nil
  end
  function reload.isPending() return pendingReload end
  return reload
end

return M
