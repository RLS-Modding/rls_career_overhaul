-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function onReset()
  electrics.values['tilt_input'] = 0
  electrics.values['lift_input'] = 0
end

local function updateGFX(dt) -- ms
end

local function tiltMast(value)
  electrics.values.tilt_input = value
end

local function liftMast(value)
  electrics.values.lift_input = value
end

-- public interface
M.onInit    = onReset
M.onReset   = onReset
M.updateGFX = updateGFX
M.tiltMast = tiltMast
M.liftMast = liftMast

return M
