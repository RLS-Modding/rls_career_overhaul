<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- The Vault's auction counter in the house style: a .modal card with an Auctions / My listings tab bar
     (LB / RB switch tabs), offer and lot-count pickers, and the player's cars with their listing state.
     It sits inside the auction's nav scope, so Back still closes the counter through the screen. The
     screen owns every rule (can register, can list); this component only shows them and emits. -->
<template>
  <div class="rls-house counter-backdrop">
    <section
      class="modal counter-card"
      role="dialog"
      aria-modal="true"
      aria-labelledby="auction-counter-title"
      v-bng-on-ui-nav:tab_l,tab_r="switchTab">
      <header class="counter-head">
        <h3 id="auction-counter-title">Auction Counter</h3>
        <div v-if="tab === 'auctions'" class="stat money">
          <span class="stat-key">Entry credit</span>
          <span class="stat-value">{{ dollars(state.entryCreditRemaining) }}</span>
        </div>
      </header>

      <div class="tab-row">
        <BngBinding ui-event="tab_l" controller track-ignore />
        <div class="seg bar counter-tabs" role="tablist" aria-label="Counter sections">
          <button
            v-for="entry in tabs"
            :key="entry.id"
            type="button"
            role="tab"
            bng-nav-item
            :aria-selected="tab === entry.id"
            :class="{ active: tab === entry.id }"
            @click="emit('update:tab', entry.id)">
            {{ entry.label }}<span v-if="entry.count" class="tab-count">{{ entry.count }}</span>
          </button>
        </div>
        <BngBinding ui-event="tab_r" controller track-ignore />
      </div>

      <template v-if="tab === 'auctions'">
        <div class="field-block">
          <span class="caption">Auction type</span>
          <div class="lines offers">
            <button
              v-for="offer in state.counterOffers || []"
              :key="offer.id"
              type="button"
              class="line offer"
              bng-nav-item
              :class="{ selected: offerId === offer.id }"
              :aria-pressed="offerId === offer.id"
              @click="emit('update:offerId', offer.id)">
              <span class="pick" aria-hidden="true"></span>
              <span class="row-copy">
                <strong>{{ offer.label }}</strong>
                <span>{{ offer.subtitle }}</span>
              </span>
              <span v-if="offer.coveredByEntry" class="pill ok">Covered</span>
              <strong v-else class="fee">{{ dollars(offer.registrationFee) }}</strong>
            </button>
          </div>
        </div>

        <div class="lot-row">
          <span class="caption">Lots</span>
          <HouseButton compact variant="quiet" :icon="icons.minus" aria-label="Fewer lots" @click="emit('batch', -1)" />
          <strong class="lot-count">{{ lotCount }}</strong>
          <HouseButton compact variant="quiet" :icon="icons.plus" aria-label="More lots" @click="emit('batch', 1)" />
        </div>

        <p v-if="registerBlockedReason" class="notice warn">{{ registerBlockedReason }}</p>
      </template>

      <template v-else>
        <div class="split-head">
          <span class="caption">Your cars</span>
          <hr class="rule" />
          <span class="pill" :class="{ warn: listingLimit > 0 && listingCount >= listingLimit }">
            {{ listingLimit > 0 ? `${listingCount} of ${listingLimit} listings used` : `${listingCount} listed` }}
          </span>
        </div>
        <p class="hint">Each listed car gets its own Anything Goes lot. Entry is paid once per visit, and cars that don't fit in a batch stay listed for the next one.</p>
        <div
          ref="vehicleList"
          class="lines scroll vehicles"
          :class="{ 'more-above': moreAbove, 'more-below': moreBelow }"
          v-bng-ui-nav-scroll.force
          @scroll.passive="updateScrollHints"
          @focusin="revealFocused">
          <div
            v-for="row in state.myVehicles || []"
            :key="row.inventoryId"
            class="line vehicle"
            role="button"
            tabindex="0"
            bng-nav-item
            bng-no-child-nav="true"
            v-bng-ui-nav-focus
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            :aria-label="vehicleRowLabel(row)"
            @click.self="activateVehicleRow(row)">
            <div class="thumb"><img v-if="row.thumbnail" :src="row.thumbnail" alt="" /></div>
            <div class="row-copy">
              <strong>{{ row.niceName }}</strong>
              <div class="stats">
                <div class="stat money">
                  <span class="stat-key">Value</span>
                  <span class="stat-value">{{ dollars(row.value) }}</span>
                </div>
                <div class="stat">
                  <span class="stat-key">Mileage</span>
                  <span class="stat-value">{{ formatMileage(row.mileage) }}</span>
                </div>
                <div v-if="row.listingInSession" class="stat accent">
                  <span class="stat-key">Status</span>
                  <span class="stat-value">In this auction</span>
                </div>
                <div v-else-if="row.listingPending" class="stat">
                  <span class="stat-key">Status</span>
                  <span class="stat-value">Preparing listing</span>
                </div>
                <div v-else-if="row.listedForAuction" class="stat ok">
                  <span class="stat-key">Status</span>
                  <span class="stat-value">Listed</span>
                </div>
                <div v-else-if="row.listBlockedReason" class="stat warn">
                  <span class="stat-key">Can't list</span>
                  <span class="stat-value">{{ row.listBlockedReason }}</span>
                </div>
              </div>
            </div>
            <HouseButton
              v-if="row.listedForAuction || row.listingPending"
              compact
              variant="quiet"
              :disabled="row.listingInSession || busy"
              @click="emit('unlist', row)">
              {{ row.listingInSession ? "Locked" : row.listingPending ? "Cancel" : "Unlist" }}
            </HouseButton>
            <HouseButton
              v-else
              compact
              :disabled="!canListVehicle(row) || busy"
              @click="emit('list', row)">
              Sell at Auction
            </HouseButton>
          </div>
          <p v-if="!state.myVehicles?.length" class="empty-note">No vehicles in your garage.</p>
        </div>
      </template>

      <div class="actions">
        <p v-if="tab !== 'auctions' && listingCount > 0" class="actions-note">
          Listings stay locked until their lot runs or you unlist them.
        </p>
        <HouseButton variant="quiet" binding="back" @click="emit('close')">Close counter</HouseButton>
        <HouseButton
          v-if="tab === 'auctions'"
          variant="primary"
          :disabled="!canRegister || busy"
          @click="emit('register')">
          Generate {{ lotCount }} Lots
        </HouseButton>
      </div>
    </section>
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUpdate, onMounted, onUpdated, ref, watch } from "vue"
import { BngBinding, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngUiNavScroll, vBngUiNavFocus } from "@/common/directives"
import HouseButton from "./house/HouseButton.vue"
import { refocusIfLost } from "../composables/useScreenEntryFocus"

import { useBridge } from "@/bridge"
import { bigLengthUnit, formatOdometer } from "../utils/units"
const { units } = useBridge()
const formatMileage = value => {
  if (value == null || value === "" || !Number.isFinite(Number(value)) || Number(value) < 0) return "Unknown"
  const displayValue = Number(value) * bigLengthUnit(units).perMetre
  return formatOdometer(units, value, displayValue > 0 && displayValue < 1 ? 2 : 0)
}

const props = defineProps({
  state: { type: Object, required: true },
  tab: { type: String, default: "auctions" },
  offerId: { type: String, default: null },
  busy: Boolean,
  canRegister: Boolean,
  // why Generate is off, or "" when it is only waiting for a pick
  registerBlockedReason: { type: String, default: "" },
  canListVehicle: { type: Function, required: true },
  listingCount: { type: Number, default: 0 },
})
const emit = defineEmits(["update:tab", "update:offerId", "batch", "register", "list", "unlist", "close"])

const tabs = computed(() => [
  ...(props.state.counterShowAuctionsTab !== false ? [{ id: "auctions", label: "Auctions" }] : []),
  { id: "myVehicles", label: "My listings", count: props.listingCount },
])
const lotCount = computed(() => props.state.lotBatchSize || 10)
const listingLimit = computed(() => Number(props.state.listingLimit) || 0)

// The row survives pending/listed changes and busy child buttons, preserving pad focus.
const vehicleRowLabel = row => row.listingInSession ? row.niceName :
  row.listingPending ? `Cancel ${row.niceName}` : row.listedForAuction ? `Unlist ${row.niceName}` :
  props.canListVehicle(row) ? `Sell at Auction ${row.niceName}` : row.niceName
const activateVehicleRow = row => {
  if (props.busy || !row || row.listingInSession) return
  if (row.listedForAuction || row.listingPending) emit('unlist', row)
  else if (props.canListVehicle(row)) emit('list', row)
}

// Scroll hints: fade the list edge that has more cars past it, and keep a focused row in view.
const vehicleList = ref(null)
let focusedVehicleRow = null
onBeforeUpdate(() => {
  const row = document.activeElement?.closest?.('.vehicle')
  // Scroll hints can queue a second update after DOM reordering has blurred the row.
  // Keep its snapshot until onUpdated consumes it; outside focus still wins below.
  if (row && vehicleList.value?.contains(row)) focusedVehicleRow = row
})
onUpdated(() => {
  const row = focusedVehicleRow
  focusedVehicleRow = null
  if (row) void refocusIfLost(() => vehicleList.value?.contains(row) ? row : null)
})
const moreAbove = ref(false)
const moreBelow = ref(false)
const updateScrollHints = () => {
  const list = vehicleList.value
  if (!list) return
  moreAbove.value = list.scrollTop > 1
  moreBelow.value = list.scrollTop + list.clientHeight < list.scrollHeight - 1
}
const revealFocused = event => event.target?.closest?.(".vehicle")?.scrollIntoView?.({ block: "nearest" })
watch(() => [props.tab, (props.state.myVehicles || []).length], () => nextTick(updateScrollHints))
onMounted(() => nextTick(updateScrollHints))

const dollars = amount => "$" + Math.round(Number(amount) || 0).toLocaleString("en-US")

// LB / RB step through the tabs
const switchTab = event => {
  const { name, value } = event?.detail || {}
  if (!value) return
  event.stopPropagation()
  const list = tabs.value
  const at = list.findIndex(entry => entry.id === props.tab)
  const step = name === "tab_l" ? -1 : 1
  const next = list[(at + step + list.length) % list.length]
  if (next && next.id !== props.tab) emit("update:tab", next.id)
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.counter-backdrop {
  position: fixed;
  inset: 0;
  display: grid;
  place-items: center;
  background: rgba(0, 0, 0, 0.45);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  pointer-events: auto;
}
.counter-card {
  width: min(34em, 94vw);
  max-height: 88vh;
  padding: 1.1em 1.1em 1em;
  overflow: hidden;
  grid-template-rows: auto auto minmax(0, auto);
}
.counter-head {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: var(--space-3);
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
  .stat { text-align: right; }
}
.money .stat-value { font-variant-numeric: tabular-nums; }
.tab-row {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  .counter-tabs { flex: 1 1 auto; }
}
.offers .offer {
  gap: 0.75em;
  padding-left: 0.5em;
  .row-copy span { white-space: normal; }
  .fee {
    color: var(--money);
    font-variant-numeric: tabular-nums;
  }
}
/* radio dot: filled when picked (no orange rings or side bars) */
.pick {
  flex: 0 0 auto;
  width: 0.85em;
  height: 0.85em;
  border-radius: 50%;
  box-shadow: inset 0 0 0 2px var(--faint);
}
.offer.selected .pick {
  background: var(--accent);
  box-shadow: inset 0 0 0 2px var(--accent), inset 0 0 0 4px #1a1a1c;
}
/* one slim row: label, then − count + */
.lot-row {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  .caption { margin-right: auto; }
  .lot-count {
    min-width: 2.2em;
    text-align: center;
    font-size: 1.1em;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }
}
.vehicles {
  max-height: min(19.5em, 46vh);
  padding-right: 0.2em;
  // the edge with more cars past it fades out, so a cut row reads as "scroll for more"
  &.more-below { mask-image: linear-gradient(to bottom, #000 calc(100% - 3em), transparent); }
  &.more-above { mask-image: linear-gradient(to top, #000 calc(100% - 3em), transparent); }
  &.more-above.more-below { mask-image: linear-gradient(to bottom, transparent, #000 3em, #000 calc(100% - 3em), transparent); }
}
.vehicle {
  gap: 0.8em;
  &.focus-visible { box-shadow: var(--focus-inset); }
  .thumb img { width: 100%; height: 100%; object-fit: cover; }
  .row-copy { gap: 0.3em; }
  .stats { gap: 0.3em 1.4em; }
  .stat-value { font-size: 0.95em; }
  > :deep(.house-button) { min-width: 8em; }
}
.tab-count {
  margin-left: 0.45em;
  padding: 0.15em 0.45em 0.05em;
  border-radius: var(--radius-pill);
  background: var(--accent-ink);
  color: var(--accent-soft);
  font-size: 0.8em;
  font-variant-numeric: tabular-nums;
}
.stat.accent .stat-value { color: var(--accent-soft); }
.hint { line-height: 1.35; }
.empty-note { margin: 0; padding: 1em 0; color: var(--muted); text-align: center; }
.actions {
  margin-top: var(--space-1);
  > :deep(.house-button) { min-width: 6.5em; }
}
</style>
