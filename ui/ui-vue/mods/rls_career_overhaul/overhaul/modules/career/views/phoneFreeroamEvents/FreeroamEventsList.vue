<template>
  <div class="list-view" v-bng-ui-nav-scroll>
    <div v-if="events.length === 0" class="empty-state small">No events match filters.</div>
    <div
      v-for="ev in events"
      :key="ev.raceName"
      class="card"
    >
      <button type="button" class="card-open" :aria-expanded="expandedId === ev.raceName" @click="$emit('toggle-expand', ev.raceName)">
      <div class="card-img">
        <img v-if="ev.thumbnail && !failedImages.has(ev.raceName)" :src="ev.thumbnail" alt="" @error="$emit('image-error', ev.raceName)" />
        <div v-else class="card-img-ph">
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="rgba(31,35,40,0.35)" stroke-width="1.5"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
          <span>No preview</span>
        </div>
        <div class="card-img-fade"></div>
        <div class="card-badges">
          <span
            v-for="t in ensureTypesArray(ev)"
            :key="t"
            class="badge"
            :style="{ background: typeColors[t] || '#888' }"
          >{{ typeLabels[t] || t }}</span>
        </div>
        <div class="card-target" v-if="ev.isPulling">Track: {{ (ev.pullDistanceMeters * FEET_PER_METER).toFixed(0) }} ft</div>
        <div class="card-target" v-else-if="isScoreEvent(ev) && scoreTarget(ev) != null">Target: {{ formatScore(scoreTarget(ev)) }}</div>
        <div class="card-target" v-else-if="ev.hasTopSpeed && ev.topSpeedGoal != null">Target: {{ ev.topSpeedGoal.toFixed(1) }} mph</div>
        <div class="card-target" v-else-if="!isScoreEvent(ev) && !ev.hasTopSpeed && ev.bestTime">Target: {{ formatTime(ev.bestTime) }}</div>
      </div>
      <div class="card-body">
        <div class="card-info">
          <span class="card-name">{{ ev.label }}</span>
          <div class="card-meta">
            <span class="meta-item" v-if="ev.isDemoEvent && ev.demoStats && ev.demoStats.runs > 0">
              {{ ev.demoStats.wins || 0 }}W, {{ formatPercent(ev.demoStats.podiumRate || 0) }} podium
            </span>
            <span class="meta-item no-time" v-else-if="ev.isDemoEvent">No derby runs</span>
            <span v-else-if="ev.isPulling" class="meta-item">Best pull: {{ ev.currentVehicleBestPullDistance ? (ev.currentVehicleBestPullDistance * FEET_PER_METER).toFixed(1) + ' ft' : 'No result yet' }}</span>
            <EventBestResult v-else :ev="ev" class="result-summary" />
            <span class="meta-item" v-if="ev.distance >= 0">
              <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
              {{ formatDistance(ev.distance) }}
            </span>
          </div>
        </div>
        <svg class="chevron" :class="{ open: expandedId === ev.raceName }" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(31,35,40,0.45)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
      </div>
      </button>
      <FreeroamEventDetail
        v-if="expandedId === ev.raceName"
        :ev="ev"
        :career-active="careerActive"
        @set-route="$emit('set-route', $event)"
      />
    </div>
  </div>
</template>

<script setup>
import EventBestResult from './EventBestResult.vue'
import { vBngUiNavScroll } from '@/common/directives'
// The event cards of the list view. Each card shows its summary; the open card mounts FreeroamEventDetail. The parent
// owns which card is open and the failed-image set, so both come in as props and changes go back as events.
import FreeroamEventDetail from './FreeroamEventDetail.vue'
import { isScoreEvent, scoreTarget, formatScore, FEET_PER_METER, ensureTypesArray, formatDistance, formatPercent, formatTime, typeColors, typeLabels } from './eventFormat.js'

defineProps({
  events: { type: Array, required: true },
  expandedId: { default: null },
  careerActive: { type: Boolean, required: true },
  failedImages: { type: Set, required: true },
})

defineEmits(['toggle-expand', 'image-error', 'set-route'])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.result-summary { flex: 1; }
.empty-state {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(31,35,40,0.55);
  font-size: 14px;
  &.small { position: relative; inset: auto; font-size: 13px; padding: 40px 20px; flex: 0; }
}

/* LIST VIEW */
.card-open { font: inherit; display: block; width: 100%; padding: 0; border: 0; text-align: left; color: inherit; background: transparent; }
.list-view {
  position: absolute;
  inset: 0;
  overflow-y: auto;
  padding: 130px 10px 80px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  &::-webkit-scrollbar { width: 3px; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(31,35,40,0.22); border-radius: 2px; }
}

.card {
  flex-shrink: 0;
  min-height: 200px;
  background: #ffffff;
  border-radius: 16px;
  overflow: hidden;
  cursor: pointer;
  border: 1px solid rgba(31,35,40,0.12);
  transition: border-color 0.15s ease;
  &:active { background: #f2efe8; }
}

.card-img {
  position: relative;
  width: 100%;
  height: 160px;
  flex-shrink: 0;
  background: #ece7dc;
  overflow: hidden;
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.card-img-ph {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 6px;
  background: linear-gradient(135deg, #f3efe6, #e7dfd0);
  span {
    font-size: 10px;
    color: rgba(31,35,40,0.48);
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }
  &.small {
    height: 80px;
    span { display: none; }
  }
}

.card-img-fade {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(31,35,40,0.38) 0%, rgba(31,35,40,0.08) 52%, transparent 75%);
  pointer-events: none;
}

.card-badges {
  position: absolute;
  top: 8px;
  left: 10px;
  display: flex;
  gap: 4px;
}

.badge {
  font-size: 9px;
  font-weight: 700;
  padding: 3px 8px;
  border-radius: 6px;
  letter-spacing: 0.5px;
  color: white;
}

.card-target {
  position: absolute;
  bottom: 10px;
  left: 12px;
  font-size: 14px;
  font-weight: 700;
  color: white;
  text-shadow: 0 1px 6px rgba(0,0,0,0.9);
}

.card-body {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: start;
  width: 100%;
  box-sizing: border-box;
  padding: 10px 16px;
  gap: 8px;
}

.card-info { flex: 1; min-width: 0; }

.card-name {
  font-size: 14px;
  font-weight: 600;
  display: block;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  color: #1f2328;
}

.card-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  gap: 8px;
  margin-top: 4px;
}

.meta-item {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  color: rgba(31,35,40,0.65);
  min-width: 0;
  &.no-time {
    color: rgba(31,35,40,0.45);
    font-style: italic;
  }
}

.chevron {
  flex-shrink: 0;
  transition: transform 0.2s ease;
  &.open { transform: rotate(180deg); }
}
</style>
