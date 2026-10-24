-- Phone controller: decides when the career phone may open, closes it when the player drives off,
-- and routes it to the phone screens.
-- Shell state is projected before navigation; movement and close guards follow below.
local M = {}
local activityAccess = require('overhaul/lib/activity/access')
local capabilities = require('overhaul/lib/platform/capabilities')
local context = require('overhaul/lib/career/context')
local layoutOwner = require('overhaul/lib/phone/layoutOwner')
local clock = require('overhaul/lib/phone/clock')
local optional = require('overhaul/lib/platform/optional')

local LOG_TAG = 'phone'
local MPS_TO_MPH = 2.2369362921
local MOVING_SPEED_MPH = 5
local UPDATE_INTERVAL = 2.5
local CLOSE_SUPPRESS_SECONDS = 2.5
local DEFAULT_SUPPRESS_SECONDS = 2

local isPhoneOpen = false
local isClosing = false
local suppressOpenUntil = 0
local updateTimer = 0
local openingBlockers = {}
local previousGameplayRoute
local phoneRoutes
local routesDirty = true
local warnedRoutes = {}

-- Membership comes from the same host declarations as Vue. Keep the last good
-- snapshot if a mounted manifest scan fails during mod adoption.
local function isPhoneRoute(name)
  if type(name) ~= 'string' then return false end
  if routesDirty then
    local ok, routes = pcall(function()
      local names = {}
      local owners = require('overhaul/lib/ui/ownerCatalog').scan()
      for route, parent in pairs(owners.routeParents) do
        if parent == 'phone-shell' then names[route] = true end
      end
      local entries = require('overhaul/lib/ui/routeDiscovery').scan({
        reservedNames = owners.routeOwners, routeHosts = owners.routeHosts,
        warn = function(message)
          if warnedRoutes[message] then return end
          warnedRoutes[message] = true
          log('W', LOG_TAG, message)
        end,
      })
      for _, entry in ipairs(entries) do
        local parent = entry.parent or (entry.ownerKind == 'phone' and 'phone-shell' or 'overhaul')
        if parent == 'phone-shell' then names[entry.name] = true end
      end
      return names
    end)
    if ok then phoneRoutes = routes; routesDirty = false end
  end
  return phoneRoutes and phoneRoutes[name] == true or false
end

function M.onModActivated() routesDirty = true end
function M.onModDeactivated() routesDirty = true end
M.isPhoneRoute = isPhoneRoute

local function currentStatus()
  local careerActive = context.isCareerActive() == true
  local attributes = overhaul_career_economy_playerAttributes
  return {
    careerActive = careerActive,
    money = careerActive and attributes and attributes.getAttributeValue('money') or nil,
  }
end

local function requestState()
  local layout = layoutOwner.get()
  local snapshot = currentStatus()
  snapshot.layout = layout and layout.getShellLayout()
  snapshot.time = clock.current()
  guihooks.trigger('phoneShellState', snapshot)
end

local function initialPhoneRoute()
  return activityAccess.get().phoneRoute() or 'phone-main'
end

local function vehicleSpeedMs(vehId)
  if not vehId or vehId < 0 then return 0 end
  local vx, vy, vz = be:getObjectVelocityXYZ(vehId)
  vx, vy, vz = tonumber(vx) or 0, tonumber(vy) or 0, tonumber(vz) or 0
  return math.sqrt(vx * vx + vy * vy + vz * vz)
end

local function playerSpeedMph()
  return vehicleSpeedMs(be:getPlayerVehicleID(0)) * MPS_TO_MPH
end

local function phoneBlockedByMovement()
  local speedMph = playerSpeedMph()
  local allowMoving = activityAccess.get().allowPhoneWhileMoving()
  return not allowMoving and speedMph > MOVING_SPEED_MPH
end

local function getCurrentRouteName()
  local router = optional('ui_router')
  if not router then return nil end
  local current = router.getCurrent()
  if not current then return nil end
  if current.resolved and type(current.resolved.name) == 'string' then return current.resolved.name end
  if current.request and type(current.request.name) == 'string' then return current.request.name end
  if current.toRoute and type(current.toRoute.name) == 'string' then return current.toRoute.name end
  return nil
end

local function isComputerRouteName(name)
  if type(name) ~= 'string' then return false end
  return name == 'overhaul.computer' or name:find('^overhaul%.computer%.', 1) ~= nil or name == 'business-computer'
end

local function isComputerMenuOpen()
  if isComputerRouteName(getCurrentRouteName()) then return true end
  local computerSession = capabilities.get('computerSession')
  if computerSession and computerSession.isShoppingSessionActive() then
    return true
  end
  return false
end

local function notifyCloseComputerToOpenPhone()
  guihooks.trigger('toastrMsg', { type = 'info', title = 'Phone', msg = 'Close the computer to open the phone.' })
end

local function blockPhoneIfComputerOpen()
  if not isComputerMenuOpen() then return false end
  notifyCloseComputerToOpenPhone()
  return true
end

local function isPhoneUiAllowed()
  if next(openingBlockers) then return false end
  local routeName = getCurrentRouteName()
  if type(routeName) == 'string' then
    if routeName == 'menu' or routeName:find('^menu%.') == 1 then return false end
    if routeName:find('^overhaul%.profiles') == 1 then return false end
  end
  local gameState = core_gamestate.state
  if type(gameState) == 'table' and gameState.state == 'menu' then return false end
  return true
end

local function navigateToPlay()
  if extensions.ui_router then
    extensions.ui_router.navigate('play')
  end
end

local function suppressOpensFor(seconds)
  local untilTime = os.clock() + (tonumber(seconds) or DEFAULT_SUPPRESS_SECONDS)
  if untilTime > suppressOpenUntil then
    suppressOpenUntil = untilTime
  end
end

-- The close is done once no phone route is shown and the debounce has passed, even if the play view never remounted.
local function settleClosing()
  if isClosing and os.clock() >= suppressOpenUntil and not isPhoneRoute(getCurrentRouteName()) then
    isClosing = false
  end
end

local function opensSuppressed()
  settleClosing()
  return isClosing or os.clock() < suppressOpenUntil
end

local function closePhone()
  local onPhoneRoute = isPhoneRoute(getCurrentRouteName())
  if not isPhoneOpen and not onPhoneRoute and not isClosing then return end
  isPhoneOpen = false
  isClosing = true
  suppressOpensFor(CLOSE_SUPPRESS_SECONDS)
  guihooks.trigger('closePhone')
  if onPhoneRoute or isPhoneRoute(getCurrentRouteName()) then
    navigateToPlay()
  end
end

local function togglePhone(reason)
  settleClosing()
  if isPhoneOpen or isPhoneRoute(getCurrentRouteName()) or isClosing then
    closePhone()
    return
  end
  if opensSuppressed() then return end
  if not isPhoneUiAllowed() then return end
  if blockPhoneIfComputerOpen() then return end
  if phoneBlockedByMovement() then
    ui_message(reason or 'You must be stationary to open the phone.', reason and 5 or 3, 'info', 'info')
    return
  end
  isClosing = false
  isPhoneOpen = true
  requestState()
  extensions.ui_router.navigate(initialPhoneRoute())
end

local function markClosed()
  isPhoneOpen = false
end

local function markOpen()
  if opensSuppressed() or isClosing then return end
  isPhoneOpen = true
  isClosing = false
end

local function openRoute(routeName, params)
  if type(routeName) ~= 'string' or routeName == '' then
    return { success = false, reason = 'invalid_route' }
  end
  if opensSuppressed() then return { success = false, reason = 'opening_suppressed' } end
  if not isPhoneUiAllowed() then return { success = false, reason = 'ui_not_ready' } end
  if blockPhoneIfComputerOpen() then return { success = false, reason = 'computer_open' } end

  isClosing = false
  isPhoneOpen = true
  requestState()
  local result = extensions.ui_router.navigate(routeName, params or {})
  if result and result.success == false then
    isPhoneOpen = false
  end
  return result
end

local function openForTutorial()
  if opensSuppressed() then return false end
  if not overhaul_career_career.isActive() then
    return false
  end
  if activityAccess.get().blocksTutorialPhone() then return false end
  if not isPhoneUiAllowed() then return false end
  if blockPhoneIfComputerOpen() then return false end
  isClosing = false
  isPhoneOpen = true
  requestState()
  extensions.ui_router.navigate(initialPhoneRoute())
  return true
end

-- Closes an open phone once the player is moving too fast, unless they are walking.
local function closePhoneIfDriving()
  if not isPhoneOpen or isClosing then return end
  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
  if walking then return end
  if phoneBlockedByMovement() then
    ui_message('Phone closed due to player movement.', 3, 'info', 'info')
    closePhone()
  end
end

function M.onUpdate(dt)
  updateTimer = updateTimer + dt
  if updateTimer > UPDATE_INTERVAL then
    updateTimer = 0
    closePhoneIfDriving()
  end
end

function M.onOverhaulPlayerAttributesChanged(change)
  if not isPhoneOpen or isClosing or not change or change.money == nil then return end
  guihooks.trigger('phoneShellStatus', currentStatus())
end

-- Stock MenuToggle treats other UI routes as Back. Register the visible phone
-- route with its menu manager so Start opens pause even in the Angular path.
local function restoreGameplayRoute()
  if previousGameplayRoute == nil then return end
  extensions.ui_menuManager.setGameplayRoute(previousGameplayRoute)
  previousGameplayRoute = nil
end

function M.onAfterRouteChange(change)
  local name = change.toRoute and change.toRoute.name
  local menu = extensions.ui_menuManager
  if not menu then return end
  if isPhoneRoute(name) then
    previousGameplayRoute = previousGameplayRoute or menu.getGameplayRoute()
    menu.setGameplayRoute(name)
  else
    restoreGameplayRoute()
  end
end

function M.onExtensionUnloaded()
  restoreGameplayRoute()
end

function M.setOpeningBlocked(owner, blocked)
  if owner ~= 'welcome' and owner ~= 'beta' then return false end
  openingBlockers[owner] = blocked == true or nil
  return true
end

function M.onExtensionLoaded()
  isPhoneOpen = false
  isClosing = false
  suppressOpenUntil = 0
  log('I', LOG_TAG, 'Phone extension loaded')
end

-- Both career exits and profile adoption pass through this hook. Use the
-- normal close path while the router and shell are still available.
function M.onOverhaulActive(active)
  if not active then closePhone() end
end

function M.onUIPlayStateChanged(changed)
  if changed then
    isPhoneOpen = false
    isClosing = false
  end
end

M.togglePhone = togglePhone
M.requestState = requestState
M.closePhone = closePhone
M.markClosed = markClosed
M.markOpen = markOpen
M.openRoute = openRoute
M.openForTutorial = openForTutorial
M.isPhoneOpen = function()
  return isPhoneOpen and not isClosing
end
M.isComputerMenuOpen = isComputerMenuOpen
M.isPhoneUiAllowed = isPhoneUiAllowed

return M
