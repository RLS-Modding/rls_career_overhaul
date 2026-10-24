-- Bridges tilt sources into forklift hydros (tilt_input).
-- Dedicated mast actions write mast_tilt_input; BeamNG shared tiltUp/tiltDown write
-- upfit_tilt. Prefer the dedicated mast command so an idle upfit_tilt of 0 cannot
-- overwrite an active mastTiltBack/mastTiltForward input every GFX tick.

local M = {}

local function onReset()
  electrics.values.mast_tilt_input = electrics.values.mast_tilt_input or 0
  electrics.values.tilt_input = electrics.values.tilt_input or 0
  electrics.values.lift_input = electrics.values.lift_input or 0
end

local function updateGFX(dt)
  local mast = electrics.values.mast_tilt_input
  if type(mast) == "number" and mast ~= 0 then
    electrics.values.tilt_input = mast
    return
  end

  local upfit = electrics.values.upfit_tilt
  if type(upfit) == "number" then
    electrics.values.tilt_input = upfit
  elseif type(mast) == "number" then
    electrics.values.tilt_input = mast
  end
end

M.init = onReset
M.reset = onReset
M.updateGFX = updateGFX

return M
