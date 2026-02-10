<template>
  <PhoneWrapper app-name="Real Estate" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="real-estate-app">
      <!-- Header -->
      <div class="app-header">
        <div class="header-icon-wrap">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#f97316" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>
            <polyline points="9 22 9 12 15 12 15 22"/>
          </svg>
        </div>
        <div class="header-text">
          <h1>Real Estate</h1>
          <span class="header-subtitle">{{ ownedCount }} owned · {{ garages.length }} properties</span>
        </div>
      </div>

      <!-- Not in career -->
      <div v-if="!careerActive && loaded" class="empty-state">
        <p>Start a career to browse properties.</p>
      </div>

      <!-- Loading -->
      <div v-if="!loaded" class="empty-state">
        <p>Loading properties...</p>
      </div>

      <!-- Garage list -->
      <div class="garage-list" v-if="careerActive && loaded">
        <div
          v-for="garage in garages"
          :key="garage.id"
          class="garage-card"
          :class="{ owned: garage.owned }"
          @click="toggleExpand(garage.id)"
        >
          <!-- Preview image -->
          <div class="card-image">
            <img v-if="garage.preview" :src="garage.preview" alt="" @error="onImgError" />
            <div v-else class="card-image-placeholder">
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.3)" stroke-width="1.5">
                <path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>
                <polyline points="9 22 9 12 15 12 15 22"/>
              </svg>
            </div>
            <!-- Overlays on image -->
            <div class="card-image-overlay"></div>
            <div class="card-badges">
              <span v-if="garage.owned" class="badge badge-owned">OWNED</span>
              <span v-else-if="garage.starterGarage" class="badge badge-starter">FREE</span>
            </div>
            <div class="card-price" v-if="!garage.owned">
              ${{ formatPrice(garage.price) }}
            </div>
          </div>

          <!-- Card info -->
          <div class="card-body">
            <div class="card-main">
              <span class="card-name">{{ garage.name }}</span>
              <div class="card-meta">
                <span class="meta-slots">
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <rect x="1" y="3" width="15" height="13" rx="2"/>
                    <path d="M16 8h2a2 2 0 012 2v6a2 2 0 01-2 2H6"/>
                    <circle cx="5.5" cy="18.5" r="2.5"/>
                    <circle cx="18.5" cy="18.5" r="2.5"/>
                  </svg>
                  <template v-if="garage.owned">{{ garage.vehicleCount }}/{{ garage.capacity }}</template>
                  <template v-else>{{ garage.capacity }} slots</template>
                </span>
                <span class="meta-distance" v-if="garage.distance >= 0">
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                    <circle cx="12" cy="10" r="3"/>
                    <path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/>
                  </svg>
                  {{ formatDistance(garage.distance) }}
                </span>
              </div>
            </div>
            <svg class="card-chevron" :class="{ expanded: expandedId === garage.id }" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.4)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="6 9 12 15 18 9"/>
            </svg>
          </div>

          <!-- Expanded actions -->
          <div class="card-actions" v-if="expandedId === garage.id">
            <p class="card-description" v-if="garage.description">{{ cleanDescription(garage.description) }}</p>
            <div class="action-buttons">
              <button class="action-btn route-btn" @click.stop="setRoute(garage)">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                  <polygon points="3 11 22 2 13 21 11 13 3 11"/>
                </svg>
                Set Route
              </button>
              <button
                v-if="garage.owned || garage.discovered"
                class="action-btn tow-btn"
                @click.stop="towTo(garage)"
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                  <circle cx="12" cy="12" r="10"/>
                  <polyline points="12 6 12 12 16 14"/>
                </svg>
                Tow Here
              </button>
              <!-- Must visit in person to purchase -->
            </div>
          </div>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import PhoneWrapper from './PhoneWrapper.vue'

const events = useEvents()
const garages = ref([])
const careerActive = ref(true)
const loaded = ref(false)
const expandedId = ref(null)

const ownedCount = computed(() => garages.value.filter(g => g.owned).length)

function formatPrice(price) {
  if (price >= 1000000) return (price / 1000000).toFixed(1) + 'M'
  if (price >= 1000) return (price / 1000).toFixed(0) + 'K'
  return price.toString()
}

function formatDistance(meters) {
  if (meters < 0) return '—'
  if (meters >= 1000) return (meters / 1000).toFixed(1) + ' km'
  return Math.round(meters) + ' m'
}

function cleanDescription(desc) {
  // Strip translation keys
  if (desc.startsWith('levels.')) return ''
  return desc
}

function toggleExpand(id) {
  expandedId.value = expandedId.value === id ? null : id
}

function setRoute(garage) {
  lua.ui_phone_realEstate.setRouteToGarage(garage.id)
}

function towTo(garage) {
  lua.ui_phone_realEstate.towToGarage(garage.id)
}

function onImgError(e) {
  e.target.style.display = 'none'
}

onMounted(() => {
  lua.extensions.load('ui_phone_realEstate')
  events.on('phoneRealEstateData', (data) => {
    garages.value = data.garages || []
    careerActive.value = data.careerActive !== false
    loaded.value = true
  })
  lua.ui_phone_realEstate.requestGarageListings()

  // Fallback
  setTimeout(() => { if (!loaded.value) loaded.value = true }, 1000)
})
</script>

<style scoped lang="scss">
.real-estate-app {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: #111;
  color: white;
  overflow: hidden;
}

.app-header {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 52px 16px 12px;
  background: linear-gradient(to bottom, rgba(249, 115, 22, 0.15), transparent);
  flex-shrink: 0;
}

.header-icon-wrap {
  width: 40px;
  height: 40px;
  border-radius: 12px;
  background: rgba(249, 115, 22, 0.15);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.header-text {
  display: flex;
  flex-direction: column;

  h1 {
    font-size: 18px;
    font-weight: 700;
    margin: 0;
    color: white;
  }
}

.header-subtitle {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.45);
  margin-top: 1px;
}

.empty-state {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(255, 255, 255, 0.4);
  font-size: 14px;
}

.garage-list {
  flex: 1;
  overflow-y: auto;
  padding: 8px 12px 120px;
  display: flex;
  flex-direction: column;
  gap: 10px;

  &::-webkit-scrollbar {
    width: 3px;
  }
  &::-webkit-scrollbar-track {
    background: transparent;
  }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.15);
    border-radius: 2px;
  }
}

.garage-card {
  background: #1a1a1a;
  border-radius: 14px;
  overflow: hidden;
  cursor: pointer;
  transition: background 0.15s ease;
  border: 1px solid rgba(255, 255, 255, 0.06);

  &:hover {
    background: #1e1e1e;
  }

  &.owned {
    border-color: rgba(249, 115, 22, 0.2);
  }
}

.card-image {
  position: relative;
  width: 100%;
  height: 100px;
  background: #0d0d0d;
  overflow: hidden;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.card-image-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(135deg, #1a1a1a, #0d0d0d);
}

.card-image-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.7) 0%, transparent 60%);
  pointer-events: none;
}

.card-badges {
  position: absolute;
  top: 8px;
  right: 8px;
  display: flex;
  gap: 4px;
}

.badge {
  font-size: 9px;
  font-weight: 700;
  padding: 2px 6px;
  border-radius: 4px;
  letter-spacing: 0.5px;
}

.badge-owned {
  background: #f97316;
  color: white;
}

.badge-starter {
  background: #22c55e;
  color: white;
}

.card-price {
  position: absolute;
  bottom: 8px;
  left: 10px;
  font-size: 16px;
  font-weight: 700;
  color: white;
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.8);
}

.card-body {
  display: flex;
  align-items: center;
  padding: 10px 12px;
  gap: 8px;
}

.card-main {
  flex: 1;
  min-width: 0;
}

.card-name {
  font-size: 14px;
  font-weight: 600;
  display: block;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.card-meta {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 3px;
}

.meta-slots, .meta-distance {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.5);
}

.card-chevron {
  flex-shrink: 0;
  transition: transform 0.2s ease;

  &.expanded {
    transform: rotate(180deg);
  }
}

.card-actions {
  padding: 0 12px 12px;
  animation: slideDown 0.2s ease;
}

.card-description {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.4);
  margin: 0 0 10px;
  line-height: 1.4;
}

.action-buttons {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.action-btn {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 7px 12px;
  border-radius: 10px;
  border: none;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: opacity 0.15s ease;
  font-family: inherit;

  &:hover {
    opacity: 0.85;
  }
}

.route-btn {
  background: rgba(249, 115, 22, 0.15);
  color: #f97316;
}

.tow-btn {
  background: rgba(59, 130, 246, 0.15);
  color: #3b82f6;
}

@keyframes slideDown {
  from {
    opacity: 0;
    transform: translateY(-6px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
</style>
