-- Owns saved intro flags, global first-use settings, phone tutorials and the career splash.
-- Read state, UI readiness, bindings, tutorials, splash, lifecycle, wiki text, public API and game hooks in order.
local M = {}

-- Requires ----------------------------------------------------------------------------------------

local ensureDir = require("overhaul/lib/save/ensureDir")
local levelData = require("overhaul/lib/world/levelData")

-- SaveStore keys for the files this module writes (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "guide.save", owner = "overhaul_career_guide_guide", files = {"career/rls_career/guide.json"}, phase = "profile", required = true},
  {key = "guide.global", owner = "overhaul_career_guide_guide", files = {"settings/RLS/guideGlobal.json"}, phase = "immediate", required = false, root = "user"},
})

-- Config ------------------------------------------------------------------------------------------

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/guide.json"
local settingsRoot = "settings/RLS/"
local globalGuideFile = settingsRoot .. "guideGlobal.json"

local VETERAN_PHONE_TUTORIAL_DELAY_S = 3.0
local PHONE_OPEN_DELAY_S = 0.35
local PHONE_TUTORIAL_EVENT_DELAY_S = 0.65
local STOCK_TIP_SETTLE_S = 0.15
-- Bump when the phone tutorial gains steps so old global completions replay.
local PHONE_TUTORIAL_VERSION = 3

-- Stock fade tutorials only persist per save; mirror them globally so new saves do not replay them.
local STOCK_INTRO_TIP_IDS = {
  "delivery/cargoScreen",
  "delivery/parcelDeliveryHelp",
  "delivery/vehicleDeliveryHelp",
  "delivery/trailerDeliveryHelp",
  "delivery/materialsDeliveryHelp",
  "delivery/loanerHelp",
  "delivery/cargoDelivered",
  "delivery/postDeliveryTaxi",
  "delivery/intro",
}

local STOCK_INTRO_TIP_HOOKS = {
  onEnterCargoOverviewScreen = "delivery/cargoScreen",
}

local INTRO_SKIP_FIELDS = {
  demo_dirt = "skipDemoDirtIntro",
}

local CONTROL_SYMBOL_NAMES = {
  backslash = "\\", slash = "/", comma = ",", period = ".",
  semicolon = ";", apostrophe = "'", grave = "`", minus = "-",
  equals = "=", leftbracket = "[", rightbracket = "]"
}

-- State -------------------------------------------------------------------------------------------

local guideShown = false
local perSaveGuideLoaded = false
local phoneTutorialComplete = false
local phoneTutorialVersion = 0
local globalPhoneTutorialComplete = false
local globalPhoneTutorialVersion = 0
local splashVisible = false
local welcomeRequested = false
local skipDemoDirtIntro = false
local phoneTutorialStartScheduled = false
local phoneTutorialStartGeneration = 0
local phoneTutorialLaunchAttempted = false
local returnToOverhaulManagerPending = false
local seenStockIntroTips = {}
local globalSeenStockIntroTips = {}

-- UI readiness ------------------------------------------------------------------------------------

local function getUiRouteName()
  local current = extensions.ui_router.getCurrent()
  if not current then
    return nil
  end
  if current.resolved and type(current.resolved.name) == "string" then
    return current.resolved.name
  end
  if current.request and type(current.request.name) == "string" then
    return current.request.name
  end
  return nil
end

local function isCareerActiveAndNotLoading()
  if not overhaul_career_career.isActive() then
    return false
  end
  if core_gamestate.getLoadingStatus("careerLoading") then return false end
  if core_gamestate.getLoadingStatus("careerActivate") then return false end
  return true
end

local function isPlayRoute()
  local routeName = getUiRouteName()
  return routeName == "play"
end

local function isCareerUiReady()
  if not isCareerActiveAndNotLoading() then
    return false
  end
  if not overhaul_phone_phone.isPhoneUiAllowed() then
    return false
  end
  return isPlayRoute()
end

local function isPhoneTutorialUiReady()
  if not isCareerActiveAndNotLoading() then
    return false
  end
  if not overhaul_phone_phone.isPhoneUiAllowed() then
    return false
  end
  local routeName = getUiRouteName()
  return overhaul_phone_phone.isPhoneRoute(routeName)
end

local function isWelcomeSplashReady()
  if not isCareerActiveAndNotLoading() then
    return false
  end
  local routeName = getUiRouteName()
  if type(routeName) == "string" then
    if routeName == "menu" or routeName:find("^menu%.") == 1 then
      return false
    end
    if routeName:find("^overhaul%.profiles") == 1 then
      return false
    end
  end
  return true
end

local function cancelPhoneTutorialStart()
  phoneTutorialStartScheduled = false
  phoneTutorialStartGeneration = phoneTutorialStartGeneration + 1
end

-- Waits in quarter-second steps while the request is still current and not yet ready.
local function waitWhile(job, isCurrent, isReady, maxWaitS)
  local waited = 0
  while isCurrent() and not isReady() and waited < maxWaitS do
    job.sleep(0.25)
    waited = waited + 0.25
  end
end

-- Tip maps ----------------------------------------------------------------------------------------

local function copySeenTipMap(source)
  local out = {}
  if type(source) ~= "table" then
    return out
  end
  for _, id in ipairs(STOCK_INTRO_TIP_IDS) do
    if source[id] == true then
      out[id] = true
    end
  end
  -- Also accept any extra string keys already stored.
  for key, value in pairs(source) do
    if type(key) == "string" and value == true then
      out[key] = true
    end
  end
  return out
end

local function mergeSeenTipMaps(...)
  local out = {}
  for index = 1, select("#", ...) do
    local map = select(index, ...)
    if type(map) == "table" then
      for key, value in pairs(map) do
        if value == true then
          out[key] = true
        end
      end
    end
  end
  return out
end

local function isTrackedStockIntroTip(id)
  if type(id) ~= "string" or id == "" then
    return false
  end
  for _, tipId in ipairs(STOCK_INTRO_TIP_IDS) do
    if tipId == id then
      return true
    end
  end
  return false
end

-- Global settings ---------------------------------------------------------------------------------

local function ensureGlobalSettingsDir()
  if not FS:directoryExists(settingsRoot) then
    FS:directoryCreate(settingsRoot, true)
  end
end

local function loadGlobalGuideData()
  ensureGlobalSettingsDir()
  local data = jsonReadFile(globalGuideFile) or {}
  globalPhoneTutorialComplete = data.phoneTutorialComplete == true
  globalPhoneTutorialVersion = tonumber(data.phoneTutorialVersion) or 0
  globalSeenStockIntroTips = copySeenTipMap(data.seenStockIntroTips)
end

local function writeGlobalGuideFile(data)
  if require("overhaul/lib/save/store").writeNow(globalGuideFile, data, true) then
    return true
  end
  if jsonWriteFile(globalGuideFile, data, true) then
    return true
  end
  return false
end

local function saveGlobalGuideData()
  ensureGlobalSettingsDir()
  local data = {
    phoneTutorialComplete = globalPhoneTutorialComplete == true,
    phoneTutorialVersion = tonumber(globalPhoneTutorialVersion) or 0,
    seenStockIntroTips = copySeenTipMap(globalSeenStockIntroTips),
  }
  if writeGlobalGuideFile(data) then
    return true
  end
  log("E", "guide", "failed to write global guide data: " .. tostring(globalGuideFile))
  return false
end

local function tutorialVersionIsCurrent(version)
  return (tonumber(version) or 0) >= PHONE_TUTORIAL_VERSION
end

local function promotePerSaveTutorialToGlobal()
  if not tutorialVersionIsCurrent(phoneTutorialVersion) then
    return
  end
  if globalPhoneTutorialComplete and tutorialVersionIsCurrent(globalPhoneTutorialVersion) then
    return
  end
  globalPhoneTutorialComplete = true
  globalPhoneTutorialVersion = PHONE_TUTORIAL_VERSION
  saveGlobalGuideData()
end

local function isPhoneTutorialCompleteGlobally()
  return globalPhoneTutorialComplete == true and tutorialVersionIsCurrent(globalPhoneTutorialVersion)
end

local function isForcePhoneTutorial()
  return overhaul_shell_settings.getSetting("forcePhoneTutorial") == true
end

-- Per-save data -----------------------------------------------------------------------------------

local function readSkipFlagFromData(data, eventKey)
  if type(data) ~= "table" or not eventKey or eventKey == "" then
    return false
  end
  local field = INTRO_SKIP_FIELDS[eventKey]
  if field and data[field] == true then
    return true
  end
  if type(data.demoIntroSkip) == "table" and data.demoIntroSkip[eventKey] == true then
    return true
  end
  return false
end

local function resetPerSaveGuideState()
  guideShown = false
  phoneTutorialComplete = false
  phoneTutorialVersion = 0
  skipDemoDirtIntro = false
  seenStockIntroTips = {}
end

local function loadGuideData()
  if perSaveGuideLoaded and overhaul_career_career.isActive() then
    return
  end
  resetPerSaveGuideState()
  if not overhaul_career_career.isActive() then
    perSaveGuideLoaded = false
    return
  end

  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return
  end

  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  guideShown = data.guideShown == true
  phoneTutorialComplete = data.phoneTutorialComplete == true
  phoneTutorialVersion = tonumber(data.phoneTutorialVersion) or 0
  if phoneTutorialComplete and not tutorialVersionIsCurrent(phoneTutorialVersion) then
    phoneTutorialComplete = false
  end
  skipDemoDirtIntro = readSkipFlagFromData(data, "demo_dirt")
  seenStockIntroTips = copySeenTipMap(data.seenStockIntroTips)
  if phoneTutorialComplete then
    promotePerSaveTutorialToGlobal()
  end
  perSaveGuideLoaded = true
end

local function saveGuideData(currentSavePath, writer)
  if not currentSavePath then
    return false
  end

  ensureDir.directory(writer, currentSavePath .. saveDir)

  local data = {
    guideShown = guideShown,
    phoneTutorialComplete = phoneTutorialComplete == true,
    phoneTutorialVersion = tonumber(phoneTutorialVersion) or 0,
    skipDemoDirtIntro = skipDemoDirtIntro == true,
    seenStockIntroTips = copySeenTipMap(mergeSeenTipMaps(seenStockIntroTips, globalSeenStockIntroTips)),
  }

  if require("overhaul/lib/save/store").writeSlot(currentSavePath .. saveFile, data, true) then
    return true
  end
  log("E", "guide", "failed to write guide save: " .. tostring(currentSavePath .. saveFile))
  return false
end

local function checkGuideShown()
  return guideShown
end

local function markGuideShown()
  guideShown = true
end

local function shouldSkipDemoIntro(eventKey)
  if not eventKey or eventKey == "" then
    return false
  end
  if not INTRO_SKIP_FIELDS[eventKey] then
    return false
  end
  loadGuideData()
  return eventKey == "demo_dirt" and skipDemoDirtIntro == true
end

local function markDemoIntroSkipped(eventKey)
  if not eventKey or eventKey == "" then
    return false
  end
  local field = INTRO_SKIP_FIELDS[eventKey]
  if not field then
    return false
  end

  loadGuideData()
  if eventKey == "demo_dirt" then
    skipDemoDirtIntro = true
  end
  return true
end

-- Stock intro tips --------------------------------------------------------------------------------

local function applyStockIntroTipsToTutorialPopups()
  local tutorialPopups = overhaul_career_guide_tutorialPopups
  local merged = mergeSeenTipMaps(seenStockIntroTips, globalSeenStockIntroTips)
  for id, seen in pairs(merged) do
    if seen == true then
      tutorialPopups.setTutorialFlag(id, true)
    end
  end
end

local function syncSeenTipsFromStockTutorialFlags()
  local tutorialPopups = overhaul_career_guide_tutorialPopups
  local changed = false
  for _, id in ipairs(STOCK_INTRO_TIP_IDS) do
    if tutorialPopups.getTutorialFlag(id) and not seenStockIntroTips[id] then
      seenStockIntroTips[id] = true
      changed = true
    end
    if tutorialPopups.getTutorialFlag(id) and not globalSeenStockIntroTips[id] then
      globalSeenStockIntroTips[id] = true
      changed = true
    end
  end
  return changed
end

local function markStockIntroTipSeen(id)
  if not isTrackedStockIntroTip(id) then
    return false
  end
  local changed = false
  if not seenStockIntroTips[id] then
    seenStockIntroTips[id] = true
    changed = true
  end
  if not globalSeenStockIntroTips[id] then
    globalSeenStockIntroTips[id] = true
    changed = true
  end

  overhaul_career_guide_tutorialPopups.setTutorialFlag(id, true)

  if not changed then
    return false
  end

  saveGlobalGuideData()
  return true
end

local function refreshStockIntroTipSuppression()
  loadGlobalGuideData()
  loadGuideData()
  if syncSeenTipsFromStockTutorialFlags() then
    saveGlobalGuideData()
  end
  applyStockIntroTipsToTutorialPopups()
end

-- Phone binding -----------------------------------------------------------------------------------

local function formatControlName(control, deviceName)
  if not control or control == "" then
    return "Not bound"
  end

  control = tostring(control)

  if deviceName and deviceName:find("mouse") then
    local btnNum = tonumber(control:match("button(%d+)"))
    if btnNum then
      if btnNum == 0 then return "Mouse Left"
      elseif btnNum == 1 then return "Mouse Right"
      elseif btnNum == 2 then return "Mouse Middle"
      else return "Mouse Button " .. (btnNum + 1) end
    end
    return "Mouse " .. control
  end

  if CONTROL_SYMBOL_NAMES[control] then
    return CONTROL_SYMBOL_NAMES[control]
  end
  if control:len() == 1 then
    return control:upper()
  elseif control:match("^f%d+$") then
    return control:upper()
  elseif control == "space" then
    return "Space"
  elseif control == "enter" then
    return "Enter"
  elseif control == "tab" then
    return "Tab"
  elseif control:find("arrow") then
    local direction = control:gsub("arrow", "")
    if direction == "left" then return "Arrow Left"
    elseif direction == "right" then return "Arrow Right"
    elseif direction == "up" then return "Arrow Up"
    elseif direction == "down" then return "Arrow Down"
    else return "Arrow " .. direction:gsub("^%l", string.upper) end
  end

  return control:gsub("^%l", string.upper):gsub("_", " ")
end

local function getPhoneBinding()
  core_input_bindings.notifyUI("guide refresh")

  if core_input_bindings.bindings then
    for _, device in ipairs(core_input_bindings.bindings) do
      if device.contents and device.contents.bindings and type(device.contents.bindings) == "table" then
        for _, binding in ipairs(device.contents.bindings) do
          if binding.action == "openPhone" and binding.control and binding.control ~= "" then
            return {binding = formatControlName(binding.control, device.devname)}
          end
        end
      end
    end
  end

  return {binding = "Not bound"}
end

local function setBindingCapture(enabled)
  ActionMap.enableBindingCapturing(enabled == true)
  setCEFTyping(enabled == true)
  -- The raw-input backend depends on the platform; some platforms expose neither backend.
  local input = rawget(_G, "Input") or rawget(_G, "WinInput")
  if input and input.setForwardRawEvents then
    input.setForwardRawEvents(enabled == true)
  end
end

local function findBindingDevice(deviceName)
  if type(core_input_bindings.bindings) ~= "table" then
    return nil
  end
  deviceName = tostring(deviceName or "keyboard0")
  local fallback = nil
  local wantKeyboard = deviceName:find("keyboard", 1, true) ~= nil
  local wantMouse = deviceName:find("mouse", 1, true) ~= nil
  for _, device in ipairs(core_input_bindings.bindings) do
    local name = tostring(device and device.devname or "")
    if name == deviceName then
      return device
    end
    if not fallback and device and device.contents then
      if wantKeyboard and name:find("keyboard", 1, true) then
        fallback = device
      elseif wantMouse and name:find("mouse", 1, true) then
        fallback = device
      end
    end
  end
  return fallback
end

local function hasOpenPhoneAction()
  local activeActions = core_input_actions.getActiveActions()
  if activeActions and activeActions.openPhone then
    return true
  end
  return false
end

-- Registers the openPhone action first when the input map has not got it yet.
local function openPhoneActionAvailable()
  if hasOpenPhoneAction() then
    return true
  end
  overhaul_shell_extensionManager.ensureInputActionsRegistered()
  return hasOpenPhoneAction()
end

-- Replaces every openPhone binding on the device with one for the new control.
local function replacePhoneBindingOnDevice(deviceContents, controlString)
  if type(deviceContents.bindings) ~= "table" then
    deviceContents.bindings = {}
  end

  local bindings = deviceContents.bindings
  for index = #bindings, 1, -1 do
    if bindings[index].action == "openPhone" then
      table.remove(bindings, index)
    end
  end

  local newBinding = {
    action = "openPhone",
    control = controlString,
    player = 0,
  }
  local bindingTemplate = core_input_bindings.bindingTemplate
  if type(bindingTemplate) == "table" then
    for key, value in pairs(bindingTemplate) do
      if newBinding[key] == nil then
        newBinding[key] = value
      end
    end
  end
  table.insert(bindings, newBinding)
end

local function setPhoneBinding(controlString, deviceName)
  if not controlString or controlString == "" then
    return {success = false, binding = "Not bound"}
  end

  if not openPhoneActionAvailable() then
    log("E", "guide", "Cannot bind phone because the openPhone input action is unavailable")
    return {success = false, binding = "Not bound"}
  end

  if not deviceName or deviceName == "" then
    deviceName = "keyboard0"
  end

  local targetDevice = findBindingDevice(deviceName)
  if not targetDevice or not targetDevice.contents then
    log("E", "guide", "Could not find device: " .. tostring(deviceName))
    return {success = false, binding = "Not bound"}
  end

  local deviceContents = targetDevice.contents
  replacePhoneBindingOnDevice(deviceContents, controlString)

  local saved = pcall(function()
    core_input_bindings.saveBindingsToDisk(deviceContents)
  end)

  if not saved then
    log("E", "guide", "Failed to save phone binding to disk")
  end

  local bindingName = formatControlName(controlString, targetDevice.devname or deviceName)
  return {success = saved, binding = bindingName}
end

-- Phone tutorial ----------------------------------------------------------------------------------

local function returnToOverhaulManagerIfNeeded()
  if not returnToOverhaulManagerPending then
    return
  end
  returnToOverhaulManagerPending = false
  overhaul_phone_phone.markClosed()
  extensions.ui_router.navigate('menu.overhaulManager')
end

-- True when the tutorial is done for good and this start is not a forced replay.
local function phoneTutorialSkippedForCompletion(forceTutorial)
  return isPhoneTutorialCompleteGlobally() and not (isForcePhoneTutorial() or forceTutorial)
end

local function finishPhoneTutorialAttempt(warning)
  phoneTutorialStartScheduled = false
  if warning then
    log("W", "guide", warning)
  end
end

local function runPhoneTutorialStart(job, startGeneration, forceTutorial, initialDelay)
  local function isCurrent()
    return startGeneration == phoneTutorialStartGeneration
  end

  job.sleep(initialDelay)
  waitWhile(job, isCurrent, isCareerUiReady, 30)
  if not isCurrent() then
    return
  end
  if phoneTutorialSkippedForCompletion(forceTutorial) then
    finishPhoneTutorialAttempt()
    return
  end
  if not isCareerUiReady() then
    finishPhoneTutorialAttempt("Skipped phone tutorial start; career UI was not ready")
    return
  end
  if not overhaul_phone_phone.openForTutorial() then
    finishPhoneTutorialAttempt("Skipped phone tutorial start; phone UI refused to open")
    return
  end
  if overhaul_phone_apps_layout then
    overhaul_phone_apps_layout.ensureDefaultAppsPlaced()
  end

  job.sleep(PHONE_TUTORIAL_EVENT_DELAY_S)
  if not isCurrent() then
    overhaul_phone_phone.closePhone()
    return
  end
  if phoneTutorialSkippedForCompletion(forceTutorial) then
    finishPhoneTutorialAttempt()
    overhaul_phone_phone.closePhone()
    return
  end

  waitWhile(job, isCurrent, isPhoneTutorialUiReady, 8)
  if not isCurrent() then
    -- A newer start owns the scheduled flag now, so this stale job must not clear it.
    overhaul_phone_phone.closePhone()
    return
  end
  if not isPhoneTutorialUiReady() then
    finishPhoneTutorialAttempt()
    overhaul_phone_phone.closePhone()
    return
  end

  phoneTutorialLaunchAttempted = true
  local bindingInfo = getPhoneBinding()
  guihooks.trigger('PhoneTutorialStart', {
    binding = bindingInfo and bindingInfo.binding or 'Not bound',
  })
  phoneTutorialStartScheduled = false
end

local function startPhoneTutorialIfNeeded(opts)
  opts = opts or {}
  loadGlobalGuideData()
  loadGuideData()

  local forceTutorial = isForcePhoneTutorial() or opts.force == true
  if isPhoneTutorialCompleteGlobally() and not forceTutorial then
    return
  end
  -- One auto-launch attempt per session. Failed opens must not retry later mid-gameplay.
  if phoneTutorialLaunchAttempted and not forceTutorial then
    return
  end
  if phoneTutorialStartScheduled then
    return
  end

  phoneTutorialStartScheduled = true
  phoneTutorialStartGeneration = phoneTutorialStartGeneration + 1
  local startGeneration = phoneTutorialStartGeneration
  local initialDelay = tonumber(opts.initialDelay) or PHONE_OPEN_DELAY_S

  core_jobsystem.create(function(job)
    runPhoneTutorialStart(job, startGeneration, forceTutorial, initialDelay)
  end)
end

-- Splash ------------------------------------------------------------------------------------------

local function showSplashIfNeeded()
  refreshStockIntroTipSuppression()
  welcomeRequested = true
  if checkGuideShown() then
    startPhoneTutorialIfNeeded({ initialDelay = VETERAN_PHONE_TUTORIAL_DELAY_S })
  else
    splashVisible = true
  end
  overhaul_career_guide_betaWelcome.requestSplash(false)
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onCareerActivated()
  cancelPhoneTutorialStart()
  phoneTutorialLaunchAttempted = false
  welcomeRequested = false
  refreshStockIntroTipSuppression()
end

local function onCareerDeactivated()
  cancelPhoneTutorialStart()
  welcomeRequested = false
  if splashVisible then
    splashVisible = false
  end
end

-- Local wiki content ------------------------------------------------------------------------------

-- Read the same level text as the racing computer, without building its UI or advancing goals.
local function guideRacingText(levelId)
  local racingTeam = overhaul_career_business_racingTeam_racingTeam
  return racingTeam and racingTeam.getLevelInfo(levelId) or {}
end

local function guideList(value)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key > #value or key % 1 ~= 0 then return false end
  end
  return true
end

local function guideReference(value)
  return type(value) == 'table' and type(value.type) == 'string' and value.type ~= ''
    and type(value.id) == 'string' and value.id ~= ''
end

local function guideFacilityTokens(tokens, prefix, reference)
  if not reference then return end
  local facilities = overhaul_world_facilities
  local facility = facilities and facilities.getFacilityIfExists(reference.type, reference.id)
  if not facility then return end
  tokens[prefix .. '.name'] = facility.name
  tokens[prefix .. '.description'] = facility.description
end

local function guideTopicTokens(topic, map, racing)
  local tokens = {['map.label'] = map and map.label}
  guideFacilityTokens(tokens, 'facility', topic.facility)
  for name, reference in pairs(topic.references or {}) do
    guideFacilityTokens(tokens, 'references.' .. name, reference)
  end
  for id, name in pairs(racing.leagueDisplayNames or {}) do tokens['league.' .. id] = name end
  for key, value in pairs(racing) do
    if type(value) == 'string' then tokens['racing.' .. key] = value end
  end
  return tokens
end

-- Omit a field with an unresolved reference so the neutral global field remains visible.
local function projectGuideText(value, tokens)
  local missing = false
  local text = value:gsub('{([%w_.-]+)}', function(key)
    if type(tokens[key]) == 'string' and tokens[key] ~= '' then return tokens[key] end
    missing = true
    return ''
  end)
  return not missing and text or nil
end

local function projectGuideRecord(record, tokens, fields)
  local out = {id = record.id}
  for _, key in ipairs(fields) do
    local value = record[key]
    if type(value) == 'string' and key ~= 'body' and key ~= 'steps' then
      out[key] = projectGuideText(value, tokens)
    elseif guideList(value) and (key == 'body' or key == 'steps') then
      local lines = {}
      for _, line in ipairs(value) do
        if type(line) ~= 'string' then return nil end
        local text = projectGuideText(line, tokens)
        if not text then break end
        lines[#lines + 1] = text
      end
      if #lines == #value then out[key] = lines end
    elseif value ~= nil then
      return nil
    end
    if value ~= nil and out[key] == nil then
      log('W', 'guide', 'Unavailable local guide field: ' .. record.id .. '.' .. key)
    end
  end
  return out
end

local function projectLocalGuide(data, map, racing)
  local topics, ids = {}, {}
  for _, topic in ipairs(data.topics) do
    if type(topic) ~= 'table' or type(topic.id) ~= 'string' or topic.id == '' or ids[topic.id]
      or (topic.sections ~= nil and not guideList(topic.sections))
      or (topic.facility ~= nil and not guideReference(topic.facility))
      or (topic.references ~= nil and type(topic.references) ~= 'table') then return nil end
    for key, reference in pairs(topic.references or {}) do
      if type(key) ~= 'string' or not key:match('^[%w_-]+$') or not guideReference(reference) then return nil end
    end
    ids[topic.id] = true
    local tokens = guideTopicTokens(topic, map, racing)
    local projected = projectGuideRecord(topic, tokens, {'title', 'description', 'category', 'iconKey', 'relatedAppId'})
    if not projected then return nil end
    projected.sections = {}
    local sectionIds = {}
    for _, section in ipairs(topic.sections or {}) do
      if type(section) ~= 'table' or type(section.id) ~= 'string' or section.id == '' or sectionIds[section.id] then return nil end
      sectionIds[section.id] = true
      local item = projectGuideRecord(section, tokens, {'title', 'body', 'steps'})
      if not item then return nil end
      projected.sections[#projected.sections + 1] = item
    end
    topics[#topics + 1] = projected
  end
  return topics
end

-- Public API: splash and tutorial -----------------------------------------------------------------

function M.getIntroState()
  loadGuideData()
  return {welcome = not checkGuideShown(), ready = isWelcomeSplashReady(),
    allowed = checkGuideShown() or welcomeRequested}
end

function M.resyncSplash()
  return overhaul_career_guide_betaWelcome.resync()
end

M.showSplashIfNeeded = showSplashIfNeeded

function M.isPhoneTutorialComplete()
  loadGlobalGuideData()
  return isPhoneTutorialCompleteGlobally()
end

function M.markPhoneTutorialComplete()
  cancelPhoneTutorialStart()
  if isForcePhoneTutorial() then
    returnToOverhaulManagerIfNeeded()
    return true
  end
  phoneTutorialComplete = true
  phoneTutorialVersion = PHONE_TUTORIAL_VERSION
  globalPhoneTutorialComplete = true
  globalPhoneTutorialVersion = PHONE_TUTORIAL_VERSION
  local saved = saveGlobalGuideData()
  returnToOverhaulManagerIfNeeded()
  return saved
end

function M.forceStartPhoneTutorial()
  if not overhaul_shell_extensionManager.isDevKeyValid() then
    return false
  end
  cancelPhoneTutorialStart()
  phoneTutorialLaunchAttempted = false
  returnToOverhaulManagerPending = true
  startPhoneTutorialIfNeeded({
    initialDelay = PHONE_OPEN_DELAY_S,
    force = true,
  })
  return true
end

function M.onContinue()
  if splashVisible then
    splashVisible = false
    markGuideShown()
    startPhoneTutorialIfNeeded()
  end
end

function M.beginPhoneRebind()
  overhaul_shell_extensionManager.ensureInputActionsRegistered()
  setBindingCapture(true)
  return true
end

function M.endPhoneRebind()
  setBindingCapture(false)
  return true
end

-- Optional per-level prose is freshly read on wiki entry; changing maps cannot reuse another map's text.
function M.getLocalGuideOverrides()
  local levelId = levelData.currentMapKey()
  local result = {mapId = levelId, topics = {}}
  if not levelId then return result end
  local file = levelData.assetPath(levelId, 'overhaul/guide.json')
  if not FS:fileExists(file) then return result end
  local data = jsonReadFile(file)
  if type(data) == 'table' and data.version == 1 and guideList(data.topics) then
    local topics = projectLocalGuide(data, levelData.getMap(levelId), guideRacingText(levelId))
    if topics then result.topics = topics; return result end
  end
  log('W', 'guide', 'Ignoring invalid local guide: ' .. file)
  return result
end

-- Public API: lifecycle and intro tips ------------------------------------------------------------

M.cancelPhoneTutorialStart = cancelPhoneTutorialStart
M.getPhoneBinding = getPhoneBinding
M.setPhoneBinding = setPhoneBinding
M.shouldSkipDemoIntro = shouldSkipDemoIntro
M.markDemoIntroSkipped = markDemoIntroSkipped
M.markStockIntroTipSeen = markStockIntroTipSeen

M.onCareerActivated = onCareerActivated
M.onOverhaulModulesActivated = onCareerActivated

M.onCareerDeactivated = onCareerDeactivated
M.onCareerDeactivatedWhileLevelLoaded = onCareerDeactivated

-- Career modules unload before deactivation hooks can fire.
function M.onExtensionUnloaded()
  perSaveGuideLoaded = false
  onCareerDeactivated()
end

-- After stock shows or closes a tip, mirror it into the RLS guide and global data so new saves skip it.
function M.onIntroPopupCareerClosed(id)
  markStockIntroTipSeen(id)
end

-- Game hooks --------------------------------------------------------------------------------------

-- career.lua asks for the splash here: the first intro only requests it, the later job also shows it when needed.
function M.onOverhaulCareerSplashRequested(showIfNeeded)
  overhaul_career_guide_betaWelcome.requestSplash(false)
  if showIfNeeded then
    M.showSplashIfNeeded()
  end
end

function M.onWorldReadyState(state)
  if state ~= 2 then
    return
  end
  overhaul_career_guide_betaWelcome.requestSplash(false)
end

function M.onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not currentSavePath then
    return
  end
  local success, err = pcall(function()
    loadGuideData()
    saveGuideData(currentSavePath, writer)
  end)
  if not success then
    log("E", "guide", "onOverhaulSaveCurrentProfile failed: " .. tostring(err))
  end
end

function M.onRecordingActionDown() end

-- Stock hooks that open a tip: the tip is marked seen after stock has had a moment to set its own flag.
for hookName, tipId in pairs(STOCK_INTRO_TIP_HOOKS) do
  M[hookName] = function()
    core_jobsystem.create(function(job)
      job.sleep(STOCK_TIP_SETTLE_S)
      -- Reload or unload ends this owner's delayed stock-tip probe.
      if overhaul_career_guide_guide ~= M then return end
      if overhaul_career_guide_tutorialPopups.getTutorialFlag(tipId) then
        markStockIntroTipSeen(tipId)
      end
    end)
  end
end

return M
