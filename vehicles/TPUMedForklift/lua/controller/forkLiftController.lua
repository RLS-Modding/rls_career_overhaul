-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local freelift = nil

local function onReset(jbeamData)
	  electrics.values['tilt'] = 0
	  electrics.values['lift'] = 0
	  electrics.values['freelift'] = 0
	  freelift = jbeamData.FreeLift
  
end

local function updateGFX(dt) -- ms
	electrics.values['tilt'] = math.min(1, math.max(-1, (electrics.values['tilt'] + electrics.values['tilt_input'] * dt * 1)))
	if not freelift then
		electrics.values['lift'] = math.min(1, math.max(0, (electrics.values['lift'] + electrics.values['lift_input'] * dt * 0.5)))
	else
		if electrics.values['lift_input']>0  then
			if electrics.values['freelift'] == 1 then
				electrics.values['lift'] = math.min(1, math.max(0, (electrics.values['lift'] + electrics.values['lift_input'] * dt * 0.5)))
			else
				electrics.values['freelift'] = math.min(1, math.max(0, (electrics.values['freelift'] + electrics.values['lift_input'] * dt * 1)))
			end
		elseif electrics.values['lift_input']<0 then
			if electrics.values['lift'] > 0 then
				electrics.values['lift'] = math.min(1, math.max(0, (electrics.values['lift'] + electrics.values['lift_input'] * dt * 0.5)))
			else
				electrics.values['freelift'] = math.min(1, math.max(0, (electrics.values['freelift'] + electrics.values['lift_input'] * dt * 1)))
			end
		else
		end
	end
end

-- public interface
M.init  = onReset
M.updateGFX = updateGFX

return M
