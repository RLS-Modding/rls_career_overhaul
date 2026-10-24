-- Stateless factory: the UI actions and existing hook names belong to the M supplied by this
-- insurance extension load. The engine keeps dispatching hooks in its existing order.
return function(M)
  local function delegate(name) return function(...) return M[name](...) end end
  return {
    id = 'insuranceRepair', label = 'Insurance repair', role = 'service', modes = {'career'},
    extension = 'overhaul_career_repair_insurance', lifecycle = 'insuranceRepair',
    actions = {
      calculateInsurancePremium = delegate('calculateInsurancePremium'),
      calculateVehiclePremium = delegate('calculateVehiclePremium'),
      changeInvVehInsurance = delegate('changeInvVehInsurance'),
      closeMenu = delegate('closeMenu'),
      openChooseInsuranceScreen = delegate('openChooseInsuranceScreen'),
      resetDriverScore = delegate('resetDriverScore'),
      saveNewInsuranceCoverageOptions = delegate('saveNewInsuranceCoverageOptions'),
      saveNewVehicleCoverageOptions = delegate('saveNewVehicleCoverageOptions'),
      sendChangeInsuranceDataToTheUI = delegate('sendChangeInsuranceDataToTheUI'),
      sendChooseInsuranceDataToTheUI = delegate('sendChooseInsuranceDataToTheUI'),
      sendUIData = delegate('sendUIData'),
    },
    -- No active predicate or existing non-pushing UI payload builder. Loading saved policy data remains the owner's activation path; it has no exported data-taking restore adapter.
    save = delegate('onOverhaulSaveCurrentProfile'),
    transitions = {save = delegate('onOverhaulSaveCurrentProfile'), stop = delegate('onOverhaulActive')},
    resources = {'vehicle', 'timer', 'input'}, settlement = 'owner', economyKeys = {},
  }
end
