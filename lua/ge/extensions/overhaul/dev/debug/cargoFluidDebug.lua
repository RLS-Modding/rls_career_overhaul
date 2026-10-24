-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/cargoFluidDebug.lua (BeamNG 0.40).
local M = {}
M.debugOrder = 11
M.debugName = "Delivery > Fluid Cargo"


local im = ui_imgui
local tableFlags = bit.bor(im.TableFlags_Resizable,im.TableFlags_RowBg,im.TableFlags_Borders)
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehOfferManager
local parcelDebug
M.onCareerActivated = function()
  dParcelManager = overhaul_career_logistics_parcelManager
  dCargoScreen = overhaul_career_logistics_cargoScreen
  dGeneral = overhaul_career_logistics_general
  dGenerator = overhaul_career_logistics_generator
  dProgress = overhaul_career_logistics_progress
  dVehOfferManager = overhaul_career_logistics_vehicleOfferManager
  parcelDebug = overhaul_dev_debug_parcelDebug
end

local function secondsToClock(seconds)
  local seconds = tonumber(seconds)

  if seconds <= 0 then
    return "00:00";
  else
    local mins = string.format("%02.f", math.floor(seconds/60));
    local secs = string.format("%02.f", math.floor(seconds - mins *60));
    return mins..":"..secs
  end
end

M.drawDebugFunctions = function()

end


local function drawFacility(facility)

  parcelDebug.drawFacilityHeader(facility, {}, {}, true)
  dGenerator.finalizeMaterialDistances(facility)


  im.BeginTable("vehOffers", 4, tableFlags)
  im.TableNextColumn()
  im.Text("")
  im.TableNextColumn()
  im.Text("Fluid")
  im.TableNextColumn()
  im.Text("Rate")
  im.TableNextColumn()
  im.Text("Connections")
  im.TableNextColumn()

  for _, key in ipairs(tableKeysSorted(facility.materialStorages)) do
    local storage = facility.materialStorages[key]
    if storage.isProvider then
      im.Text("Provider")
      im.PushStyleColor2(im.Col_PlotHistogram, im.ImVec4(0.6, 0.50, 0.45, 0.8))
    else
      im.Text("Receiver")
      im.PushStyleColor2(im.Col_PlotHistogram, im.ImVec4(0.5, 0.60, 0.45, 0.8))
    end
    im.SameLine()
    im.Text(storage.materialType)
    im.TableNextColumn()

    im.ProgressBar(storage.storedVolume/ storage.capacity, im.ImVec2(im.GetContentRegionAvailWidth(),im.GetTextLineHeight()),string.format("%d / %d", storage.storedVolume, storage.capacity))
    im.PopStyleColor()
    im.TableNextColumn()

    if storage._rate then
      im.Text(string.format("%s%0.1f L/min", storage._rate >= 0 and "+" or "", storage._rate*60))
      im.SameLine()
      im.Text(string.format("(max %0.1f L/min)", storage._rateMax*60))
    end

    im.TableNextColumn()
    if storage._rate then
      local m = storage.isProvider and 0 or storage.capacity
      im.Text(string.format("Target: %d | ToTarget: %s | maxToTarget %s", storage.target, secondsToClock(math.abs((storage.storedVolume - storage.target) / storage._rate)), secondsToClock(math.abs((m - storage.target) / storage._rate))))
    end

    
    if facility.closestMaterialProviders and facility.closestMaterialProviders[key] then
      local facName = dGenerator.getFacilityById(facility.closestMaterialProviders[key].facId) or {name = "None!"}
      facName = facName.name
      facName = _tr(facName)
      im.Text(string.format("Closest Provider: %0.2fkm - %s",facility.closestMaterialProviders[key].distance/1000, facName))
    end
    if facility.closestMaterialReceivers and facility.closestMaterialReceivers[key] then

      im.Text(string.format("Closest Receivers: %d Facilities",facility.closestMaterialReceivers[key].count))
    end
    
    im.TableNextColumn()
  end

  im.EndTable()


  im.Dummy(im.ImVec2(1,1))
  im.Separator()
  im.Dummy(im.ImVec2(1,1))
end


local facilityToDraw = "all"
local function drawDebugMenu()
  if im.Begin("Fluid CargoDebug") then

    im.Text("Delivery Time: %s", secondsToClock(dGeneral.time()))
    if im.BeginCombo("Facility", facilityToDraw) then
      if im.Selectable1("All Facilities", facilityToDraw == 'all') then
        facilityToDraw = "all"
      end
      if im.Selectable1("Auto (Nearest)", facilityToDraw == 'auto') then
        facilityToDraw = "auto"
      end
      im.Separator()
      for _, facility in ipairs(dGenerator.getFacilities()) do
        if facility.materialStorages and next(facility.materialStorages) then
          if im.Selectable1(facility.name .. '##'..facility.id, facility.id == facilityToDraw) then
            facilityToDraw = facility.id
          end
        end
      end
      im.EndCombo()
    end

    local closest = nil
    if facilityToDraw == "auto" then
      local closestDistance = 2500
      for _, fac in ipairs(dGenerator.getFacilities()) do
        if fac.materialStorages and next(fac.materialStorages) then
          local spot = fac.pickUpSpots[1]
          if spot then
            local dist = (core_camera.getPosition() - spot.pos):squaredLength()
            if dist < closestDistance then
              closest = fac
              closestDistance = dist
            end
          end
        end
      end
    end
    if closest then
      drawFacility(closest)
    else
      for _, facility in ipairs(dGenerator.getFacilities()) do
        if facilityToDraw == facility.id or facilityToDraw == "all" and (facility.materialStorages and next(facility.materialStorages)) then
          drawFacility(facility)
        end
      end
    end

  end
  im.End()
end
M.drawDebugMenu = drawDebugMenu
return M
