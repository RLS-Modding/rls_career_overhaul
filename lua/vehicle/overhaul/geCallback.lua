-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Vehicle-to-GE callback commands and replies, using the existing callback registry.
-- Stale request replies are discarded by the GE registry; command bytes stay compatible with its parser.
local M = {}

function M.command(id, args)
  return "require('overhaul/lib/vehicles/callbacks').call('" .. id .. "'" .. (args and (", " .. args) or "") .. ")"
end

function M.reply(requestId, id, args)
  return "require('overhaul/lib/vehicles/callbacks').reply(" .. tostring(requestId) .. ", '" .. id .. "'" ..
    (args and (", " .. args) or "") .. ")"
end

return M
