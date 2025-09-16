local M = {}

local ourModName = "rls_career_overhaul_updating"
local ourModId = "RLSCO24"
local copiedJsonFiles = {}

local function copyJsonOverrides()
    local overridesDir = '/lua/ge/extensions/overrides/'
    local jsonFiles = FS:findFiles(overridesDir, '*.json', -1, true, false)

    if not jsonFiles or #jsonFiles == 0 then
        return true
    end

    for _, jsonFile in ipairs(jsonFiles) do
        local originalPath = jsonFile:gsub('/overrides/', '/')

        local targetDir = originalPath:match("(.*/)")
        if targetDir then
            FS:directoryCreate(targetDir)
        end

        if FS:copyFile(jsonFile, originalPath) then
            table.insert(copiedJsonFiles, originalPath)
        end
    end

    return true
end

local function cleanupJsonOverrides()
    if not copiedJsonFiles or #copiedJsonFiles == 0 then
        return true
    end

    for _, jsonFile in ipairs(copiedJsonFiles) do
        if FS:fileExists(jsonFile) then
            FS:removeFile(jsonFile)
        end
    end

    copiedJsonFiles = {}
    return true
end

local function checkVersion()
    local fileData = jsonReadFile("integrity.json")
    if fileData.version then
        local version = fileData.version
        local versionParts = string.split(version, ".")
        if versionParts[4] ~= "7" then
            guihooks.trigger("toastrMsg", {type="error", title="Update required", msg="RLS Career Overhaul is outdated. Please update to the latest version either from Patreon or Github."})
            return false
        end
    end
    return true
end

local function deactivateBeamMP()
    local beammp = core_modmanager.getMods()["multiplayerbeammp"]
    if beammp then
        core_modmanager.deactivateMod("multiplayerbeammp")
    end
end

local function loadExtensions()

    extensions.unload("freeroam_freeroam")
    extensions.unload("core_recoveryPrompt")
    extensions.unload("gameplay_drag_dragTypes_dragPracticeRace")

    setExtensionUnloadMode("gameplay_events_freeroamEvents", "manual")
    setExtensionUnloadMode("gameplay_phone", "manual")
    setExtensionUnloadMode("gameplay_repo", "manual")
    setExtensionUnloadMode("gameplay_taxi", "manual")
    setExtensionUnloadMode("gameplay_cab", "manual")

    extensions.unload("career_career")
end

local function unloadAllExtensions()

    extensions.unload("core_gameContext")
    extensions.unload("gameplay_events_freeroamEvents")
    extensions.unload("career_career")
    extensions.unload("gameplay_phone")
    extensions.unload("freeroam_facilities")
    extensions.unload("gameplay_repo")
    extensions.unload("gameplay_taxi")
    extensions.unload("gameplay_cab")
    extensions.unload("overhaul_settings")
    extensions.unload("overhaul_maps")
    extensions.unload("overhaul_clearLevels")
    extensions.unload("overhaul_ui")

    cleanupJsonOverrides()

end

local function setupAutomaticOverrides()
    local success, overrideManager = pcall(require, 'lua.ge.extensions.overhaul.overrideManager')
    if not success then
        return false
    end

    if not overrideManager.installSystem() then
        return false
    end

    local overridesDir = '/lua/ge/extensions/overrides/'
    local luaFiles = FS:findFiles(overridesDir, '*.lua', -1, true, false)

    local overrideCount = 0
    if luaFiles and #luaFiles > 0 then
        for _, overrideFile in ipairs(luaFiles) do
            local modulePath = overrideFile:gsub('^/lua/ge/extensions/', 'lua.ge.extensions.'):gsub('%.lua$', ''):gsub('/', '.')
            local originalPath = modulePath:gsub('%.overrides%.', '.')
            local extensionPath = originalPath:gsub('lua%.ge%.extensions%.', ''):gsub('%.', '_')

            if overrideManager.setOverride(extensionPath, modulePath) then
                overrideCount = overrideCount + 1
            end
        end
    end


    copyJsonOverrides()

    return true
end

local function startup()
    deactivateBeamMP()

    setupAutomaticOverrides()

    setExtensionUnloadMode("overhaul_settings", "manual")
    setExtensionUnloadMode("overhaul_maps", "manual")
    setExtensionUnloadMode("overhaul_clearLevels", "manual")

    if not core_gamestate.state or core_gamestate.state.state ~= "career" then
        loadExtensions()
    end

    setExtensionUnloadMode("overhaul_ui", "manual")
    extensions.unload("overhaul_ui")

    core_jobsystem.create(function(job)
        job.sleep(5)
        if not checkVersion() then
            print("Deactivating RLS Career Overhaul")
            core_modmanager.deactivateModId("RLSCO24")
        end
    end)

    loadManualUnloadExtensions()
end

local function onModActivated(modData)
    if ourModName or ourModId then
        return
    end

    if not modData or not modData.modname then
        return
    end

    if modData.modname and (modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_")) then
        return
    end

    if not ourModName then
        ourModName = modData.modname
        if modData.modData and modData.modData.tagid then
            ourModId = modData.modData.tagid
        end
        return true
    end
end

local function onModDeactivated(modData)
    if not modData or not modData.modname then
        return
    end

    if modData.modname and (modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_")) then
        return
    end

    if (ourModName and modData.modname == ourModName) or
       (ourModId and modData.modData and modData.modData.tagid == ourModId) then
        unloadAllExtensions()
        loadManualUnloadExtensions()
    end
end

M.onExtensionLoaded = startup

M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated

return M
