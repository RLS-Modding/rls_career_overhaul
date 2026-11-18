local M = {}
local active, savedBrake = false, nil
local savedGearboxMode

local function getForwardMode()
  local config = v and v.data and v.data.vehicleController
  local modes = config and config.automaticModes
  if type(modes) ~= 'string' or modes:find('D', 1, true) then return 'D' end

  local mode = config.defaultAutomaticForwardMode or config.defaultForwardMode
  if mode == 'M1' then mode = 'M' end
  if type(mode) ~= 'string' or not mode:match('^[SM1-9]$') or not modes:find(mode, 1, true) then
    mode = modes:match('[SM1-9]')
  end
  return mode == 'M' and 'M1' or mode
end

function M.hold()
  if active or playerInfo and playerInfo.anyPlayerSeated then return false end
  savedBrake, active = electrics.values.brakeOverride, true
  local main = controller and controller.mainController
  savedGearboxMode = main and main.gearboxBehavior or electrics.values.gearboxMode
  if main and main.setGearboxMode then main.setGearboxMode('realistic') end
  electrics.values.brakeOverride = 1
  return true
end
function M.clear(playerHandoff)
  if not active then return end
  electrics.values.brakeOverride, savedBrake, active = savedBrake, nil, false
  if not playerHandoff and not (playerInfo and playerInfo.anyPlayerSeated) and input then input.event('brake', 0, 2) end
  local main = controller and controller.mainController
  if savedGearboxMode and main and main.setGearboxMode then main.setGearboxMode(savedGearboxMode) end
  savedGearboxMode = nil
end
function M.onPlayersChanged(seated)
  if seated then M.clear(true); extensions.unload('overhaulMotorsportStagingHold') end
end
function M.updateGFX()
  if not active then return end
  if playerInfo and playerInfo.anyPlayerSeated then M.onPlayersChanged(true); return end
  local main = controller and controller.mainController
  if main and main.setGearboxMode and main.gearboxBehavior ~= 'realistic' then main.setGearboxMode('realistic') end
  local state = main and main.getState and main.getState()
  if state and main.setState and (state.grb_mde == 'R' or state.grb_mde == 'N' or state.grb_mde == 'P') then
    local mode = getForwardMode()
    if mode then main.setState({grb_mde = mode}) end
  end
  electrics.values.brakeOverride = 1
end
M.onReset = M.clear
M.onExtensionUnloaded = M.clear
return M
