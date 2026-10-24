-- Career pause tabs (Skills, History) registered into the pause menu while Overhaul's game mode runs.
-- enable() rolls back a partial registration; disable() removes only the tabs this file added.
local M = {}

M.dependencies = {"ui_pause_actions"}

local UI_ROOT = "/ui/ui-vue/mods/rls_career_overhaul/"
local ACTION_CARD = UI_ROOT .. "OverhaulActionCard.vue"
local PAUSE_CARD_DIR = UI_ROOT .. "overhaul/modules/pause/"

local function navigateAction(route)
  return 'if overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() then ui_router.navigate("' .. route .. '") end'
end

-- Labels are translated on each enable, so the tabs follow the current language.
local function careerTabs()
  local milestones = _tr("ui.career.milestones.title")
  local logbook = _tr("ui.career.logbook.subHeading")
  return {
    {id = "progress", label = "Skills", icon = "cup", buttons = {
      {id = "overhaul.progress.paths", label = "Skills", icon = "cup",
        componentName = PAUSE_CARD_DIR .. "OverhaulProgressDigest.vue",
        card2ComponentName = PAUSE_CARD_DIR .. "OverhaulProgressDomainInfo.vue"},
    }},
    {id = "history", label = _tr("ui.pause.career.history"), icon = "listBig", buttons = {
      {id = "overhaul.history.financial", label = _tr("ui.pause.career.financialHistory"), icon = "banknotes",
        componentName = PAUSE_CARD_DIR .. "OverhaulFinancialHistory.vue"},
      {id = "overhaul.history.gameplay", label = _tr("ui.pause.career.gameplayHistory"), icon = "chartBars",
        componentName = PAUSE_CARD_DIR .. "OverhaulHistory.vue"},
      {id = "overhaul.history.milestones", label = milestones, icon = "catalog03", componentName = ACTION_CARD,
        props = {title = milestones, description = "", actionLabel = milestones, action = navigateAction("overhaul.milestones")},
        card2ComponentName = PAUSE_CARD_DIR .. "OverhaulMilestoneDigest.vue"},
      {id = "overhaul.history.logbook", label = logbook, icon = "listBig", componentName = ACTION_CARD,
        props = {title = logbook, description = "", actionLabel = logbook, action = navigateAction("overhaul.logbook")}},
    }},
  }
end

-- Tab ids this file registered, so disable() removes exactly those.
local registered = {}

local function isActive()
  if not overhaul_shell_gameMode or type(overhaul_shell_gameMode.isActive) ~= "function" then return false end
  local ok, active = pcall(overhaul_shell_gameMode.isActive)
  return ok and active == true
end

local function callActions(method, value)
  if not ui_pause_actions or type(ui_pause_actions[method]) ~= "function" then return false end
  local ok, result = pcall(ui_pause_actions[method], value)
  return ok and type(result) == "table" and result.success == true
end

local function pauseActionsReady()
  return ui_pause_actions and type(ui_pause_actions.registerModTab) == "function"
    and type(ui_pause_actions.registerModButton) == "function"
    and type(ui_pause_actions.unregisterModTab) == "function"
end

local function isRegistered(id)
  for _, registeredId in ipairs(registered) do
    if registeredId == id then return true end
  end
  return false
end

local function disable()
  for index = #registered, 1, -1 do
    if not callActions("unregisterModTab", registered[index]) then return false end
    table.remove(registered, index)
  end
  return true
end

local function registerTab(tab)
  if not callActions("registerModTab", {id = tab.id, label = tab.label, icon = tab.icon}) then return false end
  if not isRegistered(tab.id) then table.insert(registered, tab.id) end
  for _, button in ipairs(tab.buttons) do
    button.tabId = tab.id
    if not callActions("registerModButton", button) then return false end
  end
  return true
end

local function enable()
  if not isActive() then
    disable()
    return false
  end
  if not pauseActionsReady() then return false end
  for _, tab in ipairs(careerTabs()) do
    if not registerTab(tab) then
      disable()
      return false
    end
  end
  return true
end

M.enable = enable
M.disable = disable

M.onExtensionUnloaded = disable

return M
