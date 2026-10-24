-- Phone acceptance and data loading delegate to this facade; unlock status is deliberately not a probe.
-- Read call in order.

return function(M)
  local function call(name)
    return function(...) return M[name](...) end
  end
  return {
    id = "ownerOp",
    label = "Owner-operator contracts",
    role = "orchestrator",
    modes = { "career" },
    extension = "overhaul_career_logistics_ownerOpContracts",
    lifecycle = "ownerOp",
    actions = { acceptContract = call("acceptContract") },
    restore = call("setup"),
    transitions = {},
    resources = { "route", "tasklist" },
    settlement = "owner",
    economyKeys = {},
  }
end
