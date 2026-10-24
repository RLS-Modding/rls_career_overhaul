-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/debug/dealershipFilterDebug.lua (BeamNG 0.40).
local M = {}
M.debugOrder = 11
M.debugName = "General > Filter Debug"
local imguiUtils = require('ui/imguiUtils')
local im = ui_imgui
local red = im.ImVec4(1,0.4,0.4,0.75)
local yellow = im.ImVec4(0.8,0.8,0.2,0.75)
local green = im.ImVec4(0.2,1,0.4,0.75)
local tableFlags = bit.bor(im.TableFlags_Resizable,im.TableFlags_RowBg,im.TableFlags_Borders)
local includeAux = im.BoolPtr(false)
local includeLoads = im.BoolPtr(true)
local vehicleCount = im.IntPtr(10)
local sampleCount = im.IntPtr(100)

local textLen = 256*(1024)
local text = im.ArrayChar(textLen)
local search = im.ArrayChar(1280)
local defaultFilter = [[
  {
    "filter": {
      "whiteList":{"Years": {"max":2005}, "Mileage":{"min":175000000, "max":370000000}, "Value":{"min":1000, "max":60000},"Type":["Car"], "Config Type":["Factory"],"Population":{"min":1099}},
      "blackList":{"Type":["Trailer"]}
    },
    "subFilters": [
      {
        "probability":1,
        "whiteList":{"Years":{"min":1990, "max":2005}, "Mileage":{"min":240000000, "max":385000000}, "Config Type":["Service"], "Configuration":["Taxi (A)"]},
      },
      {
        "probability":1,
        "whiteList":{"Years":{"min":1980, "max":2006}, "Mileage":{"min":260000000, "max":385000000},"Config Type":["Service"]},
      },
      {
        "probability":1,
        "whiteList":{}
      }
    ],
  }]]
ffi.copy(text, defaultFilter)

local error = nil
local json
local init = false

local filterTime = 0

local filterResults = {}
local vehicleCounts = {}
local lastFilter = nil
local amountResults = {}
local function doFilter(filter)
  extensions.load("util/configListGenerator")
  filter = filter or lastFilter
  lastFilter = filter

  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(includeAux[0], includeLoads[0])
  local count = vehicleCount[0]
  if count == -1 then count = math.huge end
  local vehicleCounts = {}
  local timer = hptimer()
  local totalResultCount = 0
  amountResults = {}
  for i = 1, sampleCount[0] do
    filterResults = util_configListGenerator.getRandomVehicleInfos(filter, count, eligibleVehicles)
    for _, result in ipairs(filterResults) do
      local label = string.format("%s  -  %s", result.model_key, result.key)
      if not vehicleCounts[label] then
        vehicleCounts[label] = {
          result = result,
          model = result.model_key,
          config = result.key,
          mileages = {}
        }
      end

      if not result.mileage then
        if result.filter.whiteList.Mileage then
          result.mileage = randomGauss3()/3 * (result.filter.whiteList.Mileage.max - result.filter.whiteList.Mileage.min) + result.filter.whiteList.Mileage.min
        else
          result.mileage = 0
        end
      end

      table.insert(vehicleCounts[label].mileages, result.mileage)
    end
  end
  local keysSorted = tableKeys(vehicleCounts)
  table.sort(keysSorted, function(a,b) return #vehicleCounts[a].mileages > #vehicleCounts[b].mileages end)
  for _, key in ipairs(keysSorted) do
    table.insert(amountResults, vehicleCounts[key])
    print(string.format("%s -> %d (%0.2f)%%", key, #vehicleCounts[key].mileages, 100*(#vehicleCounts[key].mileages/sampleCount[0])))
  end
  filterTime = timer:stop()
  dump(filterTime)
end


local function drawDebugMenu()
  if not json then json = require("json") end
  if im.Begin("Filter Debug Input") then
    if error then
      im.PushStyleColor2(im.Col_Text, red)
      im.Text("Decoding Error")
      im.tooltip(error)
      im.PopStyleColor(im.Int(1))
    else
      im.PushStyleColor2(im.Col_Text, green)
      im.Text("All Good :)")
      im.PopStyleColor(im.Int(1))
    end
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    if im.InputTextMultiline("##facEditor", text, im.GetLengthArrayCharPtr(text), im.ImVec2(-1,-1)) then
      local content = ffi.string(text)
      local state, data = xpcall(function() return json.decode(content) end, debug.traceback)
      if state == false then
        error = data
      else
        error = nil
        doFilter(data)
      end
    end
  end
  im.End()
  if not init then
    --doFilter(json.decode(defaultFilter))
    init = true
  end

  if im.Begin("Filter Debug Results") then
    if im.Button("Regenerate") then
      doFilter()
    end
    im.SameLine()
    im.PushItemWidth(100)
    im.InputInt("generations", sampleCount)
    im.SameLine()
    im.Text("x")
    im.SameLine()
    im.InputInt("Vehs", vehicleCount)
    im.SameLine()
    im.Text(string.format("Took %dms", filterTime))

    im.InputText("Search",search, 1280)

    im.BeginTable("debugFilterResults", 4, tableFlags)
    im.TableNextColumn()
    im.Text("")
    im.TableNextColumn()
    im.Text("")
    im.TableNextColumn()
    im.Text("")
    im.TableNextColumn()
    im.Text("Info")
    local s = ffi.string(search):lower()
    for _, result in ipairs(amountResults) do
      if s == '' or string.find(result.model:lower(),s) or string.find(result.config:lower(), s) or string.find((result.result.Name or "No Name"):lower(), s) then
        im.TableNextColumn()
        im.HighlightText(result.result.Name or "No Name", s)
        if im.IsItemClicked() then
          dump(result)
        end
        im.TableNextColumn()
        im.HighlightText(result.model, s)
        im.TableNextColumn()
        im.HighlightText(result.config, s)
        im.TableNextColumn()
        im.ProgressBar((#result.mileages/sampleCount[0]), im.ImVec2(im.GetContentRegionAvailWidth(), 0), string.format("%d%%",100*(#result.mileages/sampleCount[0])))
      end
    end

    --[[
    for i, info in ipairs(filterResults) do
      im.TableNextColumn()
      im.Text(i.."")
      im.TableNextColumn()
      if not info._image then
        info._image = imguiUtils.texObj(info.preview)
      end
      local size = vec3(info._image.size.x, info._image.size.y, 0)
      if size.x > 60 then
        size = size * 60 / size.x
      end
      im.Image(info._image.tex:getID(), im.ImVec2(size.x*4, size.y*4), im.ImVec2(0, 0), im.ImVec2(1, 1))
      im.TableNextColumn()

      if im.Button(info.Name) then
        dump(info)
      end

      if not info.mileage then
         if info.filter.whiteList.Mileage then
          info.mileage = randomGauss3()/3 * (info.filter.whiteList.Mileage.max - info.filter.whiteList.Mileage.min) + info.filter.whiteList.Mileage.min
        else
          info.mileage = 0
        end
      end

      im.Text(string.format("%s %s", info.model_key, info.key))

      if info.mileage then
        im.Text(string.format("%d kkm", info.mileage/1000000))
      end
    end
    ]]
    im.EndTable()
  end
  im.End()
end



M.drawDebugMenu = drawDebugMenu
-- use this to show tool outside of career
-- extensions.load("overhaul/dev/debug/dealershipFilterDebug") overhaul_dev_debug_dealershipFilterDebug.show()
M.show = function()
  M.onUpdate = M.drawDebugMenu
  extensions.hookUpdate("onUpdate")
end

return M

