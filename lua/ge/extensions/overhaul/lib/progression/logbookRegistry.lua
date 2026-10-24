-- Entry owners register renderers here; the logbook owns storage and retention.
-- registerType(id, render, owner) requires a dotted namespace and an owner identity.
-- Same-owner reload replaces the registration; conflicting owners are warned/rejected.
-- It returns a registration token. unregisterType(id, owner, token) ignores stale teardown;
-- unregisterOwner(owner) removes that owner's entries (use a fresh table per owner lifetime).
local M = {}
local types = {}

local function warn(message)
  if log then log("W", "logbookRegistry", message) end
end

function M.registerType(id, render, owner)
  assert(type(id) == "string" and id:match("^[%w_-]+%.[%w_.-]+$"), "namespaced entry type required")
  assert(type(render) == "function", "entry renderer required")
  assert(type(owner) == "string" or type(owner) == "table", "entry owner required")
  if types[id] and types[id].owner ~= owner then
    warn("Conflicting logbook entry owner: " .. id)
    return nil
  end
  local registration = {render = render, owner = owner}
  types[id] = registration
  return registration
end

function M.unregisterType(id, owner, token)
  local registration = types[id]
  if not registration or registration.owner ~= owner or registration ~= token then return false end
  types[id] = nil
  return true
end

function M.unregisterOwner(owner)
  for id, registration in pairs(types) do
    if registration.owner == owner then types[id] = nil end
  end
end

-- Reject invalid UTF-8; clip valid text only between complete code points.
local function boundedText(value, limit)
  if type(value) ~= "string" then return nil end
  local i, last = 1, 0
  while i <= #value do
    local b = value:byte(i)
    local width = b < 128 and 1 or b >= 194 and b <= 223 and 2
      or b >= 224 and b <= 239 and 3 or b >= 240 and b <= 244 and 4
    if not width or i + width - 1 > #value then return nil end
    for j = i + 1, i + width - 1 do
      local c = value:byte(j)
      if c < 128 or c > 191 then return nil end
    end
    local second = value:byte(i + 1)
    if (b == 224 and second < 160) or (b == 237 and second > 159)
      or (b == 240 and second < 144) or (b == 244 and second > 143) then return nil end
    if i + width - 1 <= limit then last = i + width - 1 end
    i = i + width
  end
  return value:sub(1, last)
end

-- Facts are snapshots of public labels/values, never arbitrary owner objects.
local function boundedFacts(value)
  local facts = {}
  if type(value) ~= "table" then return facts end
  for i = 1, math.min(#value, 12) do
    local fact = value[i]
    if type(fact) == "table" then
      local label = boundedText(fact.label, 80)
      local raw = fact.value
      if type(raw) == "number" and raw == raw and math.abs(raw) < math.huge then raw = tostring(raw) end
      local text = boundedText(raw, 256)
      if label and label:match("%S") and text and text:match("%S") then
        facts[#facts + 1] = {label = label, value = text,
          kind = fact.kind == "money" and tonumber(text) and math.abs(tonumber(text)) < math.huge and "money" or nil}
      end
    end
  end
  return facts
end

function M.build(id, payload)
  local registration = types[id]
  if not registration or type(payload) ~= "table" then return nil end
  local ok, snapshot = pcall(function()
    local entry = registration.render(payload)
    if type(entry) ~= "table" then return nil end
    local title = boundedText(entry.title, 256)
    local text = boundedText(entry.text, 1024)
    local label = entry.label
    local boundedLabel = boundedText(label, 80)
    if not title or title == "" or not text or (label ~= nil and not boundedLabel) then return nil end
    local receipt = entry.receipt
    if receipt ~= nil and (type(receipt) ~= "string" or #receipt > 160 or not boundedText(receipt, 160)) then return nil end
    -- Persist only bounded public fields, never live entities or callback data.
    return {type = "progress", overhaulEntryType = id, plainText = true,
      icon = boundedText(entry.icon, 80), receipt = receipt,
      facts = boundedFacts(entry.facts), subtitle = boundedText(entry.subtitle, 256),
      related = boundedText(entry.related, 40),
      title = title, text = text, cardTypeLabel = boundedLabel and boundedLabel:match("%S") and boundedLabel or "Activity",
      money = type(entry.money) == "number" and entry.money == entry.money
        and math.abs(entry.money) < math.huge and entry.money or nil}
  end)
  if not ok then
    if not registration.warned then
      registration.warned = true
      warn("Failed logbook entry renderer: " .. id)
    end
    return nil
  end
  return snapshot
end

return M
