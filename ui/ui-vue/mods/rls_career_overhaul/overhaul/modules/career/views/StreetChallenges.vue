<template>
  <div class="challenge-screen rls-house rls-house-card" v-bng-on-ui-nav:back,menu="onNavClose">
    <NegotiationChatWindow
      v-if="negotiationOpen"
      scope-id="carMeetRaceNegotiation"
      :opponent-name="s.talk?.owner || 'Race challenger'"
      :subject-name="'Race against ' + (s.talk?.name || 'their car')"
      :meta="[{ text: 'Nearest venue: ' + s.offer.venue.name }, { text: 'Your car: ' + (s.car?.name || 'entered vehicle') }]"
      :patience="negotiation.patience / negotiation.maxPatience"
      :patience-label="(s.talk?.owner || 'Challenger') + '’s patience'"
      :history="negotiation.history"
      :status="negotiation.status"
      :their-offer="s.offer.kind === 'boss' ? 0 : s.offer.amount"
      :starting-price="s.offer.amount"
      :busy="busy"
      close-while-busy
      :resolved-title="negotiation.status === 'failed' ? 'No race agreed.' : s.offer.kind === 'boss' ? 'Pink slips agreed.' : 'Cash race agreed.'"
      :resolved-tone="negotiation.status === 'failed' ? 'bad' : 'ok'"
      :resolved-text="negotiation.status === 'failed' ? 'The owner has ended the discussion.' : 'Bring the agreed car to ' + s.offer.venue.name + ' within 30 minutes. The stake takes effect when the race starts.'"
      :resolved-action="negotiation.status === 'failed' ? 'Back to the meet' : 'Agree and set route'"
      @accept="accept"
      @resolve="resolveNegotiation"
      @walk-away="call('cancel')"
      @close="onNavClose">
      <template #notice>
        <div class="race-notices">
          <p v-if="error || s.error" class="notice bad" role="alert">{{ error || s.error }}</p>
          <p v-if="s.offer.kind === 'boss' || proposalKind === 'boss'" class="notice warn">Lose and you give up your entered car. Win and you receive their car as raced, uninsured.</p>
          <p v-if="s.talk?.winBackId" class="notice">Win a pink-slip race to reclaim your former car. A cash race pays money only.</p>
        </div>
      </template>
      <template #offer-controls="{ disabled }">
        <fieldset class="race-proposal stack" :disabled="busy || disabled">
          <div class="venue-label"><span>Your proposal</span><HouseMenu v-model="proposalKind" :items="[{value: 'cash', label: 'Cash race'}, {value: 'boss', label: 'Pink slips'}]" :disabled="busy || disabled" /></div>
          <HouseAmountField v-if="proposalKind === 'cash'" v-model="proposalAmount" label="Wager per driver" :min="negotiation.minCashWagerMoney" :max="negotiation.maxCashWagerMoney" :step="negotiation.cashWagerStepMoney" :disabled="busy || disabled" allow-text money />
          <HouseButton variant="primary" bng-scoped-nav-autofocus :disabled="busy || disabled" @click="propose">Send proposal</HouseButton>
        </fieldset>
      </template>
      <template #accept-terms>{{ s.offer.kind === 'boss' ? 'Race for pink slips' : 'Race for ' + cash(s.offer.amount) + ' each' }}</template>
    </NegotiationChatWindow>
    <section class="challenge-shell panel stack" v-else-if="s">
      <header class="header">
        <div><span class="kicker">Car Meet</span><h1>{{ s.talk?.owner || "Race Challenge" }}</h1><p class="muted">{{ s.talk?.name }}</p></div>
        <HouseButton v-if="!s.handover" variant="quiet" @click="call('close')">Return to driving</HouseButton>
      </header>
      <p v-if="error || s.error" class="notice bad">{{ error || s.error }}</p>
      <p v-if="s.talk?.winBackId && !s.result && !s.race && !s.handover" class="notice">Your former {{ s.talk.name }}. Win a pink-slip race to reclaim it; a cash race pays money only.</p>
      <section v-if="s.handover" class="stack">
        <h2>You lost the pink-slip race</h2><p>The keys belong to {{ s.handover.name }}. Give up your entered car to continue.</p>
        <HouseButton variant="primary" :disabled="busy" @click="call('giveUpCar')">Give up car</HouseButton>
      </section>
      <section v-else-if="s.warning" class="stack">
        <h2>Forfeit this race?</h2><p>If you {{ s.warning.label }}, you lose {{ s.warning.stake }}.</p>
        <div class="actions"><HouseButton variant="quiet-danger" @click="call('confirmAction')">Forfeit and continue</HouseButton><HouseButton variant="primary" @click="call('cancelAction')">Keep racing</HouseButton></div>
      </section>
      <section v-else-if="s.result" class="stack">
        <h2>{{ s.result.outcome === 'win' ? 'You won' : s.result.outcome === 'void' ? 'Race cancelled' : 'You lost' }}</h2>
        <p>Result: {{ s.result.reason }}</p><p>Stake: {{ s.result.kind === 'boss' ? 'Pink slips' : cash(s.result.amount) }}</p><p>Opponent: {{ s.result.opponent }}</p>
        <div v-if="s.canReturnToMeet" class="actions"><HouseButton variant="primary" :disabled="busy" @click="call('returnToMeet')">Return to meet</HouseButton></div>
      </section>
      <section v-else-if="s.race" class="stack">
        <h2>{{ s.race.phase }}</h2><p>Stage in your lane and wait for green.</p>
        <HouseButton variant="quiet-danger" @click="call('cancel')">Abandon race</HouseButton>
      </section>
      <section v-else-if="s.pending" class="stack">
        <h2>Your opponent is waiting</h2><p>Opponent: {{ s.pending.owner }}</p><p>Venue: {{ s.pending.venue.name }}</p>
        <p>Drive there in the agreed car, then start the race. Your stake is charged when the race starts.</p>
        <p class="muted">{{ Math.ceil(s.pending.remaining / 60) }} minutes remaining.</p>
        <div class="actions"><HouseButton variant="primary" @click="call('route')">Set route</HouseButton><HouseButton variant="primary" @click="call('startRace')">Start race at venue</HouseButton><HouseButton variant="quiet-danger" @click="call('cancel')">Cancel challenge</HouseButton></div>
      </section>
      <section v-else-if="s.offer" class="stack">
        <h2>{{ s.offer.direction === 'incoming' ? 'They want to race you' : 'Their terms' }}</h2>
        <p>The owner is sizing up both cars…</p>
      </section>
      <section v-else class="stack">
        <h2>What did you have in mind?</h2>
        <div class="actions"><HouseButton v-if="!s.talk?.winBackId" variant="primary" :disabled="busy" @click="call('makeOffer')">Make an Offer</HouseButton><HouseButton variant="primary" :disabled="busy" @click="call('challenge')">Challenge to Race</HouseButton></div>
        <p class="muted">Negotiate a cash wager or pink slips at an agreed drag venue.</p>
      </section>
    </section>
    <section v-else class="challenge-shell panel stack">
      <p v-if="error" class="notice bad" role="alert">{{ error }}</p>
      <HouseButton variant="quiet" @click="onNavClose">Return to driving</HouseButton>
    </section>
  </div>
</template>
<script setup>
import { computed, ref, watch, onMounted, onUnmounted } from "vue"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { useBridge } from "@/bridge"
import { run } from "@/bridge/libs/Lua"
import { vBngOnUiNav } from "@/common/directives"
import { HouseAmountField, HouseButton, HouseMenu } from "../components/house/index.js"
import NegotiationChatWindow from "../components/negotiation/NegotiationChatWindow.vue"
const { events } = useBridge()
const s = ref(null), error = ref(""), busy = ref(false)
const REPLY_TIMEOUT_MS = 10000
let requestGeneration = 0, requestTimer, disposed = false
const proposalKind = ref("cash"), proposalAmount = ref(250)
const negotiation = computed(() => s.value?.offer?.negotiation)
const negotiationOpen = computed(() => !!(s.value?.offer?.ready && negotiation.value && !s.value.handover && !s.value.warning && !s.value.result && !s.value.race && !s.value.pending))
watch(() => `${s.value?.offer?.revision}:${s.value?.offer?.ready}`, () => {
  const offer = s.value?.offer
  if (offer) { proposalKind.value = offer.kind; proposalAmount.value = offer.amount }
}, { immediate: true })
async function propose() { await call("negotiate", proposalKind.value, proposalAmount.value, s.value.offer.venue.id, s.value.offer.revision) }
async function accept() { await call("accept", s.value.offer.revision) }
async function resolveNegotiation() { if (negotiation.value.status === "failed") await call("cancel"); else await accept() }
const cash = n => "$" + Math.round(n || 0).toLocaleString("en-US")
const navBlocker = useUINavBlocker()
watch(() => !!s.value?.handover, active => active ? navBlocker.allowNavigationOnly() : navBlocker.clear())
const onNavClose = event => { event?.stopPropagation?.(); if (s.value?.handover) return; call(s.value?.warning ? "cancelAction" : "close") }
const update = data => { s.value = data }
const showError = message => { error.value = message }
async function call(method, ...args) {
  // Leaving must remain available when an action's bridge reply never arrives.
  if (disposed || (busy.value && method !== "close" && method !== "cancelAction")) return
  const generation = ++requestGeneration
  clearTimeout(requestTimer)
  busy.value = true; error.value = ""
  try {
    const reply = await Promise.race([
      run("overhaul_career_economy_streetChallenges." + method, args, {}),
      new Promise((_, reject) => { requestTimer = setTimeout(() => reject(new Error("reply timeout")), REPLY_TIMEOUT_MS) }),
    ])
    if (!disposed && generation === requestGeneration) return reply
  } catch (_) {
    if (!disposed && generation === requestGeneration && !error.value)
      error.value = "The request timed out. Please try again. Any committed race remains recorded."
  } finally {
    if (generation === requestGeneration) { clearTimeout(requestTimer); busy.value = false }
  }
}
onMounted(() => { events.on("StreetChallengesState", update); events.on("StreetChallengesError", showError); call("requestState") })
onUnmounted(() => { disposed = true; requestGeneration++; clearTimeout(requestTimer); navBlocker.clear(); events.off("StreetChallengesState", update); events.off("StreetChallengesError", showError) })
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.challenge-screen { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; padding: 2em; background: rgba(0,0,0,.4); }
.challenge-shell { width: min(52em, 100%); max-height: 90vh; overflow: auto; padding: 2em; background: var(--page); }
.header { display: flex; justify-content: space-between; align-items: center; gap: 1em; }
.actions { display: flex; gap: .75em; flex-wrap: wrap; }
.race-proposal { border: 0; margin: 0; padding: 0; }
.race-notices { padding: 0 1.25em; }
.venue-label { display: grid; gap: .5em; }
.challenge-shell h1, .challenge-shell h2, .challenge-shell p { margin: 0; }
</style>
