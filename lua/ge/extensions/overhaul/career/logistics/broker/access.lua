-- Projects kind requirements into admission and progress without owning unlock rules.
local M = {}
-- Unlock flag definitions give labels as keys or {txt, context} translation objects.
local function labelText(label, translate)
  if type(label) == "table" then return translate(label.txt, label.context) end
  return translate(label)
end
function M.evaluate(requirements, branchInfo, translate)
  local reasons = {}
  for _, requirement in ipairs(requirements or {}) do
    if requirement.unlocked == false then
      local definition = requirement.definition or {}
      local branch = requirement.branch or "logistics"
      local info = branchInfo(branch) or {}
      local need = definition.level
      local label = definition.lockedReason and definition.lockedReason.label
        or definition.unlockInfo and definition.unlockInfo.longLabel
      reasons[#reasons + 1] = {
        kind = "level", flag = requirement.flag, branch = branch,
        label = label and labelText(label, translate) or (need and string.format("Logistics level %d required", need)
          or "Logistics level required"),
        need = need, have = info.level or 0,
        progress = {level = info.level or 0, current = info.curLvlProgress or 0,
          needed = info.neededForNext or 0, percent = info.processPercent or 0},
      }
    end
  end
  table.sort(reasons, function(a, b)
    if (a.need or 0) ~= (b.need or 0) then return (a.need or 0) < (b.need or 0) end
    return tostring(a.flag or a.label) < tostring(b.flag or b.label)
  end)
  return {state = #reasons == 0 and "available" or "locked", reasons = reasons}
end
function M.apply(row, access)
  row.access = access
  row.unlocked = access.state == "available"
  local labels = {}
  for _, reason in ipairs(access.reasons) do labels[#labels + 1] = reason.label end
  row.lockedReason = #labels > 0 and table.concat(labels, "; ") or nil
  return row
end
return M
