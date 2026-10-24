-- Owner-local feed descriptors. Add-ons use the same registry and committed-event contract.
local M = {}
function M.register(id, descriptor, owner)
  require("overhaul/lib/progression/logbookRegistry").registerType(id, function(data)
    local text = data.detail or data.name or ""
    if core_locales then text = core_locales.translateWithOrWithoutContext(text) end
    return {title = data.title or descriptor.title, text = text,
      label = descriptor.label, icon = descriptor.icon, money = data.money, receipt = data.receipt, facts = data.facts,
      subtitle = data.name, related = descriptor.related}
  end, owner)
  return function(data)
    -- Presentation must never interrupt a committed gameplay operation.
    local ok, reason = pcall(function() extensions.hook("onOverhaulLogbookEvent", id, data) end)
    if not ok and log then log("W", "logbookFeed", tostring(reason)) end
  end
end
return M
