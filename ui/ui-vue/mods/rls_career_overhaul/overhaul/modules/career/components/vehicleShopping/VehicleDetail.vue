<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Detail page for one shop listing, opened from a VehicleCard. Back (button, controller Back via the shop's
     close(), or Escape) returns to the list where it was. Same actions as the card (useShopVehicle). -->
<template>
  <div class="rls-house vehicle-detail" :class="{ 'is-sold': isSold }">
    <div class="vd-top">
      <HouseButton v-bng-on-ui-nav:ok.asMouse.focusRequired variant="quiet" compact :icon="icons.arrowSmallLeft" class="vd-back" @click="$emit('back')">
        {{ backLabel }}
      </HouseButton>
    </div>

    <!-- .force: the right stick scrolls specs and About even while focus sits on the actions -->
    <div class="vd-scroll scroll" v-bng-ui-nav-scroll.force>
      <div class="vd-hero">
        <div class="vd-photo" :class="{ dim: isSold }">
          <img v-if="vehicle.preview && !thumbBroken" :src="vehicle.preview" alt="" @error="thumbBroken = true" />
          <BngIcon v-else class="photo-fallback" :type="icons.car" />
          <span v-if="isSold" class="photo-tag">Sold</span>
        </div>

        <div class="vd-summary">
          <div class="vd-title">
            <h2 class="vd-name">{{ [vehicle.year, vehicle.Brand, vehicle.Name].filter(Boolean).join(" ") }}</h2>
          </div>

          <div class="vd-price-block">
            <div class="vd-price" :class="{ bad: hasInsufficientFunds, sold: isSold }"><BngUnit :money="vehiclePrice" /></div>
            <span v-if="hasInsufficientFunds" class="vd-flag">{{ insufficientFundsLabel }}</span>
            <span class="vd-note">Taxes and fees are added at checkout</span>
          </div>

          <div class="vd-facts">
            <span v-if="vehicle.sellerName" class="fact"><BngIcon class="fact-icon" :type="icons.personSolid" />{{ vehicle.sellerName }}</span>
            <span v-if="!isOnlineSeller && vehicle.distance != null" class="fact"><BngIcon class="fact-icon" :type="icons.mapPoint" />{{ formatDistance(vehicle.distance) }} away</span>
            <span v-if="insuranceName" class="pill insurance" title="Required insurance"><BngIcon class="pill-icon" :type="icons.shieldCheckmark" />{{ insuranceName }}</span>
          </div>

          <div v-if="vehicleShoppingData.disableShopping" class="disabled-message">{{ vehicleShoppingData.disableShoppingReason }}</div>
          <div v-else class="vd-actions">
            <!-- the page's one orange: buying is what this page is for -->
            <HouseButton v-bng-on-ui-nav:ok.asMouse.focusRequired
              v-if="showPurchase"
              variant="primary"
              block
              :icon="icons.shoppingCart"
              :disabled="hasInsufficientFunds || vehicleShoppingData.tutorialPurchase || actionsBlocked"
              @click="openPurchase">
              {{ purchaseButtonLabel }}
            </HouseButton>
            <HouseButton v-bng-on-ui-nav:ok.asMouse.focusRequired v-if="showNegotiate" block :disabled="actionsBlocked" @click="negotiate">Negotiate</HouseButton>
            <div class="vd-actions-row">
              <HouseButton v-bng-on-ui-nav:ok.asMouse.focusRequired v-if="showRoute" block :icon="routeIcon" :disabled="actionsBlocked" @click="routeOrInspect">{{ routeLabel }}</HouseButton>
              <HouseButton v-bng-on-ui-nav:ok.asMouse.focusRequired v-if="showTaxi" block :icon="TAXI_ICON" :disabled="hasInsufficientTaxiFunds || actionsBlocked" @click="confirmTaxi">
                Taxi
                <span v-if="taxiCostKnown" class="taxi-cost"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatTaxiCost(vehicle.quickTravelPrice) }}</span>
                <span v-else class="taxi-cost unknown">{{ formatTaxiCost(vehicle.quickTravelPrice) }}</span>
              </HouseButton>
            </div>
            <p v-if="!showPurchase && !showNegotiate" class="hint vd-visit">Visit {{ vehicle.sellerName || 'the seller' }} to buy this vehicle.</p>
          </div>
        </div>
      </div>

      <section v-if="specs.length" class="vd-section">
        <span class="caption">Specifications</span>
        <dl class="vd-specs">
          <div v-for="s in specs" :key="s.key" class="vd-spec">
            <dt>{{ s.label }}</dt>
            <dd>{{ s.value }}</dd>
          </div>
        </dl>
      </section>

      <section v-if="description" class="vd-section">
        <span class="caption">About</span>
        <p class="vd-description">{{ description }}</p>
      </section>
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { BngIcon, BngUnit, icons } from "@/common/components/base"
import { popupsView } from "@/services/popup"
import { HouseButton } from "../house/index.js"
import { vBngUiNavScroll, vBngOnUiNav } from "@/common/directives"
import { useShopVehicle, TAXI_ICON } from "./useShopVehicle"

const props = defineProps({
  vehicleShoppingData: Object,
  vehicle: Object,
  racingTeamShop: { type: Boolean, default: false },
  backLabel: { type: String, default: "Back to vehicles" },
})
const emit = defineEmits(["back"])

const thumbBroken = ref(false)
watch(() => props.vehicle?.preview, () => (thumbBroken.value = false))

const {
  isSold, isOnlineSeller, purchaseButtonLabel, vehiclePrice, insufficientFundsLabel, hasInsufficientFunds,
  hasInsufficientTaxiFunds, taxiCostKnown, actionsBlocked, showRoute, showTaxi, showPurchase, showNegotiate,
  routeLabel, routeIcon, insuranceName, specs, formatDistance, formatTaxiCost,
  confirmTaxi, routeOrInspect, openPurchase, negotiate,
} = useShopVehicle(props)

const description = computed(() => {
  const d = props.vehicle?.Description || props.vehicle?.description
  return typeof d === "string" && d.trim() ? d.trim() : null
})

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.vehicle-detail {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
  min-height: 0;
  height: 100%;
  color: #fff;
}

.vd-top {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  padding: var(--inset) var(--inset) 0;
}
.vd-back :deep(.btn-label) {
  padding-top: 0.08em;
}

.vd-scroll {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 1.1em;
  padding: 0 var(--inset) var(--inset);
}

/* big photo | summary column with price and actions */
.vd-hero {
  display: grid;
  grid-template-columns: minmax(0, 1.45fr) minmax(16em, 1fr);
  gap: 1.2em;
  align-items: start;
}
.vd-photo {
  position: relative;
  display: grid;
  place-items: center;
  aspect-ratio: 16 / 10;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--photo);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  &.dim img {
    filter: brightness(50%) saturate(40%);
  }
}
.photo-fallback {
  font-size: 5em;
  color: rgba(255, 255, 255, 0.22);
}
.photo-tag {
  position: absolute;
  top: 0.6em;
  left: 0.6em;
  padding: 0.42em 0.6em 0.18em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.8);
  color: var(--bad);
  font-size: 0.8em;
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.vd-summary {
  display: flex;
  flex-direction: column;
  gap: 0.9em;
  min-width: 0;
}
.vd-title {
  display: grid;
  gap: 0.2em;
}
.vd-brand {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 700;
}
.vd-name {
  margin: 0;
  font-size: 1.6em;
  font-weight: 800;
  line-height: 1.12;
  overflow-wrap: anywhere;
}

.vd-price-block {
  display: grid;
  gap: 0.2em;
}
.vd-price {
  color: var(--money);
  font-size: 1.7em;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
  :deep(.bng-unit),
  :deep(.unit) {
    color: inherit;
  }
  &.bad {
    color: var(--bad);
  }
  &.sold {
    color: var(--faint);
    text-decoration: line-through;
  }
}
.vd-flag {
  color: var(--bad);
  font-size: 0.82em;
  font-weight: 700;
}
.vd-note {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
}

.vd-facts {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.45em 1.2em;
}
.fact {
  display: flex;
  align-items: center;
  gap: 0.45em;
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.fact-icon {
  font-size: 1.1em;
  color: var(--faint);
}
.pill.insurance {
  font-size: 0.8em;
  .pill-icon {
    font-size: 1.1em;
    color: var(--faint);
    transform: translateY(-0.1em);
  }
}

.vd-actions {
  display: grid;
  gap: 0.45em;
}
.vd-actions-row {
  display: grid;
  grid-auto-flow: column;
  grid-auto-columns: minmax(0, 1fr);
  gap: 0.45em;
  &:empty {
    display: none;
  }
}
.vd-visit {
  margin: 0;
}
.taxi-cost {
  display: inline-flex;
  align-items: baseline;
  margin-left: 0.35em;
  color: var(--money);
  font-variant-numeric: tabular-nums;
  .cur {
    font-size: 0.95em;
    margin-right: 0.1em;
    transform: translateY(0.08em);
  }
  &.unknown {
    color: var(--faint);
  }
}
.disabled-message {
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 600;
}

/* specs: labelled cells, label over value */
.vd-section {
  display: grid;
  gap: 0.55em;
}
.vd-specs {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(10em, 1fr));
  gap: 0.5em;
  margin: 0;
}
.vd-spec {
  display: grid;
  gap: 0.25em;
  padding: 0.65em 0.8em 0.55em;
  border-radius: var(--radius-tile);
  background: var(--panel);
  dt {
    color: var(--faint);
    font-size: 0.74em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
  dd {
    margin: 0;
    font-size: 1em;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }
}
.vd-description {
  margin: 0;
  max-width: 60em;
  color: var(--muted);
  line-height: 1.45;
}

@media (max-width: 900px) {
  .vd-hero {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
