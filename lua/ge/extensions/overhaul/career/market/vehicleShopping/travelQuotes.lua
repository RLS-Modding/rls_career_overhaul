-- One route cache per shopping instance. Requests queue work; each update plans at most one road route.
local M = {}

function M.new(inputs)
  local cache, pending, pendingIds = {}, {}, {}
  local currentCell
  local buffered, bufferedIds, elapsed = {}, {}, 0

  local function destination(pos)
    return table.concat({pos.x, pos.y, pos.z}, ':')
  end

  local function refreshCell()
    local origin = inputs.getOrigin()
    local cell = origin and table.concat({inputs.getContext(),
      math.floor(origin.x / inputs.cellSize), math.floor(origin.y / inputs.cellSize),
      math.floor(origin.z / inputs.cellSize)}, ':') or 'no-player'
    if cell ~= currentCell then cache = {}; currentCell = cell end
    return origin
  end

  local function request(vehicles, prioritize)
    local requested = {}
    for _, vehicle in ipairs(vehicles) do
      if prioritize or not pendingIds[vehicle.shopId] then
        requested[#requested + 1] = vehicle
        pendingIds[vehicle.shopId] = true
      end
    end
    if prioritize then
      local seen = {}
      for _, vehicle in ipairs(requested) do seen[vehicle.shopId] = true end
      for _, vehicle in ipairs(pending) do
        if not seen[vehicle.shopId] then requested[#requested + 1] = vehicle end
      end
      pending = requested
    else
      for _, vehicle in ipairs(requested) do pending[#pending + 1] = vehicle end
    end
  end

  local function step()
    if #pending == 0 then return {} end
    local origin = refreshCell()
    local updates, remaining, planned = {}, {}, false
    for _, vehicle in ipairs(pending) do
      local pos = vehicle.pos
      if inputs.getDestination then pos = inputs.getDestination(vehicle) end
      local key = vehicle.sellerId == 'private' and ('private:' .. vehicle.shopId) or tostring(vehicle.sellerId)
      local quote = cache[key]
      if quote and (not pos or quote.destination ~= destination(pos)) then quote = nil end
      if pos and origin and not quote and planned then
        remaining[#remaining + 1] = vehicle
      else
        if pos and origin and not quote then
          local price, distance = inputs.quote(pos)
          quote = {price = price, distance = distance, destination = destination(pos)}
          cache[key] = quote
          planned = true
        end
        vehicle.distance = quote and quote.distance or 0
        vehicle.quickTravelPrice = quote and quote.price or (pos and 0 or nil)
        updates[#updates + 1] = {
          shopId = vehicle.shopId, distance = vehicle.distance, quickTravelPrice = vehicle.quickTravelPrice,
        }
        pendingIds[vehicle.shopId] = nil
      end
    end
    pending = remaining
    return updates
  end

  local function cancel()
    pending = {}; pendingIds = {}
    buffered = {}; bufferedIds = {}; elapsed = 0
  end

  -- Route planning stays bounded per frame; bridge publication has its own
  -- cadence, with an immediate final batch so no completed fare is stranded.
  local function update(dtReal)
    elapsed = elapsed + dtReal
    for _, row in ipairs(step()) do
      local index = bufferedIds[row.shopId]
      if not index then index = #buffered + 1; bufferedIds[row.shopId] = index end
      buffered[index] = row
    end
    if #buffered == 0 or (#pending > 0 and elapsed < 0.25) then return {} end
    local updates = buffered
    buffered = {}; bufferedIds = {}; elapsed = 0
    return updates
  end

  return {
    request = request,
    step = step,
    update = update,
    cancel = cancel,
    clear = function() cache = {}; cancel(); currentCell = nil end,
  }
end

return M
