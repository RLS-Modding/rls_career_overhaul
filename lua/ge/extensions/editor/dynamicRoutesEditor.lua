local M = {}
local logTag = "editor_dynamicRoutesEditor"
local im = ui_imgui
local toolWindowName = "dynamicRoutesEditorTool"

local dynamicRoutesModule = require("ge/extensions/dynamicRoutes")

local function getRuntime()
  return (extensions and extensions.dynamicRoutes) or dynamicRoutesModule
end

local colAccent     = im.ImVec4(0.40, 0.70, 1.00, 1)
local colGreen      = im.ImVec4(0.30, 0.90, 0.45, 1)
local colRed        = im.ImVec4(0.95, 0.35, 0.35, 1)
local colYellow     = im.ImVec4(1.00, 0.80, 0.25, 1)
local colDim        = im.ImVec4(0.55, 0.55, 0.60, 1)
local colHeader     = im.ImVec4(0.18, 0.22, 0.30, 1)
local colHeaderHov  = im.ImVec4(0.24, 0.30, 0.40, 1)
local colHeaderAct  = im.ImVec4(0.30, 0.38, 0.50, 1)
local colSelectedBg = im.ImVec4(0.20, 0.35, 0.22, 0.45)
local colBtnPrimary = im.ImVec4(0.22, 0.45, 0.72, 1)
local colBtnPriHov  = im.ImVec4(0.30, 0.55, 0.85, 1)
local colBtnPriAct  = im.ImVec4(0.18, 0.38, 0.62, 1)

local function show()
  editor.showWindow(toolWindowName)
end

local function openConfigPath(path)
  if not path or path == "" then return end
  if Engine and Engine.Platform and Engine.Platform.exploreFolder then
    Engine.Platform.exploreFolder(path:lower())
  end
end

local function styledButton(label, size, tooltip)
  local pressed = im.Button(label, size)
  if tooltip and im.IsItemHovered() then
    im.SetTooltip(tooltip)
  end
  return pressed
end

local function primaryButton(label, size, tooltip)
  im.PushStyleColor2(im.Col_Button, colBtnPrimary)
  im.PushStyleColor2(im.Col_ButtonHovered, colBtnPriHov)
  im.PushStyleColor2(im.Col_ButtonActive, colBtnPriAct)
  local pressed = im.Button(label, size)
  im.PopStyleColor(3)
  if tooltip and im.IsItemHovered() then
    im.SetTooltip(tooltip)
  end
  return pressed
end

local function drawStatusBar(debugState)
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(12, 4))

  if debugState.rootFound then
    im.TextColored(colGreen, "ROOT")
  else
    im.TextColored(colRed, "NO ROOT")
  end
  im.SameLine()
  im.TextColored(colDim, "|")
  im.SameLine()

  im.TextColored(colAccent, tostring(debugState.groupCount or 0))
  im.SameLine()
  im.TextColored(colDim, "Groups")
  im.SameLine()
  im.TextColored(colDim, "|")
  im.SameLine()

  im.TextColored(colAccent, tostring(debugState.managedRoadCount or 0))
  im.SameLine()
  im.TextColored(colDim, "Roads")

  im.PopStyleVar(1)

  im.TextColored(colDim, debugState.configPath or "<unresolved>")
end

local function drawTimerSection(debugState)
  im.SeparatorText("Timer")

  local enabledPtr = im.BoolPtr(debugState.enabled == true)
  if im.Checkbox("Enabled", enabledPtr) then
    getRuntime().setEnabled(enabledPtr[0])
  end

  im.SameLine()
  im.SetNextItemWidth(100)
  local timerPtr = im.FloatPtr(tonumber(debugState.timerSeconds) or 60)
  if im.InputFloat("##timer", timerPtr, 1, 10, "%.1f") then
    getRuntime().setTimerSeconds(timerPtr[0])
  end
  im.SameLine()
  im.TextColored(colDim, "sec")

  local elapsed = tonumber(debugState.elapsed) or 0
  local total = tonumber(debugState.timerSeconds) or 60
  local frac = (total > 0) and math.min(elapsed / total, 1) or 0
  local remaining = math.max(0, total - elapsed)
  local timerActive = debugState.enabled and debugState.rootFound and (debugState.groupCount or 0) > 0

  im.Spacing()
  if not timerActive then
    im.PushStyleColor2(im.Col_PlotHistogram, colDim)
  end
  im.ProgressBar(frac, im.ImVec2(-1, 20), timerActive and string.format("%.1fs / %.1fs", elapsed, total) or "Paused")
  if not timerActive then
    im.PopStyleColor(1)
  end
  if im.IsItemHovered() then
    if not timerActive then
      local reason = not debugState.enabled and "Timer disabled" or (not debugState.rootFound and "Root group not found" or "No groups loaded")
      im.SetTooltip(reason)
    else
      im.SetTooltip(string.format("%.1f seconds remaining until next trigger", remaining))
    end
  end
end

local function drawActions(debugState)
  im.SeparatorText("Actions")

  local btnW = (im.GetContentRegionAvail().x - 12) / 4
  local btnSize = im.ImVec2(btnW, 26)

  if primaryButton("Trigger All", btnSize, "Randomly select new options for all enabled groups") then
    getRuntime().triggerAllWeighted()
  end
  im.SameLine()
  if styledButton("Apply", btnSize, "Re-apply current selections to the scene") then
    getRuntime().applyAllGroups()
  end
  im.SameLine()
  if styledButton("Rescan", btnSize, "Reload config and rescan the scene tree") then
    getRuntime().reloadConfigAndRescan()
  end
  im.SameLine()
  if styledButton("Save", btnSize, "Save current config to JSON") then
    local ok, err = getRuntime().saveConfig()
    if not ok then
      editor.showNotification("Dynamic Routes: Save failed - " .. tostring(err), 5, 1)
    else
      editor.showNotification("Dynamic Routes: Config saved", 3, 0)
    end
  end
end

local function drawOptionRow(groupName, option, activeOptionName, totalWeight)
  local isActive = activeOptionName == option.name
  im.PushID1(groupName .. "::" .. option.name)

  im.TableNextRow()

  if isActive then
    im.TableSetBgColor(im.TableBgTarget_RowBg1, im.GetColorU322(colSelectedBg))
  end

  im.TableSetColumnIndex(0)
  if isActive then
    im.TextColored(colGreen, option.name)
  else
    im.Text(option.name)
  end

  im.TableSetColumnIndex(1)
  if isActive then
    im.TextColored(colGreen, "Active")
  else
    im.TextColored(colDim, "Inactive")
  end

  im.TableSetColumnIndex(2)
  im.Text(tostring(option.roadCount or 0))

  im.TableSetColumnIndex(3)
  im.SetNextItemWidth(-1)
  local weightPtr = im.FloatPtr(tonumber(option.weight) or 1)
  if im.DragFloat("##w", weightPtr, 0.01, 0, 10, "%.2f") then
    getRuntime().setOptionWeight(groupName, option.name, weightPtr[0])
  end

  im.TableSetColumnIndex(4)
  local pct = 0
  if totalWeight and totalWeight > 0 then
    pct = (math.max(0, tonumber(option.weight) or 1) / totalWeight) * 100
  end
  im.TextColored(colDim, string.format("%.0f%%", pct))

  im.TableSetColumnIndex(5)
  local hasDefault = option.defaultDrivability ~= nil
  local hasDefaultPtr = im.BoolPtr(hasDefault)
  if im.Checkbox("##useDefault", hasDefaultPtr) then
    if hasDefaultPtr[0] then
      getRuntime().setOptionDefaultDrivability(groupName, option.name, tonumber(option.defaultDrivability) or 1)
    else
      getRuntime().setOptionDefaultDrivability(groupName, option.name, nil)
    end
  end
  if hasDefault then
    im.SameLine()
    im.SetNextItemWidth(50)
    local defaultPtr = im.FloatPtr(tonumber(option.defaultDrivability) or 1)
    if im.DragFloat("##dv", defaultPtr, 0.01, -1, 10, "%.2f") then
      getRuntime().setOptionDefaultDrivability(groupName, option.name, defaultPtr[0])
    end
  end

  im.TableSetColumnIndex(6)
  if not isActive then
    if im.SmallButton("Set") then
      getRuntime().setGroupOption(groupName, option.name)
    end
    if im.IsItemHovered() then
      im.SetTooltip("Activate this option")
    end
  else
    im.TextColored(colDim, "--")
  end

  im.PopID()
end

local function drawGroup(group)
  im.PushStyleColor2(im.Col_Header, colHeader)
  im.PushStyleColor2(im.Col_HeaderHovered, colHeaderHov)
  im.PushStyleColor2(im.Col_HeaderActive, colHeaderAct)

  local totalRoads = 0
  for _, option in ipairs(group.options or {}) do
    totalRoads = totalRoads + (option.roadCount or 0)
  end

  local statusIcon = group.enabled ~= false and "[ON]" or "[OFF]"
  local statusColor = group.enabled ~= false and colGreen or colRed

  local headerLabel = string.format("%s | %s | %d opts | %d roads###grp_%s",
    group.name,
    tostring(group.activeOptionName or "none"),
    group.optionCount or 0,
    totalRoads,
    group.name)

  local open = im.CollapsingHeader1(headerLabel)
  im.PopStyleColor(3)

  if not open then return end

  im.Indent(6)

  local enabledPtr = im.BoolPtr(group.enabled ~= false)
  if im.Checkbox("Enabled##g_" .. group.name, enabledPtr) then
    getRuntime().setGroupEnabled(group.name, enabledPtr[0])
  end
  im.SameLine()
  im.TextColored(statusColor, statusIcon)

  im.SameLine()
  im.Dummy(im.ImVec2(8, 0))
  im.SameLine()
  if im.SmallButton("Trigger##" .. group.name) then
    getRuntime().triggerGroupWeighted(group.name)
  end
  if im.IsItemHovered() then
    im.SetTooltip("Randomly select a new option for this group")
  end
  im.SameLine()
  if im.SmallButton("Apply##" .. group.name) then
    getRuntime().setGroupOption(group.name, group.activeOptionName)
  end
  if im.IsItemHovered() then
    im.SetTooltip("Re-apply the current selection")
  end

  if tonumber(group.totalWeight) and group.totalWeight <= 0 then
    im.SameLine()
    im.TextColored(colYellow, "  Total weight <= 0!")
  end

  im.Spacing()

  local tableFlags = im.TableFlags_Borders
    + im.TableFlags_RowBg
    + im.TableFlags_SizingStretchProp
    + im.TableFlags_PadOuterX

  if im.BeginTable("opts_" .. group.name, 7, tableFlags) then
    im.TableSetupColumn("Option",   0, 3.0)
    im.TableSetupColumn("Status",   0, 1.5)
    im.TableSetupColumn("Roads",    0, 1.0)
    im.TableSetupColumn("Weight",   0, 2.0)
    im.TableSetupColumn("%",        0, 1.0)
    im.TableSetupColumn("Default",  0, 2.5)
    im.TableSetupColumn("",         0, 1.0)
    im.TableHeadersRow()

    for _, option in ipairs(group.options or {}) do
      drawOptionRow(group.name, option, group.activeOptionName, group.totalWeight)
    end

    im.EndTable()
  end

  im.Unindent(6)
  im.Spacing()
end

local function drawWarnings(debugState)
  if (debugState.warningCount or 0) <= 0 then return end

  im.PushStyleColor2(im.Col_Header, im.ImVec4(0.35, 0.25, 0.10, 1))
  im.PushStyleColor2(im.Col_HeaderHovered, im.ImVec4(0.45, 0.32, 0.15, 1))
  im.PushStyleColor2(im.Col_HeaderActive, im.ImVec4(0.50, 0.38, 0.18, 1))

  local warnHeader = string.format("Warnings (%d)###warnings", debugState.warningCount or 0)
  if im.CollapsingHeader1(warnHeader) then
    for _, warning in ipairs(debugState.warnings or {}) do
      im.TextColored(colYellow, "  -")
      im.SameLine()
      im.TextWrapped(warning)
    end
  end

  im.PopStyleColor(3)
end

local function onEditorGui()
  if not editor.isWindowVisible(toolWindowName) then return end

  if editor.beginWindow(toolWindowName, "Dynamic Routes", im.WindowFlags_MenuBar) then
    local debugState = getRuntime().getDebugState()

    if im.BeginMenuBar() then
      if im.BeginMenu("Actions") then
        if not debugState.configFileExists and im.MenuItem1("Generate routes file") then
          local ok, err = getRuntime().generateRoutesFile()
          if ok then
            getRuntime().reloadConfigAndRescan()
            editor.showNotification("Dynamic Routes: Routes file generated", 3, 0)
          else
            editor.showNotification("Dynamic Routes: " .. tostring(err), 5, 1)
          end
        end
        if im.MenuItem1("Reload / Rescan") then getRuntime().reloadConfigAndRescan() end
        if im.MenuItem1("Trigger All Now") then getRuntime().triggerAllWeighted() end
        if im.MenuItem1("Apply Current State") then getRuntime().applyAllGroups() end
        im.Separator()
        if im.MenuItem1("Save JSON") then getRuntime().saveConfig() end
        if im.MenuItem1("Open JSON in Explorer") then openConfigPath(debugState.configPath) end
        im.EndMenu()
      end
      im.EndMenuBar()
    end

    drawStatusBar(debugState)

    if not debugState.configFileExists then
      im.Spacing()
      im.TextColored(colYellow, "No routes file found.")
      im.Spacing()
      if primaryButton("Generate routes file", im.ImVec2(-1, 28), "Create dynamicRoute.json from current scene") then
        local ok, err = getRuntime().generateRoutesFile()
        if ok then
          getRuntime().reloadConfigAndRescan()
          editor.showNotification("Dynamic Routes: Routes file generated", 3, 0)
        else
          editor.showNotification("Dynamic Routes: " .. tostring(err), 5, 1)
        end
      end
      im.Separator()
    end

    drawTimerSection(debugState)
    drawActions(debugState)
    drawWarnings(debugState)

    im.SeparatorText("Groups")
    for _, group in ipairs(debugState.groups or {}) do
      drawGroup(group)
    end

    editor.endWindow()
  end
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(860, 640))
  editor.addWindowMenuItem("Dynamic Routes", show, {groupMenuName = "Gameplay"})
  log("I", logTag, "Dynamic Routes editor window initialized")
end

local function onActivate()
  show()
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onActivate = onActivate
M.show = show

return M
