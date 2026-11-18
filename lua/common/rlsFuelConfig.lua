-- Portable fuel setup carried by a .pc. Ownership, condition and live fill never travel.
-- Copyright (C) RLS Modding; SPDX-License-Identifier: AGPL-3.0-only
local M = {version = 1}
local model = require('common/rlsFuelModel')
local control = require('common/rlsFuelControl')

local function identifier(value)
  return type(value) == 'string' and #value > 0 and #value <= 160 and not value:find('[%c]')
end

-- Shared configs are untrusted data; bound every copied subtree, including cycles.
local function tree(value, depth, budget, seen)
  local kind = type(value)
  if kind == 'number' then return model.finite(value) and value or nil end
  if kind == 'boolean' then return value end
  if kind == 'string' then return #value <= 512 and value or nil end
  if kind ~= 'table' or depth > 10 or seen[value] then return nil end
  seen[value] = true
  local out = {}
  for key, child in pairs(value) do
    budget.n = budget.n + 1
    if budget.n > 24000 then seen[value] = nil; return nil end
    if (type(key) == 'number' and key >= 1 and key <= 1000 and key % 1 == 0)
      or (type(key) == 'string' and #key <= 160) then
      out[key] = tree(child, depth + 1, budget, seen)
    end
  end
  seen[value] = nil
  return out
end
local function copy(value) return tree(value, 0, {n = 0}, {}) end
local function fields(source, keys)
  local out = {}
  if type(source)~='table' then return out end
  for _, key in ipairs(keys) do if source[key] ~= nil then out[key] = copy(source[key]) end end
  return out
end
local function positive(value) return model.finite(value) and value > 0 and value < 1000 end

function M.engine(source, origin)
  if type(source) ~= 'table' then return nil, 'Missing fuel setup' end
  local s = type(source.state) == 'table' and source.state or source
  origin = origin or source.partOrigin or s.partOrigin
  if not identifier(origin) or origin == 'mainEngine' or not model.validateTune(s.tune) then return nil, 'Fuel setup has no valid physical engine or map' end
  local out = fields(s, {'conversion', 'conversionKind', 'deliveryLps', 'baseDeliveryLps', 'deliveryStage', 'deliverySizing'})
  out.version, out.partOrigin, out.revision = 5, origin, 0
  out.tune = fields(s.tune, {'version','fuelType','afrTrim','rpm','load','lambda','timing','boost','boostCut','decel','nitrous'})
  if not model.validateTune(out.tune) or not positive(out.deliveryLps) or not positive(out.baseDeliveryLps) then return nil, 'Invalid fuel calibration or flow' end
  out.conversion = out.conversion == true
  out.conversionKind = model.conversionKind(out)
  out.exposure, out.fuelFailures, out.presets = {knock=0,lean=0,legacy=0}, {}, {}
  out.control = fields(s.control or {}, {'version','mixture','timing','boost','boostCut','decel','nitrous','hardware','conversion','liveMixtureTrim'})
  control.normalize(out)
  local h = s.hardware
  if type(h) == 'table' then
    out.hardware = fields(h, {'injector','pump','equippedInjectorLps','equippedPumpLps','legacyLps','legacyStage'})
    local clean = out.hardware
    if not identifier(clean.injector) or not identifier(clean.pump) or not positive(clean.equippedInjectorLps) or not positive(clean.equippedPumpLps) then return nil, 'Invalid installed fuel hardware' end
    clean.ownedInjectors, clean.ownedPumps = {equipped=true}, {equipped=true}
    clean.ownedInjectors[clean.injector], clean.ownedPumps[clean.pump] = true, true
    if type(h.injectorSets)=='table' and h.injectorSets[clean.injector] then
      local set = fields(h.injectorSets[clean.injector], {'count','flowLps'})
      if not model.finite(set.count) or set.count < 1 or set.count > 64 or set.count % 1 ~= 0 or not positive(set.flowLps) then return nil, 'Invalid injector set' end
      clean.injectorSets = {[clean.injector] = set}
    end
    if clean.legacyLps ~= nil and not positive(clean.legacyLps) then return nil, 'Invalid original fuel flow' end
    if type(h.dieselFlows)=='table' and positive(h.dieselFlows[clean.injector]) then clean.dieselFlows = {[clean.injector]=h.dieselFlows[clean.injector]} end
  end
  -- Baselines are inferred again from the receiving build, never from the sender's engine instance.
  return out
end

function M.blend(value)
  if type(value) ~= 'table' then return nil end
  if value.diesel == true then return {diesel=true} end
  local e,m,n = value.ethanol or 0, value.methanol or 0, value.nitromethane or 0
  local aki = value.aki or 87
  if not model.finite(e) or not model.finite(m) or not model.finite(n) or not model.finite(aki)
    or e < 0 or m < 0 or n < 0 or e+m+n > 1.000001 or aki < 60 or aki > 120 then return nil end
  return {ethanol=e,methanol=m,nitromethane=n,aki=aki}
end

function M.pack(snapshot)
  if type(snapshot) ~= 'table' then return nil, 'Fuel setup is unavailable' end
  if type(snapshot.engines)~='table' or snapshot.tanks~=nil and type(snapshot.tanks)~='table' then return nil,'Invalid fuel setup' end
  local out, count = {version=1,activation='career',engines={},tanks={}}, 0
  for name, source in pairs(snapshot.engines or {}) do
    if not identifier(name) or count >= 8 then return nil, 'Invalid engine list' end
    local state, err = M.engine(source)
    if not state then return nil, err end
    state.deviceName = name
    out.engines[name], count = state, count+1
  end
  if count == 0 then return nil, 'No supported engine fuel setup' end
  count = 0
  for name, source in pairs(snapshot.tanks or {}) do
    if not identifier(name) or count >= 32 then return nil, 'Invalid fuel tank list' end
    if type(source)~='table' then return nil,'Invalid fuel tank' end
    local blend = M.blend(source.blend)
    if source.blend~=nil and not blend then return nil,'Invalid fuel blend' end
    if blend then out.tanks[name] = {name=name,blend=blend} end
    count = count+1
  end
  return out
end

function M.isPortable(data) return type(data) == 'table' and data.activation == 'career' end
function M.read(data)
  if not M.isPortable(data) or data.version ~= M.version then return nil, 'Unsupported portable fuel version' end
  return M.pack(data)
end

-- Existing part records always win. Device-name reuse after an engine swap is not identity.
function M.seed(portable, engines, installed)
  local setup = M.read(portable)
  if not setup then return false end
  local changed, existingOrigins = false, {}
  for _, current in pairs(engines) do if current.partOrigin then existingOrigins[current.partOrigin] = true end end
  for name, state in pairs(setup.engines) do
    if not existingOrigins[state.partOrigin] and not engines[name] and installed[state.partOrigin] then
      engines[name], changed = model.copy(state), true
    end
  end
  return changed
end
return M
