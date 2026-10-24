-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Player abstract screen: the driver abstract menu opened from the computer, and the data it shows.
-- Fork of stock lua/ge/extensions/career/modules/playerAbstract.lua (BeamNG 0.40); read the menu functions, then the router hooks.
local M = {}

local originComputerId = nil

local function openPlayerAbstractMenu(_originComputerId)
  originComputerId = _originComputerId
  if originComputerId then
    extensions.ui_router.navigate("overhaul.computer.playerAbstract")
    extensions.hook("onOverhaulComputerPlayerAbstract")
  end
end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if menuData.computerFacility.functions["playerAbstract"] then
    local computerFunctionData = {
      id = "playerAbstract",
      routeTarget = "overhaul.computer.playerAbstract",
      label = _tr("ui.career.driverAbstract.title"),
      callback = function() openPlayerAbstractMenu(menuData.computerFacility.id) end,
      order = 15
    }
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
    end
    computerFunctions.general[computerFunctionData.id] = computerFunctionData
  end
end

local function closePlayerAbstractMenu()
  if originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    overhaul_career_garage_computer.openMenu(computer)
  else
    overhaul_career_career.closeAllMenus()
  end
end

local function getPlayerAbstractData()
  return overhaul_career_repair_insurance.getPlayerAbstractData()
end

-- Router lifecycle: attach the player abstract data into routeData so the UI
-- reads it from the routeData store instead of fetching it on mount.
local function onRouteMount(context, toRoute, fromRoute, data)
  data.playerAbstract = getPlayerAbstractData()
end

-- Router lifecycle: clear route-local state when leaving the screen.
local function onRouteLeave(context, toRoute, fromRoute, data)
  originComputerId = nil
end

-- Push fresh abstract data to an already-open screen (e.g. after a score reset).
local function sendPlayerAbstractDataToUI()
  guihooks.trigger("playerAbstractData", getPlayerAbstractData())
end

M.openPlayerAbstractMenu = openPlayerAbstractMenu
M.getPlayerAbstractData = getPlayerAbstractData
M.sendPlayerAbstractDataToUI = sendPlayerAbstractDataToUI
M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.closePlayerAbstractMenu = closePlayerAbstractMenu
M.onRouteMount = onRouteMount
M.onRouteLeave = onRouteLeave

return M