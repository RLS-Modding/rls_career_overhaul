<template>
  <div class="content rls-house ins-pop" v-bng-scoped-nav="popupScopeBinding" v-bng-on-ui-nav:back,menu="closePopup">
    <div class="top-banner">
      <div class="top-banner-left">
        <span class="caption title">Change insurance</span>
        <h2 class="pop-title insurance-name">{{ $translate.instant(props.insuranceData.name) }}</h2>
        <div class="banner-facts">
          <span v-if="props.insuranceData.slogan" class="insurance-slogan">"{{ $translate.instant(props.insuranceData.slogan) }}"</span>
          <span>Covers {{ props.insuranceData.carsInsuredCount }} vehicles</span>
          <span>{{ $ctx_t({ txt: "ui.career.insurance.renewsEvery", context: { distance: renewsEveryFormatted } }) }}</span>
        </div>
      </div>
      <div class="top-banner-right information-wrapper" :title="props.driverScoreData.tier.name">
        <span class="caption">Driver score</span>
        <div class="information-value">
          {{ props.driverScoreData.score }}
          <span class="risk">{{ props.driverScoreData.tier.risk }}</span>
        </div>
        <div class="premium-effect">
          <span class="premium-effect-value" :class="{ 'saving': premiumSavingPercent > 0, 'increase': premiumSavingPercent < 0 }">
            {{ $ctx_t(premiumEffectLabel) }}
          </span>
        </div>
      </div>
    </div>

    <div class="switching-details-wrapper pop-body scroll" v-bng-ui-nav-scroll.force>
      <div class="three-columns-grid">
        <section class="switching-column column-leaving">
          <span class="caption column-header">
            <span class="dir">←</span> Leaving {{ leavingInsuranceName }}
          </span>
          <div class="sheet">
            <div class="lines">
              <div class="line">
                <span class="detail-label">Vehicles</span>
                <span class="detail-value">{{ leavingInfo.vehicleCount }} → {{ leavingInfo.newVehicleCount }}</span>
              </div>
              <div class="line">
                <span class="detail-label">Discount tier</span>
                <span class="detail-value" :class="{ 'tier-change-down': tierDropped }">
                  {{ leavingInfo.discountTierData.id }} → {{ leavingInfo.newDiscountTierData.id }}
                </span>
              </div>
              <div class="line">
                <span class="detail-label">Coverage refund</span>
                <span class="detail-value-positive">+<BngUnit :money="leavingInfo.coverageRefundPrice" /></span>
              </div>
              <div class="line">
                <span class="detail-label">Cancellation fee (25%)</span>
                <span class="detail-value-negative">-<BngUnit :money="leavingInfo.earlyTerminationPenalty" /></span>
              </div>
              <div class="line result">
                <span class="detail-label-bold">
                  Net refund
                  <span class="detail-note">{{ $ctx_t({ txt: "ui.career.insurance.changeInsurance.unusedNote", context: { distance: leavingRenewsInFormatted } }) }}</span>
                </span>
                <span class="detail-value-money"><BngUnit :money="leavingInfo.netRefundPrice" /></span>
              </div>
            </div>
          </div>
        </section>

        <section class="switching-column column-vehicle">
          <span class="caption column-header">Moving vehicle</span>
          <div class="sheet">
            <div class="vehicle-display-box">
              <img :src="props.vehicleInfo?.thumbnail" alt="" class="vehicle-thumbnail" />
            </div>
            <div class="lines">
              <div class="line vehicle-line">
                <span class="detail-value-bold vehicle-name">{{ props.vehicleInfo.Name }}</span>
                <span class="detail-value-money"><BngUnit :money="props.vehicleInfo.Value" /></span>
              </div>
              <div class="line" title="Joining mid-cycle: you pay only for what is left of the renewal cycle.">
                <span class="detail-label">
                  Joining mid-cycle
                  <span class="detail-note">{{ $ctx_t({ txt: "ui.career.insurance.changeInsurance.remainingInCycle", context: { distance: renewsInFormatted } }) }}</span>
                </span>
                <span class="detail-value">× {{ proRatedPercentage }}%</span>
              </div>
            </div>
          </div>
        </section>

        <section class="switching-column column-joining">
          <span class="caption column-header">
            Joining {{ $translate.instant(props.insuranceData.name) }} <span class="dir">→</span>
          </span>
          <div class="sheet">
            <div class="lines">
              <div class="line">
                <span class="detail-label">Vehicles</span>
                <span class="detail-value">{{ props.insuranceData.carsInsuredCount }} → {{ props.insuranceData.carsInsuredCount + 1 }}</span>
              </div>
              <div class="line">
                <span class="detail-label">Discount tier</span>
                <span class="detail-value" :class="{ 'tier-change-up': tierIncreased }">
                  {{ currentTierId }} → {{ futureTierId }}
                </span>
              </div>
              <div class="line">
                <span class="detail-label">Add vehicle cost</span>
                <span class="detail-value-money">+<BngUnit :money="props.insuranceData.addVehiclePrice" /></span>
              </div>
              <div class="line">
                <span class="detail-label">Driver score impact</span>
                <span class="detail-value-impact" :class="driverScoreImpactClass">
                  {{ driverScoreImpactText }}
                </span>
              </div>
              <div class="line result">
                <span class="detail-label-bold">
                  New policy premium
                  <span class="detail-note">{{ $ctx_t({ txt: "ui.career.insurance.changeInsurance.untilRenewal", context: { distance: renewsInFormatted } }) }}</span>
                </span>
                <span class="detail-value-money"><BngUnit :money="props.insuranceData.futurePremiumDetails.totalPriceWithDriverScore" /></span>
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>

    <!-- the net result, pinned right above the button that commits it -->
    <div class="final-amount-box" :class="props.insuranceData.netSwitchingCost > 0 ? 'amount-credit' : 'amount-payment'">
      <div class="final-amount-content-row">
        <div class="final-amount-copy">
          <div class="final-amount-label">{{ props.insuranceData.netSwitchingCost > 0 ? 'Credit received today' : 'Amount due today' }}</div>
          <div class="final-amount-breakdown">
            <span><BngUnit :money="leavingInfo.netRefundPrice" /> refund</span>
            <span>-<BngUnit :money="props.insuranceData.addVehiclePrice" /> new cost</span>
          </div>
        </div>
        <div class="final-amount-total" :class="props.insuranceData.netSwitchingCost < 0 ? 'negative' : 'positive'">
          <BngUnit :money="Math.abs(props.insuranceData.netSwitchingCost)" />
        </div>
      </div>
    </div>

    <div class="buttons">
      <HouseButton class="cancel-button" variant="quiet" @click="closePopup">
        Cancel
      </HouseButton>
      <HouseButton class="save-button" variant="primary" @click="onSwitchClick">
        Switch
        <template v-if="props.insuranceData.netSwitchingCost < 0">
          for <BngUnit :money="Math.abs(props.insuranceData.netSwitchingCost)" />
        </template>
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { computed, useAttrs } from "vue"
import { BngUnit } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import { useBridge } from "@/bridge"
import "./insuranceStyle.css"

const { units } = useBridge()

const props = defineProps({
  insuranceData: {
    type: Object,
    required: true
  },
  vehicleInfo: {
    type: Object,
    default: () => ({})
  },
  driverScoreData: {
    type: Object,
    default: () => ({})
  },
  popupActive: Boolean
})

const emit = defineEmits(["return", "switch"])

const attrs = useAttrs()
const scopeName = `_changeInsuranceDetails__${attrs.__id}`
const popupScopeBinding = computed(() => ({
  scopeId: scopeName,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const premiumSavingPercent = computed(() => {
  const multiplier = props.driverScoreData?.tier?.multiplier || 1.0
  return (1 - multiplier) * 100
})

const leavingInfo = computed(() => props.insuranceData.leavingInsuranceInfo || null)
const premiumEffectLabel = computed(() => {
  const percent = premiumSavingPercent.value
  if (percent > 0) return { txt: "ui.career.insurance.changeInsurance.premiumSaving", context: { percent: percent.toFixed(0) } }
  if (percent < 0) return { txt: "ui.career.insurance.changeInsurance.premiumIncrease", context: { percent: Math.abs(percent).toFixed(0) } }
  return "ui.career.insurance.changeInsurance.premiumNoChange"
})

const leavingInsuranceName = computed(() => $translate.instant(leavingInfo.value?.currentInsuranceName || "Current Insurance"))

const tierDropped = computed(() => {
  if (!leavingInfo.value) return false
  return leavingInfo.value.discountTierData?.id > leavingInfo.value.newDiscountTierData?.id
})

const tierIncreased = computed(() => {
  const current = props.insuranceData.groupDiscountData?.currentTierData?.id || 0
  const future = props.insuranceData.groupDiscountData?.futureTierData?.id || current
  return future > current
})

const currentTierId = computed(() => props.insuranceData.groupDiscountData?.currentTierData?.id || 0)
const futureTierId = computed(() => {
  return props.insuranceData.groupDiscountData?.futureTierData?.id ||
         props.insuranceData.groupDiscountData?.currentTierData?.id || 0
})

const proRatedPercentage = computed(() => {
  return Math.round(props.insuranceData.proRatedPercentage || 100)
})

const driverScoreImpactPercent = computed(() => {
  const multiplier = props.driverScoreData?.tier?.multiplier || 1.0
  return (1 - multiplier) * 100
})

const driverScoreImpactClass = computed(() => {
  if (driverScoreImpactPercent.value > 0) return 'saving'
  if (driverScoreImpactPercent.value < 0) return 'increase'
  return 'neutral'
})

const driverScoreImpactText = computed(() => {
  if (driverScoreImpactPercent.value > 0) {
    return `↓${driverScoreImpactPercent.value.toFixed(0)}%`
  }
  if (driverScoreImpactPercent.value < 0) {
    return `↑${Math.abs(driverScoreImpactPercent.value).toFixed(0)}%`
  }
  return '0%'
})

const renewsEveryFormatted = computed(() => {
  if (!props.insuranceData?.renewsEvery) return ''
  return units.buildString('length', props.insuranceData.renewsEvery * 1000, 0)
})

const renewsInFormatted = computed(() => {
  if (!props.insuranceData?.renewsIn) return ''
  return units.buildString('length', props.insuranceData.renewsIn * 1000, 0)
})

const leavingRenewsInFormatted = computed(() => {
  if (!leavingInfo.value?.renewsIn) return ''
  return units.buildString('length', leavingInfo.value.renewsIn * 1000, 0)
})

const closePopup = () => {
  emit("return", false)
}

let switching = false
const onSwitchClick = () => {
  if (switching) return
  switching = true
  emit("switch")
  emit("return", true)
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house popup: new provider as the title, driver score as a quiet block on the right, three
   sheets (leaving / moving vehicle / joining), the net result pinned above Switch (the one orange
   action). Credits and savings in ok ink, fees and penalties red, money gold. */
.ins-pop {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  width: min(64em, 94vw);
  max-height: min(92vh, calc(100vh - 4rem));
  padding: 1.1em 1.1em 1em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  color: #fff;
  overflow: hidden;
  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
  }
}

// Header
.top-banner {
  flex: 0 0 auto;
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: var(--space-4);
}
.top-banner-left {
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
.banner-facts {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2em 1.1em;
  color: var(--faint);
  font-size: 0.88em;
  font-weight: 600;
}
.insurance-slogan {
  font-style: italic;
}

.information-wrapper {
  flex: 0 0 auto;
  display: grid;
  justify-items: end;
  gap: 0.1em;
  min-width: 9em;
  padding: 0.6em 0.8em 0.55em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  text-align: right;
}
.information-value {
  font-size: 1.3em;
  font-weight: 900;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
  .risk {
    margin-left: 0.25em;
    color: var(--muted);
    font-size: 0.65em;
    font-weight: 700;
  }
}
.premium-effect-value {
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 700;
  &.saving {
    color: var(--ok-ink);
  }
  &.increase {
    color: var(--bad);
  }
}

// Body
.pop-body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
  margin-right: -0.55em;
  padding-right: 0.05em;
}
.three-columns-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: var(--space-3);
  align-items: start;
}
.switching-column {
  display: grid;
  gap: var(--space-2);
  min-width: 0;
}
.column-header {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  .dir {
    color: var(--faint);
  }
}

.vehicle-display-box {
  aspect-ratio: 16 / 9;
  background: var(--photo);
  overflow: hidden;
}
.vehicle-thumbnail {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.sheet .line {
  align-items: baseline;
  min-height: 2.5em;
}
.detail-label,
.detail-label-bold {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.1em;
  color: var(--muted);
  font-weight: 600;
}
.detail-label-bold {
  color: #fff;
  font-weight: 800;
}
.detail-note {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
}
.vehicle-name {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.detail-value,
.detail-value-bold,
.detail-value-money,
.detail-value-positive,
.detail-value-negative,
.detail-value-impact {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: baseline;
  gap: 0.1em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.detail-value {
  color: #fff;
}
.detail-value-bold {
  font-weight: 800;
}
.detail-value-money {
  color: var(--money);
}
.detail-value-positive {
  color: var(--ok-ink);
}
.detail-value-negative {
  color: var(--bad);
}
.detail-value-impact {
  color: var(--muted);
  &.saving {
    color: var(--ok-ink);
  }
  &.increase {
    color: var(--bad);
  }
}
.tier-change-down {
  color: var(--bad);
}
.tier-change-up {
  color: var(--ok-ink);
}
.line.result .detail-value-money :deep(.value-label) {
  font-weight: 800;
}

// Net result + footer (same ground, no divider)
.final-amount-box {
  flex: 0 0 auto;
}
.final-amount-content-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: var(--space-4);
  padding: 0 0.15em;
}
.final-amount-copy {
  min-width: 0;
  display: grid;
  gap: 0.15em;
}
.final-amount-label {
  font-size: 1.3em;
  font-weight: 900;
  line-height: 1.15;
}
.final-amount-breakdown {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2em 1em;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  > span {
    display: inline-flex;
    align-items: baseline;
    gap: 0.25em;
  }
}
.final-amount-total {
  flex: 0 0 auto;
  font-size: 1.3em;
  font-variant-numeric: tabular-nums;
  color: var(--money);
  :deep(.value-label) {
    font-weight: 900;
  }
}
.amount-credit .final-amount-total {
  color: var(--ok-ink);
}

.buttons {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-end;
  gap: var(--space-2);
  > :deep(.house-button) {
    min-width: 7em;
  }
}
</style>
