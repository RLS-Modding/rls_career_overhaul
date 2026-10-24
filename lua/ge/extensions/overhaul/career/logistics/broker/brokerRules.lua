-- Pure Broker policy; no vehicle metadata is used to choose visible work. No reservation limit: players may hold as many broker loads as they like.
-- Read materialMarket, holdCount, dailyRate, chooseDepot, validStopOrder in order.

local M = {}

M.markets = {
  { id = "parcels", name = "Parcel Cargo", hint = "Packages & crates", icon = "box" },
  { id = "bulk", name = "Bulk Materials", hint = "Sand, gravel & more", icon = "bulk" },
  { id = "liquids", name = "Liquids", hint = "Fuel & water", icon = "drop" },
  { id = "specialty", name = "Specialty Cargo", hint = "Concrete & cash", icon = "specialty" },
  { id = "trailers", name = "Trailer Loads", hint = "Supplied trailers", icon = "trailer" },
  { id = "cars", name = "Car Hauling", hint = "Vehicle transport", icon = "car" },
}

function M.materialMarket(kind) return require("overhaul/lib/logistics/cargoSemantics").material(kind).market end

function M.holdCount(jobs, mapId)
  local count = 0
  for _, job in pairs(jobs or {}) do
    if job.status == "reserved" then count = count + 1 end
  end
  return count
end

-- A stable daily rate per loaner: the same key and day always give the same price.
function M.dailyRate(base, key, day)
  local hash = 17
  for i = 1, #key do
    hash = (hash * 31 + key:byte(i)) % 1000003
  end
  hash = (hash + day * 97) % 21
  return math.max(1, math.floor(base * (0.9 + hash / 100) * 100 + 0.5) / 100)
end

-- Authored depot preference and order lead; service coverage and id break ties.
function M.chooseDepot(facilities)
  local ranked = {}
  for _, fac in ipairs(facilities or {}) do
    local spots = fac.loanerNonTrailerSpots or {}
    local fallback = (fac.pickUpSpots or {})[1] or (fac.inspectSpots or {})[1]
    if spots[1] or fallback then
      local services = {}
      for k, v in pairs(fac.providedSystemsLookup or {}) do
        if v then services[k] = true end
      end
      for k, v in pairs(fac.receivedSystemsLookup or {}) do
        if v then services[k] = true end
      end
      local count = 0
      for _ in pairs(services) do
        count = count + 1
      end
      ranked[#ranked + 1] = { fac = fac, services = count, generators = #(fac.logisticGenerators or {}) }
    end
  end
  table.sort(ranked, function(a, b)
    local aBroker, bBroker = a.fac.broker or {}, b.fac.broker or {}
    if (aBroker.defaultDepot == true) ~= (bBroker.defaultDepot == true) then return aBroker.defaultDepot == true end
    local aOrder, bOrder = tonumber(aBroker.order) or 0, tonumber(bBroker.order) or 0
    if aOrder ~= bOrder then return aOrder < bOrder end
    if a.services ~= b.services then return a.services > b.services end
    if a.generators ~= b.generators then return a.generators > b.generators end
    return tostring(a.fac.id) < tostring(b.fac.id)
  end)
  return ranked[1] and ranked[1].fac
end

-- A stop order is valid when every stop has a unique id and each delivery follows its pickup.
function M.validStopOrder(stops)
  local picked, seen = {}, {}
  for _, stop in ipairs(stops or {}) do
    if type(stop.id) ~= "string" or seen[stop.id] then return false end
    seen[stop.id] = true
    if stop.kind == "pickup" then
      picked[stop.jobId] = true
    elseif stop.kind ~= "delivery" or not (picked[stop.jobId] or stop.collected) then
      return false
    end
  end
  return true
end

return M
