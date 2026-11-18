-- Owns installed cage and tire trait detection.
-- drag/classes.lua passes installed parts and compiled vehicle data; returns traits without changing the vehicle.
local M = {}

local function text(value) return type(value) == 'string' and value:lower() or '' end
local function number(value)
  return type(value) == 'number' and value == value and value >= 0 and value < math.huge and value or nil
end

local function tireType(name)
  -- Specific race descriptions take precedence over generic words such as sport.
  if name:find('drag', 1, true) then return 'drag' end
  if name:find('semi%s*%-?%s*slick') or name:find('semi_slick', 1, true) then return 'semiSlick' end
  if name:find('slick', 1, true) then return 'slick' end
  if name:find('race', 1, true) or name:find('racing', 1, true) then return 'race' end
  if name:find('sport', 1, true) then return 'sport' end
  if name:find('allseason', 1, true) or name:find('all season', 1, true) or name:find('all_season', 1, true) then return 'allSeason' end
  if name:find('offroad', 1, true) or name:find('off%-road') or name:find('off_road', 1, true) then return 'offroad' end
  for _, kind in ipairs({'rally', 'mud', 'standard', 'winter'}) do if name:find(kind, 1, true) then return kind end end
end

function M.inspect(parts, vdata)
  local result, kinds, unknown = {tires = {}}, {}, false
  for _, part in ipairs(parts or {}) do
    local slot, name = text(part.slot), text(part.name)
    local label = name .. ' ' .. text(part.data and part.data.information and part.data.information.name)
    if (slot:find('tire', 1, true) or name:match('^tire_')) and not slot:find('spare', 1, true) then
      local kind = tireType(label)
      result.tires[#result.tires + 1] = {slot = slot, part = name, type = kind, source = 'installed-part-label'}
      if kind then kinds[kind] = true else unknown = true end
    end
  end
  table.sort(result.tires, function(a, b) return a.slot < b.slot end)
  if #result.tires > 0 and not unknown then
    result.tireTypes = {}
    for kind in pairs(kinds) do result.tireTypes[#result.tireTypes + 1] = kind end
    table.sort(result.tireTypes)
    result.tireType = #result.tireTypes == 1 and result.tireTypes[1] or 'mixed'
  end

  -- pressureWheels.lua retains the generated tread nodes on each compiled wheel.
  -- Do not read rim/body coefficients or invent defaults when tread data is absent.
  local wheels, complete, maximum = {}, true, nil
  for key, wheel in pairs(vdata and vdata.wheels or {}) do
    if type(wheel) == 'table' then
      local row = {wheel = wheel.name or tostring(key), source = 'compiled-tread-nodes', nodeCount = 0}
      for _, entry in pairs(wheel.treadNodes or {}) do
        local node = type(entry) == 'table' and entry or vdata.nodes and vdata.nodes[entry]
        local friction = node and number(node.frictionCoef)
        if friction then
          row.nodeCount = row.nodeCount + 1
          row.frictionCoefMin = math.min(row.frictionCoefMin or friction, friction)
          row.frictionCoefMax = math.max(row.frictionCoefMax or friction, friction)
          local sliding = number(node.slidingFrictionCoef)
          if sliding then
            row.slidingFrictionCoefMin = math.min(row.slidingFrictionCoefMin or sliding, sliding)
            row.slidingFrictionCoefMax = math.max(row.slidingFrictionCoefMax or sliding, sliding)
          end
        else complete = false end
      end
      if row.nodeCount == 0 then complete = false end
      if row.frictionCoefMax then maximum = math.max(maximum or row.frictionCoefMax, row.frictionCoefMax) end
      wheels[#wheels + 1] = row
    end
  end
  table.sort(wheels, function(a, b) return a.wheel < b.wheel end)
  result.tireFriction = {source = 'compiled-tread-nodes', complete = complete and #wheels > 0, wheels = wheels}
  if result.tireFriction.complete then result.tireFrictionCoefMax = maximum end
  return result
end

return M
