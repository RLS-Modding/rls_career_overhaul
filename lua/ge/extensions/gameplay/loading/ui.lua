local M = {}

local Config = nil
local uiAnim = { opacity = 0, yOffset = 50, pulse = 0, targetOpacity = 0 }
local uiHidden = false
local markerAnim = { time = 0, pulseScale = 1.0, rotationAngle = 0, beamHeight = 0, ringExpand = 0 }
local debugOBBEnabled = false

local imgui = ui_imgui

local function lerp(a, b, t) return a + (b - a) * t end

local function getMixedContractBreakdown(contract)
  if not contract or contract.unitType ~= "item" or not contract.materialTypeName then
    return nil
  end

  if contract.materialRequirements and next(contract.materialRequirements) ~= nil then
    return contract.materialRequirements
  end

  return nil
end

local function drawWorkSiteMarker(dt, currentState, stateDrivingToSite, markerCleared, activeGroup)
  if currentState ~= stateDrivingToSite or markerCleared or not activeGroup or not activeGroup.loading then return end
  
  Config = gameplay_loading_config
  local uiSettings = Config.settings.ui or {}
  local pulseSpeed = uiSettings.markerPulseSpeed or 2.5
  local rotationSpeed = uiSettings.markerRotationSpeed or 0.4
  local beamSpeed = uiSettings.markerBeamSpeed or 30.0
  local maxBeamHeight = uiSettings.markerMaxBeamHeight or 12.0
  local ringSpeed = uiSettings.markerRingExpandSpeed or 1.5

  markerAnim.time = markerAnim.time + dt
  markerAnim.pulseScale = 1.0 + math.sin(markerAnim.time * pulseSpeed) * 0.1
  markerAnim.rotationAngle = markerAnim.rotationAngle + dt * rotationSpeed
  markerAnim.beamHeight = math.min(maxBeamHeight, markerAnim.beamHeight + dt * beamSpeed)
  markerAnim.ringExpand = (markerAnim.ringExpand + dt * ringSpeed) % ringSpeed

  local basePos = vec3(activeGroup.loading.center)
  local color = ColorF(0.2, 1.0, 0.4, 0.85)
  local colorFaded = ColorF(0.2, 1.0, 0.4, 0.3)
  local beamTop = basePos + vec3(0, 0, markerAnim.beamHeight)
  local beamRadius = 0.5 * markerAnim.pulseScale

  debugDrawer:drawCylinder(basePos, beamTop, beamRadius, color)
  debugDrawer:drawCylinder(basePos, beamTop, beamRadius + 0.2, colorFaded)

  local sphereRadius = 1.0 * markerAnim.pulseScale
  debugDrawer:drawSphere(beamTop, sphereRadius, color)
  debugDrawer:drawSphere(beamTop, sphereRadius + 0.3, ColorF(0.2, 1.0, 0.4, 0.15))
end

local function drawZoneChoiceMarkers(dt, currentState, stateChoosingZone, compatibleZones)
  if currentState ~= stateChoosingZone or #compatibleZones == 0 then return end

  Config = gameplay_loading_config
  local uiSettings = Config.settings.ui or {}
  local pulseSpeed = uiSettings.zoneMarkerPulseSpeed or 2.5
  local beamSpeed = uiSettings.markerBeamSpeed or 30.0
  local maxBeamHeight = uiSettings.zoneMarkerMaxBeamHeight or 15.0

  markerAnim.time = markerAnim.time + dt
  markerAnim.pulseScale = 1.0 + math.sin(markerAnim.time * pulseSpeed) * 0.15
  markerAnim.beamHeight = math.min(maxBeamHeight, markerAnim.beamHeight + dt * beamSpeed)

  for i, zone in ipairs(compatibleZones) do
    if zone.loading and zone.loading.center then
      local basePos = vec3(zone.loading.center)
      local hue = (i - 1) / math.max(1, #compatibleZones)
      local r = 0.3 + 0.7 * math.abs(math.sin(hue * 3.14159))
      local g = 0.8 + 0.2 * math.sin(markerAnim.time * 2)
      local b = 0.3 + 0.7 * math.abs(math.cos(hue * 3.14159))
      
      local color = ColorF(r, g, b, 0.85)
      local colorFaded = ColorF(r, g, b, 0.3)
      local beamTop = basePos + vec3(0, 0, markerAnim.beamHeight)
      local beamRadius = 0.6 * markerAnim.pulseScale

      debugDrawer:drawCylinder(basePos, beamTop, beamRadius, color)
      debugDrawer:drawCylinder(basePos, beamTop, beamRadius + 0.25, colorFaded)

      local sphereRadius = 1.2 * markerAnim.pulseScale
      debugDrawer:drawSphere(beamTop, sphereRadius, color)
      debugDrawer:drawSphere(beamTop, sphereRadius + 0.4, ColorF(r, g, b, 0.15))
      
      local textPos = beamTop + vec3(0, 0, 2)
      local materialNames = {}
      if zone.materials then
        for _, matKey in ipairs(zone.materials) do
          local matConfig = Config.materials and Config.materials[matKey]
          local matName = matConfig and matConfig.name or matKey
          table.insert(materialNames, matName)
        end
      elseif zone.materialType then
        local matConfig = Config.materials and Config.materials[zone.materialType]
        local matName = matConfig and matConfig.name or zone.materialType
        table.insert(materialNames, matName)
      end
      if #materialNames == 0 then return end
      local materialsStr = table.concat(materialNames, ", ")
      local text = string.format("%s (%s)", zone.secondaryTag or "Zone", materialsStr)
      debugDrawer:drawTextAdvanced(textPos, text, ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 200))
    end
  end
end

local function getQuarryStateForUI(currentState, playerMod, contractsMod, managerMod, zonesMod)
  local contractsForUI = {}
  Config = gameplay_loading_config
  for i, c in ipairs(contractsMod.ContractSystem.availableContracts or {}) do
    table.insert(contractsForUI, {
      id = c.id, name = c.name, tier = c.tier, material = c.material,
      materialTypeName = c.materialTypeName,
      requiredTons = c.requiredTons, requiredItems = c.requiredItems,
      isBulk = c.isBulk, totalPayout = c.totalPayout, paymentType = c.paymentType,
      groupTag = c.groupTag, estimatedTrips = c.estimatedTrips,
      expiresAtSimTime = c.expiresAtSimTime,
      hoursRemaining = contractsMod.getContractHoursRemaining(c), expirationHours = c.expirationHours,
      destinationName = c.destination and c.destination.name or nil,
      originZoneTag = c.destination and c.destination.originZoneTag or c.groupTag,
    })
  end

  local activeContractForUI = nil
  if contractsMod.ContractSystem.activeContract then
    local c = contractsMod.ContractSystem.activeContract
    activeContractForUI = {
      id = c.id, name = c.name, tier = c.tier, material = c.material,
      materialTypeName = c.materialTypeName,
      requiredTons = c.requiredTons, requiredItems = c.requiredItems,
      totalPayout = c.totalPayout, paymentType = c.paymentType,
      groupTag = c.groupTag, estimatedTrips = c.estimatedTrips,
      loadingZoneTag = c.loadingZoneTag,
      destinationName = c.destination and c.destination.name or nil,
    }
  end

  return {
    state = currentState,
    contractsCompleted = contractsMod.PlayerData.contractsCompleted or 0,
    availableContracts = contractsForUI,
    activeContract = activeContractForUI,
    contractProgress = {
      deliveredTons = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.deliveredTons or 0,
      totalPaidSoFar = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.totalPaidSoFar or 0,
      deliveredBlocks = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.deliveredBlocks or { big = 0, small = 0, total = 0 },
      deliveryCount = contractsMod.ContractSystem.contractProgress and contractsMod.ContractSystem.contractProgress.deliveryCount or 0
    },
    currentLoadMass = managerMod.jobObjects.currentLoadMass or 0,
    targetLoad = (function()
      local matType = managerMod.jobObjects.materialType
      if matType and Config.materials and Config.materials[matType] then
        local matConfig = Config.materials[matType]
        if matConfig.unitType == "mass" then
          return matConfig.targetLoad or 25000
        end
      end
      return nil
    end)(),
    materialType = managerMod.jobObjects.materialType or nil,
    itemBlocks = (managerMod.jobObjects.materialType ~= "rocks") and managerMod.getItemBlocksStatus() or {},
    anyItemDamaged = managerMod.jobObjects.anyItemDamaged or false,
    deliveryBlocks = managerMod.jobObjects.deliveryBlocksStatus or {},
    markerCleared = managerMod.markerCleared,
    truckStopped = managerMod.truckStoppedInLoading,
    zoneStock = managerMod.jobObjects.activeGroup and zonesMod.getZoneStockInfo(managerMod.jobObjects.activeGroup, contractsMod.getCurrentGameHour) or nil
  }
end

local function requestQuarryState(currentState, playerMod, contractsMod, managerMod, zonesMod)
  guihooks.trigger('updateQuarryState', getQuarryStateForUI(currentState, playerMod, contractsMod, managerMod, zonesMod))
end

local function drawUI(dt, currentState, configStates, playerMod, contractsMod, managerMod, zonesMod, callbacks)
  if not imgui then return end
  Config = gameplay_loading_config
  if not Config then
    print("Error: Config not found")
    return
  end
  local devMode = Config.settings and Config.settings.devMode or false
  if not devMode then return end

  if uiHidden and currentState ~= configStates.STATE_IDLE then
    imgui.SetNextWindowPos(imgui.ImVec2(10, 200), imgui.Cond_FirstUseEver)
    imgui.PushStyleVar1(imgui.StyleVar_WindowRounding, 8)
    imgui.PushStyleColor2(imgui.Col_WindowBg, imgui.ImVec4(0.1, 0.1, 0.12, 0.9))
    if imgui.Begin("##WL40Show", nil, imgui.WindowFlags_NoTitleBar + imgui.WindowFlags_AlwaysAutoResize + imgui.WindowFlags_NoCollapse) then
      imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.2, 0.4, 0.2, 0.9))
      imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.3, 0.6, 0.3, 1))
      if imgui.Button("Show Job UI", imgui.ImVec2(100, 30)) then uiHidden = false end
      imgui.PopStyleColor(2)
    end
    imgui.End()
    imgui.PopStyleColor(1)
    imgui.PopStyleVar(1)
    return
  end

  local uiSettings = Config.settings.ui or {}
  local animSpeed = uiSettings.animationSpeed or 8.0
  local pulseSpeed = uiSettings.pulseSpeed or 5.0

  uiAnim.targetOpacity = (currentState ~= configStates.STATE_IDLE) and 1.0 or 0.0
  uiAnim.opacity = lerp(uiAnim.opacity, uiAnim.targetOpacity, dt * animSpeed)
  uiAnim.yOffset = lerp(uiAnim.yOffset, (1.0 - uiAnim.opacity) * 50, dt * animSpeed)
  if uiAnim.opacity < 0.01 then return end

  uiAnim.pulse = uiAnim.pulse + dt * pulseSpeed
  local pulseAlpha = (math.sin(uiAnim.pulse) * 0.3) + 0.7

  imgui.PushStyleVar2(imgui.StyleVar_WindowPadding, imgui.ImVec2(20, 20))
  imgui.PushStyleVar1(imgui.StyleVar_WindowRounding, 12)
  imgui.PushStyleColor2(imgui.Col_WindowBg, imgui.ImVec4(0.1, 0.1, 0.12, 0.95 * uiAnim.opacity))
  imgui.PushStyleColor2(imgui.Col_Border, imgui.ImVec4(1.0, 0.7, 0.0, 0.8 * uiAnim.opacity))
  imgui.PushStyleVar1(imgui.StyleVar_WindowBorderSize, 2)
  imgui.SetNextWindowBgAlpha(0.95 * uiAnim.opacity)
  imgui.SetNextWindowSizeConstraints(imgui.ImVec2(280, 100), imgui.ImVec2(350, 800))

  if imgui.Begin("##WL40System", nil, imgui.WindowFlags_NoTitleBar + imgui.WindowFlags_AlwaysAutoResize + imgui.WindowFlags_NoCollapse) then
    local windowWidth = imgui.GetWindowWidth()
    imgui.SetCursorPosX(windowWidth - 30)
    imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.5, 0.2, 0.2, 0.8 * uiAnim.opacity))
    imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.7, 0.2, 0.2, 1))
    if imgui.Button("X", imgui.ImVec2(20, 20)) then uiHidden = true end
    imgui.PopStyleColor(2)
    imgui.SetCursorPosX(0)
    
    imgui.SetWindowFontScale(1.5)
    imgui.TextColored(imgui.ImVec4(1, 0.75, 0, uiAnim.opacity), " LOGISTICS JOB SYSTEM")
    imgui.SetWindowFontScale(1.0)
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 10))

    local contentWidth = imgui.GetContentRegionAvailWidth()

    if currentState == configStates.STATE_CONTRACT_SELECT then
      imgui.TextColored(imgui.ImVec4(1, 1, 1, uiAnim.opacity), "Available Contracts")
      imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, uiAnim.opacity), string.format("Completed: %d", contractsMod.PlayerData.contractsCompleted or 0))
      imgui.Dummy(imgui.ImVec2(0, 10))

      if #contractsMod.ContractSystem.availableContracts == 0 then
        imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, uiAnim.opacity), "No contracts available")
      else
        local tierColors = { imgui.ImVec4(0.5, 0.8, 0.5, 1), imgui.ImVec4(0.5, 0.7, 1.0, 1), imgui.ImVec4(1.0, 0.7, 0.4, 1), imgui.ImVec4(1.0, 0.4, 0.4, 1) }
        for i, c in ipairs(contractsMod.ContractSystem.availableContracts) do
          imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.15, 0.15, 0.2, 0.9))
          imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.25, 0.25, 0.35, 1))
          imgui.PushStyleColor2(imgui.Col_ButtonActive, imgui.ImVec4(0.3, 0.3, 0.4, 1))
          if imgui.Button(string.format("[%d] %s##contract%d", i, c.name or "Contract", i), imgui.ImVec2(contentWidth, 0)) then callbacks.onAcceptContract(i) end
          imgui.PopStyleColor(3)

          imgui.Indent(20)
          local typeName = c.materialTypeName
          if not typeName and c.material and Config.materials and Config.materials[c.material] then
            typeName = Config.materials[c.material].typeName
          end
          typeName = typeName or "Unknown"
          imgui.TextColored(tierColors[c.tier or 1] or imgui.ImVec4(1, 1, 1, 1), string.format("Tier %d | %s", c.tier or 1, typeName))
          imgui.SameLine()
          imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1), string.format("  $%d", c.totalPayout or 0))
          
          if c.unitType == "item" then
            local breakdown = getMixedContractBreakdown(c)
            if breakdown then
              local parts = {}
              for matKey, count in pairs(breakdown) do
                if count > 0 then
                  local matConfig = Config.materials and Config.materials[matKey]
                  local matName = matConfig and matConfig.name or matKey
                  table.insert(parts, string.format("%d %s", count, matName))
                end
              end
              if #parts > 0 then
                imgui.TextColored(imgui.ImVec4(0.8, 0.9, 1.0, 1), "* " .. table.concat(parts, " and "))
              else
                imgui.TextColored(imgui.ImVec4(0.8, 0.9, 1.0, 1), string.format("* %d %s total", c.requiredItems or 0, c.units or "items"))
              end
            else
              imgui.TextColored(imgui.ImVec4(0.8, 0.9, 1.0, 1), string.format("* %d %s total", c.requiredItems or 0, c.units or "items"))
            end
          else
            imgui.Text(string.format("* %d %s total", c.requiredTons or 0, c.units or "tons"))
          end
          imgui.Text(string.format("* Payment: %s", (c.paymentType == "progressive") and "Progressive" or "On completion"))
          
          local hoursLeft = contractsMod.getContractHoursRemaining(c)
          if c.expirationHours then
            local expiresSoonThreshold = c.expirationHours * 0.2
            if hoursLeft <= expiresSoonThreshold then imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, 1), string.format("* EXPIRES SOON: %d min", math.floor(hoursLeft * 60)))
            elseif hoursLeft <= 2 then imgui.TextColored(imgui.ImVec4(1, 0.7, 0.3, 1), string.format("* Expires in: %.1f hrs", hoursLeft))
            else imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), string.format("* Expires in: %.0f hrs", hoursLeft)) end
          else
            if hoursLeft <= 2 then imgui.TextColored(imgui.ImVec4(1, 0.7, 0.3, 1), string.format("* Expires in: %.1f hrs", hoursLeft))
            else imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), string.format("* Expires in: %.0f hrs", hoursLeft)) end
          end
          imgui.Unindent(20); imgui.Dummy(imgui.ImVec2(0, 8))
          if i < #contractsMod.ContractSystem.availableContracts then imgui.Separator(); imgui.Dummy(imgui.ImVec2(0, 5)) end
        end
      end
      imgui.Dummy(imgui.ImVec2(0, 10))
      imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.5, 0.1, 0.1, uiAnim.opacity))
      imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.7, 0.1, 0.1, uiAnim.opacity))
      if imgui.Button("DECLINE ALL", imgui.ImVec2(-1, 35)) then callbacks.onDeclineAll() end
      imgui.PopStyleColor(2)

    elseif currentState == configStates.STATE_CHOOSING_ZONE then
      imgui.TextColored(imgui.ImVec4(1, 0.8, 0.2, pulseAlpha * uiAnim.opacity), ">> CHOOSE LOADING ZONE <<")
      imgui.Dummy(imgui.ImVec2(0, 5))
      if contractsMod.ContractSystem.activeContract then
        local c = contractsMod.ContractSystem.activeContract
        imgui.Text(string.format("Contract: %s", c.name or "Contract"))
        local typeName = c.materialTypeName or (c.material and Config.materials and Config.materials[c.material] and Config.materials[c.material].typeName) or "Unknown"
        imgui.Text(string.format("Material type needed: %s", typeName))
        imgui.Dummy(imgui.ImVec2(0, 8))
      end
      imgui.TextColored(imgui.ImVec4(0.7, 1, 0.7, uiAnim.opacity), "Select a loading zone:")
      imgui.Dummy(imgui.ImVec2(0, 5))
      
      local compatibleZones = callbacks.getCompatibleZones()
      if #compatibleZones == 0 then
        imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, uiAnim.opacity), "No compatible zones available!")
      else
        for i, zone in ipairs(compatibleZones) do
          local dist = be:getPlayerVehicle(0) and (be:getPlayerVehicle(0):getPosition() - vec3(zone.loading.center)):length() or 0
          local hue = (i - 1) / math.max(1, #compatibleZones)
          local buttonColor = imgui.ImVec4(0.3 + 0.7 * math.abs(math.sin(hue * 3.14159)), 0.8, 0.3 + 0.7 * math.abs(math.cos(hue * 3.14159)), uiAnim.opacity)
          
          local materialNames = {}
          if zone.materials then
            for _, matKey in ipairs(zone.materials) do
              local matConfig = Config.materials and Config.materials[matKey]
              local matName = matConfig and matConfig.name or matKey
              table.insert(materialNames, matName)
            end
          elseif zone.materialType then
            local matConfig = Config.materials and Config.materials[zone.materialType]
            local matName = matConfig and matConfig.name or zone.materialType
            table.insert(materialNames, matName)
          end
          local materialsStr = #materialNames > 0 and table.concat(materialNames, ", ") or "Unknown"
          
          local stockInfo = zonesMod.getZoneStockInfo and zonesMod.getZoneStockInfo(zone, contractsMod.getCurrentGameHour)
          local stockText = ""
          if stockInfo and stockInfo.materialStocks then
            local stockParts = {}
            for matKey, stock in pairs(stockInfo.materialStocks) do
              local matConfig = Config.materials and Config.materials[matKey]
              local matName = matConfig and matConfig.name or matKey
              table.insert(stockParts, string.format("%s: %d/%d", matName, stock.current, stock.max))
            end
            if #stockParts > 0 then
              stockText = " | Stock: " .. table.concat(stockParts, ", ")
            end
          end
          
          imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(buttonColor.x * 0.3, buttonColor.y * 0.3, buttonColor.z * 0.3, 0.8 * uiAnim.opacity))
          imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(buttonColor.x * 0.5, buttonColor.y * 0.5, buttonColor.z * 0.5, 1))
          imgui.PushStyleColor2(imgui.Col_ButtonActive, imgui.ImVec4(buttonColor.x * 0.7, buttonColor.y * 0.7, buttonColor.z * 0.7, 1))
          
          local buttonText = string.format("%s (%s) - %.0fm%s", zone.secondaryTag or "Zone", materialsStr, dist, stockText)
          if imgui.Button(buttonText, imgui.ImVec2(-1, 0)) then
            callbacks.onSelectZone(i)
          end
          imgui.PopStyleColor(3)
          if i < #compatibleZones then
            imgui.Dummy(imgui.ImVec2(0, 3))
          end
        end
      end
      
      imgui.Dummy(imgui.ImVec2(0, 15))
      imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.5, 0.1, 0.1, uiAnim.opacity))
      imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.7, 0.1, 0.1, uiAnim.opacity))
      if imgui.Button("ABANDON CONTRACT", imgui.ImVec2(-1, 30)) then callbacks.onAbandonContract() end
      imgui.PopStyleColor(2)

    elseif currentState == configStates.STATE_DRIVING_TO_SITE then
      if managerMod.jobObjects.activeGroup and managerMod.jobObjects.activeGroup.loading then
        if not managerMod.markerCleared then
          imgui.TextColored(imgui.ImVec4(1, 1, 0, pulseAlpha * uiAnim.opacity), ">> DRIVE TO ZONE <<")
          local dist = be:getPlayerVehicle(0) and (be:getPlayerVehicle(0):getPosition() - vec3(managerMod.jobObjects.activeGroup.loading.center)):length() or 99999
          imgui.ProgressBar(1.0 - math.min(1, dist / 200), imgui.ImVec2(-1, 20), string.format("%.0fm", dist))
        else
          imgui.TextColored(imgui.ImVec4(1, 1, 0, pulseAlpha * uiAnim.opacity), ">> IN LOADING ZONE <<")
          imgui.Text(not managerMod.truckStoppedInLoading and "Waiting for truck to arrive..." or "Truck arrived. Ready to load.")
        end
      end
      imgui.Dummy(imgui.ImVec2(0, 10))
      if imgui.Button("ABANDON CONTRACT", imgui.ImVec2(-1, 30)) then callbacks.onAbandonContract() end

    elseif currentState == configStates.STATE_LOADING then
      imgui.TextColored(imgui.ImVec4(0, 1, 0, pulseAlpha * uiAnim.opacity), ">> LOADING <<")
      if contractsMod.ContractSystem.activeContract then
        local c, p = contractsMod.ContractSystem.activeContract, contractsMod.ContractSystem.contractProgress
        imgui.Text(string.format("Contract: %s", c.name or "Contract"))
        if c.unitType == "item" then
          local breakdown = getMixedContractBreakdown(c)
          if breakdown then
            local parts = {}
            for matKey, count in pairs(breakdown) do
              if count > 0 then
                local matConfig = Config.materials and Config.materials[matKey]
                local matName = matConfig and matConfig.name or matKey
                table.insert(parts, string.format("%d %s", count, matName))
              end
            end
            if #parts > 0 then
              imgui.Text(string.format("Required: %s", table.concat(parts, " and ")))
            end
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          else
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          end
        else
          imgui.Text(string.format("Progress: %.1f / %.1f tons", p.deliveredTons or 0, c.requiredTons or 0))
        end
        imgui.Separator()
      end
      
      if managerMod.jobObjects.activeGroup and zonesMod then
        local stockInfo = zonesMod.getZoneStockInfo and zonesMod.getZoneStockInfo(managerMod.jobObjects.activeGroup, contractsMod.getCurrentGameHour)
        if stockInfo and stockInfo.materialStocks then
          imgui.Text("Zone Stock:")
          for matKey, stock in pairs(stockInfo.materialStocks) do
            local matConfig = Config.materials and Config.materials[matKey]
            local matName = matConfig and matConfig.name or matKey
            local stockPercent = stock.max > 0 and (stock.current / stock.max) or 0
            local stockColor = stockPercent < 0.2 and imgui.ImVec4(1, 0.3, 0.3, uiAnim.opacity) or (stockPercent < 0.5 and imgui.ImVec4(1, 0.7, 0.3, uiAnim.opacity) or imgui.ImVec4(0.3, 1, 0.3, uiAnim.opacity))
            imgui.TextColored(stockColor, string.format("  %s: %d/%d", matName, stock.current, stock.max))
          end
          imgui.Separator()
        end
      end
      
      local materialType = managerMod.jobObjects.materialType
      local matConfig = materialType and Config.materials and Config.materials[materialType]
      if not matConfig or matConfig.unitType ~= "item" then
        local targetLoad = matConfig and matConfig.targetLoad or 25000
        local percent = math.min(1.0, managerMod.jobObjects.currentLoadMass / targetLoad)
        imgui.Text(string.format("Payload: %.0f / %.0f kg", managerMod.jobObjects.currentLoadMass, targetLoad))
        imgui.PushStyleColor2(imgui.Col_PlotHistogram, percent > 0.8 and imgui.ImVec4(0, 1, 0, 1) or imgui.ImVec4(1, 1, 0, 1))
        imgui.ProgressBar(percent, imgui.ImVec2(-1, 30), string.format("%.0f%%", percent * 100))
        imgui.PopStyleColor(1)
      end

      if matConfig and matConfig.unitType == "item" then 
        imgui.Dummy(imgui.ImVec2(0, 8)); imgui.Separator(); imgui.Dummy(imgui.ImVec2(0, 4))
        if managerMod.jobObjects.anyItemDamaged then imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, uiAnim.opacity * 0.8), "Damaged items won't count"); imgui.Dummy(imgui.ImVec2(0, 2)) end
        for _, block in ipairs(managerMod.getItemBlocksStatus()) do
          imgui.TextColored(imgui.ImVec4(1, 1, 1, uiAnim.opacity), string.format("Item %d: ", block.index))
          imgui.SameLine(); imgui.TextColored(block.isDamaged and imgui.ImVec4(1, 0.3, 0.2, ((math.sin(uiAnim.pulse * 2) * 0.3) + 0.7) * uiAnim.opacity) or imgui.ImVec4(0.3, 1, 0.3, uiAnim.opacity), block.isDamaged and "DAMAGED" or "OK")
          imgui.SameLine(); imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, uiAnim.opacity), " | ")
          imgui.SameLine(); imgui.TextColored(block.isLoaded and imgui.ImVec4(0.3, 0.8, 1, uiAnim.opacity) or imgui.ImVec4(0.6, 0.6, 0.6, uiAnim.opacity), block.isLoaded and "Loaded" or "Not loaded")
        end
      end
      imgui.Dummy(imgui.ImVec2(0, 20))
      imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0, 0.4, 0, uiAnim.opacity))
      imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0, 0.6, 0, uiAnim.opacity))
      if imgui.Button("SEND TRUCK", imgui.ImVec2(-1, 45)) then callbacks.onSendTruck() end
      imgui.PopStyleColor(2); imgui.Dummy(imgui.ImVec2(0, 5))
      
      local compatibleZones = callbacks.getCompatibleZones()
      if compatibleZones and #compatibleZones > 1 then
        imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.4, 0.4, 0, uiAnim.opacity))
        imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.6, 0.6, 0, uiAnim.opacity))
        if imgui.Button("SWAP ZONE", imgui.ImVec2(-1, 30)) then callbacks.onSwapZone() end
        imgui.PopStyleColor(2); imgui.Dummy(imgui.ImVec2(0, 5))
      end
      
      if imgui.Button("ABANDON CONTRACT", imgui.ImVec2(-1, 30)) then callbacks.onAbandonContract() end

    elseif currentState == configStates.STATE_DELIVERING then
      imgui.TextColored(imgui.ImVec4(0, 1, 1, pulseAlpha * uiAnim.opacity), ">> DELIVERING <<")
      if contractsMod.ContractSystem.activeContract then
        local c, p = contractsMod.ContractSystem.activeContract, contractsMod.ContractSystem.contractProgress
        imgui.Text(string.format("Contract: %s", c.name or "Contract"))
        if c.unitType == "item" then
          local breakdown = getMixedContractBreakdown(c)
          if breakdown then
            local parts = {}
            for matKey, count in pairs(breakdown) do
              if count > 0 then
                local matConfig = Config.materials and Config.materials[matKey]
                local matName = matConfig and matConfig.name or matKey
                table.insert(parts, string.format("%d %s", count, matName))
              end
            end
            if #parts > 0 then
              imgui.Text(string.format("Required: %s", table.concat(parts, " and ")))
            end
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          else
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          end
        else imgui.Text(string.format("Progress: %.1f / %.1f tons", p.deliveredTons or 0, c.requiredTons or 0)) end
        imgui.Separator()
      end
      imgui.Text("Truck driving to destination...")
      if managerMod.jobObjects.materialType ~= "rocks" and managerMod.jobObjects.deliveryBlocksStatus then
        imgui.Dummy(imgui.ImVec2(0, 5)); imgui.Text("Delivering:")
        for _, b in ipairs(managerMod.jobObjects.deliveryBlocksStatus) do
          if b.isLoaded then imgui.TextColored(b.isDamaged and imgui.ImVec4(1, 0.4, 0.2, uiAnim.opacity * 0.7) or imgui.ImVec4(0.3, 1, 0.3, uiAnim.opacity), string.format("  Item %d (%s)", b.index, b.isDamaged and "DAMAGED" or "OK")) end
        end
      end
      imgui.Dummy(imgui.ImVec2(0, 10))
      local compatibleZones = callbacks.getCompatibleZones()
      if compatibleZones and #compatibleZones > 1 then
        imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.4, 0.4, 0, uiAnim.opacity))
        imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.6, 0.6, 0, uiAnim.opacity))
        if imgui.Button("SWAP ZONE", imgui.ImVec2(-1, 30)) then callbacks.onSwapZone() end
        imgui.PopStyleColor(2); imgui.Dummy(imgui.ImVec2(0, 5))
      end
      if imgui.Button("ABANDON CONTRACT", imgui.ImVec2(-1, 30)) then callbacks.onAbandonContract() end

    elseif currentState == configStates.STATE_RETURN_TO_QUARRY then
      imgui.TextColored(imgui.ImVec4(1.0, 0.6, 0.2, pulseAlpha * uiAnim.opacity), ">> RETURN TO LOADING ZONE <<")
      if contractsMod.ContractSystem.activeContract then
        local c, p = contractsMod.ContractSystem.activeContract, contractsMod.ContractSystem.contractProgress
        imgui.Text(string.format("Contract: %s", c.name or "Contract"))
        if contractsMod.checkContractCompletion() then imgui.TextColored(imgui.ImVec4(0, 1, 0, pulseAlpha), "CONTRACT COMPLETE!") end
        if c.unitType == "item" then
          local breakdown = getMixedContractBreakdown(c)
          if breakdown then
            local parts = {}
            for matKey, count in pairs(breakdown) do
              if count > 0 then
                local matConfig = Config.materials and Config.materials[matKey]
                local matName = matConfig and matConfig.name or matKey
                table.insert(parts, string.format("%d %s", count, matName))
              end
            end
            if #parts > 0 then
              imgui.Text(string.format("Required: %s", table.concat(parts, " and ")))
            end
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          else
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          end
        else
          imgui.Text(string.format("Delivered: %.1f / %.1f tons", p.deliveredTons or 0, c.requiredTons or 0))
        end
        imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1), string.format("Payout: $%d (on completion)", c.totalPayout or 0))
      end
      imgui.Dummy(imgui.ImVec2(0, 10))
      if contractsMod.checkContractCompletion() then
        if imgui.Button("FINALIZE CONTRACT", imgui.ImVec2(-1, 45)) then callbacks.onFinalizeContract() end
        imgui.Dummy(imgui.ImVec2(0, 8))
      end
      if imgui.Button("ABANDON CONTRACT", imgui.ImVec2(-1, 30)) then callbacks.onAbandonContract() end

    elseif currentState == configStates.STATE_AT_QUARRY_DECIDE then
      imgui.TextColored(imgui.ImVec4(0.2, 1.0, 0.4, pulseAlpha * uiAnim.opacity), ">> AT LOADING ZONE <<")
      if contractsMod.ContractSystem.activeContract then
        local c, p = contractsMod.ContractSystem.activeContract, contractsMod.ContractSystem.contractProgress
        imgui.Text(string.format("Contract: %s", c.name or "Contract"))
        if c.unitType == "item" then
          local breakdown = getMixedContractBreakdown(c)
          if breakdown then
            local parts = {}
            for matKey, count in pairs(breakdown) do
              if count > 0 then
                local matConfig = Config.materials and Config.materials[matKey]
                local matName = matConfig and matConfig.name or matKey
                table.insert(parts, string.format("%d %s", count, matName))
              end
            end
            if #parts > 0 then
              imgui.Text(string.format("Required: %s", table.concat(parts, " and ")))
            end
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          else
            imgui.Text(string.format("Delivered: %d / %d %s", p.deliveredItems or 0, c.requiredItems or 0, c.units or "items"))
          end
        else
          local pct = (c.requiredTons or 0) > 0 and (p.deliveredTons or 0) / (c.requiredTons or 1) or 0
          imgui.Text(string.format("Progress: %.1f / %.1f tons (%.0f%%)", p.deliveredTons or 0, c.requiredTons or 0, pct * 100))
        end
        imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1), string.format("Payout: $%d", c.totalPayout or 0))
        imgui.Dummy(imgui.ImVec2(0, 10))
        if contractsMod.checkContractCompletion() then
          imgui.TextColored(imgui.ImVec4(0, 1, 0, pulseAlpha), "CONTRACT COMPLETE!"); imgui.Dummy(imgui.ImVec2(0, 10))
          if imgui.Button("FINALIZE CONTRACT", imgui.ImVec2(-1, 45)) then callbacks.onFinalizeContract() end
        else
          if imgui.Button("LOAD MORE", imgui.ImVec2(-1, 45)) then callbacks.onLoadMore() end
          imgui.Dummy(imgui.ImVec2(0, 8))
          if imgui.Button("ABANDON CONTRACT", imgui.ImVec2(-1, 30)) then callbacks.onAbandonContract() end
        end
      end
    end
    
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 5))
    if imgui.CollapsingHeader1("Zone Stock Status") then
      local zonesStock = zonesMod.getAllZonesStockInfo and zonesMod.getAllZonesStockInfo(contractsMod.getCurrentGameHour) or {}
      if #zonesStock == 0 then
        imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, uiAnim.opacity), "No zones loaded")
      else
        for _, zoneStock in ipairs(zonesStock) do
          imgui.PushID1("zone_" .. zoneStock.zoneName)
          imgui.TextColored(imgui.ImVec4(0.8, 0.9, 1.0, uiAnim.opacity), zoneStock.zoneName)
          imgui.Indent(15)
          for _, mat in ipairs(zoneStock.materials) do
            local stockPercent = mat.max > 0 and (mat.current / mat.max) or 0
            local stockColor = imgui.ImVec4(1, 1, 1, uiAnim.opacity)
            if stockPercent < 0.2 then
              stockColor = imgui.ImVec4(1, 0.3, 0.3, uiAnim.opacity)
            elseif stockPercent < 0.5 then
              stockColor = imgui.ImVec4(1, 0.7, 0.3, uiAnim.opacity)
            elseif stockPercent >= 1.0 then
              stockColor = imgui.ImVec4(0.3, 1, 0.3, uiAnim.opacity)
            end
            imgui.TextColored(stockColor, string.format("  %s: %d/%d", mat.materialName, mat.current, mat.max))
            if mat.regenRate > 0 then
              imgui.SameLine()
              imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, uiAnim.opacity), string.format(" (+%d/hr)", mat.regenRate))
            end
          end
          imgui.Unindent(15)
          imgui.Dummy(imgui.ImVec2(0, 3))
          imgui.PopID()
        end
      end
    end
  end
  imgui.End(); imgui.PopStyleColor(2); imgui.PopStyleVar(3)
end

-- Debug OBB Drawing
local function drawDebugOBB()
  if not debugOBBEnabled then return end
  
  local managerMod = extensions.gameplay_loading_manager
  if not managerMod then return end
  
  -- Draw truck bed OBB
  if managerMod.debugDrawCache and managerMod.debugDrawCache.bedData then
    local bd = managerMod.debugDrawCache.bedData
    local corners = {}
    for dx = -1, 1, 2 do
      for dy = -1, 1, 2 do
        for dz = -1, 1, 2 do
          local corner = bd.center 
            + bd.axisX * (bd.halfWidth * dx) 
            + bd.axisY * (bd.halfLength * dy) 
            + bd.axisZ * (bd.halfHeight * dz)
          table.insert(corners, corner)
        end
      end
    end
    
    local green = ColorF(0, 1, 0, 0.8)
    local greenFaded = ColorF(0, 1, 0, 0.2)
    
    -- Draw edges
    local edges = {
      {1,2}, {3,4}, {5,6}, {7,8},  -- Z edges
      {1,3}, {2,4}, {5,7}, {6,8},  -- Y edges  
      {1,5}, {2,6}, {3,7}, {4,8}   -- X edges
    }
    for _, e in ipairs(edges) do
      debugDrawer:drawLine(corners[e[1]], corners[e[2]], green)
    end
    
    -- Draw center sphere
    debugDrawer:drawSphere(bd.center, 0.2, green)
    
    -- Draw floor plane
    local floorCenter = bd.center - bd.axisZ * bd.halfHeight
    debugDrawer:drawSquarePrism(
      floorCenter - bd.axisY * bd.halfLength,
      floorCenter + bd.axisY * bd.halfLength,
      Point2F(bd.halfWidth * 2, 0.05),
      Point2F(bd.halfWidth * 2, 0.05),
      greenFaded
    )
  end
  
  -- Draw loading zone boundary
  if managerMod.jobObjects and managerMod.jobObjects.activeGroup then
    local zone = managerMod.jobObjects.activeGroup.loading
    if zone and zone.vertices then
      local yellow = ColorF(1, 1, 0, 0.6)
      local verts = zone.vertices
      for i = 1, #verts do
        local v1 = verts[i]
        local v2 = verts[(i % #verts) + 1]
        -- Handle both array format [x,y,z] and vec3/table format
        local x1, y1, z1 = v1[1] or v1.x or 0, v1[2] or v1.y or 0, v1[3] or v1.z or 0
        local x2, y2, z2 = v2[1] or v2.x or 0, v2[2] or v2.y or 0, v2[3] or v2.z or 0
        local p1 = vec3(x1, y1, z1 + 0.5)
        local p2 = vec3(x2, y2, z2 + 0.5)
        debugDrawer:drawLine(p1, p2, yellow)
        debugDrawer:drawSphere(p1, 0.3, yellow)
      end
    end
  end
  
  -- Draw props/rocks and their detection status
  if managerMod.propQueue and #managerMod.propQueue > 0 then
    local Config = extensions.gameplay_loading_config
    local nodeStep = Config and Config.settings and Config.settings.payload and Config.settings.payload.nodeSamplingStep or 10
    local bd = managerMod.debugDrawCache and managerMod.debugDrawCache.bedData
    
    for _, propEntry in ipairs(managerMod.propQueue) do
      local obj = be:getObjectByID(propEntry.id)
      if obj then
        local objPos = obj:getPosition()
        local tf = obj:getTransform()
        local axisX = vec3(tf:getColumn(0))
        local axisY = vec3(tf:getColumn(1))
        local axisZ = vec3(tf:getColumn(2))
        
        -- Draw prop center
        local cyan = ColorF(0, 1, 1, 0.8)
        debugDrawer:drawSphere(objPos, 0.5, cyan)
        
        -- Draw sampled nodes if we have bed data
        if bd then
          local nodeCount = obj:getNodeCount() or 0
          for i = 0, nodeCount - 1, nodeStep do
            local nodeLocalPos = obj:getNodePosition(i)
            local worldPoint = objPos - (axisX * nodeLocalPos.x) - (axisY * nodeLocalPos.y) + (axisZ * nodeLocalPos.z)
            
            -- Check if node is inside truck bed
            local diff = worldPoint - bd.center
            local localX = diff:dot(bd.axisX)
            local localY = diff:dot(bd.axisY)
            local localZ = diff:dot(bd.axisZ)
            local isInside = (math.abs(localX) <= bd.halfWidth and math.abs(localY) <= bd.halfLength and math.abs(localZ) <= bd.halfHeight)
            
            local nodeColor = isInside and ColorF(0, 1, 0, 0.9) or ColorF(1, 0, 0, 0.5)
            debugDrawer:drawSphere(worldPoint, 0.08, nodeColor)
          end
        end
      end
    end
  end
end

local function toggleDebugOBB(enabled)
  if enabled == nil then
    debugOBBEnabled = not debugOBBEnabled
  else
    debugOBBEnabled = enabled
  end
  print("[Loading] Debug OBB visualization: " .. (debugOBBEnabled and "ENABLED" or "DISABLED"))
  return debugOBBEnabled
end

-- API Exports
M.uiAnim = uiAnim
M.uiHidden = uiHidden
M.markerAnim = markerAnim
M.debugOBBEnabled = debugOBBEnabled

M.drawWorkSiteMarker = drawWorkSiteMarker
M.drawZoneChoiceMarkers = drawZoneChoiceMarkers
M.getQuarryStateForUI = getQuarryStateForUI
M.requestQuarryState = requestQuarryState
M.drawUI = drawUI
M.drawDebugOBB = drawDebugOBB
M.toggleDebugOBB = toggleDebugOBB
M.onExtensionLoaded = function()
  log("I", "Loading Extension: ui loaded")
end

return M

