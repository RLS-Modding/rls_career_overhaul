<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="map-carousel-wrap">
    <div
      class="map-carousel-viewport"
      ref="viewportEl"
      @pointerdown.capture="$emit('viewport-pointer-down', $event)"
      @click="$emit('viewport-click', $event)"
    >
      <div
        class="map-carousel-track"
        :class="{ 'no-transition': isDragging || isWrapping }"
        :style="{ '--carousel-duration': transitionDuration + 's', '--carousel-slide-width': slideWidth + 'px', transform: `translateX(${slideOffset}px)` }"
      >
        <article
          v-for="(ev, idx) in slides"
          :key="'c-' + ev.raceName + '-' + idx"
          class="map-slide"
          :class="{ selected: selectedEvent && selectedEvent.raceName === ev.raceName }"
          :style="{ flex: '0 0 ' + slideWidth + 'px', width: slideWidth + 'px' }"
        >
          <div class="map-slide-img">
            <img v-if="ev.thumbnail && !failedImages.has(ev.raceName)" :src="ev.thumbnail" alt="" draggable="false" @error="$emit('image-error', ev.raceName)" />
            <div v-else class="card-img-ph small">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="rgba(31,35,40,0.35)" stroke-width="1.5"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
            </div>
            <div class="map-slide-img-fade"></div>
            <div class="map-slide-badges">
              <span
                v-for="t in ensureTypesArray(ev)"
                :key="t"
                class="badge"
                :style="{ background: typeColors[t] || '#888' }"
              >{{ typeLabels[t] || t }}</span>
            </div>
          </div>
          <div class="map-slide-body">
            <div class="map-slide-top">
              <span class="map-slide-name">{{ ev.label }}</span>
            </div>
            <div class="map-slide-meta-row">
              <div class="map-slide-meta">
                <span v-if="ev.isDemoEvent && ev.demoStats && ev.demoStats.runs > 0">
                  {{ ev.demoStats.wins || 0 }}W, {{ formatPercent(ev.demoStats.podiumRate || 0) }} podium
                </span>
                <span v-else-if="ev.isDemoEvent" class="no-time">No derby runs</span>
            <span v-else-if="ev.isPulling" class="meta-item">Best pull: {{ ev.currentVehicleBestPullDistance ? (ev.currentVehicleBestPullDistance * FEET_PER_METER).toFixed(1) + ' ft' : 'No result yet' }}</span>
            <EventBestResult v-else :ev="ev" class="result-summary" />
                <span v-if="ev.distance >= 0">
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                  {{ formatDistance(ev.distance) }}
                </span>
              </div>
              <button type="button" class="act-btn route" @click.stop="$emit('set-route', ev.raceName)">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
                Route
              </button>
            </div>
          </div>
        </article>
      </div>
    </div>
  </div>
</template>

<script setup>
import EventBestResult from './EventBestResult.vue'
// The bottom card carousel of the map view. The parent's usePhoneCarousel owns the slide index and the drag; this part
// renders its strip and reports pointer, tap and Route input. The viewport element is exposed because the carousel
// measures it and pins pointer capture to it.
import { ref } from 'vue'
import { FEET_PER_METER, ensureTypesArray, formatDistance, formatPercent, formatTime, typeColors, typeLabels } from './eventFormat.js'

defineProps({
  slides: { type: Array, required: true },
  slideOffset: { type: Number, required: true },
  slideWidth: { type: Number, required: true },
  transitionDuration: { type: Number, required: true },
  isDragging: { type: Boolean, required: true },
  isWrapping: { type: Boolean, required: true },
  selectedEvent: { type: Object, default: null },
  failedImages: { type: Set, required: true },
})

defineEmits(['viewport-pointer-down', 'viewport-click', 'image-error', 'set-route'])

const viewportEl = ref(null)
defineExpose({ viewportEl })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.result-summary { flex: 1; }
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

.badge {
  font-size: 9px;
  font-weight: 700;
  padding: 3px 8px;
  border-radius: 6px;
  letter-spacing: 0.5px;
  color: white;
}

.act-btn {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 8px 14px;
  border-radius: 10px;
  border: none;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  transition: opacity 0.15s ease;
  &:hover { opacity: 0.85; }
  &.route { background: rgba(230,57,70,0.15); color: #e63946; }
}

.map-carousel-wrap {
  position: absolute;
  bottom: 10px;
  left: 0;
  right: 0;
  z-index: 5;
  pointer-events: auto;
}

.map-carousel-viewport {
  overflow: hidden;
  padding: 0 0 30px;
  cursor: grab;
  user-select: none;
  -webkit-user-select: none;
  touch-action: none;
  &:active { cursor: grabbing; }
}

.map-carousel-track {
  display: flex;
  gap: 10px;
  padding-left: max(0px, calc((100% - var(--carousel-slide-width, 292px)) / 2));
  padding-right: max(0px, calc((100% - var(--carousel-slide-width, 292px)) / 2));
  transition: transform var(--carousel-duration) cubic-bezier(0.25, 0.46, 0.45, 0.94);
  &.no-transition { transition: none; }
}

.map-slide {
  flex-shrink: 0;
  background: rgba(255, 255, 255, 0.96);
  border-radius: 18px;
  overflow: hidden;
  border: 1px solid rgba(31,35,40,0.14);
  box-shadow: 0 8px 20px rgba(31,35,40,0.18);
  pointer-events: auto;
  &.selected {
    border-color: rgba(230,57,70,0.6);
  }
  .act-btn { pointer-events: auto; }
}

.map-slide-img {
  position: relative;
  width: 100%;
  height: 118px;
  background: #ece7dc;
  overflow: hidden;
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.map-slide-img-fade {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(31,35,40,0.38) 0%, rgba(31,35,40,0.08) 52%, transparent 75%);
  pointer-events: none;
}

.map-slide-badges {
  position: absolute;
  top: 6px;
  left: 8px;
  display: flex;
  gap: 4px;
}

.map-slide-body {
  padding: 10px 12px 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.map-slide-top {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.map-slide-name {
  font-size: 14px;
  font-weight: 600;
  color: #1f2328;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  flex: 1;
  min-width: 0;
}

.map-slide-meta-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.map-slide-meta {
  display: flex;
  flex: 1;
  min-width: 0;
  gap: 12px;
  > span:not(.result-summary) {
    display: flex;
    align-items: center;
    gap: 3px;
    font-size: 11px;
    color: rgba(31,35,40,0.62);
    &.no-time {
      color: rgba(31,35,40,0.42);
      font-style: italic;
    }
  }
}

.map-slide-meta-row .act-btn {
  flex-shrink: 0;
  padding: 6px 12px;
  font-size: 11px;
}
</style>
