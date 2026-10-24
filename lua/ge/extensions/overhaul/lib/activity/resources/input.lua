-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Activity resource: blocked input actions. Uses the two calls owners make today (actionFilter.setGroup, then
-- addAction(0, name, true|false)). Remembers the groups this activity blocked so releaseAll unblocks exactly those.
local M = {}

local function remove(list, value)
  for i = #list, 1, -1 do
    if list[i] == value then table.remove(list, i) end
  end
end

function M.create(owner)
  local input = {}
  local blocked, order = {}, {}

  function input.getOwner() return owner end

  function input.block(group, actions)
    core_input_actionFilter.setGroup(group, actions)
    core_input_actionFilter.addAction(0, group, true)
    if not blocked[group] then
      blocked[group] = true
      order[#order + 1] = group
    end
    return true
  end

  function input.unblock(group)
    core_input_actionFilter.addAction(0, group, false)
    blocked[group] = nil
    remove(order, group)
    return true
  end

  -- Unblocks the groups this activity blocked, in block order. unblock edits the order list, so walk a copy.
  function input.releaseAll()
    local released = 0
    local pending = {}
    for _, group in ipairs(order) do pending[#pending + 1] = group end
    for _, group in ipairs(pending) do
      if blocked[group] then
        input.unblock(group)
        released = released + 1
      end
    end
    return released
  end

  function input.isBlocked(group) return blocked[group] == true end

  return input
end

return M
