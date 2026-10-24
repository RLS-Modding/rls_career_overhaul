<!-- RLS override of the vanilla "List a Vehicle for Sale" form (opened with openHouseFormDialog).
     Same v-model contract and price stepping (multiples of 50); laid out in the house style:
     car first, the asking price big and gold, then where it sits against market value and what
     that means for offers. -->
<template>
  <div class="rls-house list-vehicle">
    <div class="car">
      <div class="car-photo">
        <img v-if="thumb && !thumbBroken" :src="thumb" alt="" @error="thumbBroken = true" />
        <BngIcon v-else class="car-fallback" :type="icons.carCoins" />
      </div>
      <div class="car-copy">
        <div class="car-name">{{ formModel.vehicleName }}</div>
        <div v-if="mileage" class="car-meta"><BngIcon :type="icons.odometer" />{{ mileage }}</div>
        <div class="car-meta">{{ $ctx_t({ txt: "ui.career.inventory.listVehicle.marketValue", context: { value: "" } }) }} <span class="money"><BngUnit :money="marketValue" /></span></div>
      </div>
    </div>

    <div class="price-panel">
      <span class="caption">{{ $tt("ui.career.inventory.listVehicle.yourAskingPrice") }}</span>
      <div class="price money"><BngUnit :money="price" /></div>

      <div class="steps">
        <HouseButton v-for="s in steps" :key="s" class="step" @click="adjustPrice(s)">
          {{ s > 0 ? "+" : "−" }}{{ Math.abs(s).toLocaleString() }}
        </HouseButton>
      </div>

      <div class="market">
        <div class="market-track">
          <span class="market-band" />
          <span class="market-mid" />
          <span class="market-marker" :class="priceHint.class" :style="{ left: `${markerPct}%` }" />
        </div>
        <div class="market-scale">
          <span>More offers</span>
          <span>Market</span>
          <span>Fewer offers</span>
        </div>
      </div>

      <div class="outlook">
        <span v-if="priceHint.text" class="pill" :class="priceHint.class">{{ $ctx_t(priceHint.text) }}</span>
        <span class="offers" :class="offerHint.class">{{ $ctx_t(offerHint.text) }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import { BngIcon, BngUnit, icons } from "@/common/components/base"
import { useBridge } from "@/bridge"
import { HouseButton } from "../house/index.js"

const props = defineProps({
  modelValue: {
    type: Object,
    required: true,
  },
})
const emit = defineEmits(["update:modelValue"])

const { units } = useBridge()

const formModel = computed({
  get: () => props.modelValue,
  set: newValue => emit("update:modelValue", newValue),
})

const steps = [-5000, -500, -50, 50, 500, 5000]

function adjustPrice(amount) {
  const price = Math.max(0, Math.round(((formModel.value.price || 0) + amount) / 50) * 50)
  emit("update:modelValue", { ...formModel.value, price })
}

const price = computed(() => Number(formModel.value.price || 0))
const marketValue = computed(() => Number(formModel.value.marketValue || 0))

const thumbBroken = ref(false)
const thumb = computed(() => formModel.value.thumbnail || null)
watch(thumb, () => (thumbBroken.value = false))

const mileage = computed(() => {
  const m = Number(formModel.value.mileage)
  return m > 0 ? units.buildString("length", m, 0) : null
})

// marker on a 50%..150% of market value scale
const markerPct = computed(() => {
  if (!marketValue.value) return 50
  const ratio = price.value / marketValue.value
  return Math.min(100, Math.max(0, (ratio - 0.5) * 100))
})

const priceHint = computed(() => {
  const mv = marketValue.value
  const p = price.value
  if (!mv || !p) return { text: "", class: "" }
  const diff = (p - mv) / mv
  const percent = Math.round(Math.abs(diff) * 100)
  if (percent < 1) return { text: "ui.career.inventory.listVehicle.fairMarketValue", class: "ok" }
  if (diff > 0) return { text: { txt: "ui.career.inventory.listVehicle.aboveMarketValue", context: { percent } }, class: "warn" }
  return { text: { txt: "ui.career.inventory.listVehicle.belowMarketValue", context: { percent } }, class: "low" }
})

const offerHint = computed(() => {
  const mv = marketValue.value
  const p = price.value
  if (!mv || !p) return { text: "ui.career.inventory.listVehicle.regularOffersExpected", class: "regular" }
  const ratio = p / mv
  if (ratio <= 0.9) return { text: "ui.career.inventory.listVehicle.moreOffersExpected", class: "more" }
  if (ratio >= 1.2) return { text: "ui.career.inventory.listVehicle.fewerOffersExpected", class: "fewer" }
  return { text: "ui.career.inventory.listVehicle.regularOffersExpected", class: "regular" }
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.list-vehicle {
  display: grid;
  gap: 0.9em;
  width: 33em;
  max-width: 100%;
}

/* ---- the car */
.car {
  display: grid;
  grid-template-columns: 9em minmax(0, 1fr);
  gap: 0.9em;
  align-items: center;
}
.car-photo {
  display: grid;
  place-items: center;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--panel);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}
.car-fallback {
  font-size: 2em;
  color: rgba(255, 255, 255, 0.25);
}
.car-copy {
  display: grid;
  gap: 0.3em;
  min-width: 0;
}
.car-name {
  font-size: 1.25em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.car-meta {
  display: flex;
  align-items: center;
  gap: 0.4em;
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  :deep(.bng-icon) {
    color: var(--faint);
  }
}
.money,
.money :deep(.info-item),
.money :deep(.value-label) {
  color: var(--money);
  font-weight: 800;
  --units-icon-color: var(--money);
}

/* ---- asking price */
.price-panel {
  display: grid;
  justify-items: center;
  gap: 0.7em;
  padding: 1em 1em 1.1em;
  border-radius: var(--radius-panel);
  background:
    radial-gradient(90% 70% at 50% 0%, rgba(253, 230, 138, 0.08), rgba(253, 230, 138, 0) 70%),
    var(--panel);
}
.price {
  font-size: 2.4em;
  line-height: 1.05;
  font-variant-numeric: tabular-nums;
  :deep(.info-item),
  :deep(.value-label) {
    font-size: inherit;
    font-weight: 900;
  }
}
.steps {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr)) 0.6em repeat(3, minmax(0, 1fr));
  gap: 0.35em;
  width: 100%;
  .step {
    width: 100%;
    padding-left: 0.3em;
    padding-right: 0.3em;
    font-variant-numeric: tabular-nums;
  }
  .step:nth-child(4) {
    grid-column: 5;
  }
}

/* ---- where the price sits against market value */
.market {
  display: grid;
  gap: 0.35em;
  width: 100%;
  margin-top: 0.2em;
}
.market-track {
  position: relative;
  height: 0.45em;
  border-radius: 1em;
  background: rgba(255, 255, 255, 0.1);
}
/* 90%..120% of market: regular offers */
.market-band {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 40%;
  width: 30%;
  background: rgba(255, 255, 255, 0.12);
}
.market-mid {
  position: absolute;
  top: -0.25em;
  bottom: -0.25em;
  left: 50%;
  width: 1px;
  background: rgba(255, 255, 255, 0.35);
}
.market-marker {
  position: absolute;
  top: 50%;
  width: 0.95em;
  height: 0.95em;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 0 0 0.2em rgba(0, 0, 0, 0.45);
  transform: translate(-50%, -50%);
  &.ok {
    background: var(--ok-ink);
  }
  &.warn {
    background: var(--warn);
  }
}
.market-scale {
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  span:last-child {
    text-align: right;
  }
}

.outlook {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  align-items: center;
  gap: 0.6em;
}
.offers {
  font-size: 0.88em;
  font-weight: 700;
  &.more {
    color: var(--ok-ink);
  }
  &.regular {
    color: var(--muted);
  }
  &.fewer {
    color: var(--warn);
  }
}
</style>
