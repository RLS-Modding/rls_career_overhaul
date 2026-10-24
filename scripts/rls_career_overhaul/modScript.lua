-- Stock input actions and Options > Controls share this extensible table.
-- Register before loading actions so mods can join the group by category.
setExtensionUnloadMode("core_input_categories", "manual")
extensions.load("core_input_categories")
core_input_categories.rlsCareerOverhaul = {
  order = 4.25, icon = "extension", title = "RLS Career Overhaul"
}

-- core_modmanager temporarily wraps extensions.load while executing modScript.
-- Defer so the extension manager captures BeamNG's real loader; it loads everything else.
core_jobsystem.create(function(job)
  job.sleep(0.25)
  setExtensionUnloadMode("overhaul_shell_extensionManager", "manual")
  extensions.load("overhaul_shell_extensionManager")
end)
