-- Sponsor payer for taxi fares: covers the fare reason and posts the paid-by message.
-- Fare coverage stays available while payment is loaded, even when no cab runtime is loaded.

local FARE_LABEL_KEY = "ui.taxi.fareLabel"
local DEFAULT_FARE_LABEL = "Taxi fare"

-- Translations and the notification are resolved at payment time, not at load time.
local function fareLabel()
  return (_tr and _tr(FARE_LABEL_KEY)) or DEFAULT_FARE_LABEL
end

local function isFareReason(reason)
  if not reason then return false end
  local label = reason.label
  if type(label) ~= "string" or label == "" then return false end
  return label == fareLabel() or label == FARE_LABEL_KEY or label == DEFAULT_FARE_LABEL
end

return {
  matches = function(price, reason, accountId)
    return isFareReason(reason)
  end,
  onCovered = function(name, price, reason, accountId)
    ui_message(string.format("Fare paid by %s", name), 5, "taxi", "info")
  end,
}
