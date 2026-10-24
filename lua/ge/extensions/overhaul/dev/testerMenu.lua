-- Creator/tester overlay (F9 by default): money, skill XP, vehicle presets, weather, time, map switcher and repairs.
-- Not auto-loaded by career; it mounts its own input action and only works while the creator key is valid.
local M = {}
local optional = require('overhaul/lib/platform/optional')

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "rlsTesterMenu"
local SETTINGS_PATH = 'settings/inputmaps/overhaul/testerMenu.json'
local LEGACY_SETTINGS_PATH = 'settings/RLS/testerMenu.json'
local MIGRATION_MARKER = 'settings/inputmaps/overhaul/testerMenuMigrated.json'
local ACTION_NAME = "rlsTesterMenuToggle"
local ACTION_FILE = "/gameplay/overhaul/dev/rlsTesterMenu.actions.json"
local DEFAULT_TOGGLE_CONTROL = "f9"
local DEFAULT_DEVICE_NAME = "keyboard0"
local KEYBOARD_DEVICE_NAME = "keyboard0"
local KEY_CHECK_INTERVAL_SECONDS = 1
local CONTROL_MAX_LENGTH = 64
local INPUT_ACTION_TABLE_FIELDS = { "uniqueActions", "normalActions", "activeActions", "actions" }

-- The tester action and its shortcut live in the mod's temp folder, mounted while the menu is loaded.
local OVERLAY_ROOT = '/settings/inputmaps/overhaul/testerInput/'
local OVERLAY_ACTIONS = "lua/ge/extensions/core/input/actions/rls_tester_menu.json"
local OVERLAY_INPUTMAPS = "settings/inputmaps/"
local OVERLAY_INPUTMAP_SUFFIX = "_rls_tester_menu.json"

local CONTROL_SYMBOLS = {
  backslash = "\\", slash = "/", comma = ",", period = ".",
  semicolon = ";", apostrophe = "'", grave = "`", minus = "-",
  equals = "=", leftbracket = "[", rightbracket = "]",
}
local CONTROL_NAMES = { space = "Space", enter = "Enter", ["return"] = "Enter", tab = "Tab" }

local SPAWN_PRESETS = {
  { id = "drift", label = "Drift", model = "fullsize", config = "custom2" },
  { id = "race", label = "Race", model = "vivace", config = "adente_race" },
  { id = "rally", label = "Rally", model = "vivace", config = "gravel_SQ" },
  { id = "work", label = "Work Truck", model = "md_series", config = "info_md_career_shuffleboard_flatbed" },
}

-- Sleep targets on BeamNG's time-of-day scale: 0 = noon, 0.5 = midnight.
local SLEEP_PRESETS = {
  { label = "6am", time = 0.75 },
  { label = "12pm", time = 0 },
  { label = "9pm", time = 0.375 },
  { label = "12am", time = 0.5 },
}

-- State -------------------------------------------------------------------------------------------

local menuVisible = false
local keyOk = false
local lastKeyCheck = -1e9
local statusText = ""
local statusIsError = false
local toggleControl = DEFAULT_TOGGLE_CONTROL
local bindDeviceName = DEFAULT_DEVICE_NAME
local rebindArmed = false

-- Shortcut preference persistence ------------------------------------------------------------------

-- A durable marker prevents removed preferences from resurrecting an old copy.
local function migrateBindSettings()
  if FS:fileExists(MIGRATION_MARKER) then return true end
  local hasCurrent = FS:fileExists(SETTINGS_PATH)
  local hasLegacy = FS:fileExists(LEGACY_SETTINGS_PATH)
  if not hasCurrent and not hasLegacy then return true end
  FS:directoryCreate('settings/inputmaps/overhaul/', true)
  if not hasCurrent and FS:copyFile(LEGACY_SETTINGS_PATH, SETTINGS_PATH) ~= 0 then return false end
  return jsonWriteFile(MIGRATION_MARKER, {completed = true}, true) == true
end

local function saveBindSettings()
  local payload = { toggleControl = toggleControl, deviceName = bindDeviceName }
  FS:directoryCreate(SETTINGS_PATH:match("^(.*)/[^/]+$"), true)
  if overhaul_career_saveSystem and overhaul_career_saveSystem.jsonWriteFileSafe then
    overhaul_career_saveSystem.jsonWriteFileSafe(SETTINGS_PATH, payload, true)
  else
    jsonWriteFile(SETTINGS_PATH, payload, true)
  end
end

-- Helpers -----------------------------------------------------------------------------------------

local function toast(kind, msg)
  statusText = msg or ""
  statusIsError = kind == "error"
  guihooks.trigger("toastrMsg", {
    type = kind == "error" and "error" or "info",
    title = "RLS Tester",
    msg = msg,
  })
  log(kind == "error" and "W" or "I", LOG_TAG, msg or "")
end

-- The creator key is checked at most once a second unless forced.
local function refreshCreatorKey(force)
  local now = os.clock()
  if not force and (now - lastKeyCheck) < KEY_CHECK_INTERVAL_SECONDS then return keyOk end
  lastKeyCheck = now
  keyOk = overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid
    and overhaul_shell_extensionManager.isDevKeyValid() == true
  return keyOk
end

local function careerActive()
  return overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive()
end

local function requireCareer()
  if careerActive() then return true end
  toast("error", "Start or resume a career first.")
  return false
end

-- Control labels ----------------------------------------------------------------------------------

-- Accepts a single key name; anything that could break a binding file is refused.
local function sanitizeControl(value)
  local control = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if control == "" then return nil end
  if #control > CONTROL_MAX_LENGTH then return nil end
  if control:find("[%c\"']") then return nil end
  return control:lower()
end

local function formatMouseLabel(control)
  local buttonNumber = tonumber(control:match("button(%d+)"))
  if buttonNumber == 0 then return "Mouse Left" end
  if buttonNumber == 1 then return "Mouse Right" end
  if buttonNumber == 2 then return "Mouse Middle" end
  if buttonNumber then return "Mouse Button " .. (buttonNumber + 1) end
  return "Mouse " .. control
end

local function formatControlLabel(control, deviceName)
  control = tostring(control or "")
  if control == "" then return "unbound" end
  if tostring(deviceName or ""):find("mouse", 1, true) then return formatMouseLabel(control) end
  if CONTROL_SYMBOLS[control] then return CONTROL_SYMBOLS[control] end
  if control:match("^f%d+$") then return control:upper() end
  if CONTROL_NAMES[control] then return CONTROL_NAMES[control] end
  if control:len() == 1 then return control:upper() end
  return control:gsub("^%l", string.upper):gsub("_", " ")
end

-- Input devices and live bindings -----------------------------------------------------------------

local function inputBindingDevices()
  return core_input_bindings.bindings
end

local function findKeyboardDevice()
  local fallback = nil
  for _, device in ipairs(inputBindingDevices() or {}) do
    local name = tostring(device.devname or ""):lower()
    if name == KEYBOARD_DEVICE_NAME then return device end
    if not fallback and name:find("keyboard", 1, true) then fallback = device end
  end
  return fallback
end

-- A named device is looked up exactly; without a name the keyboard stands in.
local function findDevice(deviceName)
  local devices = inputBindingDevices()
  if not devices then return nil end
  if type(deviceName) == "string" and deviceName ~= "" then
    for _, device in ipairs(devices) do
      if device.devname == deviceName then return device end
    end
    return nil
  end
  return findKeyboardDevice()
end

-- Every device that binds the tester action, with its sanitized control.
local function testerActionBindings()
  local found = {}
  for _, device in ipairs(inputBindingDevices() or {}) do
    if device and device.contents and type(device.contents.bindings) == "table" then
      for _, binding in ipairs(device.contents.bindings) do
        local control = binding.action == ACTION_NAME and sanitizeControl(binding.control)
        if control then found[#found + 1] = { control = control, deviceName = device.devname } end
      end
    end
  end
  return found
end

-- With several bindings the mouse wins, then the device already in use, then the first one found.
local function readLiveBinding()
  local found = testerActionBindings()
  if #found == 0 then return nil end
  if #found > 1 then
    for _, row in ipairs(found) do
      if tostring(row.deviceName or ""):lower():find("mouse", 1, true) then return row end
    end
  end
  for _, row in ipairs(found) do
    if row.deviceName == bindDeviceName then return row end
  end
  return found[1]
end

local function refreshFromLive()
  local live = readLiveBinding()
  if not live then return false end
  toggleControl = live.control
  if type(live.deviceName) == "string" and live.deviceName ~= "" then bindDeviceName = live.deviceName end
  return true
end

local function setBindingCapture(enabled)
  local on = enabled == true
  ActionMap.enableBindingCapturing(on)
  setCEFTyping(on)
  WinInput.setForwardRawEvents(on)
end

-- Shortcut preference loading ----------------------------------------------------------------------

-- The live binding wins over the saved file, which only holds the last choice.
local function loadBindSettings()
  if not migrateBindSettings() then
    log('W', logTag, 'Could not migrate tester shortcut preferences; will retry on next load')
    return false
  end
  local raw = jsonReadFile(SETTINGS_PATH)
  if type(raw and raw.deviceName) == "string" and raw.deviceName ~= "" then
    bindDeviceName = raw.deviceName
  end
  if refreshFromLive() then return true end
  local fromFile = sanitizeControl(raw and raw.toggleControl)
  toggleControl = fromFile or DEFAULT_TOGGLE_CONTROL
  return true
end

-- Overlay -----------------------------------------------------------------------------------------

local function writeOverlay(rel, data)
  local path = OVERLAY_ROOT .. rel
  FS:directoryCreate(path:match("^(.*)/[^/]+$"), true)
  return jsonWriteFile(path, data, true) == true
end

local function mountOverlay()
  if FS:isMounted(OVERLAY_ROOT) then return true end
  return FS:mountList({ { srcPath = OVERLAY_ROOT } }) and true or false
end

local function removeOverlay()
  if FS:isMounted(OVERLAY_ROOT) then FS:unmount(OVERLAY_ROOT) end
  if not FS:directoryExists(OVERLAY_ROOT) then return false end
  for _, file in ipairs(FS:findFiles(OVERLAY_ROOT, "*", -1, true, false) or {}) do FS:removeFile(file) end
  local dirs = FS:findFiles(OVERLAY_ROOT, "*", -1, false, true) or {}
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, dir in ipairs(dirs) do FS:directoryRemove(dir) end
  FS:directoryRemove(OVERLAY_ROOT)
  return true
end

-- Adds the tester action to every action table the input system keeps, so it works without a restart.
local function injectTesterAction(def)
  if type(def) ~= "table" then return end
  local actions = core_input_actions.getActiveActions()
  for name, data in pairs(def) do
    actions[name] = data
    for _, field in ipairs(INPUT_ACTION_TABLE_FIELDS) do
      local inputTable = core_input_actions[field]
      if type(inputTable) == "table" then inputTable[name] = data end
    end
  end
end

-- Mounts the overlay and registers the action; returns true once the input system knows it.
local function registerTesterAction()
  if core_input_actions.getActiveActions()[ACTION_NAME] ~= nil and FS:isMounted(OVERLAY_ROOT) then return true end

  local def = jsonReadFile(ACTION_FILE)
  if type(def) ~= "table" then
    log("E", LOG_TAG, "Missing tester action definition at " .. tostring(ACTION_FILE))
    return false
  end

  local wrote = writeOverlay(OVERLAY_ACTIONS, def) and mountOverlay()
  if wrote then core_input_actions.onFileChanged("/" .. OVERLAY_ACTIONS) end

  injectTesterAction(def)

  local registered = core_input_actions.getActiveActions()[ACTION_NAME]
  if registered then
    core_input_bindings.onFileChanged("/settings/inputmaps/mouse.diff")
    core_input_bindings.onFileChanged("/settings/inputmaps/keyboard.diff")
  end
  return registered ~= nil
end

-- True only when exactly one binding exists and it is this control on this device.
local function isBoundAsWanted(control, deviceName)
  local matches, total = 0, 0
  for _, device in ipairs(inputBindingDevices() or {}) do
    local contents = device and device.contents
    if contents and type(contents.bindings) == "table" then
      for _, binding in ipairs(contents.bindings) do
        if binding.action == ACTION_NAME then
          total = total + 1
          if device.devname == deviceName and sanitizeControl(binding.control) == control then
            matches = matches + 1
          end
        end
      end
    end
  end
  return total == 1 and matches == 1
end

-- A default inputmap in the overlay, so the player's own binding files are never written.
local function writeShortcutInputMap(deviceType, control)
  for _, file in ipairs(FS:findFiles(OVERLAY_ROOT .. OVERLAY_INPUTMAPS, "*" .. OVERLAY_INPUTMAP_SUFFIX, 0, true, false) or {}) do
    FS:removeFile(file)
  end
  local rel = OVERLAY_INPUTMAPS .. deviceType .. OVERLAY_INPUTMAP_SUFFIX
  if not writeOverlay(rel, { bindings = { { control = control, action = ACTION_NAME } } }) or not mountOverlay() then
    log("W", LOG_TAG, "Could not write the tester shortcut")
    return false
  end
  core_input_bindings.onFileChanged("/" .. rel)
  return true
end

-- Binds the shortcut on the device, unless it is already bound as wanted and force is off.
local function applyToggleBind(deviceName, force)
  if not keyOk then return false end
  if not registerTesterAction() then
    log("D", LOG_TAG, "Tester input action is not registered")
    return false
  end

  local control = sanitizeControl(toggleControl) or DEFAULT_TOGGLE_CONTROL
  toggleControl = control
  if type(deviceName) == "string" and deviceName ~= "" then bindDeviceName = deviceName end
  if not force and isBoundAsWanted(control, bindDeviceName) then return true end

  local device = findDevice(bindDeviceName)
  if not device or not device.contents or type(device.contents.bindings) ~= "table" then
    log("W", LOG_TAG, "No input device to bind tester shortcut")
    return false
  end
  bindDeviceName = device.devname or bindDeviceName
  local deviceType = tostring(bindDeviceName):lower():match("^(%D+)")
  if not deviceType then return false end

  if not writeShortcutInputMap(deviceType, control) then return false end
  saveBindSettings()
  return true
end

-- Ownership ---------------------------------------------------------------------------------------

-- Creates the inventory record for the spawned car, marked owned and not loaned.
local function grantSpawnedVehicle(veh)
  if not veh or not overhaul_career_garage_inventory or not overhaul_career_garage_inventory.addVehicle then
    return nil
  end
  local inventoryId = overhaul_career_garage_inventory.addVehicle(veh:getID(), nil, {
    owned = true,
    takesNoInventorySpace = true,
  })
  if inventoryId then
    local record = overhaul_career_garage_inventory.getVehicle and overhaul_career_garage_inventory.getVehicle(inventoryId)
    if record then
      record.owned = true
      record.loanType = nil
    end
    extensions.hook("onOverhaulVehicleAddedToInventory", {
      inventoryId = inventoryId,
      purchaseData = { insuranceId = -1 },
    })
  end
  return inventoryId
end

-- Money and skill XP -----------------------------------------------------------------------------

local function testerReason(label)
  return { label = label or "RLS tester", tags = { "tester" }, testerForce = true }
end

local function playerAttributesReady()
  if overhaul_career_economy_playerAttributes and overhaul_career_economy_playerAttributes.addAttributes then return true end
  toast("error", "Player attributes are not loaded.")
  return false
end

local function currentMoney()
  if overhaul_career_economy_playerAttributes and overhaul_career_economy_playerAttributes.getAttributeValue then
    return tonumber(overhaul_career_economy_playerAttributes.getAttributeValue("money")) or 0
  end
  return 0
end

local function addMoney(amount)
  if not requireCareer() or not playerAttributesReady() then return end
  overhaul_career_economy_playerAttributes.addAttributes({ money = amount }, require("overhaul/lib/finance/metadata").tag(testerReason("RLS tester money"), "cheat"))
  toast("info", string.format("Added $%s. Balance: $%s", tostring(amount), tostring(math.floor(currentMoney() + 0.5))))
end

-- XP goes to every skill track except money and vouchers; stamina always gets it.
local function skillXpChanges(amount)
  local change = {}
  local count = 0
  if overhaul_career_progression_skills and overhaul_career_progression_skills.getSortedBranches then
    for _, branch in ipairs(overhaul_career_progression_skills.getSortedBranches() or {}) do
      if branch and branch.attributeKey and (branch.isSkill or branch.isBranch) then
        local key = branch.attributeKey
        if key ~= "money" and key ~= "vouchers" then
          change[key] = (change[key] or 0) + amount
          count = count + 1
        end
      end
    end
  end
  change["careerSkills-stamina"] = change["careerSkills-stamina"] or amount
  if not change["stamina"] then change["stamina"] = amount end
  return change, count
end

local function addSkillXp(amount)
  if not requireCareer() or not playerAttributesReady() then return end
  local change, count = skillXpChanges(amount)
  if count == 0 then
    toast("error", "No skill attributes found.")
    return
  end
  overhaul_career_economy_playerAttributes.addAttributes(change, testerReason("RLS tester XP"))
  toast("info", string.format("Added %s XP to %d skill tracks.", tostring(amount), count))
end

-- Business XP goes to every tuning shop the player owns.
local function addTuningShopXp(amount)
  if not requireCareer() then return end
  local manager = overhaul_career_business_manager
  local shop = manager and manager.getBusinessObject and manager.getBusinessObject("tuningShop")
  if not (shop and shop.addBusinessXP) then
    toast("error", "Tuning shop business is not loaded.")
    return
  end
  local count = 0
  for businessId, owned in pairs(manager.getPurchasedBusinesses("tuningShop") or {}) do
    if owned then
      shop.addBusinessXP(businessId, amount)
      guihooks.trigger("businessSkillTree:onTreesUpdated", { businessId = businessId })
      count = count + 1
    end
  end
  if count == 0 then
    toast("error", "You do not own a tuning shop.")
    return
  end
  toast("info", string.format("Added %s business XP to %d tuning shop(s).", tostring(amount), count))
end

-- Maxes every skill-tree node for each owned tuning shop, then refreshes what a bought upgrade refreshes.
local function maxTuningShopSkillTree()
  if not requireCareer() then return end
  local manager = overhaul_career_business_manager
  local skillTree = overhaul_career_business_skillTree
  if not (manager and manager.getPurchasedBusinesses and skillTree and skillTree.debugMaxAllNodes) then
    toast("error", "Business skill trees are not loaded.")
    return
  end
  local count = 0
  for businessId, owned in pairs(manager.getPurchasedBusinesses("tuningShop") or {}) do
    if owned and skillTree.debugMaxAllNodes("tuningShop", businessId) then count = count + 1 end
  end
  if count == 0 then
    toast("error", "You do not own a tuning shop.")
    return
  end
  if gameplay_rawPois then gameplay_rawPois.clear() end
  if overhaul_ui_recoveryPrompt then
    overhaul_ui_recoveryPrompt.addTowingButtons()
    overhaul_ui_recoveryPrompt.addTaxiButtons()
  end
  require("overhaul/lib/save/store").request("testerMenu:maxTuningShops")
  toast("info", string.format("Maxed the skill tree for %d tuning shop(s).", count))
end

-- Discovers every dealership on this map and raises each dealer organization to its reputation cap.
local function maxDealerships()
  if not requireCareer() or not playerAttributesReady() then return end
  local shopping = overhaul_career_market_vehicleShopping
  if not (shopping and shopping.discoverAllDealers) then
    toast("error", "Vehicle shopping is not loaded.")
    return
  end
  local discovered = shopping.discoverAllDealers()

  local change, orgCount = {}, 0
  for _, dealership in ipairs(overhaul_world_facilities.getFacilitiesByType("dealership") or {}) do
    local orgId = dealership.associatedOrganization
    local org = orgId and overhaul_world_organizations.getOrganization(orgId)
    local key = orgId and (orgId .. "Reputation")
    if org and not change[key] then
      local max = overhaul_career_progression_reputation.getMaximumValue(org)
      local current = tonumber(overhaul_career_economy_playerAttributes.getAttributeValue(key)) or 0
      change[key] = math.max(0, max - current)
      orgCount = orgCount + 1
    end
  end
  overhaul_career_economy_playerAttributes.addAttributes(change, require("overhaul/lib/finance/metadata").tag(testerReason("RLS tester dealership reputation"), "cheat"))
  toast("info", string.format("Discovered %d dealership(s); maxed reputation for %d organization(s).", discovered, orgCount))
end

-- Vehicle presets ---------------------------------------------------------------------------------

local function fileExists(path)
  return path and FS:fileExists(path)
end

-- Config keys match ignoring case; an exact key wins over a case-folded one.
local function configEntry(configs, configKey)
  local exact = configs[configKey]
  if type(exact) == "table" then return exact, configKey end
  local wanted = tostring(configKey or ""):lower()
  for key, value in pairs(configs) do
    if tostring(key):lower() == wanted then return value, key end
  end
  return exact, configKey
end

local function lookupModelConfig(model, configKey)
  local modelData = core_vehicles.getModel(model)
  local configs = modelData and (modelData.configs or (modelData.model and modelData.model.configs))
  if type(configs) ~= "table" then return nil end

  local cfg, resolvedKey = configEntry(configs, configKey)
  if type(cfg) ~= "table" then return nil end
  return {
    model = model,
    configKey = resolvedKey,
    pc = cfg.pcFilename or ("/vehicles/" .. model .. "/" .. resolvedKey .. ".pc"),
    name = cfg.Name or cfg.Configuration or resolvedKey,
  }
end

-- Preset configs may be named "info_<name>" or misspelled; try each spelling in turn.
local function configNameCandidates(configName)
  local name = tostring(configName or "")
  local names = { name }
  if name:find("^info_", 1) then names[#names + 1] = name:gsub("^info_", "") end
  if name == "adente_race" then names[#names + 1] = "ardente_race" end
  return names
end

local function resolvePresetConfig(preset)
  local model = preset.model
  local names = configNameCandidates(preset.config)
  for _, name in ipairs(names) do
    local found = lookupModelConfig(model, name)
    if found then return found end
    local pc = "/vehicles/" .. model .. "/" .. name .. ".pc"
    if fileExists(pc) then return { model = model, configKey = name, pc = pc, name = preset.label } end
  end
  local fallback = names[1]
  return {
    model = model,
    configKey = fallback,
    pc = "/vehicles/" .. model .. "/" .. fallback .. ".pc",
    name = preset.label,
  }
end

-- Eight metres ahead of the player's car, facing the same way; otherwise use authored safe placement.
local function spawnPose()
  local player = getPlayerVehicle(0)
  if player then
    local pos = player:getPosition()
    local dir = player:getDirectionVector()
    return pos + dir * 8, quatFromDir(dir)
  end
  local levelData = require("overhaul/lib/world/levelData")
  local level = getCurrentLevelIdentifier()
  local config = level and jsonReadFile("/levels/" .. level .. "/overhaul/debug.json")
  local definition = config and config.version == 1 and (config.safeSpawn or config.debugSpawn)
  if definition and definition.spawnPoint then
    local info = core_levels.getLevelByName(level)
    for _, point in ipairs(info and info.spawnPoints or {}) do
      if point.objectname == definition.spawnPoint then definition = {sceneObject = point.objectname}; break end
    end
  end
  local pose = definition and levelData.resolveSpawn(definition, level)
  if pose then return pose.pos, pose.rot end
  log("W", "testerMenu", "No player pose or configured safe debug spawn on this level.")
end

-- Spawns ahead of the player (or at the level's safe spawn) and enters the vehicle.
local function spawnAhead(model, config)
  local pos, rot = spawnPose()
  if not pos or not rot then
    toast("error", "No safe spawn is available on this level.")
    return nil
  end
  local options = { config = config, pos = pos, rot = rot, autoEnterVehicle = true }
  if sanitizeVehicleSpawnOptions then
    options = sanitizeVehicleSpawnOptions(model, options)
    options.config = config
    options.autoEnterVehicle = true
  end
  local ok, veh = pcall(core_vehicles.spawnNewVehicle, model, options)
  if not ok or not veh then
    toast("error", string.format("Spawn failed for %s/%s.", tostring(model), tostring(config)))
    return nil
  end
  return veh
end

local function spawnPreset(preset)
  if not requireCareer() then return end
  local found = resolvePresetConfig(preset)
  local veh = spawnAhead(found.model, found.pc)
  if not veh then return end
  local inventoryId = grantSpawnedVehicle(veh)
  local ownership = inventoryId and (" owned #" .. tostring(inventoryId)) or " (not added to garage)"
  toast("info", string.format("Spawned %s (%s/%s)%s", found.name, found.model, found.configKey, ownership))
end

-- Random cars and trucks, filtered like the stock "random vehicle" fun option (no buses or near-static configs).
local function randomModelAndConfig()
  local candidates = {}
  for _, v in ipairs(core_vehicles.getVehicleList().vehicles or {}) do
    local info = v.model or {}
    if (info.Type == "Car" or info.Type == "Truck") and info["Body Style"] ~= "Bus" and info.isAuxiliary ~= true then
      local configs = {}
      for _, c in pairs(v.configs or {}) do
        if c["Top Speed"] and c["Top Speed"] > 19 and c.isAuxiliary ~= true then configs[#configs + 1] = c end
      end
      if #configs > 0 then candidates[#candidates + 1] = { model = info.key, configs = configs } end
    end
  end
  if #candidates == 0 then return nil end
  local pick = candidates[math.random(#candidates)]
  local config = pick.configs[math.random(#pick.configs)]
  return pick.model, config.key, config.Name or config.key
end

-- Every filled slot gets a random part that fits it. Sub-slot picks are kept: the slot system ignores
-- ones the new part does not have and fills its new slots with defaults, which the next round randomizes.
local function randomizePartsTree(node)
  local changed = 0
  for _, child in pairs(node.children or {}) do
    local options = child.suitablePartNames
    if child.chosenPartName and child.chosenPartName ~= "" and type(options) == "table" and #options > 0 then
      local pick = options[math.random(#options)]
      if pick ~= child.chosenPartName then
        child.chosenPartName = pick
        changed = changed + 1
      end
      changed = changed + randomizePartsTree(child)
    end
  end
  return changed
end

local RANDOM_RESPAWN_TIMEOUT_SECONDS = 15
local RANDOM_PART_ROUNDS = 2

local function spawnRandomVehicle()
  if not requireCareer() then return end
  local model, configKey, configName = randomModelAndConfig()
  if not model then
    toast("error", "No vehicles available to pick from.")
    return
  end
  local veh = spawnAhead(model, "/vehicles/" .. model .. "/" .. configKey .. ".pc")
  if not veh then return end
  local vehId = veh:getID()
  toast("info", string.format("Spawning %s (%s) with random parts...", tostring(configName), model))

  -- The parts tree only exists once the vehicle has loaded, so randomize and respawn from a job.
  core_jobsystem.create(function(job)
    local function waitForData(previous)
      local waited = 0
      local data = core_vehicle_manager.getVehicleData(vehId)
      while (data == previous or not (data and data.config and data.config.partsTree))
          and waited < RANDOM_RESPAWN_TIMEOUT_SECONDS do
        job.sleep(0.1)
        waited = waited + 0.1
        data = core_vehicle_manager.getVehicleData(vehId)
      end
      if data == previous or not (data and data.config and data.config.partsTree) then return nil end
      return data
    end

    local data = waitForData(nil)
    local changed = 0
    for _ = 1, RANDOM_PART_ROUNDS do
      local current = getObjectByID(vehId)
      if not (current and data) then
        toast("error", "Random vehicle did not finish loading.")
        return
      end
      local config = deepcopy(data.config)
      local roundChanged = randomizePartsTree(config.partsTree)
      if roundChanged == 0 then break end
      changed = changed + roundChanged
      current:respawn(serialize(config))
      data = waitForData(data)
    end
    if not (data and getObjectByID(vehId)) then
      toast("error", "Random vehicle did not finish respawning.")
      return
    end

    if not core_funstuff then extensions.load("core_funstuff") end
    if core_funstuff and core_funstuff.randomizeColors and getPlayerVehicle(0) == getObjectByID(vehId) then
      core_funstuff.randomizeColors()
    end
    local inventoryId = grantSpawnedVehicle(getObjectByID(vehId))
    local ownership = inventoryId and (" owned #" .. tostring(inventoryId)) or " (not added to garage)"
    toast("info", string.format("Spawned %s (%s) with %d random part swaps%s", tostring(configName), model, changed, ownership))
  end)
end

local function ownCurrentVehicle()
  if not requireCareer() then return end
  local veh = getPlayerVehicle(0)
  if not veh then
    toast("error", "You are not in a vehicle.")
    return
  end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    toast("error", "Enter a vehicle first.")
    return
  end

  local vehId = veh:getID()
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  if inventoryId then
    local record = overhaul_career_garage_inventory.getVehicle(inventoryId)
    if record then
      record.owned = true
      record.loanType = nil
    end
    toast("info", "Marked inventory vehicle #" .. tostring(inventoryId) .. " as owned.")
    return
  end

  inventoryId = grantSpawnedVehicle(veh)
  if inventoryId then
    toast("info", "Added current vehicle to ownership as #" .. tostring(inventoryId) .. ".")
  else
    toast("error", "Could not add the current vehicle to inventory.")
  end
end

-- World controls ----------------------------------------------------------------------------------

local function dynamicWeather()
  return optional("overhaul_world_weather")
end

local function setWeather(condition, label)
  if not requireCareer() then return end
  local weather = dynamicWeather()
  if not (weather and weather.forceCondition) then
    toast("error", "Dynamic weather is not loaded.")
    return
  end
  if not weather.forceCondition(condition) then
    toast("error", "Could not change weather (external override?).")
  elseif condition == "clear" then
    toast("info", "Weather set to a bright sunny noon with no clouds or fog.")
  else
    toast("info", "Weather set to " .. label .. ".")
  end
end

-- Goes through the in-game sleep (fade and clock move), with the tester menu closed like the sleep menu.
local function sleepUntil(preset)
  if not requireCareer() then return end
  if not (overhaul_world_sleep and overhaul_world_sleep.sleep) then
    toast("error", "Sleep is not loaded.")
    return
  end
  menuVisible = false
  overhaul_world_sleep.closeAllMenus()
  overhaul_world_sleep.sleep(preset.time)
  toast("info", "Sleeping until " .. preset.label .. ".")
end

local function toggleDayCycle()
  if not requireCareer() then return end
  local weather = dynamicWeather()
  if not (weather and weather.getDayNightCycle and weather.toggleDayNightCycle) then
    toast("error", "Dynamic weather is not loaded.")
    return
  end
  local clock = weather.getDayNightCycle() or {}
  local nextPlay = not (clock.play == true)
  weather.toggleDayNightCycle(nextPlay)
  toast("info", nextPlay and "Day/night cycle running." or "Day/night cycle frozen.")
end

local function skipLevelUpNotifications()
  if not requireCareer() then return end
  guihooks.trigger("SkipCareerLevelUpCelebrations")
  toast("info", "Skipped queued level-up notifications.")
end

-- Shops, saves and repairs ------------------------------------------------------------------------

local function openMapSwitcher()
  if not requireCareer() then return end
  if not (overhaul_career_garage_switchMap and overhaul_career_garage_switchMap.openForTester) then
    toast("error", "Map switcher is not loaded.")
    return
  end
  local ok, err = overhaul_career_garage_switchMap.openForTester()
  if ok then
    toast("info", "Map switcher opened.")
  else
    toast("error", err or "Could not open the map switcher.")
  end
end

-- Clears the car's wear and damage, then runs the vehicle-side reset (its Lua stays as one block).
local function recoverAndRepair()
  if not requireCareer() then return end
  local veh = getPlayerVehicle(0)
  if not veh then
    toast("error", "You are not in a vehicle.")
    return
  end

  local vehId = veh:getID()
  local inventoryId = overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
  if inventoryId and overhaul_career_maintenance_tireSystem and overhaul_career_maintenance_tireSystem.forceFreshForVehicle then
    overhaul_career_maintenance_tireSystem.forceFreshForVehicle(inventoryId)
  end
  if inventoryId and overhaul_vehicles_maintenanceBridge and overhaul_vehicles_maintenanceBridge.resetAllCategories then
    overhaul_vehicles_maintenanceBridge.resetAllCategories(inventoryId)
  end
  if inventoryId and overhaul_career_repair_damageManager and overhaul_career_repair_damageManager.clearDamageState then
    overhaul_career_repair_damageManager.clearDamageState(inventoryId)
  end
  veh:queueLuaCommand([[
    if overhaulMaintenance then
      overhaulMaintenance.debugResetCategory('engine')
      overhaulMaintenance.debugResetCategory('radiator')
      overhaulMaintenance.debugResetCategory('transmission')
    end
    if energyStorage then
      for _, storage in pairs(energyStorage.getStorages() or {}) do
        if storage.energyCapacity then storage.storedEnergy = storage.energyCapacity end
      end
    end
    extensions.load('overhaulDamageState')
    if overhaulDamageState then overhaulDamageState.reset() end
    if recovery then recovery.recoverInPlace() end
    if overhaulTires and overhaulTires.applyFreshAndInflate then
      overhaulTires.applyFreshAndInflate()
    end
  ]])
  toast("info", "Repaired and refueled in place.")
end

-- The route's final waypoint may be a road node name, an {x, y, z} array or a vec3.
local function waypointPosition(wp)
  if type(wp) == "string" then
    local node = map and map.getMap and map.getMap().nodes[wp]
    return node and vec3(node.pos)
  end
  if type(wp) == "table" and #wp == 3 then return vec3(wp) end
  if wp and wp.x and wp.y and wp.z then return vec3(wp.x, wp.y, wp.z) end
end

local function teleportToWaypoint()
  if not requireCareer() then return end
  local veh = getPlayerVehicle(0)
  if not veh then
    toast("error", "No player vehicle to teleport.")
    return
  end
  local waypoints = core_groundMarkers and core_groundMarkers.endWP
  local pos = waypoints and waypointPosition(waypoints[#waypoints])
  if not pos then
    toast("error", "Set a waypoint on the map first.")
    return
  end
  spawn.safeTeleport(veh, pos, nil, nil, nil, nil, nil, false)
  toast("info", "Teleported to waypoint.")
end

local function saveCareer()
  if not requireCareer() then return end
  if overhaul_career_saveSystem and overhaul_career_saveSystem.saveCurrent then
    require("overhaul/lib/save/store").request("testerMenu:save")
    toast("info", "Career save requested.")
  else
    toast("error", "Save system is not available.")
  end
end

-- Clean Up Club ----------------------------------------------------------------------------------

local function requireCleanupClub()
  if not requireCareer() then return nil end
  local club = rawget(_G, "overhaul_jobs_cleanupClub")
  if not club then
    toast("error", "Clean Up Club is not loaded.")
    return nil
  end
  return club
end

local function spawnCleanupVehicle()
  local club = requireCleanupClub()
  if not club or not club.debugForceSpawn then
    if club then toast("error", "Clean Up Club debug spawn is unavailable.") end
    return
  end
  local ok, result = club.debugForceSpawn(1, "vehicle_project")
  if not ok then toast("error", tostring(result or "Could not spawn a cleanup container.")) end
end

local function focusCleanup()
  local club = requireCleanupClub()
  if not club or not club.debugFocusCleanup then
    if club then toast("error", "Clean Up Club debug focus is unavailable.") end
    return
  end
  local ok, result = club.debugFocusCleanup()
  if not ok then toast("error", tostring(result or "Could not focus a cleanup.")) end
end

-- Action table ------------------------------------------------------------------------------------

local testerActions = {
  sunny = function() setWeather("clear", "Sunny") end,
  rain = function() setWeather("storm", "Heavy Rain") end,
  overcast = function() setWeather("overcast", "Overcast") end,
  sleep6am = function() sleepUntil(SLEEP_PRESETS[1]) end,
  sleep12pm = function() sleepUntil(SLEEP_PRESETS[2]) end,
  sleep9pm = function() sleepUntil(SLEEP_PRESETS[3]) end,
  sleep12am = function() sleepUntil(SLEEP_PRESETS[4]) end,
  cycle = toggleDayCycle,
  money = function() addMoney(1000000) end,
  moneySmall = function() addMoney(10000) end,
  xp = function() addSkillXp(100000) end,
  xpSmall = function() addSkillXp(1000) end,
  tuningShopXp = function() addTuningShopXp(10000) end,
  tuningShopTree = maxTuningShopSkillTree,
  dealerships = maxDealerships,
  skipLevelUps = skipLevelUpNotifications,
  drift = function() spawnPreset(SPAWN_PRESETS[1]) end,
  race = function() spawnPreset(SPAWN_PRESETS[2]) end,
  rally = function() spawnPreset(SPAWN_PRESETS[3]) end,
  work = function() spawnPreset(SPAWN_PRESETS[4]) end,
  random = spawnRandomVehicle,
  own = ownCurrentVehicle,
  switcher = openMapSwitcher,
  repair = recoverAndRepair,
  waypoint = teleportToWaypoint,
  save = saveCareer,
  cleanupSpawn = spawnCleanupVehicle,
  cleanupFocus = focusCleanup,
}

-- Menu state for the UI ---------------------------------------------------------------------------

local function pushUi()
  guihooks.trigger("RlsTesterMenu", {
    visible = menuVisible == true,
    money = currentMoney(),
    status = statusText,
    statusIsError = statusIsError,
    toggleControl = toggleControl,
    toggleLabel = formatControlLabel(toggleControl, bindDeviceName),
    deviceName = bindDeviceName,
    rebindArmed = rebindArmed == true,
  })
end

-- Public API: menu --------------------------------------------------------------------------------

function M.run(actionId)
  if not refreshCreatorKey(true) then
    menuVisible = false
    return false
  end
  local handler = testerActions[tostring(actionId or "")]
  if not handler then
    toast("error", "Unknown tester action: " .. tostring(actionId))
    pushUi()
    return false
  end
  handler()
  pushUi()
  return true
end

function M.toggle()
  if rebindArmed then return false end
  if not refreshCreatorKey(true) then
    menuVisible = false
    return false
  end
  menuVisible = not menuVisible
  if menuVisible and not careerActive() then
    toast("error", "Menu opened, but career is not active yet.")
  end
  refreshFromLive()
  pushUi()
  if menuVisible then
    core_jobsystem.create(function(job)
      job.sleep(0.25)
      pushUi()
    end)
  end
  return menuVisible
end

function M.isVisible()
  return menuVisible
end

function M.hasCreatorKey()
  return refreshCreatorKey(false)
end

-- Public API: shortcut rebinding ------------------------------------------------------------------

function M.beginRebind()
  if not refreshCreatorKey(true) then return false end
  rebindArmed = true
  statusText = "Press a key for the tester menu shortcut."
  statusIsError = false
  setBindingCapture(true)
  pushUi()
  return true
end

function M.cancelRebind()
  rebindArmed = false
  statusText = ""
  statusIsError = false
  setBindingCapture(false)
  pushUi()
  return true
end

function M.setToggleControl(control, deviceName)
  if not refreshCreatorKey(true) then return false end
  local sanitized = sanitizeControl(control)
  if not sanitized then
    rebindArmed = false
    toast("error", "That key cannot be used as a shortcut.")
    pushUi()
    return false
  end

  toggleControl = sanitized
  rebindArmed = false
  setBindingCapture(false)
  if not applyToggleBind(deviceName, true) then
    toast("error", "Could not save that shortcut on that device.")
    pushUi()
    return false
  end
  toast("info", "Tester menu shortcut saved as " .. formatControlLabel(toggleControl, bindDeviceName) .. ".")
  pushUi()
  return true
end

function M.ensureBound()
  if not refreshCreatorKey(true) then return false end
  if not loadBindSettings() then return false end
  return applyToggleBind()
end

-- Game hooks --------------------------------------------------------------------------------------

function M.onExtensionLoaded()
  loadBindSettings()
end

function M.onCareerActivated()
  return M.ensureBound()
end

function M.onExtensionUnloaded()
  if not removeOverlay() then return end
  if core_input_actions then core_input_actions.onFileChanged("/" .. OVERLAY_ACTIONS) end
  if core_input_bindings then core_input_bindings.onFileChanged("/" .. OVERLAY_ACTIONS) end
end

return M
