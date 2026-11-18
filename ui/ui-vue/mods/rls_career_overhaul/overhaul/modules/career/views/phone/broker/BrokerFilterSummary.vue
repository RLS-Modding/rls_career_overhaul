<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Active Job Broker filter chips plus one clear button, shared by the market
     scope, the load toolbar and the filter sheet (BrokerWork.vue, BrokerFilters.vue).
     Reads activeFilters and resetFilters from phoneBrokerStore.js through the
     phoneBroker injection. scopeOnly shows and clears just the pickup scope;
     otherwise clear resets scope, search and saved filters. Focus moves to the
     nearest enabled button so controllers keep a target. -->

<template>
  <section data-broker-scope v-if="filters.length" class="filter-summary" aria-label="Active filters">
    <div data-broker-scope class="filter-summary-chips">
      <span data-broker-scope class="filter-summary-label">Filtered by</span>
      <span data-broker-scope v-for="filter in filters" :key="filter.key" class="filter-summary-chip">{{ filter.label }}</span>
    </div>
    <button data-broker-scope type="button" class="filter-summary-clear" @click="clear">{{ scopeOnly ? 'All pickups' : 'Show all' }}</button>
  </section>
</template>

<script setup>
import { computed, inject } from 'vue'
import { refocusIfLost } from '../../../composables/useScreenEntryFocus.js'
const props = defineProps({ scopeOnly: Boolean })
const { activeFilters, s } = inject(Symbol.for('overhaul.phoneBroker'))
const filters = computed(() => props.scopeOnly ? activeFilters.value.filter(filter => filter.key === 'scope') : activeFilters.value)
function clear(event) {
  const area = event.currentTarget.closest('.sort-panel, .toolbar, .market-body')
  if (props.scopeOnly) s.scope = ''
  else s.resetFilters()
  refocusIfLost(() => area?.querySelector('button:not([disabled])'))
}
</script>

<style scoped>
/* One quiet strip in the Broker's own tokens: orange marks what is narrowing
   the list, as it does on the filter chips, and the way out stays a plain button. */
.filter-summary { display: flex; align-items: center; gap: 0.7em; min-width: 0; padding: 0.4em 0.45em 0.4em 0.75em; border-radius: 0.5em; background: var(--panel); }
.filter-summary-chips { display: flex; flex: 1 1 0; flex-wrap: wrap; align-items: center; gap: 0.35em; min-width: 0; max-height: 6em; overflow-y: auto; }
.filter-summary-label { margin-right: 0.25em; font-size: max(0.6875rem, 0.68em); font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; white-space: nowrap; color: var(--faint); }
/* A long pickup name or search wraps inside its chip and stops at two lines,
   so one filter can never push the load list off the phone. */
.filter-summary-chip { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; max-width: 100%; padding: 0.25em 0.5em 0.15em; border-radius: 0.3em; background: color-mix(in srgb, var(--accent) 25%, transparent); color: color-mix(in srgb, var(--accent) 50%, white); font-size: max(0.75rem, 0.78em); font-weight: 700; line-height: 1.2; overflow-wrap: anywhere; font-variant-numeric: tabular-nums; }
/* The doubled class outweighs the Broker's base button rule, which still
   supplies the fill, hover and press. Pad focus gets the hover lift under the game's frame. */
.filter-summary .filter-summary-clear { flex: 0 0 auto; padding: 0.62em 0.9em 0.5em; border-radius: 0.35em; font-size: max(0.75rem, 0.9em); }
.filter-summary .filter-summary-clear.focus-visible { background: rgba(255, 255, 255, 0.16); }
.market-body .filter-summary { margin-bottom: 0.6em; }
/* On the wide board the strip hugs its content, so Show all sits beside what it clears.
   The filter panel is narrow in both modes and keeps the full-width strip. */
.expanded .toolbar .filter-summary, .expanded .market-body .filter-summary { width: fit-content; max-width: 100%; }
.expanded .toolbar .filter-summary-chips, .expanded .market-body .filter-summary-chips { flex: 0 1 auto; }
</style>
