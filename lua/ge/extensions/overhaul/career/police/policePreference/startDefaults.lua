-- Writes the owner's pre-activation choice at its existing publication boundary.
-- Read the pre-activation writer, which retains the initial save's path, format and refusal behavior.
local M = {}

function M.write(start, savePath, _source)
  local directory = savePath .. "/career/rls_career"
  if not FS:directoryExists(directory) then FS:directoryCreate(directory) end
  overhaul_career_saveSystem.jsonWriteFileSafe(directory .. "/policePreference.json", {
    enabled = start.pendingPoliceEnabled == true
  }, true)
end

return M
