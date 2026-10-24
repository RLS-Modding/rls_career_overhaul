-- Writes the owner's pre-activation choice at its existing publication boundary.
-- Read the pre-activation writer, including its source flag and wall-clock timestamp.
local M = {}

function M.write(start, savePath, source)
  local directory = savePath .. "/career/rls_career"
  if not FS:directoryExists(directory) then FS:directoryCreate(directory) end
  overhaul_career_saveSystem.jsonWriteFileSafe(directory .. "/logisticsEmploymentMode.json", {
    apprenticeship = start.pendingEmploymentApprenticeship == true,
    chosenAt = os.time(),
    source = source or "profile",
  }, true)
end

return M
