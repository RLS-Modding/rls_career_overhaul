local M = {}

local isCheatsMode = false
local infoFile = "info.json"

local saveFile = "cheats.json"
local saveData = {}

local function onCareerActive(active)
    if not active then return false end
    local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
    saveData = savePath and jsonReadFile(savePath .. "/career/rls_career/" .. saveFile) or {}
  
    if not next(saveData) then
        saveData = {
            cheatsMode = false
        }
    end
    
    if saveData.cheatsMode == nil then
        saveData.cheatsMode = false
    end
    
    isCheatsMode = saveData.cheatsMode == true
    extensions.hook("onCheatsModeChanged", isCheatsMode)
end

local function onSaveCurrentSaveSlot(currentSavePath)
    career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/rls_career/" .. saveFile, saveData, true)
end

M.enableCheatsMode = function(enabled)
    if enabled and not isCheatsMode then
        isCheatsMode = true
        saveData.cheatsMode = true
        extensions.hook("onCheatsModeChanged", isCheatsMode)
    end
end

M.isCheatsMode = function()
    return isCheatsMode or false
end

M.onCareerActive = onCareerActive
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
