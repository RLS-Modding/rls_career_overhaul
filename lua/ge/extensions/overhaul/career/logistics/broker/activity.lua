-- Broker activity entry for the activity host; reserve is the existing logistics-phone entry (phone/apps/logistics.lua). Actions and restore forward to the broker module, which keeps all state.
-- Read call in order.

return function(M)
  local function call(name)
    return function(...) return M[name](...) end
  end
  return {
    id = "broker",
    label = "Broker",
    role = "orchestrator",
    modes = { "career" },
    extension = "overhaul_career_logistics_broker",
    lifecycle = "broker",
    actions = { reserve = call("reserve") },
    restore = call("setup"),
    transitions = {},
    resources = {},
    settlement = "owner",
    economyKeys = {},
  }
end
