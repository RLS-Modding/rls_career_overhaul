local M = {}

local isCheatsMode = false
local infoFile = "info.json"

local saveFile = "cheats.json"
local saveData = {}

local function onCareerActive(active)
    if not active then return false end
    -- load from saveslot
    local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
    saveData = savePath and jsonReadFile(savePath .. "/career/rls_career/" .. saveFile) or {}
  
    if not next(saveData) then
        saveData = {
            cheatsMode = career_career.cheatsMode
        }
    end
    isCheatsMode = saveData.cheatsMode
    extensions.hook("onCheatsModeChanged", isCheatsMode)
end

local function onSaveCurrentSaveSlot(currentSavePath)
    career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/rls_career/" .. saveFile, saveData, true)
end

M.enableCheatsMode = function(enabled)
    isCheatsMode = enabled
end

M.isCheatsMode = function()
    return isCheatsMode or false
end

M.onCareerActive = onCareerActive
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
