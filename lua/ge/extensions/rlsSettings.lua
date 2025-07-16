local M = {}

local settingsRoot = 'settings/RLS/'
local settingsFile = 'careerOverhaul.json'
local settingsFilePath = settingsRoot .. settingsFile

local settings = {
    mapDevMode = false,
    noPoliceMode = false,
    noParkedMode = false
}

local function saveSettings()
    if not FS:directoryExists(settingsRoot) then
        FS:directoryCreate(settingsRoot)
    end
    
    if jsonWriteFile(settingsFilePath, settings, true) then
        log('I', 'rlsSettings', 'Settings saved to: ' .. settingsFilePath)
        return true
    else
        log('E', 'rlsSettings', 'Failed to save settings to: ' .. settingsFilePath)
        return false
    end
end

local function getSetting(key)
    return settings[key]
end

local function setSetting(key, value)
    if settings[key] ~= value then
        settings[key] = value
        saveSettings()
        log('I', 'rlsSettings', 'Setting ' .. key .. ' set to: ' .. tostring(value))
    end
end

local function loadSettings()
    local data = jsonReadFile(settingsFilePath)
    if data then
        for k, v in pairs(data) do
            if settings[k] ~= nil then
                settings[k] = v
            end
        end
        log('I', 'rlsSettings', 'Settings loaded from: ' .. settingsFilePath)
    else
        log('I', 'rlsSettings', 'No settings file found, using defaults')
        saveSettings()
    end
end

local function onExtensionLoaded()
    loadSettings()
end

M.getSetting = getSetting
M.setSetting = setSetting
M.loadSettings = loadSettings
M.onExtensionLoaded = onExtensionLoaded

return M