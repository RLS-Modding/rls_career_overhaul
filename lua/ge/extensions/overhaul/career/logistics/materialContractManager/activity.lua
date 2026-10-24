-- Pickup-screen and Broker entries for material contracts; the material owner keeps all progress and settlement. Actions and restore forward to the owner module, so this file holds no state.
-- Read call in order.

return function(M)
  local function call(name)
    return function(...) return M[name](...) end
  end
  return {
    id = "materialContracts",
    label = "Material contracts",
    role = "orchestrator",
    modes = { "career" },
    extension = "overhaul_career_logistics_materialContractManager",
    lifecycle = "materialContracts",
    actions = { acceptContract = call("acceptContract"), acceptBrokerContract = call("acceptBrokerContract") },
    restore = call("setup"),
    transitions = {},
    resources = { "tasklist" },
    settlement = "owner",
    economyKeys = {},
  }
end
