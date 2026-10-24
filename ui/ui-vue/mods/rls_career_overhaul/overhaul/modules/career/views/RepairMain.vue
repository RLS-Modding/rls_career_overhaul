<template>
  <ComputerWrapper
    :title="$translate.instant('ui.career.repair.titleWithVehicle', { name: repairStore.vehicleData.name })"
    @back="close">
    <BngCard v-if="repairStore.vehicleData.name" class="repairMain rls-house">
      <div class="content scroll" v-bng-ui-nav-scroll.force>
        <!-- the car and what the damage is worth -->
        <section class="car-hero">
          <div class="car-photo">
            <img v-if="repairStore.vehicleData.thumbnail" :src="repairStore.vehicleData.thumbnail" alt="" />
          </div>
          <div class="car-copy">
            <strong class="car-name">{{ repairStore.vehicleData.name }}</strong>
            <span class="hint">Worth <BngUnit :money="repairStore.vehicleData.initialValue" /> repaired</span>
            <span v-if="!repairStore.vehicleData.isInsured" class="pill bad">{{ $translate.instant("ui.career.repair.notInsured") }}</span>
          </div>
          <div class="damage">
            <span class="caption">{{ $translate.instant("ui.career.repair.damageEstimate") }}</span>
            <strong class="damage-value"><BngUnit :money="repairStore.vehicleData.damageCost" /></strong>
          </div>
        </section>

        <!-- how to pay for it -->
        <section class="block">
          <span class="caption">{{ $translate.instant("ui.career.repair.repairOptions") }}</span>
          <div class="repair-options">
            <Button v-for="(repairOption, key) in repairStore.repairOptions" :key="key"
              class="repair-option"
              :class="{ selected: selectedRepairOptionKey === key }"
              :bng-scoped-nav-autofocus="selectedRepairOptionKey === key ? true : undefined"
              :tab-index="-1"
              :nav-item="false"
              @click="onRepairOptionClick(key)"
            >
              <BngIcon class="option-icon" :type="repairOption.useInsurance ? icons.shieldCheckmark : icons.wrench" />
              <span class="option-copy" v-if="repairOption.useInsurance">
                <strong class="option-name">{{ $translate.instant("ui.career.repair.insuranceClaim") }}</strong>
                <span class="hint">{{ $translate.instant(repairOption.insuranceName) }}</span>
                <span class="option-price">
                  <span class="hint">{{ $translate.instant("ui.career.repair.deductible") }}</span>
                  <BngUnit :money="repairStore.repairOptions.insuranceRepairData.deductible" />
                </span>
              </span>
              <span class="option-copy" v-else>
                <strong class="option-name">{{ $translate.instant("ui.career.repair.privateRepair") }}</strong>
                <span class="hint">{{ $translate.instant("ui.career.repair.noPolicyImpact") }}</span>
                <span class="option-price">
                  <span class="hint">{{ $translate.instant("ui.career.repair.fullDamageCost") }}</span>
                  <BngUnit :money="repairStore.vehicleData.damageCost" />
                </span>
              </span>
            </Button>
          </div>
        </section>

        <section v-if="currentRepairOption" class="block">
          <CoverageOption
            :coverageOption="currentRepairOption.repairTimeOptions"
            :key="`repairTime-${selectedRepairOptionKey}`"
            v-model="selectedRepairTimeOptionIndex"
            :simpleSelect="true"
            :showPerkMode="'none'"
          />
        </section>

        <!-- what it changes (red only when it gets worse) -->
        <section v-if="currentRepairOption" class="block">
          <span class="caption">{{ $translate.instant("ui.career.repair.insuranceImpact") }}</span>
          <div class="sheet">
            <div class="lines">
              <div class="line">
                <span class="line-copy">
                  <span>{{ $translate.instant("ui.career.repair.driverScoreChange") }}</span>
                  <span v-if="currentRepairOption.useInsurance" class="hint">{{ accidentForgivenessesText }}</span>
                </span>
                <strong :class="{ worse: currentRepairOption.useInsurance && repairStore.futureDriverScore < repairStore.driverScore }">
                  <template v-if="currentRepairOption.useInsurance && repairStore.futureDriverScore !== repairStore.driverScore">
                    {{ $translate.instant("ui.career.repair.scoreChange", { from: repairStore.driverScore, to: repairStore.futureDriverScore }) }}
                  </template>
                  <template v-else>{{ $translate.instant("ui.career.repair.noChangeWithScore", { score: repairStore.driverScore }) }}</template>
                </strong>
              </div>
              <div v-if="repairStore.repairOptions.insuranceRepairData" class="line">
                <span class="line-copy">
                  <span>{{ $translate.instant("ui.career.repair.premiumImpact") }}</span>
                  <span v-if="currentRepairOption.useInsurance" class="hint">{{ $translate.instant("ui.career.repair.renewsIn", { name: $translate.instant(currentRepairOption.insuranceName) }) }}{{ renewsInFormatted }}</span>
                </span>
                <strong v-if="currentRepairOption.useInsurance && repairStore.repairOptions.insuranceRepairData.futurePremium !== repairStore.repairOptions.insuranceRepairData.currentPremium" class="worse">
                  <BngUnit :money="repairStore.repairOptions.insuranceRepairData.currentPremium" /> → <BngUnit :money="repairStore.repairOptions.insuranceRepairData.futurePremium" />
                </strong>
                <strong v-else class="money">{{ $translate.instant("ui.career.repair.noChange") }} (<BngUnit :money="repairStore.repairOptions.insuranceRepairData.currentPremium" />)</strong>
              </div>
            </div>
          </div>
        </section>
      </div>

      <!-- cost, then the button that pays it -->
      <footer v-if="currentRepairOption" class="repair-foot">
        <div class="cost-lines">
          <div class="cost-line">
            <span class="hint">{{ $translate.instant("ui.career.repair.repairTime") }}, {{ selectedRepairTimeOption?.choiceText }}</span>
            <BngUnit :money="selectedRepairTimeOption?.premiumInfluence" />
          </div>
          <div class="cost-line">
            <span class="hint">{{ currentRepairOption.useInsurance ? $translate.instant("ui.career.repair.deductibleLabel") : $translate.instant("ui.career.repair.vehicleDamage") }}</span>
            <BngUnit :money="currentRepairOption.useInsurance ? repairStore.repairOptions.insuranceRepairData.deductible : repairStore.vehicleData.damageCost" />
          </div>
          <div class="total-line">
            <span>{{ $translate.instant("ui.career.repair.totalCost") }}</span>
            <strong class="money"><BngUnit :money="selectedRepairTimeOption?.totalPrice" /></strong>
          </div>
        </div>
        <HouseButton
          class="confirm-repair-button"
          variant="primary"
          block
          :disabled="repairBusy || !selectedRepairTimeOption?.canPay || !repairStore.vehicleData.needsRepair"
          @click="startRepair(selectedRepairOptionKey, selectedRepairTimeOptionIndex)">
          <template v-if="!repairStore.vehicleData.needsRepair">{{ $translate.instant("ui.career.repair.vehicleDoesntNeedRepair") }}</template>
          <template v-else-if="!selectedRepairTimeOption?.canPay">{{ $translate.instant("ui.career.shared.insufficientFunds") }}</template>
          <template v-else>{{ $translate.instant("ui.career.repair.confirmRepair") }}</template>
        </HouseButton>
      </footer>
    </BngCard>

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { onMounted, onUnmounted, ref, computed, watch } from "vue"
import { BngCard, BngIcon, BngUnit, BngBinding, icons } from "@/common/components/base"
import { HouseButton } from "../components/house/index.js"
import { vBngUiNavScroll } from "@/common/directives"
import { Button } from "@/common/components/utility"
import { lua, useBridge } from "@/bridge"
import { $translate } from "@/services/translation"
import { useRepairStore } from "../stores/repairStore"
import CoverageOption from "../components/insurance/coverageOption.vue"
import InsuranceVehTile from "../components/insurance/insuranceVehTile.vue"

import ComputerWrapper from "./ComputerWrapper.vue"
import { useScreenEntry } from "../composables/useScreenEntryFocus"

import "../components/insurance/insuranceStyle.css"

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()

const { units } = useBridge()

const repairStore = useRepairStore()

const selectedRepairOptionKey = ref(null)
const selectedRepairTimeOptionIndex = ref(1)
const repairBusy = ref(false)

const currentRepairOption = computed(() => {
  if (!selectedRepairOptionKey.value || !repairStore.repairOptions) return null
  return repairStore.repairOptions[selectedRepairOptionKey.value]
})

const accidentForgivenessesText = computed(() => {
  if (!repairStore.repairOptions.insuranceRepairData.accidentForgivenesses > 0) {
    return $translate.instant("ui.career.repair.noAccidentForgivenessesLeft")
  }else{
    return $translate.instant("ui.career.repair.accidentForgivenessesLeft", { count: repairStore.repairOptions.insuranceRepairData.accidentForgivenesses })
  }
})

const selectedRepairTimeOption = computed(() => {
  if (!currentRepairOption.value?.repairTimeOptions?.choices) return null
  return currentRepairOption.value.repairTimeOptions.choices.find(choice => choice.id === selectedRepairTimeOptionIndex.value)
})

const renewsInFormatted = computed(() => {
  if (!currentRepairOption.value?.renewsIn) return ''
  return units.buildString('length', currentRepairOption.value.renewsIn * 1000, 0)
})

// watch for repairOptions to be loaded and set the first insurance option as default
watch(() => repairStore.repairOptions, (newOptions) => {
  if (newOptions && Object.keys(newOptions).length > 0 && !selectedRepairOptionKey.value) {
    // find the first option that uses insurance
    const insuranceKey = Object.keys(newOptions).find(key => newOptions[key].useInsurance)
    // fall back to first option if no insurance option is found
    const selectedKey = insuranceKey || Object.keys(newOptions)[0]
    selectedRepairOptionKey.value = selectedKey
    // set the initial repair time option index from the data
    if (newOptions[selectedKey]?.repairTimeOptions?.currentValueId) {
      selectedRepairTimeOptionIndex.value = newOptions[selectedKey].repairTimeOptions.currentValueId
    }
    // controller entry: start on the chosen repair option (the route's root scope is the Lua target)
    focusScreenEntry()
  }
}, { immediate: true })

// watch for repair option changes and reset the time option index
watch(() => selectedRepairOptionKey.value, (newKey) => {
  if (newKey && repairStore.repairOptions[newKey]?.repairTimeOptions?.currentValueId) {
    selectedRepairTimeOptionIndex.value = repairStore.repairOptions[newKey].repairTimeOptions.currentValueId
  } else {
    selectedRepairTimeOptionIndex.value = 1
  }
})

const onRepairOptionClick = (key) => {
  selectedRepairOptionKey.value = key
}

const close = () => {
  lua.overhaul_career_repair_repairScreen.closeMenu()
}

const startRepair = async (repairOptionKey, repairTimeOptionIndex) => {
  if (repairBusy.value || !selectedRepairTimeOption.value || repairStore.vehicleData.invVehId == null) return
  repairBusy.value = true
  try {
    const result = await lua.overhaul_career_repair_repairScreen.startRepairInGarage(repairStore.vehicleData.invVehId, {
      repairOptionKey,
      repairTimeOptionId: repairTimeOptionIndex,
      quotedPrice: selectedRepairTimeOption.value.totalPrice,
    })
    if (!result?.success) repairStore.getRepairData()
  } finally {
    repairBusy.value = false
  }
}

onMounted(() => {
  repairStore.getRepairData()
})

onUnmounted(() => {
  lua.overhaul_career_repair_repairScreen.onMenuClosed()
  repairStore.resetStore()
})


</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* House repair screen: centred card, em off a resolution-scaled font */
.repairMain.rls-house {
  --bng-card-height: auto;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(46em, 94vw);
  max-height: 100%;
  margin: 0; /* under the screen heading, like the other computer screens */
  color: #fff;
  border-radius: var(--radius-control);
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  :deep(.card-cnt) {
    display: flex;
    flex-direction: column;
    min-height: 0;
    background: rgba(var(--bng-off-black-rgb), 0.92);
  }
  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
    margin: 0 !important;
  }
}

.content {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 1.1em;
  padding: 1.1em 1em 0.8em 1.2em;
}
.block {
  display: grid;
  gap: 0.5em;
}

/* ---- car hero */
.car-hero {
  display: grid;
  grid-template-columns: 12em minmax(0, 1fr) auto;
  gap: 1em;
  align-items: center;
  padding: 0.6em 1em 0.6em 0.6em;
  border-radius: var(--radius-panel);
  background:
    radial-gradient(120% 90% at 100% 0%, rgba(252, 165, 165, 0.1), rgba(252, 165, 165, 0) 60%),
    var(--panel);
}
.car-photo {
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
}
.car-copy {
  display: grid;
  gap: 0.25em;
  min-width: 0;
  justify-items: start;
}
/* justify-items: start sized it to its text, so a long name pushed the card sideways instead of
   ellipsing; cap it to the column and give it two lines */
.car-name {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  max-width: 100%;
  overflow: hidden;
  overflow-wrap: anywhere;
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.15;
}
.damage {
  display: grid;
  gap: 0.15em;
  justify-items: end;
}
.damage-value {
  color: var(--bad);
  font-size: 1.6em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  :deep(.info-item),
  :deep(.value-label) {
    color: var(--bad);
    font-size: inherit;
    font-weight: 800;
  }
}

/* ---- how to pay: two choice tiles */
.repair-options {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.5em;
}
.repair-option {
  --bng-bg-enabled: rgba(255, 255, 255, 0.06);
  --bng-bg-hover: rgba(255, 255, 255, 0.1);
  --bng-bg-active: rgba(255, 255, 255, 0.1);
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-border-enabled: transparent;
  --bng-bg-border-hover: transparent;
  --bng-bg-border-active: transparent;
  --bng-corners-1: var(--radius-panel);
  // BngButton sets a rem font-size; keep the card's resolution-scaled em so the tile copy
  // ("Full Damage Cost" + price) fits its half-width tile at 1280x720
  font-size: inherit !important;
  display: flex !important;
  align-items: flex-start;
  justify-content: flex-start !important; // BngButton centres its content
  gap: 0.8em;
  width: 100%;
  max-width: none !important; // BngButton caps at 20em, which left the tiles narrower than their columns
  margin: 0 !important;
  padding: 0.85em 0.95em 0.8em !important;
  text-align: left;
  color: #fff;
  position: relative;
  @include house-focus;
  &.selected {
    --bng-bg-enabled: rgba(255, 255, 255, 0.1);
    --bng-bg-hover: rgba(255, 255, 255, 0.12);
    background:
      radial-gradient(120% 80% at 0% 0%, rgba(255, 102, 0, 0.14), rgba(255, 102, 0, 0) 60%);
    .option-name,
    .option-icon {
      color: var(--accent-soft);
    }
  }
}
.option-icon {
  flex: 0 0 auto;
  font-size: 1.7em;
  color: rgba(255, 255, 255, 0.7);
}
.option-copy {
  display: grid;
  gap: 0.2em;
  min-width: 0;
  justify-items: start;
}
.option-name {
  font-size: 1.1em;
  font-weight: 800;
}
.option-price {
  display: flex;
  align-items: baseline;
  gap: 0.45em;
  margin-top: 0.3em;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  :deep(.info-item),
  :deep(.value-label) {
    color: var(--money);
    font-weight: 800;
  }
}

/* ---- what it changes */
.sheet .line {
  align-items: center;
  strong {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: baseline;
    gap: 0.3em;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
  strong.worse,
  strong.worse :deep(.info-item),
  strong.worse :deep(.value-label) {
    color: var(--bad);
  }
  strong.money,
  strong.money :deep(.info-item),
  strong.money :deep(.value-label) {
    color: var(--money);
  }
}
.line-copy {
  display: grid;
  gap: 0.1em;
  min-width: 0;
}

/* ---- cost + confirm, pinned under the scroll */
.repair-foot {
  flex: 0 0 auto;
  display: grid;
  gap: 0.7em;
  padding: 0.6em 1.2em 1.1em;
}
.cost-lines {
  display: grid;
  gap: 0.25em;
}
.cost-line {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1em;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}
.total-line {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1em;
  margin-top: 0.2em;
  font-size: 1.3em;
  font-weight: 900;
  .money,
  .money :deep(.info-item),
  .money :deep(.value-label) {
    color: var(--money);
    font-weight: 900;
    font-variant-numeric: tabular-nums;
  }
}
.confirm-repair-button {
  min-height: 2.8em;
}
</style>
