-- damageTracker has no way to remove a callback, so the scanner registers one per vehicle Lua VM.
-- Required, not loaded as an extension, so it outlives scanner reloads.
local registered = false

return function()
  if registered then return end
  registered = true
  damageTracker.registerDamageUpdateCallback(function(data, delta)
    local scanner = rawget(_G, "overhaulObdScanner")
    if type(scanner) == "table" and type(scanner.onDamageDataChanged) == "function" then
      scanner.onDamageDataChanged(data, delta)
    end
  end)
end
