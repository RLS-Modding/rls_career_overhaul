<template>
  <div class="card-games" ref="rootRef">
    <div class="svg-layer" ref="svgRef" />

    <div class="card-overlay" v-if="svgReady">
      <PlayingCard
        v-if="showDeckCard"
        rank="A"
        suit="spades"
        :face-up="false"
        :theme="cardTheme"
        class="table-card"
        :style="deckCardStyle"
      />

      <!-- Blackjack cards -->
      <template v-if="state.gameId === 'blackjack' && state.mode">
        <PlayingCard
          v-for="(card, i) in state.mode.playerCards"
          :key="'p' + i"
          :rank="card.rank"
          :suit="card.suit"
          :face-up="card.faceUp"
          :theme="cardTheme"
          class="table-card"
          :style="playerCardStyle(i)"
        />
        <PlayingCard
          v-for="(card, i) in state.mode.dealerCards"
          :key="'d' + i"
          :rank="card.rank"
          :suit="card.suit"
          :face-up="card.faceUp"
          :theme="cardTheme"
          class="table-card"
          :style="dealerCardStyle(i)"
        />
      </template>

      <!-- Ride the Bus cards -->
      <template v-if="state.gameId === 'rideTheBus' && state.mode">
        <PlayingCard
          v-for="(card, i) in state.mode.cards"
          :key="'r' + i"
          :rank="card.rank"
          :suit="card.suit"
          :face-up="card.faceUp"
          :theme="cardTheme"
          class="table-card"
          :style="rtbCardStyle(i)"
        />
      </template>
    </div>

    <!-- Blackjack controls -->
    <div v-if="state.gameId === 'blackjack' && state.mode && state.mode.phase === 'player_turn'" class="game-controls bj-controls">
      <button class="game-btn" @click="doAction('hit')">Hit</button>
      <button class="game-btn" @click="doAction('stand')">Stand</button>
    </div>

    <!-- Blackjack result -->
    <div v-if="state.gameId === 'blackjack' && state.mode && state.mode.phase === 'resolved'" class="game-controls bj-result">
      <div class="bj-result-modal">
        <div class="result-text bj-result-text">{{ bjResultLabel }}</div>
        <div class="bj-result-actions">
          <button class="game-btn" @click="newRound">New Round</button>
          <button class="game-btn" @click="switchGames">Switch Games</button>
          <button class="game-btn" @click="leaveTable">Leave Table</button>
        </div>
      </div>
    </div>

    <!-- Ride the Bus controls -->
    <div v-if="state.gameId === 'rideTheBus' && state.mode && state.mode.phase === 'choosing'" class="game-controls rtb-controls">
      <div class="choice-label">{{ state.mode.choiceLabel }}</div>
      <div class="choice-timer" v-if="timerDisplay !== null">{{ timerDisplay }}s</div>
      <div class="choice-buttons">
        <template v-if="state.mode.choiceKind === 'redblack'">
          <button class="game-btn" @click="doAction('choose', 'red')">Red</button>
          <button class="game-btn" @click="doAction('choose', 'black')">Black</button>
        </template>
        <template v-else-if="state.mode.choiceKind === 'highlow'">
          <button class="game-btn" @click="doAction('choose', 'higher')">Higher</button>
          <button class="game-btn" @click="doAction('choose', 'lower')">Lower</button>
        </template>
        <template v-else-if="state.mode.choiceKind === 'inout'">
          <button class="game-btn" @click="doAction('choose', 'inside')">Inside</button>
          <button class="game-btn" @click="doAction('choose', 'outside')">Outside</button>
        </template>
        <template v-else-if="state.mode.choiceKind === 'suit'">
          <button class="game-btn" @click="doAction('choose', 'spades')">Spades</button>
          <button class="game-btn" @click="doAction('choose', 'hearts')">Hearts</button>
          <button class="game-btn" @click="doAction('choose', 'clubs')">Clubs</button>
          <button class="game-btn" @click="doAction('choose', 'diamonds')">Diamonds</button>
        </template>
      </div>
      <button class="game-btn end-btn" @click="doAction('endGame')">{{ rtbForfeitLabel }}</button>
    </div>

    <!-- RTB result -->
    <div v-if="state.gameId === 'rideTheBus' && state.mode && state.mode.phase === 'resolved'" class="game-controls rtb-result">
      <div class="bj-result-modal">
        <div class="result-text bj-result-text">{{ rtbResultLabel }}</div>
        <div class="rtb-result-amount">{{ rtbResultAmountLabel }}</div>
        <div class="bj-result-actions">
          <button class="game-btn" @click="newRound">Play Again</button>
          <button class="game-btn" @click="switchGames">Switch Games</button>
          <button class="game-btn" @click="leaveTable">{{ rtbExitLabel }}</button>
        </div>
      </div>
    </div>

    <!-- Betting UI -->
    <div v-if="state.phase === 'betting'" class="betting-overlay">
      <div class="betting-panel">
        <div class="bet-title">Place Your Bet</div>
        <div class="bet-controls">
          <button class="bet-btn" @click="adjustBet(-100)">-100</button>
          <input
            type="text"
            inputmode="numeric"
            class="bet-input"
            v-model="betInput"
            @input="onBetInput"
            @focus="onBetInputFocus"
            @blur="commitBetInput"
            @keydown.enter.prevent="commitBetInput"
          />
          <button class="bet-btn" @click="adjustBet(100)">+100</button>
          <button class="bet-btn" @click="doubleBet">x2</button>
        </div>
        <button class="game-btn deal-btn" @click="confirmBet">Deal</button>
      </div>
    </div>

    <!-- Game selector when idle -->
    <div v-if="state.phase === 'idle' && !state.gameId" class="game-selector">
      <div class="selector-buttons">
        <button class="game-btn" @click="openGame('blackjack')">Blackjack</button>
        <button class="game-btn" @click="openGame('rideTheBus')">Ride the Bus</button>
      </div>
      <button class="game-btn leave-table-btn" @click="leaveTable">Leave Table</button>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, reactive } from "vue"
import { useRouter } from "vue-router"
import { lua, useBridge } from "@/bridge"
import PlayingCard from "../components/playingCards/PlayingCard.vue"

const SVG_URL = "/ui/entrypoints/main/cardGames.svg"
const SVG_VIEWBOX = { w: 3600, h: 2400 }

const CARD_W = 473.005
const CARD_H = 661.017
const CARD_GAP = 120

const PLAYER_ANCHOR = { x: 1589.629, y: 1555.031 }
const DEALER_ANCHOR = { x: 1382.888, y: 182.865 }
const DECK_ANCHOR = { x: 3043.246, y: 95.333 }

const RTB_SLOTS = [
  { x: 555.01, y: 1300.609 },
  { x: 1219.666, y: 1300.609 },
  { x: 1891.41, y: 1300.609 },
  { x: 2570.241, y: 1300.609 },
]

const BJ_RESULTS = {
  blackjack: "Blackjack!",
  win: "You Win!",
  lose: "Dealer Wins",
  bust: "Bust!",
  dealer_bust: "Dealer Busts!",
  push: "Push",
}

const RTB_RESULTS = {
  win: "You Rode the Bus!",
  lose: "Wrong Guess!",
  timeout: "Time's Up!",
  forfeit: "Cashed Out",
}

const router = useRouter()
const { events } = useBridge()
const rootRef = ref(null)
const svgRef = ref(null)
const svgReady = ref(false)
const cardTheme = "light"
const lastTableGameId = ref(null)
const liveTimerRemaining = ref(null)
const betInput = ref("100")
const betInputFocused = ref(false)
let timerInterval = null

const state = reactive({
  gameId: null,
  phase: "idle",
  bet: 100,
  mode: null,
})

const PLACEHOLDER_IDS = [
  "Card1", "Card2", "Dealer1", "Dealer-Down",
  "Round-1", "Round-2", "Round-3", "Round-4",
  "Deck", "Outline",
]

function hidePlaceholders() {
  if (!svgRef.value) return
  for (const id of PLACEHOLDER_IDS) {
    const el = svgRef.value.querySelector(`#${CSS.escape(id)}`)
    if (!el) continue
    el.style.visibility = "hidden"
    el.style.pointerEvents = "none"
  }
}

function applyGameSvgVisibility() {
  if (!svgRef.value) return
  const root = svgRef.value.querySelector("svg") || svgRef.value
  const bj = root.querySelector("#BlackJack")
  const rtb = root.querySelector(`#${CSS.escape("Ride-the-Bus")}`)
  const deck = root.querySelector("#Deck")

  const cleanPicker =
    state.phase === "idle" && !state.gameId && !lastTableGameId.value

  if (cleanPicker) {
    if (bj) bj.style.display = "none"
    if (rtb) rtb.style.display = "none"
    if (deck) deck.style.display = "none"
    return
  }

  const tableId = state.gameId || lastTableGameId.value
  if (tableId === "blackjack") {
    if (bj) bj.style.display = ""
    if (rtb) rtb.style.display = "none"
    if (deck) deck.style.display = "none"
  } else if (tableId === "rideTheBus") {
    if (bj) bj.style.display = "none"
    if (rtb) rtb.style.display = ""
    if (deck) deck.style.display = "none"
  } else {
    if (bj) bj.style.display = "none"
    if (rtb) rtb.style.display = "none"
    if (deck) deck.style.display = "none"
  }
}

function scaleFactors() {
  if (!rootRef.value) return { sx: 1, sy: 1 }
  const rect = rootRef.value.getBoundingClientRect()
  return { sx: rect.width / SVG_VIEWBOX.w, sy: rect.height / SVG_VIEWBOX.h }
}

function cardStyle(vbX, vbY) {
  const { sx, sy } = scaleFactors()
  return {
    position: "absolute",
    left: `${vbX * sx}px`,
    top: `${vbY * sy}px`,
    width: `${CARD_W * sx}px`,
    height: `${CARD_H * sy}px`,
  }
}

function cardStyleFromSvgId(id, fallbackX, fallbackY) {
  if (!svgRef.value || !rootRef.value) {
    return cardStyle(fallbackX, fallbackY)
  }

  const el = svgRef.value.querySelector(`#${CSS.escape(id)}`)
  if (!el) {
    return cardStyle(fallbackX, fallbackY)
  }

  const rootRect = rootRef.value.getBoundingClientRect()
  const rect = el.getBoundingClientRect()
  if (!rect.width || !rect.height) {
    return cardStyle(fallbackX, fallbackY)
  }

  return {
    position: "absolute",
    left: `${rect.left - rootRect.left}px`,
    top: `${rect.top - rootRect.top}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
  }
}

function playerCardStyle(index) {
  const x = PLAYER_ANCHOR.x + index * CARD_GAP
  return cardStyle(x, PLAYER_ANCHOR.y)
}

function dealerCardStyle(index) {
  const x = DEALER_ANCHOR.x + index * CARD_W
  return cardStyle(x, DEALER_ANCHOR.y)
}

function rtbCardStyle(index) {
  const slot = RTB_SLOTS[index] || RTB_SLOTS[RTB_SLOTS.length - 1]
  return cardStyleFromSvgId(`Round-${index + 1}`, slot.x, slot.y)
}

const bjResultLabel = computed(() => {
  if (!state.mode) return ""
  return BJ_RESULTS[state.mode.result] || state.mode.result || ""
})

const rtbResultLabel = computed(() => {
  if (!state.mode) return ""
  return RTB_RESULTS[state.mode.result] || state.mode.result || ""
})

const rtbResultAmountLabel = computed(() => {
  const amount = state.mode?.collectAmount || 0
  if (state.mode?.result === "forfeit") {
    return `Collected $${amount}`
  }
  return `Won $${amount}`
})

const timerDisplay = computed(() => {
  if (liveTimerRemaining.value == null) return null
  return Math.ceil(liveTimerRemaining.value)
})

const rtbForfeitLabel = computed(() => {
  const amount = state.mode?.collectAmount || 0
  return `Forfeit and Collect $${amount}`
})

const rtbExitLabel = computed(() => {
  return "Leave Table"
})

const showDeckCard = computed(() => {
  return (
    state.gameId === "blackjack" ||
    state.gameId === "rideTheBus" ||
    (!state.gameId && (lastTableGameId.value === "blackjack" || lastTableGameId.value === "rideTheBus"))
  )
})

const deckCardStyle = computed(() => cardStyle(DECK_ANCHOR.x, DECK_ANCHOR.y))

function updateSvgHandValue() {
  if (!svgRef.value) return
  const root = svgRef.value.querySelector("svg") || svgRef.value
  const labelGroup =
    root.querySelector(`#${CSS.escape("Card-Value")}`) ||
    root.querySelector(`#${CSS.escape("Card Value")}`)

  if (!labelGroup) return

  const textEl =
    labelGroup.nextElementSibling?.tagName?.toLowerCase() === "text"
      ? labelGroup.nextElementSibling
      : null
  if (!textEl) return

  const value = state.gameId === "blackjack" ? state.mode?.playerHandValue : null
  textEl.textContent = value || ""
  textEl.style.display = value ? "" : "none"
}

function syncTimerFromState() {
  if (timerInterval) {
    clearInterval(timerInterval)
    timerInterval = null
  }

  const remaining = state.mode?.timerRemaining
  if (remaining == null) {
    liveTimerRemaining.value = null
    return
  }

  const startedAt = Date.now()
  liveTimerRemaining.value = remaining
  timerInterval = window.setInterval(() => {
    const elapsed = (Date.now() - startedAt) / 1000
    const next = Math.max(0, remaining - elapsed)
    liveTimerRemaining.value = next
    if (next <= 0) {
      clearInterval(timerInterval)
      timerInterval = null
    }
  }, 100)
}

function handleState(data) {
  const prevGameId = state.gameId
  state.gameId = data.gameId
  state.phase = data.phase
  state.bet = data.bet
  state.mode = data.mode
  if (!betInputFocused.value) {
    betInput.value = String(data.bet ?? 100)
  }

  if (data.phase === "idle" && !data.gameId && prevGameId) {
    lastTableGameId.value = prevGameId
  } else if (data.gameId) {
    lastTableGameId.value = data.gameId
  }

  applyGameSvgVisibility()
  updateSvgHandValue()
  syncTimerFromState()
}

function openGame(gameId) {
  lua.gameplay_cardGames.open(gameId)
}

function closeGame() {
  lua.gameplay_cardGames.close()
}

function switchGames() {
  closeGame()
}

function leaveTable() {
  lua.gameplay_cardGames.close()
  if (window.history.length > 1) {
    router.back()
    return
  }
  lua.career_career.closeAllMenus()
}

function doAction(name, payload) {
  lua.gameplay_cardGames.action(name, payload || "")
}

function newRound() {
  lua.gameplay_cardGames.newRound()
}

function adjustBet(delta) {
  const clamped = Math.max(50, Math.min(1000, (state.bet || 100) + delta))
  lua.gameplay_cardGames.setBet(clamped)
}

function doubleBet() {
  const clamped = Math.min(1000, (state.bet || 100) * 2)
  lua.gameplay_cardGames.setBet(clamped)
}

function onBetInput() {
  const digitsOnly = betInput.value.replace(/[^\d]/g, "")
  betInput.value = digitsOnly
}

function onBetInputFocus() {
  betInputFocused.value = true
}

function commitBetInput() {
  betInputFocused.value = false
  const val = parseInt(betInput.value, 10)
  if (isNaN(val)) {
    betInput.value = String(state.bet || 100)
    return
  }

  const clamped = Math.max(50, Math.min(1000, val))
  betInput.value = String(clamped)
  lua.gameplay_cardGames.setBet(clamped)
}

function confirmBet() {
  lua.gameplay_cardGames.confirmBet()
}

onMounted(async () => {
  events.on("cardGamesState", handleState)

  try {
    const resp = await fetch(SVG_URL)
    const text = await resp.text()
    if (svgRef.value) {
      svgRef.value.innerHTML = text
      const bgImageEl = svgRef.value.querySelector("#_Image2")
      const bgHref =
        bgImageEl?.getAttribute("href") ||
        bgImageEl?.getAttributeNS("http://www.w3.org/1999/xlink", "href") ||
        bgImageEl?.getAttribute("xlink:href")

      if (rootRef.value && bgHref) {
        rootRef.value.style.setProperty("--felt-bg-image", `url("${bgHref}")`)
      }

      hidePlaceholders()
      applyGameSvgVisibility()
      updateSvgHandValue()
      svgReady.value = true
    }
  } catch (err) {
    console.error("Failed to load cardGames SVG", err)
  }

  lua.gameplay_cardGames.requestSync()
})

onUnmounted(() => {
  if (timerInterval) {
    clearInterval(timerInterval)
    timerInterval = null
  }
  events.off("cardGamesState", handleState)
})
</script>

<style scoped lang="scss">
.card-games {
  position: fixed;
  inset: 0;
  width: 100%;
  height: 100%;
  background:
    var(--felt-bg-image, none) center center / cover no-repeat,
    radial-gradient(ellipse at center, rgba(46, 142, 74, 0.5) 0%, rgba(46, 142, 74, 0) 42%),
    linear-gradient(90deg, #0c5a2d 0%, #11753a 18%, #168548 50%, #11753a 82%, #0c5a2d 100%);
  overflow: hidden;
}

.svg-layer {
  width: 100%;
  height: 100%;
  :deep(svg) {
    width: 100%;
    height: 100%;
    display: block;
  }
}

.card-overlay {
  position: absolute;
  inset: 0;
  pointer-events: none;
}

.table-card {
  pointer-events: none;
  transition: left 0.3s ease, top 0.3s ease;
}

.hand-value-label {
  text-shadow: 0 2px 8px rgba(0,0,0,0.7);
}

.game-controls {
  position: absolute;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.75rem;
  z-index: 10;
}

.bj-controls {
  bottom: 4%;
  left: 50%;
  transform: translateX(-50%);
  flex-direction: row;
}

.bj-result {
  inset: 0;
  justify-content: center;
}

.bj-result-modal {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 1rem;
  min-width: 24rem;
  padding: 1.5rem 2rem;
  background: rgba(20, 20, 40, 0.92);
  border: 1px solid rgba(239, 198, 109, 0.35);
  border-radius: 12px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
}

.bj-result-text {
  font-size: 2rem;
}

.bj-result-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 0.75rem;
}

.rtb-controls {
  bottom: 4%;
  left: 50%;
  transform: translateX(-50%);
}

.rtb-result {
  inset: 0;
  justify-content: center;
}

.choice-label {
  font-size: 1.2rem;
  color: #efc66d;
  font-weight: bold;
  text-align: center;
}

.choice-timer {
  font-size: 2rem;
  color: #ff6b6b;
  font-weight: bold;
  text-align: center;
}

.choice-buttons {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
  justify-content: center;
}

.result-text {
  font-size: 1.6rem;
  color: #efc66d;
  font-weight: bold;
  text-shadow: 0 2px 8px rgba(0,0,0,0.7);
}

.rtb-result-amount {
  font-size: 1.1rem;
  color: #fff;
  text-align: center;
}

.game-btn {
  padding: 0.6rem 1.5rem;
  border: 1px solid #7f6825;
  border-radius: 6px;
  background: #4f6b2d;
  color: #efc66d;
  font-size: 1rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s, border-color 0.15s;

  &:hover {
    background: #617f38;
    border-color: #efc66d;
  }
}

.end-btn {
  margin-top: 0.5rem;
  color: #fff;
  border-color: #24548c;
  background: #2f6eb5;

  &:hover {
    background: #3b82d1;
    border-color: #4b97ea;
  }
}

.betting-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.6);
  z-index: 20;
}

.betting-panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 1.2rem;
  padding: 2rem 3rem;
  background: rgba(20, 20, 40, 0.95);
  border: 1px solid rgba(239, 198, 109, 0.3);
  border-radius: 12px;
}

.bet-title {
  font-size: 1.4rem;
  color: #efc66d;
  font-weight: bold;
}

.bet-controls {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.bet-btn {
  padding: 0.5rem 1rem;
  border: 1px solid #7f6825;
  border-radius: 4px;
  background: #4f6b2d;
  color: #efc66d;
  font-size: 0.95rem;
  cursor: pointer;
  transition: background 0.15s;

  &:hover {
    background: #617f38;
  }
}

.bet-input {
  width: 100px;
  padding: 0.5rem;
  border: 1px solid rgba(239, 198, 109, 0.4);
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.5);
  color: #efc66d;
  font-size: 1.1rem;
  text-align: center;
  -moz-appearance: textfield;

  &::-webkit-inner-spin-button,
  &::-webkit-outer-spin-button {
    -webkit-appearance: none;
  }
}

.deal-btn {
  font-size: 1.1rem;
  padding: 0.7rem 2.5rem;
}

.game-selector {
  position: absolute;
  top: 70%;
  left: 50%;
  transform: translate(-50%, -50%);
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 1rem;
  z-index: 20;
}

.selector-buttons {
  display: flex;
  gap: 2rem;
}

.leave-table-btn {
  min-width: 12rem;
}
</style>
