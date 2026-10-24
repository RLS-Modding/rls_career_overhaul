-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/marketplace.lua (BeamNG 0.40).
-- Listings own offer generation and saves; marketplace/negotiation owns each negotiation session.
-- Read config/state and listing helpers, sale acceptance and negotiation, then offer passes, lifecycle and exports.

local M = {}

local negotiationLib = require('overhaul/career/market/marketplace/negotiation')
local phoneLayout = require("overhaul/lib/phone/layoutOwner")
local personalitySources = require('overhaul/lib/market/personalityData')

-- Config ------------------------------------------------------------------------------------------

local config = {
  TIME_BETWEEN_OFFERS_BASE = 95,
  OFFER_TTL = 500,
  OFFER_TTL_VARIANCE = 0.5,
  OFFER_MARKET_REVIEW_THRESHOLD = 0.03,
  OFFER_COMMIT_CHANCE = 0.125,
  MAX_RETRACTIONS_PER_LISTING_PASS = 2,
  MAXIMUM_EXPIRED_OFFERS = 3,
  MIN_RATIO_DENOMINATOR = 1,
  PHONE_NOTIF_SOUND = {soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open"},
  DETAILED_OFFER_BANNER_LIMIT = 3,
  DETAILED_OFFER_TTL = 8,
  DIGEST_OFFER_TTL = 15,
  DIGEST_REPLACE_KEY = "marketplace.offerDigest",
}

-- Name and quote data -----------------------------------------------------------------------------

M.firstNames = {
  "Aaliyah", "Aaron", "Abdullah", "Abigail", "Adam", "Aditya", "Adrian", "Adriana", "Adrien", "Agustin", "Ahmed", "Aisha", "Akari", "Akira", "Alan", "Albert", "Alberto", "Alejandra", "Alejandro", "Alessandro", "Alessia", "Alexander", "Alexandre", "Alexei", "Alexis", "Alfonso", "Alfredo", "Ali", "Alice", "Alicia", "Amanda", "Amandine", "Amber", "Amelia", "Amelie", "Amina", "Amir", "Amit", "Amparo", "Amy", "Ana", "Ananya", "Anastasia", "Andre", "Andrea", "Andreas", "Andrei", "Andres", "Andrew", "Angel", "Angela", "Anh", "Anjali", "Ann", "Anna", "Anselmo", "Anthony", "Antoine", "Anton", "Antonia", "Antonio", "Aoi", "Arjun", "Armando", "Artem", "Arthur", "Arturo", "Ascension", "Ashley", "Audrey", "Aurelie", "Aurora", "Austin", "Baptiste", "Barbara", "Beatrice", "Beatriz", "Benjamin", "Bernardo", "Betty", "Beverly", "Bilal", "Billy", "Binh", "Blanca", "Bobby", "Brandon", "Brenda", "Brian", "Brianna", "Brittany", "Bruce", "Bryan", "Camila", "Camille", "Cao", "Carl", "Carlos", "Carmen", "Carol", "Carolina", "Caroline", "Carolyn", "Catalina", "Catherine", "Cecile", "Celestino", "Celine", "Cesar", "Charles", "Charlotte", "Chen", "Cheng", "Cheryl", "Chiara", "Christian", "Christina", "Christine", "Christopher", "Claire", "Claudia", "Clement", "Concepcion", "Consuelo", "Cristian", "Cristina", "Cynthia", "Dalia", "Daniel", "Daniela", "Danielle", "Daria", "Dario", "Darius", "Darnell", "David", "Davide", "DeAndre", "Deborah", "Debra", "Deepika", "Deng", "Denis", "Denise", "Dennis", "Destiny", "Devonte", "Diana", "Diane", "Diego", "Dina", "Divya", "Dmitri", "Dolores", "Donald", "Donna", "Dorothy", "Douglas", "Duc", "Dylan", "Ebony", "Edoardo", "Eduardo", "Edward", "Ekaterina", "Elena", "Elisa", "Elisabeth", "Elise", "Eliseo", "Elizabeth", "Elodie", "Emilie", "Emilio", "Emily", "Emma", "Encarnacion", "Enrique", "Eric", "Erick", "Ernesto", "Esperanza", "Esteban", "Esther", "Ethan", "Eugene", "Eugenio", "Eun", "Eusebio", "Evelyn", "Fabian", "Fabien", "Faisal", "Fang", "Fatima", "Federico", "Felipe", "Felix", "Feng", "Fernanda", "Fernando", "Florian", "Frances", "Francesca", "Francesco", "Francisca", "Francisco", "Francois", "Frank", "Gabriel", "Gabriela", "Gabriele", "Gao", "Gary", "George", "Gerald", "Gerardo", "Ginevra", "Giorgia", "Giovanni", "Giulia", "Gloria", "Gonzalo", "Grace", "Graciela", "Gregory", "Greta", "Guadalupe", "Guillaume", "Guo", "Gustavo", "Hafsa", "Hai", "Hala", "Hamza", "Han", "Hana", "Hanan", "Hannah", "Harold", "Harry", "Haruka", "Hassan", "He", "Heather", "Hector", "Helen", "Helene", "Henri", "Henry", "Hiroshi", "Hoa", "Hu", "Huang", "Hugo", "Hui", "Hung", "Huong", "Hussein", "Hye", "Ibrahim", "Ignacio", "Igor", "Ines", "Irina", "Irma", "Isabel", "Isabelle", "Isha", "Isidro", "Ismael", "Ivan", "Jack", "Jacob", "Jacqueline", "Jalen", "Jamal", "James", "Jamil", "Jan", "Jane", "Janet", "Janice", "Jasmine", "Jason", "Javier", "Jean", "Jeffrey", "Jennifer", "Jeremy", "Jerry", "Jesse", "Jessica", "Ji", "Jimena", "Jin", "Jing", "Joan", "Joaquin", "Joe", "Johannes", "John", "Johnny", "Jonas", "Jonathan", "Jordan", "Jorge", "Jose", "Joseph", "Joshua", "Joyce", "Juan", "Juana", "Judith", "Judy", "Julia", "Julie", "Julien", "Juliette", "Julio", "Jun", "Justin", "Kai", "Karan", "Kareem", "Karen", "Karim", "Katharina", "Katherine", "Kathleen", "Kathryn", "Kathy", "Kavita", "Keisha", "Keith", "Kelly", "Kendrick", "Kenji", "Kenneth", "Kevin", "Khadija", "Khaled", "Khalid", "Kimberly", "Kiran", "Kristina", "Kyle", "Kyung", "Lan", "Larry", "Latoya", "Laura", "Lawrence", "Layla", "Lea", "Leandro", "Leila", "Leonardo", "Leticia", "Li", "Liliana", "Lin", "Lina", "Linda", "Ling", "Linh", "Lisa", "Liu", "Logan", "Lorenzo", "Lori", "Louis", "Luca", "Lucas", "Lucia", "Luis", "Lukas", "Luo", "Ma", "Madison", "Mahmoud", "Mai", "Malik", "Manoj", "Manon", "Manuel", "Manuela", "Marcelo", "Marco", "Marcus", "Margaret", "Margarita", "Maria", "Mariam", "Mariana", "Marie", "Marilyn", "Marina", "Marine", "Mario", "Marion", "Marisol", "Mark", "Markus", "Marquis", "Martha", "Martin", "Martina", "Mary", "Maryam", "Matteo", "Matthew", "Matthias", "Matthieu", "Maxim", "Maxime", "Maximilian", "Maximo", "Maya", "Meera", "Megan", "Mei", "Melanie", "Melissa", "Mercedes", "Mi", "Michael", "Michelle", "Miguel", "Mikhail", "Milagros", "Mildred", "Min", "Ming", "Mohammed", "Moises", "Mona", "Monica", "Monique", "Mustafa", "Na", "Nadia", "Nadine", "Nam", "Nancy", "Nasir", "Nasser", "Natalia", "Nathalie", "Nathan", "Natividad", "Neha", "Nestor", "Nga", "Nia", "Nicholas", "Nicolas", "Nicole", "Nikhil", "Nikolai", "Nina", "Nisha", "Noah", "Noha", "Noor", "Norma", "Nour", "Octavio", "Olga", "Olivier", "Omar", "Oscar", "Pablo", "Pamela", "Paola", "Patricia", "Patrick", "Paul", "Pauline", "Pavel", "Pedro", "Peter", "Petra", "Philip", "Philipp", "Philippe", "Phuong", "Piedad", "Pierre", "Pietro", "Pilar", "Polina", "Pooja", "Pradeep", "Presentacion", "Priya", "Purificacion", "Quang", "Rachel", "Rafael", "Rahul", "Raj", "Ralph", "Rami", "Ramon", "Rana", "Randy", "Rania", "Raquel", "Rashid", "Raul", "Ravi", "Raymond", "Rebecca", "Reem", "Regina", "Remedios", "Renato", "Rene", "Ricardo", "Riccardo", "Richard", "Rima", "Rin", "Riya", "Robert", "Roberto", "Rocio", "Rodolfo", "Rodrigo", "Rogelio", "Roger", "Rohan", "Romain", "Roman", "Ronald", "Rosa", "Rosario", "Rose", "Roy", "Ruben", "Russell", "Ryan", "Ryo", "Sabine", "Safiya", "Sakura", "Salma", "Salvador", "Salvatore", "Samantha", "Sami", "Samira", "Samuel", "Sandra", "Sang", "Sara", "Sarah", "Satoshi", "Saul", "Scott", "Sean", "Sebastian", "Sebastien", "Sergei", "Sergio", "Seung", "Shanice", "Sharon", "Shirley", "Shreya", "Siddharth", "Silvia", "Simon", "Simone", "Sneha", "Sofia", "Soledad", "Song", "Soo", "Sophie", "Stefan", "Stephanie", "Stephen", "Steven", "Sun", "Suresh", "Susan", "Susana", "Susanne", "Svetlana", "Swati", "Takeshi", "Tamer", "Tang", "Tanvi", "Tarek", "Tariq", "Tatiana", "Teodoro", "Teresa", "Terry", "Thao", "Theresa", "Thomas", "Tiffany", "Tim", "Timothy", "Tobias", "Tomas", "Tommaso", "Trevon", "Tuan", "Tyler", "Tyrone", "Valentin", "Valentina", "Valeria", "Valerio", "Vanessa", "Varun", "Veronica", "Victor", "Victoria", "Vikram", "Viktor", "Vincent", "Vincenzo", "Virginia", "Virginie", "Visitacion", "Vladimir", "Waleed", "Walter", "Wayne", "Wei", "William", "Willie", "Woo", "Wu", "Xia", "Xie", "Ximena", "Xu", "Yan", "Yang", "Yasmin", "Yolanda", "Young", "Youssef", "Yuan", "Yui", "Yuki", "Yulia", "Yusuf", "Yusuke", "Zachary", "Zain", "Zainab", "Zhang", "Zhao", "Zheng", "Zhou", "Zhu", "Zoe"
}
M.firstNameCount = #M.firstNames

M.initialProbabilities = {
  A = 0.038,
  B = 0.085,
  C = 0.077,
  D = 0.045,
  E = 0.019,
  F = 0.034,
  G = 0.056,
  H = 0.071,
  I = 0.004,
  J = 0.030,
  K = 0.033,
  L = 0.049,
  M = 0.096,
  N = 0.019,
  O = 0.015,
  P = 0.050,
  Q = 0.002,
  R = 0.059,
  S = 0.094,
  T = 0.035,
  U = 0.002,
  V = 0.018,
  W = 0.055,
  X = 0.0004,
  Y = 0.006,
  Z = 0.006,
}
M.initials = {}
for initial, probability in pairs(M.initialProbabilities) do
  for _ = 1, math.ceil(probability * 100) do
    table.insert(M.initials, initial)
  end
end
M.initialCount = #M.initials

M.privateSellerQuotes = {
  "ui.career.negotiation.privateSellerQuotes.01",
  "ui.career.negotiation.privateSellerQuotes.02",
  "ui.career.negotiation.privateSellerQuotes.03",
  "ui.career.negotiation.privateSellerQuotes.04",
  "ui.career.negotiation.privateSellerQuotes.05",
  "ui.career.negotiation.privateSellerQuotes.06",
  "ui.career.negotiation.privateSellerQuotes.07",
  "ui.career.negotiation.privateSellerQuotes.08",
  "ui.career.negotiation.privateSellerQuotes.09",
  "ui.career.negotiation.privateSellerQuotes.10",
  "ui.career.negotiation.privateSellerQuotes.11",
  "ui.career.negotiation.privateSellerQuotes.12",
  "ui.career.negotiation.privateSellerQuotes.13",
  "ui.career.negotiation.privateSellerQuotes.14",
  "ui.career.negotiation.privateSellerQuotes.15",
  "ui.career.negotiation.privateSellerQuotes.16",
  "ui.career.negotiation.privateSellerQuotes.17",
  "ui.career.negotiation.privateSellerQuotes.18",
  "ui.career.negotiation.privateSellerQuotes.19",
  "ui.career.negotiation.privateSellerQuotes.20",
  "ui.career.negotiation.privateSellerQuotes.21",
  "ui.career.negotiation.privateSellerQuotes.22",
  "ui.career.negotiation.privateSellerQuotes.23",
  "ui.career.negotiation.privateSellerQuotes.24",
  "ui.career.negotiation.privateSellerQuotes.25",
  "ui.career.negotiation.privateSellerQuotes.26",
  "ui.career.negotiation.privateSellerQuotes.27",
  "ui.career.negotiation.privateSellerQuotes.28",
  "ui.career.negotiation.privateSellerQuotes.29",
  "ui.career.negotiation.privateSellerQuotes.30",
  "ui.career.negotiation.privateSellerQuotes.31",
  "ui.career.negotiation.privateSellerQuotes.32",
  "ui.career.negotiation.privateSellerQuotes.33",
  "ui.career.negotiation.privateSellerQuotes.34",
  "ui.career.negotiation.privateSellerQuotes.35",
  "ui.career.negotiation.privateSellerQuotes.36",
  "ui.career.negotiation.privateSellerQuotes.37",
  "ui.career.negotiation.privateSellerQuotes.38",
  "ui.career.negotiation.privateSellerQuotes.39",
  "ui.career.negotiation.privateSellerQuotes.40",
  "ui.career.negotiation.privateSellerQuotes.41",
  "ui.career.negotiation.privateSellerQuotes.42",
  "ui.career.negotiation.privateSellerQuotes.43",
  "ui.career.negotiation.privateSellerQuotes.44",
  "ui.career.negotiation.privateSellerQuotes.45",
  "ui.career.negotiation.privateSellerQuotes.46",
  "ui.career.negotiation.privateSellerQuotes.47",
  "ui.career.negotiation.privateSellerQuotes.48",
  "ui.career.negotiation.privateSellerQuotes.49",
  "ui.career.negotiation.privateSellerQuotes.50"
}

M.dealershipBuyerQuotes = {
  "ui.career.negotiation.dealershipBuyerQuotes.01",
  "ui.career.negotiation.dealershipBuyerQuotes.02",
  "ui.career.negotiation.dealershipBuyerQuotes.03",
  "ui.career.negotiation.dealershipBuyerQuotes.04",
  "ui.career.negotiation.dealershipBuyerQuotes.05",
  "ui.career.negotiation.dealershipBuyerQuotes.06",
  "ui.career.negotiation.dealershipBuyerQuotes.07",
  "ui.career.negotiation.dealershipBuyerQuotes.08",
  "ui.career.negotiation.dealershipBuyerQuotes.09",
  "ui.career.negotiation.dealershipBuyerQuotes.10",
  "ui.career.negotiation.dealershipBuyerQuotes.11",
  "ui.career.negotiation.dealershipBuyerQuotes.12",
  "ui.career.negotiation.dealershipBuyerQuotes.13",
  "ui.career.negotiation.dealershipBuyerQuotes.14",
  "ui.career.negotiation.dealershipBuyerQuotes.15",
  "ui.career.negotiation.dealershipBuyerQuotes.16",
  "ui.career.negotiation.dealershipBuyerQuotes.17",
  "ui.career.negotiation.dealershipBuyerQuotes.18",
  "ui.career.negotiation.dealershipBuyerQuotes.19",
  "ui.career.negotiation.dealershipBuyerQuotes.20",
  "ui.career.negotiation.dealershipBuyerQuotes.21",
  "ui.career.negotiation.dealershipBuyerQuotes.22",
  "ui.career.negotiation.dealershipBuyerQuotes.23",
  "ui.career.negotiation.dealershipBuyerQuotes.24",
  "ui.career.negotiation.dealershipBuyerQuotes.25"
}

-- State -------------------------------------------------------------------------------------------

-- listedVehicles is saved with the career as marketplace.json.
local listedVehicles = {}
local offerMenuOpen = false
local detailedOfferBannersShown = 0
local digestBannerActive = false
local personalityData
local personalityMap
local personalityRead = false
local personalityWarnedMap
local timeSinceUpdate = 0
local offerPass = {listings = {}, count = 0, index = 0, timeNow = 0, diff = 0, active = false}

-- Filled in by the listing view below; kept as a table so earlier helpers can reach it at call time.
local listingView = {}

-- Phone notifications -----------------------------------------------------------------------------

local function fireMarketplacePhoneNotification(channelKey, title, message, meta, kind, opts)
  local layout = phoneLayout.get()
  if not (layout and layout.fireNotification) then
    return false
  end
  opts = opts or {}
  local sound
  if opts.sound == false then
    sound = false
  else
    sound = opts.sound or config.PHONE_NOTIF_SOUND
  end
  local payload = {
    title = title,
    message = message,
    meta = meta,
    kind = kind or "invite",
    ttl = opts.ttl or config.DETAILED_OFFER_TTL,
    source = "Marketplace",
    sound = sound,
  }
  if opts.forceTtl then
    payload.forceTtl = true
  end
  if type(opts.replaceKey) == "string" and opts.replaceKey ~= "" then
    payload.replaceKey = opts.replaceKey
  end
  return layout.fireNotification(channelKey, payload)
end

local function countPendingOffers()
  local count = 0
  for _, listing in ipairs(listedVehicles) do
    for _, offer in ipairs(listing.offers or {}) do
      if not offer.expiredViewCounter then
        count = count + 1
      end
    end
  end
  return count
end

local function offerWaitingLabel(pendingCount)
  if pendingCount == 1 then return "You have 1 offer waiting" end
  return "You have " .. pendingCount .. " offers waiting"
end

-- Waiting offers share one replaceable banner, so a burst of offers does not stack notifications.
local function fireOfferDigest(sound)
  local pendingCount = countPendingOffers()
  fireMarketplacePhoneNotification(
    "marketplace.newOffer",
    "Marketplace",
    offerWaitingLabel(pendingCount),
    nil,
    "invite",
    {
      ttl = config.DIGEST_OFFER_TTL,
      forceTtl = true,
      replaceKey = config.DIGEST_REPLACE_KEY,
      sound = sound,
    }
  )
end

-- Offer lookups and listing values ----------------------------------------------------------------

local function isStandoutOffer(listing, offerValue)
  local asking = tonumber(listing.value) or 0
  if asking > 0 and offerValue >= asking then
    return true
  end
  local market = tonumber(listing.marketValue) or tonumber(listing.marketValueAtListing) or asking
  if market > 0 and offerValue >= market * 0.95 then
    return true
  end
  local previousBest = tonumber(listing.bestOfferValue)
  if not previousBest or offerValue > previousBest then
    return true
  end
  return false
end

local function resetOfferBannerDigest()
  detailedOfferBannersShown = 0
  digestBannerActive = false
end

local function marketRatioDenominator(marketValue)
  return math.max(tonumber(marketValue) or 0, config.MIN_RATIO_DENOMINATOR)
end

local function offerTimeMultiplierForRatio(marketRatio)
  if marketRatio >= 0.98 and marketRatio <= 1.1 then
    return 1
  end
  if marketRatio < 0.98 then
    local t = math.max(0, math.min(1, inverseLerp(0.98, 0.85, marketRatio)))
    return lerp(1, 0.4, t)
  end
  if marketRatio > 1.1 then
    local t = math.max(0, math.min(1, inverseLerp(1.1, 1.5, marketRatio)))
    return lerp(1, 4.0, t)
  end
  return 1
end

local function roundListingPrice(value)
  local n = tonumber(value)
  if not n or n <= 0 then
    return nil
  end
  return math.max(50, math.floor((n + 25) / 50) * 50)
end

local function isListingValueManual(listing)
  return listing and listing.isManualValue
end

local function refreshLiveListingValues(listing)
  if not listing or not listing.id then
    return
  end
  if listing.rtBiz then
    return
  end

  local currentMarketValue = overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(listing.id)
  if not currentMarketValue then
    return
  end

  if listing.isManualValue == nil then
    listing.isManualValue = listing.value ~= (listing.marketValueAtListing or listing.marketValue)
  end

  listing.marketValue = currentMarketValue
  listing.marketValueCurrent = currentMarketValue
  if not isListingValueManual(listing) then
    listing.value = currentMarketValue
  end
end

local function findVehicleListing(inventoryId)
  for _, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId or tostring(listing.id) == tostring(inventoryId) then
      return listing
    end
  end
end

-- Resolve by stable offer id because a live part-condition sync can reorder the listing.
local function findOfferById(offerId)
  for _, listing in ipairs(listedVehicles) do
    for offerIndex, offer in ipairs(listing.offers) do
      if offer.id == offerId then
        return listing, offerIndex, offer
      end
    end
  end
end

local function isListed(listing)
  for _, listed in ipairs(listedVehicles) do
    if listed == listing then return true end
  end
  return false
end

local function getLiveListingValue(listing)
  if not listing or not listing.id then
    return nil
  end
  if listing.rtBiz then
    return tonumber(listing.marketValue) or tonumber(listing.value)
  end
  -- Collapse a missing vehicle's zero return values to one nil.
  return (overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(listing.id))
end

local function scheduleNextOffer(listing, timeNow)
  local multiplier = listing.offerTimeMultiplier or 1
  listing.timeOfNextOffer = timeNow + (config.TIME_BETWEEN_OFFERS_BASE * multiplier) + (math.random(-60, 60) / 100 * config.TIME_BETWEEN_OFFERS_BASE * multiplier)
end

-- Repair state and part sync ----------------------------------------------------------------------

-- Damaged cars can be listed at a reduced value; the only hard block is accepting an offer after the car was damaged after listing.
local function listingNeedsRepair(inventoryId)
  if type(inventoryId) ~= "number" then return false end
  local insurance = overhaul_career_repair_insurance
  return insurance.inventoryVehNeedsRepair(inventoryId) and true or false
end

local function listingDamagedAfterListing(listing, inventoryId)
  if not listing or listing.rtBiz then return false end
  local id = inventoryId or listing.id
  local needsRepair = listingNeedsRepair(id)
  if not needsRepair then
    -- Repairs do not excuse a later crash; update the live flag as well as the copied view.
    if listing.needsRepairAtListing then
      listing.repairedSinceListing = true
      local live = findVehicleListing(id)
      if live then
        live.repairedSinceListing = true
      end
    end
    return false
  end
  if listing.needsRepairAtListing and not listing.repairedSinceListing then
    return false -- still the original pre-list damage
  end
  return true
end

local function refuseSaleDamagedAfterListing()
  guihooks.trigger("toastrMsg", {
    type = "warning",
    title = "Repair required",
    msg = "This vehicle was damaged after listing. Repair it before accepting offers."
  })
end

local function finishSyncWithoutPull(onDone)
  if onDone then onDone() end
  return false
end

-- Pulls in-flight part-condition syncs, so repeat calls wait for the first one instead of asking twice.
local listingPartSyncInFlight = {}

-- Pull spawned part conditions before repair checks; the live snapshot completes through onDone.
local function syncSpawnedListingPartConditions(inventoryId, onDone)
  if type(inventoryId) ~= "number" then return finishSyncWithoutPull(onDone) end

  local inFlight = listingPartSyncInFlight[inventoryId]
  if inFlight then
    if onDone then
      table.insert(inFlight, onDone)
    end
    return true
  end

  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local veh = vehId and getObjectByID(vehId)
  if not veh then return finishSyncWithoutPull(onDone) end

  listingPartSyncInFlight[inventoryId] = {onDone}
  core_vehicleBridge.requestValue(veh, function(res)
    local callbacks = listingPartSyncInFlight[inventoryId] or {}
    listingPartSyncInFlight[inventoryId] = nil
    if res and res.result then
      overhaul_career_garage_inventory.getPartConditionsCallback(res.result, inventoryId)
    end
    for _, cb in ipairs(callbacks) do
      if cb then cb() end
    end
  end, 'getPartConditions')
  return true
end

-- Listing records --------------------------------------------------------------------------------

local function addVehicleListing(entry, timestamp)
  local inventoryId = entry.inventoryId
  local customValue = entry.value
  local veh = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not veh or findVehicleListing(inventoryId) then
    return false
  end

  -- Damage at listing is priced in; only damage after listing blocks acceptance.
  local needsRepairAtListing = listingNeedsRepair(inventoryId)

  local value = customValue or overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  local marketValue = overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  local marketRatio = tonumber(value) / marketRatioDenominator(marketValue)

  local offerTimeMultiplier = offerTimeMultiplierForRatio(marketRatio)

  local listingData = {
    id = veh.id,
    timestamp = timestamp,
    offers = {},
    value = value,
    marketValue = marketValue,
    marketValueAtListing = marketValue,
    needsRepairAtListing = needsRepairAtListing,
    isManualValue = customValue ~= nil,
    marketRatio = marketRatio,
    timeOfNextOffer = nil,
    offerTimeMultiplier = offerTimeMultiplier,
    source = entry.source,
    temporary = entry.temporary == true,
    niceName = veh.niceName,
    thumbnail = overhaul_career_garage_inventory.getVehicleThumbnail(inventoryId),
  }
  if entry.offerTimeMultiplier then
    listingData.offerTimeMultiplier = entry.offerTimeMultiplier
  end
  scheduleNextOffer(listingData, timestamp)
  table.insert(listedVehicles, listingData)
  return true
end

local function listVehicles(vehicles, requestId)
  local timestamp = os.time()
  local remaining = 0
  local listedAny = false
  local listedIds = {}

  local function finishAll()
    guihooks.trigger("marketplaceListingsUpdated", listingView.getListings())
    guihooks.trigger("marketplaceListVehiclesFinished", {
      ok = listedAny,
      listedIds = listedIds,
      requestId = requestId,
    })
  end

  if type(vehicles) ~= "table" or #vehicles == 0 then
    finishAll()
    return false
  end

  remaining = #vehicles
  for _, entry in ipairs(vehicles) do
    local inventoryId = entry.inventoryId
    local function finishList()
      if addVehicleListing(entry, timestamp) then
        listedAny = true
        table.insert(listedIds, inventoryId)
      end
      remaining = remaining - 1
      if remaining <= 0 then
        finishAll()
      end
    end
    -- the sync calls finishList itself when it has nothing to pull, so only a live pull waits
    syncSpawnedListingPartConditions(inventoryId, finishList)
  end
  return listedAny
end

local function removeVehicleListing(inventoryId)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId or tostring(listing.id) == tostring(inventoryId) then
      table.remove(listedVehicles, i)
      break
    end
  end
end

local function updateListingValue(inventoryId, value)
  local listing = findVehicleListing(inventoryId)
  if not listing then
    return false
  end
  local rounded = roundListingPrice(value)
  if not rounded then
    return false
  end
  refreshLiveListingValues(listing)
  local marketValue = tonumber(getLiveListingValue(listing)) or tonumber(listing.marketValue) or 0
  listing.value = rounded
  listing.isManualValue = true
  listing.marketRatio = rounded / marketRatioDenominator(marketValue)
  listing.offerTimeMultiplier = offerTimeMultiplierForRatio(listing.marketRatio)
  scheduleNextOffer(listing, os.time())
  guihooks.trigger("marketplaceListingsUpdated", listingView.getListings())
  return true
end

local function addRtListing(businessId, vehicleId, askVal)
  if not businessId or vehicleId == nil then
    return false
  end
  local bid = tonumber(businessId) or businessId
  local vid = tonumber(vehicleId) or vehicleId
  local veh = overhaul_career_business_fleet.getVehicleById(bid, vid)
  if not veh then
    return false
  end
  local listingId = "rt:" .. tostring(bid) .. ":" .. tostring(vid)
  if findVehicleListing(listingId) then
    return false
  end
  local vehicleConfig = veh.vehicleConfig or {}
  local niceName = tostring(vehicleConfig.model_key or "?") .. " " .. tostring(vehicleConfig.key or "")
  local ask = tonumber(askVal) or 10000
  local timestamp = os.time()
  local row = {
    id = listingId,
    rtBiz = bid,
    rtVid = vid,
    timestamp = timestamp,
    offers = {},
    value = ask,
    marketValue = ask,
    marketValueAtListing = ask,
    isManualValue = true,
    marketRatio = 1,
    niceName = niceName,
    thumbnail = "/ui/images/appDefault.png",
    timeOfNextOffer = nil,
    offerTimeMultiplier = 1
  }
  scheduleNextOffer(row, timestamp)
  table.insert(listedVehicles, row)
  if offerMenuOpen then
    guihooks.trigger("marketplaceListingsUpdated", listingView.getListings())
  end
  return true
end

-- Buyer and seller personalities -----------------------------------------------------------------

-- Dealerships use their fixed name list; people get a first name, and very rarely a middle initial or a hyphenated name.
local function personName(chosenArchetype)
  if chosenArchetype.isDealership then
    return chosenArchetype.names[math.random(1, #chosenArchetype.names)]
  end
  local name = M.firstNames[math.random(1, M.firstNameCount)]
  if math.random() < 0.01 then
    if math.random() < 0.5 then
      name = name .. " " .. M.initials[math.random(1, M.initialCount)]
    else
      name = name .. "-" .. M.firstNames[math.random(1, M.firstNameCount)]
    end
  end
  return name .. " " .. M.initials[math.random(1, M.initialCount)] .. "."
end

local function personDelayRange(chosenArchetype)
  local dr = chosenArchetype.delayRange
  if type(dr) == "table" and dr[1] and dr[2] then
    return {min = dr[1], max = dr[2]}
  end
  return {min = 3, max = 4}
end

local function generatePersonality(buyer, _archetypes)
  local map = getCurrentLevelIdentifier()
  if map ~= personalityMap then
    personalityData, personalityRead, personalityMap = nil, false, map
  end
  -- Failed sources are retried; successful local, declared or default data is cached per map.
  if not personalityRead then
    personalityData = personalitySources.load(map)
    if type(personalityData) == 'table' and type(personalityData.archetypes) == 'table' then
      personalityRead = true
    else
      personalityData = nil
      if personalityWarnedMap ~= map then
        personalityWarnedMap = map
        log('W', 'marketplace', 'Negotiation personalities unavailable for ' .. tostring(map))
      end
    end
  end
  local data = personalityData
  if not data then return end

  local archetypeKeys = _archetypes or (buyer and data.randomBuyerArchetypes or data.randomSellerArchetypes)
  if type(archetypeKeys) ~= "table" or #archetypeKeys == 0 then return end

  local chosenKey = archetypeKeys[math.random(1, #archetypeKeys)]
  local chosenArchetype = data.archetypes[chosenKey] or {}

  local name = personName(chosenArchetype)
  local delayRange = personDelayRange(chosenArchetype)

  local priceMultiplier
  if buyer then
    priceMultiplier = 1 - (chosenArchetype.priceMultiplier or 0.1)
  else
    priceMultiplier = 1 + (chosenArchetype.priceMultiplier or 0.1)
  end

  return {
    archetype = chosenKey,
    counterOfferReadiness = chosenArchetype.counterOfferReadiness or 0.5,
    offerAcceptanceThreshold = chosenArchetype.offerAcceptanceThreshold or 0.1,
    unpredictability = chosenArchetype.unpredictability or 0.02,
    priceMultiplier = priceMultiplier,
    delayRange = delayRange,
    name = name,
    quotesByPriceTier = chosenArchetype.quotesByPriceTier,

    -- dealership specific negotiation parameters
    isDealership = chosenArchetype.isDealership,
    minimumOverMarket = chosenArchetype.minimumOverMarket,
    desperation = chosenArchetype.desperation,
    desperationMaxDiscount = chosenArchetype.desperationMaxDiscount,
    insultThresholdBase = chosenArchetype.insultThresholdBase,
    insultThresholdVariance = chosenArchetype.insultThresholdVariance,
    insultQuotes = chosenArchetype.insultQuotes,
    happyQuotes = chosenArchetype.happyQuotes,
    startingPatience = chosenArchetype.startingPatience,
    patienceVariance = chosenArchetype.patienceVariance
  }
end

local function generateOfferId()
  local offerId = 0
  ::continueNewOfferId::
  offerId = math.floor(math.random() * 1000000)
  for _, listing in ipairs(listedVehicles) do
    for _, offer in ipairs(listing.offers) do
      if offer.id == offerId then
        goto continueNewOfferId
      end
    end
  end
  return offerId
end

-- Sale completion --------------------------------------------------------------------------------

-- Keep the advertised offer value until the sale succeeds so a refusal cannot rewrite the listing.
local function completeRacingTeamSale(listing, listingIndex, offerIndex, payout)
  local bank = overhaul_career_economy_bank
  local acct = bank.getBusinessAccount("racingTeam", listing.rtBiz)
  local accountId = acct and (acct.id or acct.accountId)
  if not accountId then
    log("W", "marketplace", "completeAcceptOffer: no business account for racing team " .. tostring(listing.rtBiz))
    return false
  end
  local paid = bank.rewardToAccount({
    money = { amount = payout }
  }, accountId, "Vehicle sale", "Marketplace", require("overhaul/lib/finance/metadata").tag(nil, "sale"))
  if not paid and payout > 0 then
    return false
  end
  table.remove(listing.offers, offerIndex)
  overhaul_career_business_fleet.removeVehicle(listing.rtBiz, listing.rtVid)
  table.remove(listedVehicles, listingIndex)
  return true
end

local function completeInventorySale(listing, inventoryId, offerIndex, payout)
  local marketValue = tonumber(getLiveListingValue(listing)) or tonumber(listing.marketValue) or tonumber(listing.value) or 0
  local soldVehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not overhaul_career_garage_inventory.sellVehicle(inventoryId, payout) then
    return false
  end
  table.remove(listing.offers, offerIndex)
  overhaul_career_garage_inventory.publishVehicleSale(inventoryId, payout, marketValue, soldVehicle)
  return true
end

local function completeAcceptOffer(inventoryId, offerIndex, saleValue)
  for listingIndex, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      local offer = listing.offers[offerIndex]
      if not offer then
        return false
      end
      local payout = tonumber(saleValue)
      if payout == nil then
        payout = tonumber(offer.value) or 0
      end
      if listing.rtBiz then
        return completeRacingTeamSale(listing, listingIndex, offerIndex, payout)
      end
      return completeInventorySale(listing, inventoryId, offerIndex, payout)
    end
  end
  return false
end

local function tryAcceptOfferAfterSync(inventoryId, offerId, saleValue)
  if offerId == nil then return false, "This offer is no longer available." end
  local listing, offerIndex = findOfferById(offerId)
  if not listing or listing.id ~= inventoryId or not offerIndex then
    return false, "This offer is no longer available."
  end
  if not listing.rtBiz and listingDamagedAfterListing(listing, inventoryId) then
    refuseSaleDamagedAfterListing()
    guihooks.trigger("marketplaceListingsUpdated", listingView.getListings())
    return false, "This vehicle was damaged after listing. Repair it before accepting offers."
  end
  local ok = completeAcceptOffer(inventoryId, offerIndex, saleValue)
  guihooks.trigger("marketplaceListingsUpdated", listingView.getListings())
  return ok, not ok and "The sale could not be completed. Please try again." or nil
end

-- Prevents a double accept while a spawned listing sync is still running.
local acceptInFlight = {}

-- A started sync counts as acceptance, although its live damage check may still refuse the sale.
local function acceptOffer(inventoryId, offerIndex, saleValue)
  local listing = findVehicleListing(inventoryId)
  if not listing then return false end
  local offer = listing.offers[offerIndex]
  if not offer then return false end
  if acceptInFlight[inventoryId] then return false end
  local offerId = offer.id
  if listing.rtBiz then
    local ok = completeAcceptOffer(inventoryId, offerIndex, saleValue)
    if ok then
      guihooks.trigger("marketplaceListingsUpdated", listingView.getListings())
    end
    return ok
  end
  acceptInFlight[inventoryId] = true
  local completed = false
  if syncSpawnedListingPartConditions(inventoryId, function()
    completed = tryAcceptOfferAfterSync(inventoryId, offerId, saleValue)
    acceptInFlight[inventoryId] = nil
  end) then
    return true
  end
  acceptInFlight[inventoryId] = nil
  return completed
end

local function deleteOffer(inventoryId, offerIndex)
  for _, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      table.remove(listing.offers, offerIndex)
      return true
    end
  end
  return false
end

-- The phone reorders and expires offer rows; resolve the stable id when the player confirms.
local function acceptOfferById(offerId)
  local listing, offerIndex = findOfferById(offerId)
  if not listing then return false end
  return acceptOffer(listing.id, offerIndex) and true or false
end

local function declineOfferById(offerId)
  local listing, offerIndex = findOfferById(offerId)
  if not listing then return false end
  return deleteOffer(listing.id, offerIndex) and true or false
end

-- Negotiation -------------------------------------------------------------------------------------

-- Created after the sale helpers it borrows; generateOffer below reads it at call time.
local negotiation = negotiationLib.create(M, {
  acceptInFlight = acceptInFlight,
  findOfferById = findOfferById,
  findVehicleListing = findVehicleListing,
  generatePersonality = generatePersonality,
  listingDamagedAfterListing = listingDamagedAfterListing,
  refreshLiveListingValues = refreshLiveListingValues,
  syncSpawnedListingPartConditions = syncSpawnedListingPartConditions,
  tryAcceptOfferAfterSync = tryAcceptOfferAfterSync,
}, config.MIN_RATIO_DENOMINATOR)

-- Offer generation and expiry --------------------------------------------------------------------

local function generateOffer(inventoryId)
  local listing = inventoryId and findVehicleListing(inventoryId) or listedVehicles[math.random(1, #listedVehicles)]
  if not listing then
    return nil
  end
  refreshLiveListingValues(listing)
  local buyerPersonality = generatePersonality(true)
  if not buyerPersonality then
    return nil
  end
  local listingMarketValue = tonumber(getLiveListingValue(listing))
  if not listingMarketValue then
    listingMarketValue = tonumber(listing.marketValue) or 0
  end
  local marketRatio = tonumber(listing.value) / marketRatioDenominator(listingMarketValue)
  local baseOffer = listingMarketValue

  local personalityMult = buyerPersonality.priceMultiplier or 1.0
  local noise = (biasGainFun(math.random(), 0.5, 0.03) * 0.5) + 0.73
  local finalOfferValue = baseOffer * personalityMult * noise

  if marketRatio < 0.9 then
    local cap = listing.value * (1.05 + (math.random() * 0.1))
    finalOfferValue = math.min(finalOfferValue, cap)
  elseif marketRatio > 1.1 then
    local cap = listingMarketValue * (0.95 + (math.random() * 0.1))
    finalOfferValue = math.min(finalOfferValue, cap)
  end

  local offer = {
    id = generateOfferId(),
    timestamp = os.time(),
    value = math.max(50, math.floor((finalOfferValue + 25) / 50) * 50),
    ttl = config.OFFER_TTL + ((math.random() * config.OFFER_TTL_VARIANCE * 2) - config.OFFER_TTL_VARIANCE) * config.OFFER_TTL,
    negotiationPossible = not listing.rtBiz,
    buyerPersonality = buyerPersonality,
    marketValueAtOffer = listingMarketValue,
    -- picked once at generation so the offers inbox shows a stable pitch per buyer
    quote = negotiation.selectQuoteForPersonality(buyerPersonality, listing.value, true),
    archetype = buyerPersonality.archetype
  }
  table.insert(listing.offers, offer)
  return offer
end

local function notifyNewOfferBanner(listing, offerValue)
  local standout = isStandoutOffer(listing, offerValue)
  listing.bestOfferValue = math.max(tonumber(listing.bestOfferValue) or 0, offerValue)

  if detailedOfferBannersShown < config.DETAILED_OFFER_BANNER_LIMIT or standout then
    local delta = offerValue - listing.value
    local deltaSign = delta >= 0 and "+ " or "- "
    local title = standout and detailedOfferBannersShown >= config.DETAILED_OFFER_BANNER_LIMIT and "Strong Offer" or "New Offer"
    fireMarketplacePhoneNotification(
      "marketplace.newOffer",
      title,
      core_locales.translateWithOrWithoutContext(listing.niceName),
      "$" .. string.format("%.2f", offerValue) .. " (" .. deltaSign .. string.format("%.2f", math.abs(delta)) .. "$)",
      "invite",
      { ttl = config.DETAILED_OFFER_TTL }
    )
    if detailedOfferBannersShown < config.DETAILED_OFFER_BANNER_LIMIT then
      detailedOfferBannersShown = detailedOfferBannersShown + 1
    end
    return 1
  end

  local digestSound
  if digestBannerActive then digestSound = false else digestSound = config.PHONE_NOTIF_SOUND end
  fireOfferDigest(digestSound)
  digestBannerActive = true
  return 1
end

-- Retracts up to MAX_RETRACTIONS_PER_LISTING_PASS offers when the market moved far enough; committed offers stay.
local function reviewOffersAgainstMarket(listing, timeNow)
  if listing.rtBiz then
    return 0
  end

  refreshLiveListingValues(listing)
  local currentMarket = tonumber(getLiveListingValue(listing))
  if not currentMarket or currentMarket <= 0 then
    return 0
  end

  local retracted = 0
  for offerIndex = #listing.offers, 1, -1 do
    if retracted >= config.MAX_RETRACTIONS_PER_LISTING_PASS then
      break
    end

    local offer = listing.offers[offerIndex]
    if not negotiation.isOfferProtectedFromRetraction(offer) then
      local offerMarket = tonumber(offer.marketValueAtOffer)
      if not offerMarket or offerMarket <= 0 then
        offer.marketValueAtOffer = currentMarket
      else
        local changeRatio = math.abs(currentMarket - offerMarket) / offerMarket
        if changeRatio >= config.OFFER_MARKET_REVIEW_THRESHOLD then
          if math.random() < config.OFFER_COMMIT_CHANCE then
            offer.committed = true
          else
            table.remove(listing.offers, offerIndex)
            retracted = retracted + 1
            fireMarketplacePhoneNotification(
              "marketplace.offerWithdrawn",
              "Offer withdrawn",
              core_locales.translateWithOrWithoutContext(listing.niceName),
              "A buyer retracted their offer after re-evaluating market value.",
              "info",
              { ttl = config.DETAILED_OFFER_TTL, sound = false }
            )
          end
        end
      end
    end
  end

  return retracted
end

local function removeUnownedListings()
  local offerCountDiff = 0
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  for i = #listedVehicles, 1, -1 do
    local listing = listedVehicles[i]
    if not listing.rtBiz and not vehicles[tonumber(listing.id) or listing.id] and not vehicles[tostring(listing.id)] then
      for _, offer in ipairs(listing.offers or {}) do
        if not offer.expiredViewCounter then offerCountDiff = offerCountDiff - 1 end
      end
      table.remove(listedVehicles, i)
    end
  end
  return offerCountDiff
end

local function updateListingOffers(listing, timeNow)
  local offerCountDiff = 0
  if not listing.timeOfNextOffer then
    scheduleNextOffer(listing, timeNow)
  end

  local retractedCount = reviewOffersAgainstMarket(listing, timeNow)
  offerCountDiff = offerCountDiff - retractedCount
  for _ = 1, retractedCount do
    local replacement = generateOffer(listing.id)
    if replacement then
      offerCountDiff = offerCountDiff + notifyNewOfferBanner(listing, replacement.value)
    end
  end

  if timeNow >= listing.timeOfNextOffer then
    listing.timeOfNextOffer = nil
    local offer = generateOffer(listing.id)
    if offer then
      offerCountDiff = offerCountDiff + notifyNewOfferBanner(listing, offer.value)
    end
  end

  local expiredOffersCount = 0
  for offerIndex = #listing.offers, 1, -1 do
    local offer = listing.offers[offerIndex]
    if not offer.expiredViewCounter and timeNow - offer.timestamp > (offer.ttl or config.OFFER_TTL) then
      offer.expiredViewCounter = 0
      offerCountDiff = offerCountDiff - 1
    end

    if offer.expiredViewCounter then
      expiredOffersCount = expiredOffersCount + 1
      if expiredOffersCount > config.MAXIMUM_EXPIRED_OFFERS then
        table.remove(listing.offers, offerIndex)
      end
    end
  end
  return offerCountDiff
end

local function pushOfferCountChange(offerCountDiff)
  if offerMenuOpen and offerCountDiff ~= 0 then
    guihooks.trigger("marketplaceListingsUpdated", listingView.getListings())
  end
end

-- Offer passes -----------------------------------------------------------------------------------

-- Use the pass-start snapshot and time so spreading work across frames cannot change the offers.
local function stepOfferPass()
  local pass = offerPass
  pass.index = pass.index + 1
  local listing = pass.listings[pass.index]
  pass.listings[pass.index] = nil
  -- Sync driven listings so repair gates reflect the damage the player just caused.
  if listing and not listing.rtBiz then
    syncSpawnedListingPartConditions(listing.id)
  end
  if listing and isListed(listing) then
    pass.diff = pass.diff + updateListingOffers(listing, pass.timeNow)
  end
  if pass.index >= pass.count then
    pass.active = false
    pushOfferCountChange(pass.diff)
  end
end

local function finishOfferPass()
  while offerPass.active do stepOfferPass() end
end

local function startOfferPass()
  finishOfferPass()
  local pass = offerPass
  for i, listing in ipairs(listedVehicles) do pass.listings[i] = listing end
  pass.count, pass.index, pass.active = #listedVehicles, 0, true
  pass.timeNow = os.time()
  pass.diff = removeUnownedListings()
  stepOfferPass()
end

local function generateNewOffers()
  finishOfferPass()
  local timeNow = os.time()
  local offerCountDiff = removeUnownedListings()
  for _, listing in ipairs(listedVehicles) do
    offerCountDiff = offerCountDiff + updateListingOffers(listing, timeNow)
  end
  pushOfferCountChange(offerCountDiff)
  return offerCountDiff
end

-- Listing view -----------------------------------------------------------------------------------

-- Only inventory vehicles have condition data; average their integrity for the condition bar.
local function getListingConditionPercent(veh)
  if type(veh.partConditions) ~= "table" then return nil end
  local total, count = 0, 0
  for _, partCondition in pairs(veh.partConditions) do
    local integrity = type(partCondition) == "table" and tonumber(partCondition.integrityValue) or nil
    if integrity then
      total = total + math.max(0, math.min(1, integrity))
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return math.floor((total / count) * 100 + 0.5)
end

-- Read specs from inventory so listing views follow current wear and repairs.
local function buildListingVehicleData(inventoryId)
  local veh = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not veh then return nil end

  local certifications = veh.certifications
  local power = certifications and tonumber(certifications.power) or nil
  local weight = certifications and tonumber(certifications.weight) or nil
  local torque = certifications and tonumber(certifications.torque) or nil

  return {
    year = veh.year,
    mileage = overhaul_career_market_valueCalculator.getVehicleMileageById(inventoryId),
    power = power and math.floor(power + 0.5) or nil,
    torque = torque and math.floor(torque + 0.5) or nil,
    weight = weight and math.floor(weight + 0.5) or nil,
    powerPerTonne = (power and weight and weight > 0) and math.floor((power / weight) * 1000 + 0.5) or nil,
    condition = getListingConditionPercent(veh),
    FRETimes = deepcopy(veh.FRETimes or {}),
    needsRepair = overhaul_career_repair_insurance.inventoryVehNeedsRepair(inventoryId),
  }
end

-- Offers the buyer may act on: expired ones are greyed and each shows its countdown.
local function decorateOffersForView(listing, timeNow)
  for _, offer in ipairs(listing.offers) do
    if offer.expiredViewCounter then
      offer.disabled = true
      offer.disableReason = _tr("ui.career.vehicleMarketplace.disableReasonOfferExpired")
    end
    -- countdown for the offers inbox; the UI ticks these down locally between refreshes
    local ttl = tonumber(offer.ttl) or config.OFFER_TTL
    offer.ttlTotal = math.floor(ttl)
    offer.secondsLeft = math.max(0, math.floor((tonumber(offer.timestamp) or timeNow) + ttl - timeNow))
    -- archetype quotes are locale keys; the private-seller pool is already plain text
    if offer.quote then
      offer.quote = _tr(offer.quote)
    end
  end
end

-- Newest offers first, with disabled offers moved to the end.
local function orderOffersForView(listing)
  if #listing.offers <= 1 then return end
  local reversed = {}
  for offerIndex = #listing.offers, 1, -1 do
    table.insert(reversed, listing.offers[offerIndex])
  end

  local reordered = {}
  for _, offer in ipairs(reversed) do
    if not offer.disabled then
      table.insert(reordered, offer)
    end
  end
  for _, offer in ipairs(reversed) do
    if offer.disabled then
      table.insert(reordered, offer)
    end
  end
  listing.offers = reordered
end

local function decorateListingForView(listing, timeNow)
  listing.niceName = core_locales.translateWithOrWithoutContext(listing.niceName)
  if not listing.rtBiz then
    listing.vehicleData = buildListingVehicleData(listing.id)
  end
  if listing.rtBiz then
    listing.marketValue = listing.marketValue or listing.value
  else
    local currentValue = overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(listing.id)
    local damagedAfterListing = listingDamagedAfterListing(listing, listing.id)
    listing.damagedAfterListing = damagedAfterListing
    if damagedAfterListing then
      listing.disabled = true
      listing.disableReason = "This vehicle was damaged after listing. Repair it before accepting offers."
    end
    listing.marketValue = currentValue or listing.marketValue
    if not listing.isManualValue and currentValue then
      listing.value = currentValue
    end
  end
  decorateOffersForView(listing, timeNow)
  orderOffersForView(listing)
end

function listingView.getListings()
  for _, listing in ipairs(listedVehicles) do
    refreshLiveListingValues(listing)
  end
  local timeNow = os.time()
  local listingsCopy = deepcopy(listedVehicles)
  for _, listing in ipairs(listingsCopy) do
    decorateListingForView(listing, timeNow)
  end
  return listingsCopy
end

local function updateListings()
  if offerMenuOpen then
    local expiredOffersCount = 0
    for _, listing in ipairs(listedVehicles) do
      for offerIndex = #listing.offers, 1, -1 do
        local offer = listing.offers[offerIndex]
        if offer.expiredViewCounter then
          expiredOffersCount = expiredOffersCount + 1
          offer.expiredViewCounter = offer.expiredViewCounter + 1
          if offer.expiredViewCounter > 1 or expiredOffersCount > config.MAXIMUM_EXPIRED_OFFERS then
            table.remove(listing.offers, offerIndex)
          end
        end
      end
    end
  else
    local offerCountDiff = generateNewOffers()
    if offerCountDiff < 0 then
      for _ = 1, math.abs(offerCountDiff) do
        local offer = generateOffer()
        if offer then
          offer.timestamp = offer.timestamp + math.random(1, config.OFFER_TTL)
        end
      end
    end
  end
end

local function menuOpened(open)
  local newOfferMenuOpen = open or negotiation.isNegotiationActive()
  if newOfferMenuOpen == offerMenuOpen then return end
  offerMenuOpen = newOfferMenuOpen
  if offerMenuOpen then
    resetOfferBannerDigest()
  end
  updateListings()
end

local function openMenu(computerId)
  overhaul_career_market_vehicleShopping.openShop(nil, computerId, "marketplace")
end

-- Lifecycle --------------------------------------------------------------------------------------

local function normalizeLoadedListing(listing, timeNow)
  if listing.rtBiz then
    listing.marketValueAtListing = listing.marketValueAtListing or listing.marketValue or listing.value or 1
  else
    listing.marketValueAtListing = listing.marketValueAtListing or listing.marketValue or overhaul_career_market_valueCalculator.getInventoryVehicleSellValue(listing.id) or 1
  end
  listing.isManualValue = listing.isManualValue == nil and listing.value ~= (listing.marketValueAtListing or listing.marketValue) or listing.isManualValue
  listing.marketValue = listing.marketValueAtListing
  if not listing.bestOfferValue then
    local best = 0
    for _, offer in ipairs(listing.offers or {}) do
      local value = tonumber(offer.value) or 0
      if value > best then
        best = value
      end
    end
    if best > 0 then
      listing.bestOfferValue = best
    end
  end
  if not listing.timeOfNextOffer then
    scheduleNextOffer(listing, timeNow)
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, vehiclesThumbnailUpdate)
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/marketplace.json", {
    listedVehicles = listedVehicles
  }, true)
end

local function onExtensionLoaded()
  if not overhaul_career_career.isActive() then return false end

  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then return end

  local data = jsonReadFile(savePath .. "/career/marketplace.json")
  if not data then return end
  listedVehicles = data.listedVehicles
  local timeNow = os.time()
  for _, listing in ipairs(listedVehicles) do
    normalizeLoadedListing(listing, timeNow)
  end
end

-- Offers that arrived while the phone app was not installed are announced once it is.
local function notifyOnPhoneAppInstalled()
  if not overhaul_career_career.isActive() then
    return
  end
  local pendingCount = countPendingOffers()
  if pendingCount <= 0 then
    return
  end
  fireOfferDigest(nil)
end

-- Public API -------------------------------------------------------------------------------------

M.getListings = listingView.getListings
M.menuOpened = menuOpened
M.acceptOffer = acceptOffer
M.acceptOfferById = acceptOfferById
M.declineOfferById = declineOfferById
M.declineOffer = deleteOffer
M.listVehicles = listVehicles
M.findVehicleListing = findVehicleListing
M.openMenu = openMenu
M.removeVehicleListing = removeVehicleListing
M.updateListingValue = updateListingValue
M.addRtListing = addRtListing
M.generateOffer = generateOffer

M.generatePersonality = generatePersonality
M.startNegotiateBuyingOffer = negotiation.startNegotiateBuyingOffer
M.startNegotiateBuyingOfferById = negotiation.startNegotiateBuyingOfferById
M.startNegotiateSellingOffer = negotiation.startNegotiateSellingOffer
M.startCarMeetBuyingOffer = negotiation.startCarMeetBuyingOffer
M.getNegotiationState = negotiation.getNegotiationState
M.makeNegotiationOffer = negotiation.makeNegotiationOffer
M.takeTheirOffer = negotiation.takeTheirOffer
M.cancelNegotiation = negotiation.cancelNegotiation
M.finalizeNegotiationExit = negotiation.finalizeNegotiationExit
M.dismissNegotiation = negotiation.dismissNegotiation
M.setPhoneMarketplaceUiOpen = negotiation.setPhoneMarketplaceUiOpen
M.finishPhonePurchase = negotiation.finishPhonePurchase
M.routeToListing = negotiation.routeToListing
M.goToListing = negotiation.goToListing

M.notifyOnPhoneAppInstalled = notifyOnPhoneAppInstalled

-- Inventory negotiation contract ------------------------------------------------------------------

function M.getVehicleNegotiationService()
  return {
    generatePersonality = M.generatePersonality,
    startBuyingOffer = M.startCarMeetBuyingOffer,
    startSellingOffer = M.startNegotiateSellingOffer,
  }
end

-- Game hooks -------------------------------------------------------------------------------------

local function onOverhaulVehicleRemoved(inventoryId)
  removeVehicleListing(inventoryId)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if offerPass.active then
    stepOfferPass()
  end
  if tableIsEmpty(listedVehicles) then
    return
  end

  timeSinceUpdate = timeSinceUpdate + dtSim
  if timeSinceUpdate < 10 then return end
  timeSinceUpdate = 0
  startOfferPass()
end

M.onUpdate = onUpdate
M.onOverhaulVehicleRemoved = onOverhaulVehicleRemoved
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded

return M
