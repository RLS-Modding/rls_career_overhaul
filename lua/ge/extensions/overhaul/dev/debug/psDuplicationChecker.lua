-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/psDuplicationChecker.lua (BeamNG 0.40).
local M = {}
M.debugOrder = 11
M.debugName = "Parking Spot Duplication Checker"


local im = ui_imgui

local results = {}
local filePathA, filePathB
local selectedLevel
local levelData = require("overhaul/lib/world/levelData")

local function loadLevelDefaults()
  local level = getCurrentLevelIdentifier()
  if selectedLevel == level then return end
  selectedLevel = level
  local config = level and jsonReadFile("/levels/" .. level .. "/overhaul/debug.json")
  local files = config and config.version == 1 and config.parkingCompareSites or {}
  filePathA = levelData.assetPath(level, files[1])
  filePathB = levelData.assetPath(level, files[2])
  results = {}
end


M.drawDebugFunctions = function()



end


M.compareFiles = function()
  loadLevelDefaults()
  results = {}
  if not filePathA or not filePathB then
    log("W", "psDuplicationChecker", "Parking comparison files are not configured; choose two sites files.")
    return false
  end

  local sitesA = gameplay_sites_sitesManager.loadSites(filePathA, true, true)
  local sitesB = gameplay_sites_sitesManager.loadSites(filePathB, true, true)
  if not (sitesA and sitesA.parkingSpots and sitesB and sitesB.parkingSpots) then
    log("W", "psDuplicationChecker", "Parking comparison sites are unavailable.")
    return false
  end
  for _, psA in ipairs(sitesA.parkingSpots.sorted) do
    for _, psB in ipairs(sitesB.parkingSpots.sorted) do
      local rotA, rotB = psA.rot, psB.rot
      local xA, yA, zA = rotA * vec3(psA.scl.x / 2, 0, 0), rotA * vec3(0, psA.scl.y / 2, 0), rotA * vec3(0, 0, psA.scl.z / 2)
      local xB, yB, zB = rotB * vec3(psB.scl.x / 2, 0, 0), rotB * vec3(0, psB.scl.y / 2, 0), rotB * vec3(0, 0, psB.scl.z / 2)

      if overlapsOBB_OBB(psA.pos, xA, yA, zA, psB.pos, xB, yB, zB ) then
        table.insert(results,{
          a = psA,
          b = psB
        })
      end
    end
  end
end


local function drawDebugMenu()
  loadLevelDefaults()
  if im.Begin("PS Duplication Checker") then
    if im.Button("File A Picker") then
      extensions.editor_fileDialog.openFile(
        function(data)
          filePathA = data.filepath
          print(filePathA)
        end, {{"Sites", ".sites.json"}})
    end
    if im.Button("File B Picker") then
      extensions.editor_fileDialog.openFile(
        function(data)
          filePathB = data.filepath
          print(filePathB)
        end, {{"Sites", ".sites.json"}})
    end
    im.Text("File A: " .. dumps(filePathA))
    im.Text("File B: " .. dumps(filePathB))
    if im.Button("Compare") then
      M.compareFiles()
    end
    im.Separator()
    for _, r in ipairs(results) do
      im.Selectable1(string.format("%s & %s", r.a.name or "?", r.b.name or "?"))
      r.a:drawDebug(nil,{ 1, 0.5, 0, 0.5 })
      simpleDebugText3d(r.a.name, r.a.pos)
      r.b:drawDebug(nil, { 0, 0.5, 1, 0.5 })
      simpleDebugText3d(r.b.name, r.b.pos)
    end
  end
  im.End()
end
M.drawDebugMenu = drawDebugMenu

-- extensions.load("overhaul/dev/debug/psDuplicationChecker") overhaul_dev_debug_psDuplicationChecker.show()
M.show = function()
  M.onUpdate = M.drawDebugMenu
  extensions.hookUpdate("onUpdate")
end
return M
