-- Ordered provider registrations with lifetime-bound disposal.
-- An old disposer cannot remove a newer registration from the same owner.
local lifecycle = require("overhaul/lib/lifecycle/host")

local M = {}

local function removeEntry(list, target)
  for i, item in ipairs(list) do
    if item == target then table.remove(list, i); break end
  end
end

local function byOrder(a, b)
  if a.order ~= b.order then return a.order < b.order end
  return a.sequence < b.sequence
end

-- Owners dispose on extension unload and republish after a lifetime change.
function M.new()
  local owners, ordered, currentEpoch = {}, {}, nil
  local sequence = 0
  local registry = {}

  local function synchronize()
    local epoch = lifecycle.epochs()
    if not currentEpoch or epoch.career ~= currentEpoch.career or
      epoch.map ~= currentEpoch.map or epoch.profile ~= currentEpoch.profile then
      owners, ordered, currentEpoch = {}, {}, epoch
    end
  end

  function registry.register(owner, value, order)
    assert(type(owner) == "table", "registration owner must be an instance table")
    if order == nil then order = 0 end
    assert(type(order) == "number" and order == order and order > -math.huge and order < math.huge,
      "registration order must be finite")
    synchronize()
    sequence = sequence + 1
    local handle = {}
    local entry = {owner = owner, handle = handle, value = value, order = order or 0, sequence = sequence}
    local old = owners[owner]
    if old then removeEntry(ordered, old) end
    owners[owner] = entry
    ordered[#ordered + 1] = entry
    table.sort(ordered, byOrder)
    local function dispose()
      synchronize()
      if owners[owner] ~= entry then return false end
      owners[owner] = nil
      removeEntry(ordered, entry)
      return true
    end
    return handle, dispose
  end

  function registry.get(handle)
    synchronize()
    for _, entry in ipairs(ordered) do
      if entry.handle == handle then return entry.value end
    end
  end

  -- The typed caller owns iteration and must not mutate registrations during a query.
  function registry.entries()
    synchronize()
    return ordered
  end

  return registry
end

return M
