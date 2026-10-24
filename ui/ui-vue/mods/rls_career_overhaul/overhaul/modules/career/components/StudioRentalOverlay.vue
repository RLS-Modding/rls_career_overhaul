<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Film studio rentals (overhaul_career_garage_studioRentals_studioRentals). Renders the StudioRentalState
     payload only: a prompt card (offer, started, or why a car can't go), a status chip while driving to a
     staged stage, and short notices when a car comes back. All words live in PROMPTS / NOTICES below. -->
<template>
  <EntryOverlayPopup :active="!!prompt" @cancel="dismissPrompt" @leave="dismissPrompt">
    <div v-if="prompt" class="studio-prompt">
      <section class="modal studio-card" role="dialog" aria-labelledby="studio-rental-title">
        <span class="eyebrow">{{ prompt.studioName || "Film studio" }}</span>
        <h3 id="studio-rental-title">{{ promptCopy.title }}</h3>
        <p v-if="promptCopy.text">{{ promptCopy.text }}</p>
        <div v-if="promptCopy.stats?.length" class="stats">
          <div v-for="stat in promptCopy.stats" :key="stat.key" class="stat" :class="{ money: stat.money !== undefined }">
            <span class="stat-key">{{ stat.key }}</span>
            <span class="stat-value">
              <MoneyAmount v-if="stat.money !== undefined">{{ formatMoney(stat.money) }}</MoneyAmount>
              <template v-else>{{ stat.value }}</template>
            </span>
          </div>
        </div>
        <p v-if="promptCopy.hint" class="hint">{{ promptCopy.hint }}</p>
        <div class="actions">
          <HouseButton v-if="promptCopy.cancel" variant="quiet" binding="back" @click="dismissPrompt">{{ promptCopy.cancel }}</HouseButton>
          <HouseButton variant="primary" binding="ok" bng-scoped-nav-autofocus @click="confirmPrompt">{{ promptCopy.confirm }}</HouseButton>
        </div>
      </section>
    </div>
  </EntryOverlayPopup>

  <Teleport to="body">
    <div v-if="onPlayRoute && (status || notices.length)" class="rls-house studio-hud" aria-live="polite">
      <section v-if="status" class="studio-chip">
        <span class="eyebrow">{{ status.studioName || "Film studio" }}</span>
        <strong>{{ statusTitle }}</strong>
        <dl class="chip-stats">
          <div><dt>Pays up front</dt><dd><MoneyAmount>{{ formatMoney(status.payout) }}</MoneyAmount></dd></div>
          <div><dt>Shoot length</dt><dd>{{ formatDuration(status.seconds) }}</dd></div>
        </dl>
      </section>
      <TransitionGroup name="studio-notice" tag="div" class="studio-notices">
        <article v-for="notice in notices" :key="notice.id" class="studio-chip notice">
          <span class="eyebrow">{{ notice.studioName || "Film studio" }}</span>
          <strong>{{ noticeCopy(notice).title }}</strong>
          <span class="chip-line">{{ noticeCopy(notice).text }}</span>
        </article>
      </TransitionGroup>
    </div>
  </Teleport>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { useRoute } from "vue-router"
import { useBridge } from "@/bridge"
import EntryOverlayPopup from "./EntryOverlayPopup.vue"
import MoneyAmount from "./MoneyAmount.vue"
import HouseButton from "./house/HouseButton.vue"
import { callModLua } from "../utils/installLuaBridgeFallbacks.js"
import { safeLua } from "../utils/safeLua.js"
import { formatAccessEta as formatDuration } from "../utils/accessEta.js"

const OWNER = "overhaul_career_garage_studioRentals_studioRentals"
const STATE_EVENT = "StudioRentalState"
const NOTICE_SECONDS = 8

const carName = p => p.vehicleName || "car"

// Why a car can't go to the studio; keys are the Lua rentalBlock reasons.
const BLOCK_REASONS = {
  notOwned: "The studio only rents cars you own.",
  loaner: "Loaner cars can't be rented out.",
  listed: "Cars listed at auction can't be rented out.",
  unavailable: "This car isn't available right now.",
}

const PROMPTS = {
  offer: p => ({
    title: `Rent your ${carName(p)} for a shoot?`,
    stats: [{ key: "Shoot length", value: formatDuration(p.seconds) }, { key: "Pays up front", money: p.payout }],
    hint: `Park on Stage ${p.stageLabel} and stop. You can't drive it until the shoot ends.`,
    cancel: "Not now",
    confirm: `Go to Stage ${p.stageLabel}`,
  }),
  started: p => ({
    title: `Your ${carName(p)} is on set`,
    stats: [{ key: "Paid", money: p.payout }, { key: "Back in your garage in", value: formatDuration(p.seconds) }],
    hint: "Step out and walk away. The studio takes it from here.",
    confirm: "Got it",
  }),
  tooCheap: p => ({
    title: "Not this car",
    text: "The studio only rents high-value cars. Come back in something worth more.",
    stats: [{ key: "Your car is worth", money: p.vehicleValue }, { key: "Studio needs over", money: p.minValue }],
    confirm: "OK",
  }),
  notRentable: p => ({ title: "Not this car", text: BLOCK_REASONS[p.reason] || BLOCK_REASONS.unavailable, confirm: "OK" }),
  stageTaken: () => ({
    title: "Stage taken, try again",
    text: "That stage is no longer free. Drive through the studio gate for a new offer.",
    confirm: "OK",
  }),
  studioFull: p => ({
    title: "All stages are booked",
    text: "Every stage has a car on it. Come back when one is free.",
    stats: p.nextFreeSeconds ? [{ key: "Next stage free in", value: formatDuration(p.nextFreeSeconds) }] : [],
    confirm: "OK",
  }),
}

const NOTICES = {
  returned: n => ({ title: `Your ${carName(n)} is back`, text: "The shoot is over. It's in your garage." }),
  returnedEarly: n => ({
    title: `Your ${carName(n)} is back early`,
    text: "Its studio stage isn't on this map, so it's in your garage. You keep the pay.",
  }),
}

const STATUS_TITLES = {
  staged: s => `Drive to Stage ${s.stageLabel}`,
  onStage: () => "Stop here to start the shoot",
}

const formatMoney = amount => Math.round(Number(amount) || 0).toLocaleString("en-US")


const { events } = useBridge()
const route = useRoute()
const prompt = ref(null)
const status = ref(null)
const notices = ref([])

const promptCopy = computed(() => (prompt.value && PROMPTS[prompt.value.kind]?.(prompt.value)) || { title: "", confirm: "OK" })
const statusTitle = computed(() => STATUS_TITLES[status.value?.kind]?.(status.value) || "")
const noticeCopy = notice => NOTICES[notice.kind]?.(notice) || { title: "", text: "" }
const onPlayRoute = computed(() => route.name === "play" || !route.name)

const asList = value => (Array.isArray(value) ? value : value && typeof value === "object" ? Object.values(value) : [])

function applyState(payload) {
  if (Array.isArray(payload)) payload = payload.find(entry => entry && typeof entry === "object") || {}
  payload = payload || {}
  prompt.value = PROMPTS[payload.prompt?.kind] ? payload.prompt : null
  status.value = STATUS_TITLES[payload.status?.kind] ? payload.status : null
  notices.value = asList(payload.notices).filter(notice => NOTICES[notice?.kind])
}

const call = (method, ...args) => safeLua(() => callModLua(`${OWNER}.${method}`, ...args), `StudioRentalOverlay: ${method}`)

function confirmPrompt() {
  if (prompt.value?.kind === "offer") call("acceptOffer")
  else dismissPrompt()
}

function dismissPrompt() {
  if (!prompt.value) return
  prompt.value = null
  call("dismissPrompt")
}

// Each notice shows for a few seconds, then Lua drops it (so a UI reload doesn't repeat old notices).
const noticeTimers = new Map()
watch([notices, onPlayRoute], ([list, visible]) => {
  const live = new Set(visible ? list.map(notice => notice.id) : [])
  for (const [id, timer] of noticeTimers) {
    if (!live.has(id)) {
      clearTimeout(timer)
      noticeTimers.delete(id)
    }
  }
  for (const id of live) {
    if (!noticeTimers.has(id)) noticeTimers.set(id, setTimeout(() => call("dismissNotice", id), NOTICE_SECONDS * 1000))
  }
})

onMounted(() => events.on(STATE_EVENT, applyState))
onBeforeUnmount(() => {
  events.off(STATE_EVENT, applyState)
  for (const timer of noticeTimers.values()) clearTimeout(timer)
  noticeTimers.clear()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.studio-prompt,
.studio-hud {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
// Same backdrop as the other entry prompts (TravelJournalScenePrompt): the popup host is fullscreen.
.studio-prompt {
  position: fixed;
  inset: 0;
  display: grid;
  place-items: center;
  padding: 2em;
  background: rgba(10, 9, 8, 0.42);
  backdrop-filter: blur(2px);
  pointer-events: auto;
}
.studio-card {
  width: min(26em, 92vw);
  gap: var(--space-3);
  padding: 1.1em 1.1em 1em;
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
  .stats {
    padding: 0.6em 0.75em;
    border-radius: var(--radius-panel);
    background: var(--panel);
  }
  .stat-value {
    font-variant-numeric: tabular-nums;
  }
}
.eyebrow {
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
}
.actions {
  margin-top: var(--space-1);
  > :deep(.house-button) {
    min-width: 6.5em;
  }
}

// Gameplay HUD: never takes input, sits under the top bar so it doesn't cover the stock toasts.
.studio-hud {
  position: fixed;
  top: 5.5em;
  left: 50%;
  z-index: 40;
  display: grid;
  justify-items: center;
  gap: var(--space-2);
  transform: translateX(-50%);
  pointer-events: none;
}
.studio-notices {
  display: grid;
  justify-items: center;
  gap: var(--space-2);
}
.studio-chip {
  display: grid;
  justify-items: center;
  gap: 0.15em;
  min-width: 16em;
  max-width: 28em;
  padding: 0.6em 1.1em 0.65em;
  border-radius: var(--radius-control);
  background: rgba(26, 26, 28, 0.92);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 0.6em 1.6em rgba(0, 0, 0, 0.45);
  text-align: center;
  strong {
    font-size: 1.2em;
    line-height: 1.2;
  }
}
.chip-line {
  display: inline-flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 0 0.4em;
  color: var(--muted);
  font-size: 0.95em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.chip-stats {
  display: flex;
  justify-content: center;
  gap: 1.25em;
  margin: 0.3em 0 0;
  dt {
    color: var(--faint);
    font-size: 0.65em;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }
  dd {
    margin: 0.1em 0 0;
    font-size: 0.95em;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
}
.studio-notice-enter-active,
.studio-notice-leave-active {
  transition: opacity 0.2s var(--bx-ease-out, cubic-bezier(0.23, 1, 0.32, 1)), transform 0.2s var(--bx-ease-out, cubic-bezier(0.23, 1, 0.32, 1));
}
.studio-notice-enter-from,
.studio-notice-leave-to {
  opacity: 0;
  transform: translateY(-0.4em);
}
@media (prefers-reduced-motion: reduce) {
  .studio-notice-enter-active,
  .studio-notice-leave-active {
    transition: none;
  }
}
</style>
