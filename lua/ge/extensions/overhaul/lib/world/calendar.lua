-- Calendar-only consumers share a provider contract without constructing a screen payload.
local capabilities = require('overhaul/lib/platform/capabilities')
local M = {}
function M.get()
  local provider = capabilities.get('worldCalendar')
  return provider and provider.getCalendarState and provider.getCalendarState() or {ready=false}
end
return M
