<template>
  <div v-if="watching && state" class="rls-house rls-house-card betting">
    <div v-if="!expanded" class="bet-entry cluster">
      <HouseButton v-if="market?.open && !ticket" compact variant="primary" @click="show('bet')">Place bet, {{ market.seconds }} s left</HouseButton>
      <HouseButton v-else-if="ticket && !ticket.settled" compact @click="show('ticket')">View bet</HouseButton>
      <HouseButton v-if="state.result" compact @click="show('result')">Bet result</HouseButton>
    </div>
    <section v-else class="bet-backdrop" v-bng-scoped-nav="betScope" v-bng-on-ui-nav:back,menu="minimize" @keydown.esc.stop="minimize">
      <div ref="root" class="bet-panel" role="dialog" aria-label="Race bet">
        <header class="bet-head">
          <h2 :class="headTone">{{ headTitle }}</h2>
          <div class="cluster"><span v-if="market?.open && mode !== 'result'" class="timer" :class="{ soon: !ticket && market.seconds <= 10 }"><template v-if="ticket">Race starts soon</template><span v-else-if="market.paused" class="paused ms-tone-wait">Race paused</span><template v-else><span class="ms-label">Closes in</span><strong class="time">{{ market.seconds }} s</strong></template></span><HouseButton compact variant="quiet" bng-scoped-nav-autofocus aria-label="Minimize bet" @click="minimize">Hide</HouseButton></div>
        </header>
        <template v-if="mode === 'result' && state.result">
          <div class="receipt">
            <img v-if="state.result.car.image" :src="state.result.car.image" alt="" @error="hideImage" />
            <h3>{{ state.result.car.name }}</h3>
            <p>{{ state.result.car.driver }}</p>
            <p v-if="state.result.xp">+{{ state.result.xp }} Gambling XP</p>
          </div>
          <div class="bet-footer ms-foot">
            <!-- One amount for a loss or a refund; a win adds what it was made of. -->
            <dl class="summary">
              <template v-if="state.result.net > 0"><div class="lead"><dt class="ms-label">Net winnings</dt><dd class="money">{{ cash(state.result.net) }}</dd></div><div><dt class="ms-label">Stake</dt><dd class="money">{{ cash(state.result.stake) }}</dd></div><div><dt class="ms-label">Returned</dt><dd class="money">{{ cash(state.result.returned) }}</dd></div></template>
              <div v-else-if="state.result.net < 0"><dt class="ms-label">Stake</dt><dd class="loss">{{ cash(state.result.stake) }}</dd></div>
              <div v-else><dt class="ms-label">Returned</dt><dd class="money">{{ cash(state.result.returned) }}</dd></div>
            </dl>
            <HouseButton class="ms-foot-end" variant="primary" @click="minimize">Back to race</HouseButton>
          </div>
        </template>
        <template v-else-if="ticket">
          <div class="receipt"><img v-if="ticket.car.image" :src="ticket.car.image" alt="" @error="hideImage" /><h3>{{ ticket.car.name }}</h3><p>{{ ticket.car.driver }}</p></div>
          <div class="bet-footer ms-foot">
            <dl class="summary"><div><dt class="ms-label">Stake</dt><dd class="money">{{ cash(ticket.stake) }}</dd></div><div><dt class="ms-label">Return if won</dt><dd class="money">{{ cash(ticket.total) }}</dd></div></dl>
            <HouseButton class="ms-foot-end" variant="primary" @click="minimize">Watch race</HouseButton>
          </div>
        </template>
        <template v-else-if="market?.open">
          <div class="cars">
            <HouseButton v-for="car in market.cars" :key="car.id" class="car" :class="{selected: selected === car.id}" :aria-pressed="selected === car.id" :disabled="busy" @click="selected = car.id">
              <img v-if="car.image" :src="car.image" :alt="car.name" @error="hideImage" />
              <div v-else class="no-photo"><BngIcon :type="icons.car" /></div>
              <div class="car-copy"><div class="name-row"><span class="car-name">{{ car.name }}</span><span v-if="selected === car.id" class="picked">Selected</span></div><small>{{ car.driver }}</small>
                <div class="numbers"><span><span class="ms-label">Lane</span><strong>{{ car.lane === 'right' ? 'Right' : car.lane === 'left' ? 'Left' : 'Pending' }}</strong></span><span><span class="ms-label">Qualifying avg.</span><strong class="time">{{ car.average.toFixed(3) }} s</strong></span><span class="pays"><span class="ms-label">Pays</span><strong>{{ car.odds.toFixed(2) }}×</strong></span></div>
              </div>
            </HouseButton>
          </div>
          <dl class="limits"><div><dt class="ms-label">Minimum</dt><dd class="money">{{ cash(minimum) }}</dd></div><div><dt class="ms-label">Maximum</dt><dd class="money">{{ cash(marketMaximum) }}</dd></div><div><dt class="ms-label" :class="{ short: balanceShort }">Balance</dt><dd class="money">{{ cash(balance) }}</dd></div></dl>
          <div class="stake-line"><span class="ms-label">Stake</span><div class="cluster">
            <HouseButton :disabled="busy || stake <= minimum" aria-label="Decrease stake by 100 dollars" @click="step(-100)">−</HouseButton>
            <span class="money">$</span><input v-model.number="stake" v-bng-text-input class="field" type="number" :min="minimum" :max="maximum" step="1" aria-label="Stake" :disabled="busy" />
            <HouseButton :disabled="busy || stake >= maximum" aria-label="Increase stake by 100 dollars" @click="step(100)">+</HouseButton>
            <HouseButton :disabled="busy || maximum < minimum || stake === maximum" @click="stake = maximum">Max</HouseButton>
          </div></div>
          <!-- One message line: what stops the bet, or the warning that matters once it can be placed. -->
          <p id="motorsport-bet-reason" class="validation" :class="{error: !!(error || state.error), hint: !(error || state.error || disabledReason)}" aria-live="polite">{{ error || state.error || disabledReason || 'If you leave or reload the game before the race ends, open bets are lost.' }}</p>
          <div class="bet-footer ms-foot"><span class="return"><span class="ms-label">Return with stake, rounded down</span><strong :class="payout == null ? 'zero' : 'money'">{{ payout == null ? '—' : cash(payout) }}</strong></span><HouseButton class="ms-foot-end" data-fk="confirm-bet" variant="primary" :busy="busy" :disabled="!!disabledReason || busy" aria-describedby="motorsport-bet-reason" @click="place">Confirm bet</HouseButton></div>
        </template>
        <p v-if="(error || state.error) && (ticket || mode === 'result' || !market?.open)" class="error" role="alert">{{ error || state.error }}</p>
      </div>
    </section>
  </div>
</template>
<script setup>
import {computed, ref, watch, onBeforeUnmount} from 'vue'
import {lua} from '@/bridge'
import '../utils/installLuaBridgeFallbacks.js'
import {HouseButton} from './house/index.js'
import {BngIcon, icons} from '@/common/components/base'
import {vBngTextInput, vBngScopedNav, vBngOnUiNav} from '@/common/directives'
import {useActionFocus} from '../composables/useActionFocus.js'
const props = defineProps({state: Object, watching: Boolean})
const emit = defineEmits(['refresh'])
const root = ref(null), expanded = ref(false), selected = ref(null), stake = ref(500), mode = ref('bet'), error = ref(''), rejectedMarket = ref(null)
const {busy, run} = useActionFocus(root)
const market = computed(() => props.state?.market)
const ticket = computed(() => props.state?.ticket)
const minimum = computed(() => props.state?.minimum || 50)
const balance = computed(() => props.state?.balance || 0)
const balanceShort = computed(() => balance.value < minimum.value || stake.value > balance.value)
const marketMaximum = computed(() => Math.max(0, Math.floor(props.state?.maxBet || 0)))
const maximum = computed(() => Math.min(marketMaximum.value, Math.max(0, Math.floor(balance.value))))
const valid = computed(() => Number.isInteger(stake.value) && stake.value >= minimum.value && stake.value <= maximum.value)
const chosen = computed(() => market.value?.cars?.find(car => car.id === selected.value))
// The header says what the panel is showing, so the body does not repeat it: a settled bet takes its outcome's colour.
const headTitle = computed(() => mode.value === 'result' && props.state?.result
  ? ({ win: 'Bet won', void: 'Bet refunded' })[props.state.result.outcome] || 'Bet lost'
  : ticket.value ? 'Bet placed' : 'Pick your winner')
const headTone = computed(() => mode.value === 'result' && props.state?.result
  ? ({ win: 'ms-tone-go', void: 'ms-tone-wait' })[props.state.result.outcome] || 'ms-tone-blocked'
  : ticket.value ? 'ms-tone-go' : '')
const disabledReason = computed(() => {
  if (props.state?.error) return 'Betting is unavailable while the wallet service recovers.'
  if (!market.value?.open || rejectedMarket.value === market.value?.id) return 'Betting closed. Wait for the next heat.'
  // The limits and the balance are printed just above this line, so it points at them instead of repeating the amounts.
  if (balance.value < minimum.value) return 'Your balance is below the minimum bet.'
  if (!Number.isInteger(stake.value)) return 'Enter a stake in whole dollars.'
  if (stake.value < minimum.value) return 'Stake is below the minimum.'
  if (stake.value > balance.value) return 'Stake is over your balance.'
  if (stake.value > maximum.value) return 'Stake is over the maximum.'
  if (!chosen.value) return 'Pick a car to bet on.'
  return ''
})
const payout = computed(() => valid.value && chosen.value ? Math.floor(stake.value * chosen.value.odds) : null)
const cash = value => `${value < 0 ? '−' : ''}$${Math.abs(value).toLocaleString('en-US')}`
const hideImage = event => { event.target.style.display = 'none' }
const betScope = { scopeId: 'motorsport-bet', activated: true, activateOnMount: true, preferAutoFocus: true, canDeactivate: () => false, trapPolicy: 'always' }
// While the slip is open it tells Lua so once a second. That one call takes the pause and keeps it, and Lua
// lets go after a few silent seconds, so no request ever waits on another. Hiding, betting or unmounting
// tells Lua the slip closed, retried a couple of times. Replies are applied only while they still match
// the slip that sent them. The bridge never rejects, and a Lua error simply never answers, so nothing here
// waits for a reply or a rejection. A slip whose heartbeats go unanswered hides itself, but no sooner than
// Lua's own 5 second watchdog, so a short game stall (an autosave) never ends the pause early.
// Every call carries this slip's own name, so after an overlay remount the old slip's late close cannot
// release the new one.
const slipBeatMs = 1000, slipCloseRetries = 2, slipUnansweredBeatsBeforeHiding = 5
const slipName = `bet-slip-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
const slipOpen = computed(() => expanded.value && mode.value === 'bet' && props.watching && !!market.value?.open
  && !ticket.value && rejectedMarket.value !== market.value?.id)
let slipTimer = null, disposed = false, slipIntent = 0, closeRetriesLeft = 0, unansweredBeats = 0
const motorsport = () => lua.overhaul_events_motorsportEvents
function sendSlipClosed() {
  const intent = slipIntent
  Promise.resolve().then(() => motorsport().closeSpectatorBetSlip(slipName)).then(result => {
    if (result?.ok !== true || intent !== slipIntent) return
    closeRetriesLeft = 0
    syncSlipTimer()
    if (!disposed) emit('refresh')
  }, () => {})
}
function sendSlipOpen() {
  if (disposed || !slipOpen.value) return
  const intent = slipIntent, marketId = market.value.id
  Promise.resolve().then(() => motorsport().openSpectatorBetSlip(marketId, slipName)).then(result => {
    // A reply for a slip that has since closed may have re-taken the pause, so close it once more.
    if (disposed || intent !== slipIntent) { if (disposed || !slipOpen.value) sendSlipClosed(); return }
    unansweredBeats = 0
    if (result?.ok !== true) minimize()
    else if (!market.value?.paused) emit('refresh')
  }, () => {})
}
function slipBeat() {
  if (slipOpen.value) {
    if (++unansweredBeats >= slipUnansweredBeatsBeforeHiding) minimize()
    else sendSlipOpen()
  } else if (closeRetriesLeft > 0) { closeRetriesLeft--; sendSlipClosed() }
  syncSlipTimer()
}
function syncSlipTimer() {
  const needed = !disposed && (slipOpen.value || closeRetriesLeft > 0)
  if (needed && slipTimer === null) slipTimer = setInterval(slipBeat, slipBeatMs)
  else if (!needed && slipTimer !== null) { clearInterval(slipTimer); slipTimer = null }
}
watch(slipOpen, open => {
  slipIntent++
  unansweredBeats = 0
  closeRetriesLeft = open ? 0 : slipCloseRetries
  if (open) sendSlipOpen()
  else sendSlipClosed()
  syncSlipTimer()
})
onBeforeUnmount(() => {
  disposed = true
  slipIntent++
  clearInterval(slipTimer)
  slipTimer = null
  // One last close; if it is lost, the silence makes Lua let go.
  if (slipOpen.value || closeRetriesLeft > 0) sendSlipClosed()
})
const minimize = event => { event?.stopPropagation?.(); expanded.value = false; return false }
function show(value) { mode.value = value; error.value = ''; expanded.value = true }
function step(delta) { stake.value = Math.min(maximum.value, Math.max(minimum.value, (Number(stake.value) || minimum.value) + delta)) }
watch(() => market.value?.id, () => { selected.value = null; rejectedMarket.value = null; error.value = ''; stake.value = Math.min(500, maximum.value); if (mode.value !== 'result') minimize() })
watch(() => market.value?.open, open => { if (!open && mode.value !== 'result') minimize() })
watch(() => props.watching, watching => { if (!watching) minimize() })
watch(() => props.state?.result?.id, id => { if (id && props.watching) show('result') })
async function place() {
  if (disabledReason.value || busy.value) return
  const marketId = market.value.id, carId = selected.value, amount = stake.value
  await run(async () => {
    error.value = ''
    try {
      const result = await motorsport().placeSpectatorBet(marketId, carId, amount)
      if (!result?.ok) {
        error.value = result?.error || "Couldn't place the bet. Wait for the next heat."
        // Only the owner can confirm a refusal happened before ticket creation.
        if (result?.retryable !== true) rejectedMarket.value = marketId
      }
      else mode.value = 'ticket'
    } catch (_) { error.value = "Couldn't confirm the bet. Check View bet before placing another."; rejectedMarket.value = marketId }
    emit('refresh')
  })
}
</script>
<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss' as *;
@use '@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss' as ms;
// The panel belongs to the dock, leaving the centre of the track visible.
.betting { @include ms.ms-scale-overlay; --bet-pad: 1.3rem; font-variant-numeric: tabular-nums; }
.bet-entry { pointer-events: auto; }
.bet-backdrop { position: absolute; bottom: calc(100% + .75em); left: 0; width: min(42em, calc(100vw - 4rem)); z-index: 1010; }
.bet-panel { width: min(42em, 100%); max-height: calc(100vh - 16rem); overflow: hidden auto; background: var(--page); border-radius: var(--radius-panel); box-shadow: inset 0 0 0 1px rgba(255, 255, 255, .07), 0 1em 3em rgba(0, 0, 0, .6); }
.bet-panel > * { margin-left: var(--bet-pad); margin-right: var(--bet-pad); }
.bet-head, .stake-line { display: flex; justify-content: space-between; align-items: center; gap: 1em; }
// A plain header: what the panel shows, then how long the market stays open.
.bet-head { margin: 0 0 .9em; padding: .9em var(--bet-pad) 0; }
.bet-head h2 { margin: 0; font-size: 1.25em; font-weight: 800; letter-spacing: -.01em; color: var(--tone, #fff); }
.betting .ms-label { display: block; }
.betting .ms-label.short { color: var(--bad); }
.time { font-family: var(--ms-time-font); font-weight: 700; letter-spacing: -.03em; word-spacing: -.22em; font-variant-numeric: tabular-nums; }
.timer { display: flex; align-items: baseline; gap: .5em; color: var(--muted); font-weight: 600; }
.timer .time { font-size: 1.35em; line-height: 1; color: #fff; }
.timer.soon .time { color: var(--ms-stop); }
.timer .paused { font-weight: 800; }
small { display: block; color: var(--muted); font-size: max(12px, .85em); font-weight: 400; line-height: 1.4; }
// The two lanes side by side. The pick is a fill and a filled chip, never a ring.
.cars { display: grid; grid-template-columns: 1fr 1fr; gap: .6em; }
.car { display: block; min-width: 0; padding: 0; overflow: hidden; border-radius: var(--radius-tile); background: var(--panel); text-align: left; white-space: normal; }
.car :deep(.btn-label) { display: block; width: 100%; white-space: normal; }
.car.selected { background: color-mix(in srgb, var(--accent) 20%, var(--panel)); }
// The game's config previews are 800 by 448, so the photo box takes that shape and shows the whole car.
// A mod's odd-sized preview is letterboxed on the photo backdrop rather than cropped.
.car img, .no-photo { display: block; width: 100%; aspect-ratio: 800 / 448; object-fit: contain; background: var(--photo); }
.no-photo { display: grid; place-items: center; font-size: 1.6em; color: var(--faint); }
.car-copy { padding: .7em .85em .8em; }
.name-row { display: flex; align-items: center; justify-content: space-between; gap: .5em; min-height: 1.5em; }
.picked { padding: .2em .55em .1em; border-radius: var(--radius-pill); background: var(--accent); color: #17130a; font-size: max(12px, .76em); font-weight: 800; }
.car-name { min-width: 0; font-size: 1.12em; font-weight: 800; line-height: 1.2; }
.numbers { display: flex; justify-content: space-between; align-items: end; gap: .4em; margin-top: .8em; }
.numbers strong { display: block; font-size: 1.35em; line-height: 1.2; }
.numbers .pays { text-align: right; }
.numbers .pays strong { color: var(--money); font-weight: 800; }
// Limits and the stake as labelled values; the return is the biggest number on the panel.
.limits { display: flex; gap: 0; margin: 1em var(--bet-pad) 0; }
.limits > div { flex: 1 1 0; display: grid; gap: .15em; padding: 0 .9em; border-left: 1px solid var(--line); }
.limits > div:first-child { padding-left: 0; border-left: 0; }
.limits dd, .summary dd { margin: 0; font-size: 1.1em; font-weight: 800; }
.money { color: var(--money); }
.zero { color: var(--muted) !important; }
.stake-line { margin-top: 1em; margin-bottom: .2em; }
// The stake is money like every other amount on the slip.
.stake-line .field { width: 5em; text-align: center; color: var(--money); font-weight: 800; }
.stake-line .money { font-weight: 800; line-height: 1; transform: translateY(.06em); }
.validation { min-height: 1.5em; margin-top: .5em; margin-bottom: .7em; color: var(--warn); }
.error, .summary .loss { color: var(--bad); }
// Every view of the slip ends in one line: its amounts as a label beside each value, then the one button.
.bet-footer { margin-bottom: 1.1em; padding-top: .9em; border-top: 1px solid var(--line); }
.bet-footer .return, .summary > div { display: flex; align-items: baseline; gap: .5em; min-width: 0; }
.bet-footer .return strong, .summary .lead dd { font-size: 1.6em; font-weight: 800; line-height: 1.1; letter-spacing: -.02em; }
.summary { display: flex; align-items: baseline; gap: 1.4em; margin: 0; min-width: 0; }
.validation.hint { font-size: max(12px, .86em); color: var(--faint); }
// Ticket and result.
.receipt { display: grid; justify-items: start; gap: .3em; padding-bottom: 1em; }
.receipt img { width: 16em; max-width: 100%; border-radius: var(--radius-thumb); }
.receipt h3 { margin: .2em 0 0; font-size: 1.3em; font-weight: 800; }
.receipt p { margin: 0; color: var(--muted); }
</style>
