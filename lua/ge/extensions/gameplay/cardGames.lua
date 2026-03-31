local M = {}

local loadedExtensions = {}
local activeGameId = nil
local activeMode = nil

local MIN_BET = 50
local MAX_BET = 1000
local RESHUFFLE_THRESHOLD = 0.5

local RANKS = {"A","2","3","4","5","6","7","8","9","10","J","Q","K"}
local SUITS = {"spades","hearts","clubs","diamonds"}
local FULL_DECK_SIZE = #RANKS * #SUITS

local shoe = {}
local shoeSize = FULL_DECK_SIZE
local session

local function buildShoe()
  shoe = {}
  for _, suit in ipairs(SUITS) do
    for _, rank in ipairs(RANKS) do
      table.insert(shoe, {rank = rank, suit = suit})
    end
  end
  shoeSize = #shoe
end

local function shuffleShoe()
  for i = #shoe, 2, -1 do
    local j = math.random(1, i)
    shoe[i], shoe[j] = shoe[j], shoe[i]
  end
end

local function rebuildAndShuffleShoe()
  buildShoe()
  shuffleShoe()
  session.shuffleCounter = (session.shuffleCounter or 0) + 1
end

local function needsReshuffle()
  return #shoe < math.floor(shoeSize * RESHUFFLE_THRESHOLD)
end

local function ensureShoe()
  if #shoe == 0 or needsReshuffle() then
    rebuildAndShuffleShoe()
  end
end

local function draw()
  if #shoe == 0 then
    rebuildAndShuffleShoe()
  end
  return table.remove(shoe)
end

session = {
  bet = 100,
  phase = "idle",
  shuffleCounter = 0,
}

local modeRegistry = {}

local function loadExtensions()
  local basePath = "/lua/ge/extensions/gameplay/cardGamesModes/"
  local files = FS:findFiles(basePath, "*.lua", -1, true, false)
  if files then
    for _, filePath in ipairs(files) do
      local filename = string.match(filePath, "([^/]+)%.lua$")
      if filename then
        local extensionName = "gameplay_cardGamesModes_" .. filename
        setExtensionUnloadMode(extensionName, "manual")
        extensions.unload(extensionName)
        table.insert(loadedExtensions, extensionName)
      end
    end
  end
  loadManualUnloadExtensions()
end

local function unloadExtensions()
  for _, extensionName in ipairs(loadedExtensions) do
    extensions.unload(extensionName)
  end
  loadedExtensions = {}
end

local function pushState()
  local modeState = {}
  if activeMode and activeMode.getState then
    modeState = activeMode.getState()
  end

  local state = {
    gameId = activeGameId,
    phase = session.phase,
    bet = session.bet,
    shuffleCounter = session.shuffleCounter,
    mode = modeState,
  }
  guihooks.trigger("cardGamesState", state)
end

local function register(gameId, api)
  modeRegistry[gameId] = api
end

local function open(gameId)
  local api = modeRegistry[gameId]
  if not api then
    log("E", "cardGames", "Unknown game: " .. tostring(gameId))
    return
  end
  activeGameId = gameId
  activeMode = api
  session.phase = "betting"
  session.bet = 100
  if activeMode.reset then activeMode.reset() end
  pushState()
end

local function close()
  if activeMode and activeMode.reset then activeMode.reset() end
  activeGameId = nil
  activeMode = nil
  session.phase = "idle"
  pushState()
end

local function setBet(amount)
  if session.phase ~= "betting" then return end
  amount = math.floor(tonumber(amount) or session.bet)
  amount = math.max(MIN_BET, math.min(MAX_BET, amount))
  session.bet = amount
  pushState()
end

local function confirmBet()
  if session.phase ~= "betting" then return end
  if not activeMode then return end
  ensureShoe()
  session.phase = "playing"
  if activeMode.deal then activeMode.deal(session.bet) end
  pushState()
end

local function action(name, payload)
  if not activeMode then return end
  if activeMode.onAction then
    activeMode.onAction(name, payload)
  end
  pushState()
end

local function newRound()
  if not activeMode then return end
  session.phase = "betting"
  if activeMode.reset then activeMode.reset() end
  pushState()
end

local function requestSync()
  pushState()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if activeMode and activeMode.onUpdate then
    activeMode.onUpdate(dtReal, dtSim, dtRaw)
  end
end

local function onExtensionLoaded()
  loadExtensions()
end

local function onExtensionUnloaded()
  close()
  unloadExtensions()
end

M.draw = draw
M.ensureShoe = ensureShoe
M.getShoeCount = function() return #shoe end
M.getSessionBet = function() return session.bet end
M.register = register
M.open = open
M.close = close
M.setBet = setBet
M.confirmBet = confirmBet
M.action = action
M.newRound = newRound
M.requestSync = requestSync
M.pushState = pushState
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
