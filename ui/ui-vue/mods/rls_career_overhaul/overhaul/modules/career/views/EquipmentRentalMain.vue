<template>
  <!-- Active scope routes Back through rental cleanup, even with focus on body. -->
  <div class="equipment-rental-wrapper" bng-ui-scope="equipmentRental" v-bng-on-ui-nav:back,menu="onNavClose">
    <BngCard class="equipment-rental-container" v-bng-blur="1" v-bng-ui-nav-scroll>
      <div class="main-header">
        <div class="header-titles">
          <h1>Equipment Rental</h1>
          <div v-if="uiData.facilityName" class="spot-name">{{ uiData.facilityName }}</div>
          <div v-if="uiData.organizationName" class="org-name">{{ uiData.organizationName }}</div>
        </div>
        <button class="close-button" @click="close" data-focusable>
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <line x1="18" y1="6" x2="6" y2="18"/>
            <line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </button>
      </div>

      <div v-if="loading" class="loading-state">
        <span>Loading rental fleet...</span>
      </div>

      <div v-else-if="error" class="error-state">
        <span>{{ error }}</span>
        <BngButton @click="close">Close</BngButton>
      </div>

      <template v-else>
        <div class="rental-note">
          <span class="note-icon">&#9432;</span>
          <span>Hourly rental rates are billed while the vehicle is out. Return it when finished.</span>
        </div>

        <div v-if="uiData.activeRentals?.length" class="rental-group">
          <div class="group-header">Active Rentals</div>
          <div class="rental-table">
            <div class="table-head">
              <span class="col-vehicle">Vehicle</span>
              <span class="col-rate"><BngIcon class="cur" :type="icons.beamCurrency" />/hour</span>
              <span class="col-action"></span>
            </div>
            <div
              v-for="rental in uiData.activeRentals"
              :key="rental.inventoryId"
              :data-row-key="`rental:${rental.inventoryId}`"
              class="table-row"
              :class="{ renting: returningId === rental.inventoryId }"
            >
              <div class="col-vehicle">
                <div class="vehicle-meta">
                  <div class="vehicle-name">{{ rental.name }}</div>
                </div>
              </div>
              <div class="col-rate">
                <span v-if="rental.hourlyRate != null"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(rental.hourlyRate) }}</span>
                <span v-else class="muted">—</span>
              </div>
              <div class="col-action">
                <!-- disabled buttons leave pad navigation (crossfire would dead-end on them) -->
                <BngButton
                  :disabled="returningId === rental.inventoryId"
                  :bng-no-nav="returningId === rental.inventoryId ? 'true' : null"
                  @click="returnRental(rental)"
                >
                  {{ returningId === rental.inventoryId ? 'Returning...' : 'Return' }}
                </BngButton>
              </div>
            </div>
          </div>
        </div>

        <div v-if="!uiData.groups?.length && !uiData.activeRentals?.length" class="empty-state">
          No rental equipment is available here right now.
        </div>

        <div v-for="group in uiData.groups" :key="group.id" class="rental-group">
          <div class="group-header">{{ group.label }}</div>
          <div class="rental-table">
            <div class="table-head">
              <span class="col-vehicle">Vehicle</span>
              <span class="col-rate"><BngIcon class="cur" :type="icons.beamCurrency" />/hour</span>
              <span class="col-action"></span>
            </div>
            <div
              v-for="offer in group.offers"
              :key="offer.id"
              :data-row-key="`offer:${offer.id}`"
              class="table-row"
              :class="{ disabled: !offer.enabled, renting: rentingId === offer.id }"
            >
              <div class="col-vehicle">
                <img
                  v-if="offer.thumbnail"
                  class="vehicle-thumb"
                  :src="offer.thumbnail"
                  alt=""
                />
                <div class="vehicle-meta">
                  <div class="vehicle-name">{{ offer.name }}</div>
                  <div v-if="offer.unlockInfo?.shortLabel" class="vehicle-unlock">{{ offer.unlockInfo.shortLabel }}</div>
                  <div v-if="offer.disableReason?.label && !offer.enabled" class="vehicle-reason">{{ offer.disableReason.label }}</div>
                </div>
              </div>
              <div class="col-rate">
                <span v-if="offer.hourlyRate != null"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(offer.hourlyRate) }}</span>
                <span v-else class="muted">—</span>
              </div>
              <div class="col-action">
                <BngButton
                  :accent="ACCENTS.attention"
                  :disabled="!offer.enabled || rentingId === offer.id"
                  :bng-no-nav="!offer.enabled || rentingId === offer.id ? 'true' : null"
                  @click="rent(offer)"
                >
                  {{ rentingId === offer.id ? 'Renting...' : 'Rent Me' }}
                </BngButton>
              </div>
            </div>
          </div>
        </div>

        <div class="footer-info">
          <div class="player-money">
            <span class="money-label">Your Money:</span>
            <span class="money-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(uiData.playerMoney || 0) }}</span>
          </div>
        </div>
      </template>
    </BngCard>
  </div>
</template>

<script setup>
import { useUINavScope } from "@/services/uiNav"
import { reportUiFailure } from "../utils/safeLua"

import { ref, onMounted, watch } from 'vue'
import { BngCard, BngButton, ACCENTS, BngIcon, icons } from "@/common/components/base"
import { vBngBlur, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { refocusIfLost } from "../composables/useScreenEntryFocus"
import { lua } from "@/bridge"
import { installLuaBridgeFallbacks, callModLua } from "../utils/installLuaBridgeFallbacks"

useUINavScope("equipmentRental")

installLuaBridgeFallbacks()

const loading = ref(true)
const error = ref(null)
const uiData = ref({})
const rentingId = ref(null)
const returningId = ref(null)

// Template puts the game currency glyph before it.
const formatMoney = (amount) => {
  return (amount || 0).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })
}

const loadData = async () => {
  // only the first load shows the loading state: a refresh after Rent / Return keeps the list mounted,
  // so a controller keeps its place instead of falling back to <body>
  loading.value = !uiData.value || !Object.keys(uiData.value).length
  error.value = null
  try {
    const data = await callModLua("overhaul_career_work_equipmentRental.getUiData")
    if (data?.error) {
      error.value = data.error === 'no_facility' ? 'No rental yard selected.' : 'Failed to load rental fleet.'
    } else if (data) {
      uiData.value = data
    } else {
      error.value = 'Failed to load rental fleet.'
    }
  } catch (e) {
    reportUiFailure(e, "Failed to load equipment rental data: (EquipmentRentalMain)")
    error.value = 'Failed to load rental fleet.'
  }
  loading.value = false
}

const rent = async (offer) => {
  if (!offer?.enabled || rentingId.value) return
  rentingId.value = offer.id
  try {
    const result = await callModLua("overhaul_career_work_equipmentRental.rentOffer", offer.id)
    if (!result?.ok) {
      error.value = result?.message || 'Could not rent that vehicle.'
      rentingId.value = null
      await loadData()
    }
  } catch (e) {
    reportUiFailure(e, "Rent failed: (EquipmentRentalMain)")
    error.value = 'Could not rent that vehicle.'
    rentingId.value = null
  }
}

const returnRental = async (rental) => {
  if (!rental?.inventoryId || returningId.value) return
  returningId.value = rental.inventoryId
  try {
    const result = await callModLua("overhaul_career_work_equipmentRental.returnRental", rental.inventoryId)
    if (!result?.ok) {
      error.value = result?.message || 'Could not return that vehicle.'
    }
    await loadData()
  } catch (e) {
    reportUiFailure(e, "Return failed: (EquipmentRentalMain)")
    error.value = 'Could not return that vehicle.'
  }
  returningId.value = null
}

// B / Start handler for this unscoped screen: the directive's listener does not stop the ui_nav event by
// itself, so without stopPropagation it also reaches the game's global fallback (ui_router.back())
const onNavClose = event => {
  event?.stopPropagation?.()
  close()
}

const close = async () => {
  try {
    await callModLua("overhaul_career_work_equipmentRental.closeScreen")
  } catch (e) {
    reportUiFailure(e, "Failed to close equipment rental: (EquipmentRentalMain)")
  }
  try {
    await callModLua("overhaul_career_career.closeAllMenus")
  } catch (_) {
    lua.extensions?.ui_router?.navigate?.('play')
  }
}

// Controller: entry on the first usable Rent / Return button (this screen has no scope, so nothing is
// focused by itself); after a refresh, back on the same row or the first usable one
let lastRowKey = null
const onFocusIn = event => {
  const key = event.target?.closest?.("[data-row-key]")?.dataset.rowKey
  if (key) lastRowKey = key
}
const pickRowButton = () => {
  const root = document.querySelector(".equipment-rental-container")
  const row = lastRowKey && [...(root?.querySelectorAll("[data-row-key]") || [])].find(el => el.dataset.rowKey === lastRowKey)
  return row?.querySelector("button:not([disabled])") ||
    root?.querySelector(".table-row button:not([disabled])") ||
    root?.querySelector(".close-button")
}
// the row is noted right before each refresh re-renders (focus events can be missed while the window
// is unfocused); afterwards a lost focus goes back to that row
watch([uiData, loading], () => onFocusIn({ target: document.activeElement }), { flush: "pre" })
watch([uiData, loading], () => refocusIfLost(pickRowButton), { flush: "post" })

onMounted(() => {
  loadData()
})
</script>

<style scoped lang="scss">
.equipment-rental-wrapper {
  // scaled unit: the screen keeps the same share of the display at 720p..4K (rem/px-sized it shrank at 1440p),
  // still following the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, 1rem);
  display: flex;
  justify-content: flex-start;
  align-items: center;
  height: 100%;
  padding: calc(2 * var(--rls-u, 1rem));
}

.equipment-rental-container {
  font-size: inherit; // BngCard pins 1rem; take the scaled size from the layout
  width: 100%;
  max-width: calc(51.25 * var(--rls-u, 1rem));
  max-height: calc(100vh - calc(4 * var(--rls-u, 1rem)));
  overflow-y: auto;
  background: rgba(0, 0, 0, 0.85);
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  padding: calc(1.5 * var(--rls-u, 1rem));
  color: white;
}

.main-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: calc(1.5 * var(--rls-u, 1rem));
  padding-bottom: var(--rls-u, 1rem);
  border-bottom: 1px solid rgba(255, 255, 255, 0.2);

  h1 {
    margin: 0;
    font-size: calc(1.5 * var(--rls-u, 1rem));
    font-weight: 600;
  }

  .header-titles {
    display: flex;
    flex-direction: column;
    gap: calc(0.25 * var(--rls-u, 1rem));
  }

  .spot-name {
    color: rgba(255, 255, 255, 0.75);
    font-size: calc(0.95 * var(--rls-u, 1rem));
  }

  .org-name {
    color: rgba(255, 255, 255, 0.55);
    font-size: calc(0.85 * var(--rls-u, 1rem));
  }
}

.close-button {
  // positioned so the game's ::before focus frame anchors to the button (it ballooned over the card)
  position: relative;
  border-radius: calc(0.25 * var(--rls-u, 1rem));
  background: transparent;
  border: none;
  color: white;
  cursor: pointer;
  padding: calc(0.25 * var(--rls-u, 1rem));
  opacity: 0.8;

  &:hover {
    opacity: 1;
  }
  // controller (.focus-visible) and keyboard focus: the house ring instead of the game frame
  &.focus-visible {
    opacity: 1;
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 calc(0.2188 * var(--rls-u, 1rem)) var(--bng-orange-b400, #ff6600);
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.rental-note {
  display: flex;
  align-items: flex-start;
  gap: calc(0.5 * var(--rls-u, 1rem));
  padding: calc(0.75 * var(--rls-u, 1rem)) var(--rls-u, 1rem);
  margin-bottom: calc(1.25 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.06);
  border-radius: calc(0.375 * var(--rls-u, 1rem));
  font-size: calc(0.9 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.8);

  .note-icon {
    flex-shrink: 0;
  }
}

.rental-group + .rental-group {
  margin-top: calc(1.5 * var(--rls-u, 1rem));
}

.group-header {
  font-size: calc(0.8 * var(--rls-u, 1rem));
  font-weight: 600;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.55);
  margin-bottom: calc(0.5 * var(--rls-u, 1rem));
}

.rental-table {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: calc(0.375 * var(--rls-u, 1rem));
  overflow: hidden;
}

.table-head,
.table-row {
  display: grid;
  grid-template-columns: 1fr calc(6.875 * var(--rls-u, 1rem)) calc(7.5 * var(--rls-u, 1rem));
  gap: calc(0.75 * var(--rls-u, 1rem));
  align-items: center;
  padding: calc(0.75 * var(--rls-u, 1rem)) var(--rls-u, 1rem);
}

.table-head {
  background: rgba(255, 255, 255, 0.05);
  font-size: calc(0.75 * var(--rls-u, 1rem));
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: rgba(255, 255, 255, 0.55);
}

.table-row {
  border-top: 1px solid rgba(255, 255, 255, 0.08);

  &.disabled {
    opacity: 0.55;
  }
}

.col-vehicle {
  display: flex;
  align-items: center;
  gap: calc(0.75 * var(--rls-u, 1rem));
  min-width: 0;
}

.vehicle-thumb {
  width: calc(4.5 * var(--rls-u, 1rem));
  height: calc(3 * var(--rls-u, 1rem));
  object-fit: cover;
  border-radius: calc(0.25 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.05);
  flex-shrink: 0;
}

.vehicle-meta {
  min-width: 0;
}

.vehicle-name {
  font-weight: 500;
}

.vehicle-unlock,
.vehicle-reason {
  font-size: calc(0.8 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.55);
  margin-top: calc(0.15 * var(--rls-u, 1rem));
}

.col-rate {
  font-weight: 600;
  text-align: right;
}

.col-action {
  display: flex;
  justify-content: flex-end;
}

.muted {
  color: rgba(255, 255, 255, 0.35);
}

.loading-state,
.error-state,
.empty-state {
  padding: calc(2 * var(--rls-u, 1rem)) var(--rls-u, 1rem);
  text-align: center;
  color: rgba(255, 255, 255, 0.7);
}

.footer-info {
  margin-top: calc(1.5 * var(--rls-u, 1rem));
  padding-top: var(--rls-u, 1rem);
  border-top: 1px solid rgba(255, 255, 255, 0.2);
}

.player-money {
  display: flex;
  justify-content: space-between;
  align-items: center;

  .money-label {
    color: rgba(255, 255, 255, 0.65);
  }

  .money-value {
    font-weight: 600;
    font-size: calc(1.1 * var(--rls-u, 1rem));
  }
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
