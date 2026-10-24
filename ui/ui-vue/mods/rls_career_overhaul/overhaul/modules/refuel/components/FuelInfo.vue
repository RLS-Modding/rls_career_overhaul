<!-- House price block: the running total is the hero (gold, currency icon), the per-unit price sits
     under it, muted. Same props and store calls as before. -->
<template>
  <div class="fuel-info">
    <div class="cost">
      <BngUnit class="cost-value" :money="totalCost" />
      <InsurancePerkIcon class="perk-icon" v-if="fuelDiscountData?.hasFuelDiscount" :perkIconData="fuelDiscountData.perkData" />
    </div>
    <div class="per-unit">
      <BngUnit class="per-unit-value" :money="displayPrice" />
      <span class="unit">/ {{ displayUnit }}</span>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngUnit } from "@/common/components/base"
import { useRefuelStore } from "../refuelStore"
import InsurancePerkIcon from "../../career/components/insurance/insurancePerkIcon.vue"

const refuelStore = useRefuelStore()

const props = defineProps({
  totalCost: {
    type: Number,
    required: true,
  },
  pricePerUnit: {
    type: Number,
    required: true,
  },
  unitLabel: {
    type: String,
    required: true,
  },
  fuelDiscountData: {
    type: Object,
    required: false,
  },
})

const displayPrice = computed(() => Number(refuelStore.convertToPricePerLocalUnit(props.pricePerUnit, refuelStore.currentEnergyType) || 0))
const displayUnit = computed(() => refuelStore.getUnitLabel(refuelStore.currentEnergyType))
</script>

<style scoped lang="scss">
.fuel-info {
  display: grid;
  justify-items: center;
  gap: 0.15em;
  padding: 0.2em 0 0.8em;
}
.cost {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.4em;
  color: #fde68a;
  --units-icon-color: #fde68a;
  font-size: 2em;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
  :deep(.unit-container),
  :deep(.info-item) {
    padding: 0;
    margin: 0;
  }
}
.perk-icon {
  font-size: 0.45em;
}
.per-unit {
  display: flex;
  align-items: baseline;
  gap: 0.3em;
  color: rgba(255, 255, 255, 0.72);
  --units-icon-color: rgba(255, 255, 255, 0.55);
  font-size: 0.95em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.unit {
  color: rgba(255, 255, 255, 0.55);
  font-weight: 600;
}
</style>
