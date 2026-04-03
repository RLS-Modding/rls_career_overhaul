-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local saveRoot = 'settings/cloud/saves/'
local saveSystemVersion = 61
local backwardsCompVersion = 36
local numberOfAutosaves = 3
local creationDateOfCurrentSaveSlot
local queueSave = false
local pendingVehiclesThumbnailUpdate

local currentSaveSlot
local currentSavePath

-- Start Nisch additions
local ffbDisabledForSave = false
local ffbSettleFrames = 0
local ffbRestoreFrames = 0
local FFB_SETTLE_DELAY = 20
local FFB_RESTORE_DELAY = 10
-- End Nisch additions

local function getAllAutosaves(slotName)
  local res = {}
  local folders = FS:directoryList(saveRoot .. slotName, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    local data = jsonReadFile(dir .. filename .. "/info.json")
    if data then
      data.name = filename
      table.insert(res, data)
    end
  end

  table.sort(res, function(a,b) return tostring(a.date) < tostring(b.date) end)
  return res
end

local function getAutosave(slotName, oldest)
  local allAutosaves = getAllAutosaves(slotName)
  local path = saveRoot .. slotName

  if (tableSize(allAutosaves) < numberOfAutosaves) and oldest then
    local folders = FS:directoryList(path, false, true)
    for i = 1, numberOfAutosaves do
      local possiblePath = path .. "/autosave" .. i
      if not tableContains(folders, "/" .. possiblePath) then
        return possiblePath, "0"
      end
    end
  end

  if tableSize(allAutosaves) > 0 then
    local targetSave
    if oldest then
      targetSave = allAutosaves[1]
    else
      targetSave = allAutosaves[tableSize(allAutosaves)]
    end

    if targetSave then
      return path .. "/" .. targetSave.name, targetSave.date or "0"
    end
  end

  return nil, oldest and "A" or "0"
end

local function isLegalDirectoryName(name)
  return not string.match(name, '[<>:"/\\|?*]')
end

local function setSaveSlot(slotName, specificAutosave)
  extensions.hook("onBeforeSetSaveSlot")
  if not slotName then
    currentSavePath = nil
    currentSaveSlot = nil
    creationDateOfCurrentSaveSlot = nil
    extensions.hook("onSetSaveSlot", nil, nil)
    return false
  end
  if not isLegalDirectoryName(slotName) then
    return false
  end
  
  local savePath
  if specificAutosave then
    savePath = saveRoot .. slotName .. "/" .. specificAutosave
  else
    local allAutosaves = getAllAutosaves(slotName)
    if tableSize(allAutosaves) == 0 then
      savePath = saveRoot .. slotName .. "/autosave1"
    else
      savePath = getAutosave(slotName, false)
    end
  end
  
  if not savePath or savePath == "" then
    savePath = saveRoot .. slotName .. "/autosave1"
  end

  local data = jsonReadFile(savePath .. "/info.json")
  if data then
    if not data.version or M.getBackwardsCompVersion() > data.version then
      return false
    end
    creationDateOfCurrentSaveSlot = data.creationDate
  else
    creationDateOfCurrentSaveSlot = nil
  end

  currentSavePath = savePath
  currentSaveSlot = slotName

  extensions.hook("onSetSaveSlot", currentSavePath, slotName)
  return true
end

local function removeSaveSlot(slotName)
  if currentSaveSlot == slotName then
    if not career_career.isActive() then
      setSaveSlot(nil)
      FS:directoryRemove(saveRoot .. slotName)
    end
  else
    FS:directoryRemove(saveRoot .. slotName)
  end
end

local function renameFolderRec(oldName, newName, oldNameLength)
  local success = true
  local folders = FS:directoryList(oldName, true, true)
  for i = 1, tableSize(folders) do
    if FS:directoryExists(folders[i]) then
      if not renameFolderRec(folders[i], newName, oldNameLength) then
        success = false
      end
    else
      local newPath = string.sub(folders[i], oldNameLength + 2)
      newPath = newName .. newPath
      if FS:renameFile(folders[i], newPath) == -1 then
        success = false
      end
    end
  end
  return success
end

local function renameFolder(oldName, newName)
  local oldNameLength = string.len(oldName)
  if renameFolderRec(oldName, newName, oldNameLength) then
    -- If the renaming of all files was successful, remove the old folder
    FS:directoryRemove(oldName)
    return true
  end
end

local function renameSaveSlot(slotName, newName)
  if not isLegalDirectoryName(slotName) or not FS:directoryExists(saveRoot .. slotName)
  or FS:directoryExists(saveRoot .. newName) then
    return false
  end

  if currentSaveSlot == slotName then
    if not career_career.isActive() then
      setSaveSlot(nil)
      return renameFolder(saveRoot .. slotName, saveRoot .. newName)
    end
  else
    return renameFolder(saveRoot .. slotName, saveRoot .. newName)
  end
end

local function duplicateSaveSlot(slotName, newName)
  if not isLegalDirectoryName(slotName) or not isLegalDirectoryName(newName) then
    return false
  end
  if slotName == newName then
    return false
  end
  local src = saveRoot .. slotName
  local dst = saveRoot .. newName
  if not FS:directoryExists(src) or FS:directoryExists(dst) then
    return false
  end

  if currentSaveSlot == slotName and career_career.isActive() then
    M.saveCurrent(nil, true)
  end

  local files = FS:findFiles(src .. "/", "*.*", -1, true, true)
  if not files or tableSize(files) == 0 then
    return false
  end

  local ok = true
  for i = 1, tableSize(files) do
    local srcPath = files[i]
    if not FS:directoryExists(srcPath) then
      local dstPath = dst .. string.sub(srcPath, #src + 2)
      local parentDir = path.split(dstPath)
      if parentDir and parentDir ~= "" and not FS:directoryExists(parentDir) then
        FS:directoryCreate(parentDir, true)
      end
      if FS:copyFile(srcPath, dstPath) ~= 0 then
        ok = false
        break
      end
    end
  end

  if not ok then
    FS:directoryRemove(dst)
    return false
  end
  return true
end

local function getCurrentSaveSlot()
  return currentSaveSlot, currentSavePath
end

local syncSaveExtensionsDone
local asyncSaveExtensions = {}
local infoData
local saveDate
local oldestSave, oldSaveDate

local function saveFailed()
  infoData = nil
end

local function jsonWriteFileSafe(filename, obj, pretty, numberPrecision, tempFileName)
  tempFileName = tempFileName or filename..".tmp"
  if jsonWriteFile(tempFileName, obj, pretty, numberPrecision) then
    if FS:renameFile(tempFileName, filename) == 0 then
      return true
    else
      log("E", "save", "failed to copy temporary json!")
    end
  else
    log("E", "save", "failed to write json!")
  end
  saveFailed()
  return false
end

local function getFFBConfigForVeh(veh)
  local result = {}
  for _, action in ipairs({"steering", "accelerate", "brake"}) do
    local FFBID = veh:getFFBID(action)
    if FFBID >= 0 then
      local configStr = be:getFFBConfig(FFBID)
      local ok, ffbConfig = pcall(json.decode, configStr)
      if ok and ffbConfig then
        local ok2, ffbParams = pcall(json.decode, ffbConfig.ffbParamsJson)
        if ok2 and ffbParams then
          ffbConfig.ffbParams = ffbParams
          ffbConfig.FFBID = FFBID
          result[action] = ffbConfig
        end
      end
    end
  end
  return result
end

local function restoreFFBActual()
  local playerVeh = be:getPlayerVehicle(0)
  if playerVeh then
    playerVeh:queueLuaCommand("hydros.enableFFB = true")
    local ffbConfig = getFFBConfigForVeh(playerVeh)
    if ffbConfig and next(ffbConfig) then
      playerVeh:queueLuaCommand("hydros.onFFBConfigChanged("..serialize(ffbConfig)..")")
    end
  end
  ffbDisabledForSave = false
end

local function restoreFFB()
  if not ffbDisabledForSave then return end
  ffbRestoreFrames = FFB_RESTORE_DELAY
end

local function saveCompleted()
  if infoData then
    infoData.corrupted = nil
    infoData.date = saveDate
    if jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
      guihooks.trigger("toastrMsg", {type="success", title="Game Saved", msg=""})
      log("I", "Saved to " .. oldestSave)
      currentSavePath = oldestSave -- update the currentSavePath
      restoreFFB() -- Restore the FFB
      extensions.hook("onSaveFinished")
      return
    end
  end

  restoreFFB()
  guihooks.trigger("toastrMsg", {type="error", title="Game Save failed", msg= "Saving failed!"})
  log("E", "Saving to " .. oldestSave ..  " failed!")
end

local function registerAsyncSaveExtension(extName)
  asyncSaveExtensions[extName] = true
end

local function asyncSaveExtensionFinished(extName)
  asyncSaveExtensions[extName] = nil
  if syncSaveExtensionsDone and tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

local saveCurrentActual

local function disableFFBForSave()
  local playerVeh = be:getPlayerVehicle(0)
  if playerVeh then
    playerVeh:queueLuaCommand("hydros.destroy(); hydros.enableFFB = false")
    ffbDisabledForSave = true
    ffbSettleFrames = FFB_SETTLE_DELAY
  else --No Vehicle
    saveCurrentActual(pendingVehiclesThumbnailUpdate)
    pendingVehiclesThumbnailUpdate = nil
    queueSave = false
  end
end

saveCurrentActual = function(vehiclesThumbnailUpdate)
  if not currentSaveSlot or career_modules_linearTutorial.isLinearTutorialActive() then return end
  oldestSave, oldSaveDate = getAutosave(currentSaveSlot, true) -- get oldest autosave to overwrite
  saveDate = os.date("!%Y-%m-%dT%H:%M:%SZ") -- UTC time

  infoData = {}
  infoData.version = saveSystemVersion
  infoData.date = "0"
  creationDateOfCurrentSaveSlot = creationDateOfCurrentSaveSlot or saveDate
  infoData.creationDate = creationDateOfCurrentSaveSlot
  infoData.corrupted = true

  if not jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
    saveFailed()
    saveCompleted()
    return
  end

  syncSaveExtensionsDone = false
  extensions.hook("onSaveCurrentSaveSlotAsyncStart")
  extensions.hook("onSaveCurrentSaveSlot", oldestSave, oldSaveDate, vehiclesThumbnailUpdate)
  syncSaveExtensionsDone = true
  if tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

local function mergeVehiclesThumbnailUpdate(incoming)
  if type(incoming) ~= "table" then return end
  pendingVehiclesThumbnailUpdate = pendingVehiclesThumbnailUpdate or {}
  for _, inventoryId in ipairs(incoming) do
    if inventoryId and not tableContains(pendingVehiclesThumbnailUpdate, inventoryId) then
      table.insert(pendingVehiclesThumbnailUpdate, inventoryId)
    end
  end
end

local function saveCurrent(vehiclesThumbnailUpdate, force)
  mergeVehiclesThumbnailUpdate(vehiclesThumbnailUpdate)
  queueSave = true
  if force then
    saveCurrentActual(pendingVehiclesThumbnailUpdate)
    pendingVehiclesThumbnailUpdate = nil
    queueSave = false
  end
end

local function onUpdate()
  if ffbRestoreFrames > 0 then
    ffbRestoreFrames = ffbRestoreFrames - 1
    if ffbRestoreFrames == 0 then
      restoreFFBActual()
    end
    return
  end

  if ffbSettleFrames > 0 then
    ffbSettleFrames = ffbSettleFrames - 1
    if ffbSettleFrames == 0 then
      saveCurrentActual(pendingVehiclesThumbnailUpdate)
      pendingVehiclesThumbnailUpdate = nil
      queueSave = false
    end
    return
  end

  if queueSave then
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh or playerVeh:getVelocity():length() < 2 then
      disableFFBForSave()
    end
  end
end

local function getAllSaveSlots()
  local res = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    table.insert(res, filename)
  end
  return res
end

local function onExtensionLoaded()
end

local function getSaveRootDirectory()
  return saveRoot
end

local function onSerialize()
  local data = {}
  data.currentSaveSlot = currentSaveSlot
  data.currentSavePath = currentSavePath
  data.creationDateOfCurrentSaveSlot = creationDateOfCurrentSaveSlot
  return data
end

local function onDeserialized(v)
  currentSaveSlot = v.currentSaveSlot
  currentSavePath = v.currentSavePath
  creationDateOfCurrentSaveSlot = v.creationDateOfCurrentSaveSlot
end

local function getSaveSystemVersion()
  return saveSystemVersion
end

local function getBackwardsCompVersion()
  return backwardsCompVersion
end

M.onUpdate = onUpdate
M.setSaveSlot = setSaveSlot
M.removeSaveSlot = removeSaveSlot
M.renameSaveSlot = renameSaveSlot
M.duplicateSaveSlot = duplicateSaveSlot
M.getCurrentSaveSlot = getCurrentSaveSlot
M.saveCurrent = saveCurrent
M.getAllSaveSlots = getAllSaveSlots
M.getSaveRootDirectory = getSaveRootDirectory
M.getAutosave = getAutosave
M.getAllAutosaves = getAllAutosaves
M.getSaveSystemVersion = getSaveSystemVersion
M.getBackwardsCompVersion = getBackwardsCompVersion
M.saveFailed = saveFailed
M.registerAsyncSaveExtension = registerAsyncSaveExtension
M.asyncSaveExtensionFinished = asyncSaveExtensionFinished
M.jsonWriteFileSafe = jsonWriteFileSafe

M.onExtensionLoaded = onExtensionLoaded
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
