// Negotiation map: state; turn/range/price derivations; chat and input actions; server sync;
// offer/exit actions and lifecycle. The public composable wires the groups in initialization order.
import { computed, onMounted, onUnmounted, ref, nextTick, watch } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'

const STEP = 50

// Created in the same order as the original single function: refs and computeds as they are declared, then
// the watcher, the events subscription and the mount/unmount hooks. Helpers that create refs or computeds
// must be called in the order useVehicleNegotiation calls them; the initialization-order test in
// tests/phone/vehicle_negotiation_ordered_trace_test.cjs fails if that order changes.

function createNegotiationState() {
  const state = ref({
    active: false,
    startingPrice: 0,
    patience: 0,
    myOffer: null,
    theirOffer: 0,
    thinking: false,
    status: '',
    negotiationStatus: '',
    opponentName: '',
    opponentQuote: '',
    vehicleNiceName: '',
    vehicleThumbnail: '',
    amISelling: false,
    hideMarketValue: false,
    playerStartsNegotiation: false,
    hasVisibleTheirOffer: true,
    purchaseAfterAccept: false,
    purchaseFailureReason: null,
    offerHistory: [],
  })

  const opponent = computed(() => (state.value.amISelling ? 'Buyer' : 'Seller'))
  const biggerIsBetter = computed(() => state.value.amISelling === true)

  const offerPreview = ref(0)
  const openingOffer = ref(null)
  const openingOfferText = ref('0')
  const openingOfferTouched = ref(false)
  const negotiationChat = ref(null)
  /** Set when a stepper or Split gap could not move the preview, so the UI can say why. */
  const clampedHint = ref('')
  /** Split gap always lands a valid counter, so it is worth one use per negotiation. */
  const splitGapUsed = ref(false)
  /** Sell path syncs live damage before completing — lock Take/Send/Back until result arrives. */
  const acceptancePending = ref(false)

  return {
    state,
    opponent,
    biggerIsBetter,
    offerPreview,
    openingOffer,
    openingOfferText,
    openingOfferTouched,
    negotiationChat,
    clampedHint,
    splitGapUsed,
    acceptancePending,
  }
}

function deriveTurnGate({ state, openingOffer, acceptancePending }) {
  const awaitingOpeningOffer = computed(() => {
    return (
      state.value.playerStartsNegotiation
      && state.value.myOffer == null
      && !state.value.hasVisibleTheirOffer
      && state.value.negotiationStatus !== 'failed'
      && state.value.negotiationStatus !== 'accepted'
    )
  })

  const openingOfferDisabled = computed(() => !(Number(openingOffer.value) > 0) || offerDisabled.value)

  const offerDisabled = computed(() => {
    const status = state.value.negotiationStatus
    return acceptancePending.value
      || status === 'thinking' || status === 'typing' || status === 'accepted' || status === 'failed'
  })

  const isResolved = computed(() =>
    state.value.negotiationStatus === 'accepted' || state.value.negotiationStatus === 'failed',
  )
  const isWaitingOnThem = computed(() =>
    state.value.negotiationStatus === 'thinking' || state.value.negotiationStatus === 'typing',
  )
  const isMyTurn = computed(() => !isResolved.value && !isWaitingOnThem.value)

  return { awaitingOpeningOffer, openingOfferDisabled, offerDisabled, isResolved, isWaitingOnThem, isMyTurn }
}

function deriveRange({ state, offerPreview }) {
  /** Hard limits the offer may be nudged within — mirrors what Lua will accept. */
  const offerLimits = computed(() => {
    const s = state.value
    if (s.amISelling) {
      return {
        min: Number(s.theirOffer) || 0,
        max: s.myOffer != null ? Number(s.myOffer) : Number.POSITIVE_INFINITY,
      }
    }
    return {
      min: s.myOffer != null ? Number(s.myOffer) : 0,
      max: s.hasVisibleTheirOffer ? Number(s.theirOffer) || 0 : Number.POSITIVE_INFINITY,
    }
  })

  /**
   * Finite bounds for the range track. Starts from the legal limits and widens to keep the
   * handle on the track when a limit is unbounded (opening offers) or the player steps past it.
   */
  const rangeBounds = computed(() => {
    const s = state.value
    const preview = Number(offerPreview.value) || 0
    const limits = offerLimits.value

    let lo = limits.min
    let hi = limits.max

    if (!Number.isFinite(hi)) {
      hi = Math.max(Number(s.startingPrice) || 0, preview)
    }
    if (s.amISelling && s.myOffer == null) {
      hi = Math.max(Number(s.startingPrice) || 0, preview)
    }
    if (!s.amISelling && s.myOffer == null) {
      // no counter of ours yet: give the handle somewhere to travel below their asking price
      lo = Math.round((hi * 0.5) / STEP) * STEP
    }

    return { lo: Math.min(lo, preview), hi: Math.max(hi, preview) }
  })

  const rangePercent = value => {
    const { lo, hi } = rangeBounds.value
    const span = Math.max(1, hi - lo)
    return Math.max(0, Math.min(100, ((Number(value) - lo) / span) * 100))
  }

  const previewPercent = computed(() => rangePercent(offerPreview.value))

  const theirOfferPercent = computed(() => rangePercent(state.value.theirOffer))

  /** Blue band spanning the gap between their current price and what you are about to send. */
  const gapFill = computed(() => {
    const a = previewPercent.value
    const b = theirOfferPercent.value
    return { left: Math.min(a, b), width: Math.abs(a - b) }
  })

  const marketValue = computed(() => {
    if (state.value.hideMarketValue) return null
    const value = Number(state.value.actualVehicleValue)
    return Number.isFinite(value) && value > 0 ? value : null
  })

  const showMarketTick = computed(() => {
    if (marketValue.value === null) return false
    const { lo, hi } = rangeBounds.value
    return marketValue.value >= lo && marketValue.value <= hi
  })

  const marketPercent = computed(() => rangePercent(marketValue.value ?? 0))

  const rangeLowLabel = computed(() => {
    const s = state.value
    if (s.amISelling) return { prefix: 'Their', value: rangeBounds.value.lo }
    return s.myOffer != null ? { prefix: 'You', value: rangeBounds.value.lo } : null
  })

  const rangeHighLabel = computed(() => {
    const s = state.value
    if (!s.amISelling) return { prefix: 'Their', value: rangeBounds.value.hi }
    return s.myOffer != null
      ? { prefix: 'You', value: rangeBounds.value.hi }
      : { prefix: 'Asking', value: rangeBounds.value.hi }
  })

  const increaseOfferDisabled = computed(() => offerPreview.value >= offerLimits.value.max)
  const decreaseOfferDisabled = computed(() => offerPreview.value <= offerLimits.value.min)

  return {
    offerLimits,
    rangeBounds,
    previewPercent,
    gapFill,
    marketValue,
    showMarketTick,
    marketPercent,
    rangeLowLabel,
    rangeHighLabel,
    increaseOfferDisabled,
    decreaseOfferDisabled,
  }
}

function derivePriceComparison({ state, offerPreview, biggerIsBetter }, { marketValue }) {
  const diffOfferPreviewToStarting = computed(() => offerPreview.value - state.value.startingPrice)

  const isDiffOfferPreviewToStartingGood = computed(() => {
    return biggerIsBetter.value ? diffOfferPreviewToStarting.value >= 0 : diffOfferPreviewToStarting.value <= 0
  })

  const diffPercentOfferPreviewToMarket = computed(() => {
    if (marketValue.value === null) return null
    return Math.round(((offerPreview.value - marketValue.value) / marketValue.value) * 100)
  })

  const isDiffPercentOfferPreviewToMarketGood = computed(() => {
    if (diffPercentOfferPreviewToMarket.value === null) return null
    return biggerIsBetter.value
      ? diffPercentOfferPreviewToMarket.value >= 0
      : diffPercentOfferPreviewToMarket.value <= 0
  })

  const marketDiffText = computed(() => {
    const diff = diffPercentOfferPreviewToMarket.value
    if (diff === null) return ''
    if (diff === 0) return 'At est. market'
    return `${Math.abs(diff)}% ${diff < 0 ? 'under' : 'over'} market`
  })

  return { diffOfferPreviewToStarting, isDiffOfferPreviewToStartingGood, diffPercentOfferPreviewToMarket, isDiffPercentOfferPreviewToMarketGood, marketDiffText }
}

function deriveTurnCopy({ state, opponent }, { isWaitingOnThem }) {
  const patienceClass = computed(() => {
    const m = state.value.patience ?? 0
    if (m > 0.66) return 'patience-good'
    if (m > 0.33) return 'patience-mid'
    return 'patience-bad'
  })

  const patiencePercent = computed(() => Math.round(Math.max(0, Math.min(1, state.value.patience ?? 0)) * 100))

  /** Short patience state. The bar carries the detail; this just names where it sits. */
  const patienceText = computed(() => {
    const p = state.value.patience ?? 0
    if (state.value.negotiationStatus === 'counterOfferLastChance') return 'Final offer'
    if (state.value.negotiationStatus === 'failed') return 'Walked away'
    if (p > 0.66) return 'Patient'
    if (p > 0.33) return 'Getting impatient'
    return 'About to walk away'
  })

  const turnText = computed(() => {
    if (isWaitingOnThem.value) return `${opponent.value} is thinking…`
    if (state.value.negotiationStatus === 'accepted') return 'Deal agreed'
    if (state.value.negotiationStatus === 'failed') return `${opponent.value} walked away`
    return 'Your move'
  })

  const turnClass = computed(() => {
    if (isWaitingOnThem.value) return 'turn--waiting'
    if (state.value.negotiationStatus === 'failed') return 'turn--failed'
    if (state.value.negotiationStatus === 'accepted') return 'turn--done'
    return 'turn--yours'
  })

  return { patienceClass, patiencePercent, patienceText, turnText, turnClass }
}

function deriveOfferInputs({ state, acceptancePending, offerPreview, clampedHint }, { isMyTurn, awaitingOpeningOffer, offerDisabled }, { offerLimits }) {
  /**
   * Repeating the number already on the table is a no-op in Lua, and the steppers stop at the
   * legal limits — in both cases say why instead of leaving a dead button.
   */
  const sendIsNoop = computed(() => {
    const preview = Number(offerPreview.value)
    const { theirOffer, myOffer, hasVisibleTheirOffer } = state.value
    if (hasVisibleTheirOffer && preview === Number(theirOffer)) return true
    return myOffer != null && preview === Number(myOffer)
  })

  const clampHint = computed(() => {
    if (!isMyTurn.value || awaitingOpeningOffer.value) return ''
    const s = state.value
    const limits = offerLimits.value
    // Sitting on their number: say which number, and whether taking it is the better move.
    if (!s.amISelling && s.hasVisibleTheirOffer && offerPreview.value >= limits.max) {
      return "That's their full asking price — come down to counter, or take it."
    }
    if (s.amISelling && offerPreview.value <= limits.min) {
      return 'Lowest you can go is their current offer.'
    }
    if (sendIsNoop.value) {
      return s.amISelling
        ? 'Come down from your last price to counter — repeating it does nothing.'
        : 'Go up from your last offer to counter — repeating it does nothing.'
    }
    return clampedHint.value
  })

  // counterOfferLastChance blocks further counters, not acceptance — it is their final offer, so
  // taking it is the whole point. Guarding Take on it too left the player with no way out.
  const canTakeTheirOffer = computed(() =>
    isMyTurn.value
    && state.value.hasVisibleTheirOffer
    && !offerDisabled.value
    && !acceptancePending.value,
  )

  const sendDisabled = computed(() =>
    !isMyTurn.value
    || offerDisabled.value
    || sendIsNoop.value
    || state.value.negotiationStatus === 'counterOfferLastChance'
    || acceptancePending.value,
  )

  return { sendIsNoop, clampHint, canTakeTheirOffer, sendDisabled }
}

function deriveOutcome({ state }) {
  const noDeal = computed(() => {
    if (state.value.purchaseFailureReason) return false
    return state.value.negotiationStatus === 'failed' && (state.value.amISelling || state.value.playerStartsNegotiation)
  })

  const resolvedIconType = computed(() => {
    if (state.value.purchaseFailureReason) return 'danger'
    if (state.value.negotiationStatus === 'accepted') return 'checkmark'
    return 'abandon'
  })

  const resolvedStatusText = computed(() => {
    if (state.value.purchaseFailureReason) return state.value.purchaseFailureReason
    if (state.value.negotiationStatus === 'failed') {
      if (state.value.amISelling) {
        return `${state.value.opponentName || 'The buyer'} ran out of patience and walked away. Your listing stays live — another buyer will come along.`
      }
      if (state.value.playerStartsNegotiation) {
        return `${state.value.opponentName || 'The seller'} ran out of patience and walked away.`
      }
      return 'The other party ran out of patience.'
    }
    if (state.value.negotiationStatus === 'accepted') {
      return state.value.amISelling
        ? 'The sale is agreed. The vehicle leaves your garage when you complete it.'
        : 'Continue to complete the purchase at this price.'
    }
    return ''
  })

  const resolvedTitle = computed(() => {
    if (state.value.purchaseFailureReason) return state.value.amISelling ? 'Sale failed' : 'Purchase failed'
    return state.value.negotiationStatus === 'accepted' ? 'Deal agreed' : 'No deal'
  })

  const resolvedActionText = computed(() => {
    if (state.value.purchaseFailureReason) return 'Continue'
    if (state.value.negotiationStatus === 'failed') return state.value.amISelling ? 'Back to offers' : 'Close'
    if (state.value.amISelling) return 'Complete sale'
    if (state.value.purchaseAfterAccept) return 'Purchase'
    return 'Go to purchase'
  })

  return { noDeal, resolvedIconType, resolvedStatusText, resolvedTitle, resolvedActionText }
}

function createChatView({ state }) {
  const formatMileage = mileageMeters => {
    const meters = Number(mileageMeters)
    if (!Number.isFinite(meters) || meters <= 0) return '0 mi'
    return `${Math.round(meters / 1609.344).toLocaleString()} mi`
  }

  /** Chat bubbles: side plus a label that names which number this is. */
  const messages = computed(() => {
    const history = Array.isArray(state.value.offerHistory) ? state.value.offerHistory : []
    const selling = state.value.amISelling
    const who = selling ? 'BUYER' : 'SELLER'
    let seenMine = false
    let seenTheirs = false

    const rows = history.map((item, index) => {
      const mine = item.myOffer != null
      const price = mine ? item.myOffer : item.theirOffer
      const status = String(item.negotiationStatus || '')
      let label

      if (status === 'accepted') {
        label = mine ? 'YOU ACCEPTED' : 'THEY ACCEPTED'
      } else if (status === 'failed') {
        label = `${who} WALKED AWAY`
      } else if (status === 'refused') {
        label = 'THEY REFUSED'
      } else if (mine) {
        label = seenMine ? 'YOUR COUNTER' : (selling ? 'YOUR ASKING PRICE' : 'YOUR OPENING OFFER')
      } else if (status === 'counterOfferLastChance') {
        label = 'THEIR FINAL OFFER'
      } else {
        label = seenTheirs ? 'THEIR COUNTER' : (selling ? 'THEIR OFFER' : 'ASKING PRICE')
      }

      if (mine) seenMine = true
      else seenTheirs = true

      return {
        key: `${index}-${mine ? 'me' : 'them'}-${price ?? status}`,
        mine,
        label,
        price: status === 'failed' ? null : price,
        tone: status === 'accepted' ? 'accepted' : status === 'failed' ? 'failed' : null,
        note: status === 'failed'
          ? 'Out of patience.'
          : status === 'counterOfferLastChance'
            ? 'Take it or leave it.'
            : status === 'refused'
              ? 'That offer was not worth a reply.'
              : '',
        typing: false,
      }
    })

    // opening quote sits under the first thing they said, so the pitch has a home
    if (rows.length && state.value.opponentQuote) {
      const firstTheirs = rows.find(row => !row.mine)
      if (firstTheirs && !firstTheirs.note) firstTheirs.note = state.value.opponentQuote
    }

    // No typing bubble here — the turn indicator above the actions already says
    // "<Seller> is thinking…", and showing both said the same thing twice.
    return rows
  })

  return { messages, formatMileage }
}

function createOfferInputActions({ offerPreview, openingOffer, openingOfferText, openingOfferTouched, clampedHint, splitGapUsed }, { offerLimits }, { isMyTurn, offerDisabled }) {
  const nudgeOffer = delta => {
    const { min, max } = offerLimits.value
    const rounded = Math.max(0, Math.round((offerPreview.value + delta) / STEP) * STEP)
    const next = Math.min(max, Math.max(min, rounded))
    clampedHint.value = next === offerPreview.value && delta !== 0
      ? `Can't move ${delta > 0 ? 'up' : 'down'} any further in this negotiation.`
      : ''
    offerPreview.value = next
  }

  const splitGapAvailable = computed(() => !splitGapUsed.value && isMyTurn.value && !offerDisabled.value)

  /**
   * Meet in the middle between their current price and your last offer. Once per negotiation.
   * Uses offerLimits, not rangeBounds: the latter is a display range that widens to the preview
   * and invents a floor for an opening buyer, so midpointing it landed at ~75% of asking and
   * moved as the player stepped the preview.
   */
  const splitTheGap = () => {
    if (!splitGapAvailable.value) return
    const { min, max } = offerLimits.value
    if (!Number.isFinite(min) || !Number.isFinite(max) || max <= min) return
    clampedHint.value = ''
    offerPreview.value = Math.min(max, Math.max(min, Math.round(((min + max) / 2) / STEP) * STEP))
    splitGapUsed.value = true
  }

  const nudgeOpeningOffer = delta => {
    const current = Number(openingOffer.value) || 0
    openingOfferTouched.value = true
    openingOffer.value = Math.max(0, Math.round((current + delta) / STEP) * STEP)
    openingOfferText.value = String(openingOffer.value)
    offerPreview.value = openingOffer.value
  }

  const onOpeningOfferInput = event => {
    const digits = String(event.target.value || '').replace(/[^\d]/g, '')
    openingOfferText.value = digits
    openingOffer.value = digits === '' ? null : Number(digits)
    openingOfferTouched.value = true
    offerPreview.value = Number(openingOffer.value) || 0
  }

  const onOpeningInputFocus = event => {
    try { lua.setCEFTyping(true) } catch (_) {}
    if (event?.target?.select) event.target.select()
  }

  const onOpeningInputBlur = () => {
    try { lua.setCEFTyping(false) } catch (_) {}
  }

  return { splitGapAvailable, nudgeOffer, splitTheGap, nudgeOpeningOffer, onOpeningOfferInput, onOpeningInputFocus, onOpeningInputBlur }
}

function createServerSync({ state, offerPreview, openingOffer, openingOfferText, openingOfferTouched, acceptancePending, clampedHint }, { awaitingOpeningOffer }, onExit) {
  const applyPurchaseFailure = result => {
    acceptancePending.value = false
    const reason = result?.reason || 'Purchase could not be completed.'
    state.value.purchaseFailureReason = reason
    if (state.value.negotiationStatus === 'failed') {
      state.value.negotiationStatus = 'accepted'
      state.value.status = 'accepted'
    }
    offerPreview.value = state.value.theirOffer ?? offerPreview.value
  }

  const refresh = async payload => {
    const s = payload || await lua.overhaul_career_market_marketplace.getNegotiationState()
    if (!s) {
      onExit?.(state.value)
      return
    }
    if (!payload && !s.active) return
    const priorHistory = state.value.offerHistory
    state.value = {
      ...state.value,
      ...s,
      purchaseFailureReason: s.purchaseFailureReason ?? state.value.purchaseFailureReason ?? null,
    }
    if (s.saleCompleted) {
      acceptancePending.value = false
      state.value.negotiationStatus = 'accepted'
      state.value.status = 'accepted'
      state.value.iAccepted = true
      state.value.purchaseFailureReason = null
      offerPreview.value = state.value.theirOffer ?? offerPreview.value
      if (!Array.isArray(state.value.offerHistory)) state.value.offerHistory = []
      state.value.offerHistory.push({
        myOffer: state.value.theirOffer,
        negotiationStatus: 'accepted',
      })
    }
    if (state.value.purchaseFailureReason) {
      acceptancePending.value = false
    }
    if (state.value.purchaseFailureReason && state.value.negotiationStatus === 'failed') {
      state.value.negotiationStatus = 'accepted'
      state.value.status = 'accepted'
    }
    if (!s.offerHistory && priorHistory?.length) {
      state.value.offerHistory = priorHistory
    }

    const base = state.value.myOffer != null ? state.value.myOffer : state.value.startingPrice
    if (!awaitingOpeningOffer.value && !Number.isNaN(Number(base))) offerPreview.value = Number(base)
    if (awaitingOpeningOffer.value) {
      if (!openingOfferTouched.value && openingOffer.value == null) {
        openingOffer.value = 0
        openingOfferText.value = '0'
      }
      offerPreview.value = Number(openingOffer.value) || 0
    }
    if (state.value.negotiationStatus === 'failed' && !state.value.purchaseFailureReason) {
      offerPreview.value = state.value.startingPrice
    }
    clampedHint.value = ''
  }

  return { applyPurchaseFailure, refresh }
}

function watchNewNegotiation({ state, splitGapUsed, acceptancePending }) {
  // A fresh negotiation gets its own Split gap; the composable can outlive one deal.
  watch(() => [state.value.opponentName, state.value.vehicleNiceName].join('|'), () => {
    splitGapUsed.value = false
    acceptancePending.value = false
  })
}

function createOfferActions({ state, offerPreview, openingOffer, openingOfferTouched, acceptancePending }, { applyPurchaseFailure, refresh }) {
  const submitOffer = async () => {
    const price = Number(offerPreview.value)
    if (!Number.isFinite(price)) return
    await lua.overhaul_career_market_marketplace.makeNegotiationOffer(price)
  }

  const submitOpeningOffer = async () => {
    const price = Number(openingOffer.value)
    if (!Number.isFinite(price) || price <= 0) return
    offerPreview.value = price
    openingOfferTouched.value = true
    await lua.overhaul_career_market_marketplace.makeNegotiationOffer(price)
  }

  const takeOffer = async () => {
    if (acceptancePending.value) return
    const result = await lua.overhaul_career_market_marketplace.takeTheirOffer()
    if (result?.ok === false || result?.ok === 0) {
      applyPurchaseFailure(result)
      return
    }
    // Spawned sell path syncs live damage before completing — wait for negotiationData.
    if (result?.pending) {
      acceptancePending.value = true
      return
    }
    if (!result?.ok && state.value.purchaseAfterAccept) {
      await refresh()
      if (state.value.purchaseFailureReason) return
    }

    state.value.negotiationStatus = 'accepted'
    state.value.status = 'accepted'
    state.value.purchaseFailureReason = null
    offerPreview.value = state.value.theirOffer
    state.value.iAccepted = true
    if (!Array.isArray(state.value.offerHistory)) state.value.offerHistory = []
    state.value.offerHistory.push({
      myOffer: state.value.theirOffer,
      negotiationStatus: 'accepted',
    })
  }

  return { submitOffer, submitOpeningOffer, takeOffer }
}

function createExitActions({ state, acceptancePending }, { applyPurchaseFailure, refresh }, onExit) {
  const cancel = async () => {
    if (state.value.negotiationStatus !== 'accepted') {
      await lua.overhaul_career_market_marketplace.cancelNegotiation()
    }
  }

  const exitNegotiation = async () => {
    if (acceptancePending.value) return
    if (state.value.purchaseFailureReason) {
      await lua.overhaul_career_market_marketplace.dismissNegotiation()
    } else if (
      state.value.negotiationStatus === 'accepted'
      && state.value.purchaseAfterAccept
      && !state.value.iAccepted
    ) {
      await lua.overhaul_career_market_marketplace.dismissNegotiation()
    } else {
      await cancel()
    }
    onExit?.(state.value)
  }

  const goBack = async () => {
    if (acceptancePending.value) return
    if (state.value.purchaseFailureReason) {
      await lua.overhaul_career_market_marketplace.dismissNegotiation()
      onExit?.(state.value)
      return
    }

    if (state.value.negotiationStatus === 'accepted' && !state.value.iAccepted) {
      const result = await lua.overhaul_career_market_marketplace.takeTheirOffer()
      if (result?.ok === false || result?.ok === 0) {
        applyPurchaseFailure(result)
        return
      }
      // Async damage sync still running — negotiationData will accept or show repair failure.
      if (result?.pending) {
        acceptancePending.value = true
        return
      }
      if (!result?.ok) {
        await refresh()
        if (state.value.purchaseFailureReason) return
      }
      state.value.iAccepted = true
    }

    if (state.value.purchaseFailureReason) {
      await lua.overhaul_career_market_marketplace.dismissNegotiation()
    } else {
      await cancel()
    }
    if (state.value.purchaseAfterAccept && state.value.negotiationStatus === 'accepted') {
      lua.overhaul_career_career.closeAllMenus()
      onExit?.(state.value)
      return
    }
    // Buying: takeTheirOffer() only writes the agreed price onto the shop vehicle. Hand off to
    // the purchase screen so the car is actually bought, instead of dropping back on the feed.
    if (!state.value.amISelling && state.value.negotiationStatus === 'accepted') {
      const handedOff = await lua.overhaul_career_market_marketplace.finishPhonePurchase()
      if (handedOff) return
    }
    onExit?.(state.value)
  }

  return { exitNegotiation, goBack }
}

function createLifecycle({ negotiationChat }, { refresh }, events) {
  const start = async () => {
    await refresh()
    nextTick(() => {
      if (negotiationChat.value) negotiationChat.value.scrollTop = negotiationChat.value.scrollHeight
    })
  }

  const kill = async () => {
    try { lua.setCEFTyping(false) } catch (_) {}
    events.off('negotiationData')
  }

  return { start, kill }
}

export function useVehicleNegotiation(onExit) {
  const events = useEvents()

  const core = createNegotiationState()
  const turnGate = deriveTurnGate(core)
  const range = deriveRange(core)
  const price = derivePriceComparison(core, range)
  const turnCopy = deriveTurnCopy(core, turnGate)
  const inputs = deriveOfferInputs(core, turnGate, range)
  const outcome = deriveOutcome(core)
  const chat = createChatView(core)
  const inputActions = createOfferInputActions(core, range, turnGate)
  const sync = createServerSync(core, turnGate, onExit)
  const offers = createOfferActions(core, sync)
  const exits = createExitActions(core, sync, onExit)
  const lifecycle = createLifecycle(core, sync, events)
  const { refresh } = sync

  watchNewNegotiation(core)

  events.on('negotiationData', data => {
    refresh(data)
  })

  onMounted(lifecycle.start)
  onUnmounted(lifecycle.kill)

  return {
    state: core.state,
    opponent: core.opponent,
    acceptancePending: core.acceptancePending,
    offerPreview: core.offerPreview,
    openingOfferText: core.openingOfferText,
    awaitingOpeningOffer: turnGate.awaitingOpeningOffer,
    openingOfferDisabled: turnGate.openingOfferDisabled,
    increaseOfferDisabled: range.increaseOfferDisabled,
    decreaseOfferDisabled: range.decreaseOfferDisabled,
    diffOfferPreviewToStarting: price.diffOfferPreviewToStarting,
    isDiffOfferPreviewToStartingGood: price.isDiffOfferPreviewToStartingGood,
    diffPercentOfferPreviewToMarket: price.diffPercentOfferPreviewToMarket,
    isDiffPercentOfferPreviewToMarketGood: price.isDiffPercentOfferPreviewToMarketGood,
    marketValue: range.marketValue,
    marketDiffText: price.marketDiffText,
    offerDisabled: turnGate.offerDisabled,
    isResolved: turnGate.isResolved,
    isWaitingOnThem: turnGate.isWaitingOnThem,
    isMyTurn: turnGate.isMyTurn,
    messages: chat.messages,
    rangeBounds: range.rangeBounds,
    previewPercent: range.previewPercent,
    gapFill: range.gapFill,
    showMarketTick: range.showMarketTick,
    marketPercent: range.marketPercent,
    rangeLowLabel: range.rangeLowLabel,
    rangeHighLabel: range.rangeHighLabel,
    clampHint: inputs.clampHint,
    splitGapAvailable: inputActions.splitGapAvailable,
    splitGapUsed: core.splitGapUsed,
    canTakeTheirOffer: inputs.canTakeTheirOffer,
    sendDisabled: inputs.sendDisabled,
    turnText: turnCopy.turnText,
    turnClass: turnCopy.turnClass,
    patienceClass: turnCopy.patienceClass,
    patiencePercent: turnCopy.patiencePercent,
    patienceText: turnCopy.patienceText,
    noDeal: outcome.noDeal,
    resolvedIconType: outcome.resolvedIconType,
    resolvedTitle: outcome.resolvedTitle,
    resolvedStatusText: outcome.resolvedStatusText,
    resolvedActionText: outcome.resolvedActionText,
    formatMileage: chat.formatMileage,
    negotiationChat: core.negotiationChat,
    nudgeOffer: inputActions.nudgeOffer,
    splitTheGap: inputActions.splitTheGap,
    nudgeOpeningOffer: inputActions.nudgeOpeningOffer,
    onOpeningOfferInput: inputActions.onOpeningOfferInput,
    onOpeningInputFocus: inputActions.onOpeningInputFocus,
    onOpeningInputBlur: inputActions.onOpeningInputBlur,
    submitOffer: offers.submitOffer,
    submitOpeningOffer: offers.submitOpeningOffer,
    takeOffer: offers.takeOffer,
    exitNegotiation: exits.exitNegotiation,
    goBack: exits.goBack,
  }
}
