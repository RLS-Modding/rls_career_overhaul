-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/vehicleShoppingDebug.lua (BeamNG 0.40).
local M = {}
local im = ui_imgui
M.debugOrder = 0
M.debugName = "Vehicle Shopping"

local search = im.ArrayChar(512)
local simVehiclesPerDealer = im.IntPtr(10)

local resultsCache = nil
local lastCalcInfo = { tookMs = 0, eligibleCount = 0 }

local function ensureDeps()
  extensions.load("util/configListGenerator")
  extensions.load("freeroam/facilities")
end

-- re-read facilities files from disk so we always get the latest dealerships
local function loadDealershipsFromFiles()
  local list = {}
  local levelName = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if not levelName or levelName == '' then return list end
  local levelInfo = core_levels.getLevelByName(levelName)
  if not levelInfo or not levelInfo.dir then return list end
  for _, file in ipairs(FS:findFiles(levelInfo.dir.."/facilities/", '*.facilities.json', -1, false, true) or {}) do
    local data = jsonReadFile(file)
    if data then
      for _, d in ipairs(data.dealerships or {}) do
        table.insert(list, d)
      end
      for _, d in ipairs(data.privateSellers or {}) do
        table.insert(list, d)
      end
    end
  end
  return list
end

local function aggregateFiltersForSeller(seller)
  local aggregated = {}
  if seller.subFilters and not tableIsEmpty(seller.subFilters) then
    for _, sub in ipairs(seller.subFilters) do
      local agg = deepcopy(seller.filter or {})
      tableMergeRecursive(agg, sub)
      table.insert(aggregated, agg)
    end
  else
    table.insert(aggregated, seller.filter or {})
  end
  return aggregated
end

local function recompute()
  ensureDeps()
  local timer = hptimer()

  local dealerships = loadDealershipsFromFiles() or {}
  local eligible = util_configListGenerator.getEligibleVehicles() or {}
  lastCalcInfo.eligibleCount = #eligible

  local out = {}
  for _, dealer in ipairs(dealerships) do
    local dealerEntry = { id = dealer.id, name = dealer.name or dealer.id, subFilters = {} }
    local filters = aggregateFiltersForSeller(dealer)
    -- compute sum of probabilities (defaulting missing values to 1, same as generator)
    local sumProb = 0
    for _, f in ipairs(filters) do
      sumProb = sumProb + (f.probability or 1)
    end
    if sumProb <= 0 then sumProb = #filters > 0 and #filters or 1 end
    for idx, filter in ipairs(filters) do
      local matches = {}
      for _, vehInfo in ipairs(eligible) do
        if util_configListGenerator.doesVehiclePassFilter(vehInfo, filter) then
          table.insert(matches, {
            model = vehInfo.model_key,
            config = vehInfo.key,
            name = vehInfo.Name or (vehInfo.model_key .. " - " .. vehInfo.key)
          })
        end
      end
      local rawP = filter.probability or 1
      local normP = rawP / sumProb
      table.insert(dealerEntry.subFilters, { index = idx, probability = filter.probability, normalizedProbability = normP, filter = filter, matches = matches })
    end
    table.insert(out, dealerEntry)
  end

  lastCalcInfo.tookMs = timer:stop()
  resultsCache = out
end

local vehiclesInShop = {}
local function simulateDealerships()
  vehiclesInShop = {}
  local sellers = loadDealershipsFromFiles() or {}
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles()
  for _, seller in ipairs(sellers) do
    local randomVehicleInfos = {}
    local numberOfVehiclesToGenerate = simVehiclesPerDealer[0]
    log("I", "Career", "Generating " .. numberOfVehiclesToGenerate .. " vehicles for " .. seller.id)

    -- generate the vehicles without duplicating vehicles that are already in the dealership
    local eligibleVehiclesWithoutDealershipVehicles = overhaul_career_market_vehicleShopping.getEligibleVehiclesWithoutDealershipVehicles(eligibleVehicles, seller)
    local newRandomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, numberOfVehiclesToGenerate, eligibleVehiclesWithoutDealershipVehicles, "adjustedPopulation")
    arrayConcat(randomVehicleInfos, newRandomVehicleInfos)

    -- generate the remaining vehicles without a duplicate check
    local numberOfMissingVehicles = numberOfVehiclesToGenerate - tableSize(newRandomVehicleInfos)
    if numberOfMissingVehicles > 0 then
      log("I", "Career", "Generating " .. numberOfMissingVehicles .. " more vehicles without duplicate check for " .. seller.id)
      for i = 1, numberOfMissingVehicles do
        local newRandomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 1, eligibleVehicles, "adjustedPopulation")
        arrayConcat(randomVehicleInfos, newRandomVehicleInfos)
      end
    end

    for i, randomVehicleInfo in ipairs(randomVehicleInfos) do
      randomVehicleInfo.sellerId = seller.id
    end
    arrayConcat(vehiclesInShop, randomVehicleInfos)
  end
end

M.drawDebugMenu = function()
  if im.Begin("Vehicle Shopping - SubFilter Matches") then
    if im.Button("Refresh") then
      recompute()
    end
    im.SameLine()

    im.Text(string.format("Eligible: %d", lastCalcInfo.eligibleCount or 0))
    im.SameLine()
    im.Text(string.format("Last calc: %dms", lastCalcInfo.tookMs or 0))

    im.SeparatorText("Filtered configs")
    im.InputText("Search", search, 512)
    local s = ffi.string(search):lower()

    if resultsCache then
      for _, dealer in ipairs(resultsCache) do
        if im.CollapsingHeader1(string.format("%s (%s)", dealer.name, dealer.id)) then
          for _, sub in ipairs(dealer.subFilters) do
            im.Separator()
            im.Text(string.format("SubFilter #%d  (p=%s, prob=%.3f) - %d matches", sub.index, tostring(sub.probability or 1), sub.normalizedProbability or 0, #sub.matches))
            if im.BeginTable("tbl_"..dealer.id.."_"..sub.index, 3, bit.bor(im.TableFlags_Resizable, im.TableFlags_RowBg, im.TableFlags_Borders, im.TableFlags_SizingStretchSame)) then
              im.TableSetupColumn("Model")
              im.TableSetupColumn("Config")
              im.TableSetupColumn("Name")
              im.TableHeadersRow()
              for _, m in ipairs(sub.matches) do
                if s == '' or string.find((m.model or ''):lower(), s, 1, true) or string.find((m.config or ''):lower(), s, 1, true) or string.find((m.name or ''):lower(), s, 1, true) then
                  im.TableNextRow()
                  im.TableSetColumnIndex(0); im.Text(m.model or "-")
                  im.TableSetColumnIndex(1); im.Text(m.config or "-")
                  im.TableSetColumnIndex(2); im.Text(m.name or "-")
                end
              end
              im.EndTable()
            end
          end
        end
      end
    else
      im.Text("Press Refresh to compute matches.")
    end

    -- Simulation controls and results
    im.Dummy(im.ImVec2(0, 30))
    im.SeparatorText("Simulated dealerships")
    if im.Button("Simulate Dealerships") then
      simulateDealerships()
    end
    im.SameLine()

    im.SetNextItemWidth(180)
    im.InputInt("Vehicles per dealership", simVehiclesPerDealer)
    if simVehiclesPerDealer[0] < 1 then simVehiclesPerDealer[0] = 1 end
    if simVehiclesPerDealer[0] > 100 then simVehiclesPerDealer[0] = 100 end

    if not tableIsEmpty(vehiclesInShop) then
      -- Build a mapping of sellerId -> vehicles for display
      local sellersById = {}
      for _, d in ipairs(loadDealershipsFromFiles() or {}) do
        sellersById[d.id] = d
      end

      local vehiclesBySeller = {}
      for _, veh in ipairs(vehiclesInShop) do
        local sid = veh.sellerId or "unknown"
        vehiclesBySeller[sid] = vehiclesBySeller[sid] or {}
        table.insert(vehiclesBySeller[sid], veh)
      end

      im.Columns(2, "simDealersCols")
      for sellerId, list in pairs(vehiclesBySeller) do
        local dealer = sellersById[sellerId]
        local header = string.format("Simulated: %s (%s) - %d vehicles", dealer and (dealer.name or dealer.id) or sellerId, sellerId, #list)
        if im.CollapsingHeader1(header) then
          if im.BeginTable("simtbl_"..tostring(sellerId), 3, bit.bor(im.TableFlags_Resizable, im.TableFlags_RowBg, im.TableFlags_Borders, im.TableFlags_SizingStretchSame)) then
            im.TableSetupColumn("Model")
            im.TableSetupColumn("Config")
            im.TableSetupColumn("Name")
            im.TableHeadersRow()
            for _, v in ipairs(list) do
              im.TableNextRow()
              im.TableSetColumnIndex(0); im.Text(v.model_key or "-")
              im.TableSetColumnIndex(1); im.Text(v.key or "-")
              im.TableSetColumnIndex(2); im.Text(v.Name or ((v.model_key or "-") .. " - " .. (v.key or "-")))
            end
            im.EndTable()
          end
        end
        im.NextColumn()
      end
      im.Columns(1)
    else
      im.Text("Press 'Simulate Dealerships' to generate simulated inventories.")
    end
  end
  im.End()
end

return M