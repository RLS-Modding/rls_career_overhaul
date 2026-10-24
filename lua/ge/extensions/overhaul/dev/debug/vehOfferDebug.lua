-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/debug/vehOfferDebug.lua (BeamNG 0.40).
local M = {}
M.debugOrder = 11
M.debugName = "Delivery > Veh Offers"


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
  for _, t in ipairs({"vehicle", "trailer"}) do
    if im.Selectable1("> Available " .. t .. " per facility") then
      local results = {}
      for _, fac in ipairs(dGenerator.getFacilities()) do
        local amounts = {[1]=0, [2]=0, [3]=0, [4]=0, [5]=0}
        local hasVehicle = false
        for _, item in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(fac.id)) do
          if item.data.type == t then
            local enabled, reason = dVehOfferManager.isVehicleTagUnlocked(item.vehicle.unlockTag)
            amounts[reason.level] = amounts[reason.level] + 1
            hasVehicle = true
          end
        end
        if hasVehicle then
          table.insert(results, {name = fac.name, amounts = amounts, sort = string.format("%02d %02d %02d %02d %02d", amounts[1],amounts[2],amounts[3],amounts[4],amounts[5])})
        end
      end
      table.sort(results,function(a,b) return a.sort > b.sort end)
      print("L1 L2 L3 L4 L5  |  Facility")
      for _, r in ipairs(results) do

        print(r.sort:gsub("00", "--") .. "  <- " .. r.name)
      end
    end
  end
end


local function drawFacility(facility)

  parcelDebug.drawFacilityHeader(facility, {}, {})

  im.BeginTable("vehOffers", 5, tableFlags)
  im.TableNextColumn()
  im.Text("Id")
  im.TableNextColumn()
  im.Text("Name")
  im.TableNextColumn()
  im.Text("Task")
  im.TableNextColumn()
  im.Text("Expires In")
  im.TableNextColumn()
  im.Text("Actions")

  for _, item in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(facility.id)) do
    im.TableNextColumn()
    im.Text(""..item.id.." "..item.generatorLabel)
    im.TableNextColumn()
    im.Text(item.name)
    im.Text(dumps(item.vehicle))
    im.Text(dumps(item.data))
    im.TableNextColumn()
    im.Text(dumps(item.task))

    im.TableNextColumn()
    im.ProgressBar(clamp((item.offerExpiresAt - dGeneral.time())/120,0,1), im.ImVec2(100,im.GetTextLineHeight()), string.format("%s",secondsToClock(item.offerExpiresAt - dGeneral.time())))


    im.TableNextColumn()
    if im.Button("X##"..item.id) then
      item.offerExpiresAt = dGeneral.time() - 1
    end
    im.SameLine()
    if im.Button("Extend##"..item.id) then
      item.offerExpiresAt = item.offerExpiresAt + 300
    end
    im.SameLine()
    if im.Button("Spawn##"..item.id) then
      dVehOfferManager.spawnOffer(item.id)
    end
  end
  im.EndTable()


  im.Dummy(im.ImVec2(1,1))
  im.Separator()
  im.Dummy(im.ImVec2(1,1))
end


local facilityToDraw = "auto"
local function drawDebugMenu()
  if im.Begin("Vehicle Offer Debug") then

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
        if im.Selectable1(facility.name .. '##'..facility.id, facility.id == facilityToDraw) then
          facilityToDraw = facility.id
        end
      end
      im.EndCombo()
    end

    local closest = nil
    if facilityToDraw == "auto" then
      local closestDistance = 2500
      for _, fac in ipairs(dGenerator.getFacilities()) do
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
    if closest then
      drawFacility(closest)
    else
      for _, facility in ipairs(dGenerator.getFacilities()) do
        if facilityToDraw == facility.id or facilityToDraw == "all" then
          drawFacility(facility)
        end
      end
    end

  end
  im.End()
end
M.drawDebugMenu = drawDebugMenu
return M
