-- Restores game-wide materials that a previously loaded map redefined.
-- A map that redefines a shared material edits it in place, and the edit outlives that map, so the
-- next map draws it with the old map's textures, or "NO TEXTURE" when those files are gone.
local M = {}

local function normalize(path)
  if type(path) ~= 'string' or path == '' then return nil end
  return path:gsub('\\', '/'):gsub('^/', ''):lower()
end

local function levelOf(path)
  local normalized = normalize(path)
  return normalized and normalized:match('^levels/([^/]+)/')
end

local function liveColorMap(material, layer)
  for _, field in ipairs({'baseColorMap', 'colorMap'}) do
    local ok, path = pcall(material.getField, material, field, layer)
    if ok and path ~= nil and path ~= '' then return path end
  end
end

local function fileColorMap(stage)
  return type(stage) == 'table' and (stage.baseColorMap or stage.colorMap) or nil
end

-- The material file's own definition of each material it declares, keyed by lower-case name.
local function readDefinitions(fileName)
  local data = jsonReadFile(fileName)
  if type(data) ~= 'table' then return nil end
  local definitions = {}
  for key, entry in pairs(data) do
    if type(entry) == 'table' and tostring(entry.class or ''):lower() == 'material' then
      definitions[tostring(entry.name or key):lower()] = entry
    end
  end
  return definitions
end

-- A shared material belongs to another map when its live texture points into that map's folder
-- while its own file says otherwise. The current map's own redefinitions are left alone.
local function findOverwritten(currentLevel)
  local byFile, keepFile = {}, {}
  for _, name in ipairs(scenetree.findClassObjects('Material') or {}) do
    local material = scenetree.findObject(name)
    local fileName = material and material:getFileName() or ''
    local normalizedFile = normalize(fileName)
    if normalizedFile and not normalizedFile:find('^levels/') and not normalizedFile:find('^vehicles/') then
      for layer = 0, 3 do
        local owner = levelOf(liveColorMap(material, layer))
        if owner then
          if owner == currentLevel then keepFile[fileName] = true
          else
            byFile[fileName] = byFile[fileName] or {}
            table.insert(byFile[fileName], name)
          end
          break
        end
      end
    end
  end
  for fileName in pairs(keepFile) do byFile[fileName] = nil end
  return byFile
end

local function differsFromFile(material, definition)
  if not definition then return false end
  for layer = 0, 3 do
    local stage = type(definition.Stages) == 'table' and definition.Stages[layer + 1] or nil
    if normalize(liveColorMap(material, layer)) ~= normalize(fileColorMap(stage)) then return true end
  end
  return false
end

function M.repair(levelName)
  local currentLevel = normalize(levelName)
  local repaired = 0
  for fileName, names in pairs(findOverwritten(currentLevel)) do
    local definitions = FS:fileExists(fileName) and readDefinitions(fileName)
    local overwritten = {}
    for _, name in ipairs(names) do
      local material = scenetree.findObject(name)
      if material and differsFromFile(material, definitions and definitions[name:lower()]) then
        table.insert(overwritten, material)
      end
    end
    if #overwritten > 0 then
      loadJsonMaterialsFile(fileName)
      for _, material in ipairs(overwritten) do material:reload() end
      repaired = repaired + #overwritten
    end
  end
  if repaired > 0 then
    log('I', 'overhaul.sharedMaterials', string.format('Restored %d shared material(s) a previous map redefined', repaired))
  end
  return repaired
end

return M
