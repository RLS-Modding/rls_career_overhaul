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
  
  -- Try to get binding from core_input_bindings first (more reliable)
  if core_input_bindings and core_input_bindings.getControlForAction then
    local success, control = pcall(function()
      return core_input_bindings.getControlForAction("openPhone")
    end)
    if success and control and control ~= "" then
      binding = formatControlName(control)
      return {binding = binding}
    end
  end
  
  -- Fallback: try to read directly from ActionMap
  -- Try common action maps since actionToCommands might return invalid values
  local actionMapsToTry = {"VehicleCommon", "UI", "Camera", "Normal"}
  
  -- First try to get the action map from actionToCommands
  local actionMapName = nil
  local pcallSuccess, success, actionMap = pcall(function()
    if core_input_actions and core_input_actions.actionToCommands then
      return core_input_actions.actionToCommands("openPhone")
    end
    return false, "VehicleCommon"
  end)
  
  if pcallSuccess and success and actionMap and type(actionMap) == "string" then
    actionMapName = actionMap
    -- Insert at the beginning of the list to try it first
    table.insert(actionMapsToTry, 1, actionMapName)
  end
  
  -- Try each action map until we find the binding
  for _, mapName in ipairs(actionMapsToTry) do
    local actionMapFullName = mapName .. "ActionMap"
    local actionMap = scenetree.findObject(actionMapFullName)
    
    if actionMap then
      local bind = actionMap:getBinding("openPhone")
      if bind and bind ~= "" then
        binding = formatControlName(bind)
        break
      end
    end
  end
  
  return {binding = binding}
end

local function setPhoneBinding(controlString)
  local success = false
  local bindingName = "Not bound"
  
  if not controlString or controlString == "" then
    return {success = false, binding = bindingName}
  end
  
  -- Normalize control string to lowercase (like vanilla does)
  controlString = string.lower(controlString)
  
  -- Get action metadata to find the correct ActionMap
  local actionSuccess, actionMapName, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, isRelative, ctx, isCentered
  
  if core_input_actions and core_input_actions.actionToCommands then
    actionSuccess, actionMapName, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, isRelative, ctx, isCentered = 
      core_input_actions.actionToCommands("openPhone")
  end
  
  -- Use defaults if actionToCommands fails
  if not actionSuccess then
    actionMapName = "VehicleCommon"
    isCentered = 0
    actsOnChange = false
    onChange = ""
    actsOnDown = false
    onDown = ""
    actsOnUp = false
    onUp = ""
    isRelative = false
    ctx = ""
  end
  
  -- Extract device name and control from the control string
  local deviceName = "keyboard0"
  local control = controlString
  
  if controlString:find("^keyboard_") then
    deviceName = "keyboard0"
    control = controlString:gsub("^keyboard_", "")
  elseif controlString:find("^mouse") then
    deviceName = "mouse0"
    control = controlString:gsub("^mouse", "")
  end
  
  -- Remove all existing bindings for openPhone first (before setting new one)
  local actionMapsToCheck = {"VehicleCommon", "UI", "Camera", "Normal"}
  if actionMapName then
    table.insert(actionMapsToCheck, 1, actionMapName)
  end
  
  -- Remove from all ActionMaps
  for _, mapName in ipairs(actionMapsToCheck) do
    pcall(function()
      local mapToCheck = scenetree.findObject(mapName .. "ActionMap")
      if mapToCheck and mapToCheck.getBinding then
        local oldBind = mapToCheck:getBinding("openPhone")
        if oldBind and oldBind ~= "" then
          local oldDeviceName = "keyboard0"
          local oldControl = oldBind
          
          if oldBind:find("^keyboard_") then
            oldDeviceName = "keyboard0"
            oldControl = oldBind:gsub("^keyboard_", "")
          elseif oldBind:find("^mouse") then
            oldDeviceName = "mouse0"
            oldControl = oldBind:gsub("^mouse", "")
          end
          
          if mapToCheck.unbind then
            mapToCheck:unbind(oldDeviceName, "openPhone", oldControl)
          end
        end
      end
    end)
  end
  
  -- Find the correct ActionMap
  local actionMapFullName = actionMapName .. "ActionMap"
  local actionMap = scenetree.findObject(actionMapFullName)
  
  -- Use core_input_bindings.setBinding first (it handles everything properly)
  if core_input_bindings and core_input_bindings.setBinding then
    local success_result = pcall(function()
      core_input_bindings.setBinding("openPhone", controlString)
    end)
    if success_result then
      success = true
    end
  end
  
  -- Also set binding in ActionMap directly to ensure it works immediately
  if actionMap then
    local deadzoneResting = 0
    local deadzoneEnd = 0
    local linearity = 1
    local angle = 0
    local lockType = 3
    local isInverted = false
    local isForceEnabled = false
    local isForceInverted = false
    local useLogitechSDK = false
    local logitechVibrotactileCoef = 1
    local logitechVibrotactileFreqMax = 50
    local ffbUpdateType = 0
    local ffb_json = jsonEncode({updateType = 0})
    local filterType = -1
    local player = 0
    
    pcall(function()
      actionMap:bind(
        deviceName, "openPhone", control, 
        isCentered, deadzoneResting, deadzoneEnd, linearity, angle, lockType,
        isInverted, isForceEnabled, isForceInverted, useLogitechSDK, 
        logitechVibrotactileCoef, logitechVibrotactileFreqMax, ffbUpdateType, ffb_json,
        actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp,
        filterType, isRelative, player, ctx
      )
    end)
    success = true
  end
  
  bindingName = formatControlName(controlString)
  return {success = success, binding = bindingName}
end

M.getPhoneBinding = getPhoneBinding
M.setPhoneBinding = setPhoneBinding

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
