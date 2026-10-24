-- Context queries for phone apps, services and save code. Each call resolves engine and extension globals
-- when it runs, so a module that is not loaded yet reads as absent; the variants differ on purpose.
local M = {}

-- Phone apps: the game state decides first (freeroam is never a career, overhaul always is), then the career module.
function M.isCareerActive()
  local state = core_gamestate.state and core_gamestate.state.state
  if state == "freeroam" then return false end
  if state == "overhaul" then return true end
  return overhaul_career_career and overhaul_career_career.isActive()
end

-- Save code: only a career module that answers true counts.
function M.isCareerActiveStrict()
  return overhaul_career_career ~= nil and overhaul_career_career.isActive ~= nil and overhaul_career_career.isActive() == true
end

-- Freeroam events: the career module alone, and only when isActive is a function.
function M.isCareerModuleActive()
  local career = overhaul_career_career
  return career and type(career.isActive) == "function" and career.isActive()
end

function M.isOverhaulActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() == true
end

-- Persistent patches also run in vanilla; an absent or failing optional game-mode provider leaves them inactive.
function M.isOverhaulActiveSafe()
  local gameMode = overhaul_shell_gameMode
  if type(gameMode) ~= "table" or type(gameMode.isActive) ~= "function" then return false end
  local ok, active = pcall(gameMode.isActive)
  return ok and active or false
end

-- Level the player is on: the loaded level, else the mission's level, else nil.
function M.currentLevel()
  if getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  if getMissionFilename() ~= "" then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

-- Loaded level only; an empty string when there is none.
function M.currentLevelId()
  if getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  return ""
end

-- Name of the UI route on screen: the request name, else the resolved screen id, else nil.
function M.currentUiRouteName()
  if not (ui_router and ui_router.getState) then return nil end
  local ok, state = pcall(ui_router.getState)
  if not ok or type(state) ~= "table" or type(state.currentRoute) ~= "table" then
    return nil
  end
  local entry = state.currentRoute
  if entry.request and type(entry.request.name) == "string" then
    return entry.request.name
  end
  if entry.resolved and type(entry.resolved.screenId) == "string" then
    return entry.resolved.screenId
  end
  return nil
end

-- The game loads its sites manager with each level; outside a level it is loaded on demand.
function M.sitesManager()
  if not gameplay_sites_sitesManager then extensions.load("gameplay_sites_sitesManager") end
  return gameplay_sites_sitesManager
end

-- Value of an inventory vehicle: the market value, else the sell value, else 0.
function M.inventoryVehicleValue(inventoryId)
  if not inventoryId or not overhaul_career_market_valueCalculator then return 0 end
  local value = overhaul_career_market_valueCalculator.getInventoryVehicleValue and overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId)
  if not value and overhaul_career_market_valueCalculator.getInventoryVehicleSellValue then
    value = overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  end
  return tonumber(value) or 0
end

return M
