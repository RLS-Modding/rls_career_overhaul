-- One definition per maintenanceComputer load. No state or lifecycle dispatch: delegates always
-- look up the current export on the owning M, exactly as the existing UI does.
return function(M)
  local function delegate(name) return function(...) return M[name](...) end end
  return {
    id = 'maintenance', label = 'Maintenance service', role = 'service', modes = {'career'},
    extension = 'overhaul_career_maintenance_maintenanceComputer', lifecycle = 'maintenance',
    actions = {
      getMaintenanceUiData = delegate('getMaintenanceUiData'),
      startCheck = delegate('startCheck'),
      inspectTires = delegate('inspectTires'),
      getMaintenanceUiDataForBusinessVehicle = delegate('getMaintenanceUiDataForBusinessVehicle'),
      startCheckForBusinessVehicle = delegate('startCheckForBusinessVehicle'),
      startServiceForBusinessVehicle = delegate('startServiceForBusinessVehicle'),
      inspectBusinessVehicleTires = delegate('inspectBusinessVehicleTires'),
      checkoutTiresForBusinessVehicle = delegate('checkoutTiresForBusinessVehicle'),
    },
    -- UI builders normalize/persist state; the descriptor has no active predicate or save hook.
    transitions = {stop = delegate('onOverhaulActive')},
    resources = {'vehicle'}, settlement = 'owner', economyKeys = {},
  }
end
