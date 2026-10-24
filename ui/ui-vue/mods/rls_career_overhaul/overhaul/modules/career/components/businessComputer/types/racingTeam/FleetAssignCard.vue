<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <article class="rls-house fleet-assign-card">
    <div class="fleet-assign-card__photo">
      <img :src="displayImage" :alt="displayName" />
      <span v-if="isDeliveryPending" class="photo-pill photo-pill--left">Delivering</span>
      <span v-if="sanctionedClassLabel" class="photo-pill">{{ sanctionedClassLabel }}</span>
    </div>
    <div class="fleet-assign-card__body">
      <div class="fleet-assign-card__head">
        <strong class="fleet-name" :title="displayName">{{ displayName }}</strong>
        <strong v-if="valueLabel" class="fleet-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ valueLabel }}</strong>
      </div>
      <span v-if="!sanctionedClassLabel && classStatusMessage" class="hint">{{ classStatusMessage }}</span>
      <div v-if="hpLabel || pwLabel" class="facts fleet-facts">
        <div v-if="hpLabel" class="fact">
          <span class="fact-key">Power</span>
          <span class="fact-value">{{ hpLabel }}</span>
        </div>
        <div v-if="pwLabel" class="fact">
          <span class="fact-key">Power to weight</span>
          <span class="fact-value">{{ pwLabel }}</span>
        </div>
      </div>
      <HouseButton
        variant="primary"
        block
        class="fleet-assign-card__button"
        :bng-scoped-nav-autofocus="navAutofocus ? true : null"
        @click.stop="$emit('assign', vehicle)"
        @mousedown.stop
      >
        Assign
      </HouseButton>
    </div>
  </article>
</template>

<script setup>
import { computed } from "vue"
import { formatSanctionedClassWithBucket } from "../../../../utils/sanctionedClassFormat"
import { HouseButton } from "../../../house/index.js"
import { useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { formatWholeMoney } from "./racingTeamMoney.js"

const { units } = useBridge()

const props = defineProps({
  vehicle: {
    type: Object,
    required: true
  },
  // controller: the picker modal lands on the first card's Assign button
  navAutofocus: Boolean
})

const displayName = computed(() => {
  const v = props.vehicle
  if (!v) return "Vehicle"
  return v.vehicleName || v.name || `Vehicle #${v.vehicleId ?? v.id ?? ""}`
})

const displayImage = computed(() => {
  const v = props.vehicle
  const src = v?.vehicleImage
  if (typeof src === "string" && src.length > 0) return src
  return "/ui/images/appDefault.png"
})

const sanctionedClassLabel = computed(() => {
  return formatSanctionedClassWithBucket(props.vehicle?.fleetSanctionedClassLabel, props.vehicle?.fleetEffectivePw)
})

const classStatusMessage = computed(() => {
  return typeof props.vehicle?.fleetClassStatusMessage === "string" ? props.vehicle.fleetClassStatusMessage : ""
})

// display only: power and power-to-weight as separate facts, value in gold when the fleet entry has one
const hpLabel = computed(() => {
  const hp = Number(props.vehicle?.fleetEffectiveHp)
  // fleetEffectiveHp is metric hp from Lua: shown in the player's power unit
  return Number.isFinite(hp) && hp > 0 ? units.buildString("power", hp, 0) : ""
})

const pwLabel = computed(() => {
  const pw = Number(props.vehicle?.fleetEffectivePw)
  return Number.isFinite(pw) && pw > 0 ? `${(Math.round(pw * 100) / 100).toFixed(2)} hp/kg` : ""
})

const valueLabel = computed(() => {
  const value = Number(props.vehicle?.vehicleValue ?? props.vehicle?.value)
  return Number.isFinite(value) && value > 0 ? formatWholeMoney(value) : ""
})

const isDeliveryPending = computed(() => props.vehicle?.deliveryPending === true)

defineEmits(["assign"])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Fleet car picker card, house style: photo first, name biggest, value gold, specs as faint facts. */

.fleet-assign-card {
  display: flex;
  flex-direction: column;
  min-width: 0;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--panel);
  font-variant-numeric: tabular-nums;
}

.fleet-assign-card__photo {
  position: relative;
  width: 100%;
  aspect-ratio: 16 / 9;
  overflow: hidden;
  background: var(--photo);

  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.photo-pill {
  position: absolute;
  top: 0.55em;
  right: 0.55em;
  max-width: calc(100% - 1.1em);
  padding: 0.45em 0.6em 0.25em;
  border-radius: var(--radius-pill);
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  font-size: 0.78em;
  font-weight: 700;
  line-height: 1.1;
  white-space: normal;
  text-align: right;

  &--left {
    right: auto;
    left: 0.55em;
    color: var(--accent-soft);
  }
}

.fleet-assign-card__body {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
  padding: var(--inset);
}

.fleet-assign-card__head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.2em 0.8em;
}

.fleet-name {
  flex: 1 1 9em;
  min-width: 0;
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
  /* long names: two lines, then ellipsis */
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.fleet-value {
  flex: 0 0 auto;
  color: var(--money);
  font-size: 1.05em;
  font-weight: 800;
}

.fleet-facts {
  grid-template-columns: repeat(2, minmax(0, 1fr));
  column-gap: 0.85em;

  .fact-value {
    font-size: 0.92em;
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
  }
}

.fleet-assign-card__button {
  margin-top: auto;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
