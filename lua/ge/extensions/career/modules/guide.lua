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
  
  -- Try using core_input_bindings first (simpler API)
  if core_input_bindings and core_input_bindings.setBinding then
    local success_result = pcall(function()
      core_input_bindings.setBinding("openPhone", controlString)
    end)
    if success_result then
      success = true
      bindingName = formatControlName(controlString)
      return {success = success, binding = bindingName}
    end
  end
  
  -- Fallback to direct ActionMap binding
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
  
  -- Normalize control string to lowercase (like vanilla does)
  controlString = string.lower(controlString)
  
  -- Extract device name and control from the control string
  -- controlString format: "keyboard_p" or "keyboard_backslash" or "mouse0"
  -- actionMap:bind() expects: deviceName (like "keyboard0"), action, control (just the key part)
  local deviceName = "keyboard0"  -- Default to keyboard0
  local control = controlString
  
  if controlString:find("^keyboard_") then
    deviceName = "keyboard0"
    control = controlString:gsub("^keyboard_", "")  -- Extract control part (e.g., "p", "backslash")
  elseif controlString:find("^mouse") then
    deviceName = "mouse0"
    control = controlString:gsub("^mouse", "")  -- Extract button number (e.g., "0", "1")
  end
  
  -- Find the correct ActionMap
  local actionMapFullName = actionMapName .. "ActionMap"
  local actionMap = scenetree.findObject(actionMapFullName)
  
  if actionMap then
    -- Fill binding defaults (matching vanilla fillNormalizeBindingDefaults)
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
    
    -- bind requires many arguments - matching vanilla signature exactly
    -- deviceName should be like "keyboard0" or "mouse0", control should be just the key part (e.g., "p", "backslash", "0")
    actionMap:bind(
      deviceName, "openPhone", control, 
      isCentered, deadzoneResting, deadzoneEnd, linearity, angle, lockType,
      isInverted, isForceEnabled, isForceInverted, useLogitechSDK, 
      logitechVibrotactileCoef, logitechVibrotactileFreqMax, ffbUpdateType, ffb_json,
      actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp,
      filterType, isRelative, player, ctx
    )
    success = true
    bindingName = formatControlName(controlString)
    
    -- Save the binding to disk using the bindings system's proper API
    pcall(function()
      if core_input_bindings and core_input_bindings.devices and core_input_bindings.bindings and core_input_bindings.saveBindingsToDisk then
        local deviceInfo = core_input_bindings.devices[deviceName]
        
        if deviceInfo then
          local guid, productName, pidvid = deviceInfo[1], deviceInfo[2], deviceInfo[3]
          -- Extract device type from deviceName (e.g., "keyboard0" -> "keyboard")
          local devicetype = deviceName:gsub("%d+$", "") or deviceName
          
          -- Find the device data in the bindings structure
          for _, deviceData in ipairs(core_input_bindings.bindings) do
            if deviceData.devicename == deviceName and deviceData.contents then
              -- Ensure required device metadata fields exist
              if not deviceData.contents.devicetype then
                deviceData.contents.devicetype = devicetype
              end
              if not deviceData.contents.guid then
                deviceData.contents.guid = guid
              end
              if not deviceData.contents.name then
                deviceData.contents.name = productName
              end
              if not deviceData.contents.vidpid then
                deviceData.contents.vidpid = pidvid
              end
              
              -- Ensure bindings array exists
              if not deviceData.contents.bindings then
                deviceData.contents.bindings = {}
              end
              
              -- Find and update the openPhone binding, or add it if it doesn't exist
              local found = false
              for _, binding in ipairs(deviceData.contents.bindings) do
                if binding.action == "openPhone" then
                  binding.control = controlString
                  -- Update other required fields
                  binding.deadzoneResting = 0
                  binding.deadzoneEnd = 0
                  binding.linearity = 1
                  binding.angle = 0
                  binding.lockType = 3
                  binding.isInverted = false
                  binding.isForceEnabled = false
                  binding.isForceInverted = false
                  binding.useLogitechSDK = false
                  binding.logitechVibrotactileCoef = 1
                  binding.logitechVibrotactileFreqMax = 50
                  binding.ffb = binding.ffb or {updateType = 0}
                  binding.filterType = -1
                  binding.isRelative = false
                  found = true
                  break
                end
              end
              
              if not found then
                -- Add new binding with proper structure
                table.insert(deviceData.contents.bindings, {
                  action = "openPhone",
                  control = controlString,
                  deadzoneResting = 0,
                  deadzoneEnd = 0,
                  linearity = 1,
                  angle = 0,
                  lockType = 3,
                  isInverted = false,
                  isForceEnabled = false,
                  isForceInverted = false,
                  useLogitechSDK = false,
                  logitechVibrotactileCoef = 1,
                  logitechVibrotactileFreqMax = 50,
                  ffb = {updateType = 0},
                  filterType = -1,
                  isRelative = false
                })
              end
              
              -- Save using the bindings system's save function
              core_input_bindings.saveBindingsToDisk(deviceData.contents)
              log("D", "guide", "Saved phone binding via bindings system")
              break
            end
          end
        end
      end
    end)
  end
  
  return {success = success, binding = bindingName}
end

M.getPhoneBinding = getPhoneBinding
M.setPhoneBinding = setPhoneBinding

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
