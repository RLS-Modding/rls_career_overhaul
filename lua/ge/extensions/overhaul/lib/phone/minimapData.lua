-- Road graph and terrain metadata survive phone scope unloads. Mission end
-- invalidates the departed level so edited or reloaded roads cannot go stale.
local M = {}
local levelData = require("overhaul/lib/world/levelData")
local catalog = require("overhaul/lib/platform/jsonCatalog")
local levels = {}
local revision = 0

-- Copies the visible road nodes and the links between them.
local function getNodes(mapData)
  local newNodes = {}
  if not mapData or not mapData.nodes then return newNodes end

  for nodeId, node in pairs(mapData.nodes) do
    if not node.hiddenInNavi then
      newNodes[nodeId] = {
        pos = { node.pos.x, node.pos.y },
        radius = node.radius,
        links = {},
      }
      for linkId, link in pairs(node.links or {}) do
        local targetNode = mapData.nodes[linkId]
        if targetNode and not targetNode.hiddenInNavi and not link.hiddenInNavi then
          newNodes[nodeId].links[linkId] = {
            drivability = link.drivability or 1,
            oneWay = link.oneWay or false,
          }
        end
      end
    end
  end
  return newNodes
end

local function getTerrainTiles(level)
  local config = level and jsonReadFile("levels/" .. level .. "/minimap.config.json")
  local tiles = {}
  if config ~= nil then
    if type(config) ~= "table" or type(config.terrainTiles) ~= "table" then
      log("W", "phoneMinimap", "Minimap backdrop disabled: invalid terrainTiles metadata")
      return tiles
    end
    for _, tile in ipairs(config.terrainTiles) do
      if type(tile) == "table" and type(tile.file) == "string" and tile.file ~= ""
        and type(tile.size) == "table" and type(tile.offset) == "table"
        and catalog.finite(tile.size[1]) and tile.size[1] > 0
        and catalog.finite(tile.size[2]) and tile.size[2] > 0
        and catalog.finite(tile.offset[1]) and catalog.finite(tile.offset[2]) then
        tiles[#tiles + 1] = {file = levelData.assetPath(level, tile.file):gsub("^/", ""),
          size = tile.size, offset = tile.offset}
      else
        log("W", "phoneMinimap", "Ignoring minimap tile: requires file, positive size and finite offset")
      end
    end
    return tiles
  end
  for _, name in ipairs(scenetree.findClassObjects("TerrainBlock") or {}) do
    local terrain = scenetree.findObject(name)
    if terrain then
      local blockSize = terrain:getWorldBlockSize()
      local image = terrain.minimapImage
      if type(image) == "string" and image ~= "" and catalog.finite(blockSize) and blockSize > 0 then
        local pos = terrain:getPosition()
        tiles[#tiles + 1] = {size = {blockSize, blockSize}, offset = {pos.x, pos.y + blockSize},
          file = image:gsub("^/", "")}
      end
    end
  end
  if #tiles == 0 then log("D", "phoneMinimap", "No minimap backdrop data or terrain images for current level") end
  return tiles
end

function M.get(level)
  local source = map.getMap()
  local cached = levels[level]
  if cached and cached.source == source then return cached.data end
  revision = revision + 1
  local data = {level = level, revision = revision, nodes = getNodes(source), terrainTiles = getTerrainTiles(level)}
  levels[level] = {source = source, data = data}
  return data
end

function M.invalidate(level)
  if level then levels[level] = nil end
end

return M
