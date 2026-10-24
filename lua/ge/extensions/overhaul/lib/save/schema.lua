-- Overhaul save schema: every save writes OVERHAUL_SCHEMA into info.json next to the game-format version.
-- A change that adds state an older build would lose bumps it; refusal() turns away a newer slot.

local M = {}

M.OVERHAUL_SCHEMA = 1

-- Refuse unsupported newer saves before any rewrite can change their bytes.
function M.refusal(info)
  local schema = type(info) == "table" and tonumber(info.overhaulSchema) or nil
  if not schema or schema <= M.OVERHAUL_SCHEMA then return nil end
  return string.format("This save was made by a newer version of RLS Career Overhaul (save schema %s; this version reads up to %d). Update the mod to load it.",
    tostring(schema), M.OVERHAUL_SCHEMA)
end

return M
