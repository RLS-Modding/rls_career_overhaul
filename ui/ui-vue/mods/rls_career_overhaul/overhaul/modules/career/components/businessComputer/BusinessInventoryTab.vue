<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Business computer: used-parts inventory, house style. Title + hint, search with totals, then one
     panel per vehicle (name, count pill) holding a line per part: name, faint mileage, condition pill
     (colour only when Excellent or worn), gold value and a neutral Sell. Selling by vehicle is quiet. -->
<template>
  <div ref="rootRef" class="inventory-tab rls-house">
    <header class="page-head">
      <h2 class="page-title">Inventory</h2>
      <p class="hint">Manage your used car parts collection</p>
    </header>

    <!-- Search Bar and Stats -->
    <div class="toolbar-bar">
      <label class="search" data-focus-field>
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.25" /><path d="M15.2 15.2L20 20" /></svg>
        <input
          v-model="searchQuery"
          type="text"
          placeholder="Search by part name or vehicle"
          aria-label="Search parts"
          bng-no-nav="true"
          v-bng-text-input
          @keydown.stop
          @keyup.stop
          @keypress.stop
        />
        <button v-if="searchQuery" type="button" class="search-clear" aria-label="Clear search" @click="searchQuery = ''">
          <svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
      </label>
      <div class="facts totals">
        <div class="fact">
          <span class="fact-key">Total Parts</span>
          <span class="fact-value">{{ filteredParts.length }}</span>
        </div>
        <div class="fact money">
          <span class="fact-key">Total Value</span>
          <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(totalValue) }}</span>
        </div>
      </div>
      <HouseButton
        class="sell-all-btn"
        :aria-disabled="selling" :disabled="filteredParts.length === 0" data-fk="sell-all"
        @click.stop="sellAllParts"
        @mousedown.stop>
        {{ searchQuery.trim() ? 'Sell Matching Parts' : 'Sell All Parts' }}
      </HouseButton>
    </div>

    <!-- Parts Grouped by Vehicle -->
    <div class="parts-groups">
      <div v-if="Object.keys(groupedParts).length === 0" class="empty">
        <p v-if="searchQuery.trim()">No parts found matching your search.</p>
        <p v-else>No parts in inventory</p>
      </div>

      <section
        v-for="[vehicle, vehicleParts] in Object.entries(groupedParts)"
        :key="vehicle"
        class="group"
        :class="{ open: openSections[vehicle] !== false }"
      >
        <button
          type="button"
          class="group-head"
          :aria-expanded="openSections[vehicle] !== false"
          @click="toggleSection(vehicle)">
          <span class="group-title">{{ vehicle }}</span>
          <span class="pill">{{ vehicleParts.length }} {{ vehicleParts.length === 1 ? 'part' : 'parts' }}</span>
          <svg class="chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
        </button>

        <div v-if="openSections[vehicle] !== false" class="group-body">
          <div class="lines part-lines scroll" v-bng-ui-nav-scroll>
            <div
              v-for="part in vehicleParts"
              :key="part.partId"
              class="line part-line"
            >
              <div class="part-copy">
                <strong class="part-name">{{ part.name }}</strong>
                <span class="part-meta">
                  <span v-if="part.slot">{{ part.slot }}</span>
                  <span>{{ partDistance(part) }}</span>
                </span>
              </div>

              <span class="pill" :class="conditionTone(getConditionText(part.mileage || 0))">
                {{ getConditionText(part.mileage || 0) }}
              </span>

              <span class="part-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(part.price || part.value || 0) }}</span>

              <HouseButton compact :data-fk="`sell-${part.partId}`" :aria-disabled="selling" @click.stop="sellPart(part.partId)" @mousedown.stop>
                Sell
              </HouseButton>
            </div>
          </div>

          <div class="group-foot">
            <HouseButton compact variant="quiet" :data-fk="`sell-vehicle-${vehicle}`" :aria-disabled="selling" @click.stop="sellAllVehicleParts(vehicle)" @mousedown.stop>
              Sell all {{ vehicle }} parts
            </HouseButton>
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<script setup>
import { useActionFocus } from "../../composables/useActionFocus.js"
import { reportUiFailure } from "../../utils/safeLua.js"
import { ref, computed, onMounted, watch } from "vue"
import { useBusinessPartsStore } from "../../stores/businessComputer/businessPartsStore.js"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { lua, useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { useEvents } from "@/services/events"
import { vBngTextInput, vBngUiNavScroll } from "@/common/directives"
import { HouseButton, openHouseConfirmation } from "../house/index.js"
import { formatPrice, getConditionClass, getConditionText } from "../../utils/businessUtils"
import { formatOdometer, METERS_PER_MILE } from "../../utils/units"

const partsStore = useBusinessPartsStore()
const sessionStore = useBusinessSessionStore()
const { units } = useBridge()

// odometer (metres) in the player's distance unit; part.mileage (whole miles) is the fallback
const partDistance = part => formatOdometer(units, part.odometer ?? (part.mileage || 0) * METERS_PER_MILE)
const events = useEvents()
const searchQuery = ref('')
const openSections = ref({})
const selling = ref(false)
const rootRef = ref(null)
const { remember, restore } = useActionFocus(rootRef)

// condition pill tone: green only for Excellent, amber when worn, neutral otherwise
const conditionTone = (text) => {
  if (text === 'Excellent') return 'ok'
  if (text === 'Fair' || text === 'Poor') return 'warn'
  return null
}

const filteredParts = computed(() => {
  try {
    const parts = Array.isArray(sessionStore.parts) ? sessionStore.parts : []
    if (!searchQuery.value.trim()) {
      return parts
    }
    const query = searchQuery.value.toLowerCase()
    return parts.filter(part =>
      (part.name && part.name.toLowerCase().includes(query)) ||
      (part.compatibleVehicle && part.compatibleVehicle.toLowerCase().includes(query))
    )
  } catch (error) {
    return []
  }
})

const groupedParts = computed(() => {
  try {
    const parts = Array.isArray(filteredParts.value) ? filteredParts.value : []
    const groups = {}
    parts.forEach(part => {
      if (!part) return
      const vehicle = part.compatibleVehicle || "Unknown"
      if (!groups[vehicle]) {
        groups[vehicle] = []
      }
      groups[vehicle].push(part)
    })
    return groups
  } catch (error) {
    return {}
  }
})

const totalValue = computed(() => {
  const parts = Array.isArray(filteredParts.value) ? filteredParts.value : []
  if (parts.length === 0) return 0
  const total = parts.reduce((sum, part) => sum + (part.price || part.value || 0), 0)
  return Math.round(total * 100) / 100
})

const toggleSection = (vehicle) => {
  openSections.value[vehicle] = openSections.value[vehicle] === false ? true : false
}

const sellPart = async (partId) => {
  if (!sessionStore.businessId || !partId || selling.value) return
  remember()
  selling.value = true
  try {
    await lua.overhaul_career_business_computer.sellPart(sessionStore.businessId, partId)
    if (partsStore.requestPartInventory) {
      await partsStore.requestPartInventory()
    }
  } catch (error) {
    reportUiFailure(error, "Sell the confirmed business part selection")
  } finally {
    selling.value = false
    await restore()
  }
}

const sellVisibleParts = async (parts, scope) => {
  if (!sessionStore.businessId || selling.value || !parts.length) return
  const businessId = sessionStore.businessId
  const ids = [...new Set(parts.map(part => part.partId).filter(id => id != null))]
  remember()
  selling.value = true
  try {
    const confirmed = await openHouseConfirmation('Sell parts', `Sell ${ids.length} ${scope}?`, [
      { label: 'Cancel', value: false, extras: { default: true, cancel: true } },
      { label: 'Sell Parts', value: true, extras: { destructive: true } },
    ])
    if (confirmed !== true || sessionStore.businessId !== businessId) return
    for (const id of ids) {
      await lua.overhaul_career_business_computer.sellPart(businessId, id)
    }
    if (partsStore.requestPartInventory) {
      await partsStore.requestPartInventory()
    }
  } catch (error) {
    reportUiFailure(error, "Sell the confirmed business part selection")
  } finally {
    selling.value = false
    await restore()
  }
}

const sellAllParts = () => sellVisibleParts(filteredParts.value, searchQuery.value.trim() ? 'matching parts' : 'parts in this business')
const sellAllVehicleParts = vehicleName => sellVisibleParts(groupedParts.value[vehicleName] || [], `visible ${vehicleName} parts`)

const loadInventory = () => {
  if (sessionStore.businessId && partsStore.requestPartInventory) {
    partsStore.requestPartInventory()
  }
}

watch(() => sessionStore.businessId, (newId) => {
  if (newId) {
    loadInventory()
  }
}, { immediate: false })

onMounted(() => {
  loadInventory()
})

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.inventory-tab {
  display: flex;
  flex-direction: column;
  gap: 1.1em;
}

.page-head {
  display: grid;
  gap: 0.3em;
}
.page-title {
  margin: 0;
  color: #fff;
  font-size: 1.4em;
  font-weight: 800;
  line-height: 1.15;
}
.page-head .hint {
  font-size: 0.9em;
}

/* ---- search + totals */
.toolbar-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.8em 1.6em;

  .search {
    flex: 1 1 18em;
  }
}
.facts.totals {
  flex: 0 0 auto;
  grid-template-columns: repeat(2, auto);
  column-gap: 1.8em;
}
.fact-value {
  font-variant-numeric: tabular-nums;
}
.sell-all-btn {
  flex: 0 0 auto;
}

/* ---- vehicle groups */
.parts-groups {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
}
.group {
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.group-head {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 0.6em;
  width: 100%;
  margin: 0;
  padding: 0.8em var(--inset) 0.7em;
  border: 0;
  border-radius: var(--radius-panel);
  background: transparent;
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;

  &:hover {
    background: rgba(255, 255, 255, 0.04);
  }
  @include house-focus;
  .pill {
    flex: 0 0 auto;
  }
}
.group-title {
  flex: 0 1 auto;
  min-width: 0;
  font-size: 1.1em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.chevron {
  flex: 0 0 auto;
  width: 1em;
  height: 1em;
  margin-left: auto;
  fill: none;
  stroke: var(--faint);
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
  transform: rotate(-90deg);
  transition: transform 0.16s ease;
  .open & {
    transform: rotate(0deg);
  }
}

.group-body {
  display: grid;
  gap: 0.2em;
  padding: 0 var(--inset) 0.6em;
}
.part-lines {
  max-height: 25em;
  padding-right: 0.2em;
}
.part-line {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto 6.5em auto;
  align-items: center;
  gap: 0.9em;
}
.part-copy {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}
.part-name {
  font-weight: 700;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.part-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2em 0.9em;
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.part-value {
  justify-self: end;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.group-foot {
  display: flex;
  justify-content: flex-end;
  padding-top: 0.3em;
}

.empty:not(.bng-button) {
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
