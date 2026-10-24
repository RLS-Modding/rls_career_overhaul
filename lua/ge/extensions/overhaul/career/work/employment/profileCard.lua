-- Projects the employment choice from a profile's own file before modules load.
-- Read the saved apprenticeship choice, then project the card's choice fields.
local M = {}

function M.readSaved(savePath)
  return jsonReadFile(savePath .. "/career/rls_career/logisticsEmploymentMode.json")
end

function M.read(_profile, _savePath, options)
  local saved = options.saved.work
  if type(saved) == "table" and saved.apprenticeship ~= nil then
    return {needsEmploymentChoice = false, employmentApprenticeship = saved.apprenticeship == true}
  end
  return {needsEmploymentChoice = true, employmentApprenticeship = false}
end

return M
