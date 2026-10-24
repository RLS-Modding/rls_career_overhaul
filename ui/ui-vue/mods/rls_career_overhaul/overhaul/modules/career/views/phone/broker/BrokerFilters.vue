<template>
  <BrokerStyles />
      <section data-broker-scope v-show="!pickedField" ref="filterPanel" class="sort-panel filter-page">
        <h3 data-broker-scope>Filters</h3>
        <div data-broker-scope v-if="s.market === 'all'" class="filter-group">
          <h3 data-broker-scope>Work type</h3>
          <div data-broker-scope class="chips market-chips">
            <button data-broker-scope v-for="m in markets" :key="m.id" type="button" :class="{ active: isMarketFilterActive(m.id) }" @click="toggleMarketFilter(m.id)">{{ m.name }}</button>
          </div>
          <p data-broker-scope v-if="!s.filter.markets?.length" class="filter-note">All six markets included.</p>
        </div>
        <button data-broker-scope v-for="field in fields" :key="field.key" type="button" class="picker-field" :aria-label="`${field.label}: ${chosenLabel(field)}`" @click="openPicker(field.key)"><span data-broker-scope class="picker-label">{{ field.label }}</span><span data-broker-scope class="picker-value">{{ chosenLabel(field) }}</span><span data-broker-scope class="picker-chev" aria-hidden="true">›</span></button>
        <div data-broker-scope v-if="trailerTypes.length" class="filter-group"><h3 data-broker-scope>Trailer type</h3><div data-broker-scope class="chips"><button data-broker-scope v-for="type in trailerTypes" :key="type" type="button" :class="{ active: s.filter.trailers.includes(type) }" @click="toggleTrailer(type)">{{ type }}</button></div></div>
        <div data-broker-scope class="filter-actions"><button data-broker-scope @click="s.resetFilters">Reset filters</button><button data-broker-scope class="primary" @click="emit('done')">Show {{ groupedOfferCount(s.rows) }} loads</button></div>
      </section>
      <section data-broker-scope v-if="pickedField" ref="optionPanel" class="sort-panel">
        <h3 data-broker-scope>{{ pickedField.label }}</h3>
        <div data-broker-scope class="sort-options" role="group" :aria-label="pickedField.label"><button data-broker-scope v-for="option in pickedField.items" :key="option.value" type="button" :aria-pressed="pickedField.value === option.value" :class="{ active: pickedField.value === option.value }" @click="choose(pickedField, option.value)">{{ option.label }}</button></div>
      </section>
</template>

<script setup>
// A filter opens its options in place of the filter list, like Sort, so pad,
// mouse and keyboard all pick the same way; B steps back to the list first.
import BrokerStyles from './BrokerStyles.vue'
import { refocusIfLost } from '../../../composables/useScreenEntryFocus.js'
import { computed, inject, onBeforeUnmount, ref } from 'vue'
const emit = defineEmits(['done'])
const { groupedOfferCount, markets, s, cargoOptions, arrangementOptions, trailerTypes, pickupLocationOptions, destLocationOptions, effectiveRadius, radiusDropdownItems, isMarketFilterActive, toggleMarketFilter, toggleTrailer } = inject(Symbol.for('overhaul.phoneBroker'))
const layers = inject(Symbol.for('overhaul.phoneLayers'), null)
const picking = ref(''), filterPanel = ref(null), optionPanel = ref(null)
let releasePicker = null, pickerOpener = null
const fields = computed(() => [
  { key: 'radius', label: 'Max pickup distance', items: radiusDropdownItems.value, value: effectiveRadius.value },
  { key: 'pickupFac', label: 'Pickup location', items: pickupLocationOptions.value, value: s.filter.pickupFac || '' },
  { key: 'destFac', label: 'Delivery location', items: destLocationOptions.value, value: s.filter.destFac || '' },
  ...(s.market === 'specialty' || s.market === 'all' ? [{ key: 'subtype', label: 'Specialty cargo', items: cargoOptions, value: s.filter.subtype || '' }] : []),
  ...(s.market === 'all' || s.market === 'trailers' ? [{ key: 'arrangement', label: 'Trailer arrangement', items: arrangementOptions, value: s.filter.arrangement || '' }] : []),
])
const pickedField = computed(() => fields.value.find(field => field.key === picking.value))
const chosenLabel = field => field.items.find(option => option.value === field.value)?.label ?? field.items[0]?.label
function openPicker(key) {
  pickerOpener = document.activeElement
  releasePicker = layers?.push(closePicker, pickerOpener)
  picking.value = key
  refocusIfLost(() => optionPanel.value?.querySelector('button.active') || optionPanel.value?.querySelector('button'), { force: true })
}
function closePicker() {
  picking.value = ''
  const release = releasePicker
  releasePicker = null
  release?.()
  refocusIfLost(() => pickerOpener, { force: true })
}
function choose(field, value) {
  s.updateFilter(field.key, value)
  closePicker()
}
onBeforeUnmount(() => releasePicker?.())
</script>
