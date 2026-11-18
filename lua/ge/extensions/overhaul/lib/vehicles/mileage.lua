local M={}
function M.apply(vehicle,mileage)
  vehicle:queueLuaCommand(string.format([[
    local conditions=partCondition.getConditions() or {}
    for _,condition in pairs(conditions) do condition.odometer=%.17g end
    partCondition.setResetSnapshotKey(nil)
    partCondition.reset()
    partCondition.initConditions(conditions,%.17g)
  ]],mileage,mileage))
end
return M
