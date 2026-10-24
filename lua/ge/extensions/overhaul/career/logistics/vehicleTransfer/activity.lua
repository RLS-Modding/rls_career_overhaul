-- One definition per CarGo extension load; delegation adds no state or lifecycle dispatch. Each entry forwards to the vehicle transfer module that defines it.
-- Read call in order.

return function(M)
  local function call(name)
    return function(...) return M[name](...) end
  end
  return {
    id = "carGo",
    label = "CarGo",
    role = "orchestrator",
    modes = { "career" },
    extension = "overhaul_career_logistics_vehicleTransfer",
    lifecycle = "carGo",
    probe = function() return not not (M.isOnShift and M.isOnShift()) end,
    blocksTutorialPhone = true,
    actions = {
      startDay = call("startDay"),
      endDay = call("endDay"),
      nextRun = call("nextRun"),
      reportUndeliverable = call("reportUndeliverable"),
      requestState = call("requestState"),
      getUiState = call("getUiState"),
    },
    state = call("getUiState"),
    save = call("onOverhaulSaveCurrentProfile"),
    transitions = { save = call("onOverhaulSaveCurrentProfile"), stop = call("onOverhaulActive") },
    resources = { "vehicle", "tasklist" },
    settlement = "owner",
    economyKeys = {},
  }
end
