<template>
  <!-- Controller (no scope on this screen): every control block that appears puts focus on its main
       button; B steps back one level (bet -> cancel, result -> game list, game list -> leave table) and
       does nothing mid-hand -->
  <div class="card-games" ref="rootRef" v-bng-on-ui-nav:back.focusRequired="onBack">
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
          :class="['table-card', { 'table-card--dealing': isCardDealing(`bj-p-${i}`) }]"
          :style="animatedCardStyle(`bj-p-${i}`, playerCardStyle(i))"
        />
        <PlayingCard
          v-for="(card, i) in state.mode.dealerCards"
          :key="'d' + i"
          :rank="card.rank"
          :suit="card.suit"
          :face-up="card.faceUp"
          :theme="cardTheme"
          :class="['table-card', { 'table-card--dealing': isCardDealing(`bj-d-${i}`) }]"
          :style="animatedCardStyle(`bj-d-${i}`, dealerCardStyle(i))"
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
          :class="['table-card', { 'table-card--dealing': isCardDealing(`rtb-${i}`) }]"
          :style="animatedCardStyle(`rtb-${i}`, rtbCardStyle(i))"
        />
      </template>
    </div>

    <!-- Blackjack controls -->
    <div v-if="state.gameId === 'blackjack' && state.mode && state.mode.phase === 'player_turn'" class="game-controls bj-controls">
      <button class="game-btn game-btn--primary" @click="doAction('hit')">Hit</button>
      <button class="game-btn" @click="doAction('stand')">Stand</button>
    </div>

    <!-- Blackjack result -->
    <div v-if="state.gameId === 'blackjack' && state.mode && state.mode.phase === 'resolved'" class="game-controls bj-result">
      <div class="bj-result-modal">
        <div class="result-text bj-result-text">{{ bjResultLabel }}</div>
        <div v-if="bjPayoutLabel" class="rtb-result-amount">{{ bjPayoutLabel.pre }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ bjPayoutLabel.amount }}{{ bjPayoutLabel.post }}</div>
        <div class="bj-result-actions">
          <button class="game-btn game-btn--primary" @click="newRound">New Round</button>
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
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'red')">Red</button>
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'black')">Black</button>
        </template>
        <template v-else-if="state.mode.choiceKind === 'highlow'">
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'higher')">Higher</button>
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'lower')">Lower</button>
        </template>
        <template v-else-if="state.mode.choiceKind === 'inout'">
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'inside')">Inside</button>
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'outside')">Outside</button>
        </template>
        <template v-else-if="state.mode.choiceKind === 'suit'">
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'spades')">Spades</button>
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'hearts')">Hearts</button>
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'clubs')">Clubs</button>
          <button class="game-btn game-btn--primary" @click="doAction('choose', 'diamonds')">Diamonds</button>
        </template>
      </div>
      <button class="game-btn end-btn" @click="doAction('endGame')">Forfeit and Collect <BngIcon class="cur" :type="icons.beamCurrency" />{{ rtbForfeitAmount }}</button>
    </div>

    <!-- RTB result -->
    <div v-if="state.gameId === 'rideTheBus' && state.mode && state.mode.phase === 'resolved'" class="game-controls rtb-result">
      <div class="bj-result-modal">
        <div class="result-text bj-result-text">{{ rtbResultLabel }}</div>
        <div v-if="rtbResultAmountLabel" class="rtb-result-amount">You won <BngIcon class="cur" :type="icons.beamCurrency" />{{ rtbResultAmountLabel }}!</div>
        <div class="bj-result-actions">
          <button class="game-btn game-btn--primary" @click="newRound">Play Again</button>
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
          <!-- typing only: a pad sets the bet with -100 / +100 / x2, so the d-pad skips the field -->
          <input
            type="text"
            inputmode="numeric"
            class="bet-input"
            bng-no-nav="true"
            v-model="betInput"
            @input="onBetInput"
            @focus="onBetInputFocus"
            @blur="commitBetInput"
            @keydown.enter.prevent="commitBetInput"
          />
          <button class="bet-btn" @click="adjustBet(100)">+100</button>
          <button class="bet-btn" @click="doubleBet">x2</button>
        </div>
        <div v-if="state.careerActive" class="bet-cap-hint">
          Max bet: <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(effectiveMaxBet) }}
        </div>
        <div v-if="state.careerActive && state.betError === 'insufficientFunds'" class="bet-error-hint">
          Not enough balance for this bet.
        </div>
        <div class="betting-actions">
          <button type="button" class="game-btn betting-cancel-btn" @click="closeGame">Cancel</button>
          <button
            type="button"
            class="game-btn game-btn--primary deal-btn"
            :disabled="!canConfirmBet"
            :bng-no-nav="!canConfirmBet ? 'true' : null"
            @click="confirmBet"
          >
            Deal
          </button>
        </div>
      </div>
    </div>

    <div
      v-if="state.careerActive && state.balance != null"
      class="card-games-balance"
    >
      Balance <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(state.balance) }}
    </div>

    <!-- Game selector when idle -->
    <div v-if="state.phase === 'idle' && !state.gameId" class="game-selector">
      <div class="selector-buttons">
        <button class="game-btn game-btn--primary" @click="openGame('blackjack')">Blackjack</button>
        <button class="game-btn game-btn--primary" @click="openGame('rideTheBus')">Ride the Bus</button>
      </div>
      <button class="game-btn leave-table-btn" @click="leaveTable">Leave Table</button>
    </div>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { ref, computed, onMounted, onUnmounted, reactive, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { useCefTyping } from "../composables/useCefTyping"
import PlayingCard from "../components/playingCards/PlayingCard.vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngOnUiNav } from "@/common/directives"
import { refocusIfLost } from "../composables/useScreenEntryFocus"

const SVG_URL = "/ui/entrypoints/main/rls_career_overhaul/cardGames.svg"
const SVG_VIEWBOX = { w: 3600, h: 2400 }
const CARD_SOUNDS_BASE = "/ui/entrypoints/main/rls_career_overhaul/cardSounds"
const DEAL_SOUND_URL = `${CARD_SOUNDS_BASE}/Deal.mp3`
const SHUFFLE_SOUND_URL = `${CARD_SOUNDS_BASE}/Shuffle.mp3`
const HIT_SOUND_URL = `${CARD_SOUNDS_BASE}/Hit.mp3`
const PLACE_SOUND_URL = `${CARD_SOUNDS_BASE}/Place.mp3`
const SHUFFLE_SOUND_VOLUME = 0.22
const DEAL_SOUND_VOLUME = 0.22
const HIT_SOUND_VOLUME = 0.22
const PLACE_SOUND_VOLUME = 0.16
const SHUFFLE_DELAY_MS = 1150
const HIT_SOUND_LEAD_MS = 140
const DEAL_ANIMATION_MS = 460
const DEAL_STAGGER_MS = 500
const PLACE_SOUND_LEAD_MS = 70

const CARD_W = 473.005
const CARD_H = 661.017
const CARD_GAP = 120
const DEALER_CARD_GAP = 380
const DEALER_HIT_OVERLAP = 80

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
}

const { events } = useBridge()
const cefTyping = useCefTyping()
const rootRef = ref(null)
const svgRef = ref(null)
const svgReady = ref(false)
// bumped on window resize: card positions are pixel boxes measured from the scaled SVG, so they are
// re-read when the viewport changes (they stayed at the old size before)
const viewportTick = ref(0)
const onViewportResize = () => { viewportTick.value++ }
const cardTheme = "light"
const lastTableGameId = ref(null)
const lastShuffleCounter = ref(null)
const liveTimerRemaining = ref(null)
const betInput = ref("100")
const betInputFocused = ref(false)
const dealAnimations = reactive({})
const dealtCardKeys = new Set()
const dealAnimationTimers = []
let pendingShuffleState = null
let shuffleDelayTimer = null
let timerInterval = null

const state = reactive({
  gameId: null,
  phase: "idle",
  bet: 100,
  mode: null,
  careerActive: false,
  balance: null,
  maxBet: 1000,
  betError: null,
})

function formatMoney(n) {
  const v = Math.floor(Number(n) || 0)
  return v.toLocaleString()
}

const effectiveMaxBet = computed(() => {
  const m = Number(state.maxBet)
  return Number.isFinite(m) && m > 0 ? m : 1000
})

const canConfirmBet = computed(() => {
  if (state.phase !== "betting") return false
  if (!state.careerActive) return true
  const bal = Number(state.balance)
  const bet = Number(state.bet)
  const cap = effectiveMaxBet.value
  if (!Number.isFinite(bal) || !Number.isFinite(bet)) return false
  if (bet < 50) return false
  if (bet > cap) return false
  if (bet > bal) return false
  return state.betError !== "insufficientFunds"
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
  void viewportTick.value
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

function parsePx(value) {
  return Number.parseFloat(value || "0") || 0
}

function cardStyleFromSvgId(id, fallbackX, fallbackY) {
  void viewportTick.value
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
  let x
  if (index <= 1) {
    x = DEALER_ANCHOR.x + index * DEALER_CARD_GAP
  } else {
    x = DEALER_ANCHOR.x + DEALER_CARD_GAP + (index - 1) * DEALER_HIT_OVERLAP
  }
  return cardStyle(x, DEALER_ANCHOR.y)
}

function rtbCardStyle(index) {
  const slot = RTB_SLOTS[index] || RTB_SLOTS[RTB_SLOTS.length - 1]
  return cardStyleFromSvgId(`Round-${index + 1}`, slot.x, slot.y)
}

function playCardSound(url, volume = 1) {
  try {
    const audio = new Audio(url)
    audio.volume = volume
    void audio.play().catch(error => reportUiFailure(error, "play card sound (CardGames)"))
  } catch (error) { reportUiFailure(error, "play card sound (CardGames)") }
}

function clearDealAnimationTimers() {
  while (dealAnimationTimers.length) {
    clearTimeout(dealAnimationTimers.pop())
  }
}

function clearShuffleDelayTimer() {
  if (shuffleDelayTimer) {
    clearTimeout(shuffleDelayTimer)
    shuffleDelayTimer = null
  }
}

function resetDealAnimations() {
  clearDealAnimationTimers()
  for (const key of Object.keys(dealAnimations)) {
    delete dealAnimations[key]
  }
  dealtCardKeys.clear()
}

function animatedCardStyle(key, baseStyle) {
  const animationStyle = dealAnimations[key]
  return animationStyle ? { ...baseStyle, ...animationStyle } : baseStyle
}

function isCardDealing(key) {
  return Boolean(dealAnimations[key])
}

function scheduleDealAnimation(key, targetStyle, delayMs, options = {}) {
  const {
    preSoundUrl = null,
    preSoundVolume = 1,
    preSoundLeadMs = 0,
    startSoundUrl = DEAL_SOUND_URL,
    startVolume = DEAL_SOUND_VOLUME,
  } = options
  const deckStyle = deckCardStyle.value
  const fromX = parsePx(deckStyle.left) - parsePx(targetStyle.left)
  const fromY = parsePx(deckStyle.top) - parsePx(targetStyle.top)
  const animationStartMs = delayMs + preSoundLeadMs

  dealAnimations[key] = {
    "--deal-duration": `${DEAL_ANIMATION_MS}ms`,
    "--deal-delay": `${animationStartMs}ms`,
    "--deal-from-x": `${fromX}px`,
    "--deal-from-y": `${fromY}px`,
    zIndex: 15 + Math.round(delayMs / DEAL_STAGGER_MS),
  }

  if (preSoundUrl) {
    dealAnimationTimers.push(window.setTimeout(() => {
      playCardSound(preSoundUrl, preSoundVolume)
    }, delayMs))
  }

  dealAnimationTimers.push(window.setTimeout(() => {
    playCardSound(startSoundUrl, startVolume)
  }, animationStartMs))

  dealAnimationTimers.push(window.setTimeout(() => {
    playCardSound(PLACE_SOUND_URL, PLACE_SOUND_VOLUME)
  }, animationStartMs + Math.max(0, DEAL_ANIMATION_MS - PLACE_SOUND_LEAD_MS)))

  dealAnimationTimers.push(window.setTimeout(() => {
    delete dealAnimations[key]
  }, animationStartMs + DEAL_ANIMATION_MS))
}

function queueDealAnimations(data) {
  if (!data.gameId || !data.mode) return

  const pendingAnimations = []

  if (data.gameId === "blackjack") {
    const playerCards = data.mode.playerCards || []
    const dealerCards = data.mode.dealerCards || []
    const count = Math.max(playerCards.length, dealerCards.length)

    for (let i = 0; i < count; i += 1) {
      if (playerCards[i]) {
        const key = `bj-p-${i}`
        if (!dealtCardKeys.has(key)) {
          dealtCardKeys.add(key)
          pendingAnimations.push({
            key,
            style: playerCardStyle(i),
            preSoundUrl: i >= 2 ? HIT_SOUND_URL : null,
            preSoundVolume: HIT_SOUND_VOLUME,
            preSoundLeadMs: i >= 2 ? HIT_SOUND_LEAD_MS : 0,
            startSoundUrl: DEAL_SOUND_URL,
            startVolume: DEAL_SOUND_VOLUME,
          })
        }
      }

      if (dealerCards[i]) {
        const key = `bj-d-${i}`
        if (!dealtCardKeys.has(key)) {
          dealtCardKeys.add(key)
          pendingAnimations.push({ key, style: dealerCardStyle(i), startSoundUrl: DEAL_SOUND_URL, startVolume: DEAL_SOUND_VOLUME })
        }
      }
    }
  } else if (data.gameId === "rideTheBus") {
    const cards = data.mode.cards || []

    for (let i = 0; i < cards.length; i += 1) {
      const key = `rtb-${i}`
      if (!dealtCardKeys.has(key)) {
        dealtCardKeys.add(key)
        pendingAnimations.push({ key, style: rtbCardStyle(i), startSoundUrl: DEAL_SOUND_URL, startVolume: DEAL_SOUND_VOLUME })
      }
    }
  }

  pendingAnimations.forEach((entry, index) => {
    scheduleDealAnimation(
      entry.key,
      entry.style,
      index * DEAL_STAGGER_MS,
      entry
    )
  })
}

function applyStateData(data) {
  if (!data.gameId || data.phase === "idle" || data.phase === "betting") {
    resetDealAnimations()
  }

  const prevGameId = state.gameId
  state.gameId = data.gameId
  state.phase = data.phase
  state.bet = data.bet
  state.mode = data.mode
  state.careerActive = Boolean(data.careerActive)
  state.balance = typeof data.balance === "number" ? data.balance : null
  state.maxBet = typeof data.maxBet === "number" ? data.maxBet : 1000
  state.betError = data.betError ?? null
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
  queueDealAnimations(data)
}

function applyShufflePendingState(data) {
  state.gameId = data.gameId
  state.phase = data.phase
  state.bet = data.bet
  state.careerActive = Boolean(data.careerActive)
  state.balance = typeof data.balance === "number" ? data.balance : null
  state.maxBet = typeof data.maxBet === "number" ? data.maxBet : 1000
  state.betError = data.betError ?? null

  if (!betInputFocused.value) {
    betInput.value = String(data.bet ?? 100)
  }

  if (data.gameId) {
    lastTableGameId.value = data.gameId
  }

  applyGameSvgVisibility()
}


const bjResultLabel = computed(() => {
  if (!state.mode) return ""
  return BJ_RESULTS[state.mode.result] || state.mode.result || ""
})

function bjStakeAmount() {
  const mb = Number(state.mode?.bet)
  if (Number.isFinite(mb) && mb > 0) return mb
  const sb = Number(state.bet)
  return Number.isFinite(sb) && sb > 0 ? sb : 0
}

// { pre, amount, post }: the template puts the currency glyph before the amount.
const bjPayoutLabel = computed(() => {
  if (!state.mode || !state.mode.result) return null
  const stake = bjStakeAmount()
  const r = state.mode.result
  let total = Number(state.mode.payout)
  if (!Number.isFinite(total) || total <= 0) {
    if (r === "blackjack") total = Math.floor(stake * 2.5)
    else if (r === "win" || r === "dealer_bust") total = stake * 2
    else if (r === "push") total = stake
    else total = 0
  }
  if (r === "blackjack") return { pre: "You won ", amount: total, post: " Blackjack!" }
  if (r === "win" || r === "dealer_bust") return { pre: "You Won ", amount: total, post: "!" }
  if (r === "push") return { pre: "Bet returned ", amount: total, post: "" }
  return null
})

const rtbResultLabel = computed(() => {
  if (!state.mode) return ""
  const r = state.mode.result
  if (r === "forfeit") {
    const cleared = Number(state.mode.roundsCleared) || 0
    if (cleared === 0) return "Bet returned"
    return "You won!"
  }
  return RTB_RESULTS[r] || r || ""
})

// Formatted amount only; the template wraps it as "You won <glyph>amount!".
const rtbResultAmountLabel = computed(() => {
  const amount = state.mode?.collectAmount ?? 0
  const r = state.mode?.result
  if (r === "win") {
    return formatMoney(amount)
  }
  if (r === "forfeit") {
    const cleared = Number(state.mode.roundsCleared) || 0
    if (cleared === 0) return ""
    return formatMoney(amount)
  }
  return ""
})

const timerDisplay = computed(() => {
  if (liveTimerRemaining.value == null) return null
  return Math.ceil(liveTimerRemaining.value)
})

const rtbForfeitAmount = computed(() => state.mode?.collectAmount || 0)

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
  const shuffleIncreased =
    typeof data.shuffleCounter === "number" &&
    lastShuffleCounter.value !== null &&
    data.shuffleCounter > lastShuffleCounter.value

  if (typeof data.shuffleCounter === "number") {
    lastShuffleCounter.value = data.shuffleCounter
  }

  if (shuffleIncreased) {
    applyShufflePendingState(data)
    playCardSound(SHUFFLE_SOUND_URL, SHUFFLE_SOUND_VOLUME)
    pendingShuffleState = data
    clearShuffleDelayTimer()
    shuffleDelayTimer = window.setTimeout(() => {
      const nextState = pendingShuffleState
      pendingShuffleState = null
      shuffleDelayTimer = null
      if (nextState) {
        applyStateData(nextState)
      }
    }, SHUFFLE_DELAY_MS)
    return
  }

  if (shuffleDelayTimer) {
    pendingShuffleState = data
    return
  }

  applyStateData(data)
}

function openGame(gameId) {
  lua.overhaul_jobs_cardGames_cardGames.open(gameId)
}

function closeGame() {
  lua.overhaul_jobs_cardGames_cardGames.close()
}

function switchGames() {
  closeGame()
}

function leaveTable() {
  lua.overhaul_jobs_cardGames_cardGames.leaveTable()
  if (lua.overhaul_career_career && lua.overhaul_career_career.closeAllMenus) {
    lua.overhaul_career_career.closeAllMenus()
    return
  }
  if (window.bngVue && typeof window.bngVue.gotoGameState === "function") {
    window.bngVue.gotoGameState("play", { tryAngularJS: true, blankAngularJS: true })
  }
}

function doAction(name, payload) {
  lua.overhaul_jobs_cardGames_cardGames.action(name, payload || "")
}

function newRound() {
  lua.overhaul_jobs_cardGames_cardGames.newRound()
}

function adjustBet(delta) {
  const cap = effectiveMaxBet.value
  const clamped = Math.max(50, Math.min(cap, (state.bet || 100) + delta))
  lua.overhaul_jobs_cardGames_cardGames.setBet(clamped)
}

function doubleBet() {
  const cap = effectiveMaxBet.value
  const clamped = Math.min(cap, (state.bet || 100) * 2)
  lua.overhaul_jobs_cardGames_cardGames.setBet(clamped)
}

function onBetInput() {
  const digitsOnly = betInput.value.replace(/[^\d]/g, "")
  betInput.value = digitsOnly
}

function onBetInputFocus() {
  betInputFocused.value = true
  cefTyping.onFocus()
}

function commitBetInput() {
  betInputFocused.value = false
  cefTyping.onBlur()
  const val = parseInt(betInput.value, 10)
  if (isNaN(val)) {
    betInput.value = String(state.bet || 100)
    return
  }

  const cap = effectiveMaxBet.value
  const clamped = Math.max(50, Math.min(cap, val))
  betInput.value = String(clamped)
  lua.overhaul_jobs_cardGames_cardGames.setBet(clamped)
}

function confirmBet() {
  lua.overhaul_jobs_cardGames_cardGames.confirmBet()
}

// ---- controller
const enabledBtn = sel => rootRef.value?.querySelector(`${sel}:not([disabled])`) || null
// the main button of whatever control block is showing
function pickControlFocus() {
  if (state.phase === "betting") return enabledBtn(".deal-btn") || enabledBtn(".bet-controls .bet-btn:nth-of-type(2)") || enabledBtn(".betting-panel button")
  if (state.phase === "idle" && !state.gameId) return enabledBtn(".game-selector .game-btn--primary")
  return enabledBtn(".game-controls .game-btn--primary") || enabledBtn(".game-controls .game-btn")
}
// each step swaps its control block (v-if), unmounting the focused button
const controlsKey = computed(() => [state.phase, state.gameId, state.mode?.phase, state.mode?.choiceKind].join("|"))
watch(controlsKey, () => refocusIfLost(pickControlFocus, { force: true }), { flush: "post" })
// Deal turns enabled / disabled with the bet: keep a pad on a live button
// (force while focus sits on the just-disabled Deal: the browser drops it only later)
watch(canConfirmBet, () => refocusIfLost(pickControlFocus, { force: !!document.activeElement?.disabled }), { flush: "post" })

// (unscoped screen: stop the event, or it also reaches the game's global ui_router.back() fallback)
function onBack(event) {
  event?.stopPropagation?.()
  if (state.phase === "betting") return closeGame()
  if (state.phase === "idle" && !state.gameId) return leaveTable()
  if (state.mode?.phase === "resolved") return switchGames()
  // mid-hand (hit / stand, a Ride the Bus choice): B does nothing
}

function resetCardGamesClientState() {
  resetDealAnimations()
  clearShuffleDelayTimer()
  pendingShuffleState = null
  if (timerInterval) {
    clearInterval(timerInterval)
    timerInterval = null
  }
  state.gameId = null
  state.phase = "idle"
  state.bet = 100
  state.mode = null
  state.careerActive = false
  state.balance = null
  state.maxBet = 1000
  state.betError = null
  lastTableGameId.value = null
  lastShuffleCounter.value = null
  liveTimerRemaining.value = null
  betInput.value = "100"
  betInputFocused.value = false
  svgReady.value = false
  cefTyping.onBlur()
}

onMounted(async () => {
  events.on("cardGamesState", handleState)
  window.addEventListener("resize", onViewportResize)

  try {
    const resp = await fetch(SVG_URL)
    const text = await resp.text()
    if (svgRef.value) {
      svgRef.value.innerHTML = text

      hidePlaceholders()
      applyGameSvgVisibility()
      updateSvgHandValue()
      svgReady.value = true
    }
  } catch (err) {
    reportUiFailure(err, "Failed to load cardGames SVG (CardGames)")
  }

  lua.overhaul_jobs_cardGames_cardGames.requestSync()
  // controller entry when the first state matches the initial one (no controlsKey change)
  refocusIfLost(pickControlFocus)
})

onUnmounted(() => {
  try {
    lua.overhaul_jobs_cardGames_cardGames.leaveTable()
  } catch (_) { reportUiFailure(_, "optional action (CardGames)") }
  resetCardGamesClientState()
  events.off("cardGamesState", handleState)
  window.removeEventListener("resize", onViewportResize)
})
</script>

<style scoped lang="scss">
.card-games {
  // controls, bet panel and balance scale with the screen like the SVG table under them (rem-sized they
  // were oversized at 720p, where they rose into the card row, and small at 1440p)
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  position: fixed;
  inset: 0;
  width: 100%;
  height: 100%;
  background: transparent;
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
  will-change: transform, left, top;
}

.table-card--dealing {
  animation-name: card-deal;
  animation-duration: var(--deal-duration, 325ms);
  animation-delay: var(--deal-delay, 0ms);
  animation-fill-mode: both;
  animation-timing-function: cubic-bezier(0.22, 0.61, 0.36, 1);
}

@keyframes card-deal {
  0% {
    transform: translate(var(--deal-from-x), var(--deal-from-y)) scale(0.96);
  }

  82% {
    transform: translate(0, 0) scale(1.015);
  }

  100% {
    transform: translate(0, 0) scale(1);
  }
}

.hand-value-label {
  text-shadow: 0 2px 8px rgba(0,0,0,0.7);
}

.game-controls {
  position: absolute;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: calc(0.6 * var(--rls-u, 1rem));
  // above dealt cards (they animate in at z-index 15 + n and keep it)
  z-index: 30;
}

.bj-controls {
  // the player's hand ends ~92% down the table; at 4% the buttons covered the cards' bottom edge at 720p
  bottom: 1.5%;
  left: 50%;
  transform: translateX(-50%);
  flex-direction: row;
  gap: calc(0.6 * var(--rls-u, 1rem));
}

.bj-result {
  inset: 0;
  justify-content: center;
}

.bj-result-modal {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: calc(1.2 * var(--rls-u, 1rem));
  min-width: calc(22 * var(--rls-u, 1rem));
  padding: calc(2 * var(--rls-u, 1rem)) calc(2.5 * var(--rls-u, 1rem));
  background: rgba(11, 15, 25, 0.94);
  border: 1px solid rgba(71, 85, 105, 0.4);
  border-radius: calc(0.75 * var(--rls-u, 1rem));
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.55);
}

.bj-result-text {
  font-size: calc(1.8 * var(--rls-u, 1rem));
  font-weight: 500;
  color: #fff;
  letter-spacing: 0.01em;
}

.bj-result-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: calc(0.55 * var(--rls-u, 1rem));
}

.rtb-controls {
  bottom: 4%;
  left: 50%;
  transform: translateX(-50%);
  // two compact rows (prompt + timer, then choices + forfeit) so the block fits in the strip under the
  // card row; stacked in four rows it rose behind the cards at 720p-1080p
  display: grid;
  grid-template-columns: auto auto;
  align-items: center;
  column-gap: calc(0.55 * var(--rls-u, 1rem));
  row-gap: calc(0.5 * var(--rls-u, 1rem));
  width: max-content;
  max-width: 94vw;

  .choice-label { grid-column: 1; grid-row: 1; justify-self: end; }
  .choice-timer { grid-column: 2; grid-row: 1; justify-self: start; font-size: calc(1.35 * var(--rls-u, 1rem)); line-height: 1; }
  .choice-label:not(:has(+ .choice-timer)) { grid-column: 1 / -1; justify-self: center; }
  .choice-buttons { grid-column: 1; grid-row: 2; justify-content: flex-end; }
  .end-btn { grid-column: 2; grid-row: 2; margin-top: 0; justify-self: start; }
}

.rtb-result {
  inset: 0;
  justify-content: center;
}

.choice-label {
  font-size: var(--rls-u, 1rem);
  color: rgba(255, 255, 255, 0.6);
  font-weight: 400;
  text-align: center;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.choice-timer {
  font-size: calc(2.2 * var(--rls-u, 1rem));
  color: #f87171;
  font-weight: 500;
  text-align: center;
}

.choice-buttons {
  display: flex;
  gap: calc(0.55 * var(--rls-u, 1rem));
  flex-wrap: wrap;
  justify-content: center;
}

.result-text {
  font-size: calc(1.5 * var(--rls-u, 1rem));
  color: #fff;
  font-weight: 500;
  text-shadow: 0 2px 12px rgba(0,0,0,0.5);
}

.rtb-result-amount {
  font-size: calc(0.95 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.7);
  text-align: center;
  font-weight: 400;
}

// keyboard / controller focus: the house ring (rlsHouse --focus values) on positioned buttons, with the
// game's ::before frame hidden
.game-btn,
.bet-btn {
  position: relative;
  &.focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600),
      0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.game-btn {
  padding: calc(0.55 * var(--rls-u, 1rem)) calc(1.4 * var(--rls-u, 1rem));
  border: 0;
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  background: #374151;
  color: #f3f4f6;
  font-size: calc(0.92 * var(--rls-u, 1rem));
  font-weight: 400;
  cursor: pointer;
  transition: filter 0.15s;

  &:hover { filter: brightness(1.15); }
  &:active { filter: brightness(0.92); }
}

.game-btn--primary {
  background: linear-gradient(90deg, #ff7a1a, #e85f00);
  color: #fff;
  font-weight: 500;
}

.end-btn {
  margin-top: calc(0.35 * var(--rls-u, 1rem));
  background: rgba(71, 85, 105, 0.45);
  color: rgba(255, 255, 255, 0.85);

  &:hover { filter: brightness(1.2); }
}

.betting-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.55);
  // stays above the in-hand controls (z-index 30) and the dealt cards
  z-index: 40;
}

.betting-panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: calc(1.4 * var(--rls-u, 1rem));
  padding: calc(2 * var(--rls-u, 1rem)) calc(2.8 * var(--rls-u, 1rem));
  background: rgba(11, 15, 25, 0.95);
  border: 1px solid rgba(71, 85, 105, 0.4);
  border-radius: calc(0.75 * var(--rls-u, 1rem));
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.55);
}

.bet-title {
  font-size: calc(1.2 * var(--rls-u, 1rem));
  color: #fff;
  font-weight: 500;
  letter-spacing: 0.01em;
}

.bet-controls {
  display: flex;
  align-items: center;
  gap: calc(0.5 * var(--rls-u, 1rem));
}

.bet-btn {
  padding: calc(0.5 * var(--rls-u, 1rem)) calc(0.9 * var(--rls-u, 1rem));
  border: 0;
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  background: #374151;
  color: #f3f4f6;
  font-size: calc(0.88 * var(--rls-u, 1rem));
  font-weight: 400;
  cursor: pointer;
  transition: filter 0.15s;

  &:hover { filter: brightness(1.15); }
  &:active { filter: brightness(0.92); }
}

.bet-input {
  width: calc(6.25 * var(--rls-u, 1rem));
  padding: calc(0.5 * var(--rls-u, 1rem)) calc(0.6 * var(--rls-u, 1rem));
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  background: rgba(5, 8, 15, 0.7);
  color: #fff;
  font-size: var(--rls-u, 1rem);
  font-weight: 400;
  text-align: center;
  outline: none;
  -moz-appearance: textfield;

  &:focus { border-color: rgba(148, 163, 184, 0.5); }

  &::-webkit-inner-spin-button,
  &::-webkit-outer-spin-button {
    -webkit-appearance: none;
  }
}

.deal-btn {
  font-size: var(--rls-u, 1rem);
  padding: calc(0.6 * var(--rls-u, 1rem)) calc(2.4 * var(--rls-u, 1rem));
  background: linear-gradient(90deg, #ff7a1a, #e85f00);
  color: #fff;
  font-weight: 500;

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
    filter: none;
  }
}

.bet-cap-hint {
  font-size: calc(0.8 * var(--rls-u, 1rem));
  color: rgba(148, 163, 184, 0.95);
  font-weight: 400;
  text-align: center;
  margin-top: -0.25rem;
}

.bet-error-hint {
  font-size: calc(0.85 * var(--rls-u, 1rem));
  color: #f87171;
  font-weight: 400;
  text-align: center;
}

.betting-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: calc(0.75 * var(--rls-u, 1rem));
}

.betting-cancel-btn {
  font-size: var(--rls-u, 1rem);
  padding: calc(0.6 * var(--rls-u, 1rem)) calc(1.5 * var(--rls-u, 1rem));
}

.card-games-balance {
  position: absolute;
  bottom: calc(1.25 * var(--rls-u, 1rem));
  right: calc(1.25 * var(--rls-u, 1rem));
  z-index: 25;
  padding: calc(0.65 * var(--rls-u, 1rem)) var(--rls-u, 1rem);
  background: rgba(11, 15, 25, 0.92);
  border: 1px solid rgba(71, 85, 105, 0.4);
  border-radius: calc(0.62 * var(--rls-u, 1rem));
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
  color: rgba(255, 255, 255, 0.9);
  font-size: calc(0.95 * var(--rls-u, 1rem));
  font-weight: 400;
  letter-spacing: 0.02em;
  pointer-events: none;
}

.game-selector {
  position: absolute;
  top: 70%;
  left: 50%;
  transform: translate(-50%, -50%);
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: calc(0.8 * var(--rls-u, 1rem));
  z-index: 20;
}

.selector-buttons {
  display: flex;
  gap: calc(0.8 * var(--rls-u, 1rem));
}

.leave-table-btn {
  min-width: calc(10 * var(--rls-u, 1rem));
  background: rgba(71, 85, 105, 0.45);
  color: rgba(255, 255, 255, 0.85);
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
