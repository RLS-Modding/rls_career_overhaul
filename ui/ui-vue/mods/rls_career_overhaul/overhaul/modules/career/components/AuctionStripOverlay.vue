<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div v-if="visible" ref="root" @mousedown="!interactive && $event.preventDefault()" v-bng-scoped-nav="navScope" :bng-no-child-nav="!interactive ? 'true' : null">
    <AuctionStrip :lot="state.currentLot" :state="state" :music-state="musicState" :busy="busy"
      :interactive="interactive" shortcut :can-restore="canRestore" :expanded="expanded" :bid-amounts="bidAmounts" @restore="restore" @bid="bid" @music-command="musicCommand" @leave="leave" />
  </div>
</template>

<script setup>
// The live auction owns data. This overlay borrows input only after an explicit
// bumper press, and returns to the activity's original control on Back.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useBridge } from '@/bridge'
import { useUINavTracker } from '@/services/uiNavTracker'
import { useScopedNav } from '@/services/scopedNav/api'
import { vBngScopedNav } from '@/common/directives'
import { callModLua } from '../utils/installLuaBridgeFallbacks.js'
import { safeLua } from '../utils/safeLua.js'
import { auctionBidReason, auctionBidIncrement, auctionBidAmounts } from '../utils/auctionBidRules.js'
import { openHouseConfirmation } from './house/index.js'
import AuctionStrip from './AuctionStrip.vue'

const route = useRoute()
const { events } = useBridge()
const tracker = useUINavTracker()
const nav = useScopedNav()
const state = ref({}), musicState = ref({}), busy = ref(false), interactive = ref(false), root = ref(null)
// Activities opt in through shared route metadata; unknown menus fail closed.
const visible = computed(() => state.value.sessionActive && (route.name === 'play' || route.meta?.inWorldActivity === true))
const canRestore = computed(() => visible.value)
// Over an in-world activity (Blackjack, darts) the player must stay at the table, so
// Expand opens the bid sizes inside the strip instead of switching to the auction screen.
const inActivity = computed(() => route.meta?.inWorldActivity === true)
const expanded = ref(false)
const bidAmounts = computed(() => auctionBidAmounts(state.value.currentLot))
const receive = data => { state.value = data || {} }
let disposed = false, opener = null, musicTimer = null, musicPending = false, musicRevision = 0, inputRevision = 0, musicQueue = Promise.resolve()
const navScope = { scopeId: 'auction-mini', activateOnMount: false, trapPolicy: 'always',
  canActivate: () => interactive.value, canDeactivate: () => !interactive.value }
const release = async (returnFocus = true) => {
  const held = interactive.value
  const target = opener
  const revision = ++inputRevision
  opener = null
  interactive.value = false
  if (held) await nav.deactivateScope('auction-mini', { force: true })
  if (held && returnFocus && revision === inputRevision && target?.isConnected) target.focus()
}
const enter = async () => {
  if (!visible.value || interactive.value || document.querySelector('dialog[open]')) return
  const revision = ++inputRevision
  opener = document.activeElement
  interactive.value = true
  await nextTick()
  if (disposed || !interactive.value || revision !== inputRevision) return
  await nav.activateScope('auction-mini')
  if (disposed || !interactive.value || revision !== inputRevision) return
  root.value?.querySelector('button:not([disabled])')?.focus()
}
const refreshMusic = async () => {
  if (disposed || !visible.value || musicPending || document.hidden) return
  musicPending = true
  const revision = musicRevision
  try {
    const next = await callModLua('overhaul_phone_musicPlayer.getUiState', musicState.value.tracksVersion)
    if (!disposed && revision === musicRevision && next && typeof next === 'object') musicState.value = next
  } finally { musicPending = false }
}
const musicCommand = (name, ...args) => {
  const run = musicQueue.then(async () => {
    if (disposed || !visible.value) return
    // Resolve toggles when their turn starts, so rapid presses keep their order.
    const action = name === 'togglePlayback' ? (musicState.value.isPlaying ? 'uiStop' : 'uiPlay') : name
    if (!['uiPlay', 'uiStop', 'uiPrevious', 'uiNext'].includes(action)) return
    musicRevision++
    const result = await callModLua(`overhaul_phone_musicPlayer.${action}`, ...args)
    if (disposed || !visible.value) return
    const playing = action !== 'uiStop' && result !== false
    await callModLua('overhaul_career_market_auction_auction.setAuctionMusicEnabled', playing)
    musicState.value = { ...musicState.value, isPlaying: playing }
    await refreshMusic()
  })
  musicQueue = run.catch(() => {})
  return safeLua(() => run, 'Auction music')
}
const act = async action => {
  if (!visible.value || busy.value) return
  busy.value = true
  try { await safeLua(action, 'Auction action') } finally { busy.value = false }
}
const bid = amount => act(async () => {
  if (auctionBidReason(state.value, state.value.currentLot, amount)) return
  await callModLua('overhaul_career_market_auction_auction.placeBid', auctionBidIncrement(state.value.currentLot, amount))
  await callModLua('overhaul_career_market_auction_auction.publishAuctionState')
})
const restore = () => {
  if (inActivity.value) { expanded.value = !expanded.value; return }
  return act(async () => {
    await release(false)
    if (disposed || !visible.value) return
    await callModLua('overhaul_career_market_auction_auction.restoreAuctionView')
  })
}
const leave = () => act(async () => {
  // Match the full panel: refresh before deciding whether leaving needs consent.
  const latest = await callModLua('overhaul_career_market_auction_auction.requestAuctionState')
  if (!latest || disposed) return
  if (latest.auctionExitNeedsConfirm || latest.phase === 'bidding') {
    const yes = await openHouseConfirmation('Leave the vault?',
      'A live auction will end when you leave. A listed vehicle stays listed and locked until it sells or you unlist it. Purchased cars will be collected outside.',
      [{ label: 'Stay', value: false, extras: { default: true, cancel: true } },
       { label: 'Leave and collect', value: true, extras: { destructive: true } }])
    if (!yes || disposed) return
  }
  await release(false)
  // Route departure unmounts the activity and runs its own cleanup.
  await callModLua('ui_router.navigate', 'play')
  await callModLua('overhaul_career_market_auction_auction.exitAuctionArea')
})
const onNav = event => {
  if (!visible.value || document.querySelector('dialog[open]')) return
  const { name, value } = event.detail || {}
  if (name !== 'tab_l' && !(interactive.value && name === 'back')) return
  event.preventDefault()
  event.stopImmediatePropagation()
  if (value !== 1) return
  if (interactive.value) void release()
  else void enter()
}
const cancelInput = () => { void release() }
watch([visible, () => route.name], () => {
  expanded.value = false
  void release(false)
  if (visible.value) { tracker.addEvent('tab_l', 'auction-mini'); void safeLua(refreshMusic, 'Sync auction music') }
  else tracker.removeEvent('tab_l', 'auction-mini')
}, { immediate: true })
events.on('UsedAuctionState', receive)
onMounted(() => {
  document.addEventListener('ui_nav', onNav, true)
  window.addEventListener('blur', cancelInput)
  musicTimer = setInterval(() => { void safeLua(refreshMusic, 'Sync auction music') }, 1000)
  void safeLua(() => callModLua('overhaul_career_market_auction_auction.publishAuctionState'), 'Sync auction strip')
})
onBeforeUnmount(() => {
  disposed = true
  void release(false)
  clearInterval(musicTimer)
  events.off('UsedAuctionState', receive)
  document.removeEventListener('ui_nav', onNav, true)
  window.removeEventListener('blur', cancelInput)
  tracker.removeEvent('tab_l', 'auction-mini')
})
</script>
