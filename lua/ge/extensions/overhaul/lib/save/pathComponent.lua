-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

function M.displayName(name)
  return type(name) == 'string' and name ~= '' and name ~= '.' and name ~= '..'
    and not name:find('[<>:"/\\|?*%c]')
end

function M.valid(name)
  if not M.displayName(name) or name:find('[%. ]$') then return false end
  -- Windows device aliases remain reserved with a filename extension.
  local stem = (name:match('^[^%.]+') or ''):upper():gsub(' +$', '')
  -- Windows also treats the ISO-8859-1 superscripts 1, 2 and 3 as device digits.
  stem = stem:gsub('¹', '1'):gsub('²', '2'):gsub('³', '3')
  return not (stem == 'CON' or stem == 'PRN' or stem == 'AUX' or stem == 'NUL'
    or stem:match('^COM[1-9]$') or stem:match('^LPT[1-9]$'))
end

return M
