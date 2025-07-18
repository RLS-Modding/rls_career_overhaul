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

loadManualUnloadExtensions()