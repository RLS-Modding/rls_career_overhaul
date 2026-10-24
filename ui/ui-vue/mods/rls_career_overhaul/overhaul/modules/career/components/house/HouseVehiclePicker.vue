<!-- House picker for "which of your vehicles here?" (opened by useZoneVehiclePicker.js).
     Renders state.view from overhaul_career_garage_zoneVehicles: one .row per vehicle with its picture,
     name and labelled values; vehicles that can't be used stay listed with the reason. Back cancels. -->
<template>
  <!-- Escape (menu) cancels like Back, as in HouseConfirm; OverhaulPopup already maps Back -->
  <div class="modal vehicle-picker" v-bng-on-ui-nav:menu="cancel">
    <div class="picker-head">
      <h3>{{ view.title }}</h3>
      <span v-if="view.placeName" class="caption">{{ view.placeName }}</span>
    </div>
    <p v-if="view.notice" class="notice bad">{{ view.notice }}</p>

    <div class="picker-list scroll" v-bng-ui-nav-scroll>
      <button
        v-for="vehicle in vehicles"
        :key="vehicle.inventoryId"
        type="button"
        class="row picker-row"
        :class="{ blocked: !vehicle.canChoose }"
        :disabled="!vehicle.canChoose"
        :aria-disabled="busy ? 'true' : null"
        :data-inventory-id="vehicle.inventoryId"
        v-bind="navAttrs(vehicle)"
        :bng-scoped-nav-autofocus="popupActive && vehicle.inventoryId === defaultId ? true : null"
        v-bng-focus-if="popupActive && vehicle.inventoryId === defaultId"
        v-bng-sound-class="vehicle.canChoose && 'bng_click_hover_generic'"
        @click="choose(vehicle)">
        <span class="thumb wide">
          <img v-if="vehicle.thumbnail" :src="vehicle.thumbnail" alt="" />
        </span>
        <span class="row-copy">
          <span class="name-line">
            <strong>{{ vehicle.name }}</strong>
            <span v-if="vehicle.isCurrent" class="pill current-tag">Current vehicle</span>
          </span>
          <span class="stats">
            <span v-if="!vehicle.isCurrent" class="stat">
              <span class="stat-key">Distance</span>
              <span class="stat-value">{{ distanceLabel(vehicle) }}</span>
            </span>
            <span v-if="vehicle.blockedReason" class="stat bad">
              <span class="stat-key">{{ view.blockedCaption || "Unavailable" }}</span>
              <span class="stat-value">{{ vehicle.blockedReason }}</span>
            </span>
            <span v-else-if="busy && state.pendingId === vehicle.inventoryId" class="stat">
              <span class="stat-key">Status</span>
              <span class="stat-value">Opening…</span>
            </span>
          </span>
        </span>
      </button>
    </div>

    <div class="actions">
      <HouseButton variant="quiet" binding="back" :disabled="busy" @click="cancel">Cancel</HouseButton>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import { vBngFocusIf, vBngOnUiNav, vBngSoundClass, vBngUiNavScroll } from "@/common/directives"
import HouseButton from "./HouseButton.vue"

const props = defineProps({
  popupActive: Boolean,
  // reactive { view, pendingId } owned by useZoneVehiclePicker; Lua re-pushes the view while open
  state: { type: Object, required: true },
  onChoose: { type: Function, required: true },
})
const emit = defineEmits(["return"])

const view = computed(() => props.state.view || { vehicles: [] })
const vehicles = computed(() => (Array.isArray(view.value.vehicles) ? view.value.vehicles : []))
const busy = computed(() => props.state.pendingId != null)
// Lua sorts usable vehicles first: the one the player is in, then the nearest. Latched per ticket so
// a refresh (a car moving closer) never pulls focus off the row the player moved to.
const defaultVehicle = computed(() => vehicles.value.find(vehicle => vehicle.canChoose) || null)
const defaultId = ref(null)
watch(() => view.value.ticket, () => { defaultId.value = defaultVehicle.value?.inventoryId ?? null }, { immediate: true })

// rows stay focusable while a choice is pending so a pad keeps its place
const choose = vehicle => {
  if (vehicle.canChoose && !busy.value) props.onChoose(vehicle.inventoryId)
}

const cancel = event => {
  event?.stopPropagation?.()
  if (!busy.value) emit("return", false)
}

const navAttrs = vehicle => (vehicle.canChoose ? { "bng-nav-item": "" } : { "bng-nav-item": "", "bng-no-nav": "true" })

// the car the player is in carries a "Current vehicle" tag instead of a distance
const distanceLabel = vehicle => {
  return Number.isFinite(vehicle.distanceMeters) ? `${vehicle.distanceMeters} m` : "Nearby"
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.vehicle-picker {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(30em, 92vw);
  gap: var(--space-3);
  padding: 1.1em 1.1em 1em;
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
}
.picker-head {
  display: grid;
  gap: 0.2em;
}
// about five rows before the list scrolls
.picker-list {
  display: grid;
  gap: var(--space-1);
  max-height: 24em;
  padding: 0.25em;
  margin: -0.25em;
}
.picker-row {
  @include house-focus;
  .thumb img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .name-line {
    display: flex;
    align-items: center;
    gap: 0.5em;
    min-width: 0;
  }
  // .row-copy dims and shrinks every span; the tag keeps the house pill type
  .row-copy .current-tag {
    flex: 0 0 auto;
    color: rgba(255, 255, 255, 0.8);
    font-size: 0.74em;
  }
  // .row-copy dims every span; the labelled values set their own type
  .row-copy .stats {
    gap: 0.3em 1.6em;
    margin-top: 0.15em;
    overflow: visible;
    white-space: normal;
  }
  .row-copy .stat-key {
    font-size: 0.68em;
    color: var(--faint);
  }
  .row-copy .stat-value {
    color: #fff;
    font-size: 0.95em;
    font-variant-numeric: tabular-nums;
  }
  .row-copy .stat.bad .stat-value {
    color: var(--bad);
  }
  &:disabled {
    cursor: default;
  }
  &.blocked {
    background: rgba(255, 255, 255, 0.03);
    .thumb,
    .row-copy strong {
      opacity: 0.55;
    }
  }
}
.actions > :deep(.house-button) {
  min-width: 6.5em;
}
</style>
