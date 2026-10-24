-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/insuranceDebug.lua (BeamNG 0.40).
local M = {}
local im = ui_imgui
M.debugOrder = 1
M.debugName = "Insurance"

M.drawDebugFunctions = function()
  if im.Selectable1("> Reset insurance data") then
    overhaul_career_repair_insurance.resetPlPolicyData()
  end
end

return M
