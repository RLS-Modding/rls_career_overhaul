<template>
  <div ref="auctionRoot" class="rls-house auction-overlay-layout ua-overlay-root" :aria-busy="busy"
    :inert="inputSuspended ? true : undefined" :bng-uinav-suppressed="inputSuspended || controllerWalking ? '' : undefined"
    v-bng-scoped-nav="navScope">
    <AuctionStrip v-if="controllerWalking && !isEntryPrompt && !state.counterPromptActive"
      :lot="activeLot" :state="state" :music-state="musicState" :busy="busy" @bid="bid(250)" @music-command="musicCommand" @leave="leaveAuction" can-restore :back-binding="controllerBackBinding" hold-to-restore @restore="interactWithAuction" />
    <AuctionEntryPrompt
      v-if="isEntryPrompt"
      :message="entryPromptStatus"
      :fee="entryFee"
      :can-pay="canPayEntry && !busy"
      @pay="startAuctionFromPrompt"
      @cancel="cancelEntryPrompt" />
    <AuctionCounter
      v-else-if="state.counterPromptActive"
      v-model:tab="counterTab"
      v-model:offer-id="selectedOfferId"
      :state="state"
      :busy="busy"
      :can-register="canRegister"
      :register-blocked-reason="registerBlockedReason"
      :can-list-vehicle="canListVehicle"
      :listing-count="listingCount"
      @batch="setBatchSize"
      @register="command('confirmRegisterNextLot', selectedOfferId, state.lotBatchSize || 10)"
      @list="row => command('listVehicleForNextAnythingGoesAuction', row.inventoryId)"
      @unlist="unlistVehicle"
      @close="command('cancelCounterPrompt', true)" />
    <div
      v-if="!isEntryPrompt"
      v-show="!controllerWalking"
      class="ua-vault-session-stack auction-overlay"
      :inert="state.counterPromptActive ? true : undefined"
      :bng-no-child-nav="state.counterPromptActive ? 'true' : null"
      :style="{ transform: `translate(${panelOffset.x}px, ${panelOffset.y}px)` }"
    >
      <div :class="showMainAuctionPanel ? 'ua-panel' : 'ua-vault-shell'" v-bng-ui-nav-scroll.force>
        <div
          :class="showMainAuctionPanel ? 'ua-header' : 'ua-vault-shell-header'"
          @pointerdown="startPanelDrag"
          @pointermove="movePanel"
          @pointerup="endPanelDrag"
          @pointercancel="endPanelDrag"
          @lostpointercapture="endPanelDrag"
        >
          <div class="ua-header-left"
            ><div class="ua-title">{{ showMainAuctionPanel ? 'Used Car Auction' : 'The Vault' }}</div
            ><div v-if="showMainAuctionPanel && state.totalLots > 0" class="ua-subtitle"
              >{{ state.totalLots }} lots</div
            ></div
          >
          <div class="ua-header-badges">
            <Transition name="ua-pill">
              <div v-if="controllerWalking" class="ua-mode-pill">Walking</div>
            </Transition>
            <div class="ua-phase-badge" :class="phaseClass">{{ phaseLabel }}</div>
          </div>
        </div>
        <div class="ua-stats-inline">
          <div class="ua-stat-item"
            ><span class="ua-stat-k">Wins</span><span class="ua-stat-v">{{ state.purchasedCount || 0 }}</span></div
          ><div class="ua-stat-sep"></div>
          <div class="ua-stat-item"
            ><span class="ua-stat-k">Balance</span
            ><span class="ua-stat-v">${{ formatCurrency(state.playerBalance) }}</span></div
          >
          <template v-if="showMainAuctionPanel && activeLot"
            ><div class="ua-stat-sep"></div
            ><div class="ua-stat-item"
              ><span class="ua-stat-k">Live</span><span class="ua-stat-v">Lot {{ activeLot.lotIndex }}</span></div
            ></template
          >
        </div>
        <div v-if="yourLots.length" class="ua-your-lots">Your lots: {{ yourLots.length }} in this auction</div>
        <AuctionMusicPlayer
          v-if="state.musicEnabled !== null"
          class="ua-music-player"
          :state="musicState"
          :active="!inputSuspended && !controllerWalking"
          @command="musicCommand"
        />
        <div v-if="!showMainAuctionPanel" class="ua-vault-cta">{{
          state.statusMessage || 'Visit the auction counter to register a lot group.'
        }}</div>
        <template v-else>
          <div class="ua-table" id="ua-lot-table">
            <div class="ua-table-head"
              ><div class="ua-col-lot">Lot</div><div class="ua-col-vehicle">Vehicle</div
              ><div class="ua-col-mileage">Mileage</div><div class="ua-col-status">Status</div></div
            >
            <div class="ua-table-body" v-bng-ui-nav-scroll.force>
              <div
                v-for="lot in state.lots || []"
                :key="lot.lotIndex"
                :id="'ua-lot-' + lot.lotIndex"
                class="ua-table-row"
                :class="{
                  active: isActiveLot(lot),
                  finished: lot.state === 'finished',
                  won: isLotWon(lot),
                  'your-lot': lot.isPlayerListing
                }"
              >
                <div class="ua-col-lot"
                  ><span class="ua-lot-num">{{ lot.lotIndex }}</span></div
                ><div class="ua-col-vehicle" :title="lot.title || '-'"><span class="ua-vehicle-name">{{ lot.title || '-' }}</span><small v-if="lot.isPlayerListing" class="ua-your-lot-label">Your lot</small></div
                ><div class="ua-col-mileage">{{ formatMileage(lot.mileage) }}</div
                ><div class="ua-col-status"
                  ><span class="ua-lot-badge" :class="lotBadgeClass(lot)">{{ lotStatusLabel(lot) }}</span></div
                >
              </div>
              <div v-if="!state.lots?.length" class="ua-empty">No active lots.</div>
            </div>
          </div>
          <div v-if="activeLot" class="ua-bidding-section">
            <div class="ua-bid-info">
              <div class="ua-bid-main">
                <div class="ua-bid-amount-wrap" :class="{ waiting: !isLiveBidLot }"
                  ><span class="ua-bid-label">{{ isLiveBidLot ? 'Current Bid' : 'Awaiting Lot' }}</span
                  ><span v-if="isLiveBidLot" class="ua-bid-amount"
                    >${{ formatCurrency(activeLot.currentBid) }}</span
                  ></div
                >
                <div
                  v-if="isLiveBidLot"
                  class="ua-bid-leader-wrap"
                  :class="activeLot.highestBidder === 'player' ? 'leader-player' : 'leader-npc'"
                  ><span class="ua-bid-leader-indicator"></span
                  ><span class="ua-bid-leader-name">{{ formatBidder(activeLot) }}</span></div
                >
                <div v-else class="ua-bid-waiting-text">Lot is moving to the block</div>
              </div>
              <div v-if="isLiveBidLot" class="ua-timer" :class="timerClass"
                ><svg viewBox="0 0 36 36" class="ua-timer-ring" aria-hidden="true">
                  <circle cx="18" cy="18" r="16" fill="none" stroke="rgba(255,255,255,0.08)" stroke-width="3" />
                  <circle
                    cx="18"
                    cy="18"
                    r="16"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="3"
                    :stroke-dasharray="timerDash"
                    transform="rotate(-90 18 18)"
                    stroke-linecap="round"
                  /></svg
                ><span class="ua-timer-text">{{ activeLot.timeLeft || 0 }}s</span></div
              >
              <div v-else class="ua-timer-waiting"
                ><svg viewBox="0 0 36 36" class="ua-spinner-ring" aria-hidden="true">
                  <circle cx="18" cy="18" r="16" fill="none" stroke="rgba(255,255,255,0.08)" stroke-width="3" />
                  <circle
                    cx="18"
                    cy="18"
                    r="16"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="3"
                    stroke-dasharray="25 75.5"
                    stroke-linecap="round"
                  /></svg
              ></div>
            </div>
            <div v-if="state.bidMessage" class="ua-bid-hint">{{ state.bidMessage }}</div>
            <div v-if="activeLot.isPlayerListing" class="ua-bid-blocked"
              >This lot is your consignment. You cannot bid on it.</div
            >
            <div v-else-if="state.hasFreeGarageSlot === false" class="ua-bid-blocked"
              >No free garage slot. You cannot bid on vehicles.</div
            >
            <div v-if="canBid" class="ua-actions actions">
              <button
                type="button"
                bng-nav-item
                v-bng-ui-nav-focus
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                v-for="amount in bidAmounts"
                :key="amount"
                class="ua-btn ua-btn-bid"
                :disabled="!canAffordBid(amount) || busy"
                :bng-no-nav="!canAffordBid(amount) || busy ? 'true' : null"
                @click="bid(amount)"
                ><span class="ua-btn-increment">+${{ formatCurrency(bidIncrement(amount)) }}</span
                ><span class="ua-btn-total">${{ formatCurrency((activeLot.currentBid || 0) + bidIncrement(amount)) }}</span></button
              >
            </div>
            <div v-if="canBid && !canAffordBid(250)" class="ua-bid-blocked"
              >Not enough funds to bid on this vehicle.</div
            >
            <div v-if="isLiveBidLot && activeLot.highestBidder === 'player'" class="ua-winning-banner"
              >You are the highest bidder</div
            >
          </div>
        </template>
        <AuctionControlBar :mode="controlMode" :back-binding="controllerBackBinding" :holding="controllerHolding" :hold-ms="PANEL_CONTROLLER_HOLD_MS" />
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { callModLua } from '../utils/installLuaBridgeFallbacks'
import { openHouseConfirmation } from '../components/house/index.js'
import AuctionEntryPrompt from '../components/AuctionEntryPrompt.vue'
import AuctionCounter from '../components/AuctionCounter.vue'
import { returnFocusToOpener } from '../composables/useScreenEntryFocus'
import { BngIcon, icons } from '@/common/components/base'
import { vBngUiNavFocus, vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from '@/common/directives'
import AuctionMusicPlayer from '../components/AuctionMusicPlayer.vue'
import AuctionControlBar from '../components/AuctionControlBar.vue'
import AuctionStrip from '../components/AuctionStrip.vue'
import { auctionCanBid, auctionCanAffordBid, auctionBidIncrement, auctionBidAmounts } from '../utils/auctionBidRules.js'
import { refocusIfLost, useScreenEntry } from '../composables/useScreenEntryFocus'
import { bigLengthUnit, formatOdometer, METERS_PER_MILE } from '../utils/units'
import { useScopedNav } from '@/services/scopedNav/api'
import useControls from '@/services/controls'
import { useUINavTracker } from '@/services/uiNavTracker'
import { createPanelControllerBack, PANEL_CONTROLLER_HOLD_MS } from '../utils/panelControllerBack'

const { units, events } = useBridge()
const focusEntry = useScreenEntry()
const scopedNav = useScopedNav()
const auctionRoot = ref(null)
const inputSuspended = ref(false)
const controllerWalking = ref(false)
const controls = useControls()
const navTracker = useUINavTracker()
const isGamepad = computed(() => controls.isControllerUsed)
// A passive scope intentionally hides ui-event bindings. Resolve the same
// stock mapping as a display-only binding so the way back stays visible.
const controllerBackBinding = computed(() => controls.makeViewerObj({ uiEvent: 'back', controller: true }))
const controllerHolding = ref(false)
const controlMode = computed(() => controllerWalking.value ? 'walk' : isGamepad.value ? 'panel' : 'pointer')
const backOwner = 'auction-controller-back'
const retainControllerBack = () => navTracker?.addEvent('back', backOwner, document.body)
const releaseControllerBack = () => navTracker?.removeEvent('back', backOwner)
let screenClosing = false
let focusGeneration = 0
const focusAuctionEntry = (options = {}) => {
  if (inputSuspended.value || controllerWalking.value || isUnmounted) return
  const generation = focusGeneration
  return focusEntry('used-car-auction', {
    ...options, isCurrent: () => !inputSuspended.value && !controllerWalking.value && !isUnmounted && generation === focusGeneration,
  })
}
const releaseAuctionGamepad = () => {
  ++focusGeneration
  auctionRoot.value?.setAttribute('bng-uinav-suppressed', '')
  if (auctionRoot.value?.contains(document.activeElement)) document.activeElement?.blur?.()
  void scopedNav?.deactivateScope('used-car-auction', { force: true, resumePrevious: false })
  // Suppression is a live DOM boundary; stock does not observe its mutations.
  navTracker?.refreshActionStates?.()
}
const releaseAuctionInput = () => {
  inputSuspended.value = true
  controllerBack.cancel()
  releaseControllerBack()
  // Suppress the DOM immediately: the nav tracker can otherwise reclaim the
  // pad while a route transition still has this screen mounted.
  auctionRoot.value?.setAttribute('bng-uinav-suppressed', '')
  auctionRoot.value?.setAttribute('inert', '')
  releaseAuctionGamepad()
}
const hideAuctionInput = () => {
  screenClosing = true
  releaseAuctionInput()
}
const resumeAuctionInput = () => {
  if (screenClosing || isUnmounted || document.hidden) return
  inputSuspended.value = false
  retainControllerBack()
  if (!controllerWalking.value) auctionRoot.value?.removeAttribute('bng-uinav-suppressed')
  auctionRoot.value?.removeAttribute('inert')
  navTracker?.refreshActionStates?.()
  void focusAuctionEntry({ force: true })
}
const auctionVisibilityChanged = () => document.hidden ? releaseAuctionInput() : resumeAuctionInput()

const defaultState = () => ({
  phase: 'idle',
  musicEnabled: true,
  entryPromptActive: false,
  entryFee: 1000,
  canPayEntryFee: false,
  hasFreeGarageSlot: true,
  activeLotIndex: 1,
  currentLotIndex: null,
  statusMessage: '',
  purchasedCount: 0,
  bidMessage: '',
  lots: []
})

const state = ref(defaultState())
const panelOffset = ref({ x: 0, y: 0 })
let panelDrag = null
const startPanelDrag = (event) => {
  if (!showMainAuctionPanel.value || event.button !== 0) return
  const bounds = event.currentTarget.closest('.ua-vault-session-stack').getBoundingClientRect()
  panelDrag = { x: event.clientX, y: event.clientY, offset: panelOffset.value, bounds }
  event.currentTarget.setPointerCapture(event.pointerId)
}
const movePanel = (event) => {
  if (!panelDrag) return
  const { x, y, offset, bounds } = panelDrag
  panelOffset.value = {
    x: offset.x + Math.max(-bounds.left, Math.min(window.innerWidth - bounds.right, event.clientX - x)),
    y: offset.y + Math.max(-bounds.top, Math.min(window.innerHeight - bounds.bottom, event.clientY - y))
  }
}
const endPanelDrag = () => {
  panelDrag = null
}
const counterTab = ref('auctions')
const selectedOfferId = ref(null)
const busy = ref(false)
let pendingBatchSize = null
let requestedBatchSize = null
let acceptedBatchSize = null
let batchSizeRevision = 0
let batchSizeCommandInFlight = false
let leaveInFlight = false
const selectedOffer = computed(() => state.value.counterOffers?.find(offer => offer.id === selectedOfferId.value))
const hasEntryCapacity = computed(() => state.value.hasFreeGarageSlot !== false || state.value.hasValidConsignment === true)
const hasRegistrationCapacity = computed(() => hasEntryCapacity.value &&
  (state.value.hasFreeGarageSlot !== false || selectedOfferId.value === 'anything_goes'))
// Why Generate is unavailable, in the order the player can fix it; "" when only a pick is missing.
const registerBlockedReason = computed(() => {
  if (state.value.canRegisterMoreLots === false) return 'Finish the current lot group before registering another.'
  if (!hasRegistrationCapacity.value) return 'You need a free garage slot or an Anything Goes consignment to register a lot group.'
  if (selectedOffer.value && !canRegister.value) return 'Not enough money to register this auction type.'
  return ''
})
const canRegister = computed(() => !!selectedOffer.value && state.value.canRegisterMoreLots !== false &&
  hasRegistrationCapacity.value && (Number(state.value.playerBalance) || 0) >= (selectedOffer.value.registrationFee || 0))
// Lua's listing rule decides; a reason means the car can't be listed right now
const listingCount = computed(() => state.value.listedVehicleInventoryIds?.length ?? (state.value.listedVehicleInventoryId != null ? 1 : 0))
const yourLots = computed(() => Array.isArray(state.value.lots) ? state.value.lots.filter(lot => lot.isPlayerListing) : [])
const canListVehicle = row => !!row && !row.listedForAuction && !row.listingPending && !row.listBlockedReason
const bidIncrement = amount => auctionBidIncrement(activeLot.value, amount)
const bidAmounts = computed(() => auctionBidAmounts(activeLot.value))
const canAffordBid = amount => auctionCanAffordBid(state.value, activeLot.value, amount)
const command = async (name, ...args) => {
  if (isUnmounted || busy.value) return
  busy.value = true
  const changesBatchSize = name === 'setCounterLotBatchSize'
  try {
    if (changesBatchSize) batchSizeCommandInFlight = true
    try {
      const result = await getAuctionApi()?.[name]?.(...args)
      if (changesBatchSize && !isUnmounted && Number.isFinite(result)) {
        acceptedBatchSize = result
        if (pendingBatchSize == null) requestedBatchSize = result
      }
    } catch (error) {
      if (changesBatchSize && pendingBatchSize == null) requestedBatchSize = acceptedBatchSize
      throw error
    } finally {
      if (changesBatchSize) batchSizeCommandInFlight = false
    }
    await refresh()
  } finally {
    busy.value = false
    if (pendingBatchSize != null && !isUnmounted) {
      const next = pendingBatchSize
      pendingBatchSize = null
      await command('setCounterLotBatchSize', next)
    }
  }
}
const setBatchSizeAbsolute = async (value) => {
  if (isUnmounted) return
  const opener = document.activeElement
  pendingBatchSize = Math.max(5, Math.min(25, Math.round(Number(value)) || 10))
  requestedBatchSize = pendingBatchSize
  batchSizeRevision++
  if (busy.value) return
  const next = pendingBatchSize
  pendingBatchSize = null
  await command('setCounterLotBatchSize', next)
  if (!isUnmounted) refocusIfLost(() => inputSuspended.value || controllerWalking.value || isUnmounted ? null : opener)
}
const setBatchSize = (delta) => setBatchSizeAbsolute((requestedBatchSize ?? state.value.lotBatchSize ?? 10) + delta)
const unlistVehicle = row => {
  if ((!row?.listedForAuction && !row?.listingPending) || row.listingInSession || !Number.isFinite(Number(row.inventoryId))) return
  return command('cancelAuctionListing', Number(row.inventoryId))
}
const musicState = ref({})
const musicCommands = {
  uiPlay: () => callModLua('overhaul_phone_musicPlayer.uiPlay'),
  uiStop: () => callModLua('overhaul_phone_musicPlayer.uiStop'),
  uiPrevious: () => callModLua('overhaul_phone_musicPlayer.uiPrevious'),
  uiNext: () => callModLua('overhaul_phone_musicPlayer.uiNext'),
  uiToggleShuffle: () => callModLua('overhaul_phone_musicPlayer.uiToggleShuffle'),
  uiToggleRepeat: () => callModLua('overhaul_phone_musicPlayer.uiToggleRepeat'),
  uiSetVolume: (value) => callModLua('overhaul_phone_musicPlayer.uiSetVolume', value),
  setActivePlaylist: (name) => callModLua('overhaul_phone_musicPlayer.setActivePlaylist', name)
}
let playbackCommandsInFlight = 0
let musicCommandsInFlight = 0
let musicRevision = 0
let playbackRevision = 0
let musicSnapshotRevision = 0
let appliedMusicSnapshotRevision = 0
let musicPreferenceRevision = 0
let musicPreferencesInFlight = 0
let requestedPlayback = null
let acceptedPlayback = null
let musicQueue = Promise.resolve()
const clampVolume = value => Math.max(0, Math.min(1, Math.round((Number(value) || 0) * 100) / 100))
const musicCommand = (name, ...args) => {
  if (isUnmounted) return Promise.resolve()
  const revision = ++musicRevision
  if (name === 'uiSetVolume') args[0] = clampVolume(args[0])
  const toggle = name === 'togglePlayback'
  if (toggle) name = (requestedPlayback ?? acceptedPlayback ?? !!musicState.value.isPlaying) ? 'uiStop' : 'uiPlay'
  const trackPlayback = name === 'uiNext' || name === 'uiPrevious'
  const playback = name === 'uiPlay' || name === 'uiStop' || trackPlayback
  if (playback) {
    requestedPlayback = name !== 'uiStop'
    playbackRevision = revision
    playbackCommandsInFlight++
  }
  musicCommandsInFlight++
  const running = musicQueue.then(async () => {
    try {
      if (isUnmounted) return
      let result
      try {
        result = await musicCommands[name](...args)
      } catch (error) {
        if (playback && playbackRevision === revision) requestedPlayback = acceptedPlayback
        throw error
      }
      if (isUnmounted) return
      if (playback) {
        acceptedPlayback = name !== 'uiStop' && result !== false
        if (playbackRevision === revision) requestedPlayback = acceptedPlayback
        if (toggle || trackPlayback) await setAuctionMusicEnabled(acceptedPlayback)
      }
    } finally {
      musicCommandsInFlight--
      if (playback) playbackCommandsInFlight--
    }
    await refreshMusic()
  })
  // A rejected command must not prevent a newer queued intent from running.
  musicQueue = running.catch(() => {})
  return running
}
const refreshMusic = async () => {
  if (isUnmounted || musicCommandsInFlight || isEntryPrompt.value || state.value.counterPromptActive || globalThis.document?.hidden) return
  const revision = musicRevision
  const snapshotRevision = ++musicSnapshotRevision
  const next = await callModLua('overhaul_phone_musicPlayer.getUiState', musicState.value.tracksVersion)
  if (isUnmounted || revision !== musicRevision || snapshotRevision < appliedMusicSnapshotRevision || musicCommandsInFlight || !next || typeof next !== 'object') return
  appliedMusicSnapshotRevision = snapshotRevision
  if (typeof next.isPlaying === 'boolean') requestedPlayback = acceptedPlayback = null
  if (JSON.stringify(next) !== JSON.stringify(musicState.value)) musicState.value = next
}
watch(
  [() => state.value.entryPromptActive, () => state.value.musicEnabled],
  () => {
    if (isEntryPrompt.value || state.value.phase === 'idle' || playbackCommandsInFlight) return
    void musicCommand(state.value.musicEnabled !== false ? 'uiPlay' : 'uiStop')
  }
)
const leaveAuction = async () => {
  if (leaveInFlight || isUnmounted) return
  leaveInFlight = true
  const opener = document.activeElement
  try {
    await refresh()
    if (state.value.auctionExitNeedsConfirm || state.value.phase === 'bidding') {
      const leave = await openHouseConfirmation(
        'Leave the vault?',
        'A live auction will end when you leave. A listed vehicle stays listed and locked until it sells or you unlist it. Purchased cars will be collected outside.',
        [
          { label: 'Stay', value: false, extras: { default: true, cancel: true } },
          { label: 'Leave and collect', value: true, extras: { destructive: true } }
        ]
      )
      if (!leave || isUnmounted) {
        await returnFocusToOpener(() => inputSuspended.value || controllerWalking.value || isUnmounted ? null : opener)
        return
      }
    }
    await command('exitAuctionArea')
  } finally {
    leaveInFlight = false
  }
}
const navScope = {
  scopeId: 'used-car-auction',
  activateOnMount: true,
  trapPolicy: 'always',
  canActivate: () => !inputSuspended.value && !controllerWalking.value && !screenClosing && !isUnmounted,
  canDeactivate: () => (onBack(), false)
}
// Keep keyboard Back on the original path. Only a gamepad Back is two-stage.
let keyboardBackWakeup = false
const interactWithAuction = () => {
  controllerWalking.value = false
  if (inputSuspended.value || screenClosing || isUnmounted) return
  auctionRoot.value?.removeAttribute('bng-uinav-suppressed')
  navTracker?.refreshActionStates?.()
  return focusAuctionEntry({ force: true })
}
const controllerBack = createPanelControllerBack({
  isWalking: () => controllerWalking.value,
  walk: () => { controllerWalking.value = true; releaseAuctionGamepad() },
  interact: interactWithAuction,
  leave: () => { void leaveAuction() },
  onHoldChange: holding => { controllerHolding.value = holding },
})
const minimizeAuction = () => {
  if (isEntryPrompt.value || screenClosing || isUnmounted) return
  controllerWalking.value = true
  releaseAuctionGamepad()
}
// Only lot data is event-owned here. Command preferences keep their existing
// revision guards so a late snapshot cannot undo a newer player click.
let liveStateRevision = 0
const liveStateKeys = new Set(['lots', 'currentLot', 'currentLotIndex', 'activeLotIndex', 'phase'])
const receiveAuctionState = snapshot => {
  if (!snapshot || isUnmounted) return
  liveStateRevision++
  for (const key of liveStateKeys) {
    state.value[key] = snapshot[key]
  }
}
watch(isGamepad, gamepad => {
  if (!gamepad) {
    controllerBack.cancel()
    if (controllerWalking.value) {
      keyboardBackWakeup = true
      Promise.resolve(interactWithAuction()).finally(() => { keyboardBackWakeup = false })
    }
  }
}, { flush: 'sync' })
const onControllerNav = event => {
  if (event.detail?.name !== 'back') return
  // A press cancelled by a popup/blur/prompt must not complete on a later up.
  if (inputSuspended.value || screenClosing || isUnmounted ||
      isEntryPrompt.value || state.value.counterPromptActive ||
      document.querySelector('dialog[open]')) {
    controllerBack.cancel()
    return
  }
  // Keep NP0 on the same leave path while a passive scope is waking back up.
  if (!isGamepad.value && (!keyboardBackWakeup || scopedNav?.isActiveScope('used-car-auction'))) return
  event.preventDefault()
  event.stopImmediatePropagation()
  if (leaveInFlight) { controllerBack.cancel(); return }
  if (!isGamepad.value) {
    controllerBack.cancel()
    if (event.detail.value === 1) void onBack()
    return
  }
  controllerBack.handle(event.detail.value)
}
const onBack = () => {
  if (isEntryPrompt.value) return cancelEntryPrompt()
  if (state.value.counterPromptActive) return command('cancelCounterPrompt', true)
  return leaveAuction()
}

let intervalId = null
let musicIntervalId = null
let refreshInFlight = false

const getAuctionApi = () => lua?.overhaul_career_market_auction_auction

const isAuctionLotState = (lotState) => {
  return lotState === 'queued' || lotState === 'approaching' || lotState === 'active' || lotState === 'exiting'
}

const isEntryPrompt = computed(() => {
  return state.value?.phase === 'entryPrompt' || state.value?.entryPromptActive === true
})

const entryFee = computed(() => {
  const fee = Number(state.value?.entryFee)
  return Number.isFinite(fee) && fee >= 0 ? fee : 1000
})

// The entry prompt marks its opening button (Enter Auction, or Leave when blocked); else the first one.
const entryFocus = () =>
  document.querySelector('.entry-modal [bng-scoped-nav-autofocus]:not([disabled])') ||
  document.querySelector('.entry-modal button:not([disabled])')

watch([() => state.value.counterPromptActive, () => state.value.counterShowAuctionsTab, isEntryPrompt], () => {
  if (isEntryPrompt.value || state.value.counterPromptActive) {
    controllerBack.cancel()
    controllerWalking.value = false
    if (!inputSuspended.value) {
      auctionRoot.value?.removeAttribute('bng-uinav-suppressed')
      navTracker?.refreshActionStates?.()
    }
  }
  if (state.value.counterShowAuctionsTab === false) counterTab.value = 'myVehicles'
  else if (state.value.counterPromptActive) counterTab.value = 'auctions'
  selectedOfferId.value = state.value.counterOffers?.[0]?.id || null
  void focusAuctionEntry({ force: true })
  refocusIfLost(() => inputSuspended.value || controllerWalking.value || isUnmounted ? null : isEntryPrompt.value ? entryFocus() : document.querySelector(state.value.counterPromptActive ? '.counter-card [aria-selected="true"]' : '.ua-music-player button:not([disabled])'), { force: true })
}, { flush: 'post' })

// Lua's status line when it sent one; otherwise the template's own prompt (with the currency glyph).
const entryPromptStatus = computed(() => {
  if (isEntryPrompt.value) {
    const st = (state.value?.statusMessage || '').trim()
    if (st) {
      return st
    }
  }
  return ''
})

const activeLot = computed(() => {
  const lots = state.value?.lots || []
  if (!lots.length) return null

  const currentLotIndex = Number(state.value.currentLotIndex || state.value.activeLotIndex || 0)
  if (currentLotIndex > 0) {
    const direct = lots.find((lot) => Number(lot?.lotIndex || 0) === currentLotIndex)
    if (direct) return direct
  }

  const activeByState = lots.find((lot) => isAuctionLotState(lot?.state))
  if (activeByState) return activeByState
  return lots[0]
})

const canBid = computed(() => auctionCanBid(state.value, activeLot.value))

const canPayEntry = computed(() => !!state.value?.canPayEntryFee && hasEntryCapacity.value)

// Controller: the bid buttons only exist while bidding is open; when they appear, move a pad onto the
// first one (unless it is already on a bid button)
watch(
  canBid,
  (open) => {
    if (inputSuspended.value || isUnmounted) return
    if (!open) {
      refocusIfLost(() => inputSuspended.value || controllerWalking.value || isUnmounted ? null : document.querySelector('.ua-music-player button:not([disabled])'))
      return
    }
    refocusIfLost(() => inputSuspended.value || controllerWalking.value || isUnmounted ? null : document.querySelector('.auction-overlay .ua-actions button:not([disabled])'), {
      force: !document.activeElement?.closest?.('.auction-overlay .ua-actions')
    })
  },
  { flush: 'post' }
)

const showMainAuctionPanel = computed(
  () =>
    state.value.mainAuctionPanelActive === true ||
    (state.value.mainAuctionPanelActive !== false && !!state.value.lots?.length)
)
const isLiveBidLot = computed(() => activeLot.value?.state === 'active')
watch(
  () => isLiveBidLot.value ? activeLot.value.lotIndex : null,
  (lotIndex) => {
    if (lotIndex != null) void getAuctionApi()?.onBiddingUiReady?.(lotIndex)
  },
  { flush: 'post' }
)
const phaseLabel = computed(
  () =>
    ({ bidding: 'Bidding', complete: 'Complete', starting: 'Entering', vaultIdle: 'Inside' })[state.value.phase] ||
    'Idle'
)
const phaseClass = computed(() => (state.value.phase === 'vaultIdle' ? 'phase-vault' : `phase-${state.value.phase}`))
const isLotWon = lot => lot.state === 'finished' && lot.outcome === 'won' && lot.wonByPlayer === true
const lotResult = lot => {
  if (lot.state === 'finished') {
    if (isLotWon(lot)) return { label: 'Won', badge: 'badge-won' }
    const label = { refunded: 'Refunded', voided: 'Voided', pending: 'Collecting', unsold: 'Not sold', sold: 'Sold' }[lot.outcome]
      || (lot.highestBidder === 'player' ? 'Not delivered' : 'Finished')
    return { label, badge: lot.outcome === 'pending' ? 'badge-closing' : 'badge-sold' }
  }
  return {
    active: { label: 'Live', badge: 'badge-live' },
    approaching: { label: 'Next', badge: 'badge-approaching' },
    exiting: { label: 'Closing', badge: 'badge-closing' },
    failed: { label: 'No Sale', badge: 'badge-sold' }
  }[lot.state] || { label: 'Upcoming', badge: 'badge-upcoming' }
}
const lotStatusLabel = lot => lotResult(lot).label
const lotBadgeClass = lot => lotResult(lot).badge
const timerClass = computed(() =>
  (Number(activeLot.value?.timeLeft) || 0) <= 5
    ? 'timer-critical'
    : activeLot.value.timeLeft <= 15
      ? 'timer-warning'
      : 'timer-safe'
)
const timerMaximum = ref(1)
watch(
  () => [activeLot.value?.lotIndex, activeLot.value?.timeLeft],
  ([index, time], previous = []) => {
    timerMaximum.value =
      index !== previous[0] ? Math.max(1, Number(time) || 0) : Math.max(timerMaximum.value, Number(time) || 0)
  },
  { immediate: true }
)
const timerDash = computed(
  () => `${(Math.max(0, Number(activeLot.value?.timeLeft) || 0) / timerMaximum.value) * 100.5} 100.5`
)
watch(
  () => activeLot.value?.lotIndex,
  (index) => {
    document.getElementById(`ua-lot-${index}`)?.scrollIntoView({ block: 'nearest' })
  },
  { flush: 'post' }
)

const refresh = async () => {
  if (isUnmounted || refreshInFlight || globalThis.document?.hidden) return
  refreshInFlight = true
  const liveRevision = liveStateRevision
  const revision = batchSizeRevision
  const preferenceRevision = musicPreferenceRevision
  const canConfirmMusicPreference = !musicPreferencesInFlight
  const canConfirmBatchSize = !batchSizeCommandInFlight && pendingBatchSize == null
  try {
    const api = getAuctionApi()
    const nextState = api?.requestAuctionState
      ? await api.requestAuctionState()
      : { ...defaultState(), statusMessage: 'Auction service unavailable right now.' }
    if (isUnmounted || !nextState || typeof nextState !== 'object') return
    const confirmMusicPreference = canConfirmMusicPreference && !musicPreferencesInFlight &&
      preferenceRevision === musicPreferenceRevision
    // Only a snapshot begun after the command settled can confirm Lua's value.
    // Older polls and snapshots preceding a newer click must retain that intent.
    if (canConfirmBatchSize && revision === batchSizeRevision && !batchSizeCommandInFlight &&
      pendingBatchSize == null && Number.isFinite(nextState.lotBatchSize)) {
      requestedBatchSize = null
      acceptedBatchSize = null
    }
    for (const key of Object.keys(state.value)) {
      if (liveRevision !== liveStateRevision && liveStateKeys.has(key)) continue
      if (key === 'musicEnabled' && !confirmMusicPreference) continue
      if (!(key in nextState)) delete state.value[key]
    }
    for (const [key, value] of Object.entries(nextState)) {
      if (liveRevision !== liveStateRevision && liveStateKeys.has(key)) continue
      if (key === 'musicEnabled' && !confirmMusicPreference) continue
      if (JSON.stringify(state.value[key]) !== JSON.stringify(value)) state.value[key] = value
    }
  } finally {
    refreshInFlight = false
  }
}

const setAuctionMusicEnabled = async (enabled) => {
  const boolEnabled = enabled === true
  musicPreferenceRevision++
  musicPreferencesInFlight++
  state.value = { ...state.value, musicEnabled: boolEnabled }
  try {
    const api = getAuctionApi()
    if (api?.setAuctionMusicEnabled) await api.setAuctionMusicEnabled(boolEnabled)
  } finally {
    musicPreferencesInFlight--
    musicPreferenceRevision++
  }
}

const bid = async (amount) => {
  const api = getAuctionApi()
  if (!api?.placeBid) return
  if (!canBid.value || !canAffordBid(amount)) return
  await command('placeBid', bidIncrement(amount))
}

const startAuctionFromPrompt = async () => {
  const api = getAuctionApi()
  if (!api?.startAuction || !canPayEntry.value || busy.value) return
  await command('startAuction')
}

const cancelEntryPrompt = async () => {
  const api = getAuctionApi()
  if (!api?.cancelTravelPrompt) return
  await api.cancelTravelPrompt()
}

const isActiveLot = (lot) => {
  if (!lot || !activeLot.value) return false
  return Number(lot.lotIndex) === Number(activeLot.value.lotIndex)
}

const formatBidder = (lot) => {
  if (!lot) return '-'
  // Identity drives both the status colour and the player label.
  if (lot.highestBidder === 'player') return 'You'
  const bidderName = `${lot?.highestBidderName || ''}`.trim()
  if (bidderName && bidderName !== 'You') return bidderName
  if (lot?.highestBidder === 'npc') return 'NPC'
  return '-'
}

const formatMileage = (mileage) => {
  const n = Number(mileage)
  if (mileage == null || mileage === '' || !Number.isFinite(n) || n < 0) return 'Unknown'
  // Lot mileage arrives in miles (including fractional inventory miles); show it in the player's unit.
  const metres = n * METERS_PER_MILE
  const displayValue = metres * bigLengthUnit(units).perMetre
  return formatOdometer(units, metres, displayValue > 0 && displayValue < 1 ? 2 : 0)
}

const formatCurrency = (amount) => {
  const n = Number(amount)
  if (!Number.isFinite(n) || n < 0) return '0'
  return n.toLocaleString()
}

let isUnmounted = false

onMounted(async () => {
  retainControllerBack()
  document.addEventListener?.('ui_nav', onControllerNav, true)
  events?.on('UsedAuctionHide', hideAuctionInput)
  events?.on('UsedAuctionState', receiveAuctionState)
  events?.on('UsedAuctionMinimize', minimizeAuction)
  globalThis.window?.addEventListener('blur', releaseAuctionInput)
  globalThis.window?.addEventListener('focus', resumeAuctionInput)
  document.addEventListener?.('visibilitychange', auctionVisibilityChanged)
  await refresh()
  if (isUnmounted) return
  void focusAuctionEntry()
  events?.on('UsedAuctionExitRequest', leaveAuction)
  void refreshMusic()
  musicIntervalId = setInterval(refreshMusic, 1000)
  intervalId = setInterval(refresh, 500)
})

onUnmounted(() => {
  isUnmounted = true
  pendingBatchSize = null
  requestedBatchSize = null
  acceptedBatchSize = null
  requestedPlayback = acceptedPlayback = null
  panelDrag = null
  events?.off('UsedAuctionExitRequest', leaveAuction)
  events?.off('UsedAuctionHide', hideAuctionInput)
  events?.off('UsedAuctionState', receiveAuctionState)
  events?.off('UsedAuctionMinimize', minimizeAuction)
  document.removeEventListener?.('ui_nav', onControllerNav, true)
  globalThis.window?.removeEventListener('blur', releaseAuctionInput)
  globalThis.window?.removeEventListener('focus', resumeAuctionInput)
  document.removeEventListener?.('visibilitychange', auctionVisibilityChanged)
  if (musicIntervalId) clearInterval(musicIntervalId)
  if (intervalId) {
    clearInterval(intervalId)
    intervalId = null
  }
  hideAuctionInput()
})
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/auctionPanel.scss';
@use '@/styles/rls_career_overhaul/modules/career/styles/overhaulFocus.scss' as *;
@use '@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss' as *;

// Port the pre-route auction skin, including its gold prices and compact geometry.
// Keep this local: legacy Angular styles must not leak into the Vue route.

.ua-overlay-root {
  position: fixed;
  inset: 0;
  z-index: 160;
  pointer-events: none;
  font-family: Overpass, Arial, sans-serif;
}

.ua-your-lots { color: var(--muted); font-size: 0.8rem; margin-bottom: 0.5rem; }
.ua-your-lot-label {
  display: inline-block;
  margin-left: 0.5em;
  padding: 0.1em 0.45em;
  border: 1px solid var(--line);
  border-radius: var(--radius-control);
  color: var(--muted);
  font-size: 0.78em;
  font-weight: 600;
  line-height: 1.3;
}

.ua-entry-backdrop {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.5);
  pointer-events: auto;
}

.ua-entry-modal {
  width: min(28rem, calc(100vw - 2rem));
  border-radius: 0.75rem;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(10, 12, 18, 0.96);
  color: #f5f7fa;
  box-shadow: 0 1.2rem 3rem rgba(0, 0, 0, 0.6);
  padding: 1.6rem 1.4rem 1.2rem;
  text-align: center;
}

.ua-entry-icon {
  color: rgba(245, 122, 30, 0.85);
  margin-bottom: 0.6rem;
  font-size: 2.25rem;
  --bng-icon-color: currentColor;
}

.ua-entry-title {
  font-size: 1.15rem;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.06rem;
  margin-bottom: 0.35rem;
}

.ua-entry-text {
  font-size: 0.85rem;
  color: rgba(255, 255, 255, 0.7);
  line-height: 1.45;
  margin-bottom: 0.8rem;
}

.ua-entry-fee {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.55rem 0.75rem;
  border-radius: 0.4rem;
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
  margin-bottom: 0.9rem;
  font-size: 0.85rem;
}

.ua-entry-fee-label {
  color: rgba(255, 255, 255, 0.6);
}

.ua-entry-fee-amount {
  font-weight: 700;
  color: #f5a623;
}

.ua-lot-inline {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  margin-bottom: 0.35rem;
}

.ua-lot-inline-label {
  font-size: 0.78rem;
  color: rgba(255, 255, 255, 0.55);
  flex-shrink: 0;
}

.ua-lot-inline-value {
  font-size: 0.9rem;
  font-weight: 700;
  color: #f5a623;
  min-width: 1.6rem;
  text-align: right;
  flex-shrink: 0;
}

.ua-lot-inline-meta {
  font-size: 0.72rem;
  color: rgba(255, 255, 255, 0.45);
  margin-bottom: 0.75rem;
  text-align: left;
}

.ua-lot-inline-meta strong {
  color: #f5a623;
  font-weight: 700;
}

.ua-hslider-wrap {
  flex: 1;
  min-width: 0;
  display: flex;
  align-items: center;
  padding: 0.35rem 0;
  box-sizing: border-box;
}

.ua-counter-options {
  display: grid;
  gap: 0.55rem;
  margin-bottom: 0.9rem;
}

.ua-counter-option {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.85rem;
  width: 100%;
  padding: 0.7rem 0.85rem;
  border-radius: 0.5rem;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(255, 255, 255, 0.04);
  color: inherit;
  cursor: pointer;
  appearance: none;
  text-align: left;
  transition:
    border-color 0.15s ease,
    background 0.15s ease,
    transform 0.15s ease;
}

.ua-counter-option:hover {
  border-color: rgba(245, 166, 35, 0.45);
  background: rgba(245, 166, 35, 0.08);
}

.ua-counter-option.is-selected {
  border-color: rgba(245, 166, 35, 0.7);
  background: rgba(245, 166, 35, 0.12);
  transform: translateY(-1px);
}

.ua-counter-option-copy {
  display: flex;
  flex-direction: column;
  gap: 0.12rem;
  min-width: 0;
}

.ua-counter-option-title {
  font-size: 0.9rem;
  font-weight: 700;
}

.ua-counter-option-subtitle {
  font-size: 0.76rem;
  color: rgba(255, 255, 255, 0.64);
}

.ua-counter-option-meta {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.2rem;
  flex-shrink: 0;
}

.ua-counter-option-fee {
  font-size: 0.86rem;
  font-weight: 700;
  color: #f5a623;
}

.ua-entry-warning {
  font-size: 0.78rem;
  color: #e85454;
  padding: 0.45rem 0.65rem;
  border-radius: 0.4rem;
  background: rgba(232, 84, 84, 0.1);
  border: 1px solid rgba(232, 84, 84, 0.2);
  margin-bottom: 0.4rem;
  text-align: left;
}

.ua-entry-actions {
  display: grid;
  grid-template-columns: 1fr 1.5fr;
  gap: 0.5rem;
}

.ua-vault-session-stack {
  position: fixed;
  top: 1.2rem;
  left: 1.2rem;
  width: min(30rem, calc(100vw - 2rem));
  max-height: calc(100vh - 2.4rem);
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 0.55rem;
  box-sizing: border-box;
  pointer-events: none;
  z-index: 160;
}

.ua-vault-session-stack > * {
  pointer-events: auto;
}

.ua-vault-session-stack > .ua-vault-shell {
  flex: 0 0 auto;
}

.ua-vault-session-stack > .ua-panel {
  flex: 1 1 auto;
  min-height: 0;
}

.ua-phase-badge.phase-complete {
  background: rgba(80, 200, 120, 0.15);
  color: #50c878;
}

.ua-phase-badge.phase-vault {
  background: rgba(100, 160, 255, 0.15);
  color: #8eb8ff;
}

.ua-phase-badge.phase-starting {
  background: rgba(255, 255, 255, 0.1);
  color: rgba(255, 255, 255, 0.65);
}

.ua-vault-shell {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 0.55rem;
  padding: 0.75rem 0.85rem 0.95rem;
  border-radius: 0.6rem;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(8, 10, 14, 0.92);
  color: #f5f7fa;
  box-shadow: 0 0.8rem 2.4rem rgba(0, 0, 0, 0.5);
  pointer-events: auto;
}

.ua-vault-shell-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
}

.ua-vault-cta {
  font-size: 0.82rem;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.82);
  padding: 0.65rem 0.75rem;
  border-radius: 0.45rem;
  background: rgba(245, 122, 30, 0.12);
  border: 1px solid rgba(245, 122, 30, 0.25);
}

.ua-music-player {
  display: flex;
  flex-direction: column;
  padding: 0;
  margin: 0;
  border: none;
  border-radius: 0;
  background: transparent;
  pointer-events: auto;
  flex-shrink: 0;
}

.ua-stats-inline {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.15rem 0;
  font-size: 0.78rem;
  align-self: stretch;
  box-sizing: border-box;
  flex-shrink: 0;
}

.ua-stat-item {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  flex: 1;
  justify-content: center;
}

.ua-stat-k {
  color: rgba(255, 255, 255, 0.45);
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.02rem;
}

.ua-stat-v {
  font-weight: 700;
}

.ua-stat-sep {
  width: 1px;
  height: 0.85rem;
  background: rgba(255, 255, 255, 0.12);
  flex: none;
}

.ua-table {
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.45rem;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  flex: 0 0 auto;
  min-width: 0;
}

.ua-table-body {
  overflow-y: auto;
  overflow-x: hidden;
  flex: 0 1 auto;
  max-height: min(28rem, calc(100vh - 17rem));
  scroll-behavior: auto;
}

.ua-table-body::-webkit-scrollbar {
  width: 6px;
}

.ua-table-body::-webkit-scrollbar-track {
  background: rgba(255, 255, 255, 0.04);
  border-radius: 3px;
}

.ua-table-body::-webkit-scrollbar-thumb {
  background: rgba(245, 122, 30, 0.45);
  border-radius: 3px;
}

.ua-table-body::-webkit-scrollbar-thumb:hover {
  background: rgba(245, 122, 30, 0.65);
}

.ua-table-head,
.ua-table-row {
  display: grid;
  grid-template-columns: 2.8rem minmax(0, 1fr) 5.5rem 4.5rem;
  gap: 0.35rem;
  align-items: center;
  padding: 0.35rem 0.5rem;
  font-size: 0.75rem;
}

.ua-table-head {
  font-size: 0.62rem;
  text-transform: uppercase;
  letter-spacing: 0.03rem;
  color: rgba(255, 255, 255, 0.5);
  background: rgba(255, 255, 255, 0.04);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  position: sticky;
  top: 0;
  flex-shrink: 0;
  z-index: 1;
}

.ua-table-row {
  border-top: 1px solid rgba(255, 255, 255, 0.04);
  transition: background 0.2s ease;
}

.ua-table-row:first-child {
  border-top: none;
}

.ua-table-row:nth-child(even) {
  background: rgba(255, 255, 255, 0.015);
}

.ua-table-row.active {
  background: rgba(245, 122, 30, 0.12);
  box-shadow: inset 3px 0 #f57a1e;
}

.ua-table-row.finished {
  opacity: 0.5;
}

.ua-table-row.won {
  opacity: 0.85;
  background: rgba(80, 200, 120, 0.08);
  box-shadow: inset 3px 0 #50c878;
}

.ua-lot-num {
  font-weight: 700;
  color: rgba(255, 255, 255, 0.6);
}

.ua-table-row.active .ua-lot-num {
  color: #f5a623;
}

.ua-col-vehicle {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.ua-table-row .ua-col-vehicle { display: flex; align-items: center; }
.ua-vehicle-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
.ua-your-lot-label { flex-shrink: 0; }

.ua-col-mileage {
  text-align: right;
  color: rgba(255, 255, 255, 0.65);
  font-size: 0.72rem;
}

.ua-col-status {
  text-align: center;
}

.ua-lot-badge {
  font-size: 0.58rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.02rem;
  padding: 0.12rem 0.4rem;
  border-radius: 0.8rem;
  display: inline-block;
}

.ua-lot-badge.badge-upcoming,
.ua-lot-badge.badge-closing {
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.4);
}

.ua-lot-badge.badge-live {
  background: rgba(245, 122, 30, 0.25);
  color: #f5a623;
  animation: ua-pulse 1.5s ease-in-out infinite;
}

.ua-lot-badge.badge-approaching {
  background: rgba(245, 200, 30, 0.15);
  color: #f5c81e;
}

.ua-lot-badge.badge-won {
  background: rgba(80, 200, 120, 0.18);
  color: #50c878;
}

.ua-lot-badge.badge-sold {
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.35);
}

.ua-empty {
  padding: 1rem;
  color: rgba(255, 255, 255, 0.4);
  font-size: 0.78rem;
  text-align: center;
}

.ua-bidding-section {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
  flex-shrink: 0;
}

.ua-timer.timer-critical {
  color: #e85454;
  animation: ua-timer-flash 0.8s ease-in-out infinite;
}

.ua-timer-waiting {
  width: 3.2rem;
  height: 3.2rem;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(255, 255, 255, 0.35);
}

.ua-spinner-ring {
  width: 100%;
  height: 100%;
  animation: ua-spin 1s linear infinite;
}

@keyframes ua-spin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}

@keyframes ua-timer-flash {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.65;
  }
}

.ua-bid-hint {
  font-size: 0.75rem;
  color: rgba(232, 84, 84, 0.9);
  padding: 0.3rem 0.5rem;
  border-radius: 0.3rem;
  background: rgba(232, 84, 84, 0.08);
  border: 1px solid rgba(232, 84, 84, 0.15);
}

.ua-bid-blocked {
  font-size: 0.78rem;
  color: #e8a054;
  padding: 0.45rem 0.65rem;
  border-radius: 0.4rem;
  background: rgba(232, 160, 84, 0.08);
  border: 1px solid rgba(232, 160, 84, 0.18);
  text-align: center;
}

.ua-winning-banner {
  font-size: 0.72rem;
  font-weight: 700;
  text-align: center;
  padding: 0.35rem;
  border-radius: 0.35rem;
  background: rgba(80, 200, 120, 0.1);
  border: 1px solid rgba(80, 200, 120, 0.2);
  color: #50c878;
  text-transform: uppercase;
  letter-spacing: 0.03rem;
}

.ua-actions {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0.35rem;
}

.ua-btn {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 0.4rem;
  padding: 0.5rem 0.4rem;
  color: #f5f7fa;
  background: rgba(255, 255, 255, 0.06);
  cursor: pointer;
  font-family: inherit;
  font-size: 0.78rem;
  font-weight: 600;
  transition:
    background 0.15s ease,
    border-color 0.15s ease,
    transform 0.1s ease;
}

.ua-btn:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}

.ua-btn-primary {
  background: rgba(245, 122, 30, 0.3);
  border-color: rgba(245, 122, 30, 0.5);
  font-weight: 700;
}

.ua-btn-primary:hover:not(:disabled) {
  background: rgba(245, 122, 30, 0.45);
  border-color: rgba(245, 122, 30, 0.7);
}


.ua-btn-bid {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.15rem;
  padding: 0.5rem 0.25rem;
  background: rgba(245, 122, 30, 0.2);
  border-color: rgba(245, 122, 30, 0.4);
}

.ua-btn-bid:hover:not(:disabled) {
  background: rgba(245, 122, 30, 0.38);
  border-color: rgba(245, 122, 30, 0.65);
  transform: translateY(-1px);
}

.ua-btn-bid:active:not(:disabled) {
  transform: translateY(0);
}

.ua-btn-increment {
  font-size: 0.82rem;
  font-weight: 700;
}

.ua-btn-total {
  font-size: 0.6rem;
  color: rgba(255, 255, 255, 0.45);
}

.ua-counter-modal {
  max-width: 32rem;
  max-height: calc(100vh - 2rem);
  overflow-y: auto;
}

.ua-counter-tabs {
  display: flex;
  gap: 0.35rem;
  margin: 0.5rem 0 0.75rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  padding-bottom: 0.35rem;
}

.ua-counter-tab {
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.85rem;
  font-weight: 600;
  padding: 0.35rem 0.65rem;
  border-radius: 0.3rem;
  cursor: pointer;
}

.ua-counter-tab.is-active {
  color: #fff;
  background: rgba(245, 122, 30, 0.25);
}

.ua-counter-panel {
  margin-top: 0.25rem;
}

.ua-my-vehicles-panel .ua-my-vehicles-scroll {
  max-height: 60vh;
  overflow-y: auto;
  overflow-x: hidden;
  margin: 0.5rem 0;
  padding-right: 0.25rem;
}

.ua-my-vehicles-scroll::-webkit-scrollbar {
  width: 6px;
}

.ua-my-vehicles-scroll::-webkit-scrollbar-track {
  background: rgba(255, 255, 255, 0.04);
  border-radius: 3px;
}

.ua-my-vehicles-scroll::-webkit-scrollbar-thumb {
  background: rgba(245, 122, 30, 0.45);
  border-radius: 3px;
}

.ua-my-vehicles-scroll::-webkit-scrollbar-thumb:hover {
  background: rgba(245, 122, 30, 0.65);
}

.ua-mv-row {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  padding: 0.55rem 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

.ua-mv-row:last-child {
  border-bottom: none;
}

.ua-mv-thumb-wrap {
  flex: 0 0 auto;
}

.ua-mv-thumb {
  width: 4.5rem;
  height: 2.5rem;
  object-fit: cover;
  border-radius: 0.4rem;
  display: block;
  background: rgba(0, 0, 0, 0.35);
}

.ua-mv-thumb-placeholder {
  width: 4.5rem;
  height: 2.5rem;
}

.ua-mv-info {
  flex: 1 1 auto;
  min-width: 0;
}

.ua-mv-name {
  font-weight: 700;
  font-size: 0.88rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.ua-mv-value {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.55);
  margin-top: 0.15rem;
}

.ua-mv-listed {
  font-size: 0.7rem;
  color: rgba(127, 216, 255, 0.95);
  margin-top: 0.2rem;
}

.ua-mv-actions {
  flex: 0 0 auto;
}

.ua-btn-small {
  font-size: 0.72rem;
  padding: 0.35rem 0.55rem;
}

.ua-mv-footer {
  margin-top: 0.35rem;
}

.auction-overlay-layout {
  font-variant-numeric: tabular-nums;
}
.counter-backdrop { z-index: 170; }
.auction-overlay-layout * {
  box-sizing: border-box;
}
button.focus-visible {
  @include overhaul-focus;
}
.ua-entry-icon :deep(.bng-icon) { color: inherit; }
.ua-mv-row.focus-visible { @include overhaul-focus; }
.ua-step {
  padding: 0.1rem 0.45rem;
}
.ua-step[aria-disabled='true'] { opacity: .4; cursor: default; }
.ua-lot-range {
  width: 100%;
}
.ua-header-badges {
  display: flex;
  align-items: center;
  gap: 0.35rem;
}

// Controller walk mode, shown beside the phase so the state reads at a glance.
.ua-mode-pill {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  font-size: 0.65rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04rem;
  padding: 0.2rem 0.55rem;
  border-radius: 1rem;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.16);
  color: rgba(255, 255, 255, 0.85);
}

.ua-mode-pill::before {
  content: '';
  width: 0.4rem;
  height: 0.4rem;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.7);
}

.ua-pill-enter-active,
.ua-pill-leave-active {
  transition: opacity 160ms var(--bx-ease-out, cubic-bezier(0.23, 1, 0.32, 1)),
    transform 160ms var(--bx-ease-out, cubic-bezier(0.23, 1, 0.32, 1));
}

.ua-pill-enter-from,
.ua-pill-leave-to {
  opacity: 0;
  transform: scale(0.95);
}

// Action footer: a tinted band on the panel's bottom edge, chips aligned to the panel padding.
.ua-control-bar {
  position: relative;
  flex-shrink: 0;
  margin: 0.1rem -0.85rem -0.75rem;
  padding: 0.5rem 0.85rem 0.6rem;
  border-top: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 0 0 calc(0.6rem - 1px) calc(0.6rem - 1px);
  background: rgba(255, 255, 255, 0.03);
}

.ua-vault-shell > .ua-control-bar {
  margin-bottom: -0.95rem;
}

// The live panel scrolls; pin the footer over the panel's bottom padding too.
.ua-panel > .ua-control-bar {
  position: sticky;
  bottom: -0.75rem;
  z-index: 2;
  // Opaque only here, where scrolled content passes underneath.
  background: linear-gradient(rgba(255, 255, 255, 0.03), rgba(255, 255, 255, 0.03)), rgb(9, 11, 15);
}
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation: none !important;
    transition: none !important;
  }
}
</style>
