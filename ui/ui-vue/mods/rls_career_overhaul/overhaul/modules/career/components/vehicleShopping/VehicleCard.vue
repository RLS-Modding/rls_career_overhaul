<!-- One shop listing. Computer: photo | name and gold price, the three key specs, seller facts, and two
     buttons (Taxi, Details); everything else, buying included, is on the detail page; the whole card opens the detail page (emit "open"). Phone: compact, photo on top.
     State and actions come from useShopVehicle (shared with VehicleDetail). -->
<template>
  <div class="rls-house vehicle-card" :class="{ 'vehicle-card--phone': phoneMode, 'is-sold': isSold }">
    <!-- phone layout (compact, photo on top) -->
    <div v-if="phoneMode" class="phone-layout">
      <div class="vc-photo phone-photo" :class="{ dim: isSold }">
        <img v-if="vehicle.preview && !thumbBroken" :src="vehicle.preview" alt="" @error="thumbBroken = true" />
        <BngIcon v-else class="photo-fallback" :type="icons.car" />
        <span v-if="isSold" class="photo-tag">Sold</span>
      </div>

      <div class="phone-body">
        <div class="vc-head">
          <div class="vc-title">
            <div class="vc-name">{{ vehicle.year }} {{ vehicle.Name }}</div>
            <div class="vc-brand">{{ vehicle.Brand }}</div>
          </div>
          <div class="vc-price" :class="{ bad: hasInsufficientFunds, sold: isSold }">
            <BngUnit :money="vehiclePrice" />
          </div>
        </div>

        <div class="phone-meta">
          <span v-if="vehicle.Power" class="meta"><BngIcon class="meta-icon" :type="icons.powerGauge01" />{{ units.buildString('power', vehicle.Power, 0) }}</span>
          <span v-if="vehicle.Mileage !== undefined" class="meta"><BngIcon class="meta-icon" :type="icons.odometer" />{{ formatMileage(vehicle.Mileage) }}</span>
          <span v-if="vehicle.sellerName" class="meta"><BngIcon class="meta-icon" :type="icons.personSolid" />{{ vehicle.sellerName }}</span>
          <span v-if="vehicle.distance != null" class="meta"><BngIcon class="meta-icon" :type="icons.mapPoint" />{{ formatDistance(vehicle.distance) }}</span>
        </div>

        <div v-if="vehicleShoppingData.disableShopping" class="disabled-message">
          {{ vehicleShoppingData.disableShoppingReason }}
        </div>
        <div v-else class="phone-actions">
          <HouseButton compact :icon="icons.routeSimple" :disabled="actionsBlocked" @click="navigate">Set Route</HouseButton>
          <HouseButton compact :icon="TAXI_ICON" :disabled="hasInsufficientTaxiFunds || actionsBlocked" @click="confirmTaxi">
            Taxi
            <span v-if="taxiCostKnown" class="taxi-cost"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatTaxiCost(vehicle.quickTravelPrice) }}</span>
            <span v-else class="taxi-cost unknown">{{ formatTaxiCost(vehicle.quickTravelPrice) }}</span>
          </HouseButton>
        </div>
      </div>
    </div>

    <!-- computer layout: the card is the way into the detail page -->
    <div v-else class="vc-row" v-bng-scoped-nav="{ type: 'container', preventNavigationEscape: ['right'] }">
      <button type="button" class="vc-open" bng-nav-item
        v-bng-on-ui-nav:ok.asMouse.focusRequired
        v-bng-on-ui-nav:back.focusRequired="backFromCard"
        :aria-label="`${vehicle.year || ''} ${vehicle.Name || ''} details`"
        @click="$emit('open')"><span class="sr-only">{{ fullName }} details</span></button>
      <div class="vc-photo" :class="{ dim: isSold }">
        <img v-if="vehicle.preview && !thumbBroken" :src="vehicle.preview" alt="" @error="thumbBroken = true" />
        <BngIcon v-else class="photo-fallback" :type="icons.car" />
        <span v-if="isSold" class="photo-tag">Sold</span>
      </div>

      <div class="vc-body">
        <!-- name, brand and where it is (left); gold price (right) -->
        <div class="vc-head">
          <div class="vc-title">
            <h3 class="vc-name">{{ fullName }}</h3>
            <div class="vc-meta">
              <span v-if="!vehicleShoppingData.currentSeller" class="meta" title="Seller">
                <BngIcon class="meta-icon" :type="icons.personSolid" />{{ vehicle.sellerName }}
              </span>
              <span v-if="!vehicleShoppingData.currentSeller && !isOnlineSeller" class="meta" title="Distance">
                <BngIcon class="meta-icon" :type="icons.mapPoint" />{{ formatDistance(vehicle.distance) }}
              </span>
              <span v-if="insuranceName" class="pill insurance" title="Required insurance">
                <BngIcon class="pill-icon" :type="icons.shieldCheckmark" />{{ insuranceName }}
              </span>
            </div>
          </div>
          <div class="vc-side">
            <div class="vc-price" :class="{ bad: hasInsufficientFunds, sold: isSold }">
              <BngUnit :money="vehiclePrice" />
            </div>
            <span v-if="hasInsufficientFunds" class="vc-flag">{{ insufficientFundsLabel }}</span>
          </div>
        </div>

        <!-- the specs people shop by: one strip, caption over value, same columns on every card -->
        <dl class="vc-keyspecs">
          <div v-for="s in keySpecs" :key="s.key" class="spec">
            <dt>{{ s.label }}</dt>
            <dd>{{ s.value }}</dd>
          </div>
        </dl>

        <!-- quick actions on the bottom edge; buying happens on the detail page -->
        <div class="vc-actions">
          <!-- shopping switched off: say why where Taxi would be (faint, last in the hierarchy); Details stays -->
          <span v-if="vehicleShoppingData.disableShopping && vehicleShoppingData.disableShoppingReason" class="disabled-message">
            {{ vehicleShoppingData.disableShoppingReason }}
          </span>
          <HouseButton
            v-if="showTaxi && !vehicleShoppingData.disableShopping"
            compact
            bng-no-nav="true"
            :icon="TAXI_ICON"
            :disabled="hasInsufficientTaxiFunds || actionsBlocked"
            @click="confirmTaxi">
            Taxi
            <span v-if="taxiCostKnown" class="taxi-cost"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatTaxiCost(vehicle.quickTravelPrice) }}</span>
            <span v-else class="taxi-cost unknown">{{ formatTaxiCost(vehicle.quickTravelPrice) }}</span>
          </HouseButton>
          <HouseButton compact class="details-btn" bng-no-nav="true" @click="$emit('open')">
            Details<BngIcon class="details-chev" :type="icons.arrowSmallRight" />
          </HouseButton>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import { BngIcon, BngUnit, icons } from "@/common/components/base"
import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { lua } from '@/bridge'
import { HouseButton } from "../house/index.js"
import { useShopVehicle, TAXI_ICON } from "./useShopVehicle"

const props = defineProps({
  vehicleShoppingData: Object,
  vehicle: Object,
  racingTeamShop: { type: Boolean, default: false },
  phoneMode: { type: Boolean, default: false },
})
defineEmits(["open"])
const backFromCard = event => { event.stopPropagation(); lua.extensions.ui_router.back() }

// photo stays even without a thumbnail (plain car glyph); a broken image falls back the same way
const thumbBroken = ref(false)
watch(() => props.vehicle?.preview, () => (thumbBroken.value = false))

const {
  units, isSold, isOnlineSeller, vehiclePrice, insufficientFundsLabel, hasInsufficientFunds, hasInsufficientTaxiFunds,
  taxiCostKnown, actionsBlocked, showTaxi, insuranceName, specs, formatDistance, formatTaxiCost, formatMileage,
  confirmTaxi, navigate,
} = useShopVehicle(props)

// one line: year, brand, model ("1991 Bruckell Legran Wagon")
const fullName = computed(() => [props.vehicle?.year, props.vehicle?.Brand, props.vehicle?.Name].filter(Boolean).join(" "))

// power, drivetrain, gearbox, odometer: the facts a buyer compares; the rest is on the detail page
const KEY_SPECS = ["power", "drivetrain", "transmission", "mileage"]
const keySpecs = computed(() =>
  KEY_SPECS.map(key => specs.value.find(s => s.key === key))
    .filter(Boolean)
)

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* one listing: photo | body. Sizes in em off the list's resolution-scaled font. */
.vehicle-card {
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  transition: background-color 0.12s;
  &:not(.vehicle-card--phone):hover,
  &:not(.vehicle-card--phone):focus-within {
    background: var(--panel-2);
  }
  &.is-sold .vc-name {
    color: var(--muted);
  }
}

.vc-row {
  position: relative;
  display: grid;
  grid-template-columns: 17em minmax(0, 1fr);
  gap: 1.1em;
  align-items: stretch;
  padding: 0.6em 0.75em 0.6em 0.6em;
  border-radius: inherit;
  cursor: pointer;
  // full-width card in the shop's scroll box: inset ring, for the pad class and keyboard alike
}
.vc-open {
  position: absolute;
  inset: 0;
  z-index: 1;
  border: 0;
  border-radius: inherit;
  background: transparent;
  cursor: pointer;
  @include house-focus(var(--focus-inset));
}
.vc-actions { position: relative; z-index: 2; }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }

/* Preserve the complete preview in the native 16:9 listing frame. */
.vc-photo {
  position: relative;
  display: grid;
  place-items: center;
  align-self: start;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: contain;
  }
  &.dim img {
    filter: brightness(50%) saturate(40%);
  }
}
.photo-fallback {
  font-size: 3em;
  color: rgba(255, 255, 255, 0.22);
}
.photo-tag {
  position: absolute;
  top: 0.45em;
  left: 0.45em;
  padding: 0.42em 0.55em 0.18em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.8);
  color: var(--bad);
  font-size: 0.74em;
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.vc-body {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  min-width: 0;
  padding-top: 0.15em;
}

/* name biggest, brand faint, price gold right */
.vc-head {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 0.3em 1em;
  align-items: start;
}
.vc-title {
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.vc-name {
  margin: 0;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.15;
  overflow-wrap: anywhere;
}
.vc-brand {
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
}
.vc-side {
  display: grid;
  justify-items: end;
  gap: 0.2em;
  text-align: right;
}
.vc-price {
  color: var(--money);
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
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
.vc-flag {
  color: var(--bad);
  font-size: 0.78em;
  font-weight: 700;
}


/* key specs: one captioned strip, four even columns */
.vc-keyspecs {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0;
  margin: 0;
  padding: 0.5em 0;
  border-radius: var(--radius-tile);
  background: rgba(0, 0, 0, 0.22);
  box-shadow: inset 0 0 0 1px var(--line);
}
.spec {
  display: grid;
  gap: 0.2em;
  min-width: 0;
  padding: 0 0.8em;
  & + .spec {
    box-shadow: -1px 0 0 var(--line);
  }
  dt {
    color: var(--faint);
    font-size: 0.7em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
  // third in the hierarchy: under the name and the gold price, above the faint seller facts
  dd {
    margin: 0;
    color: rgba(255, 255, 255, 0.86);
    font-size: 0.92em;
    font-weight: 600;
    line-height: 1.2;
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }
}

/* seller facts under the brand */
.vc-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35em 1.1em;
  min-width: 0;
  margin-top: 0.35em;
}
.meta {
  display: flex;
  align-items: center;
  gap: 0.45em;
  color: var(--faint);
  font-size: 0.86em;
  font-weight: 600;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}
.meta-icon {
  flex: 0 0 auto;
  font-size: 1.1em;
  color: var(--faint);
}
.pill.insurance {
  font-size: 0.78em;
  .pill-icon {
    font-size: 1.1em;
    color: var(--faint);
    transform: translateY(-0.1em);
  }
}

.vc-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.4em;
  margin-top: auto;
}
.details-btn :deep(.btn-label) {
  display: inline-flex;
  align-items: center;
  gap: 0.25em;
}
.details-chev {
  font-size: 1.1em;
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
  align-self: center;
  min-width: 0;
  margin-left: auto;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  text-align: right;
}

/* narrow screens: photo above */
@media (max-width: 900px) {
  .vc-row {
    grid-template-columns: minmax(0, 1fr);
  }
}

/* ---- phone layout */
.vehicle-card--phone {
  display: block;
  overflow: hidden;
  .phone-photo {
    border-radius: 0;
    aspect-ratio: 16 / 9;
  }
  .phone-body {
    display: flex;
    flex-direction: column;
    gap: 0.6em;
    padding: 0.7em 0.8em 0.8em;
  }
  .vc-name {
    font-size: 1.1em;
    font-weight: 800;
  }
  .vc-price {
    font-size: 1.1em;
  }
  .phone-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35em 0.9em;
  }
  .phone-actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.4em;
  }
  .disabled-message {
    align-self: stretch;
    margin: 0;
    text-align: center;
  }
}
</style>
