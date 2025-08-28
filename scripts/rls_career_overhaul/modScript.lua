local function checkVersion()
    local fileData = jsonReadFile("integrity.json")
    if fileData.version then
        local version = fileData.version
        local versionParts = string.split(version, ".")
        if versionParts[4] ~= "6" then
            guihooks.trigger("toastrMsg", {type="error", title="Update required", msg="RLS Career Overhaul is outdated. Please update to the latest version either from Patreon or Github."})
            return false
        end
    end
    return true
end

local function loadExtensions()
    print("Starting extension loading sequence")
    extensions.unload("freeroam_freeroam")
    
    extensions.unload("core_recoveryPrompt")

    setExtensionUnloadMode("core_gameContext", "manual")

    setExtensionUnloadMode("gameplay_events_freeroamEvents", "manual")

    setExtensionUnloadMode("career_career", "manual")
    extensions.unload("career_career")

    setExtensionUnloadMode("gameplay_phone", "manual")

    setExtensionUnloadMode("freeroam_facilities", "manual")

    setExtensionUnloadMode("gameplay_repo", "manual")

    setExtensionUnloadMode("gameplay_taxi", "manual")
    
    setExtensionUnloadMode("gameplay_cab", "manual")

    setExtensionUnloadMode("career_challengeModes", "manual")
    
    setExtensionUnloadMode("career_economyAdjuster", "manual")
end

local function deactivateBeamMP()
    local beammp = core_modmanager.getMods()["multiplayerbeammp"]
    if beammp then
        core_modmanager.deactivateMod("multiplayerbeammp")
    end
end

deactivateBeamMP()

setExtensionUnloadMode("rlsSettings", "manual")

setExtensionUnloadMode("careerMaps", "manual")

setExtensionUnloadMode("clearLevels", "manual")

if not core_gamestate.state or core_gamestate.state.state ~= "career" then
    loadExtensions()
end

setExtensionUnloadMode("UIloader", "manual")
extensions.unload("UIloader")

core_jobsystem.create(function(job)
    job.sleep(5)
    if not checkVersion() then
        print("Deactivating RLS Career Overhaul")
        core_modmanager.deactivateModId("RLSCO24")
    end
end)

loadManualUnloadExtensions()