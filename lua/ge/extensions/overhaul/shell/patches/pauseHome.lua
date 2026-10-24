-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Overhaul's pause Home: the career Home rail, main and side panels, built on Overhaul's own modules.
-- Adjusts the stock pause layout after the stock lifecycle fills it, and only in Overhaul's mode.
local capabilities = require('overhaul/lib/platform/capabilities')
local owners = require('overhaul/lib/ui/ownerCatalog')
local optional = require('overhaul/lib/platform/optional')

local M = {}

-- Config ------------------------------------------------------------------------------------------

local CAREER_HIDDEN_TABS = {vehicle = true, environment = true}
local LEADING_GROUPS = {recovery = true, firstDriveLearning = true, tutorialLesson = true}

-- The stock profile overview card lists every row of data.branches; the pause card shows only the best few skills.
local PROFILE_CARD_SKILL_ROWS = 4
M.PROFILE_CARD_SKILL_ROWS = PROFILE_CARD_SKILL_ROWS

-- Helpers -----------------------------------------------------------------------------------------

local function isOverhaulActive()
  -- Vanilla pause can outlive an absent or failed optional game-mode provider.
  local ok, active = pcall(function() return overhaul_shell_gameMode.isActive() end)
  return ok and active == true
end
M.isOverhaulActive = isOverhaulActive

-- Calls module[methodName](...) when the module provides it; nil otherwise.
local function call(module, methodName, ...)
  if type(module) ~= "table" or type(module[methodName]) ~= "function" then return nil end
  return module[methodName](...)
end

local function findAction(group, actionId)
  for index, action in ipairs(group.actions or {}) do
    if action.id == actionId then return index end
  end
end

local function openMainMenuAction(actionId)
  return ui_pause_actions.registerButton({
    id = actionId,
    label = "Main Menu",
    icon = "catalog02",
    flavor = "system",
    routeTarget = "menu",
    visible = true,
    enabled = true,
  }, function() return ui_router.navigate("menu") ~= false end)
end

-- Accepts a plain label, a {label} table, a {context = {label, count}} table, or a {txt} table.
local function actionLabel(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  if type(value) ~= "table" then return fallback end
  if type(value.label) == "string" and value.label ~= "" then return value.label end
  if type(value.context) == "table" and type(value.context.label) == "string" and value.context.label ~= "" then
    if value.context.count ~= nil then
      return string.format("%s (%s)", value.context.label, tostring(value.context.count))
    end
    return value.context.label
  end
  if type(value.txt) == "string" and value.txt ~= "" then return value.txt end
  return fallback
end

local function recoveryTarget(targetType, targetVehId)
  if targetType == "none" then return {type = "none"} end
  if targetType == "walk" then return {type = "walk"} end
  if targetType == "vehicle" and targetVehId then return {type = "vehicle", vehId = targetVehId} end
  local vehicle = getPlayerVehicle and getPlayerVehicle(0)
  if vehicle then return {type = "vehicle", vehId = vehicle:getId()} end
  return {type = "none"}
end

local function progressAvailable()
  return call(overhaul_career_career, "hasBoughtStarterVehicle") and true or false
end

-- Overhaul's home replaces the stock content unless the first-drive guide or the driving-assists digest owns it.
local function homeContentReplaced(context)
  if context.isFirstDriveGuided then return false end
  local home = rawget(_G, "ui_pause_providers_routeData_home")
  return not call(home, "isDrivingAssistsDigestEnabled")
end

-- Career buttons ----------------------------------------------------------------------------------

local function recoveryActions()
  local actions = {}
  local buttons = call(overhaul_ui_recoveryPrompt, "getPauseCareerRightRailButtons") or {}
  for _, button in ipairs(buttons) do
    local id = tostring(button.id or "unknown")
    local targetType, targetVehId = button.targetType, button.targetVehId
    table.insert(actions, ui_pause_actions.registerButton({
      id = "home.career." .. id,
      label = actionLabel(button.title, id),
      icon = button.icon or "recover",
      rail = "home",
      visible = true,
      enabled = button.enabled ~= false,
      disabledReason = button.disableReason,
      confirmText = button.holdToClick,
    }, function()
      overhaul_ui_recoveryPrompt.buttonPressed(id, recoveryTarget(targetType, targetVehId))
      return true
    end))
  end
  return actions
end

-- Skills and milestones only exist once the player has a starter vehicle.
local function appendProgressActions(actions)
  if not progressAvailable() then return end
  local unclaimed = call(capabilities.get("progressIndicators"), "unclaimedMilestonesCount") or 0
  table.insert(actions, ui_pause_actions.registerButton({
    id = "home.careerPaths",
    label = "Skills",
    icon = "cup",
    rail = "home",
    routeTarget = "overhaul.domainSelection",
    showIndicator = unclaimed > 0,
    visible = true,
    enabled = true,
  }, function() return ui_router.navigate("overhaul.domainSelection") ~= false end))
  table.insert(actions, ui_pause_actions.registerButton({
    id = "home.careerMilestones",
    label = _tr("ui.career.milestones.title"),
    icon = "catalog03",
    rail = "home",
    routeTarget = "overhaul.milestones",
    showIndicator = unclaimed > 0,
    visible = true,
    enabled = true,
  }, function() return ui_router.navigate("overhaul.milestones") ~= false end))
end

local function appendSaveActions(actions, saveEnabled)
  table.insert(actions, ui_pause_actions.registerButton({
    id = "home.careerQuicksave",
    label = _tr("ui.career.quicksave"),
    icon = "floppyDisk",
    visible = true,
    enabled = saveEnabled,
  }, function()
    require("overhaul/lib/save/store").request("pauseHome:quicksave", nil, true)
    return true
  end))
  table.insert(actions, ui_pause_actions.registerButton({
    id = "home.careerSaveAs",
    label = _tr("ui.common.save"),
    icon = "saveAs1",
    routeTarget = "overhaul.profiles.saveAs",
    visible = true,
    enabled = saveEnabled,
  }, function() return ui_router.navigate("overhaul.profiles.saveAs") ~= false end))
  table.insert(actions, ui_pause_actions.registerButton({
    id = "home.careerLoad",
    label = _tr("ui.common.load"),
    icon = "folder",
    routeTarget = "overhaul.profiles",
    confirmText = "Are you sure you want to load a different profile? Any unsaved progress will be lost.",
    visible = true,
    enabled = saveEnabled,
  }, function() return ui_router.navigate("overhaul.profiles") ~= false end))
end

local function careerActions()
  local actions = {}
  appendProgressActions(actions)
  appendSaveActions(actions, call(overhaul_career_career, "isAutosaveEnabled") and true or false)
  return actions
end

-- Rail --------------------------------------------------------------------------------------------

-- Each stock rail group owns its adjustment, preserving the incoming group order.
local railGroupHandlers = {
  recovery = function(group)
    for _, action in ipairs(recoveryActions()) do table.insert(group.actions, action) end
  end,
  auxiliary = function(group)
    local replay = findAction(group, "home.replay")
    if replay then table.remove(group.actions, replay) end
  end,
  mainMenu = function(group)
    if findAction(group, "home.openMainMenu") then return end
    table.insert(group.actions, findAction(group, "home.exitToMainMenu") or #group.actions + 1, openMainMenuAction("home.openMainMenu"))
  end,
}

local function applyRailGroupActions(group)
  local apply = railGroupHandlers[group.id]
  if apply then apply(group) end
end

function M.buildRail(rail)
  local groups = {}
  local careerIndex
  for _, group in ipairs(type(rail) == "table" and rail or {}) do
    if not careerIndex and not LEADING_GROUPS[group.id] then careerIndex = #groups + 1 end
    applyRailGroupActions(group)
    if group.id ~= "career" and #(group.actions or {}) > 0 then table.insert(groups, group) end
  end
  local career = careerActions()
  if #career > 0 then
    table.insert(groups, careerIndex or #groups + 1, {id = "career", actions = career})
  end
  return groups
end

function M.buildSystemRail(rail)
  for _, group in ipairs(type(rail) == "table" and rail or {}) do
    if group.id == "exitSystemButtons" and not findAction(group, "system.openMainMenu") then
      table.insert(group.actions, findAction(group, "system.exitToMainMenu") or #group.actions + 1, openMainMenuAction("system.openMainMenu"))
    end
  end
  return rail
end

-- Pause action catalog ----------------------------------------------------------------------------

-- Pause actions are contributed by UI owners. Availability and callbacks resolve live extensions;
-- opening the pause menu neither loads optional features nor retains an unloaded owner.

-- Calls reference.owner[reference.method]() when the owner is loaded; nil otherwise.
local function callActionReference(reference)
  if type(reference) ~= 'table' then return nil end
  local owner = optional(reference.owner)
  if type(owner) ~= 'table' or type(owner[reference.method]) ~= 'function' then return nil end
  return owner[reference.method]()
end

-- Owners are scanned on each open, so the menu follows what is loaded right now.
local function collectDeclarations()
  local declarations = {}
  for _, owner in ipairs(owners.scan().owners) do
    for _, action in ipairs(owner.pauseActions or {}) do declarations[#declarations + 1] = action end
  end
  table.sort(declarations, function(left, right)
    if left.order ~= right.order then return left.order < right.order end
    return left.id < right.id
  end)
  return declarations
end

-- The owner is resolved at click time, so an owner unloaded since the menu opened is a no-op.
local function executeAction(action)
  local reference = action.execute
  local owner = optional(reference.owner)
  if reference.optional and (not owner or type(owner[reference.method]) ~= 'function') then return false end
  owner[reference.method]()
  return true
end

local function buildActionButton(action)
  local button = {}
  for key, value in pairs(action.button) do button[key] = value end
  if action.labelKey then button.label = _tr(action.labelKey) end
  button.callback = function() return executeAction(action) end
  return button
end

local function actionCatalogButtons()
  local buttons = {}
  for _, action in ipairs(collectDeclarations()) do
    if callActionReference(action.available) then buttons[#buttons + 1] = buildActionButton(action) end
  end
  return buttons
end

-- Main, side and tabs -----------------------------------------------------------------------------

local function careerButtons()
  local definitions = actionCatalogButtons()
  local buttons = {}
  for _, definition in ipairs(definitions) do
    local callback = definition.callback
    definition.callback = nil
    definition.visible = true
    definition.enabled = true
    local registered = ui_pause_actions.registerButton(definition, callback)
    if registered and registered.visible ~= false then table.insert(buttons, registered) end
  end
  return buttons
end

function M.buildMain(main)
  local result = {}
  local buttons = careerButtons()
  if #buttons > 0 then
    table.insert(result, {id = "careerButtons", type = "component", componentName = "PausePanelButtons", props = {buttons = buttons}})
  end
  for _, element in ipairs(type(main) == "table" and main or {}) do
    if element.componentName ~= "PauseNearbyVehicles" then table.insert(result, element) end
  end
  return result
end

function M.buildSide()
  return {{{id = "careerProfileOverview", type = "component", componentName = "PauseCareerProfileOverview"}}}
end

-- Keeps the selected tab even when it is hidden, so the pause menu never opens on a missing tab.
function M.filterTabs(topbar)
  if type(topbar) ~= "table" or type(topbar.tabs) ~= "table" then return end
  local selected = topbar.tabs[(tonumber(topbar.selectedTab) or 0) + 1]
  local tabs = {}
  for _, tab in ipairs(topbar.tabs) do
    if tab == selected or not CAREER_HIDDEN_TABS[tab.tabId] then
      table.insert(tabs, tab)
      if tab == selected then topbar.selectedTab = #tabs - 1 end
    end
  end
  topbar.tabs = tabs
end

-- Layout hook -------------------------------------------------------------------------------------

-- Runs after the stock pause lifecycle has filled data.layoutMenu.
function M.adjustLayout(context, toRoute, data, includeContent)
  if not isOverhaulActive() or type(context) ~= "table" or context.mode ~= "overhaul" then return end
  local layout = type(data) == "table" and data.layoutMenu
  if type(layout) ~= "table" then return end
  M.filterTabs(layout.topbar)
  if not toRoute or type(layout.content) ~= "table" then return end
  if toRoute.name == "pause.system" then
    layout.content.rail = M.buildSystemRail(layout.content.rail)
    return
  end
  if toRoute.name ~= "pause" then return end
  if not homeContentReplaced(context) then return end
  layout.content.rail = M.buildRail(layout.content.rail)
  if includeContent then
    layout.content.main = M.buildMain(layout.content.main)
    layout.content.side = M.buildSide()
  end
end

-- Profile card ------------------------------------------------------------------------------------

local function rowProgress(row)
  local needed = tonumber(row.neededForNext) or 0
  if needed <= 0 then return 0 end
  return (tonumber(row.curLvlProgress) or 0) / needed
end

-- The first `limit` rows by level (highest first), then by progress within the level, then by their current order.
-- Returns a new list; the rows themselves are shared and untouched. A list within the limit is returned as is.
function M.topSkillRows(rows, limit)
  limit = limit or PROFILE_CARD_SKILL_ROWS
  if type(rows) ~= "table" or #rows <= limit then return rows end
  local ranked = {}
  for index, row in ipairs(rows) do
    ranked[index] = {row = row, index = index, level = tonumber(row.level) or 0, progress = rowProgress(row)}
  end
  table.sort(ranked, function(left, right)
    if left.level ~= right.level then return left.level > right.level end
    if left.progress ~= right.progress then return left.progress > right.progress end
    return left.index < right.index
  end)
  local top = {}
  for index = 1, limit do top[index] = ranked[index].row end
  return top
end

-- The stock profile overview card asks vanilla career for the current profile.
function M.currentProfileData(career, original, ...)
  local vanillaActive = call(career, "isActive")
  if not vanillaActive and isOverhaulActive() then
    local data = overhaul_career_career.sendCurrentProfileData()
    if type(data) == "table" and type(data.branches) == "table" and #data.branches > PROFILE_CARD_SKILL_ROWS then
      local card = {}
      for key, value in pairs(data) do card[key] = value end
      card.branches = M.topSkillRows(data.branches, PROFILE_CARD_SKILL_ROWS)
      return card
    end
    return data
  end
  return original(...)
end

return M
