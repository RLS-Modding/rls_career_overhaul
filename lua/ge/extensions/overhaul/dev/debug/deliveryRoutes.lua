-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/deliveryRoutes.lua (BeamNG 0.40).
local M = {}
M.debugOrder = 10
M.debugName = "Delivery > Routes"


local im = ui_imgui
local tableFlags = bit.bor(im.TableFlags_Resizable,im.TableFlags_RowBg,im.TableFlags_Borders)
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehOfferManager
M.onCareerActivated = function()
  dParcelManager = overhaul_career_logistics_parcelManager
  dCargoScreen = overhaul_career_logistics_cargoScreen
  dGeneral = overhaul_career_logistics_general
  dGenerator = overhaul_career_logistics_generator
  dProgress = overhaul_career_logistics_progress
  dVehOfferManager = overhaul_career_logistics_vehicleOfferManager
end

local color = ColorF(0.91,0.05,0.48,0.5)

local white = ColorF(1,1,1,1)
local green = ColorF(0.6,1,0.6,1)
local red = ColorF(1,0.6,0.6,1)
local blue = ColorF(0.6,0.6,1,1)
local cyan = ColorF(0.6,1,1,1)
local clrBG = ColorI(0,0,0,220)
M.drawDebugFunctions = function()

end

local selectedAp
local mouseInfo
local function drawArc(a,b,t)
  local h = (a-b):length()/2
  --debugDrawer:drawLine(a,b, color)
  local steps = 1/100
  for i = 0, 1, steps do
    local c, d = lerp(a,b,i), lerp(a,b,i+steps)
    c.z = c.z + math.sin(i*math.pi)*h
    d.z = d.z + math.sin((i+steps)*math.pi)*h
    local w = -4 + math.pow((1-(((t-(i*(h/25)))/(h/100))%1)),3)*8
    if w > 0 then
      debugDrawer:drawLineInstance(c, d, w, color)
    end
    debugDrawer:drawLine(c, d, white)
  end

end


local routeData = {}
local function drawRoute(from, to, dt)
  local a, b = from, to


end


local facilityToDraw = "auto"
local function allCargoFilter() return true end
local function drawDebugMenu(dt)
  if im.Begin("Delivery Access Points") then
    M.updateMouseInfo()
    for _, fac in ipairs(dGenerator.getFacilities()) do
      if im.TreeNode1(_tr(fac.name)) then
        for _, apName in ipairs(tableKeysSorted(fac.accessPointsByName)) do
          local ap = fac.accessPointsByName[apName]
          if im.Selectable1(ap.name, selectedAp == ap) then
            selectedAp = ap
          end
        end
        im.TreePop()
      end
    end

    -- mouse clicking
    if mouseInfo.valid then

      debugDrawer:drawSphere(mouseInfo.rayCast.pos, 0.25,color)

      local closestAp, closestDist = nil, math.huge
      for _, fac in ipairs(dGenerator.getFacilities()) do
        for _, ap in pairs(fac.accessPointsByName) do
          local psPos = ap.ps.pos
          local distNodeToCam = (psPos - mouseInfo.camPos):length()
          local nodeRayDistance = (psPos - mouseInfo.camPos):cross(mouseInfo.rayDir):length() / mouseInfo.rayDir:length()
          local sphereRadius = 3
          if nodeRayDistance < 100 or ap == selectedAp then
            ap.ps:drawDebug("faded")
          end
          if nodeRayDistance < 100 or ap == selectedAp then
            if next(ap.logisticTypesReceivedLookup) then
              debugDrawer:drawTextAdvanced(psPos + vec3(0,0,2.2), String("Rcv: " ..table.concat( tableKeysSorted(ap.logisticTypesReceivedLookup), ", ")), red, true, false, clrBG)
            end
            if next(ap.logisticTypesProvidedLookup) then
              debugDrawer:drawTextAdvanced(psPos + vec3(0,0,2.2), String("Prv: " ..table.concat( tableKeysSorted(ap.logisticTypesProvidedLookup), ", ")), green, true, false, clrBG)
            end
            if ap.isLoanerVehicleSpot then
              debugDrawer:drawTextAdvanced(psPos + vec3(0,0,2.2), String("Loaner Spawn Location"), cyan, true, false, clrBG)
            end
            if ap.isInspectSpot then
              debugDrawer:drawTextAdvanced(psPos + vec3(0,0,2.2), String("Inspect"), blue, true, false, clrBG)
            end
            debugDrawer:drawTextAdvanced(psPos + vec3(0,0,2.2), String(ap.name), white, true, false, clrBG)
          end
          if mouseInfo.down or mouseInfo.up then
            if nodeRayDistance <= sphereRadius then
              if distNodeToCam < closestDist then
                closestDist = distNodeToCam
                closestAp = ap
              end
            end
          end
        end
        if closestAp then
          selectedAp = closestAp
        end
      end
    end
  end
  im.End()
  if im.Begin("Acces Points Details") then
    if selectedAp then
      local ap = selectedAp
      im.Text(ap.name)

      im.Text("Inspect: " .. (ap.isInspectSpot and "Yes" or "No"))

      im.Text("Provides:")

      for _, logisticType in ipairs(tableKeysSorted(ap.logisticTypesProvidedLookup)) do
        im.Text(logisticType)
        if im.IsItemHovered() then
          for _, fac in ipairs(dGenerator.getFacilities()) do
            if fac.id ~= ap.facId then
              for _, otherAp in pairs(fac.accessPointsByName) do
                if otherAp.logisticTypesReceivedLookup[logisticType] then
                  drawArc(ap.ps.pos, otherAp.ps.pos, os.clockhp())
                end
              end
            end
          end

        end
      end

      im.Text("Receives:")
      for _, logisticType in ipairs(tableKeysSorted(ap.logisticTypesReceivedLookup)) do
        im.Text(logisticType)
        if im.IsItemHovered() then
          for _, fac in ipairs(dGenerator.getFacilities()) do
            if fac.id ~= ap.facId then
              for _, otherAp in pairs(fac.accessPointsByName) do
                if otherAp.logisticTypesProvidedLookup[logisticType] then
                  drawArc(otherAp.ps.pos, ap.ps.pos, os.clockhp())
                end
              end
            end
          end
        end
      end

    end
  end
  im.End()
end

M.drawDebugMenu = drawDebugMenu

M.updateMouseInfo = function()
  if not mouseInfo then mouseInfo = {} end
  if core_forest.getForestObject() then core_forest.getForestObject():disableCollision() end
  mouseInfo.camPos = core_camera.getPosition()
  mouseInfo.ray = getCameraMouseRay()
  mouseInfo.rayDir = vec3(mouseInfo.ray.dir)
  mouseInfo.rayCast = cameraMouseRayCast()
  mouseInfo.valid = mouseInfo.rayCast and true or false

  if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end
  if not mouseInfo.valid then
    mouseInfo.down = false
    mouseInfo.hold = false
    mouseInfo.up   = false
    mouseInfo.closestNodeHovered = nil
  else
    mouseInfo.down =  im.IsMouseClicked(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.hold = im.IsMouseDown(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.up =  im.IsMouseReleased(0) and not im.GetIO().WantCaptureMouse
    if mouseInfo.down then
      mouseInfo.hold = false
      mouseInfo._downPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._downNormal = vec3(mouseInfo.rayCast.normal)
    end
    if mouseInfo.hold then
      mouseInfo._holdPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._holdNormal = vec3(mouseInfo.rayCast.normal)
    end
    if mouseInfo.up then
      mouseInfo._upPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._upNormal = vec3(mouseInfo.rayCast.normal)
    end
  end
end
return M
