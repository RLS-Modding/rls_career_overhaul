-- Projects saved or live police preferences without loading the police extension at the menu.
-- Read saved input first, then project policeEnabled for the requested profile.
local M = {}

function M.readSaved(savePath)
  return jsonReadFile(savePath .. "/career/rls_career/policePreference.json")
end

function M.read(_profile, _savePath, options)
  local saved = options.saved.police
  if saved and saved.enabled ~= nil then return {policeEnabled = saved.enabled == true} end
  if options.live then
    return {policeEnabled = overhaul_career_police_policePreference.getSavedEnabled() == true}
  end
  return {policeEnabled = true}
end

return M
