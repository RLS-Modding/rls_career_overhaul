-- Dynamic routes editor: an imgui window for the timer, groups, options and weights of dynamic road routes.
-- Every action goes through the dynamic routes runtime; the window only draws its state and forwards clicks.
local M = {}

local imgui = ui_imgui

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "overhaul_dev_editor_dynamicRoutesEditor"
local TOOL_WINDOW_NAME = "dynamicRoutesEditorTool"
local DEFAULT_TIMER_SECONDS = 60

local colAccent = imgui.ImVec4(0.40, 0.70, 1.00, 1)
local colGreen = imgui.ImVec4(0.30, 0.90, 0.45, 1)
local colRed = imgui.ImVec4(0.95, 0.35, 0.35, 1)
local colYellow = imgui.ImVec4(1.00, 0.80, 0.25, 1)
local colDim = imgui.ImVec4(0.55, 0.55, 0.60, 1)
local colHeader = imgui.ImVec4(0.18, 0.22, 0.30, 1)
local colHeaderHov = imgui.ImVec4(0.24, 0.30, 0.40, 1)
local colHeaderAct = imgui.ImVec4(0.30, 0.38, 0.50, 1)
local colSelectedBg = imgui.ImVec4(0.20, 0.35, 0.22, 0.45)
local colBtnPrimary = imgui.ImVec4(0.22, 0.45, 0.72, 1)
local colBtnPriHov = imgui.ImVec4(0.30, 0.55, 0.85, 1)
local colBtnPriAct = imgui.ImVec4(0.18, 0.38, 0.62, 1)

-- Helpers -----------------------------------------------------------------------------------------

local function getRuntime()
  local runtime = rawget(extensions, "overhaul_world_dynamicRoutes")
  if runtime then return runtime end
  -- Retained editor callbacks must not recreate a runtime after mod deactivation.
  local manager = rawget(_G, "overhaul_shell_extensionManager")
  if not manager or manager.canLoadOwners() ~= true then
    error("Dynamic routes runtime is unavailable while Overhaul is inactive.", 0)
  end
  local loaded = extensions.load("overhaul_world_dynamicRoutes")
  if loaded == false then error("Dynamic routes runtime load was refused.", 0) end
  runtime = rawget(extensions, "overhaul_world_dynamicRoutes")
  if not runtime then error("Dynamic routes runtime did not register after loading.", 0) end
  return runtime
end

local function show()
  editor.showWindow(TOOL_WINDOW_NAME)
end

local function openConfigPath(path)
  if not path or path == "" then return end
  Engine.Platform.exploreFolder(path:lower())
end

local function styledButton(label, size, tooltip)
  local pressed = imgui.Button(label, size)
  if tooltip and imgui.IsItemHovered() then imgui.SetTooltip(tooltip) end
  return pressed
end

local function primaryButton(label, size, tooltip)
  imgui.PushStyleColor2(imgui.Col_Button, colBtnPrimary)
  imgui.PushStyleColor2(imgui.Col_ButtonHovered, colBtnPriHov)
  imgui.PushStyleColor2(imgui.Col_ButtonActive, colBtnPriAct)
  local pressed = imgui.Button(label, size)
  imgui.PopStyleColor(3)
  if tooltip and imgui.IsItemHovered() then imgui.SetTooltip(tooltip) end
  return pressed
end

-- Generates the routes file from the scene, then reloads it; the notice reports either outcome.
local function generateRoutesFromScene()
  local ok, err = getRuntime().generateRoutesFile()
  if ok then
    getRuntime().reloadConfigAndRescan()
    editor.showNotification("Dynamic Routes: Routes file generated", 3, 0)
  else
    editor.showNotification("Dynamic Routes: " .. tostring(err), 5, 1)
  end
end

-- Parts -------------------------------------------------------------------------------------------

local function drawStatusBar(debugState)
  imgui.PushStyleVar2(imgui.StyleVar_ItemSpacing, imgui.ImVec2(12, 4))

  if debugState.rootFound then
    imgui.TextColored(colGreen, "ROOT")
  else
    imgui.TextColored(colRed, "NO ROOT")
  end
  imgui.SameLine()
  imgui.TextColored(colDim, "|")
  imgui.SameLine()

  imgui.TextColored(colAccent, tostring(debugState.groupCount or 0))
  imgui.SameLine()
  imgui.TextColored(colDim, "Groups")
  imgui.SameLine()
  imgui.TextColored(colDim, "|")
  imgui.SameLine()

  imgui.TextColored(colAccent, tostring(debugState.managedRoadCount or 0))
  imgui.SameLine()
  imgui.TextColored(colDim, "Roads")

  imgui.PopStyleVar(1)

  imgui.TextColored(colDim, debugState.configPath or "<unresolved>")
end

local function timerIdleReason(debugState)
  if not debugState.enabled then return "Timer disabled" end
  if not debugState.rootFound then return "Root group not found" end
  return "No groups loaded"
end

local function drawTimerSection(debugState)
  imgui.SeparatorText("Timer")

  local enabledPtr = imgui.BoolPtr(debugState.enabled == true)
  if imgui.Checkbox("Enabled", enabledPtr) then
    getRuntime().setEnabled(enabledPtr[0])
  end

  imgui.SameLine()
  imgui.SetNextItemWidth(100)
  local timerPtr = imgui.FloatPtr(tonumber(debugState.timerSeconds) or DEFAULT_TIMER_SECONDS)
  if imgui.InputFloat("##timer", timerPtr, 1, 10, "%.1f") then
    getRuntime().setTimerSeconds(timerPtr[0])
  end
  imgui.SameLine()
  imgui.TextColored(colDim, "sec")

  local elapsed = tonumber(debugState.elapsed) or 0
  local total = tonumber(debugState.timerSeconds) or DEFAULT_TIMER_SECONDS
  local fraction = (total > 0) and math.min(elapsed / total, 1) or 0
  local remaining = math.max(0, total - elapsed)
  local timerActive = debugState.enabled and debugState.rootFound and (debugState.groupCount or 0) > 0

  imgui.Spacing()
  if not timerActive then imgui.PushStyleColor2(imgui.Col_PlotHistogram, colDim) end
  imgui.ProgressBar(fraction, imgui.ImVec2(-1, 20), timerActive and string.format("%.1fs / %.1fs", elapsed, total) or "Paused")
  if not timerActive then imgui.PopStyleColor(1) end

  if imgui.IsItemHovered() then
    if timerActive then
      imgui.SetTooltip(string.format("%.1f seconds remaining until next trigger", remaining))
    else
      imgui.SetTooltip(timerIdleReason(debugState))
    end
  end
end

local function drawActions()
  imgui.SeparatorText("Actions")

  local buttonWidth = (imgui.GetContentRegionAvail().x - 12) / 4
  local buttonSize = imgui.ImVec2(buttonWidth, 26)

  if primaryButton("Trigger All", buttonSize, "Randomly select new options for all enabled groups") then
    getRuntime().triggerAllWeighted()
  end
  imgui.SameLine()
  if styledButton("Apply", buttonSize, "Re-apply current selections to the scene") then
    getRuntime().applyAllGroups()
  end
  imgui.SameLine()
  if styledButton("Rescan", buttonSize, "Reload config and rescan the scene tree") then
    getRuntime().reloadConfigAndRescan()
  end
  imgui.SameLine()
  if styledButton("Save", buttonSize, "Save current config to JSON") then
    local ok, err = getRuntime().saveConfig()
    if ok then
      editor.showNotification("Dynamic Routes: Config saved", 3, 0)
    else
      editor.showNotification("Dynamic Routes: Save failed - " .. tostring(err), 5, 1)
    end
  end
end

-- Option table columns: name and status, then the road count and weight.
local function drawOptionNameCells(option, isActive)
  imgui.TableSetColumnIndex(0)
  if isActive then imgui.TextColored(colGreen, option.name) else imgui.Text(option.name) end

  imgui.TableSetColumnIndex(1)
  if isActive then imgui.TextColored(colGreen, "Active") else imgui.TextColored(colDim, "Inactive") end

  imgui.TableSetColumnIndex(2)
  imgui.Text(tostring(option.roadCount or 0))
end

local function drawOptionWeightCells(groupName, option, totalWeight)
  imgui.TableSetColumnIndex(3)
  imgui.SetNextItemWidth(-1)
  local weightPtr = imgui.FloatPtr(tonumber(option.weight) or 1)
  if imgui.DragFloat("##w", weightPtr, 0.01, 0, 10, "%.2f") then
    getRuntime().setOptionWeight(groupName, option.name, weightPtr[0])
  end

  imgui.TableSetColumnIndex(4)
  local percent = 0
  if totalWeight and totalWeight > 0 then
    percent = (math.max(0, tonumber(option.weight) or 1) / totalWeight) * 100
  end
  imgui.TextColored(colDim, string.format("%.0f%%", percent))
end

-- An option may pin its own default drivability; the checkbox turns that pin on and off.
local function drawOptionDefaultCell(groupName, option)
  imgui.TableSetColumnIndex(5)
  local hasDefault = option.defaultDrivability ~= nil
  local hasDefaultPtr = imgui.BoolPtr(hasDefault)
  if imgui.Checkbox("##useDefault", hasDefaultPtr) then
    local drivability = hasDefaultPtr[0] and (tonumber(option.defaultDrivability) or 1) or nil
    getRuntime().setOptionDefaultDrivability(groupName, option.name, drivability)
  end
  if not hasDefault then return end

  imgui.SameLine()
  imgui.SetNextItemWidth(50)
  local defaultPtr = imgui.FloatPtr(tonumber(option.defaultDrivability) or 1)
  if imgui.DragFloat("##dv", defaultPtr, 0.01, -1, 10, "%.2f") then
    getRuntime().setOptionDefaultDrivability(groupName, option.name, defaultPtr[0])
  end
end

local function drawOptionActionCell(groupName, option, isActive)
  imgui.TableSetColumnIndex(6)
  if isActive then
    imgui.TextColored(colDim, "--")
    return
  end
  if imgui.SmallButton("Set") then
    getRuntime().setGroupOption(groupName, option.name)
  end
  if imgui.IsItemHovered() then imgui.SetTooltip("Activate this option") end
end

local function drawOptionRow(groupName, option, activeOptionName, totalWeight)
  local isActive = activeOptionName == option.name
  imgui.PushID1(groupName .. "::" .. option.name)

  imgui.TableNextRow()
  if isActive then imgui.TableSetBgColor(imgui.TableBgTarget_RowBg1, imgui.GetColorU322(colSelectedBg)) end

  drawOptionNameCells(option, isActive)
  drawOptionWeightCells(groupName, option, totalWeight)
  drawOptionDefaultCell(groupName, option)
  drawOptionActionCell(groupName, option, isActive)

  imgui.PopID()
end

-- Header and controls of one group; the header's colors are pushed only for its own label.
local function drawGroupHeader(group)
  imgui.PushStyleColor2(imgui.Col_Header, colHeader)
  imgui.PushStyleColor2(imgui.Col_HeaderHovered, colHeaderHov)
  imgui.PushStyleColor2(imgui.Col_HeaderActive, colHeaderAct)

  local totalRoads = 0
  for _, option in ipairs(group.options or {}) do
    totalRoads = totalRoads + (option.roadCount or 0)
  end
  local headerLabel = string.format("%s | %s | %d opts | %d roads###grp_%s",
    group.name,
    tostring(group.activeOptionName or "none"),
    group.optionCount or 0,
    totalRoads,
    group.name)

  local open = imgui.CollapsingHeader1(headerLabel)
  imgui.PopStyleColor(3)
  return open
end

local function drawGroupControls(group)
  local isEnabled = group.enabled ~= false
  local enabledPtr = imgui.BoolPtr(isEnabled)
  if imgui.Checkbox("Enabled##g_" .. group.name, enabledPtr) then
    getRuntime().setGroupEnabled(group.name, enabledPtr[0])
  end
  imgui.SameLine()
  imgui.TextColored(isEnabled and colGreen or colRed, isEnabled and "[ON]" or "[OFF]")

  imgui.SameLine()
  imgui.Dummy(imgui.ImVec2(8, 0))
  imgui.SameLine()
  if imgui.SmallButton("Trigger##" .. group.name) then
    getRuntime().triggerGroupWeighted(group.name)
  end
  if imgui.IsItemHovered() then imgui.SetTooltip("Randomly select a new option for this group") end
  imgui.SameLine()
  if imgui.SmallButton("Apply##" .. group.name) then
    getRuntime().setGroupOption(group.name, group.activeOptionName)
  end
  if imgui.IsItemHovered() then imgui.SetTooltip("Re-apply the current selection") end

  if tonumber(group.totalWeight) and group.totalWeight <= 0 then
    imgui.SameLine()
    imgui.TextColored(colYellow, "  Total weight <= 0!")
  end
end

local function drawOptionTable(group)
  local tableFlags = imgui.TableFlags_Borders
    + imgui.TableFlags_RowBg
    + imgui.TableFlags_SizingStretchProp
    + imgui.TableFlags_PadOuterX
  if not imgui.BeginTable("opts_" .. group.name, 7, tableFlags) then return end

  imgui.TableSetupColumn("Option", 0, 3.0)
  imgui.TableSetupColumn("Status", 0, 1.5)
  imgui.TableSetupColumn("Roads", 0, 1.0)
  imgui.TableSetupColumn("Weight", 0, 2.0)
  imgui.TableSetupColumn("%", 0, 1.0)
  imgui.TableSetupColumn("Default", 0, 2.5)
  imgui.TableSetupColumn("", 0, 1.0)
  imgui.TableHeadersRow()

  for _, option in ipairs(group.options or {}) do
    drawOptionRow(group.name, option, group.activeOptionName, group.totalWeight)
  end
  imgui.EndTable()
end

local function drawGroup(group)
  if not drawGroupHeader(group) then return end

  imgui.Indent(6)
  drawGroupControls(group)
  imgui.Spacing()
  drawOptionTable(group)
  imgui.Unindent(6)
  imgui.Spacing()
end

local function drawWarnings(debugState)
  if (debugState.warningCount or 0) <= 0 then return end

  imgui.PushStyleColor2(imgui.Col_Header, imgui.ImVec4(0.35, 0.25, 0.10, 1))
  imgui.PushStyleColor2(imgui.Col_HeaderHovered, imgui.ImVec4(0.45, 0.32, 0.15, 1))
  imgui.PushStyleColor2(imgui.Col_HeaderActive, imgui.ImVec4(0.50, 0.38, 0.18, 1))

  local warningHeader = string.format("Warnings (%d)###warnings", debugState.warningCount or 0)
  if imgui.CollapsingHeader1(warningHeader) then
    for _, warning in ipairs(debugState.warnings or {}) do
      imgui.TextColored(colYellow, "  -")
      imgui.SameLine()
      imgui.TextWrapped(warning)
    end
  end

  imgui.PopStyleColor(3)
end

local function drawMenuBar(debugState)
  if not imgui.BeginMenuBar() then return end
  if imgui.BeginMenu("Actions") then
    if not debugState.configFileExists and imgui.MenuItem1("Generate routes file") then
      generateRoutesFromScene()
    end
    if imgui.MenuItem1("Reload / Rescan") then getRuntime().reloadConfigAndRescan() end
    if imgui.MenuItem1("Trigger All Now") then getRuntime().triggerAllWeighted() end
    if imgui.MenuItem1("Apply Current State") then getRuntime().applyAllGroups() end
    imgui.Separator()
    if imgui.MenuItem1("Save JSON") then getRuntime().saveConfig() end
    if imgui.MenuItem1("Open JSON in Explorer") then openConfigPath(debugState.configPath) end
    imgui.EndMenu()
  end
  imgui.EndMenuBar()
end

-- Shown only while there is no routes file yet; it offers the same generate action as the menu.
local function drawMissingRoutesPrompt()
  imgui.Spacing()
  imgui.TextColored(colYellow, "No routes file found.")
  imgui.Spacing()
  if primaryButton("Generate routes file", imgui.ImVec2(-1, 28), "Create dynamicRoute.json from current scene") then
    generateRoutesFromScene()
  end
  imgui.Separator()
end

-- Editor window -----------------------------------------------------------------------------------

local function onEditorGui()
  if not editor.isWindowVisible(TOOL_WINDOW_NAME) then return end
  if not editor.beginWindow(TOOL_WINDOW_NAME, "Dynamic Routes", imgui.WindowFlags_MenuBar) then return end

  local debugState = getRuntime().getDebugState()
  drawMenuBar(debugState)
  drawStatusBar(debugState)
  if not debugState.configFileExists then drawMissingRoutesPrompt() end

  drawTimerSection(debugState)
  drawActions()
  drawWarnings(debugState)

  imgui.SeparatorText("Groups")
  for _, group in ipairs(debugState.groups or {}) do
    drawGroup(group)
  end

  editor.endWindow()
end

local function onEditorInitialized()
  editor.registerWindow(TOOL_WINDOW_NAME, imgui.ImVec2(860, 640))
  editor.addWindowMenuItem("Dynamic Routes", show, { groupMenuName = "Gameplay" })
  log("I", LOG_TAG, "Dynamic Routes editor window initialized")
end

-- Public API --------------------------------------------------------------------------------------

M.show = show

-- This window owns no scene resources; the routes runtime has its own lifetime.
function M.prepareForUnload()
  return true
end

-- Game hooks --------------------------------------------------------------------------------------

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onActivate = show

return M
