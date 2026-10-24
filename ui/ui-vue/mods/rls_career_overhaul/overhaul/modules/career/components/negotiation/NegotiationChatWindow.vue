<!-- Shared negotiation chat (vehicle, real estate, phone marketplace). Presentational: the host passes the
     negotiation state and does the Lua calls on send / accept / walk-away / resolve.
     Layout: one compact header (photo as avatar, the other party, what's being sold, patience), the
     conversation (their opening statement + price first, then every offer / counter as a bubble with varied
     wording) and a composer (shortcut row, offer text box + Send, Walk away / Buy-or-Sell for their price).
     The host's limits are kept: you can't offer past their price or back past your last offer. -->
<template>
  <!-- Controller (full-screen window only; the phone host has its own back handling): the window is its
       own nav scope, active on entry with focus on a sensible control, and B is the header Close. -->
  <div class="rls-house nego" :class="{ compact }" v-bng-scoped-nav="compact ? null : navScope">
    <!-- who you're talking to, about what -->
    <header class="nego-head">
      <div class="subject-photo">
        <img v-if="thumbnail && !thumbBroken" :src="thumbnail" alt="" @error="thumbBroken = true" />
        <BngIcon v-else class="subject-fallback" :type="fallbackIcon || icons.car" />
      </div>
      <div class="who">
        <strong class="who-name">{{ opponentName }}</strong>
        <span class="who-subject">{{ subjectName }}</span>
        <span v-if="meta.length || marketValue != null" class="who-meta">
          <span v-for="(m, i) in meta" :key="i"><BngIcon v-if="m.icon" :type="m.icon" />{{ m.text }}</span>
          <span v-if="marketValue != null">Est. market <span class="amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(marketValue) }}</span></span>
        </span>
      </div>
      <div v-if="!isResolved" class="patience" :class="patienceTone" v-bng-tooltip="`${amISelling ? 'Buyer' : 'Seller'}'s patience`">
        <span class="caption">Patience</span>
        <span class="patience-bar"><span :style="{ transform: `scaleX(${patienceFraction})` }" /></span>
      </div>
      <HouseButton
        v-if="showClose"
        class="close"
        variant="quiet"
        compact
        :icon="icons.xmark"
        aria-label="Close"
        :disabled="busy"
        bng-no-nav="true"
        :tabindex="-1"
        @click="emit('close')" />
    </header>

    <!-- the conversation -->
    <div ref="chatEl" class="chat scroll" v-bng-ui-nav-scroll.force>
      <div v-for="msg in messages" :key="msg.key" class="msg" :class="[msg.from, msg.tone]">
        <div class="bubble">
          <p v-if="msg.text" class="msg-text">{{ msg.text }}</p>
          <p v-if="msg.amount != null" class="msg-line">{{ msg.pre }}<span class="amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(msg.amount) }}</span>{{ msg.post }}</p>
        </div>
      </div>
      <div v-if="isTyping" class="msg them typing">
        <div class="bubble"><span class="dots"><i /><i /><i /></span></div>
      </div>
    </div>

    <!-- composer -->
    <footer class="composer">
      <template v-if="!isResolved">
        <p v-if="status === 'counterOfferLastChance'" class="notice warn">
          That's their final offer. Accept it or walk away.
        </p>

        <!-- A shortcut that would not change the offer is only dimmed ("off"), not disabled: disabling the
             button you just pressed drops controller focus. -->
        <div v-if="quickOffers.length" class="seg bar quick">
          <button
            v-for="q in quickOffers"
            :key="q.id"
            type="button"
            bng-nav-item
            :class="{ off: q.value == null || Number(q.value) === Number(preview) }"
            :aria-disabled="q.value == null || Number(q.value) === Number(preview) ? 'true' : null"
            :disabled="composerDisabled"
            :bng-scoped-nav-autofocus="autofocusKey === `quick:${q.id}` ? '' : null"
            v-bng-tooltip="`${q.tip}: ${moneyText(units, q.value || 0, { decimals: 0 })}`"
            @click="setOffer(q.value)">
            {{ q.label }}
          </button>
        </div>

        <!-- step the offer up or down without typing (controller friendly); same limits as the box -->
        <div v-if="!compact && stepButtons.length" class="seg bar steps">
          <button
            v-for="s in stepButtons"
            :key="s.id"
            type="button"
            bng-nav-item
            :class="{ off: s.value === Number(preview) }"
            :aria-disabled="s.value === Number(preview) ? 'true' : null"
            :disabled="composerDisabled"
            :bng-scoped-nav-autofocus="autofocusKey === `step:${s.id}` ? '' : null"
            @click="setOffer(s.value)">
            {{ s.label }}
          </button>
        </div>

        <div class="offer-row">
          <label data-focus-field class="offer-field" :class="{ disabled: composerDisabled }">
            <BngIcon class="currency" :type="icons.beamCurrency" />
            <input
              :value="offerText"
              type="text"
              inputmode="numeric"
              aria-label="Your offer"
              :disabled="composerDisabled"
              v-bng-text-input
              @input="onInput"
              @focus="onFocus"
              @blur="onBlur"
              @keydown.enter.stop.prevent="send"
              @keydown.stop
              @keyup.stop
              @keypress.stop />
          </label>
          <!-- While they reply, Send only dims (send() ignores it): disabling the button you just pressed
               would drop controller focus onto whatever is nearest, e.g. Walk away. -->
          <HouseButton
            variant="primary"
            :class="{ off: isTyping }"
            :aria-disabled="sendDisabled ? 'true' : null"
            :disabled="sendDisabled && !isTyping"
            :bng-scoped-nav-autofocus="autofocusKey === 'send' ? '' : null"
            @click="send">
            {{ compact ? "Send" : awaitingOpening ? "Send opening offer" : "Send offer" }}
          </HouseButton>
        </div>

        <div class="decide">
          <HouseButton variant="quiet-danger" :disabled="busy" @click="emit('walk-away')">
            Walk away
          </HouseButton>
          <!-- hold to accept; ok.asMouse turns a held A into the mouse hold v-bng-click listens for -->
          <HouseButton
            v-if="!awaitingOpening"
            class="accept"
            binding="ok"
            :disabled="acceptDisabled"
            :bng-scoped-nav-autofocus="autofocusKey === 'accept' ? '' : null"
            v-bng-tooltip="'Hold to accept'"
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-click="{ holdCallback: () => emit('accept'), holdDelay: 1000, repeatInterval: 0 }">
            {{ amISelling ? "Sell for" : "Buy for" }}
            <span class="amt accept-amount"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(theirOffer || 0) }}</span>
          </HouseButton>
        </div>
      </template>

      <!-- deal done / no deal -->
      <template v-else>
        <div class="resolved" :class="resolvedTone">
          <BngIcon :type="resolvedTone === 'ok' ? icons.checkmark : icons.abandon" class="resolved-icon" />
          <div class="resolved-copy">
            <strong>{{ resolvedTitle }}<template v-if="resolvedTitleAmount != null">{{ ' ' }}<MoneyAmount>{{ moneyText(units, resolvedTitleAmount) }}</MoneyAmount></template></strong>
            <span v-if="resolvedText">{{ resolvedText }}<template v-if="resolvedAmount != null"> <span class="amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(resolvedAmount) }}</span></template></span>
          </div>
        </div>
        <div class="decide">
          <HouseButton
            variant="primary"
            :disabled="busy"
            :bng-scoped-nav-autofocus="autofocusKey === 'resolve' ? '' : null"
            @click="emit('resolve')">
            {{ resolvedAction }}
          </HouseButton>
        </div>
      </template>
    </footer>
  </div>
</template>

<script setup>
import MoneyAmount from "../MoneyAmount.vue"
import { safeLua } from "../../utils/safeLua.js"

import { computed, nextTick, ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngClick, vBngOnUiNav, vBngScopedNav, vBngTextInput, vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import { moneyText } from "../../utils/units"
import { HouseButton } from "../house/index.js"
import { buildConversation } from "./negotiationConversation.js"

const props = defineProps({
  opponentName: { type: String, default: "Seller" },
  subjectName: { type: String, default: "" },
  thumbnail: String,
  // as BngIcon takes it: callers pass an icons.* entry (object) or a name
  fallbackIcon: [String, Object],
  // [{ icon?, text }] faint facts under the subject name
  meta: { type: Array, default: () => [] },
  // null hides the market value (and the market-based shortcuts)
  marketValue: { type: Number, default: null },
  patience: { type: Number, default: 1 },
  quote: String,
  history: { type: Array, default: () => [] },
  status: { type: String, default: "" },
  amISelling: Boolean,
  theirOffer: { type: Number, default: 0 },
  myOffer: { type: Number, default: null },
  startingPrice: { type: Number, default: 0 },
  hasVisibleTheirOffer: { type: Boolean, default: true },
  // the other party hasn't named a price: you send the first number
  awaitingOpening: Boolean,
  // base unit for the step buttons (vehicles 50, property 1000); offers themselves are not rounded to it
  step: { type: Number, default: 50 },
  // step button sizes (small, large); defaults to 10x and 100x the step (vehicles: 500 / 5,000)
  stepSizes: { type: Array, default: null },
  busy: Boolean,
  resolvedTitle: String,
  resolvedTitleAmount: { type: Number, default: null },
  resolvedText: String,
  resolvedTone: { type: String, default: "ok" },
  resolvedAction: { type: String, default: "Continue" },
  resolvedAmount: { type: Number, default: null },
  showClose: { type: Boolean, default: true },
  scopeId: { type: String, default: "vehicleNegotiation" },
  // phone: fill the host instead of being a centred window
  compact: Boolean,
})
const emit = defineEmits(["send", "accept", "walk-away", "resolve", "close"])

const { units } = useBridge()
const chatEl = ref(null)
const thumbBroken = ref(false)
watch(() => props.thumbnail, () => (thumbBroken.value = false))

const isResolved = computed(() => props.status === "accepted" || props.status === "failed")
const isTyping = computed(() => props.status === "typing" || props.status === "thinking")
const patienceFraction = computed(() => Math.max(0, Math.min(1, Number(props.patience) || 0)))
const patienceTone = computed(() => (patienceFraction.value > 0.66 ? "patience-good" : patienceFraction.value > 0.33 ? "patience-mid" : "patience-bad"))
const blocked = computed(() => props.busy || isTyping.value || isResolved.value)

const wholeMoney = v => Math.round(Number(v) || 0).toLocaleString()
// offers are plain whole numbers (never snapped to the step), never negative
const round = v => Math.max(0, Math.round(Number(v) || 0))

// ---- conversation ---------------------------------------------------------------------------------
const messages = computed(() => buildConversation(props))

const scrollChatToBottom = () => nextTick(() => {
  const el = chatEl.value
  if (el) el.scrollTop = el.scrollHeight
})
watch(() => [messages.value.length, isTyping.value], scrollChatToBottom, { immediate: true })

// ---- composer ---------------------------------------------------------------------------------------
const preview = ref(0)
const offerText = ref("0")
const focused = ref(false)

// follow the negotiation: your last offer, else their starting price (opening offers start empty)
watch(
  () => [props.myOffer, props.startingPrice, props.status, props.awaitingOpening],
  () => {
    if (props.awaitingOpening) {
      if (!focused.value && !(preview.value > 0)) preview.value = 0
    } else if (props.status === "failed") {
      preview.value = Number(props.startingPrice) || 0
    } else {
      const base = props.myOffer != null ? props.myOffer : props.startingPrice
      if (!Number.isNaN(Number(base))) preview.value = Number(base)
    }
  },
  { immediate: true }
)
watch(preview, v => {
  if (!focused.value) offerText.value = wholeMoney(v)
}, { immediate: true })

const clampOffer = value => {
  const rounded = round(value)
  if (props.awaitingOpening) return rounded
  let min = 0
  let max = Number.POSITIVE_INFINITY
  if (props.amISelling) {
    min = props.theirOffer
    if (props.myOffer != null) max = props.myOffer
  } else {
    max = props.hasVisibleTheirOffer ? props.theirOffer : Number.POSITIVE_INFINITY
    if (props.myOffer != null) min = props.myOffer
  }
  return Math.min(max, Math.max(min, rounded))
}

const setOffer = value => {
  if (value == null) return
  preview.value = clampOffer(value)
  offerText.value = focused.value ? String(preview.value) : wholeMoney(preview.value)
}

const onInput = event => {
  const digits = String(event.target.value || "").replace(/[^\d]/g, "")
  offerText.value = digits
  preview.value = digits === "" ? 0 : Number(digits)
}
const onFocus = event => {
  focused.value = true
  offerText.value = preview.value ? String(Math.round(Number(preview.value) || 0)) : ""

  if (event?.target?.select) nextTick(() => event.target.select())
}
const onBlur = () => {
  focused.value = false

  setOffer(preview.value)
}

const composerDisabled = computed(() => blocked.value || props.status === "counterOfferLastChance")
const sendDisabled = computed(() => {
  if (props.awaitingOpening) return blocked.value || !(Number(preview.value) > 0)
  const p = clampOffer(preview.value)
  return composerDisabled.value || p == props.theirOffer || p == props.myOffer
})
// their final offer can still be accepted (Lua takes it); only countering is locked
const acceptDisabled = computed(() => blocked.value || !props.hasVisibleTheirOffer)

const send = () => {
  if (sendDisabled.value) return
  setOffer(preview.value)
  emit("send", Number(preview.value), { opening: !!props.awaitingOpening })
}

// negotiating shortcuts (buying: lower is better; selling: higher is better), through the same limits
const quickOffers = computed(() => {
  const selling = !!props.amISelling
  const theirs = Number(props.theirOffer) || 0
  const market = props.marketValue != null ? Number(props.marketValue) || 0 : 0
  const mine = props.myOffer != null ? Number(props.myOffer) : null

  if (props.awaitingOpening) {
    if (!market) return []
    return [
      { id: "low", label: "Lowball", value: round(market * 0.7), tip: "70% of market value" },
      { id: "fair", label: "Fair", value: round(market * 0.9), tip: "90% of market value" },
      { id: "market", label: "Market", value: round(market), tip: "Market value" },
    ]
  }
  if (!props.hasVisibleTheirOffer) return []
  const dir = selling ? 1 : -1
  // Percent steps start from the offer in the box, so pressing again keeps going until the limit.
  const current = Number(preview.value) || theirs
  const list = []
  if (mine != null) list.push({ id: "mid", label: "Halfway", value: clampOffer((mine + theirs) / 2), tip: "Halfway between your offer and theirs" })
  list.push({ id: "5", label: selling ? "+5%" : "-5%", value: clampOffer(current * (1 + dir * 0.05)), tip: selling ? "5% above your offer" : "5% under your offer" })
  list.push({ id: "10", label: selling ? "+10%" : "-10%", value: clampOffer(current * (1 + dir * 0.1)), tip: selling ? "10% above your offer" : "10% under your offer" })
  if (market) list.push({ id: "market", label: "Market", value: clampOffer(market), tip: "Market value" })
  return list
})

// -big -small +small +big, each applied to the current offer and kept inside the negotiation's limits
const stepButtons = computed(() => {
  const sizes = Array.isArray(props.stepSizes) && props.stepSizes.length ? props.stepSizes : [props.step * 10, props.step * 100]
  const [small, large] = [Math.min(...sizes), Math.max(...sizes)]
  const current = Number(preview.value) || 0
  const fmt = n => Number(n).toLocaleString()
  const at = delta => clampOffer(Math.max(0, current + delta))
  const list = [
    { id: "-l", label: `-${fmt(large)}`, value: at(-large) },
    { id: "-s", label: `-${fmt(small)}`, value: at(-small) },
    { id: "+s", label: `+${fmt(small)}`, value: at(small) },
    { id: "+l", label: `+${fmt(large)}`, value: at(large) },
  ]
  return small === large ? list.filter(x => x.id.endsWith("s")) : list
})

// ---- controller -------------------------------------------------------------------------------------
// Where focus lands when the window opens or when the focused control goes away (Send greys out while
// they reply, the composer swaps for the result): Continue once resolved, else the first shortcut that
// would change the offer, else Accept / Send.
const autofocusKey = computed(() => {
  if (isResolved.value) return "resolve"
  if (!composerDisabled.value) {
    const live = item => item.value != null && Number(item.value) !== Number(preview.value)
    const q = quickOffers.value.find(live)
    if (q) return `quick:${q.id}`
    const s = !props.compact && stepButtons.value.find(live)
    if (s) return `step:${s.id}`
  }
  // their final offer: Accept (a hold, so a stray A does nothing); while they type: the dimmed Send
  return !props.awaitingOpening && !acceptDisabled.value ? "accept" : "send"
})
// B = the header Close (the host cancels / leaves); never the router's plain back, which skips the
// host's cleanup. Ignored while a deal is being settled.
// The id matches the hosts' legacy UI scope name, so presses made while nothing is focused still reach it.
const navScope = {
  scopeId: props.scopeId,
  activateOnMount: true,
  canDeactivate: () => {
    if (!props.busy) emit("close")
    return false
  },
}

defineExpose({ scrollChatToBottom, setOffer })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* one near-black chat window, em off a resolution-scaled font */
.nego {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  width: min(36em, 94vw);
  height: min(48em, 88vh);
  color: #fff;
  border-radius: var(--radius-control);
  overflow: hidden;
  background: rgba(21, 21, 23, 0.95);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  // phone: fills the phone screen at a phone-sized type scale; the host pads the header below its status bar
  &.compact {
    font-size: 12px;
    width: 100%;
    height: 100%;
    border-radius: 0;
    background: transparent;
    box-shadow: none;
    .nego-head {
      gap: 0.6em;
      padding: var(--nego-head-top, 0.8em) 0.9em 0.7em;
    }
    .patience-bar {
      width: 3.6em;
    }
    .chat {
      padding: 0.8em 0.7em 0.8em 0.9em;
    }
    .composer {
      padding: 0.6em 0.8em 0.8em;
    }
    .decide > .house-button {
      flex: 1 1 0;
      min-width: 0;
    }
  }
}

/* ---- header: photo as the avatar, the other party, what's being sold, patience */
.nego-head {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.8em;
  padding: 0.8em 0.7em 0.8em 0.9em;
  border-bottom: 1px solid var(--line);
}
.subject-photo {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 6em;
  aspect-ratio: 16 / 10;
  border-radius: var(--radius-tile);
  overflow: hidden;
  background: var(--panel);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .compact & {
    width: 4.5em;
  }
}
.subject-fallback {
  font-size: 1.5em;
  color: rgba(255, 255, 255, 0.3);
}
.who {
  flex: 1 1 auto;
  display: grid;
  gap: 0.12em;
  min-width: 0;
}
.who-name {
  font-size: 1.1em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.who-subject {
  color: rgba(255, 255, 255, 0.82);
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.25;
  overflow-wrap: anywhere;
}
.who-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.2em 0.9em;
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  > span > :deep(.bng-icon:first-child) {
    margin-right: 0.3em;
  }
}
.patience {
  flex: 0 0 auto;
  display: grid;
  justify-items: end;
  gap: 0.3em;
  .caption {
    font-size: 0.68em;
  }
}
.patience-bar {
  position: relative;
  width: 5em;
  height: 0.3em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);
  > span {
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background: rgba(255, 255, 255, 0.6);
    transform-origin: left center;
    transition: transform 0.3s ease-out;
  }
  .patience-mid & > span {
    background: var(--warn);
  }
  .patience-bad & > span {
    background: var(--bad);
  }
}

/* ---- money inline in text: coin glyph + whole number on the text line */
.amt {
  display: inline;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-icon) {
    display: inline-block;
    margin-right: 0.15em;
    font-size: 0.95em;
    line-height: 1;
    vertical-align: -0.1em;
    color: var(--money);
  }
}

/* ---- chat */
.chat {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 0.7em;
  padding: 1em 0.8em 1em 1em;
}
.msg {
  display: grid;
  gap: 0.25em;
  max-width: 78%;
  animation: msg-in 0.18s ease-out;
  &.them {
    align-self: flex-start;
    justify-items: start;
  }
  &.me {
    align-self: flex-end;
    justify-items: end;
  }
  .compact & {
    max-width: 86%;
  }
}
@keyframes msg-in {
  from {
    opacity: 0;
    transform: translateY(0.4em);
  }
  to {
    opacity: 1;
    transform: none;
  }
}
@media (prefers-reduced-motion: reduce) {
  .msg {
    animation: none;
  }
}
.bubble {
  display: grid;
  gap: 0.3em;
  padding: 0.6em 0.85em 0.55em;
  border-radius: 0.9em;
  line-height: 1.35;
  .them & {
    background: var(--panel-2);
    border-top-left-radius: 0.3em;
  }
  .me & {
    background: rgba(255, 102, 0, 0.16);
    box-shadow: inset 0 0 0 1px rgba(255, 178, 122, 0.18);
    border-top-right-radius: 0.3em;
  }
  .final & {
    box-shadow: inset 0 0 0 1px rgba(251, 191, 36, 0.35);
  }
  .deal & {
    box-shadow: inset 0 0 0 1px rgba(134, 239, 172, 0.35);
  }
  .failed & {
    box-shadow: inset 0 0 0 1px rgba(252, 165, 165, 0.35);
  }
}
.msg-text {
  margin: 0;
  color: rgba(255, 255, 255, 0.72);
  font-weight: 600;
}
.msg-line {
  margin: 0;
  color: #fff;
  font-size: 1.05em;
  font-weight: 700;
}
.typing .bubble {
  padding: 0.75em 0.9em;
}
.dots {
  display: inline-flex;
  gap: 0.3em;
  i {
    width: 0.4em;
    height: 0.4em;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.55);
    animation: dot 1.1s ease-in-out infinite;
  }
  i:nth-child(2) {
    animation-delay: 0.15s;
  }
  i:nth-child(3) {
    animation-delay: 0.3s;
  }
}
@keyframes dot {
  0%,
  80%,
  100% {
    opacity: 0.35;
    transform: translateY(0);
  }
  40% {
    opacity: 1;
    transform: translateY(-0.2em);
  }
}

/* ---- composer */
.composer {
  flex: 0 0 auto;
  display: grid;
  gap: 0.6em;
  padding: 0.8em 1em 1em;
  border-top: 1px solid var(--line);
}
.quick,
.steps {
  display: flex;
  button {
    flex: 1 1 0;
    font-size: 0.9em;
    font-variant-numeric: tabular-nums;
  }
  // would not change the offer: dimmed but still focusable (see the template)
  button.off {
    opacity: 0.45;
    cursor: default;
  }
}
.offer-row {
  display: flex;
  gap: 0.5em;
  align-items: stretch;
  > .house-button {
    flex: 0 0 auto;
  }
  // waiting for their reply: looks disabled, keeps focus
  > .house-button.off {
    opacity: 0.45;
    cursor: default;
  }
}
.offer-field {
  flex: 1 1 auto;
  display: flex;
  align-items: center;
  gap: 0.4em;
  min-width: 0;
  padding: 0 0.75em;
  border-radius: var(--radius-control);
  background: rgba(0, 0, 0, 0.3);
  box-shadow: inset 0 0 0 1px var(--line);
  &:focus-within {
    box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.6);
  }
  &.disabled {
    opacity: 0.5;
  }
  .currency {
    flex: 0 0 auto;
    color: var(--money);
    font-size: 1.05em;
  }
  input {
    flex: 1 1 auto;
    min-width: 0;
    padding: 0.55em 0 0.45em;
    border: 0;
    outline: none;
    background: transparent;
    color: var(--money);
    font: inherit;
    font-size: 1.1em;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }
}
.decide {
  display: flex;
  justify-content: space-between;
  gap: 0.5em;
  > :only-child {
    margin-left: auto;
  }
}
// accept label as a centred row (text, coin, number) so the inline coin doesn't push the text down
.accept :deep(.btn-label) {
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
}
.accept .accept-amount {
  display: inline-flex;
  align-items: center;
  :deep(.bng-icon) {
    margin-right: 0.15em;
    vertical-align: 0;
    transform: translateY(-0.08em);
  }
}
.notice {
  margin: 0;
}

.resolved {
  display: flex;
  align-items: center;
  gap: 0.8em;
  padding: 0.7em 0.85em;
  border-radius: var(--radius-panel);
  &.ok {
    background: rgba(74, 222, 128, 0.1);
    .resolved-icon,
    strong {
      color: var(--ok-ink);
    }
  }
  &.bad {
    background: rgba(252, 165, 165, 0.1);
    .resolved-icon,
    strong {
      color: var(--bad);
    }
  }
}
.resolved-icon {
  flex: 0 0 auto;
  font-size: 1.6em;
}
.resolved-copy {
  display: grid;
  gap: 0.15em;
  strong {
    font-size: 1.1em;
    font-weight: 800;
  }
  > span {
    color: var(--muted);
    font-weight: 600;
  }
}
</style>
