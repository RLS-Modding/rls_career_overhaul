-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Compares installed part selections with their original slot records.
-- Read original-slot removals, new-slot additions and same-name replacements in order.

-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/valueCalculator.lua.
local M = {}

function M.getPartDifference(originalParts, newParts, changedSlots)
  local addedParts = {}
  local removedParts = {}
  if not originalParts then return addedParts, removedParts end
  newParts = newParts or {}
  changedSlots = changedSlots or {}
  for slotName, oldPart in pairs(originalParts) do
    if newParts then
      local newPart = newParts[slotName]
      if newPart ~= oldPart.name then
        if oldPart.name ~= "" then
          removedParts[slotName] = oldPart.name
        end
        if newPart ~= "" then
          addedParts[slotName] = newPart
        end
      end
    end
  end

  for slotName, newPart in pairs(newParts) do
    local oldPart = originalParts[slotName]
    if newPart ~= "" then
      if not oldPart then
        addedParts[slotName] = newPart
      end

      -- A changed slot can replace a part with another instance of the same named part.
      if changedSlots[slotName] and oldPart and newPart == oldPart.name then
        addedParts[slotName] = newPart
        removedParts[slotName] = originalParts[slotName]
      end
    end
  end

  return addedParts, removedParts
end

return M
