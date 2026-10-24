<template>
  <aside class="auction-strip ua-panel" aria-label="Live auction">
    <div class="ua-bid-info">
      <div class="ua-bid-main" :class="{ 'auction-strip__live': live }">
        <div class="auction-strip__lot">
          <span v-if="lot" class="auction-strip__lot-number">Lot {{ lot.lotIndex }}</span>
          <span class="auction-strip__vehicle" :title="lot?.title">{{ lot?.title || 'Waiting for the next lot' }}</span>
        </div>
        <div class="ua-bid-amount-wrap">
          <span class="ua-bid-label">{{ live ? 'Current Bid' : 'Awaiting Lot' }}</span>
          <strong v-if="live" class="ua-bid-amount">${{ Number(lot.currentBid || 0).toLocaleString() }}</strong>
        </div>
        <div v-if="live" class="ua-bid-leader-wrap" :class="leading ? 'leader-player' : 'leader-npc'">
          <span class="ua-bid-leader-indicator"></span>
          <span class="ua-bid-leader-name" :title="leaderName">{{ leaderName }}</span>
        </div>
        <span v-else class="ua-bid-waiting-text">Lot is moving to the block</span>
      </div>
      <div v-if="live" class="ua-timer" :class="time <= 5 ? 'timer-critical' : time <= 15 ? 'timer-warning' : 'timer-safe'">
        <svg viewBox="0 0 36 36" class="ua-timer-ring" aria-hidden="true">
          <circle cx="18" cy="18" r="16" fill="none" stroke="rgba(255,255,255,0.08)" stroke-width="3" />
          <circle cx="18" cy="18" r="16" fill="none" stroke="currentColor" stroke-width="3" :stroke-dasharray="timerDash" transform="rotate(-90 18 18)" stroke-linecap="round" />
        </svg>
        <span class="ua-timer-text">{{ time }}s</span>
      </div>
    </div>
    <div class="auction-strip__actions">
      <span class="auction-strip__hint">
        <HouseActionHint v-if="shortcut && !interactive" ui-event="tab_l" glyph-label="Left bumper: auction controls" label="" />
        <HouseActionHint v-if="interactive" ui-event="back" glyph-label="Back" label="Table" />
        <HouseActionHint v-else-if="holdToRestore" :viewer-obj="backBinding" :ui-event="backBinding ? undefined : 'back'" glyph-label="Back" label="Expand" hold />
      </span>
      <HouseButton compact class="auction-strip__bid" :nav-item="interactive" :tabindex="interactive ? 0 : -1"
        :disabled="busy || !!bidReason" :title="bidReason" v-bng-ui-nav-focus v-bng-on-ui-nav:ok.asMouse.focusRequired
        @click="!busy && !bidReason && $emit('bid')">Bid ${{ nextBid.toLocaleString() }}</HouseButton>
      <HouseButton v-if="canRestore" compact :nav-item="interactive" :tabindex="interactive ? 0 : -1"
        v-bng-ui-nav-focus v-bng-on-ui-nav:ok.asMouse.focusRequired @click="$emit('restore')">{{ expanded ? 'Collapse' : 'Expand' }}</HouseButton>
      <HouseButton compact variant="quiet-danger" :nav-item="interactive" :tabindex="interactive ? 0 : -1"
        :disabled="busy" v-bng-ui-nav-focus v-bng-on-ui-nav:ok.asMouse.focusRequired @click="$emit('leave')">Leave auction</HouseButton>
    </div>
    <div v-if="expanded" class="auction-strip__amounts" role="group" aria-label="Bid amount">
      <HouseButton v-for="amount in bidAmounts" :key="amount" compact class="auction-strip__amount"
        :nav-item="interactive" :tabindex="interactive ? 0 : -1" :disabled="busy || !!amountReason(amount)" :title="amountReason(amount)"
        v-bng-ui-nav-focus v-bng-on-ui-nav:ok.asMouse.focusRequired
        @click="!busy && !amountReason(amount) && $emit('bid', amount)">+${{ amount.toLocaleString() }}</HouseButton>
    </div>
    <span v-if="bidReason && bidReason !== 'You are leading'" class="auction-strip__reason" role="status">{{ bidReason }}</span>
    <AuctionMusicPlayer class="auction-strip__music" compact :state="musicState" :active="interactive" @command="(...args) => $emit('music-command', ...args)" />
  </aside>
</template>

<script setup>
// Presentation only. The route owns input; another activity keeps its actions.
// Shared auctionPanel.scss owns the expanded and collapsed house surfaces.
import { computed, ref, watch } from 'vue'
import AuctionMusicPlayer from './AuctionMusicPlayer.vue'
import HouseButton from './house/HouseButton.vue'
import { vBngUiNavFocus, vBngOnUiNav } from '@/common/directives'
import { auctionBidReason, auctionBidIncrement } from '../utils/auctionBidRules.js'
import HouseActionHint from './house/HouseActionHint.vue'
const props = defineProps({ lot: Object, canRestore: Boolean, backBinding: Object, holdToRestore: Boolean, state: { type: Object, default: () => ({}) }, musicState: { type: Object, default: () => ({}) }, busy: Boolean, interactive: Boolean, shortcut: Boolean,
  // Inline mode: the activity keeps the screen, so the strip itself offers the bid sizes.
  expanded: Boolean, bidAmounts: { type: Array, default: () => [] } })
defineEmits(['restore', 'bid', 'music-command', 'leave'])
const bidReason = computed(() => auctionBidReason(props.state, props.lot))
const amountReason = amount => auctionBidReason(props.state, props.lot, amount)
const nextBid = computed(() => (Number(props.lot?.currentBid) || 0) + auctionBidIncrement(props.lot))
const live = computed(() => props.lot?.state === 'active')
const leading = computed(() => props.lot?.highestBidder === 'player')
const leaderName = computed(() => leading.value ? 'You' : props.lot?.highestBidderName === 'You' ? 'NPC' : props.lot?.highestBidderName || 'NPC')
const time = computed(() => Math.max(0, Number(props.lot?.timeLeft) || 0))
const maximum = ref(1)
watch(() => [props.lot?.lotIndex, time.value], ([index, seconds], previous = []) => {
  maximum.value = index !== previous[0] ? Math.max(1, seconds) : Math.max(maximum.value, seconds)
}, { immediate: true })
const timerDash = computed(() => `${time.value / maximum.value * 100.5} 100.5`)
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/auctionPanel.scss';
.auction-strip.ua-panel {
  position: fixed;
  top: max(1rem, var(--safezone-top, 0px));
  left: max(1rem, var(--safezone-left, 0px));
  width: min(26rem, calc(100vw - 2rem));
  box-sizing: border-box;
  font-family: Overpass, sans-serif;
  font-variant-numeric: tabular-nums;
  z-index: 100;
}
.auction-strip.ua-panel { gap: .4rem; padding: .6rem .7rem; }
.auction-strip .ua-bid-info { gap: .6rem; }
.auction-strip .ua-bid-main { min-width: 0; flex: 1; gap: .25rem; }
.auction-strip__lot { display: flex; align-items: baseline; gap: .55rem; min-width: 0; }
.auction-strip__lot-number { font-size: .75rem; text-transform: uppercase; color: #f5a623; white-space: nowrap; }
.auction-strip__vehicle { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: .85rem; font-weight: 700; }
.auction-strip .ua-bid-label { font-size: .65rem; color: rgba(255,255,255,.5); }
.auction-strip .ua-bid-leader-wrap { gap: .5rem; }
.auction-strip__live .ua-bid-leader-wrap { min-width: 0; }
.auction-strip .ua-bid-leader-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.auction-strip .timer-critical { color: #e85454; }
.auction-strip__hint { display: inline-flex; flex-shrink: 0; align-items: center; font-size: .75rem; }
.auction-strip__hint:empty { display: none; }
.auction-strip__actions { display: flex; gap: .35rem; align-items: center; }
.auction-strip__actions :deep(.house-button) { font-size: .72rem; padding: .35rem .45rem; min-height: 1.8rem; }
.auction-strip__bid { color: #50c878; flex: 1; }
.auction-strip__amounts { display: flex; gap: .35rem; }
.auction-strip__amounts :deep(.house-button) { flex: 1; font-size: .72rem; padding: .35rem .45rem; min-height: 1.8rem; color: #50c878; }
.auction-strip__reason { font-size: .72rem; color: #f5c878; margin-top: -.35rem; }
.auction-strip__music { border-top: 1px solid #ffffff10; padding-top: .35rem; }
</style>
