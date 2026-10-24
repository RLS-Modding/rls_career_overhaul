<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <section class="lmm-section">
    <div class="lmm-section-heading">
      <h3>{{ pickable ? "Pick what to sell" : "Save contents" }}</h3>
      <button v-if="!pickable" type="button" class="lmm-link" @click="emit('toggle-assets')">
        {{ assetsOpen ? "Hide" : `Show ${assetCount} item${assetCount === 1 ? "" : "s"}` }}
      </button>
      <div v-else class="lmm-bulk">
        <button type="button" class="lmm-link" @click="emit('select-all')">All</button>
        <button type="button" class="lmm-link" @click="emit('select-issues')">Only at-risk</button>
        <button type="button" class="lmm-link" @click="emit('select-none')">None</button>
      </div>
    </div>

    <p v-if="pickable" class="lmm-selection-total">
      Selling <strong>{{ selectedCashOutIds.length + selectedGarageIds.length }}</strong>
      of {{ assetCount }}, credits <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(individualTotal) }}</strong>
    </p>

    <div v-if="assetsVisible" class="lmm-asset-groups">
      <div v-if="vehicles.length" class="lmm-asset-group">
        <div class="lmm-asset-group-head">
          <h4>Vehicles</h4>
          <span>{{ vehicleCounts.available }} available, {{ vehicleCounts.atRisk }} at risk</span>
        </div>
        <div class="lmm-assets">
          <label
            v-for="vehicle in vehicles"
            :key="vehicle.id"
            :class="[
              'lmm-asset',
              { 'lmm-asset--issue': !vehicle.available },
              { 'lmm-asset--pickable': pickable },
              { 'is-picked': pickable && selectedCashOutIds.includes(Number(vehicle.id)) },
            ]">
            <input
              v-if="pickable"
              type="checkbox"
              class="lmm-asset-check"
              :checked="selectedCashOutIds.includes(Number(vehicle.id))"
              @change="emit('toggle-vehicle', vehicle.id)" />
            <span class="lmm-asset-main">
              <strong>{{ vehicle.name }}</strong>
              <span class="lmm-asset-sub">{{ vehicle.model || "Unknown model" }}</span>
              <span v-if="vehicle.issues?.length" class="lmm-asset-reason">{{ vehicle.issues.join(", ") }}</span>
            </span>
            <span :class="['lmm-status', vehicle.available ? 'lmm-status--ok' : 'lmm-status--risk']">
              {{ vehicle.available ? "Available" : "At risk" }}
            </span>
            <span class="lmm-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(vehicle.savedValue) }}</span>
          </label>
        </div>
      </div>

      <div v-if="garages.length" class="lmm-asset-group">
        <div class="lmm-asset-group-head">
          <h4>Garages</h4>
          <span>{{ garageCounts.available }} available, {{ garageCounts.atRisk }} at risk</span>
        </div>
        <p class="lmm-hint">Garage proceeds use the immediate sell-back estimate after any saved mortgage balance.</p>
        <div class="lmm-assets">
          <label
            v-for="garage in garages"
            :key="garage.id"
            :class="[
              'lmm-asset',
              { 'lmm-asset--issue': !garage.available },
              { 'lmm-asset--pickable': pickable },
              { 'is-picked': pickable && selectedGarageIds.includes(String(garage.id)) },
            ]">
            <input
              v-if="pickable"
              type="checkbox"
              class="lmm-asset-check"
              :checked="selectedGarageIds.includes(String(garage.id))"
              @change="emit('toggle-garage', garage.id)" />
            <span class="lmm-asset-main">
              <strong>{{ garage.name }}</strong>
              <span class="lmm-asset-sub">
                {{ garage.capacity || 0 }} space{{ garage.capacity === 1 ? "" : "s" }}
                <template v-if="garage.vehicleCount">, {{ garage.vehicleCount }} stored vehicle{{ garage.vehicleCount === 1 ? "" : "s" }}</template>
              </span>
              <span v-if="garage.issues?.length" class="lmm-asset-reason">{{ garage.issues.join(", ") }}</span>
            </span>
            <span :class="['lmm-status', garage.available ? 'lmm-status--ok' : 'lmm-status--risk']">
              {{ garage.available ? "Available" : "At risk" }}
            </span>
            <span class="lmm-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(garage.savedValue) }}</span>
          </label>
        </div>
      </div>
    </div>
  </section>
</template>

<script setup>
// Asset list of LegacyMigrationModal's Options step: the heading controls, the selection total, and the vehicle and garage
// rows. The shell owns the selection and the open state. This component shows them and emits each request as an event.
import { BngIcon, icons } from "@/common/components/base"
import { formatMoney } from "./format.js"

defineProps({
  pickable: Boolean,
  assetsOpen: Boolean,
  assetsVisible: Boolean,
  assetCount: { type: Number, default: 0 },
  vehicles: { type: Array, default: () => [] },
  garages: { type: Array, default: () => [] },
  vehicleCounts: { type: Object, required: true },
  garageCounts: { type: Object, required: true },
  selectedCashOutIds: { type: Array, default: () => [] },
  selectedGarageIds: { type: Array, default: () => [] },
  individualTotal: { type: Number, default: 0 },
})

const emit = defineEmits(["toggle-assets", "select-all", "select-issues", "select-none", "toggle-vehicle", "toggle-garage"])
</script>

<style lang="scss" scoped>
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/legacyMigration/tokens" as *;
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/legacyMigration/skin" as *;

@include lmm-section;
@include lmm-section-heading;
@include lmm-hint;
@include lmm-currency;

.lmm-link {
  border: 0;
  background: none;
  padding: 0;
  color: $accent;
  font-family: inherit;
  font-size: 0.78em;
  font-weight: 700;
  cursor: pointer;

  &:hover { text-decoration: underline; }
}

.lmm-bulk {
  display: flex;
  gap: 0.75em;
}

.lmm-selection-total {
  margin: -0.15em 0 0.55em;
  color: rgba(255, 255, 255, 0.65);
  font-size: 0.8em;

  strong { color: #fff; }
}

.lmm-asset-groups {
  display: flex;
  flex-direction: column;
  gap: 0.9em;
}

.lmm-asset-group-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5em;
  margin-bottom: 0.35em;

  span { color: $muted; font-size: 0.74em; }
}

.lmm-assets {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.lmm-asset {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto 6em;
  align-items: center;
  gap: 0.65em;
  padding: 0.5em 0.7em;
  border: 1px solid transparent;
  border-radius: 8px;
  background: rgba(15, 23, 42, 0.5);
}
.lmm-asset--pickable {
  grid-template-columns: auto minmax(0, 1fr) auto 6em;
  cursor: pointer;

  &:hover { border-color: rgba(255, 122, 26, 0.4); }
  &.is-picked { border-color: rgba(255, 122, 26, 0.65); background: rgba(255, 122, 26, 0.08); }
}
.lmm-asset--issue { border-color: rgba(251, 146, 60, 0.45); }

.lmm-asset-check {
  width: 1em;
  height: 1em;
  accent-color: $accent;
}

.lmm-asset-main {
  display: flex;
  flex-direction: column;
  min-width: 0;

  strong { font-size: 0.88em; }
}
.lmm-asset-sub { color: $muted; font-size: 0.72em; }
.lmm-asset-reason { color: $risk; font-size: 0.7em; }

.lmm-status {
  padding: 0.18em 0.5em;
  border-radius: 999px;
  font-size: 0.66em;
  font-weight: 800;
  white-space: nowrap;
}
.lmm-status--ok { color: $ok; background: rgba(74, 222, 128, 0.14); }
.lmm-status--risk { color: $risk; background: rgba(251, 146, 60, 0.16); }

.lmm-value {
  text-align: right;
  color: rgba(255, 255, 255, 0.75);
  font-size: 0.85em;
  font-variant-numeric: tabular-nums;
}
</style>
