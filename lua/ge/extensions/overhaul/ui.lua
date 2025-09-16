local M = {}

local function overrideUIVue()
  FS:copyFile("ui/ui-vue-override/dist/index.css", "ui/ui-vue/dist/index.css")
  FS:copyFile("ui/ui-vue-override/dist/index.html", "ui/ui-vue/dist/index.html")
  FS:copyFile("ui/ui-vue-override/dist/index.js", "ui/ui-vue/dist/index.js")
  FS:copyFile("ui/ui-vue-override/dist/index.js.map", "ui/ui-vue/dist/index.js.map")
end

local function applyStartScreenOverride()
  -- Copy start screen file
  FS:copyFile("ui/startScreen/startScreen.html", "ui/modules/startScreen/startScreen.html")
end

local function restoreOriginalFiles()
  print("UIloader: Restoring original UI files")

  FS:removeFile("ui/ui-vue/dist/index.css")
  FS:removeFile("ui/ui-vue/dist/index.html")
  FS:removeFile("ui/ui-vue/dist/index.js")
  FS:removeFile("ui/ui-vue/dist/index.js.map")

  FS:removeFile("ui/modules/startScreen/startScreen.html")
end

local function onExtensionLoaded()
  overrideUIVue()
  applyStartScreenOverride()

  reloadUI()
  if career_career.isActive() then
    guihooks.trigger('ChangeState', {state = 'play', params = {}})
  end
  print("RLS Career Overhaul UI loaded")
end

local function onExtensionUnloaded()
  print("UIloader: Extension unloading - starting restoration")
  restoreOriginalFiles()
  print("UIloader: Reloading UI after restoration")
  reloadUI()
  print("RLS Career Overhaul UI unloaded - original files restored")
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M