-- Negotiation lines: what the other party says in a vehicle negotiation, chosen by voice and situation.
-- Voices live in /gameplay/overhaul/market/negotiationLines/*.json (overhaul.json first, then add-on files by name);
-- registerVoice adds lines at runtime. A voice names who is talking (a dealer, a junkyard, a private buyer) and lists
-- lines per situation; it may extend another voice for anything it leaves out.
-- Reading order: situations, voice registry, voice resolution, rendering, pick.
-- Contract: pick(context, situation, recent, preferred) returns {text, pre, post} or nil. Price situations split the
-- line around {price} so the UI can draw the amount; nil means no voice had a usable line and the UI keeps its own words.
local M = {}

local LINES_FOLDER = '/gameplay/overhaul/market/negotiationLines/'
local BASE_FILE = LINES_FOLDER .. 'overhaul.json'
local LOG_TAG = 'negotiationLines'

-- Situations ---------------------------------------------------------------------------------------

-- price: the line must carry exactly one {price}. personalityField: lines a negotiation personality brings along
-- (map personality files), used by voices that set usePersonalityLines.
M.situations = {
  opening = {price = false, personalityField = 'quotesByPriceTier'},
  openingNoPrice = {price = false},
  askingPrice = {price = true},
  counter = {price = true},
  hold = {price = true},
  finalOffer = {price = true},
  accepted = {price = true},
  acceptedHappy = {price = false, personalityField = 'happyQuotes'},
  insulted = {price = false, personalityField = 'insultQuotes'},
  walkedAway = {price = false},
}

-- Fallback voice for each side when nothing more specific matches; overhaul.json defines both.
M.genericVoice = {buying = 'seller', selling = 'buyer'}

-- Most specific first: an explicit facility voice, then the seller id, its sales channel, its used-vehicle profile
-- and finally the kind of source (dealership, private, carMeet, marketplace).
local MATCH_ORDER = {
  {field = 'sellerIds', contextKey = 'sellerId'},
  {field = 'salesChannels', contextKey = 'salesChannel'},
  {field = 'usedVehicleProfiles', contextKey = 'usedVehicleProfile'},
  {field = 'sources', contextKey = 'source'},
}
local PRICE_TIERS = {low = true, mid = true, high = true}

-- Registry -------------------------------------------------------------------------------------------

local voices = {}
local skipKeys = {}
local runtimeVoices = {}
local loaded = false
local lastPick = {}

-- Line variety draws from its own generator so negotiation prices keep their math.random order.
local randomState = (os.time() % 2147483646) + 1
local function nextRandom(count)
  randomState = (randomState * 16807) % 2147483647
  return 1 + math.floor(randomState / 2147483647 * count)
end

function M.setRandomSeed(seed)
  randomState = (math.floor(tonumber(seed) or 1) % 2147483646) + 1
end

local function warn(message)
  if log then log('W', LOG_TAG, message) end
end

local function isLocaleKey(line)
  return line:match('^ui%.[%w_%.]+$') ~= nil
end

local function priceCount(line)
  local _, count = line:gsub('{price}', '')
  return count
end

-- Plain-text lines are checked when they arrive; locale keys are checked again once translated.
local function acceptsLine(situation, line)
  if type(line) ~= 'string' or line == '' then return false end
  local spec = M.situations[situation]
  if not spec or isLocaleKey(line) then return spec ~= nil end
  return priceCount(line) == (spec.price and 1 or 0)
end

local function appendLines(target, situation, lines, source)
  for _, line in ipairs(type(lines) == 'table' and lines or {}) do
    if acceptsLine(situation, line) then
      target[#target + 1] = line
    else
      warn(string.format('Dropping %s line from %s: %s', situation, source, tostring(line)))
    end
  end
end

-- A situation holds a list, or price-tier lists (low/mid/high) plus 'any' for every tier.
local function mergeSituation(into, situation, value, source)
  if type(value) ~= 'table' then return end
  into[situation] = into[situation] or {any = {}}
  local slot = into[situation]
  if value[1] ~= nil then
    appendLines(slot.any, situation, value, source)
    return
  end
  for tier, lines in pairs(value) do
    if tier == 'any' or PRICE_TIERS[tier] then
      slot[tier] = slot[tier] or {}
      appendLines(slot[tier], situation, lines, source)
    end
  end
end

local function mergeVoice(id, def, source)
  if type(id) ~= 'string' or id == '' or type(def) ~= 'table' then
    warn('Ignoring malformed voice from ' .. tostring(source))
    return false
  end
  local voice = voices[id] or {match = {}, lines = {}, moods = {}}
  voices[id] = voice
  for _, field in ipairs({'extends', 'side', 'usePersonalityLines'}) do
    if def[field] ~= nil then voice[field] = def[field] end
  end
  for field, values in pairs(type(def.match) == 'table' and def.match or {}) do
    voice.match[field] = voice.match[field] or {}
    for _, value in ipairs(type(values) == 'table' and values or {}) do voice.match[field][value] = true end
  end
  for situation, value in pairs(type(def.lines) == 'table' and def.lines or {}) do
    if M.situations[situation] then mergeSituation(voice.lines, situation, value, source .. ':' .. id) end
  end
  for mood, moodLines in pairs(type(def.moods) == 'table' and def.moods or {}) do
    voice.moods[mood] = voice.moods[mood] or {}
    for situation, value in pairs(type(moodLines) == 'table' and moodLines or {}) do
      if M.situations[situation] then mergeSituation(voice.moods[mood], situation, value, source .. ':' .. id) end
    end
  end
  return true
end

local function mergeFile(path)
  local data = jsonReadFile(path)
  if type(data) ~= 'table' or type(data.voices) ~= 'table' then
    warn('Ignoring negotiation lines file without voices: ' .. tostring(path))
    return
  end
  for _, key in ipairs(type(data.skipLineKeys) == 'table' and data.skipLineKeys or {}) do skipKeys[key] = true end
  local ids = {}
  for id in pairs(data.voices) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do mergeVoice(id, data.voices[id], path) end
end

-- Files first (overhaul.json, then add-ons by name, later files add to earlier voices), runtime registrations last.
function M.reload()
  voices, skipKeys, lastPick, loaded = {}, {}, {}, true
  local files = FS and FS.findFiles and FS:findFiles(LINES_FOLDER, '*.json', -1, false, false) or {}
  table.sort(files)
  local hasBase = false
  for _, file in ipairs(files) do
    if file == BASE_FILE then hasBase = true end
  end
  if hasBase then mergeFile(BASE_FILE) end
  for _, file in ipairs(files) do
    if file ~= BASE_FILE then mergeFile(file) end
  end
  for _, entry in ipairs(runtimeVoices) do mergeVoice(entry.id, entry.def, 'registerVoice') end
end

local function ensureLoaded()
  if not loaded then M.reload() end
end

-- Add-ons call this (or ship a JSON file in the lines folder); the voice survives later reloads.
function M.registerVoice(id, def)
  ensureLoaded()
  if not mergeVoice(id, def, 'registerVoice') then return false end
  runtimeVoices[#runtimeVoices + 1] = {id = id, def = def}
  return true
end

function M.hasVoice(id)
  ensureLoaded()
  return voices[id] ~= nil
end

function M.voiceIds()
  ensureLoaded()
  local ids = {}
  for id in pairs(voices) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Voice resolution -----------------------------------------------------------------------------------

local function sideFits(voice, side)
  return voice.side == nil or voice.side == side
end

-- A voice, then everything it extends, skipping voices for the other side and cycles.
local function appendChain(order, seen, id, side)
  local guard = 0
  while type(id) == 'string' and voices[id] and not seen[id] and guard < 16 do
    seen[id] = true
    if sideFits(voices[id], side) then order[#order + 1] = id end
    id = voices[id].extends
    guard = guard + 1
  end
end

function M.voiceChain(context)
  ensureLoaded()
  context = context or {}
  local side = context.side == 'selling' and 'selling' or 'buying'
  local order, seen = {}, {}
  if context.voice then appendChain(order, seen, context.voice, side) end
  local ids = M.voiceIds()
  for _, rule in ipairs(MATCH_ORDER) do
    local value = context[rule.contextKey]
    if value ~= nil then
      for _, id in ipairs(ids) do
        local values = voices[id].match[rule.field]
        if values and values[value] and sideFits(voices[id], side) then appendChain(order, seen, id, side) end
      end
    end
  end
  appendChain(order, seen, M.genericVoice[side], side)
  return order
end

local function inheritedFlag(id, field)
  local guard = 0
  while id and voices[id] and guard < 16 do
    if voices[id][field] ~= nil then return voices[id][field] end
    id = voices[id].extends
    guard = guard + 1
  end
  return false
end

-- Rendering ------------------------------------------------------------------------------------------

local function translate(line)
  if not isLocaleKey(line) then return line end
  local text = _tr and _tr(line) or line
  -- A key the locale doesn't have would show raw; treat it as no line.
  if type(text) ~= 'string' or text == line then return nil end
  return text
end

-- nil when the line can't be shown here: a missing translation, an unknown or empty placeholder, a wrong {price}.
local function render(line, situation, fill)
  local text = translate(line)
  if not text then return nil end
  local spec = M.situations[situation]
  local expectedPrices = spec.price and 1 or 0
  if priceCount(text) ~= expectedPrices then return nil end
  local missing = false
  text = text:gsub('{(%w+)}', function(name)
    if name == 'price' then return nil end
    local value = fill and fill[name]
    if type(value) ~= 'string' or value == '' then
      missing = true
      return nil
    end
    return value
  end)
  -- Filled names can contain braces too; check the final text before splitting around the price.
  if missing or priceCount(text) ~= expectedPrices or text:gsub('{price}', ''):find('[{}]') then return nil end
  if not spec.price then return {text = text} end
  local priceAt = text:find('{price}', 1, true)
  return {pre = text:sub(1, priceAt - 1), post = text:sub(priceAt + #'{price}')}
end

local function addSlotLines(out, slot, tier)
  if not slot then return end
  for _, line in ipairs(slot.any or {}) do out[#out + 1] = line end
  for _, line in ipairs(tier and slot[tier] or {}) do out[#out + 1] = line end
end

local function addPersonalityLines(out, personality, situation, tier)
  local field = M.situations[situation].personalityField
  local value = field and type(personality) == 'table' and personality[field]
  if type(value) ~= 'table' then return end
  if field == 'quotesByPriceTier' then value = value[tier or 'low'] end
  for _, line in ipairs(type(value) == 'table' and value or {}) do
    if type(line) == 'string' then out[#out + 1] = line end
  end
end

-- Mood lines (keyed by the personality archetype) replace the voice's own lines for that situation.
local function candidateLines(id, situation, context)
  local voice = voices[id]
  local out = {}
  local mood = context.archetype and voice.moods[context.archetype]
  addSlotLines(out, mood and mood[situation], context.priceTier)
  if #out > 0 then return out end
  addSlotLines(out, voice.lines[situation], context.priceTier)
  if inheritedFlag(id, 'usePersonalityLines') then
    addPersonalityLines(out, context.personality, situation, context.priceTier)
  end
  return out
end

local function usableLines(lines, situation, context)
  local out, seenLine = {}, {}
  for _, line in ipairs(lines) do
    if not skipKeys[line] and not seenLine[line] then
      seenLine[line] = true
      local rendered = render(line, situation, context.fill)
      if rendered then out[#out + 1] = {key = line, rendered = rendered} end
    end
  end
  return out
end

-- Pick -----------------------------------------------------------------------------------------------

-- Avoid anything already said in this negotiation and the last line this voice used for the situation.
local function choose(candidates, recent, lastKey, preferred)
  local fresh = {}
  for _, c in ipairs(candidates) do
    if not recent[c.key] and c.key ~= lastPick[lastKey] then
      if c.key == preferred then return c end
      fresh[#fresh + 1] = c
    end
  end
  if #fresh == 0 then
    for _, c in ipairs(candidates) do
      if c.key ~= lastPick[lastKey] then fresh[#fresh + 1] = c end
    end
  end
  if #fresh == 0 then fresh = candidates end
  return fresh[nextRandom(#fresh)]
end

-- preferred: a line already chosen elsewhere; kept only when usable and not recent or the previous pick.
function M.pick(context, situation, recent, preferred)
  if not M.situations[situation] then return nil end
  context = context or {}
  recent = recent or {}
  for _, id in ipairs(M.voiceChain(context)) do
    local candidates = usableLines(candidateLines(id, situation, context), situation, context)
    if #candidates > 0 then
      local choice = choose(candidates, recent, id .. '/' .. situation, preferred)
      recent[choice.key] = true
      lastPick[id .. '/' .. situation] = choice.key
      local line = {voice = id}
      for k, v in pairs(choice.rendered) do line[k] = v end
      return line
    end
  end
  return nil
end

return M
