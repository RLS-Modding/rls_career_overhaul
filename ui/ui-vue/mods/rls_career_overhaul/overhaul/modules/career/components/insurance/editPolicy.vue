<template>
  <div class="popup-content rls-house ins-pop" v-bng-scoped-nav="popupScopeBinding" v-bng-on-ui-nav:back,menu="closePopup">
    <div class="top-banner pop-head">
      <div class="top-info head-copy" :title="$t('ui.career.insurance.editPolicy.description')">
        <span class="caption">{{ $t("ui.career.insurance.smallCard.editPolicy") }}</span>
        <h2 class="pop-title">{{ $translate.instant(props.insuranceData.name) }}</h2>
      </div>

      <HouseButton
        class="edit-vehicles-button"
        compact
        :icon="icons.car"
        @click="openVehicleList"
      >
        {{ $t("ui.career.insurance.editPolicy.editVehicles") }}
      </HouseButton>
    </div>

    <div class="pop-body">
      <!-- coverage choices: no overflow clipping here, the perk callout sits outside the right edge -->
      <div class="customize-coverage cover-list">
        <div
          v-for="coverageOption in props.insuranceData.coverageOptionsData"
          :key="coverageOption.name"
          class="cover-item">
          <CoverageOption
            :coverageOption="coverageOption"
            :changedCoverageOptions="changedCoverageOptions"
            @choiceClick="onChoiceClick"
            @toggleChange="onToggleChange"
          />
        </div>
      </div>

      <section class="premium-details">
        <span class="caption">{{ $t("ui.career.insurance.editPolicy.premiumBreakdown") }}</span>
        <div class="sheet">
          <div class="lines">
            <div class="line" v-for="(detail, key) in props.insuranceData.currentPremiumDetails.items" :key="key">
              <span class="label">{{ detail.name }}</span>
              <span class="value-cell">
                <span v-if="computedNewPremiumDiffs[key] && computedNewPremiumDiffs[key].priceDiff !== 0" class="price-diff-container" :class="{ 'green-price': computedNewPremiumDiffs[key].priceDiff < 0, 'red-price': computedNewPremiumDiffs[key].priceDiff > 0 }">
                  <span class="arrow">{{ computedNewPremiumDiffs[key].priceDiff > 0 ? '↑' : '↓' }}</span>
                  <BngUnit class="price-diff" :money="computedNewPremiumDiffs[key].priceDiff" />
                </span>
                <BngUnit class="money-value" :money="newPremiumDetails?.items?.[key]?.price || detail.price" />
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>

    <!-- the result, pinned right above the button that applies it -->
    <div class="pop-total">
      <div class="total-line">
        <span class="total-copy">
          <span class="total-label">{{ $t("ui.career.insurance.editPolicy.finalPremium") }}</span>
          <span class="driver-score-details">
            {{ $t("ui.career.insurance.editPolicy.basePremium") }} <BngUnit class="money-value" :money="props.insuranceData.currentPremiumDetails.totalPrice" />
            {{ $ctx_t({ txt: "ui.career.insurance.editPolicy.driverScoreMultiplier", context: { score: props.driverScoreData.score } }) }}
            <span class="driver-score" :class="driverScoreColorClass">{{ Math.round(props.driverScoreData.tier.multiplier * 100) }}%</span>
          </span>
        </span>
        <span class="value-cell">
          <span v-if="computedTotalPriceDiff !== 0" class="price-diff-container" :class="{ 'green-price': computedTotalPriceDiff < 0, 'red-price': computedTotalPriceDiff > 0 }">
            <span class="arrow">{{ computedTotalPriceDiff > 0 ? '↑' : '↓' }}</span>
            <BngUnit class="price-diff" :money="computedTotalPriceDiff" />
          </span>
          <BngUnit class="money-value total-value" :money=" newPremiumDetails?.totalPriceWithDriverScore || props.insuranceData.currentPremiumDetails.totalPriceWithDriverScore" />
        </span>
      </div>
    </div>

    <div class="buttons pop-foot">
      <HouseButton class="cancel-button" variant="quiet" @click="closePopup">
        {{ $t("ui.common.cancel") }}
      </HouseButton>
      <HouseButton class="save-button" variant="primary" @click="onSaveClick" :disabled="!props.insuranceData.canPayPaperworkFees || !hasChangedCoverageOptions">
        <template v-if="!props.insuranceData.canPayPaperworkFees">
          {{ $t("ui.career.shared.insufficientFunds") }}
        </template>
        <template v-else>
          {{ $t("ui.career.insurance.editPolicy.applyFor") }} <BngUnit :money="props.insuranceData.paperworkFees" />
        </template>
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { $translate } from "@/services/translation"
import InsuranceIdentity from "./insuranceIdentity.vue"
import CoverageOption from "./coverageOption.vue"
import { BngIcon, icons, BngUnit } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { ref, onMounted, computed, useAttrs, defineAsyncComponent } from "vue"
import { lua } from "@/bridge"
import { addPopup } from "@/services/popup"
import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
// vehicleInsuranceList imports this component back; loading it lazily keeps the import graph acyclic
const VehicleInsuranceList = defineAsyncComponent(() => import("./vehicleInsuranceList.vue"))


const props = defineProps({
  insuranceData: {
    type: Object,
    required: true,
  },
  driverScoreData: {
    type: Object,
    required: true,
  },
  popupActive: Boolean,
})

const attrs = useAttrs()
const scopeName = `_editPolicyPopup__${attrs.__id}`
const popupScopeBinding = computed(() => ({
  scopeId: scopeName,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const changedCoverageOptions = ref({})
const newPremiumDetails = ref({})

const computedNewPremiumDiffs = computed(() => {
  if (!newPremiumDetails.value?.items) return {}

  const diffs = {}
  for (const key in newPremiumDetails.value.items) {
    const newPrice = newPremiumDetails.value.items[key]?.price || 0
    const oldPrice = props.insuranceData.currentPremiumDetails.items[key]?.price || 0
    diffs[key] = {
      priceDiff: newPrice - oldPrice,
      newPrice: newPrice,
      oldPrice: oldPrice,
    }
  }
  return diffs
})

const computedTotalPriceDiff = computed(() => {
  if (!newPremiumDetails.value?.totalPrice) return 0
  return newPremiumDetails.value.totalPrice - props.insuranceData.currentPremiumDetails.totalPrice
})

const driverScoreColorClass = computed(() => {
  const multiplier = props.driverScoreData?.tier?.multiplier
  if (!multiplier) return ''
  if (multiplier < 1) return 'driver-score-good'
  if (multiplier > 1) return 'driver-score-bad'
  return ''
})

const hasChangedCoverageOptions = computed(() => {
  if (!props.insuranceData?.coverageOptionsData) return false

  return props.insuranceData.coverageOptionsData.some(option => {
    return changedCoverageOptions.value[option.key] !== option.currentValueId
  })
})

// copy the current coverage options to the temporary state
onMounted(() => {
  if (props.insuranceData?.coverageOptionsData) {
    props.insuranceData.coverageOptionsData.forEach(option => {
      changedCoverageOptions.value[option.key] = option.currentValueId
    })
  }
})

const emit = defineEmits(["return"])

const closePopup = () => {
  emit("return", true)
}

const openVehicleList = () => {
  addPopup(VehicleInsuranceList, { insuranceData: props.insuranceData, driverScoreData: props.driverScoreData })
  closePopup()
}

const onSaveClick = () => {
  lua.overhaul_career_repair_insurance.saveNewInsuranceCoverageOptions(props.insuranceData.id, changedCoverageOptions.value)
  emit("return", true)
}

const updatePremiumDetails = async () => {
  const result = await lua.overhaul_career_repair_insurance.calculateInsurancePremium(
    props.insuranceData.id,
    changedCoverageOptions.value,
    null
  )
  newPremiumDetails.value = result
}

const onToggleChange = (coverageOption, newValue) => {
  // Find the choice that matches the new value
  const targetChoiceIndex = coverageOption.choices.findIndex(choice => choice.value === newValue)
  if (targetChoiceIndex !== -1) {
    changedCoverageOptions.value[coverageOption.key] = targetChoiceIndex + 1
    updatePremiumDetails()
  }
}

const onChoiceClick = (coverageOption, choice) => {
  changedCoverageOptions.value[coverageOption.key] = choice.id
  updatePremiumDetails()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house popup: near-black ground, policy name as the title, coverage choices, premium
   breakdown sheet, final premium pinned above Apply (the one orange action). */
.ins-pop {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  width: min(34em, 94vw);
  max-height: min(90vh, calc(100vh - 4rem));
  padding: 1.1em 1.1em 1em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  /* visible: the coverage perk callout is drawn beside the popup */
  overflow: visible;
  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
  }
}

.pop-head {
  flex: 0 0 auto;
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--space-4);
}
.head-copy {
  min-width: 0;
  display: grid;
  gap: 0.15em;
}
.pop-title {
  margin: 0;
  font-size: 1.45em;
  font-weight: 800;
  line-height: 1.15;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.pop-body {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  align-content: start;
  gap: var(--space-4);
  /* no scroll container: it would clip the perk callout drawn outside the right edge (vanilla had none either) */
}

.cover-list {
  display: grid;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.cover-item {
  padding: 0.75em var(--inset) 0.7em;
  border-bottom: 1px solid var(--line);
  &:last-child {
    border-bottom: 0;
  }
}

.premium-details {
  display: grid;
  gap: var(--space-2);
}

.line .label {
  flex: 1 1 auto;
  min-width: 0;
  color: var(--muted);
  font-weight: 600;
}

.value-cell {
  flex: 0 0 auto;
  display: flex;
  align-items: baseline;
  gap: 0.6em;
  font-variant-numeric: tabular-nums;
}

.money-value {
  color: var(--money);
  font-variant-numeric: tabular-nums;
}

.price-diff-container {
  display: inline-flex;
  align-items: baseline;
  gap: 0.2em;
  font-size: 0.85em;
  font-weight: 700;
  &.green-price {
    color: var(--ok-ink);
  }
  &.red-price {
    color: var(--bad);
  }
}
.arrow {
  font-weight: 800;
}

.pop-total {
  flex: 0 0 auto;
}
.total-line {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: var(--space-4);
  padding: 0 0.15em;
}
.total-copy {
  min-width: 0;
  display: grid;
  gap: 0.15em;
}
.total-label {
  font-size: 1.25em;
  font-weight: 900;
  line-height: 1.15;
}
.total-line > .value-cell {
  font-size: 1.25em;
  font-weight: 900;
  :deep(.value-label) {
    font-weight: 900;
  }
  .price-diff-container {
    font-size: 0.68em;
  }
}
.driver-score-details {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.25em;
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
  .money-value {
    color: var(--muted);
  }
}
.driver-score {
  font-weight: 800;
  color: var(--muted);
  &.driver-score-good {
    color: var(--ok-ink);
  }
  &.driver-score-bad {
    color: var(--bad);
  }
}

.pop-foot {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-end;
  gap: var(--space-2);
  > :deep(.house-button) {
    min-width: 7em;
  }
  .save-button {
    flex: 0 1 auto;
  }
}
</style>
