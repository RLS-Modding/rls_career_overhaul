-- Fit supported RLS tires at the native pre-wheel-generation stage.
-- Parent wheel geometry and all tire forces remain owned by their JBeam parts.
-- Loaded by scripts/rls_drag_tires/modScript.lua in freeroam and career.
-- Fit meshes: vehicles/common/rls_drag_tires/rls_drag_tires_15x14_fits.dae and
-- rls_drag_tires_welp_fits.dae, built by tools/vehicles/build_drag_tire_15x14_fits.cjs
-- and build_drag_tire_welp_fits.cjs. Tests: tests/vehicles/drag_tire_15x14_fit_test.lua.
-- Background: docs/vehicles/drag-tire-15x14-fitment.md.
-- Contract: only flexbody position and mesh name change; unknown parts are left as is.
local M = {}
local jbeamUtils = require('jbeam/utils')

local tires = {
  rls_dt_R_28x105_15_bias_w14 = {axle = 'R', construction = 'bias'},
  rls_dt_R_28x105_15_radial_w14 = {axle = 'R', construction = 'radial'},
  rls_dt_F_28x105_15_bias_w14 = {axle = 'F', construction = 'bias'},
  rls_dt_F_28x105_15_radial_w14 = {axle = 'F', construction = 'radial'},
}
local widths = {305, 325, 345, 355, 375}
local warned = {}

-- These parts share tire slots with Welp rims but were authored for other
-- mounting centers and bead dimensions. Select by resolved physical interface,
-- not a particular wheel model or vehicle. Other interfaces keep their mesh.
local welpFamilies = {
  {'rls_dt_R_28x105_15_', 'R', 'R_15x10', .255, .20},
  {'rls_dt_fit_F_15x10_', 'F', 'F_15x10', .255, .20},
  {'rls_dt_fit_F_15x10_short_', 'F', 'F_15x10_short', .255, .20},
  {'rls_dt_fit_F_15x9_', 'F', 'F_15x9', .255, .20},
  {'rls_dt_fit_R_15x9_', 'R', 'R_15x9', .255, .20},
  {'rls_dt_F_26x4_17_', 'F', 'F_17x4_dragger', .125, .23},
  {'rls_dt_fit_F_17x4_', 'F', 'F_17x4', .125, .23},
  {'rls_dt_fit_R_17x4_', 'R', 'R_17x4', .125, .23},
}
for _, family in ipairs(welpFamilies) do
  for _, construction in ipairs({'bias', 'radial'}) do
    tires[family[1] .. construction] = {
      axle = family[2], construction = construction,
      mesh = 'rls_dt_welp_' .. family[3] .. '_' .. construction,
      hubWidth = family[4], hubRadius = family[5],
    }
  end
end

local function meshFor(fit, wheel)
  local width = tonumber(wheel.hubWidth)
  local radius = tonumber(wheel.hubRadius)
  if not width or not radius then return end
  if fit.mesh then
    if math.abs(width - fit.hubWidth) < .00001 and math.abs(radius - fit.hubRadius) < .00001 then
      return fit.mesh
    end
    return
  end
  -- The retained vanilla Dragger has its original, byte-identical mesh.
  if fit.axle == 'R' and math.abs(width - 0.375) < 0.00001
      and math.abs(radius - 0.205) < 0.00001 then
    return 'rls_dt_28x105_15_' .. fit.construction .. '_w14_sidewall'
  end
  if math.abs(radius - 0.20) > 0.00001 then return end
  for _, mm in ipairs(widths) do
    if math.abs(width - mm / 1000) < 0.00001 then
      return string.format('rls_dt_15x14_%s_%s_h%d', fit.axle, fit.construction, mm)
    end
  end
end

-- Same midpoint, offsetFromNode and wheelOffset convention as the native
-- jbeam/sections/wheelTypes/pressureWheels.lua. Nodes are already transformed.
local function wheelCenter(vehicle, wheel)
  local a = vehicle.nodes and vehicle.nodes[wheel.node1]
  local b = vehicle.nodes and vehicle.nodes[wheel.node2]
  if not a or not b or not a.pos or not b.pos then return end
  a, b = a.pos, b.pos
  local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
  local length = math.sqrt(dx * dx + dy * dy + dz * dz)
  if length < 0.000001 then return end
  dx, dy, dz = dx / length, dy / length, dz / length
  local x, y, z = (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2
  local half = wheel.hubWidth / 2
  if wheel.offsetFromNode == 1 then
    x, y, z = a.x + dx * half, a.y + dy * half, a.z + dz * half
  elseif wheel.offsetFromNode == 2 then
    x, y, z = b.x - dx * half, b.y - dy * half, b.z - dz * half
  end
  local offset = wheel.wheelOffset or 0
  return x + dx * offset, y + dy * offset, z + dz * offset
end

local function onJbeamLoadingPhase1(_, _, vehicle)
  if not vehicle or not vehicle.flexbodies or not vehicle.pressureWheels then return end
  local wheelsByName = {}
  for _, wheel in pairs(vehicle.pressureWheels) do
    wheelsByName[wheel.name] = wheel
  end
  for _, body in pairs(vehicle.flexbodies) do
    local fit = tires[body.partOrigin]
    if fit and type(body.mesh) == 'string' and body.mesh:match('^rls_dt_') and body.pos then
      local name = fit.axle .. (body.pos.x < 0 and 'R' or 'L')
      local wheel = wheelsByName[name]
      local mesh = wheel and meshFor(fit, wheel)
      local x, y, z
      if mesh then x, y, z = wheelCenter(vehicle, wheel) end
      if x then
        -- Flexbody transforms are applied later by meshs.lua; invert them now
        -- instead of applying a vehicle/axle relocation twice.
        x, y, z = jbeamUtils.getPosRotBeforeNodeRotateOffsetMove(body, x, y, z, 0, 0, 0)
        body.pos = {x = x, y = y, z = z}
        body.mesh = mesh
      -- The additional Welp profiles are opt-in interfaces. Other original
      -- stock/dedicated rim fits remain ordinary authored tire parts.
      elseif wheel and not fit.mesh then
        local key = body.partOrigin .. ':' .. tostring(wheel.hubWidth) .. '/' .. tostring(wheel.hubRadius)
        if not warned[key] then
          warned[key] = true
          log('W', 'rlsDragTireFit', 'Unverified rim interface ' .. key .. '; retained authored tire mesh')
        end
      end
    end
  end
end

M.onJbeamLoadingPhase1 = onJbeamLoadingPhase1
return M
