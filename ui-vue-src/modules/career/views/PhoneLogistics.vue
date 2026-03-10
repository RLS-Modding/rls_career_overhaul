<template>
  <PhoneWrapper app-name="Logistics" :custom-back="handleBack">
    <div class="logistics-app">
      <div v-if="!loaded" class="empty-state">
        <p>Loading logistics...</p>
      </div>

      <div v-else-if="!careerActive" class="empty-state">
        <p>Start a career to view logistics.</p>
      </div>

      <div v-else-if="error && !selectedFacilityId" class="empty-state">
        <p>Unable to load logistics right now.</p>
        <button class="primary-btn" @click="refreshList(true)">Try Again</button>
      </div>

      <template v-else-if="!selectedFacilityId">
        <div class="toolbar">
          <div class="search-shell">
            <input
              v-model.trim="search"
              class="search-input"
              type="text"
              placeholder="Search facilities"
              v-bng-text-input
              @keydown.stop
              @keypress.stop
              @keyup.stop
              @focus="onSearchFocus"
              @blur="onSearchBlur"
            />
            <button class="search-refresh-btn" :disabled="loadingList" @click="refreshList(true)" aria-label="Refresh logistics">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round">
                <path d="M21 12a9 9 0 1 1-2.64-6.36"/>
                <polyline points="21 3 21 9 15 9"/>
              </svg>
            </button>
          </div>

          <div class="toolbar-row-2">
            <div class="dropdown-wrap">
              <button class="dropdown-btn" :class="{ active: filterOpen }" @click="filterOpen = !filterOpen; sortOpen = false">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>
                </svg>
                Filter
                <svg class="dropdown-chevron" :class="{ open: filterOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <polyline points="6 9 12 15 18 9"/>
                </svg>
              </button>
              <div v-if="filterOpen" ref="filterPanelRef" class="dropdown-panel filter-panel" tabindex="-1" @mousedown.stop>
                <label v-for="filter in filters" :key="filter.id" class="filter-opt">
                  <span class="custom-checkbox" :class="{ checked: activeFilters.includes(filter.id) }">
                    <span class="custom-checkbox-dot"></span>
                  </span>
                  <input
                    :checked="activeFilters.includes(filter.id)"
                    class="sr-only"
                    type="checkbox"
                    @change="toggleFilter(filter.id)"
                  />
                  {{ filter.label }}
                </label>
                <button class="filter-clear" @click="clearFilters">Clear</button>
              </div>
            </div>

            <div class="dropdown-wrap">
              <button class="dropdown-btn" :class="{ active: sortOpen }" @click="sortOpen = !sortOpen; filterOpen = false">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <line x1="4" y1="6" x2="20" y2="6"/>
                  <line x1="4" y1="12" x2="14" y2="12"/>
                  <line x1="4" y1="18" x2="9" y2="18"/>
                </svg>
                Sort
                <svg class="dropdown-chevron" :class="{ open: sortOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <polyline points="6 9 12 15 18 9"/>
                </svg>
              </button>
              <div v-if="sortOpen" class="dropdown-panel sort-panel" @mousedown.stop>
                <div class="sort-grid">
                  <span class="sort-label">By</span>
                  <div class="sort-options">
                    <button
                      v-for="option in sortOptions"
                      :key="option.id"
                      class="sort-opt"
                      :class="{ active: sortBy === option.id }"
                      @click="selectSort(option.id)"
                    >
                      {{ option.label }}
                    </button>
                  </div>
                </div>
              </div>
            </div>

            <span class="toolbar-count">{{ visibleFacilities.length }} shown</span>
          </div>
        </div>

        <div v-if="visibleFacilities.length === 0" class="empty-state small">
          <p>No logistics facilities available right now.</p>
        </div>

        <div v-else class="facility-list">
          <article
            v-for="facility in visibleFacilities"
            :key="facility.id"
            class="facility-card"
          >
            <div class="facility-preview">
              <img
                v-if="facility.preview && !imageFailed(facility.id)"
                :src="facility.preview"
                alt=""
                @error="markImageFailure(facility.id)"
              />
              <div v-else class="preview-fallback">
                <BngIcon :type="icons.cogs" />
              </div>
              <div class="preview-overlay"></div>
              <div class="facility-distance">{{ formatDistance(facility.distance) }}</div>
            </div>

            <div class="facility-body">
              <div class="facility-topline">
                <h2>{{ facility.name }}</h2>
                <span class="job-total">{{ facility.totalVisibleJobs }} jobs</span>
              </div>

              <div class="count-grid">
                <div
                  v-for="chip in facilityCountChips(facility)"
                  :key="chip.id"
                  class="count-chip"
                >
                  <span>{{ chip.label }}</span>
                  <strong>{{ chip.count }}</strong>
                </div>
              </div>

              <div class="action-row">
                <button class="primary-btn" @click="viewFacility(facility.id)">View</button>
                <button class="secondary-btn" @click="routeToFacility(facility.id)">Route</button>
              </div>
            </div>
          </article>
        </div>
      </template>

      <template v-else>
        <div class="detail-shell">
          <div class="detail-hero">
            <img
              v-if="detailPreview && !imageFailed(`detail:${selectedFacilityId}`)"
              :src="detailPreview"
              alt=""
              @error="markImageFailure(`detail:${selectedFacilityId}`)"
            />
            <div v-else class="preview-fallback detail-fallback">
              <BngIcon :type="icons.cogs" />
            </div>
            <div class="preview-overlay"></div>
            <div class="detail-copy">
              <h2>{{ detailFacility?.name || "Loading..." }}</h2>
              <p v-if="detailFacility?.distance >= 0" class="detail-meta">{{ formatDistance(detailFacility.distance) }}</p>
            </div>
            <button class="primary-btn hero-route-btn" @click="routeToFacility(selectedFacilityId)">Set Route</button>
          </div>

          <p v-if="detailDescription" class="detail-description">
            {{ detailDescription }}
          </p>

          <div class="chip-row detail-tabs">
            <button
              v-for="tab in detailTabs"
              :key="tab.id"
              class="chip"
              :class="{ active: detailTab === tab.id }"
              @click="detailTab = tab.id"
            >
              {{ tab.label }}
            </button>
          </div>

          <div v-if="loadingDetail && !selectedDetail" class="empty-state small">
            <p>Loading facility details...</p>
          </div>

          <div v-else-if="selectedDetailError" class="empty-state small">
            <p>Unable to load this facility.</p>
            <button class="primary-btn" @click="refreshDetail()">Try Again</button>
          </div>

          <template v-else-if="detailTab === 'parcels'">
            <div v-if="parcelSections.length === 0" class="empty-state small">
              <p>No parcel offers available right now.</p>
            </div>

            <div v-else class="section-list">
              <section
                v-for="section in parcelSections"
                :key="section.destinationKey"
                class="destination-section"
              >
                <div class="section-header">
                  <div>
                    <h3>{{ section.destinationName }}</h3>
                    <p class="section-meta">
                      {{ section.rowCount }} rows
                      <span v-if="section.distance >= 0"> - {{ formatDistance(section.distance) }}</span>
                    </p>
                  </div>
                </div>

                <div class="row-list">
                  <article
                    v-for="row in section.rows"
                    :key="row.rowId"
                    class="compact-row"
                  >
                    <div class="row-copy">
                      <h4>{{ row.parcelName }}</h4>
                      <p>
                        x{{ row.quantity }} - {{ formatSlotSize(row.slotSize) }} - {{ formatMoney(row.rewardPerItem) }} each
                        <span v-if="row.timed"> - Timed</span>
                      </p>
                    </div>
                    <div class="row-actions">
                      <strong>{{ formatMoney(row.rewardTotal) }}</strong>
                    </div>
                  </article>
                </div>
              </section>
            </div>
          </template>

          <template v-else-if="detailTab === 'materials'">
            <div v-if="materialSources.length === 0" class="empty-state small">
              <p>No material sources available right now.</p>
            </div>

            <div v-else class="section-list">
              <article
                v-for="source in materialSources"
                :key="source.storageId"
                class="material-card"
              >
                <button class="material-header" @click="toggleMaterialSource(source.storageId)">
                  <div class="row-copy">
                    <h3>{{ source.materialName }}</h3>
                    <p>{{ formatMaterialAmount(source.amountAvailable, source.units) }} available</p>
                  </div>
                  <div class="material-header-right">
                    <strong>{{ formatRewardPerUnitValue(source.rewardPerUnit, source.units) }}</strong>
                    <span class="chevron" :class="{ open: isMaterialSourceExpanded(source.storageId) }">⌄</span>
                  </div>
                </button>

                <div class="detail-stats compact-stats">
                  <span>{{ source.destinationCount }} destinations</span>
                  <span v-if="source.density != null">{{ formatDensity(source.density, source.units) }}</span>
                </div>

                <div v-if="isMaterialSourceExpanded(source.storageId)" class="nested-list">
                  <div v-if="source.destinations.length === 0" class="nested-empty">
                    No destinations available.
                  </div>

                  <article
                    v-for="destination in source.destinations"
                    :key="destination.destinationKey"
                    class="nested-row"
                  >
                    <div class="row-copy">
                      <h4>{{ destination.destinationName }}</h4>
                      <p>{{ destination.distance >= 0 ? formatDistance(destination.distance) : "Distance unknown" }}</p>
                    </div>
                    <button
                      class="inline-btn"
                      :disabled="!destination.destinationFacilityId"
                      @click="routeToFacility(destination.destinationFacilityId)"
                    >
                      Route
                    </button>
                  </article>
                </div>
              </article>
            </div>
          </template>

          <template v-else-if="detailTab === 'vehicles'">
            <div v-if="vehicleSections.length === 0" class="empty-state small">
              <p>No vehicle offers available right now.</p>
            </div>

            <div v-else class="section-list">
              <section
                v-for="section in vehicleSections"
                :key="section.destinationKey"
                class="destination-section"
              >
                <div class="section-header">
                  <div>
                    <h3>{{ section.destinationName }}</h3>
                    <p class="section-meta">
                      {{ section.rowCount }} offers
                      <span v-if="section.distance >= 0"> - {{ formatDistance(section.distance) }}</span>
                    </p>
                  </div>
                </div>

                <div class="row-list">
                  <article
                    v-for="offer in section.rows"
                    :key="offer.offerId"
                    class="compact-row"
                  >
                    <div class="row-copy">
                      <h4>{{ offer.name }}</h4>
                      <p>
                        {{ offer.vehicleBrand || "Vehicle" }}
                        <span v-if="offer.distance > 0"> - {{ formatDistance(offer.distance) }}</span>
                      </p>
                    </div>
                    <div class="row-actions">
                      <strong>{{ formatMoney(offer.reward) }}</strong>
                    </div>
                  </article>
                </div>
              </section>
            </div>
          </template>

          <template v-else>
            <div v-if="trailerSections.length === 0" class="empty-state small">
              <p>No trailer offers available right now.</p>
            </div>

            <div v-else class="section-list">
              <section
                v-for="section in trailerSections"
                :key="section.destinationKey"
                class="destination-section"
              >
                <div class="section-header">
                  <div>
                    <h3>{{ section.destinationName }}</h3>
                    <p class="section-meta">
                      {{ section.rowCount }} offers
                      <span v-if="section.distance >= 0"> - {{ formatDistance(section.distance) }}</span>
                    </p>
                  </div>
                </div>

                <div class="row-list">
                  <article
                    v-for="offer in section.rows"
                    :key="offer.offerId"
                    class="compact-row"
                  >
                    <div class="row-copy">
                      <h4>{{ offer.name }}</h4>
                      <p>
                        Trailer haul
                        <span v-if="offer.distance > 0"> - {{ formatDistance(offer.distance) }}</span>
                      </p>
                    </div>
                    <div class="row-actions">
                      <strong>{{ formatMoney(offer.reward) }}</strong>
                    </div>
                  </article>
                </div>
              </section>
            </div>
          </template>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, onMounted, onUnmounted, reactive, ref, watch } from "vue"
import { storeToRefs } from "pinia"
import { BngIcon, icons } from "@/common/components/base"
import { lua } from "@/bridge"
import { vBngTextInput } from "@/common/directives"
import PhoneWrapper from "./PhoneWrapper.vue"
import { usePhoneLogisticsStore } from "../stores/phoneLogisticsStore"

const store = usePhoneLogisticsStore()
const {
  loaded,
  loadingList,
  loadingDetail,
  careerActive,
  facilities,
  selectedFacilityId,
  selectedFacility,
  selectedDetail,
  selectedDetailError,
  error,
} = storeToRefs(store)

const search = ref("")
const sortBy = ref("distance")
const activeFilters = ref([])
const filterOpen = ref(false)
const sortOpen = ref(false)
const detailTab = ref("parcels")
const failedImages = reactive({})
const expandedMaterialSources = reactive({})
const filterPanelRef = ref(null)

const filters = [
  { id: "parcel", label: "Parcel" },
  { id: "material", label: "Material" },
  { id: "vehicle", label: "Vehicle" },
  { id: "trailer", label: "Trailer" },
]

const sortOptions = [
  { id: "distance", label: "Distance" },
  { id: "jobs", label: "Jobs" },
  { id: "name", label: "Name" },
]

const detailFacility = computed(() => {
  const detail = selectedDetail.value?.facility || {}
  const summary = selectedFacility.value || {}
  return {
    ...summary,
    ...detail,
  }
})

const detailPreview = computed(() => detailFacility.value?.preview || "")
const detailDescription = computed(() => detailFacility.value?.longDescription || "")
const parcelSections = computed(() => selectedDetail.value?.parcelDestinations || [])
const materialSources = computed(() => selectedDetail.value?.materialSources || [])
const vehicleSections = computed(() => selectedDetail.value?.vehicleOfferDestinations || [])
const trailerSections = computed(() => selectedDetail.value?.trailerOfferDestinations || [])
const detailTabs = computed(() => {
  const tabs = []
  if (parcelSections.value.length > 0) tabs.push({ id: "parcels", label: "Parcels" })
  if (materialSources.value.length > 0) tabs.push({ id: "materials", label: "Materials" })
  if (vehicleSections.value.length > 0) tabs.push({ id: "vehicles", label: "Vehicles" })
  if (trailerSections.value.length > 0) tabs.push({ id: "trailers", label: "Trailers" })
  return tabs
})

const visibleFacilities = computed(() => {
  const query = search.value.toLowerCase()
  const filtered = facilities.value.filter(facility => {
    const matchesSearch = !query
      || facility.name?.toLowerCase().includes(query)
      || facility.organizationName?.toLowerCase().includes(query)

    const matchesTypes = activeFilters.value.length === 0
      || activeFilters.value.some(filterId => (facility.badges || []).includes(filterId))

    return matchesSearch && matchesTypes
  })

  return [...filtered].sort((left, right) => {
    if (sortBy.value === "jobs") {
      const diff = (right.totalVisibleJobs || 0) - (left.totalVisibleJobs || 0)
      if (diff !== 0) return diff
    }

    if (sortBy.value === "name") {
      return String(left.name || "").localeCompare(String(right.name || ""))
    }

    const leftDistance = left.distance >= 0 ? left.distance : Number.MAX_SAFE_INTEGER
    const rightDistance = right.distance >= 0 ? right.distance : Number.MAX_SAFE_INTEGER
    if (leftDistance !== rightDistance) return leftDistance - rightDistance
    return String(left.name || "").localeCompare(String(right.name || ""))
  })
})

function clearMaterialExpansion() {
  Object.keys(expandedMaterialSources).forEach(key => {
    delete expandedMaterialSources[key]
  })
}

function toggleFilter(filterId) {
  if (activeFilters.value.includes(filterId)) {
    activeFilters.value = activeFilters.value.filter(id => id !== filterId)
    return
  }
  activeFilters.value = [...activeFilters.value, filterId]
}

function clearFilters() {
  activeFilters.value = []
}

function selectSort(sortId) {
  sortBy.value = sortId
  sortOpen.value = false
}

function toggleMaterialSource(storageId) {
  expandedMaterialSources[storageId] = !expandedMaterialSources[storageId]
}

function isMaterialSourceExpanded(storageId) {
  return !!expandedMaterialSources[storageId]
}

function imageFailed(key) {
  return !!failedImages[key]
}

function markImageFailure(key) {
  failedImages[key] = true
}

function onSearchFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}

function onSearchBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
}

function facilityCountChips(facility) {
  const counts = facility?.counts || {}
  return [
    { id: "parcels", label: "Parcels", count: counts.parcelGroups || 0 },
    { id: "materials", label: "Materials", count: counts.materialGroups || 0 },
    { id: "vehicles", label: "Vehicles", count: counts.vehicleOffers || 0 },
    { id: "trailers", label: "Trailers", count: counts.trailerOffers || 0 },
  ].filter(chip => chip.count > 0)
}

watch(detailTabs, tabs => {
  if (tabs.length === 0) {
    detailTab.value = "parcels"
    return
  }

  if (!tabs.some(tab => tab.id === detailTab.value)) {
    detailTab.value = tabs[0].id
  }
}, { immediate: true })

watch(filterOpen, open => {
  if (!open) return
  setTimeout(() => {
    filterPanelRef.value?.focus()
  }, 0)
})

function formatDistance(distance) {
  if (distance == null || distance < 0) return "Unknown"
  if (distance >= 1000) return `${(distance / 1000).toFixed(1)} km`
  return `${Math.round(distance)} m`
}

function formatMoney(amount) {
  const value = Number(amount || 0)
  return `$${Math.round(value).toLocaleString()}`
}

function formatMaterialAmount(amount, units = "L") {
  return `${Math.round(Number(amount || 0)).toLocaleString()} ${units}`
}

function formatRewardPerUnitValue(rewardPerUnit, units = "L") {
  const value = Number(rewardPerUnit || 0)
  const display = value >= 10 ? value.toFixed(1) : value.toFixed(2)
  return `$${display}/${units}`
}

function formatDensity(density, units = "L") {
  const value = Number(density || 0)
  if (!value) return ""
  return `${value.toFixed(2)} kg/${units}`
}

function formatSlotSize(slotSize) {
  const value = Number(slotSize || 0)
  return `${value} ${value === 1 ? "slot" : "slots"}`
}

async function viewFacility(facilityId) {
  clearMaterialExpansion()
  detailTab.value = "parcels"
  await store.selectFacility(facilityId, true)
}

async function routeToFacility(facilityId) {
  if (!facilityId) return
  await store.navigateToFacility(facilityId)
}

async function refreshList(force = false) {
  await store.refreshList(force)
}

async function refreshDetail() {
  if (!selectedFacilityId.value) return
  await store.selectFacility(selectedFacilityId.value, true)
}

function handleBack() {
  if (!selectedFacilityId.value) return false
  clearMaterialExpansion()
  store.backToList()
  return true
}

onMounted(async () => {
  await store.init()
})

onUnmounted(() => {
  store.cleanup()
})
</script>

<style scoped lang="scss">
.logistics-app {
  height: 100%;
  padding: 2.8rem 0.85rem 1rem;
  color: #10233c;
  background:
    radial-gradient(circle at top right, rgba(99, 179, 237, 0.22), transparent 36%),
    linear-gradient(180deg, #eef5fb 0%, #dce8f4 100%);
  box-sizing: border-box;
  overflow-y: auto;
  overflow-x: hidden;
  -webkit-overflow-scrolling: touch;
  scrollbar-width: thin;
  scrollbar-color: rgba(56, 90, 125, 0.38) transparent;
}

.logistics-app::-webkit-scrollbar {
  width: 6px;
}

.logistics-app::-webkit-scrollbar-track {
  background: transparent;
}

.logistics-app::-webkit-scrollbar-thumb {
  border-radius: 999px;
  background: rgba(56, 90, 125, 0.38);
}

.logistics-app::-webkit-scrollbar-thumb:hover {
  background: rgba(43, 108, 176, 0.55);
}

.facility-topline,
.action-row,
.sort-row,
.section-header,
.material-header,
.compact-row,
.nested-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
}

h1,
h2,
h3,
h4,
p {
  margin: 0;
}

h1 {
  font-size: 1.6rem;
  font-weight: 800;
}

h3 {
  font-size: 0.98rem;
  font-weight: 800;
}

h4 {
  font-size: 0.9rem;
  font-weight: 800;
}

.toolbar,
.detail-shell {
  display: flex;
  flex-direction: column;
  gap: 0.7rem;
}

.search-shell {
  position: relative;
}

.search-input {
  width: 100%;
  padding: 0.72rem 3.1rem 0.72rem 0.85rem;
  border: 1px solid rgba(16, 35, 60, 0.12);
  border-radius: 14px;
  background: rgba(255, 255, 255, 0.78);
  color: #10233c;
  box-sizing: border-box;
}

.search-refresh-btn {
  position: absolute;
  top: 50%;
  right: 0.42rem;
  width: 2.1rem;
  height: 2.1rem;
  display: flex;
  align-items: center;
  justify-content: center;
  transform: translateY(-50%);
  border: none;
  border-radius: 999px;
  background: rgba(233, 241, 250, 0.95);
  color: #385a7d;
}

.search-refresh-btn:disabled {
  opacity: 0.55;
}

.toolbar-row-2 {
  display: flex;
  align-items: center;
  gap: 0.55rem;
}

.dropdown-wrap {
  position: relative;
}

.dropdown-btn {
  display: flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.48rem 0.72rem;
  border-radius: 10px;
  border: 1px solid rgba(16, 35, 60, 0.12);
  background: rgba(255, 255, 255, 0.78);
  color: #385a7d;
  font-size: 0.72rem;
  font-weight: 700;
  font-family: inherit;
}

.dropdown-btn.active {
  background: #2b6cb0;
  border-color: #2b6cb0;
  color: #ffffff;
}

.dropdown-chevron {
  transition: transform 0.15s ease;
}

.dropdown-chevron.open {
  transform: rotate(180deg);
}

.dropdown-panel {
  position: absolute;
  top: calc(100% + 0.3rem);
  left: 0;
  z-index: 50;
  min-width: 12rem;
  border-radius: 12px;
  border: 1px solid rgba(16, 35, 60, 0.12);
  background: rgba(255, 255, 255, 0.96);
  box-shadow: 0 12px 28px rgba(32, 58, 88, 0.16);
  outline: none;
}

.filter-panel,
.sort-panel {
  padding: 0.8rem;
}

.filter-panel {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  border: 0;
}

.custom-checkbox {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 1rem;
  height: 1rem;
  border-radius: 999px;
  border: 1.5px solid rgba(56, 90, 125, 0.28);
  flex-shrink: 0;
}

.custom-checkbox-dot {
  width: 0.42rem;
  height: 0.42rem;
  border-radius: 999px;
  background: #2b6cb0;
  opacity: 0;
  transform: scale(0.5);
  transition: opacity 0.15s ease, transform 0.15s ease;
}

.custom-checkbox.checked {
  border-color: rgba(43, 108, 176, 0.48);
}

.custom-checkbox.checked .custom-checkbox-dot {
  opacity: 1;
  transform: scale(1);
}

.filter-opt {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-height: 1.35rem;
  font-size: 0.78rem;
  line-height: 1;
  color: #385a7d;
}

.filter-clear {
  align-self: flex-start;
  padding: 0.38rem 0.72rem;
  border: 1px solid rgba(16, 35, 60, 0.12);
  border-radius: 8px;
  background: rgba(233, 241, 250, 0.9);
  color: #385a7d;
  font-size: 0.72rem;
  font-weight: 700;
  font-family: inherit;
}

.sort-panel {
  min-width: 12.4rem;
}

.sort-grid {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 0.45rem 0.8rem;
  align-items: center;
}

.sort-label {
  font-size: 0.72rem;
  color: #5b7490;
}

.sort-options {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.3rem;
}

.sort-opt {
  padding: 0.36rem 0.55rem;
  border-radius: 8px;
  border: 1px solid rgba(16, 35, 60, 0.12);
  background: rgba(233, 241, 250, 0.9);
  color: #385a7d;
  font-size: 0.72rem;
  font-weight: 700;
  font-family: inherit;
}

.sort-opt.active {
  background: #2b6cb0;
  border-color: #2b6cb0;
  color: #ffffff;
}

.toolbar-count {
  margin-left: auto;
  font-size: 0.72rem;
  color: #5b7490;
}

.chip-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45rem;
}

.chip,
.sort-btn,
.ghost-btn,
.primary-btn,
.secondary-btn,
.inline-btn,
.material-header {
  border: none;
  border-radius: 999px;
  font-weight: 700;
}

.chip,
.sort-btn,
.ghost-btn,
.inline-btn {
  padding: 0.45rem 0.75rem;
  background: rgba(255, 255, 255, 0.72);
  color: #385a7d;
}

.chip.active,
.sort-btn.active {
  background: #2b6cb0;
  color: #ffffff;
}

.toolbar-label,
.section-meta,
.row-copy p,
.detail-description,
.detail-meta,
.nested-empty {
  color: #5b7490;
}

.toolbar-label {
  font-size: 0.78rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.facility-list,
.section-list {
  display: flex;
  flex-direction: column;
  gap: 0.7rem;
  margin-top: 0.8rem;
}

.facility-card,
.destination-section,
.material-card {
  overflow: hidden;
  border-radius: 18px;
  background: rgba(255, 255, 255, 0.88);
  box-shadow: 0 12px 28px rgba(32, 58, 88, 0.12);
}

.facility-preview,
.detail-hero {
  position: relative;
  min-height: 112px;
  background: linear-gradient(135deg, #214f87, #4f8cc9);
}

.detail-hero {
  overflow: hidden;
  border-radius: 18px;
}

.facility-preview img,
.detail-hero img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.preview-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(180deg, rgba(9, 20, 34, 0.08), rgba(9, 20, 34, 0.7));
}

.preview-fallback {
  min-height: 112px;
  display: grid;
  place-items: center;
  color: rgba(255, 255, 255, 0.8);
  font-size: 1.5rem;
}

.detail-fallback {
  min-height: 180px;
}

.facility-distance,
.detail-copy {
  position: absolute;
  z-index: 1;
}

.facility-distance {
  top: 0.65rem;
  right: 0.65rem;
  padding: 0.28rem 0.55rem;
  border-radius: 999px;
  background: rgba(9, 20, 34, 0.55);
  color: #ffffff;
  font-size: 0.72rem;
  font-weight: 700;
}

.detail-copy {
  left: 1rem;
  right: 1rem;
  bottom: 3.8rem;
  color: #ffffff;
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 0.75rem;
}

.facility-body,
.destination-section,
.material-card {
  padding: 0.8rem 0.85rem;
}

.facility-topline h2,
.detail-copy h2 {
  font-weight: 800;
}

.facility-topline h2 {
  font-size: 0.98rem;
  line-height: 1.2;
}

.detail-copy h2 {
  font-size: 1.15rem;
  line-height: 1.05;
  flex: 1 1 auto;
}

.job-total {
  font-size: 0.72rem;
  color: #537295;
  font-weight: 700;
  text-align: right;
  min-width: 52px;
}

.count-grid,
.detail-stats,
.compact-stats {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45rem;
}

.count-chip,
.detail-stats span,
.compact-stats span {
  border-radius: 999px;
  font-size: 0.68rem;
  font-weight: 700;
}

.count-grid {
  margin: 0.6rem 0 0.75rem;
}

.count-chip {
  min-width: calc(50% - 0.25rem);
  padding: 0.5rem 0.7rem;
  background: #eef5fb;
  color: #21486f;
  display: flex;
  align-items: center;
  justify-content: space-between;
  box-sizing: border-box;
}

.count-chip strong {
  font-size: 0.9rem;
}

.primary-btn,
.secondary-btn {
  flex: 1;
  padding: 0.62rem 0.85rem;
  font-size: 0.9rem;
}

.primary-btn {
  background: #2b6cb0;
  color: #ffffff;
}

.secondary-btn {
  background: #dbeaf7;
  color: #21486f;
}

.ghost-btn {
  color: #21486f;
}

.inline-btn {
  cursor: pointer;
}

.detail-meta {
  color: rgba(255, 255, 255, 0.92);
  font-size: 0.95rem;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
  flex-shrink: 0;
}

.hero-route-btn {
  position: absolute;
  z-index: 1;
  left: 0.75rem;
  right: 0.75rem;
  bottom: 0.75rem;
  padding: 0.68rem 0.9rem;
  border-radius: 16px;
  box-shadow: 0 10px 24px rgba(24, 56, 92, 0.24);
}

.primary-btn:disabled,
.secondary-btn:disabled,
.ghost-btn:disabled,
.inline-btn:disabled {
  opacity: 0.55;
  cursor: default;
}

.detail-actions {
  margin-top: 0.15rem;
}

.detail-description {
  padding: 0 0.15rem;
  line-height: 1.45;
}

.section-header {
  margin-bottom: 0.55rem;
}

.section-meta {
  font-size: 0.75rem;
  margin-top: 0.18rem;
}

.row-list,
.nested-list {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
}

.compact-row,
.nested-row {
  padding: 0.65rem 0.7rem;
  border-radius: 14px;
  background: #eef5fb;
  align-items: flex-start;
}

.row-copy {
  min-width: 0;
  flex: 1;
}

.row-copy p {
  margin-top: 0.18rem;
  font-size: 0.78rem;
  line-height: 1.3;
}

.row-actions,
.material-header-right {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.35rem;
  flex-shrink: 0;
}

.row-actions strong,
.material-header-right strong {
  color: #1f4f81;
}

.material-header {
  width: 100%;
  padding: 0;
  background: transparent;
  cursor: pointer;
}

.compact-stats {
  margin: 0.55rem 0 0.2rem;
}

.detail-stats span,
.compact-stats span {
  padding: 0.35rem 0.6rem;
  background: #eef5fb;
  color: #426380;
}

.nested-empty {
  padding: 0.5rem 0;
  font-size: 0.8rem;
}

.chevron {
  font-size: 1rem;
  line-height: 1;
  transition: transform 0.15s ease;
}

.chevron.open {
  transform: rotate(180deg);
}

.empty-state {
  padding: 2.5rem 1rem;
  text-align: center;
  color: #4f6681;
}

.empty-state.small {
  padding-top: 1.5rem;
}

@media (max-width: 420px) {
  .detail-actions,
  .action-row {
    flex-direction: column;
  }

  .primary-btn,
  .secondary-btn {
    width: 100%;
  }
}
</style>
