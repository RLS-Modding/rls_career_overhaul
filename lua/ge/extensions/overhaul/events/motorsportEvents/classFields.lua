-- Shares frozen class fields between qualifying displays and spectator runs.
local M = {}

function M.registrationId(row)
  return row.registrationId or (row.id or 'player-' .. tostring(row.inventoryId)) .. ':' .. tostring(row.leagueId)
end

function M.fields(eventState)
  local result, sessions, seen = {}, {}, {}
  for _, session in ipairs(eventState.classes or {}) do sessions[session.classId or session.id] = session end
  local function add(id, row, session)
    if not id or seen[id] then return end
    seen[id] = true
    local entrants = session and session.entrants or row and (row.qualifyingOpponents or {})
    if not entrants then return end
    local field = {id = id, registration = row, session = session, opponents = {}, all = {}}
    for _, entrant in ipairs(entrants) do
      field.all[#field.all + 1] = entrant
      if entrant.player then field.player = entrant else field.opponents[#field.opponents + 1] = entrant end
    end
    if not field.player and row then field.player = row; field.all[#field.all + 1] = row end
    result[#result + 1] = field
  end
  for _, row in ipairs(eventState.registrations or {}) do
    -- Preserve the stored exclusion for a class; new entries cannot share it.
    if row.excluded then
      local id = row.declaredClassId or row.classId
      if id then seen[id] = true end
    else add(row.declaredClassId or row.classId, row, sessions[row.classId or row.declaredClassId]) end
  end
  for _, session in ipairs(eventState.classes or {}) do add(session.classId or session.id, nil, session) end
  return result
end

return M
