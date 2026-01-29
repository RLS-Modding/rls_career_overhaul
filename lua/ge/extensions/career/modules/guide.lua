local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/guide.json"

local guideShown = false
local splashVisible = false

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function loadGuideData()
  if not career_career.isActive() then
    return
  end
  
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then
    return
  end

  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  guideShown = data.guideShown or false
end

local function saveGuideData(currentSavePath)
  if not career_career.isActive() then
    return
  end
  
  if not currentSavePath then
    local _, path = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = path
  end
  
  if not currentSavePath then
    return
  end

  ensureSaveDir(currentSavePath)

  local data = {
    guideShown = guideShown
  }

  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
end

local function checkGuideShown()
  return guideShown
end

local function markGuideShown()
  guideShown = true
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveGuideData(currentSavePath)
  end
end

local function showSplash()
  if splashVisible then return end
  
  splashVisible = true
  guihooks.trigger('GuideShowSplash')
end

local function onSaveCurrentSaveSlot(currentSavePath)
  if not currentSavePath then
    return
  end
  local success, err = pcall(function()
    saveGuideData(currentSavePath)
  end)
  if not success then
    log("E", "guide", "onSaveCurrentSaveSlot failed: " .. tostring(err))
  end
end

M.onCareerActivated = function()
  loadGuideData()
end

M.showSplashIfNeeded = function()
  if not checkGuideShown() then
    core_jobsystem.create(function(job)
      job.sleep(0.5)
      showSplash()
    end)
  end
end

M.onContinue = function()
  if splashVisible then
    splashVisible = false
    markGuideShown()
    guihooks.trigger('GuideHideSplash')
  end
end

local function formatControlName(control)
  if not control or control == "" then
    return "Not bound"
  end
  
  control = tostring(control)
  
  if control:find("keyboard_") then
    local key = control:gsub("keyboard_", "")
    local symbolMap = {
      backslash = "\\",
      slash = "/",
      comma = ",",
      period = ".",
      semicolon = ";",
      apostrophe = "'",
      grave = "`",
      minus = "-",
      equals = "=",
      leftbracket = "[",
      rightbracket = "]"
    }
    if symbolMap[key] then
      return symbolMap[key]
    end
    if key:len() == 1 then
      return key:upper()
    elseif key:match("^f%d+$") then
      return key:upper()
    elseif key == "space" then
      return "Space"
    elseif key == "enter" then
      return "Enter"
    elseif key == "tab" then
      return "Tab"
    elseif key:find("arrow") then
      local direction = key:gsub("arrow", "")
      if direction == "left" then
        return "Arrow Left"
      elseif direction == "right" then
        return "Arrow Right"
      elseif direction == "up" then
        return "Arrow Up"
      elseif direction == "down" then
        return "Arrow Down"
      else
        return "Arrow " .. direction:gsub("^%l", string.upper)
      end
    else
      return key:gsub("^%l", string.upper):gsub("_", " ")
    end
  elseif control:find("^mouse%d+") then
    local button = control:gsub("mouse", "")
    local btnNum = tonumber(button)
    if btnNum == 0 then
      return "Mouse Left"
    elseif btnNum == 1 then
      return "Mouse Right"
    elseif btnNum == 2 then
      return "Mouse Middle"
    else
      return "Mouse Button " .. (btnNum + 1)
    end
  end
  
  return control
end

local function getPhoneBinding()
  local binding = "Not bound"

  -- Try the cached lookup first
  if core_input_bindings and core_input_bindings.getControlForAction then
    local success, control = pcall(function()
      return core_input_bindings.getControlForAction("openPhone")
    end)
    if success and control and control ~= "" then
      binding = formatControlName(control)
      return {binding = binding}
    end
  end

  -- Fallback: iterate all device bindings to find openPhone
  if core_input_bindings and core_input_bindings.bindings then
    for _, device in ipairs(core_input_bindings.bindings) do
      if device.contents and device.contents.bindings then
        for _, b in ipairs(device.contents.bindings) do
          if b.action == "openPhone" and b.control and b.control ~= "" then
            binding = formatControlName(b.control)
            return {binding = binding}
          end
        end
      end
    end
  end

  return {binding = binding}
end

local function setPhoneBinding(controlString)
  local bindingName = "Not bound"

  if not controlString or controlString == "" then
    return {success = false, binding = bindingName}
  end

  controlString = string.lower(controlString)

  -- Determine device name from control string
  local deviceName = "keyboard0"
  if controlString:find("^mouse") then
    deviceName = "mouse0"
  end

  -- Find the keyboard/mouse device in core_input_bindings
  if not core_input_bindings or not core_input_bindings.bindings then
    log("E", "guide", "core_input_bindings not available")
    return {success = false, binding = bindingName}
  end

  local targetDevice = nil
  for _, device in ipairs(core_input_bindings.bindings) do
    if device.devname == deviceName then
      targetDevice = device
      break
    end
  end

  if not targetDevice or not targetDevice.contents then
    log("E", "guide", "Could not find device: " .. deviceName)
    return {success = false, binding = bindingName}
  end

  -- Remove any existing openPhone binding from this device
  local bindings = targetDevice.contents.bindings
  for i = #bindings, 1, -1 do
    if bindings[i].action == "openPhone" then
      table.remove(bindings, i)
    end
  end

  -- Add the new binding
  table.insert(bindings, {
    action = "openPhone",
    control = controlString,
  })

  -- Bind directly to the engine ActionMap so it works immediately
  local ok = false
  pcall(function()
    -- Ensure the action JSON has been loaded before trying to bind.
    -- If openPhone isn't registered yet, force a rescan of action JSON files
    -- so phone.json is picked up. This prevents bindingsLegend.lua from
    -- crashing with nil actionInfo later.
    if core_input_actions then
      local testOk, testActionSuccess = pcall(function()
        local s = core_input_actions.actionToCommands("openPhone")
        return s
      end)
      if not testOk or not testActionSuccess then
        pcall(function() extensions.reload("core_input_actions") end)
      end
    end

    local actionSuccess, actionMapName, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, isRelative, ctx, isCentered =
      core_input_actions.actionToCommands("openPhone")

    if actionSuccess then
      local amFullName = actionMapName .. "ActionMap"
      local am = scenetree.findObject(amFullName)
      if am then
        local b = {action = "openPhone", control = controlString}
        -- Fill in binding defaults so bind() gets all required params
        if core_input_bindings.fillNormalizeBindingDefaults then
          b = core_input_bindings.fillNormalizeBindingDefaults(b)
        end
        am:bind(
          deviceName, b.action, b.control, isCentered,
          b.deadzoneResting or 0, b.deadzoneEnd or 0, b.linearity or 1,
          b.angle or 0, b.lockType or 3, b.isInverted or false,
          b.isForceEnabled or false, b.isForceInverted or false,
          b.useLogitechSDK or false, b.logitechVibrotactileCoef or 1,
          b.logitechVibrotactileFreqMax or 50,
          (b.ffb and b.ffb.updateType) or 0, jsonEncode(b.ffb or {updateType = 0}),
          actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp,
          b.filterType or -1, isRelative, 0, ctx
        )
        ok = true
      end
    end
  end)

  if not ok then
    log("E", "guide", "Failed to bind openPhone to engine ActionMap")
  end

  -- Also save to disk so binding persists across restarts
  pcall(function()
    core_input_bindings.saveBindingsToDisk(targetDevice)
  end)

  bindingName = formatControlName(controlString)
  return {success = ok, binding = bindingName}
end

M.getPhoneBinding = getPhoneBinding
M.setPhoneBinding = setPhoneBinding
M.onRecordingActionDown = function() end -- handler for guide_recording action

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
