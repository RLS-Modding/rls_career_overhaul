-- GE-callable API: enable(sequence), disable(sequence).
-- The monotonic sequence rejects stale GE toggles; player/controllerSeam.lua owns the controller adapter.
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')

local generation = -1
local active = false
local ownedController
local bridges = {}
local cargoName = 'gameplayInterfaceModules_overhaulCargoContainers'
local stateName = 'gameplayInterfaceModules_overhaulVehicleState'
local controllerName = 'overhaulPlayerController'
local gearGuardName = 'overhaulPauseGearGuard'

local function wrap(target, name, handler)
  local original = target[name]
  if type(original) ~= 'function' then return end
  local state = {active = true}
  local wrapper = function(...)
    if state.active and active then return handler(...) end
    return original(...)
  end
  bridges[#bridges + 1] = {target = target, name = name, original = original, wrapper = wrapper, state = state}
  target[name] = wrapper
end

local function restoreBridges()
  for index = #bridges, 1, -1 do
    local bridge = bridges[index]
    bridge.state.active = false
    if bridge.target[bridge.name] == bridge.wrapper then bridge.target[bridge.name] = bridge.original end
    bridges[index] = nil
  end
end

local function replayInputs(target, state)
  if not target or not state then return end
  target.walkLeftRightRaw(state.x)
  target.walkUpDownRaw(state.y)
  target.setSpeedCoef(state.speed)
  target.setFreeze(state.frozen and 1 or 0)
  if state.cameraRotation then target.setCameraControlData({cameraRotation = state.cameraRotation}) end
  if state.crouching then target.crouch(-1) end
end

local function restoreStock()
  local state = ownedController and ownedController.getControlState()
  restoreBridges()
  if ownedController then
    controller.unloadControllerExternal(controllerName)
    ownedController = nil
    controller.init()
    controller.initSecondStage()
    controller.initSounds()
    controller.initLastStage()
    replayInputs(controller.mainController, state)
  end
end

local function activatePlayer()
  local main = controller.mainController
  if not main or main.name ~= 'playerController' then return end
  local data
  for _, row in pairs(v.data.controller or {}) do
    if row.fileName == 'playerController' and (row.name or row.fileName) == 'playerController' then
      data = tableMergeRecursive(deepcopy(row), deepcopy(v.data[row.name or row.fileName] or {}))
      break
    end
  end
  if not data then error('Missing stock player controller data') end
  rerequire('controller/' .. controllerName)
  ownedController = controller.loadControllerExternal(controllerName, controllerName, data)
  if not ownedController then error('Could not load Overhaul player controller') end
  ownedController.setFreeze(controller.isFrozen and 1 or 0)
  controller.unloadControllerExternal('playerController')
  for _, name in ipairs({
    'walkLeftRightRaw', 'walkLeftRight', 'walkUpDownRaw', 'walkUpDown', 'setSpeedCoef',
    'toggleSpeedCoef', 'jump', 'crouch', 'toggleCrouch', 'setFreeze', 'setCameraControlData'
  }) do
    local method = ownedController[name]
    wrap(main, name, function(...) return method(...) end)
  end
  for _, name in ipairs({'getController', 'getControllerSafe'}) do
    local original = controller[name]
    wrap(controller, name, function(requestedName, ...)
      if requestedName == 'playerController' then return ownedController end
      return original(requestedName, ...)
    end)
  end
  -- GE may have sent movement settings before this asynchronously loaded controller existed.
  obj:queueGameEngineLua(geCallback.command("playerControllerReady", tostring(obj:getId())))
end

local function setActive(enabled, sequence)
  sequence = tonumber(sequence)
  if not sequence or sequence < generation then return false end
  if sequence == generation then return active == enabled end
  generation = sequence
  if enabled then
    if active then return true end
    active = true
    local ok, err = pcall(function()
      -- The explicit loader name avoids stock-scanned folders while preserving gameplayInterface discovery.
      extensions.loadAtRoot('lua/vehicle/extensions/overhaulCargoContainers', 'gameplayInterfaceModules')
      local cargo = extensions[cargoName]
      if not cargo or not cargo.setActive(true) then error('Could not activate Overhaul cargo API') end
      extensions.loadAtRoot('lua/vehicle/extensions/overhaulVehicleState', 'gameplayInterfaceModules')
      local state = extensions[stateName]
      if not state or not state.setActive(true) then error('Could not activate vehicle state API') end
      activatePlayer()
    end)
    if not ok then
      active = false
      restoreStock()
      if extensions[cargoName] then extensions[cargoName].setActive(false) end
      if extensions[stateName] then extensions[stateName].setActive(false) end
      error(err)
    end
    extensions.load(gearGuardName)
  else
    active = false
    extensions.unload(gearGuardName)
    restoreStock()
    if extensions[cargoName] then extensions[cargoName].setActive(false) end
    if extensions[stateName] then extensions[stateName].setActive(false) end
  end
  return true
end

M.enable = function(sequence) return setActive(true, sequence) end
M.disable = function(sequence) return setActive(false, sequence) end
M.onReset = function()
  if not active then return end
  restoreStock()
  activatePlayer()
end
M.onExtensionUnloaded = function()
  active = false
  extensions.unload(gearGuardName)
  restoreStock()
  if extensions[cargoName] then extensions[cargoName].setActive(false) end
  if extensions[stateName] then extensions[stateName].setActive(false) end
end

return M
