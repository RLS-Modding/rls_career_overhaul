-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/cargoContainerDebug.lua (BeamNG 0.40).
local M = {}
M.debugOrder = 11
M.debugName = "Vehicle > Cargo Containers"

local im = ui_imgui
local red = im.ImVec4(1,0.4,0.4,0.75)
local yellow = im.ImVec4(0.8,0.8,0.2,0.75)
local green = im.ImVec4(0.2,1,0.4,0.75)
local tableFlags = bit.bor(im.TableFlags_Resizable,im.TableFlags_RowBg,im.TableFlags_Borders)

local flowRate = im.FloatPtr(0)
local maxRate = im.FloatPtr(250)

local inputsPerContainer = {}
M.vehCargoData = {}
local function getData()
  if not core_vehicleBridge then return {} end
  local newContainers = {}
  local vehs = {}
  local vehData = {}
  for vehId, veh in activeVehiclesIterator() do
    vehData[vehId] = -1
    vehs[vehId] = veh
  end
  for vehId, veh in pairs(vehs) do
    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      vehData[vehId] = {
        vehId = vehId,
        name = string.format("%s (%s)", veh:getJBeamFilename() or "<No Model>", veh:getName() or "<No Name>"),
        containers = {},
      }

      for _, container in ipairs(vehCargoContainerData[1]) do
        container.inputsId = container.id .. " - " .. vehId
        if not inputsPerContainer[container.inputsId] then
          inputsPerContainer[container.inputsId] = {
            sendUpdate = false,
            volume = im.FloatPtr(container.currentVolume or 0),
            density = im.FloatPtr(container.currenDensity or 1),
            fillWithFlowRate = false
          }
        end
        table.insert(vehData[vehId].containers, container)
      end
      table.sort(vehData[vehId].containers, function(a,b) return a.id < b.id end)

      -- check if all cargo was sent
      for key, val in pairs(vehData) do
        if val == -1 then return end
      end

      for _, d in pairs(vehData) do
        table.insert(newContainers, d)
      end

      table.sort(newContainers, function(a,b) return a.vehId < b.vehId end)
      M.vehCargoData = newContainers
    end, "overhaulGetCargoContainers")
  end
end
M.getData = getData

local function removeVehicleData(id)
  for i, data in ipairs(M.vehCargoData) do
    if data.vehId == id then
      table.remove(M.vehCargoData, i)
      return
    end
  end
end

local function updateVehicle(data)
  local veh = scenetree.findObjectById(data.vehId)
  if not veh then return false end

  local clusterGeneration = veh:getNodeClusterGeneration()
  if clusterGeneration > (data.clusterGeneration or -math.huge) then
    -- update detachment
    data.refNodeClusterId = veh:getNodeClusterId(veh:getRefNodeId())
    for _, container in ipairs(data.containers) do
      container.clusterId = container.nodeId and veh:getNodeClusterId(container.nodeId) or data.refNodeClusterId
      container.noDetach = container.nodeId == nil
    end
  end
  data.clusterGeneration = clusterGeneration


  data.vehPos = veh:getPosition()
  for _, container in ipairs(data.containers) do
    container.position = container.noDetach and veh:getNodePosition(veh:getRefNodeId()) or veh:getNodePosition(container.nodeId)
  end
  return true
end
M.updateVehicle = updateVehicle


local forceUpdate = false
local function drawVehicle(data)
  local editEnded = im.BoolPtr(false)
  im.PushID1("Veh"..data.vehId)
  im.BeginTable("vehHeader", 3, tableFlags)
  im.TableNextColumn()
  im.Text("Id")
  im.TableNextColumn()
  im.Text("Name")
  im.TableNextColumn()
  im.Text("Cluster Info")
  --im.TableNextColumn()
  --im.Text("Position")

  im.TableNextColumn()
  im.Text(""..data.vehId)
  im.TableNextColumn()
  im.Text(data.name)
  im.TableNextColumn()
  im.Text(string.format("Gen: %d, Ref: %d", data.clusterGeneration, data.refNodeClusterId))
  --im.TableNextColumn()
  --im.Text(string.format("%0.1f / %0.1f / %0.1f", data.vehPos.x, data.vehPos.y, data.vehPos.z ))

  im.EndTable()

  im.BeginTable("container", 5, tableFlags)
  im.TableNextColumn()
  im.Text("General Info")
  im.TableNextColumn()
  im.Text("Contents")
  im.TableNextColumn()
  im.TableNextColumn()
  im.Text("Raw Values")
  im.TableNextColumn()

  for _, container in ipairs(data.containers) do
    local id = container.id.."-"..data.vehId
    im.PushID1(id)
    im.TableNextColumn()
    im.Text(string.format("%d - %s (%s)", container.id, container.name or "No Name", table.concat(container.cargoTypes,",")))
    if im.IsItemHovered() then
      simpleDebugText3d(container.name, container.position, 0.15, ColorF(1,0.5,0.2, 0.75))
    end
    im.Text(string.format("%d / %d ", container.nodeId or -1, container.clusterId or -1))
    im.tooltip("Node ID and Cluster ID")
    im.SameLine()

    if container.clusterId == data.refNodeClusterId then
      im.TextColored(green, "Atached")
      if container.noDetach then
        im.SameLine()
        im.TextColored(yellow,"(No Detach)")
      end
    else
      local dist = (container.position-data.vehPos):length()
      if dist < 10 then
        im.TextColored(yellow,"Nearby")
      else
        im.TextColored(red,"Lost")
      end
      im.SameLine()
      im.Text(string.format(" (%0.1fm)", dist))
    end
    if im.Button("Console Dump") then
      dump(container)
    end



    im.TableNextColumn()
    local inputs = inputsPerContainer[container.inputsId]

    local progressPercent = 0
    if flowRate[0] > 0 and inputs.fillWithFlowRate then
      progressPercent = container.currentVolume / container.capacity
    else
      progressPercent = container.reachTargetDuration and ((container.reachTargetDuration-container.reachTargetTimeRemaining)/container.reachTargetDuration) or 1
    end
      im.ProgressBar(progressPercent, im.ImVec2(im.GetContentRegionAvailWidth(), 0), string.format("%d%%",progressPercent*100))

    if progressPercent < 1 then
      forceUpdate = true
    end

    local volumePercent = container.currentVolume / container.capacity
    im.ProgressBar(volumePercent, im.ImVec2(im.GetContentRegionAvailWidth(), 0), string.format("%d%%", volumePercent*100))


    im.SetNextItemWidth(im.GetContentRegionAvailWidth())
    if im.SliderFloat("##sliderVol",inputs.volume, 0, container.capacity, "%0.1f L") then
     inputs.sendUpdate = true
    end

    im.TableNextColumn()
    if flowRate[0] > 0 and inputs.fillWithFlowRate then
      local eta = (container.capacity - container.currentVolume) / (flowRate[0] * maxRate[0])
      if maxRate[0] < 0 then
        eta = (-container.capacity) / (flowRate[0] * maxRate[0])
      end
      im.TextColored(yellow,string.format("%0.2fs",eta))
    else
      im.Text(string.format("%0.2fs (%0.2fs)",container.reachTargetTimeRemaining or 0, container.reachTargetDuration or 0))
      im.tooltip("The time remainign for the current target to be reached (since the last time a target was set)")

    end
    im.Text(string.format("%dL / %dL",container.currentVolume, container.capacity))
    im.tooltip("The currently loaded volume inside the container")
    im.Text(string.format("(max %0.1fL/s)", container.rateVolume or 0))
    im.tooltip("The maximum rate of change inside the container")


    im.TableNextColumn()
    --im.Text(string.format("%0.1f / %0.1f / %0.1f (%0.1f m)", container.position.x, container.position.y, container.position.z, (container.position-data.vehPos):length()))
    --im.TableNextColumn()
    if im.Button("Set Values") then
      inputs.sendUpdate = true
    end

    im.SetNextItemWidth(140)
    im.InputFloat("##volume"..id, inputs.volume, 1,10, "%0.1f L")
    if im.IsItemDeactivatedAfterEdit() then
      inputs.sendUpdate = true
    end
    im.SetNextItemWidth(140)
    im.InputFloat("##density"..id, inputs.density, 1,10, "%0.1f kg/l")
    if im.IsItemDeactivatedAfterEdit() then
      inputs.sendUpdate = true
    end

    im.TableNextColumn()
    if im.Checkbox("##fill"..id, im.BoolPtr(inputs.fillWithFlowRate)) then
      inputs.fillWithFlowRate = not inputs.fillWithFlowRate
    end

    im.PopID()
  end
  local veh = scenetree.findObjectById(data.vehId)
  local vehData = {}
  for _, container in ipairs(data.containers) do
    local inputs = inputsPerContainer[container.inputsId]
    if inputs.sendUpdate then
      vehData[container.id] = {
        containerId = container.id,
        volume = inputs.volume[0],
        density = inputs.density[0],
      }
    end
    inputs.sendUpdate = false
  end
  if veh and next(vehData) then
    core_vehicleBridge.executeAction(veh, "overhaulSetCargoContainers", vehData, "updateExplicit")
    forceUpdate = true
  end
  im.EndTable()
  im.PopID()
end
M.drawVehicle = drawVehicle


local function updateFuelSoundParameters()
  local relativeFuelLevel = getRelativeFuelLevel()
  local sound = scenetree.findObjectById(gasSoundId)
  if sound then
    sound:setParameter("volume", relativeFuelLevel)
    sound:setParameter("pitch", fuelFlowRate / maxFuelFlowRate)
    sound:setTransform(getCameraTransform())
  end
end
local function isActionMapEnabled(map)
  local list = ActionMap:getList()
  if list and list.active then
    for _, e in ipairs(list.active) do
      if e.name == map.."ActionMap" and e.enabled then
        return true
      end
    end
  end
  return false
end
M.drawFlowRate = function(dt)
  im.SliderFloat("Flow Rate", flowRate, 0, 1)
  im.SliderFloat("Max Fill Rate", maxRate, -500, 500, string.format("%0.1f L/s", maxRate[0]))
  local actionMapEnabled = isActionMapEnabled("Refueling")
  if im.Checkbox("Loading with Trigger ActionMap (Blocks Throttle via trigger)", im.BoolPtr(actionMapEnabled)) then
    if actionMapEnabled then
      popActionMap("Refueling")
    else
      pushActionMap("Refueling")
    end
  end
  im.SameLine()
  im.Text(" | ")
  im.SameLine()

  local fillCount = 0
  for _, data in ipairs(M.vehCargoData) do
    for _, container in ipairs(data.containers) do
      local inputs = inputsPerContainer[container.inputsId]
      if inputs.fillWithFlowRate then
        fillCount = fillCount + 1
        if flowRate[0] > 0 then
          inputs.volume[0] = inputs.volume[0] + flowRate[0] * maxRate[0] * dt
          inputs.volume[0] = clamp(inputs.volume[0], 0, container.capacity)
          inputs.sendUpdate = true
        end
      end
    end
  end
  if fillCount > 0 then
    im.TextColored(flowRate[0] > 0 and green or yellow, string.format("Loading %d containers with %0.1f L/s", fillCount, maxRate[0] * flowRate[0]))
  else
    im.Text(string.format("Mark containers below to be loaded. (%0.1f L/s)",  maxRate[0] * flowRate[0]))
  end
end

local function onChangeFlowRate(factor)
  flowRate[0] = clamp(factor, 0, 1)
end


local function drawDebugMenu(dt)
  if im.Begin("Cargo Container Debug") then
    if im.Button("Refresh Data from All Vehicles", im.ImVec2(-1, 0)) then
      inputsPerContainer = {}
      M.vehCargoData = {}
      M.getData()
    end
    im.Separator()
    M.drawFlowRate(dt)
    im.Separator()
    local i = 1
    while i <= #M.vehCargoData do
      local data = M.vehCargoData[i]
      if M.updateVehicle(data) then
        M.drawVehicle(data)
        i = i + 1
      else
        table.remove(M.vehCargoData, i)
      end
    end
    if forceUpdate then
      M.getData()
    end
    forceUpdate = false
  end
  im.End()
end


-- extensions.load("overhaul/dev/debug/cargoContainerDebug") overhaul_dev_debug_cargoContainerDebug.show()
M.drawDebugMenu = drawDebugMenu
M.show = function()
  M.onUpdate = M.drawDebugMenu
  extensions.hookUpdate("onUpdate")
  M.getData()
end

M.onVehicleResetted = function(id)
  removeVehicleData(id)
  forceUpdate = true
end

M.onChangeFlowRate = onChangeFlowRate

local function onVehicleDestroyed(id)
  removeVehicleData(id)
end
M.onVehicleDestroyed = onVehicleDestroyed
M.onInstabilityDetected = onVehicleDestroyed


return M
