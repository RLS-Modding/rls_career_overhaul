-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/debug/parcelDebug.lua (BeamNG 0.40).
local M = {}
M.debugOrder = 10
M.debugName = "Delivery > Parcels"


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
  if im.Selectable1("> Available parcel per facility") then
    local results = {}
    for _, fac in ipairs(dGenerator.getFacilities()) do
      local amounts = {[1]=0, [2]=0, [3]=0, [4]=0, [5]=0}
      local hasParcel = false
      for _, item in ipairs(dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(fac.id)) do
        dGenerator.finalizeParcelItemDistanceAndRewards(item)
        local modifierKeys = {}
        for _, mod in ipairs(item.modifiers or {}) do
          modifierKeys[mod.type] = true
        end
        local lockedBecauseOfMods, minTier = overhaul_career_logistics_parcelMods.lockedBecauseOfMods(modifierKeys)
        amounts[minTier] = amounts[minTier] + 1 
        hasParcel = true
      end
      if hasParcel then
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


local function drawFacility(facility)
  local outCargo = dParcelManager.getAllCargoAtFacilityUnexpired(facility.id)
  local inCargo = dParcelManager.getAllCargoForDestinationFacilityStillAtOriginUnexpired(facility.id)
  table.sort(outCargo, function(a,b) return a.offerExpiresAt < b.offerExpiresAt end)
  table.sort(inCargo, function(a,b) return a.offerExpiresAt < b.offerExpiresAt end)

  M.drawFacilityHeader(facility, outCargo, inCargo)

  M.drawFacilityOutCargo(facility, outCargo)
  M.drawFacilityInCargo(facility, inCargo)




  im.Dummy(im.ImVec2(1,1))
  im.Separator()
  im.Dummy(im.ImVec2(1,1))
end


local facilityToDraw = "auto"
local function allCargoFilter() return true end
local function drawDebugMenu()
  if im.Begin("Parcel Debug") then

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
        local spot = fac.accessPointsByName[tableKeysSorted(fac.accessPointsByName)[1]].ps
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


local function drawFacilityHeader(facility, outCargo, inCargo, ignoreGenerators)
  im.PushStyleColor2(im.Col_PlotHistogram, im.ImVec4(0.6, 0.5, 0.25, 0.8))
  im.BeginTable("facilities", 4, tableFlags)
  im.TableNextColumn()
  im.Text("Name")
  im.TableNextColumn()
  im.Text("Current Cargo")
  im.TableNextColumn()
  im.Text("New Cargo in")
  im.TableNextColumn()
  im.Text("Actions")
  im.TableNextColumn()
  im.PushFont3("cairo_semibold_large")
  im.TextColored(im.ImVec4(1,0.6,0,8,0.75),_tr(facility.name))
  im.PopFont()
  im.TableNextColumn()
  im.Text(string.format("Out: %d / %d | In: %d ", #outCargo, facility.logisticMaxItems, #inCargo))
  im.TableNextColumn()
--[[
  if dProgress.isFacilityVisible(facility.id) then
    im.TextColored(im.ImVec4(0,1,0,0.75),"Visible ")
  else
    im.TextColored(im.ImVec4(1,0,0,0.75),"Invisible ")
  end
  im.SameLine()

  if dProgress.isFacilityUnlocked(facility.id) then
    im.TextColored(im.ImVec4(0,1,0,0.75),"Unlocked ")
  else
    im.TextColored(im.ImVec4(1,0,0,0.75),"Locked ")
  end
  ]]
  im.TableNextColumn()
  if im.Button("Clear##"..facility.id) then
    for _, item in ipairs(outCargo) do
      item.offerExpiresAt = dGeneral.time()-1
    end
  end

  im.TableNextColumn()
  --im.Text(string.format("Prog Out: %d (%0.2f$)", facility.progress.itemsDeliveredFromHere.count, facility.progress.itemsDeliveredFromHere.moneySum))
  im.TableNextColumn()
  --im.Text(string.format("Prog In: %d (%0.2f$)", facility.progress.itemsDeliveredToHere.count, facility.progress.itemsDeliveredToHere.moneySum))
  im.TableNextColumn()
  if not ignoreGenerators then
    for _, generator in ipairs(facility.logisticGenerators) do

      im.ProgressBar(((generator.nextGenerationTimestamp - dGeneral.time())/generator.interval), im.ImVec2(100,im.GetTextLineHeight()),string.format("%s", secondsToClock(generator.nextGenerationTimestamp - dGeneral.time())))
      im.SameLine()
      im.Text(dumps(generator.type) .. " => " .. table.concat(generator.logisticTypes, ", "))
    end
  end
  im.TableNextColumn()
  if not im.TableNextColumn() then
    for i, generator in ipairs(facility.logisticGenerators) do
      if im.Button("Generate##"..facility.id..i) then
        dGenerator.triggerGenerator(facility, generator)
      end
    end
  end
  im.EndTable()
end


local function drawFacilityOutCargo(facility, outCargo)
  im.BeginTable("cargo", 9, tableFlags)
  im.TableNextColumn()
  im.Text("Id")
  im.TableNextColumn()
  im.Text("Name")
  im.TableNextColumn()
  im.Text("Slots")
  im.TableNextColumn()
  im.Text("Expires In")
  im.TableNextColumn()
  im.Text("Destination")
  im.TableNextColumn()
  im.Text("Distance")
  im.TableNextColumn()
  im.Text("Rewards")
  im.TableNextColumn()
  im.Text("Actions")
  im.TableNextColumn()
  im.Text("Modifiers")

  for _, item in ipairs(outCargo) do
    dGenerator.finalizeParcelItemDistanceAndRewards(item)
    --local expired = item.offerExpiresAt - dGeneral.time() < 0
    --if expired or item.data.delivered then im.BeginDisabled() end

    im.TableNextColumn()
    im.Text(""..item.id.." "..item.generatorLabel)
    im.TableNextColumn()
    im.Text(item.name)
    im.TableNextColumn()
    im.Text(string.format("%d %s", item.slots, item.type))
    im.TableNextColumn()

    im.ProgressBar(clamp((item.offerExpiresAt - dGeneral.time())/120,0,1), im.ImVec2(100,im.GetTextLineHeight()), string.format("%s",secondsToClock(item.offerExpiresAt - dGeneral.time())))
    im.TableNextColumn()
    im.Text(dParcelManager.getLocationLabelLong(item.destination))
    im.TableNextColumn()
    im.Text(string.format("%0.1fkm", item.data.originalDistance/1000))
    im.TableNextColumn()
    local rewards = {}
    for _, key in ipairs(overhaul_career_progression_skills.orderAttributeKeysByBranchOrder(tableKeys(item.rewards or {}))) do
      table.insert(rewards, key=="money" and string.format("%0.2f$",item.rewards[key]) or string.format("%s: %d", key, item.rewards[key]))
    end
    im.TextWrapped(table.concat(rewards, " | "))
    im.TableNextColumn()
    if im.Button("X##"..item.id) then
      item.offerExpiresAt = dGeneral.time() - 1
    end
    im.SameLine()
    if im.Button("Extend##"..item.id) then
      item.offerExpiresAt = item.offerExpiresAt + 300
    end
    im.SameLine()
    if im.Button("Deliver##"..item.id) then
      dParcelManager.changeCargoLocation(item.id, item.destination)
      dParcelManager.checkDeliveredCargo()
    end
    local modifiers = {}
    im.TableNextColumn()
    if item.modifiers and #item.modifiers > 0 then
      for _, mod in ipairs(item.modifiers) do
        table.insert(modifiers, mod.type)
      end
    end
    im.TextWrapped(table.concat(modifiers, " | "))
  end
  im.EndTable()

  im.PopStyleColor()
end

local function drawFacilityInCargo(facility, inCargo)

  im.BeginTable("cargoIn", 8, tableFlags)
  im.TableNextColumn()
  im.Text("Id")
  im.TableNextColumn()
  im.Text("Name")
  im.TableNextColumn()
  im.Text("Slots")
  im.TableNextColumn()
  im.Text("Expires In")
  im.TableNextColumn()
  im.Text("Origin")
  im.TableNextColumn()
  im.Text("Distance")
  im.TableNextColumn()
  im.Text("Rewards")
  im.TableNextColumn()
  im.Text("Actions")
  im.PushStyleColor2(im.Col_PlotHistogram, im.ImVec4(0.6, 0.30, 0.45, 0.8))
  for _, item in ipairs(inCargo) do
    dGenerator.finalizeParcelItemDistanceAndRewards(item)
    --local expired = item.offerExpiresAt - dGeneral.time() < 0
    --if expired or item.data.delivered then im.BeginDisabled() end

    im.TableNextColumn()
    im.Text(""..item.id.." "..item.generatorLabel)
    im.TableNextColumn()
    im.Text(item.name)
    im.TableNextColumn()
    im.Text(string.format("%d %s", item.slots, item.type))
    im.TableNextColumn()

    im.ProgressBar(clamp((item.offerExpiresAt - dGeneral.time())/120,0,1), im.ImVec2(100,im.GetTextLineHeight()), string.format("%s",secondsToClock(item.offerExpiresAt - dGeneral.time())))
    im.TableNextColumn()
    im.Text(dParcelManager.getLocationLabelLong(item.origin))
    im.TableNextColumn()
    im.Text(string.format("%0.1fkm", item.data.originalDistance/1000))
    im.TableNextColumn()
    local rewards = {}
    for _, key in ipairs(overhaul_career_progression_skills.orderAttributeKeysByBranchOrder(tableKeys(item.rewards or {}))) do
      table.insert(rewards, key=="money" and string.format("%0.2f$",item.rewards[key]) or string.format("%s: %d", key, item.rewards[key]))
    end

    im.TextWrapped(table.concat(rewards, " | "))
    im.TableNextColumn()
    if im.Button("X##"..item.id) then
      item.offerExpiresAt = dGeneral.time() - 1
    end
    im.SameLine()
    if im.Button("Extend##"..item.id) then
      item.offerExpiresAt = item.offerExpiresAt + 300
    end
    im.SameLine()
    if im.Button("Deliver##"..item.id) then
      dParcelManager.changeCargoLocation(item.id, {type = "delivered"})
      dParcelManager.checkDeliveredCargo()
    end
    --if expired or item.data.delivered then im.EndDisabled() end
  end
  im.EndTable()
  im.PopStyleColor()
end

M.drawFacilityHeader = drawFacilityHeader
M.drawFacilityOutCargo = drawFacilityOutCargo
M.drawFacilityInCargo = drawFacilityInCargo

return M
