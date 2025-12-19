-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Road drawing state variables
local kdTree = require('kdtreebox2d')
local layers = require("ui/apps/minimap/layers")
local clrTransparent = color(0,0,0,0)
local kdNodes = nil
local links = {}
local hasRoads = false

-- Road drawing function
M.drawRoads = function(p, radius, td, debugSettings, camPos, scale, dpi  )
  if not kdNodes then
    local mapNodes = map.getMap().nodes
    local StyleColorSet = ui_apps_minimap_utils.getStyleColorSet()
    local defaultStyleColorSet = ui_apps_minimap_utils.getDefaultStyleColorSet()
    local roadColor = StyleColorSet[defaultStyleColorSet].color
    local roadColorLow = StyleColorSet[defaultStyleColorSet].colorLow
    local roadColorLowest = StyleColorSet[defaultStyleColorSet].colorLowest
    -- create links table
    table.clear(links)
    kdNodes = kdTree.new()
    -- setup kdTree for map links
    local lIdx = 1
    for nid, n in pairs(map.getMap().nodes) do
      for lid, data in pairs(n.links) do
        if data.hiddenInNavi then goto continue end
        local n1 = mapNodes[nid]
        local n2 = mapNodes[lid]
        local n1Pos = n1.pos
        local n2Pos = n2.pos
        local color = data.drivability >= 0.9 and roadColor or (data.drivability > 0.25 and roadColorLow or roadColorLowest )

        table.insert(links, n1Pos.x)
        table.insert(links, n1Pos.y)
        table.insert(links, n2Pos.x)
        table.insert(links, n2Pos.y)
        --table.insert(links, n1.radius)
        --table.insert(links, n2.radius)
        --table.insert(links, 0)
        --table.insert(links, 0)
        --table.insert(links, 0)
        --table.insert(links, 0)
        table.insert(links, color)

        local minX = math.min(n1Pos.x - n1.radius, n2Pos.x - n2.radius)
        local minY = math.min(n1Pos.y - n1.radius, n2Pos.y - n2.radius)
        local maxX = math.max(n1Pos.x + n1.radius, n2Pos.x + n2.radius)
        local maxY = math.max(n1Pos.y + n1.radius, n2Pos.y + n2.radius)
        kdNodes:preLoad(lIdx, minX, minY, maxX, maxY)

        lIdx = lIdx + 5
        ::continue::
      end
    end
    hasRoads = lIdx > 1
    kdNodes:build()
  else
    --if p then p:add("Start Roads") end
    local roadBgTransparentBlack = ui_apps_minimap_utils.colors.roadBgTransparentBlack
    local scaleInverse = 1/(scale+1e-10)
    local worldToMapXY = ui_apps_minimap_utils.worldToMapXY
    local tdlineRoundEnd = td.lineRoundEnd
    dpi = dpi or 1
    local constantWidth = 2 * scaleInverse * dpi
    local constantWidthBg = constantWidth + 2 * dpi
    local layerBG = layers.ROADS_BG
    local layerFG = layers.ROADS_FG

    for lIdx in kdNodes:queryNotNested(camPos.x-radius, camPos.y-radius, camPos.x+radius, camPos.y+radius) do
      -- stats.navgraphRoadsVisible = stats.navgraphRoadsVisible + 1
      local s1X, s1Y = worldToMapXY(links[lIdx  ], links[lIdx+1])
      local s2X, s2Y = worldToMapXY(links[lIdx+2], links[lIdx+3])
      local clr = links[lIdx+4]

      tdlineRoundEnd(td, s1X, s1Y, s2X, s2Y, constantWidthBg, constantWidthBg, 0, roadBgTransparentBlack, roadBgTransparentBlack, clrTransparent, clrTransparent, 0, layerBG)
      tdlineRoundEnd(td, s1X, s1Y, s2X, s2Y, constantWidth, constantWidth, 0, clr, clr, clrTransparent, clrTransparent, 0, layerFG)
    end

    if p then p:add("Roads") end

    --if p then p:add("Draw Link") end
    if not hasRoads and not debugSettings.drawGrid then
      -- Call drawGrid from utils extension if it exists
      if ui_apps_minimap_utils.drawGrid then
        ui_apps_minimap_utils.drawGrid()
      end
    end
  end
end

-- Reset function to clear cached data
M.reset = function()
  kdNodes = nil
  hasRoads = false
end

return M