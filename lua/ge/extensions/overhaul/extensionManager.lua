local M = {}

local ourModName = "rls_career_overhaul"
local ourModId = "RLSCO24"

local commandCallback = nil
local devKey = "dc124d6fb1a6261f"


local function checkVersion()
    local fileData = jsonReadFile("integrity.json")
    if fileData.version then
        local version = fileData.version
        local versionParts = string.split(version, ".")
        if versionParts[4] ~= "8" then
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
    setExtensionUnloadMode("gameplay_loading", "manual")
    setExtensionUnloadMode("career_challengeModes", "manual")
    setExtensionUnloadMode("career_economyAdjuster", "manual")
    setExtensionUnloadMode("career_challengeSeedEncoder", "manual")
    setExtensionUnloadMode("editor_freeroamEventEditor", "manual")

    extensions.unload("career_career")
    extensions.unload("career_saveSystem")
end

local function unloadAllExtensions()
    extensions.unload("core_gameContext")
    extensions.unload("gameplay_events_freeroamEvents")
    extensions.unload("career_career")
    extensions.unload("career_saveSystem")
    extensions.unload("gameplay_phone")
    extensions.unload("freeroam_facilities")
    extensions.unload("gameplay_repo")
    extensions.unload("gameplay_taxi")
    extensions.unload("gameplay_cab")
    extensions.unload("overhaul_settings")
    extensions.unload("overhaul_maps")
    extensions.unload("overhaul_clearLevels")
    extensions.unload("overhaul_addMapChanges")
    extensions.unload("career_challengeModes")
    extensions.unload("career_economyAdjuster")
    extensions.unload("career_challengeSeedEncoder")
end

local function startup()
    deactivateBeamMP()

    setExtensionUnloadMode("overhaul_overrideManager", "manual")
    extensions.load("overhaul_overrideManager")

    setExtensionUnloadMode("overhaul_settings", "manual")
    setExtensionUnloadMode("overhaul_maps", "manual")
    setExtensionUnloadMode("overhaul_clearLevels", "manual")
    setExtensionUnloadMode("overhaul_addMapChanges", "manual")

    if not core_gamestate.state or core_gamestate.state.state ~= "career" then
        loadExtensions()
    end

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

local function onVehicleSpawned(_, veh)
    veh:queueLuaCommand("extensions.load('fuelMultiplier')")
    veh:queueLuaCommand([[
        extensions.load('overrideAI')
        ai = overrideAI
    ]])
end

local function updateEditorBlocking()
    local blockedActions = {"editorToggle", "editorSafeModeToggle", "vehicleEditorToggle"}
    core_input_actionFilter.setGroup("RLS_DEACTIVATION", blockedActions)
    local cheatsEnabled = career_modules_cheats and career_modules_cheats.isCheatsMode()
    if not M.isDevKeyValid() and career_career.isActive() and not cheatsEnabled then
        core_input_actionFilter.addAction(0, "RLS_DEACTIVATION", true)
    else
        core_input_actionFilter.addAction(0, "RLS_DEACTIVATION", false)
    end
end

M.onWorldReadyState = function(state)
    if state == 2 then
        updateEditorBlocking()
    end
end

M.onCheatsModeChanged = function(enabled)
    updateEditorBlocking()
end
  
M.onVehicleSpawned = onVehicleSpawned
M.onExtensionLoaded = startup
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated

M.isDevKeyValid = function()
    return devKey == FS:hashFile("devkey.txt")
end

M.getModData = function()
    return {
        name = ourModName,
        id = ourModId
    }
end

return M
