<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!--
Map: Loading Work phone screen. Read top to bottom.
  1. Template: one panel per currentState (idle, contract_select, choosing_zone, driving_to_site,
     truck_arriving, loading, delivering, return_to_quarry, at_quarry_decide), plus the active contract
     header, the truck status and the zone modal, which sit above and beside the panel. Only the loading
     panel and the completion panel (the two big ones) are separate components.
  2. Script: the state owner. Every ref a panel reads is set only by handleStateUpdate or the two contract
     events. Derived values come from usePhoneQuarryDerived.js. Every Lua call and event subscription is here.
  3. views/phoneQuarry/: QuarryLoadingPanel and QuarryCompletionPanel receive narrow props and emit named
     actions (sendTruck, swapZone, finalize, abandon). quarryMath.js holds the pure formatting they and this view share.
  4. Style: the panel skin shared with those two children stays here, reached through :deep() for their
     internals (.active-contract-info, .status-section, .action-button). Rules used only by this file's own
     panels are plain selectors, grouped by panel.
-->
<template>
  <div class="quarry-container" v-bng-on-ui-nav:tab_l="event => changePhoneTab(-1, event)" v-bng-on-ui-nav:tab_r="event => changePhoneTab(1, event)" v-bng-ui-nav-scroll>
    <div v-if="currentState === 'idle'" class="state-panel idle-compact">
      <div class="idle-header">
        <div class="state-icon idle-icon">🏔️</div>
        <div class="state-title idle-title">Loading Work</div>
      </div>
      <div v-if="allZonesByFacility.length > 0" class="zones-by-facility-section">
        <div class="idle-info-message">Drive to a zone to do loading work</div>
        <div
          v-for="facility in allZonesByFacility"
          :key="facility.facilityId"
          class="facility-group"
        >
          <div class="facility-group-header">{{ facility.facilityName }}</div>
          <div class="facility-zones-list">
            <div
              v-for="zone in facility.zones"
              :key="zone.zoneTag"
              class="zone-item"
            >
              <div class="zone-item-info">
                <div class="zone-item-name">{{ zone.displayName }}</div>
                <div class="zone-item-distance">{{ formatDistance(zone.distance) }} away</div>
              </div>
              <button class="zone-waypoint-button" @click="setZoneWaypoint(zone.zoneTag)">
                Set Waypoint
              </button>
            </div>
          </div>
        </div>
      </div>
      <div v-else class="state-message centered-message">No loading zones available.</div>
    </div>

    <div
      v-if="activeContract && currentState !== 'idle' && currentState !== 'contract_select'"
      class="active-contract-section"
    >
      <div class="section-header">Active Contract</div>
      <div class="active-contract-card">
        <div class="contract-name-row">
          <span class="contract-name">{{ activeContract.name }}</span>
          <span class="contract-payout-badge">${{ formatNumber(activeContract.totalPayout) }}</span>
        </div>
        <div class="contract-progress-row">
          <template v-if="activeContract.materialBreakdown && activeContract.materialBreakdown.length > 0">
            <div
              v-for="mat in activeContract.materialBreakdown"
              :key="mat.materialKey"
              class="material-progress-item"
            >
              <div class="material-progress-label">{{ mergeMaterialNameAndUnit(mat.materialName, mat.units) }}:</div>
              <div class="progress-bar-container">
                <div
                  class="progress-bar"
                  :style="{ width: getMaterialProgressPercent(contractProgress, mat) + '%' }"
                ></div>
              </div>
              <div class="progress-text">
                {{ getMaterialDelivered(contractProgress, mat.materialKey) || 0 }} / {{ mat.required }} {{ mergeMaterialNameAndUnit(mat.materialName, mat.units) }}
                <span class="progress-percent">({{ getMaterialProgressPercent(contractProgress, mat).toFixed(0) }}%)</span>
              </div>
            </div>
          </template>
          <template v-else>
            <div class="progress-bar-container">
              <div class="progress-bar" :style="{ width: progressPercent + '%' }"></div>
            </div>
            <div class="progress-text">
              <template v-if="activeContract.unitType === 'item'">
                {{ contractProgress.deliveredItems || 0 }} / {{ activeContract.requiredItems || 0 }} {{ activeContract.units || 'items' }}
              </template>
              <template v-else>
                {{ formatNumber(contractProgress.deliveredTons || 0) }} / {{ activeContract.requiredTons || 0 }} {{ activeContract.units || 'tons' }}
              </template>
              <span class="progress-percent">({{ progressPercent.toFixed(0) }}%)</span>
            </div>
          </template>
        </div>
      </div>
    </div>

    <div v-if="activeContract && truckState.status !== 'none'" class="truck-status-section">
      <div class="section-header">Truck Status</div>
      <div class="truck-status-card">
        <div class="truck-status-icon" :class="{ pulsing: truckState.status === 'arriving' || truckState.status === 'spawning' }">
          {{ getTruckStatusIcon(truckState.status) }}
        </div>
        <div class="truck-status-info">
          <div class="truck-status-text">{{ getTruckStatusText(truckState.status) }}</div>
          <div class="truck-status-location" v-if="truckState.currentZone">
            Zone: {{ truckState.currentZone }}
          </div>
        </div>
      </div>
    </div>

    <div v-if="currentState === 'contract_select'" class="contract-list">
    <div class="page-tabs">
        <button
          class="tab-button"
          :class="{ active: currentPage === 'contracts' }"
          @click="selectPage('contracts')"
        >
          Contracts
        </button>
        <button
          class="tab-button"
          :class="{ active: currentPage === 'stock' }"
          @click="selectPage('stock')"
        >
          Stock
        </button>
      </div>

      <div v-if="currentPage === 'contracts'" class="contracts-page">
        <div class="contracts-header">
          <div class="header-title">Available Contracts</div>
        </div>

        <div class="contracts-scroll">
          <div v-if="!quarryUnlocked" class="no-contracts">
            Quarry Work unlocks at Operator level {{ quarryUnlockLevel }}. Current level: {{ operatorLevel }}.
          </div>
          <div v-else-if="availableContracts.length === 0" class="no-contracts">
            No contracts available
          </div>

          <div
            v-for="(contract, index) in availableContracts"
            :key="contract.id"
            class="contract-card"
            :class="[getTierClass(contract.tier), { 'urgent': contract.isUrgent }]"
          >
            <div class="contract-header">
              <span class="contract-name">{{ contract.name }}</span>
              <span class="contract-payout">${{ formatNumber(contract.totalPayout) }}</span>
            </div>
            <div class="contract-details">
              <span class="tier-badge" :class="getTierClass(contract.tier)">
                Tier {{ contract.tier }}
              </span>
              <span class="material-badge">{{ (contract.materialName || contract.material || 'rocks').toUpperCase() }}</span>
              <span v-if="contract.isUrgent" class="urgent-badge">⚡ +25%</span>
            </div>
            <div class="contract-info">
              <template v-if="contract.materialBreakdown && contract.materialBreakdown.length > 0">
                <div class="material-breakdown">
                  <div
                    v-for="mat in contract.materialBreakdown"
                    :key="mat.materialKey"
                    class="material-breakdown-item"
                  >
                    {{ mat.required }} {{ mergeMaterialNameAndUnit(mat.materialName, mat.units) }}
                  </div>
                </div>
              </template>
              <template v-else>
                <span v-if="contract.unitType === 'item'">
                  {{ contract.requiredItems || 0 }} {{ contract.units || 'items' }}
                </span>
                <span v-else>
                  {{ contract.requiredTons || 0 }} {{ contract.units || 'tons' }}
                </span>
              </template>
              <span>• Pay on Completion</span>
            </div>
            <div class="contract-expiration" :class="getExpirationClass(getTimeRemaining(contract, currentSimTime))">
              <span>⏰ Expires in {{ formatTimeRemaining(contract, currentSimTime) }}</span>
            </div>
            <div class="contract-modifiers" v-if="contract.modifiers && contract.modifiers.length > 0">
              <span v-for="mod in contract.modifiers" :key="mod.name" class="modifier-badge">
                {{ mod.name }}
              </span>
            </div>
            <button class="accept-button" @click="acceptContract(index)">
              Accept Contract
            </button>
          </div>
        </div>

        <button class="action-button decline" @click="declineAll">
          Decline All
        </button>
      </div>

      <div class="facility-name-bottom" v-if="currentFacility">
        {{ currentFacility.name }}
      </div>

      <div v-if="currentPage === 'stock'" class="stock-page">
        <div class="stock-header">
          <div class="header-title">Zone Stock</div>
          <div class="header-subtitle">All zones and regeneration rates</div>
        </div>
        <div class="zones-scroll">
          <div v-if="allZonesStock.length === 0" class="no-zones">
            No zones available
          </div>
          <div
            v-for="stockZone in allZonesStock"
            :key="stockZone.zoneName"
            class="zone-stock-card"
          >
            <div class="zone-header">
              <span class="zone-name">{{ stockZone.zoneName }}</span>
            </div>
            <div class="zone-materials">
              <div
                v-for="material in stockZone.materials"
                :key="material.materialKey"
                class="material-stock-item"
              >
                <div class="material-name">{{ material.materialName }}</div>
                <div class="stock-info">
                  <div class="stock-bar-container">
                    <div
                      class="stock-bar"
                      :class="getStockLevelClass(material.current, material.max)"
                      :style="{ width: ((material.current / material.max) * 100) + '%' }"
                    ></div>
                  </div>
                  <div class="stock-text">
                    <span class="stock-current">{{ material.current }}</span>
                    <span class="stock-separator">/</span>
                    <span class="stock-max">{{ material.max }}</span>
                    <span class="stock-regen" v-if="material.regenRate > 0">
                      (+{{ material.regenRate }}/hr)
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Shown when the player must pick a loading zone. The zone modal is opened from here. -->
    <div v-if="currentState === 'choosing_zone' && !showZoneModal" class="state-panel">
      <div class="state-icon">📍</div>
      <div class="state-title">Choose Loading Zone</div>
      <div class="state-message">Select a zone from the list below.</div>
      <button class="action-button primary" @click="openZoneModal">
        Select Zone
      </button>
      <button class="action-button decline" @click="abandonContract">
        Abandon Contract
      </button>
    </div>

    <!-- Two states before loading: driving to the marker (driving_to_site) and waiting for the truck (truck_arriving). -->
    <div v-if="currentState === 'driving_to_site' || currentState === 'truck_arriving'" class="state-panel">
      <div class="active-contract-info" v-if="activeContract">
        <div class="contract-name">{{ activeContract.name }}</div>
        <div class="contract-progress">
          <template v-if="activeContract.unitType === 'item'">
            {{ contractProgress.deliveredItems || 0 }} / {{ activeContract.requiredItems || 0 }} {{ activeContract.units || 'items' }}
          </template>
          <template v-else>
            {{ formatNumber(contractProgress.deliveredTons || 0) }} / {{ activeContract.requiredTons || 0 }} {{ activeContract.units || 'tons' }}
          </template>
        </div>
      </div>

      <div class="status-section">
        <template v-if="currentState === 'driving_to_site'">
          <div class="status-icon pulsing">📍</div>
          <div class="status-title" v-if="!markerCleared">Travel to Marker</div>
          <div class="status-title" v-else>In Loading Zone</div>
          <div class="status-message" v-if="!markerCleared">
            Drive to the quarry loading zone
          </div>
          <div class="status-message" v-else-if="!truckStopped">
            Waiting for truck to arrive...
          </div>
          <div class="status-message" v-else>
            Truck arrived. Ready to load.
          </div>
        </template>
        <template v-else>
          <div class="status-icon pulsing">🚚</div>
          <div class="status-title">Truck Arriving</div>
          <div class="status-message">Waiting for truck to arrive at loading zone...</div>
        </template>
      </div>

      <button class="action-button danger" @click="abandonContract">
        Abandon Contract
      </button>
    </div>

    <QuarryLoadingPanel
      v-if="currentState === 'loading'"
      :contract="activeContract"
      :zone-stock="zoneStock"
      :current-load-mass="currentLoadMass"
      :target-load="targetLoad"
      :load-percent="loadPercent"
      :material-type="materialType"
      :marble-blocks="marbleBlocks"
      :any-marble-damaged="anyMarbleDamaged"
      :truck-status="truckState.status"
      :zones="compatibleZones"
      :is-complete="isComplete"
      @send-truck="sendTruck"
      @swap-zone="swapZone"
      @abandon="abandonContract"
    />

    <div v-if="currentState === 'delivering'" class="state-panel">
      <div class="active-contract-info" v-if="activeContract">
        <div class="contract-name">{{ activeContract.name }}</div>
        <div class="contract-progress">
          <template v-if="activeContract.unitType === 'item'">
            {{ contractProgress.deliveredItems || 0 }} / {{ activeContract.requiredItems || 0 }} {{ activeContract.units || 'items' }}
          </template>
          <template v-else>
            {{ formatNumber(contractProgress.deliveredTons || 0) }} / {{ activeContract.requiredTons || 0 }} {{ activeContract.units || 'tons' }}
          </template>
        </div>
      </div>

      <!-- Delivering blocks info -->
      <div class="delivering-blocks" v-if="materialType === 'marble' && deliveryBlocks && deliveryBlocks.length > 0">
        <div class="delivering-header">Delivering:</div>
        <div
          v-for="block in deliveryBlocks.filter(b => b.isLoaded)"
          :key="block.index"
          class="delivering-block"
          :class="{ damaged: block.isDamaged }"
        >
          Block {{ block.index }} ({{ block.isDamaged ? 'DAMAGED' : 'OK' }})
        </div>
      </div>

      <button
        v-if="compatibleZones.length > 1 && !isComplete"
        class="action-button swap-zone"
        @click="swapZone"
      >
        Switch Zone
      </button>

      <button class="action-button danger" @click="abandonContract">
        Abandon Contract
      </button>
    </div>

    <QuarryCompletionPanel
      v-if="currentState === 'return_to_quarry' || currentState === 'at_quarry_decide'"
      :phase="currentState"
      :contract="activeContract"
      :progress="contractProgress"
      :progress-percent="progressPercent"
      :is-contract-complete="isContractComplete"
      :is-complete="isComplete"
      :zones="compatibleZones"
      @finalize="finalizeContract"
      @swap-zone="swapZone"
      @abandon="abandonContract"
    />

    <div v-if="showZoneModal" class="zone-modal-overlay">
      <button type="button" class="phone-overlay-dismiss" bng-no-nav="true" tabindex="-1" aria-label="Close overlay" @click="closeZoneModal"></button>
      <div class="zone-modal" v-bng-scoped-nav="modalScopes.zone" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
        <div class="modal-header">
          <div class="modal-title">Select Loading Zone</div>
          <button bng-scoped-nav-autofocus class="modal-close" @click="closeZoneModal">×</button>
        </div>
        <div class="modal-content">
          <div v-if="compatibleZones.length === 0" class="no-zones-modal">
            No compatible zones available
          </div>
          <button type="button"
            v-for="(zone, index) in compatibleZones"
            :key="zone.zoneTag"
            class="zone-option-card"
            @click="selectZone(index)"
          >
            <div class="zone-option-header">
              <span class="zone-option-name">{{ zone.displayName || zone.zoneTag }}</span>
            </div>
            <div class="zone-option-stock" v-if="zone.stock && zone.stock.materialStocks">
              <div
                v-for="(stock, matKey) in zone.stock.materialStocks"
                :key="matKey"
                class="zone-stock-item"
              >
                <span class="stock-label">{{ getMaterialDisplayNameWithUnits(matKey, zone) }}:</span>
                <span class="stock-value">{{ stock.current }}/{{ stock.max }}</span>
                <span class="stock-regen" v-if="stock.regenRate > 0">(+{{ stock.regenRate }}/hr)</span>
              </div>
            </div>
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>


import { nextTab } from '../../utils/controllerTabs.js'
import { openHouseConfirmation } from '../../components/house/index.js'
import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { vBcModalFocus } from '../../components/businessComputer/bcModalNav.js'
import { usePhoneAppLayers, usePhoneAppFocus } from './controllerLayers.js'
import { vBngUiNavScroll } from '@/common/directives'
import { ref, onMounted, onUnmounted } from 'vue'
import { useEvents } from '@/services/events'
import { lua } from '@/bridge'
import QuarryLoadingPanel from '../phoneQuarry/QuarryLoadingPanel.vue'
import QuarryCompletionPanel from '../phoneQuarry/QuarryCompletionPanel.vue'
import { usePhoneQuarryDerived } from '../phoneQuarry/usePhoneQuarryDerived.js'
import {
  formatDistance,
  formatNumber,
  formatTimeRemaining,
  getExpirationClass,
  getMaterialDelivered,
  getMaterialDisplayNameWithUnits,
  getMaterialProgressPercent,
  getStockLevelClass,
  getTierClass,
  getTimeRemaining,
  getTruckStatusIcon,
  getTruckStatusText,
  mergeMaterialNameAndUnit,
} from '../phoneQuarry/quarryMath.js'

usePhoneAppFocus()

function changePhoneTab(direction, event) {

  event?.stopPropagation()
  const next = nextTab([{ id: 'contracts' }, { id: 'stock' }], currentPage.value, direction)
  if (next) currentPage.value = next.id
}


const events = useEvents()

// Lua sends the screen as a number. Unknown numbers fall back to idle in handleStateUpdate.
const STATE_BY_NUMBER = {
  0: 'idle',
  1: 'contract_select',
  2: 'choosing_zone',      // Player choosing which zone to load from
  3: 'driving_to_site',
  4: 'truck_arriving',
  5: 'loading',
  6: 'delivering',
  7: 'return_to_quarry',
  8: 'at_quarry_decide'
}
const DEFAULT_TARGET_LOAD = 25000
const DEFAULT_QUARRY_UNLOCK_LEVEL = 10
// Ticks updateCounter once a second. No template reads updateCounter, so the tick changes no visible output.
const UPDATE_COUNTER_TICK_MS = 1000

// State owner. The template reads these directly; the loading and completion panels get them through props.
const currentState = ref('idle')
const contractsCompleted = ref(0)
const currentFacility = ref(null)
const currentPage = ref('contracts')
const operatorLevel = ref(0)
const quarryUnlocked = ref(false)
const quarryUnlockLevel = ref(DEFAULT_QUARRY_UNLOCK_LEVEL)

const availableContracts = ref([])
const activeContract = ref(null)
const contractProgress = ref({
  deliveredTons: 0,
  totalPaidSoFar: 0,
  deliveryCount: 0
})

const currentLoadMass = ref(0)
const targetLoad = ref(DEFAULT_TARGET_LOAD)
const materialType = ref('rocks')
const marbleBlocks = ref([])
const anyMarbleDamaged = ref(false)
const deliveryBlocks = ref([])

const markerCleared = ref(false)
const truckStopped = ref(false)

const truckState = ref({ status: 'none', truckId: null, currentZone: null, zoneSwapPending: false })
const allZonesStock = ref([])
const compatibleZones = ref([])
const showZoneModal = ref(false)
const { scopes: modalScopes, back: closeTopLayer } = usePhoneAppLayers({
  zone: { open: () => showZoneModal.value, close: () => closeZoneModal() },
})

const zoneModalShownForEntry = ref(false)
const allZonesByFacility = ref([])
const zoneStock = ref(null)
const isComplete = ref(false)
const currentSimTime = ref(null)
const updateCounter = ref(0)

// The template reads only these three. The pure formatting helpers live in phoneQuarry/quarryMath.js.
const {
  loadPercent,
  isContractComplete,
  progressPercent,
} = usePhoneQuarryDerived({ activeContract, contractProgress, currentLoadMass, targetLoad, currentSimTime })

const setZoneWaypoint = zoneTag => lua.overhaul_jobs_quarry_quarry.setZoneWaypointFromUI(zoneTag)
const acceptContract = index => lua.overhaul_jobs_quarry_quarry.acceptContractFromUI(index + 1)
const declineAll = async () => {
  if (await openHouseConfirmation('Decline all contracts?', 'Remove every available loading contract?', [{ label: 'Cancel', value: false, extras: { cancel: true } }, { label: 'Decline all', value: true, extras: { destructive: true } }])) return lua.overhaul_jobs_quarry_quarry.declineAllContracts()
}
const abandonContract = async () => {
  if (await openHouseConfirmation('Abandon contract?', 'End the current loading contract?', [{ label: 'Cancel', value: false, extras: { cancel: true } }, { label: 'Abandon', value: true, extras: { destructive: true } }])) return lua.overhaul_jobs_quarry_quarry.abandonContractFromUI()
}
const sendTruck = () => lua.overhaul_jobs_quarry_quarry.sendTruckFromUI()
const finalizeContract = () => lua.overhaul_jobs_quarry_quarry.finalizeContractFromUI()

const selectPage = page => {
  currentPage.value = page
}

const openZoneModal = () => {
  showZoneModal.value = true
}

const selectZone = zoneIndex => {
  lua.overhaul_jobs_quarry_quarry.selectZoneFromUI(zoneIndex + 1)
  showZoneModal.value = false
}

const swapZone = () => {
  lua.overhaul_jobs_quarry_quarry.swapZoneFromUI()
  zoneModalShownForEntry.value = true
  showZoneModal.value = true
}

const closeZoneModal = () => {
  showZoneModal.value = false
}

// State update handler: the one place where the Lua payload becomes view state.
const handleStateUpdate = (data) => {
  if (!data) return

  currentState.value = STATE_BY_NUMBER[data.state] || 'idle'
  contractsCompleted.value = data.contractsCompleted || 0
  operatorLevel.value = Number(data.operatorLevel || 0)
  quarryUnlocked.value = data.quarryUnlocked === true
  quarryUnlockLevel.value = Number(data.quarryUnlockLevel || DEFAULT_QUARRY_UNLOCK_LEVEL)
  currentFacility.value = data.currentFacility || null
  availableContracts.value = data.availableContracts || []
  activeContract.value = data.activeContract || null
  contractProgress.value = data.contractProgress || { deliveredTons: 0, totalPaidSoFar: 0, deliveryCount: 0, deliveredBlocks: { big: 0, small: 0, total: 0 } }
  currentLoadMass.value = data.currentLoadMass || 0
  targetLoad.value = data.targetLoad || DEFAULT_TARGET_LOAD
  materialType.value = data.materialType || 'rocks'
  marbleBlocks.value = data.itemBlocks || []
  anyMarbleDamaged.value = data.anyItemDamaged || false
  deliveryBlocks.value = data.deliveryBlocks || []
  markerCleared.value = data.markerCleared || false
  truckStopped.value = data.truckStopped || false
  truckState.value = data.truckState || { status: 'none', truckId: null, currentZone: null, zoneSwapPending: false }
  allZonesStock.value = data.allZonesStock || []
  compatibleZones.value = data.compatibleZones || []
  allZonesByFacility.value = data.allZonesByFacility || []
  zoneStock.value = data.zoneStock || null
  isComplete.value = data.isComplete || false
  if (data.currentSimTime !== undefined && data.currentSimTime !== null) {
    currentSimTime.value = data.currentSimTime
  }
  const hasCompatibleZones = compatibleZones.value && compatibleZones.value.length > 0
  if (data.state === 2 && hasCompatibleZones && !zoneModalShownForEntry.value) {
    zoneModalShownForEntry.value = true
    showZoneModal.value = true
  } else if (data.state !== 2) {
    zoneModalShownForEntry.value = false
    if (showZoneModal.value) showZoneModal.value = false
  }
}

const handleContractExpired = (data) => {
  if (data && data.contractId) {
    const index = availableContracts.value.findIndex(c => c.id === data.contractId)
    if (index !== -1) {
      availableContracts.value.splice(index, 1)
    }
  }
}

const handleContractGenerated = (data) => {
  if (data && data.contractData) {
    const contract = data.contractData
    const existingIndex = availableContracts.value.findIndex(c => c.id === contract.id)
    if (existingIndex === -1) {
      availableContracts.value.push(contract)
      availableContracts.value.sort((a, b) => {
        if (a.tier === b.tier) return a.totalPayout - b.totalPayout
        return a.tier - b.tier
      })
    }
  }
}

let expirationTimer = null

onMounted(() => {
  events.on('updateQuarryState', handleStateUpdate)
  events.on('contractExpired', handleContractExpired)
  events.on('contractGenerated', handleContractGenerated)
  // Request initial state using bngApi
  lua.overhaul_jobs_quarry_quarry.requestQuarryState()

  expirationTimer = setInterval(() => {
    updateCounter.value = updateCounter.value + 1
  }, UPDATE_COUNTER_TICK_MS)
})

onUnmounted(() => {
  events.off('updateQuarryState', handleStateUpdate)
  events.off('contractExpired', handleContractExpired)
  events.off('contractGenerated', handleContractGenerated)
  if (expirationTimer) {
    clearInterval(expirationTimer)
    expirationTimer = null
  }
})
</script>

<style scoped lang="scss">
.phone-overlay-dismiss { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; background: transparent; }
.zone-modal { position: relative; z-index: 1; }
.quarry-container {
  position: relative;
  width: 100%;
  height: 100%;
  // Pin em-based layout to phone chrome size (360x640); without this, em
  // inherits the game UI root and the app looks massively oversized.
  font-size: 14px;
  background: rgba(20, 20, 20, 0.95);
  overflow-y: auto;
  padding-top: 2em;
  padding-bottom: 0.75em;

  &:has(.idle-compact) {
    padding-top: 2em;
  }
}

.quarry-container::-webkit-scrollbar {
  width: 8px;
}

.quarry-container::-webkit-scrollbar-track {
  background: transparent;
}

.quarry-container::-webkit-scrollbar-thumb {
  background: rgba(255, 255, 255, 0.2);
  border-radius: 4px;
  border: 2px solid transparent;
  background-clip: padding-box;
}

.quarry-container::-webkit-scrollbar-thumb:hover {
  background: rgba(255, 255, 255, 0.3);
  background-clip: padding-box;
}

.facility-banner {
  margin: 8px 0.75em 0.5em 0.75em;
  padding: 0.6em 0.75em;
  border-radius: 10px;
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 102, 0, 0.3);
}

.facility-label {
  font-size: 0.75em;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.55);
  margin-bottom: 0.25em;
}

.facility-name {
  font-size: 1.1em;
  font-weight: 700;
  color: #fff;
}

.facility-banner.empty .facility-name {
  color: rgba(255, 255, 255, 0.6);
}
// State Panels
.state-panel {
  padding: 24px 0.75em 0.75em 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.6em;

  &.centered {
    align-items: center;
    justify-content: center;
    text-align: center;
    min-height: 100%;
    padding-top: 24%;
  }

  &.loading {
    padding-top: 0.5em;
    padding-bottom: 0.5em;
    gap: 0.5em;
  }

  &.idle-compact {
    padding-top: 0.75em;
    padding-bottom: 0.5em;
    gap: 0.75em;
  }
}
// Idle panel
.idle-header {
  text-align: center;
  margin-bottom: 0.25em;
}
.zones-by-facility-section {
  margin-top: 0;
  display: flex;
  flex-direction: column;
  gap: 0.6em;
  max-height: calc(100vh - 100px);
  overflow-y: auto;
  padding-right: 0.25em;
  padding-left: 0.25em;
}

.idle-info-message {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.6);
  text-align: center;
  padding: 0.25em 0.5em;
  margin-bottom: 0.5em;
}

.facility-group {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 102, 0, 0.3);
  border-radius: 10px;
  padding: 0.6em;
}

.facility-group-header {
  font-weight: 700;
  color: #ff6600;
  font-size: 1em;
  margin-bottom: 0.5em;
  padding-bottom: 0.4em;
  border-bottom: 1px solid rgba(255, 102, 0, 0.2);
}

.facility-zones-list {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.zone-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.5em;
  background: rgba(255, 255, 255, 0.05);
  border-radius: 6px;
  transition: background 0.2s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.1);
  }
}

.zone-item-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.2em;
}

.zone-item-name {
  font-weight: 600;
  color: #fff;
  font-size: 0.95em;
}

.zone-item-distance {
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.85em;
}

.zone-waypoint-button {
  padding: 0.4em 0.8em;
  background: linear-gradient(135deg, #ff6600, #ff9933);
  border: none;
  border-radius: 6px;
  color: #fff;
  font-weight: 600;
  font-size: 0.85em;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover {
    background: linear-gradient(135deg, #ff9933, #ff6600);
    transform: scale(1.05);
  }

  &:active {
    transform: scale(0.95);
  }
}

.centered-message {
  text-align: center;
  margin-top: 0.5em;
  padding: 1em;
}

// Active contract header
.active-contract-section {
  margin: 0.5em 0.75em 0.4em 0.75em;
}
.active-contract-card {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 102, 0, 0.3);
  border-radius: 10px;
  padding: 0.6em 0.75em;
  text-align: center;
}

.contract-name-row {
  display: flex;
  justify-content: center;
  align-items: center;
  gap: 0.5em;
  margin-bottom: 0.4em;
}

.contract-payout-badge {
  background: rgba(255, 102, 0, 0.2);
  color: #ff6600;
  padding: 0.2em 0.5em;
  border-radius: 6px;
  font-weight: 700;
  font-size: 0.9em;
}

.contract-progress-row {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.progress-bar-container {
  height: 6px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 3px;
  overflow: hidden;
}

.progress-bar {
  height: 100%;
  background: linear-gradient(90deg, #ff6600, #ff9933);
  border-radius: 3px;
  transition: width 0.3s ease;
}

.progress-text {
  font-size: 0.8em;
  color: rgba(255, 255, 255, 0.8);
  display: flex;
  align-items: center;
  gap: 0.4em;
}

.progress-percent {
  color: #ff6600;
  font-weight: 600;
}

.material-progress-item {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  margin-bottom: 0.5em;

  &:last-child {
    margin-bottom: 0;
  }
}

.material-progress-label {
  font-size: 0.8em;
  color: rgba(255, 255, 255, 0.7);
  font-weight: 600;
}

// Truck status
.truck-status-section {
  margin: 0 0.75em 0.4em 0.75em;
}

.truck-status-card {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  padding: 0.5em 0.75em;
  display: flex;
  align-items: center;
  gap: 0.6em;
}

.truck-status-icon {
  font-size: 1.6em;

  &.pulsing {
    animation: pulse 2s ease-in-out infinite;
  }
}

.truck-status-info {
  flex: 1;
}

.truck-status-text {
  font-weight: 600;
  color: #fff;
  font-size: 0.9em;
  margin-bottom: 0.15em;
}

.truck-status-location {
  font-size: 0.8em;
  color: rgba(255, 255, 255, 0.6);
}

// Contract selection: list, tabs, contract cards
.contract-list {
  padding: 8px 0.75em 0.5em 0.75em;
  display: flex;
  flex-direction: column;
  height: 100%;
}

.page-tabs {
  display: flex;
  gap: 0.4em;
  margin: 0.5em 0.75em;
  padding-bottom: 0.4em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.tab-button {
  flex: 1;
  padding: 0.5em 0.9em;
  background: transparent;
  border: none;
  border-bottom: 2px solid transparent;
  color: rgba(255, 255, 255, 0.6);
  font-weight: 600;
  font-size: 0.9em;
  cursor: pointer;
  transition: all 0.2s ease;

  &.active {
    color: #ff6600;
    border-bottom-color: #ff6600;
  }

  &:hover {
    color: #fff;
  }
}

.contracts-page {
  display: flex;
  flex-direction: column;
  flex: 1;
}

// The same title block heads the contracts page and the stock page.
.contracts-header,
.stock-header {
  margin-bottom: 0.6em;

  .header-title {
    font-size: 1.2em;
    font-weight: 700;
    color: #fff;
  }

  .header-subtitle {
    font-size: 0.85em;
    color: rgba(255, 255, 255, 0.6);
  }
}

.contracts-scroll {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  margin-bottom: 0.5em;
  padding-right: 0.25em;
}

.no-contracts,
.no-zones,
.no-zones-modal {
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
  padding: 2em;
}

.facility-name-bottom {
  text-align: center;
  color: rgba(255, 255, 255, 0.7);
  font-size: 0.9em;
  margin-top: 0.5em;
  padding-bottom: 0.5em;
}

.contract-card {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  padding: 0.6em 0.75em;
  text-align: left;
  transition: all 0.2s ease;

  &.tier-1 { border-left: 3px solid #22c55e; }
  &.tier-2 { border-left: 3px solid #60a5fa; }
  &.tier-3 { border-left: 3px solid #ff6600; }
  &.tier-4 { border-left: 3px solid #f87171; }
}

.contract-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.5em;

  .contract-name {
    font-weight: 600;
    color: #fff;
    font-size: 1em;
  }

  .contract-payout {
    font-weight: 700;
    color: #4ade80;
    font-size: 1.1em;
  }
}

.contract-details {
  display: flex;
  gap: 0.4em;
  margin-bottom: 0.4em;
  flex-wrap: wrap;
}

.tier-badge, .material-badge, .location-badge {
  font-size: 0.75em;
  padding: 0.2em 0.5em;
  border-radius: 4px;
  font-weight: 600;
}

.tier-badge {
  &.tier-1 { background: rgba(74, 222, 128, 0.2); color: #4ade80; }
  &.tier-2 { background: rgba(96, 165, 250, 0.2); color: #60a5fa; }
  &.tier-3 { background: rgba(251, 191, 36, 0.2); color: #fbbf24; }
  &.tier-4 { background: rgba(248, 113, 113, 0.2); color: #f87171; }
}

.material-badge {
  background: rgba(255, 255, 255, 0.15);
  color: rgba(255, 255, 255, 0.9);
}

.location-badge {
  background: rgba(147, 51, 234, 0.2);
  color: #c084fc;
}

.contract-info {
  display: flex;
  justify-content: space-between;
  font-size: 0.8em;
  color: rgba(255, 255, 255, 0.6);
}

.contract-modifiers {
  display: flex;
  gap: 0.4em;
  margin-top: 0.5em;
  flex-wrap: wrap;
}

.modifier-badge {
  font-size: 0.7em;
  padding: 0.15em 0.4em;
  border-radius: 3px;
  background: rgba(251, 191, 36, 0.2);
  color: #fbbf24;
  font-weight: 500;
}

.urgent-badge {
  font-size: 0.7em;
  padding: 0.15em 0.5em;
  border-radius: 3px;
  background: linear-gradient(135deg, rgba(255, 140, 0, 0.3), rgba(255, 80, 0, 0.3));
  color: #ff8c00;
  font-weight: 600;
  animation: urgentPulse 1.5s ease-in-out infinite;
}

@keyframes urgentPulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.7; }
}

.contract-card.urgent {
  border-color: rgba(255, 140, 0, 0.5);
  background: linear-gradient(135deg, rgba(255, 140, 0, 0.1), rgba(255, 255, 255, 0.08));
}

.contract-expiration {
  font-size: 0.75em;
  margin-top: 0.4em;
  padding: 0.3em 0.5em;
  border-radius: 4px;
}

.contract-expiration.expiring-soon {
  background: rgba(255, 100, 100, 0.2);
  color: #ff6b6b;
  animation: expiringBlink 1s ease-in-out infinite;
}

@keyframes expiringBlink {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.6; }
}

.contract-expiration.expiring-warning {
  background: rgba(255, 180, 100, 0.15);
  color: #ffb464;
}

.contract-expiration.expiring-normal {
  background: rgba(100, 100, 100, 0.15);
  color: rgba(255, 255, 255, 0.5);
}

.accept-button {
  width: 100%;
  margin-top: 0.5em;
  padding: 0.5em 0.9em;
  background: linear-gradient(135deg, #ff6600, #ff9933);
  border: none;
  border-radius: 8px;
  color: #fff;
  font-weight: 600;
  font-size: 0.9em;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover {
    background: linear-gradient(135deg, #ff9933, #ff6600);
    transform: scale(1.02);
  }

  &:active {
    transform: scale(0.98);
  }
}
.material-breakdown {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  margin-bottom: 0.4em;
}

.material-breakdown-item {
  font-size: 0.9em;
  color: rgba(255, 255, 255, 0.9);
}

// Contract selection: stock tab
.stock-page {
  display: flex;
  flex-direction: column;
  flex: 1;
  padding: 0 0.75em;
}

.zones-scroll {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  padding-right: 0.25em;
  padding-bottom: 2em;
}

.zone-stock-card {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  padding: 0.6em 0.75em;
}

.zone-header {
  margin-bottom: 0.5em;
}

.zone-name {
  font-weight: 700;
  color: #fff;
  font-size: 1.1em;
}

.zone-materials {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.material-stock-item {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.material-name {
  font-size: 0.9em;
  color: rgba(255, 255, 255, 0.8);
  font-weight: 500;
}

.stock-info {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.stock-bar-container {
  height: 6px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 3px;
  overflow: hidden;
}

.stock-bar {
  height: 100%;
  border-radius: 3px;
  transition: width 0.3s ease;

  &.low {
    background: #ef4444;
  }

  &.medium {
    background: #ff6600;
  }

  &.high {
    background: #22c55e;
  }

  &.empty {
    background: rgba(255, 255, 255, 0.2);
  }
}

.stock-text {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.7);
  display: flex;
  align-items: center;
  gap: 0.3em;
}

.stock-current {
  font-weight: 600;
  color: #fff;
}

.stock-separator {
  opacity: 0.5;
}

.stock-max {
  opacity: 0.7;
}

// Delivering blocks
.delivering-blocks {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  padding: 0.75em;

  .delivering-header {
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.9em;
    margin-bottom: 0.5em;
  }

  .delivering-block {
    font-size: 0.85em;
    color: #4ade80;
    padding: 0.2em 0;

    &.damaged {
      color: #fbbf24;
      opacity: 0.7;
    }
  }
}

// Zone selection modal
.zone-modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.8);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.zone-modal {
  background: rgba(20, 20, 20, 0.98);
  border: 2px solid rgba(255, 102, 0, 0.5);
  border-radius: 16px;
  width: 90%;
  max-width: 400px;
  max-height: 80vh;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.modal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 1em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.modal-title {
  font-size: 1.2em;
  font-weight: 700;
  color: #fff;
}

.modal-close {
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.7);
  font-size: 1.5em;
  cursor: pointer;
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 4px;
  transition: all 0.2s ease;

  &:hover {
    background: rgba(255, 102, 0, 0.2);
    color: #ff6600;
  }
}

.modal-content {
  flex: 1;
  overflow-y: auto;
  padding: 1em;
  padding-bottom: 2em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.zone-option-card {
  font: inherit; color: inherit; text-align: left; width: 100%;
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 12px;
  padding: 0.75em;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover {
    border-color: rgba(255, 102, 0, 0.5);
    background: rgba(30, 30, 30, 1);
  }
}

.zone-option-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.5em;
}

.zone-option-name {
  font-weight: 700;
  color: #fff;
  font-size: 1em;
}

.zone-option-materials {
  font-size: 0.75em;
  color: rgba(255, 255, 255, 0.6);
  padding: 0.2em 0.5em;
  background: rgba(255, 102, 0, 0.15);
  border-radius: 4px;
}

.zone-option-stock {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.zone-stock-item {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.7);
  display: flex;
  align-items: center;
  gap: 0.5em;
}

.stock-label {
  font-weight: 500;
}

.stock-value {
  color: #fff;
  font-weight: 600;
}

// Panel skin shared with QuarryLoadingPanel and QuarryCompletionPanel (reached with :deep) and this file's own panels.
.idle-icon {
  font-size: 2em;
  margin-bottom: 0.25em;
}
.idle-title {
  font-size: 1.3em;
  font-weight: 700;
  color: #fff;
  margin-bottom: 0;
}
.state-icon {
  font-size: 2.5em;
  margin-bottom: 0.25em;

  &.pulsing {
    animation: pulse 2s ease-in-out infinite;
  }
}

@keyframes pulse {
  0%, 100% { transform: scale(1); opacity: 1; }
  50% { transform: scale(1.1); opacity: 0.8; }
}

.state-title {
  font-size: 1.5em;
  font-weight: 700;
  color: #fff;

  &.complete {
    color: #4ade80;
  }
}

.state-message {
  color: rgba(255, 255, 255, 0.7);
  font-size: 1em;
  max-width: 280px;
}
// Active Contract Info
:deep(.active-contract-info) {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 102, 0, 0.3);
  border-radius: 10px;
  padding: 0.75em;

  &.compact {
    padding: 0.5em 0.75em;
    margin-bottom: 0.5em;
  }

  .contract-name {
    font-weight: 600;
    color: #fff;
    font-size: 1em;
    margin-bottom: 0.25em;
  }

  &.compact .contract-name {
    font-size: 0.9em;
    margin-bottom: 0.2em;
  }

  .contract-progress {
    font-size: 0.9em;
    color: rgba(255, 255, 255, 0.8);

    &.complete {
      color: #4ade80;
    }
  }

  &.compact .contract-progress {
    font-size: 0.85em;
  }

  .complete-badge {
    background: #4ade80;
    color: #000;
    padding: 0.1em 0.4em;
    border-radius: 4px;
    font-size: 0.8em;
    font-weight: 700;
    margin-left: 0.5em;
  }

  .payout-info {
    font-size: 0.9em;
    color: #ff6600;
    margin-top: 0.25em;
    font-weight: 600;

    &.complete {
      color: #22c55e;
      font-size: 1em;
    }
  }
}

// Status Section
:deep(.status-section) {
  text-align: center;
  padding: 1.5em 0;
}
// Action Buttons
:deep(.action-button) {
  width: 100%;
  padding: 0.7em;
  border: none;
  border-radius: 12px;
  font-size: 1em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover {
    transform: scale(1.02);
  }

  &.primary {
    background: linear-gradient(135deg, #ff6600, #ff9933);
    color: #fff;

    &:hover {
      background: linear-gradient(135deg, #ff9933, #ff6600);
    }
  }

  &.success {
    background: linear-gradient(135deg, #22c55e, #16a34a);
    color: #fff;
  }

  &.danger {
    background: linear-gradient(135deg, #ef4444, #dc2626);
    color: #fff;
  }

  &.decline {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.8);

    &:hover {
      background: rgba(239, 68, 68, 0.3);
      color: #f87171;
    }
  }

  &.small {
    padding: 0.6em;
    font-size: 0.9em;
    background: rgba(239, 68, 68, 0.2);
    color: #f87171;

    &:hover {
      background: rgba(239, 68, 68, 0.4);
    }
  }

  &.swap-zone {
    background: linear-gradient(135deg, #ff6600, #ff9933);
    color: #fff;

    &:hover {
      background: linear-gradient(135deg, #ff9933, #ff6600);
    }
  }
}
.section-header {
  font-size: 0.7em;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.55);
  margin-bottom: 0.35em;
  margin-top: 2em;
}
.stock-regen {
  color: #ff6600;
  font-size: 0.9em;
  margin-left: 0.3em;
}
</style>
