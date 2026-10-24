<!-- One vehicle in My Vehicles (and the trade-in chooser). House row: photo first, then name, value
     in gold, one line of icon details, and red flags only when something is wrong. Fixed height so
     rows line up whatever their state. -->
<template>
  <div
    v-if="data"
    class="rls-house vehicle-tile-row"
    :class="{ selected, 'hover-enabled': enableHover, 'is-message': !!data._message, small }"
    role="button"
    v-bng-disabled="data.disabled">
    <div v-if="!data._message" class="veh-photo" :class="{ dim: !!locked || !!disabledReason }">
      <img v-if="thumbUrl && !thumbBroken" :src="thumbUrl" alt="" @error="thumbBroken = true" />
      <span v-if="vehicleClassDisplay" class="photo-tag">{{ vehicleClassDisplay }}</span>
      <BngIcon v-if="data.favorite" class="photo-fav" :type="icons.star" v-bng-tooltip="'Favourite'" />
      <div v-if="disabledReason || (locked && !locked.location)" class="photo-lock">
        <strong>{{ disabledReason || locked.reason }}</strong>
        <span v-if="!disabledReason && locked.eta">{{ locked.eta }}</span>
      </div>
    </div>

    <div v-if="!data._message" class="veh-info">
      <div class="veh-name">{{ displayName }}</div>
      <!-- one detail per line -->
      <div class="veh-specs">
        <span v-if="mileage" class="spec">
          <BngIcon class="spec-icon" :type="icons.odometer" />{{ mileage }}
        </span>
        <span class="spec" :class="{ bad: data.isInsured === false }">
          <BngIcon class="spec-icon" :type="icons.shieldCheckmark" />{{ data.isInsured === false ? "Not insured" : $translate.instant(data.insuranceInfo?.name || "No insurance") }}
        </span>
        <span class="spec" :class="{ bad: isDamaged }">
          <BngIcon class="spec-icon" :type="icons.wrench" />
          <template v-if="data.delayReason === 'repair'">Being repaired</template>
          <template v-else-if="isDamaged">Needs repair, {{ conditionPct }}%</template>
          <template v-else>No damage</template>
        </span>
      </div>
    </div>

    <!-- right column: value, then anything about its sale state -->
    <div v-if="!data._message" class="veh-side">
      <div class="veh-value" v-if="!data.returnLoanerPermission?.allow">
        <BngUnit :money="data.marketSellValue || data.value" />
      </div>
      <span v-if="isDamaged && data.valueRepaired && !data.returnLoanerPermission?.allow" class="veh-value-note">
        <BngUnit :money="data.valueRepaired" /> repaired
      </span>
      <div v-if="data.listedForAuction || data.listedForSale || elsewhere" class="veh-flags">
        <span v-if="data.listedForAuction" class="pill warn">At auction</span>
        <span v-if="data.listedForSale" class="pill warn">Listed for sale</span>
        <span v-if="elsewhere" class="pill">{{ location }}</span>
      </div>
    </div>

    <div v-else class="veh-message">{{ data._message }}</div>
  </div>
</template>

<script>
export default {
  width: 100, // em
  margin: 0.25, // em, on each side
}
</script>

<script setup>
import { $translate } from "@/services/translation"
import { computed, ref, watch } from "vue"
import { BngUnit, BngIcon, icons } from "@/common/components/base"
import { vBngDisabled, vBngTooltip } from "@/common/directives"
import { useBridge } from "@/bridge"
import { formatSanctionedClassWithBucket } from "../../utils/sanctionedClassFormat"
import { formatAccessEta } from "../../utils/accessEta.js"
const { units } = useBridge()

const props = defineProps({
  data: Object,
  isTutorial: Boolean,
  selected: Boolean,
  enableHover: {
    type: Boolean,
    default: true,
  },
  small: Boolean,
  disabledReason: String,
})

const thumbBroken = ref(false)

const displayName = computed(() => {
  let name = props.data.niceName
  if (props.data.isCurrentVehicle) {
    name = $translate.instant("ui.career.inventory.vehicleName.current", { name })
  }
  if (!props.data.owned) {
    name = $translate.instant("ui.career.inventory.vehicleName.notOwned", { name })
  }
  return name
})

const partConditionAvg = computed(() => props.data?.conditionAvg ?? 1)
const conditionPct = computed(() => Math.round(partConditionAvg.value * 100))
const isDamaged = computed(() => !!props.data?.needsRepair || partConditionAvg.value < 1)

const thumbUrl = computed(() => (props.data.thumbnail ? `${props.data.thumbnail}?${props.data.dirtyDate}` : null))
watch(thumbUrl, () => (thumbBroken.value = false))

const mileage = computed(() => {
  const m = Number(props.data?.mileage)
  return m > 0 ? units.buildString("length", m, 0) : null
})

const vehiclePwForDisplay = computed(() => {
  const d = props.data
  if (!d) return null
  const direct = Number(d.powerPerWeight)
  if (Number.isFinite(direct) && direct > 0) return direct
  const hp = Number(d.certificationData?.power)
  const kg = Number(d.certificationData?.weight)
  if (Number.isFinite(hp) && hp > 0 && Number.isFinite(kg) && kg > 0) return hp / kg
  return null
})

/** Prefer persisted snapshot from save; fallback to live certificationData (back-compat). */
const performanceIndexDisplay = computed(() => {
  const d = props.data
  if (!d) return null
  const s = d.savedVehicleClassUi && d.savedVehicleClassUi.performanceIndex
  if (s != null && !Number.isNaN(Number(s))) return Number(s).toFixed(0)
  const vc = d.certificationData && d.certificationData.vehicleClass
  if (vc && vc.performanceIndex != null && !Number.isNaN(Number(vc.performanceIndex))) return Number(vc.performanceIndex).toFixed(0)
  return null
})

const vehicleClassDisplay = computed(() => {
  const d = props.data
  if (!d) return null
  const formatted = formatSanctionedClassWithBucket(
    d.savedVehicleClassUi?.label || d.certificationData?.vehicleClass?.label || d.certificationData?.vehicleClass?.name,
    vehiclePwForDisplay.value
  )
  return formatted || performanceIndexDisplay.value
})

const location = computed(() => {
  if (locked.value && !locked.value.location) return locked.value.reason
  if (props.data.niceLocation) return props.data.niceLocation
  if (props.data.inGarage) return "In garage"
  if (props.data.distance) return `${units.buildString("length", props.data.distance, 0)} away`
  return "Storage"
})

// rows are grouped by garage, so location only shows when it adds something
const elsewhere = computed(() => !!props.data && !props.data.niceLocation && (props.data.inStorage || !!props.data.distance))

const locked = computed(() => {
  /**
   * @type {Object}
   * @prop {string} [reason] Blocking reason
   * @prop {string} [eta] Estimated time
   * @prop {boolean} [location] If location should be processed and displayed normally
   */
  let res
  if (props.data._message) {
    res = { reason: props.data._message }
  } else if (props.data.missingFile) {
    res = { reason: "Missing File!" }
  } else if (props.data.timeToAccess) {
    const eta = formatAccessEta(props.data.timeToAccess)
    if (props.data.delayReason === "engineRetailPickup") {
      res = { reason: "Ready at engine shop" }
    } else if (props.data.delayReason === "engineRetailInstall") {
      res = { reason: "Engine swap in progress", eta }
    } else if (props.data.delayReason === "bought") {
      res = { reason: "Out for delivery", eta }
    } else if (props.data.delayReason === "repair") {
      res = { reason: "Being repaired", eta }
    } else if (props.data.delayReason === "rented") {
      res = { reason: "At the film studio", eta }
    } else {
      res = { reason: "Available in", eta }
    }
  } else if (props.data.needsRepair) {
    res = { reason: "Needs repair", location: true }
  }
  return res
})
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.vehicle-tile-row {
  // Setting round corners and focus frame offset for focusable row
  $f-offset: 0.2em;
  $rad: var(--radius-panel);

  // positioned: without it the game's ::before focus frame anchored to a far ancestor and ballooned
  position: relative;
  display: grid;
  grid-template-columns: 11.5em minmax(0, 1fr) auto;
  gap: 1em;
  align-items: center;
  min-height: 7.6em;
  padding: 0.5em 0.9em 0.5em 0.5em;
  border-radius: $rad;
  background: var(--panel);
  color: #fff;
  font-family: "Overpass", var(--fnt-defs);
  cursor: pointer;
  transition: background-color 0.12s;

  // full-width row in the list's scroll box: the house inset ring in place of the game frame
  @include house-focus(var(--focus-inset));

  &.hover-enabled:hover,
  &:focus,
  &:focus-within {
    background: var(--panel-2);
  }
  &.selected {
    background: var(--panel-2);
    .veh-name {
      color: var(--accent-soft);
    }
  }
  &[disabled] {
    cursor: default;
    .veh-info {
      opacity: 0.55;
    }
  }
  &.is-message {
    grid-template-columns: 1fr;
    min-height: 0;
    cursor: default;
  }
}

/* photo: 16:9, class tag top-left, favourite star top-right, lock reason over a dimmed image */
.veh-photo {
  position: relative;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  &.dim img {
    filter: brightness(45%) saturate(50%);
  }
}
.photo-tag {
  position: absolute;
  top: 0.4em;
  left: 0.4em;
  padding: 0.4em 0.5em 0.15em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.78);
  color: rgba(255, 255, 255, 0.85);
  font-size: 0.7em;
  font-weight: 700;
  line-height: 1;
}
.photo-fav {
  position: absolute;
  top: 0.35em;
  right: 0.4em;
  font-size: 1em;
  color: var(--money);
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.8));
}
.photo-lock {
  position: absolute;
  inset: 0;
  display: grid;
  place-content: center;
  gap: 0.1em;
  padding: 0.4em;
  text-align: center;
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.9);
  strong {
    font-size: 0.95em;
    font-weight: 800;
    line-height: 1.15;
  }
  span {
    color: var(--muted);
    font-size: 0.85em;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}

/* info: name, then one detail per line */
.veh-info {
  display: grid;
  gap: 0.45em;
  min-width: 0;
  align-self: center;
}
.veh-name {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.15;
}
.veh-specs {
  display: grid;
  gap: 0.3em;
}
.spec {
  display: flex;
  align-items: center;
  gap: 0.5em;
  min-width: 0;
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  .spec-icon {
    flex: 0 0 auto;
    width: 1.25em;
    font-size: 1.2em;
    text-align: center;
    color: var(--faint);
  }
  &.bad,
  &.bad .spec-icon {
    color: var(--bad);
  }
}

/* right column: value, repaired note, sale tags */
.veh-side {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  align-self: start;
  gap: 0.3em;
  padding-top: 0.55em;
  text-align: right;
}
.veh-value {
  color: var(--money);
  font-size: 1.05em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-unit),
  :deep(.unit) {
    color: inherit;
  }
}
.veh-value-note {
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 600;
  white-space: nowrap;
}
.veh-flags {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.35em;
  margin-top: 0.15em;
}

.veh-message {
  padding: 1.2em 0.6em;
  color: var(--muted);
  font-weight: 600;
  text-align: center;
}

.vehicle-tile-row.small {
  grid-template-columns: 9em minmax(0, 1fr) auto;
  min-height: 6.2em;
}
</style>
