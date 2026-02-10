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

local function formatControlName(control, deviceName)
  if not control or control == "" then
    return "Not bound"
  end

  control = tostring(control)

  if deviceName and deviceName:find("mouse") then
    -- Mouse controls: "button0", "button1", etc.
    local btnNum = tonumber(control:match("button(%d+)"))
    if btnNum then
      if btnNum == 0 then return "Mouse Left"
      elseif btnNum == 1 then return "Mouse Right"
      elseif btnNum == 2 then return "Mouse Middle"
      else return "Mouse Button " .. (btnNum + 1) end
    end
    return "Mouse " .. control
  end

  -- Default: keyboard controls
  local symbolMap = {
    backslash = "\\", slash = "/", comma = ",", period = ".",
    semicolon = ";", apostrophe = "'", grave = "`", minus = "-",
    equals = "=", leftbracket = "[", rightbracket = "]"
  }
  if symbolMap[control] then
    return symbolMap[control]
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
  if not core_input_bindings then
    return {binding = "Not bound"}
  end

  -- Ensure bindings data is fresh
  if core_input_bindings.notifyUI then
    pcall(function() core_input_bindings.notifyUI("guide refresh") end)
  end

  if core_input_bindings.bindings then
    for _, device in ipairs(core_input_bindings.bindings) do
      if device.contents and device.contents.bindings then
        for _, b in ipairs(device.contents.bindings) do
          if b.action == "openPhone" and b.control and b.control ~= "" then
            return {binding = formatControlName(b.control, device.devname)}
          end
        end
      end
    end
  end

  return {binding = "Not bound"}
end

local function setPhoneBinding(controlString, deviceName)
  if not controlString or controlString == "" then
    return {success = false, binding = "Not bound"}
  end

  if not deviceName then deviceName = "keyboard0" end

  -- Find the device in core_input_bindings
  if not core_input_bindings or not core_input_bindings.bindings then
    log("E", "guide", "core_input_bindings not available")
    return {success = false, binding = "Not bound"}
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
    return {success = false, binding = "Not bound"}
  end

  -- Remove any existing openPhone binding from this device
  local bindings = targetDevice.contents.bindings
  for i = #bindings, 1, -1 do
    if bindings[i].action == "openPhone" then
      table.remove(bindings, i)
    end
  end

  -- Add the new binding with raw control string
  table.insert(bindings, {
    action = "openPhone",
    control = controlString,
    player = 0,
  })

  -- Save to disk — saveBindingsToDisk handles rebinding automatically
  local ok = pcall(function()
    core_input_bindings.saveBindingsToDisk(targetDevice.contents)
  end)

  if not ok then
    log("E", "guide", "Failed to save phone binding to disk")
  end

  local bindingName = formatControlName(controlString, deviceName)
  return {success = ok, binding = bindingName}
end

M.getPhoneBinding = getPhoneBinding
M.setPhoneBinding = setPhoneBinding
M.onRecordingActionDown = function() end -- handler for guide_recording action

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
