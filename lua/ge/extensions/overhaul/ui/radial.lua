-- Radial quick-access menu for Overhaul's career root and recovery actions.
-- Disabling restores the game's root and recovery buttons to their captured state.
local M = {}

local ROOT_ENTRY_ID = "overhaulCareerRoot"
local CAREER_ROOT = "/root/sandbox/career/"

local active = false
local recoverySnapshot

local function isGameModeActive()
  if not overhaul_shell_gameMode or type(overhaul_shell_gameMode.isActive) ~= "function" then return false end
  local ok, modeActive = pcall(overhaul_shell_gameMode.isActive)
  return ok and modeActive == true
end

-- The game titles the radial root by career_career; Overhaul presents its career root the same way.
local function relabelSandboxEntry(entries)
  if not active or not isGameModeActive() then return true end
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and entry.uniqueID == "sandbox" then
      entry.title = "ui.radialmenu2.careerActions"
      entry.icon = "cup"
      entry.desc = "ui.radialmenu2.careerActions.desc"
      entry["goto"] = CAREER_ROOT
      return true
    end
  end
  return false
end

-- quickAccess runs a level's generators in list order and also runs generators they append,
-- so a relabel that runs before the game's root generator queues itself behind it.
local function relabelRoot(entries)
  if not relabelSandboxEntry(entries) then
    table.insert(entries, {generator = relabelSandboxEntry})
  end
end

local function addRootEntry()
  local quickAccess = core_quickAccess
  if not (quickAccess and type(quickAccess.addEntry) == "function") then return false end
  return quickAccess.addEntry({level = "/root/", uniqueID = ROOT_ENTRY_ID, generator = relabelRoot})
end

-- Reads each button's active state; a prompt without readable states yields nil.
local function readRecoveryButtons(prompt)
  if type(prompt.getCustomRecoveryOptionsActiveState) ~= "function" then return nil end
  local ok, options = pcall(prompt.getCustomRecoveryOptionsActiveState)
  if not ok or type(options) ~= "table" or not next(options) then return nil end
  local buttons = {}
  for id, option in pairs(options) do
    if type(option) == "table" and option.active ~= nil then
      buttons[id] = option.active
    end
  end
  return buttons
end

-- Captures the prompt's state once, before the first change, so disable() can put it back.
local function captureRecoveryState(prompt)
  if not recoverySnapshot then
    local wasActive
    if type(prompt.isActive) == "function" then wasActive = prompt.isActive() end
    recoverySnapshot = {active = wasActive, buttons = nil}
  end
  if recoverySnapshot.buttons then return end
  recoverySnapshot.buttons = readRecoveryButtons(prompt)
end

-- Keeps the reset key on the radial (no free reset); overhaul_ui_recoveryPrompt provides the buttons.
local function applyRecoveryPrompt()
  local prompt = core_recoveryPrompt
  if type(prompt) ~= "table" then return false end
  captureRecoveryState(prompt)
  if type(prompt.setActive) == "function" then prompt.setActive(true) end
  if type(prompt.deactivateAllButtons) == "function" then prompt.deactivateAllButtons() end
  return true
end

local function restoreRecoveryPrompt()
  local snapshot = recoverySnapshot
  local prompt = core_recoveryPrompt
  recoverySnapshot = nil
  if not snapshot or not prompt then return end

  if snapshot.active ~= nil and type(prompt.setActive) == "function" then
    prompt.setActive(snapshot.active)
  end
  if snapshot.buttons and type(prompt.setButtonActiveById) == "function" then
    for id, wasActive in pairs(snapshot.buttons) do
      prompt.setButtonActiveById(id, wasActive)
    end
  end
end

local function enable()
  if not isGameModeActive() then return false end
  active = true
  addRootEntry()
  applyRecoveryPrompt()
  return true
end

local function disable()
  active = false
  restoreRecoveryPrompt()
  return true
end

M.enable = enable
M.disable = disable
function M.isActive() return active end

M.onExtensionUnloaded = disable

function M.onOverhaulActive(isActive)
  if isActive and isGameModeActive() then enable() end
end

function M.onRegisterQuickAccessMenus()
  if active then addRootEntry() end
end

function M.onQuickAccessLoaded()
  if active and isGameModeActive() then
    addRootEntry()
    applyRecoveryPrompt()
  end
end

function M.onWorldReadyState(state)
  if active and state == 2 and isGameModeActive() then enable() end
end

return M
