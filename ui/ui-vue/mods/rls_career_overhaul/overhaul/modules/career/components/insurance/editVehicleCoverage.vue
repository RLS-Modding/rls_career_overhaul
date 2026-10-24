<template>
  <div class="popup-content rls-house ins-pop" v-bng-scoped-nav="popupScopeBinding" v-bng-on-ui-nav:back,menu="closePopup">
    <div class="top-info pop-head" :title="`Choose how much you'll pay out-of-pocket when repairing this vehicle. Lower deductibles cost more per ${distanceUnit}.`">
      <div class="head-copy">
        <span class="caption">Select deductible</span>
        <h2 class="pop-title">{{ props.vehicleData.name }}</h2>
        <div class="pop-sub">
          <BngUnit class="money-value" :money="props.vehicleData.initialValue" />
          <span>{{ $translate.instant(props.insuranceData.name) }}</span>
        </div>
      </div>
    </div>

    <div class="pop-body">
      <section class="section">
        <span class="caption" title="You pay this amount per repair.">Deductible per repair</span>
        <div class="cover-list">
          <div
            v-for="coverageOption in props.vehicleData.insuranceData.coverageOptionsData.currentCoverageOptionsSanitized"
            :key="coverageOption.name"
            class="cover-item">
            <CoverageOption class="coverage-option"
              :coverageOption="coverageOption"
              :onlyShowMainText="true"
              :changedCoverageOptions="changedCoverageOptions"
              :dontShowName="true"
              @choiceClick="onChoiceClick"
              @toggleChange="onToggleChange"
            />
          </div>
        </div>
      </section>

      <section class="section">
        <span class="caption">Policy impact</span>
        <div class="sheet">
          <div class="lines">
            <div class="line contribution-item" :class="{ 'green': computedNewInsurancePremiumDiff < 0, 'red': computedNewInsurancePremiumDiff > 0 }">
              <span class="label">Insurance premium</span>
              <span class="contribution-item-value">
                <BngUnit class="old-value" :class="{ 'is-old': computedNewInsurancePremiumDiff !== 0 && !isNaN(computedNewInsurancePremiumDiff) }" :money="props.insuranceData.currentPremiumDetails.totalPriceWithDriverScore" />
                <span v-if="computedNewInsurancePremiumDiff !== 0 && !isNaN(computedNewInsurancePremiumDiff)" class="price-diff-container">→</span>
                <BngUnit v-if="computedNewInsurancePremiumDiff !== 0 && !isNaN(computedNewInsurancePremiumDiff)" class="new-value" :money="newInsurancePremiumDetails.totalPriceWithDriverScore" />
              </span>
            </div>
            <div class="line contribution-item" :class="{ 'green': computedNewInsurancePremiumDiff < 0, 'red': computedNewInsurancePremiumDiff > 0 }">
              <span class="label">Vehicle contribution</span>
              <span class="contribution-item-value">
                <BngUnit class="old-value" :class="{ 'is-old': computedNewPremiumDiff !== 0 && !isNaN(computedNewPremiumDiff) }" :money="props.vehicleData.insuranceData.currentPremiumPrice" />
                <span v-if="computedNewPremiumDiff !== 0 && !isNaN(computedNewPremiumDiff)" class="price-diff-container">→</span>
                <BngUnit v-if="computedNewPremiumDiff !== 0 && !isNaN(computedNewPremiumDiff)" class="new-value" :money="newPremiumPrice" />
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>

    <div class="buttons pop-foot">
      <HouseButton class="switch-button" @click="openSwitchProvider">
        Switch provider
      </HouseButton>
      <span class="foot-gap"></span>
      <HouseButton class="cancel-button" variant="quiet" @click="closePopup">
        Cancel
      </HouseButton>
      <HouseButton class="save-button" variant="primary" @click="onSaveClick" :disabled="!props.insuranceData.canPayPaperworkFees || !hasChangedCoverageOptions">
        <template v-if="!props.insuranceData.canPayPaperworkFees">
          Insufficient funds
        </template>
        <template v-else>
          Apply for <BngUnit :money="props.insuranceData.paperworkFees" />
        </template>
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { BngUnit } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import InsuranceIdentity from "./insuranceIdentity.vue"
import CoverageOption from "./coverageOption.vue"
import InsuranceVehTile from "./insuranceVehTile.vue"
import { ref, onMounted, computed, useAttrs } from "vue"
import { lua, useBridge } from "@/bridge"
import { bigLengthUnit } from "../../utils/units"
import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
import "./insuranceStyle.css"

// km or mi, per the player's unit setting (tooltip text).
const distanceUnit = bigLengthUnit(useBridge().units).unit

const props = defineProps({
  insuranceData: {
    type: Object,
    required: true,
  },
  vehicleData: {
    type: Object,
    required: true,
  },
  popupActive: Boolean,
})

const attrs = useAttrs()
const popupScopeBinding = computed(() => ({
  scopeId: `_editVehicleCoverage__${attrs.__id}`,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))
const newPremiumPrice = ref(0)
const newInsurancePremiumDetails = ref({
  totalPriceWithDriverScore: 0
})

const computedNewPremiumDiff = computed(() => {
  return newPremiumPrice.value - props.vehicleData.insuranceData.currentPremiumPrice
})

const computedNewInsurancePremiumDiff = computed(() => {
  return newInsurancePremiumDetails.value.totalPriceWithDriverScore - props.insuranceData.currentPremiumDetails.totalPriceWithDriverScore
})

const hasChangedCoverageOptions = computed(() => {
  if (!props.vehicleData?.insuranceData?.coverageOptionsData?.currentCoverageOptionsSanitized) return false

  return props.vehicleData.insuranceData.coverageOptionsData.currentCoverageOptionsSanitized.some(option => {
    return changedCoverageOptions.value[option.key] !== option.currentValueId
  })
})

const emit = defineEmits(["return"])

const closePopup = () => {
  emit("return", true)
}

const changedCoverageOptions = ref({})

const updatePremiumPrice = async () => {
  const result = await lua.overhaul_career_repair_insurance.calculateVehiclePremium(
    props.vehicleData.id,
    null,
    changedCoverageOptions.value
  )
  newPremiumPrice.value = result.cost

  const newInsurancePremiumDetailsResult = await lua.overhaul_career_repair_insurance.calculateInsurancePremium(
    props.insuranceData.id,
    null,
    {
      [props.vehicleData.id]: changedCoverageOptions.value
    }
  )
  newInsurancePremiumDetails.value = newInsurancePremiumDetailsResult
}

const onChoiceClick = (coverageOption, choice) => {
  changedCoverageOptions.value[coverageOption.key] = choice.id
  updatePremiumPrice()
}

const onToggleChange = (coverageOption, newValue) => {
  const targetChoiceIndex = coverageOption.choices.findIndex(choice => choice.value === newValue)
  if (targetChoiceIndex !== -1) {
    changedCoverageOptions.value[coverageOption.key] = targetChoiceIndex + 1
  }

  updatePremiumPrice()
}

const onSaveClick = () => {
  lua.overhaul_career_repair_insurance.saveNewVehicleCoverageOptions(
    props.vehicleData.id,
    changedCoverageOptions.value
  )
  emit("return", true)
}

// "navigated" tells the parent vehicle list popup to close as well, so no popup covers the routed screen
const openSwitchProvider = async () => {
  const nav = await lua.overhaul_career_repair_insurance.openChooseInsuranceScreen("change", { vehicleId: props.vehicleData.id })
  if (nav?.success) emit("return", "navigated")
}

// copy the current coverage options to the temporary state
onMounted(() => {
  props.vehicleData.insuranceData.coverageOptionsData.currentCoverageOptionsSanitized.forEach(option => {
    changedCoverageOptions.value[option.key] = option.currentValueId
  })
  updatePremiumPrice()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house popup: vehicle name as the title, its value in gold, the deductible choices, then
   what the change does to the premium (savings in ok ink, increases in red). Apply is the one
   orange action. */
.ins-pop {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  gap: var(--space-4);
  width: min(32em, 94vw);
  max-height: min(90vh, calc(100vh - 4rem));
  padding: 1.1em 1.1em 1em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  /* visible: a coverage perk callout may be drawn beside the popup */
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
.pop-sub {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.2em 1.1em;
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 600;
}

.money-value {
  color: var(--money);
  font-variant-numeric: tabular-nums;
}

.pop-body {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  align-content: start;
  gap: var(--space-4);
}

.section {
  display: grid;
  gap: var(--space-2);
}

.cover-list {
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.cover-item {
  padding: 0.6em;
}

.line .label {
  flex: 1 1 auto;
  min-width: 0;
  color: var(--muted);
  font-weight: 600;
}

.contribution-item-value {
  flex: 0 0 auto;
  display: flex;
  align-items: baseline;
  gap: 0.45em;
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  .is-old {
    color: var(--faint);
    font-size: 0.88em;
  }
  .price-diff-container {
    color: var(--faint);
  }
}
.contribution-item.green .new-value {
  color: var(--ok-ink);
}
.contribution-item.red .new-value {
  color: var(--bad);
}

.pop-foot {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: var(--space-2);
  .foot-gap {
    flex: 1 1 auto;
  }
  > :deep(.house-button) {
    min-width: 7em;
  }
}
</style>
