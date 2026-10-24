-- Transaction metadata belongs to the posting system. Providers can fill missing fields
-- at recording time; historical reads never consult a live vehicle, facility or provider.
local M = {}
local ledgerCategories = require("overhaul/lib/ledger/categories")
local providers, categories = {}, {}

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do result[key] = copy(item, seen) end
  return result
end

local function text(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function id(value)
  if type(value) == "number" and value == value and math.abs(value) < math.huge then return tostring(value) end
  return text(value)
end

-- Producers declare intent here; providers resolve live names/identities only at posting.
-- Copy rather than alter a shared reason/spec used by retries or XP-only legs.
function M.tag(reason, category, fields)
  local result = copy(type(reason) == "table" and reason or {})
  local finance = type(result.finance) == "table" and result.finance or {}
  if result.category == nil then
    local ledgerCategory = ledgerCategories.normalize(category)
    if ledgerCategory and ledgerCategory ~= "unknown" then result.category = ledgerCategory
    else finance.category = finance.category or category end
  end
  for key, value in pairs(fields or {}) do
    if finance[key] == nil then finance[key] = copy(value) end
  end
  if next(finance) then result.finance = finance end
  return result
end

function M.tagPayout(spec, category, fields)
  local result = {}
  for key, value in pairs(spec) do
    if key == "destination" and type(value) == "table" then
      result.destination = {}
      -- Never traverse opaque registration tokens; their owners can be cyclic.
      for field, item in pairs(value) do
        result.destination[field] = field == "holder" and item or copy(item)
      end
    else result[key] = copy(value) end
  end
  result.reason = M.tag(result.reason, result.category or category, fields)
  return result
end

-- Re-registering an id replaces it. A stale disposer cannot remove its replacement.
function M.registerCategory(key, definition)
  assert(text(key) and type(definition) == "table" and text(definition.name), "category needs an id and name")
  local entry = {id = key, name = definition.name, accent = definition.accent or "#8e8e93"}
  categories[key] = entry
  return function() if categories[key] == entry then categories[key] = nil end end
end

function M.registerProvider(key, callback, order)
  assert(text(key) and type(callback) == "function", "provider needs an id and callback")
  order = tonumber(order) or 100
  assert(order == order and math.abs(order) < math.huge, "provider order must be finite")
  local entry = {id = key, callback = callback, order = order}
  providers[key] = entry
  return function() if providers[key] == entry then providers[key] = nil end end
end

local names = {
  unknown = {"Uncategorized", "#8e8e93"}, work_income = {"Work income", "#248a3d"},
  purchase = {"Purchase", "#5856d6"}, sale = {"Sales", "#248a3d"}, repair = {"Repair", "#bf5b00"},
  insurance = {"Insurance", "#007aff"}, fuel = {"Fuel", "#af52de"}, fine = {"Fines", "#c93430"},
  rent = {"Rent", "#98651d"}, property = {"Property", "#98651d"}, service = {"Services", "#007aff"},
  business = {"Business", "#5856d6"}, transfer = {"Transfers", "#007aff"}, loan = {"Loans", "#98651d"},
  interest = {"Interest", "#248a3d"}, refund = {"Refunds", "#248a3d"}, reward = {"Rewards", "#248a3d"},
  gambling = {"Gambling", "#af52de"}, cheat = {"Cheats", "#8e8e93"},
  starting_funds = {"Starting funds", "#248a3d"},
}
for key, value in pairs(names) do M.registerCategory(key, {name = value[1], accent = value[2]}) end

local function humanize(value)
  return (value:gsub("[_%-]", " "):gsub("^%l", string.upper))
end

-- Exact semantic tags only. Never parse translated/free-form labels or guess a current car.
local tagCategories = {
  fuel = "fuel", repair = "repair", insurance = "insurance", fine = "fine",
  vehicleBought = "purchase", vehicleSold = "sale", rent = "rent", startingFunds = "starting_funds",
}
-- Built-in payments saved before they declared a category carried only their exact label.
-- A closed historical list: new producers declare a category through tag/tagPayout.
local labelCategories = {
  ["Towed your vehicle to your garage"] = "service",
  ["Towed your vehicle and connected trailers to the road"] = "service",
  ["Flipped your vehicle and connected trailers upright"] = "service",
  ["Dyno session fee"] = "service",
  ["ui.career.delivery.general.penaltyAbandonLabel"] = "fine",
}
-- Compatibility inference for exact historical built-in tags. New producers
-- declare category/source explicitly through tag/tagPayout and the registry.
local workTags
local function historicalWorkTags()
  if not workTags then
    workTags = assert(jsonReadFile('/gameplay/overhaul/finance/legacyWorkTags.json'), 'Missing historical finance work tags')
    for tag, source in pairs(workTags) do
      assert(text(tag) and text(source), 'Historical finance work tags need string tags and sources')
    end
  end
  return workTags
end
local function hasTag(tags, wanted)
  if type(tags) ~= "table" then return false end
  if tags[wanted] == true then return true end
  for _, value in ipairs(tags) do if value == wanted then return true end end
  return false
end

-- Only these exact built-in legacy service tag sets override old fine inference.
local function legacyService(reason)
  if type(reason) ~= "table" or reason.category ~= nil or type(reason.tags) ~= "table"
      or (type(reason.finance) == "table" and reason.finance.category ~= nil) then return false end
  local tags = {}
  for key, value in pairs(reason.tags) do
    local tag = type(key) == "number" and value or (value == true and key or nil)
    if type(tag) ~= "string" then return false end
    tags[tag] = true
  end
  local count = 0
  for _ in pairs(tags) do count = count + 1 end
  return (count == 2 and tags.fine and tags.rental)
    or (count == 4 and tags.gameplay and tags.employment and tags.tow and tags.fine)
end

local function base(reason, storedCategory, amount)
  reason = type(reason) == "table" and reason or {}
  local result = copy(type(reason.finance) == "table" and reason.finance or {})
  result.vehicleName = text(result.vehicleName)
  local category = text(result.category) or ledgerCategories.normalize(storedCategory or reason.category)
  local activity = category and category:match("^activity:(.+)$")
  if activity then category = "work_income" end
  if not category or category == "unknown" then
    local found = legacyService(reason) and "service" or nil
    for tag, candidate in pairs(legacyService(reason) and {} or tagCategories) do
      if hasTag(reason.tags, tag) then
        if found and found ~= candidate then found = "unknown"; break end
        found = candidate
      end
    end
    category = found
  end
  local source = text(result.source) or activity or text(reason.demandJobId)
  if not source and type(reason.tags) == "table" and next(reason.tags) then
    local found, ambiguous
    for tag, candidate in pairs(historicalWorkTags()) do
      if hasTag(reason.tags, tag) then
        if found and found ~= candidate then ambiguous = true end
        found = candidate
      end
    end
    if not ambiguous then source = found end
  end
  result.category = category or (source and amount > 0 and "work_income") or "unknown"
  result.source = source
  return result
end

local nonVehicleCategories = {starting_funds=true, transfer=true, loan=true, interest=true,
  property=true, rent=true, business=true, cheat=true, gambling=true, reward=true}

local function sanitize(value, timestamp)
  local category = text(value.category) or "unknown"
  local definition = categories[category]
  -- A source tag on a purchase, fee or refund must not turn it into work income.
  local isWork = category == "work_income" or (value.isWork == true and names[category] == nil)
  local vehicleRelated = value.vehicleRelated
  if type(vehicleRelated) ~= "boolean" then vehicleRelated = nil end
  if category == "starting_funds" or category == "transfer" then vehicleRelated = false
  elseif nonVehicleCategories[category] and vehicleRelated == nil
      and not id(value.vehicleId) and not id(value.vehicleKey) and not text(value.vehicleName) then
    vehicleRelated = false
  end
  local vehicleId = vehicleRelated ~= false and id(value.vehicleId) or nil
  return {
    version = 1, category = category,
    categoryName = text(value.categoryName) or (definition and definition.name) or humanize(category),
    categoryAccent = text(value.categoryAccent) or (definition and definition.accent) or "#8e8e93",
    isWork = isWork, vehicleRelated = vehicleRelated,
    source = id(value.source), sourceName = text(value.sourceName) or (id(value.source) and humanize(id(value.source))),
    vehicleId = vehicleId, vehicleKey = vehicleRelated ~= false and id(value.vehicleKey) or nil,
    vehicleName = vehicleRelated ~= false and text(value.vehicleName) or nil,
    locationId = id(value.locationId), locationName = text(value.locationName),
    timestamp = timestamp,
  }
end

function M.capture(reason, timestamp, amount)
  local result = base(reason, nil, amount)
  local ordered = {}
  for _, provider in pairs(providers) do ordered[#ordered + 1] = provider end
  table.sort(ordered, function(a, b) if a.order == b.order then return a.id < b.id end return a.order < b.order end)
  for _, provider in ipairs(ordered) do
    local ok, fields = pcall(provider.callback, {reason = copy(reason), amount = amount, timestamp = timestamp})
    if ok and type(fields) == "table" then
      for key, value in pairs(fields) do if result[key] == nil or (key == "category" and result[key] == "unknown") then result[key] = copy(value) end end
    elseif not ok and log then log("W", "financeMetadata", "Provider " .. provider.id .. " failed: " .. tostring(fields)) end
  end
  return sanitize(result, timestamp)
end

function M.read(row, amount)
  local timestamp = tonumber(row.time)
  if timestamp and (timestamp ~= timestamp or math.abs(timestamp) == math.huge) then timestamp = nil end
  if timestamp then
    local ok = pcall(os.date, "!%Y", timestamp)
    if not ok then timestamp = nil end
  end
  local saved = type(row.finance) == "table" and row.finance
  -- This exact built-in label was the sole marker written by old start modes.
  -- Do not pattern-match arbitrary labels or infer any historical car.
  if (not saved or saved.category == "unknown") and not row.category
      and type(row.reason) == "table" and row.reason.label == "Starting Capital"
      and (row.reason.tags == nil or (type(row.reason.tags) == "table" and not next(row.reason.tags))) then
    saved = copy(saved or {})
    saved.category, saved.categoryName, saved.categoryAccent = "starting_funds", nil, nil
  end
  if not row.category and legacyService(row.reason) and saved and (saved.category == "fine" or saved.category == "unknown") then
    saved = copy(saved)
    saved.category, saved.categoryName, saved.categoryAccent = "service", nil, nil
  end
  local labelled = not row.category and type(row.reason) == "table" and labelCategories[row.reason.label]
  if labelled then
    local current = saved or base(row.reason, nil, amount)
    if current.category == "unknown" then
      saved = copy(current)
      saved.category, saved.categoryName, saved.categoryAccent = labelled, nil, nil
    end
  end
  return sanitize(saved or base(row.reason, row.category, amount), timestamp), type(row.finance) ~= "table"
end

-- Facility names are resolved once at recording; historical reads stay pure.
M.registerProvider("world.facilityNames", function(context)
  local finance = type(context.reason) == "table" and context.reason.finance
  local locationId = type(finance) == "table" and id(finance.locationId)
  local facilities = overhaul_world_facilities
  if not locationId or finance.locationName or not facilities or not facilities.getCurrentLevelFacilities then return end
  if not getCurrentLevelIdentifier or not getCurrentLevelIdentifier() then return end
  local found
  for _, list in pairs(facilities.getCurrentLevelFacilities() or {}) do
    if type(list) == "table" then
      for _, facility in pairs(list) do
        if type(facility) == "table" and id(facility.id) == locationId and text(facility.name) then
          if found and found ~= facility.name then return end
          found = facility.name
        end
      end
    end
  end
  if found then return {locationName = found} end
end, 200)

M.copy = copy
return M
