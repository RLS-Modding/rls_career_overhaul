<template>
  <div class="insurance-details-wrapper rls-house ins-pop" v-bng-scoped-nav="popupScopeBinding" v-bng-on-ui-nav:back,menu="closePopup">
    <div class="header">
      <div class="header-left">
        <span class="caption policy-details">{{ $t("ui.career.insurance.policyDetails") }}</span>
        <h2 class="pop-title insurance-name">{{ $translate.instant(props.insuranceData.name) }}</h2>
        <div class="covers-renew-info">
          <span v-if="props.insuranceData.slogan" class="insurance-slogan">{{ $translate.instant(props.insuranceData.slogan) }}</span>
          <span>Covers {{ props.insuranceData.carsInsuredCount }} vehicles</span>
          <span>{{ $ctx_t({ txt: "ui.career.insurance.renewsEvery", context: { distance: renewsEveryFormatted } }) }}</span>
        </div>
      </div>
      <div class="header-right">
        <span class="caption action-type">Adding vehicle</span>
        <div class="vehicle-name">{{ props.vehicleInfo.Name }}</div>
        <BngUnit class="vehicle-value money-value" :money="props.vehicleInfo.Value" />
      </div>
    </div>

    <div class="pop-body scroll" v-bng-ui-nav-scroll.force>
      <div v-if="props.insuranceData.groupDiscountData.willHaveGroupDiscountForTheFirstTime || props.insuranceData.groupDiscountData.willBumpTheirDiscount || props.insuranceData.groupDiscountData.currentTierData.id > 0" class="group-discount-wrapper">
        <div class="group-discount-header" :title="$t('ui.career.insurance.multiVehicleDiscountDescription')">
          <BngIcon class="discount-check" :type="icons.checkmark" />
          <span class="group-discount-main-text">{{ $t(groupDiscountText) }}</span>
        </div>

        <div class="tiers-wrapper">
          <div class="textual-tiers-wrapper">
            <div class="tier" v-for="tier in props.insuranceData.groupDiscountData.groupDiscountTiers" :key="tier.id">
              <span class="tier-number">{{ $ctx_t({ txt: "ui.career.insurance.tier", context: { id: tier.id } }) }}</span>
              <span class="money-bracket">
                {{ $ctx_t(moneyBracketLabel(tier)) }}
              </span>
            </div>
          </div>
          <InsuranceTiers :tiers="props.insuranceData.groupDiscountData.groupDiscountTiers" />
        </div>

        <div class="current-after-discount-price">
          <div class="tier-discount-price">
            <span class="caption">Current tier</span>
            <div class="policy-tier">
              Tier {{ Math.max(props.insuranceData.groupDiscountData.currentTierData.id, 0) }}
              <span class="tier-off">-{{ props.insuranceData.groupDiscountData.currentTierData.discount * 100 }}%</span>
            </div>
            <div class="policy-value">
              <BngUnit :money="props.insuranceData.totalInsuranceVehsValue" /> fleet value
            </div>
          </div>
          <div class="tier-discount-price isFutureTier">
            <span class="caption">After purchase</span>
            <div class="policy-tier isFuture">
              Tier {{ props.insuranceData.groupDiscountData.futureTierData.id }}
              <span class="tier-off">-{{ props.insuranceData.groupDiscountData.futureTierData.discount * 100 }}%</span>
            </div>
            <div class="policy-value">
              <BngUnit :money="props.insuranceData.totalInsuranceVehsValue + props.insuranceData.vehicleValue" /> fleet value
            </div>
          </div>
        </div>
      </div>

      <div class="prices-breakdown-header">
        <section class="breakdown-item">
          <span class="caption section-label">This vehicle</span>
          <div class="sheet">
            <div class="lines">
              <div class="line">
                <span class="breakdown-label">Coverage cost</span>
                <span class="breakdown-value"><BngUnit :money="props.insuranceData.nonProRatedVehiclePremium" /></span>
              </div>
              <div class="line" title="You join part-way through the renewal cycle and pay only for what is left of it.">
                <span class="breakdown-label">Pro-rated renewal</span>
                <span class="breakdown-value plain">{{ $ctx_t({ txt: "ui.career.insurance.proRatedRenewalMultiplier", context: { percent: props.insuranceData.proRatedPercentage } }) }}</span>
              </div>
              <div v-if="props.insuranceData.groupDiscountData?.currentTierData.id > 0" class="line">
                <span class="breakdown-label">{{ $ctx_t({ txt: "ui.career.insurance.tierDiscount", context: { id: props.insuranceData.groupDiscountData?.currentTierData.id } }) }}</span>
                <span class="breakdown-value saving">-{{ props.insuranceData.groupDiscountData?.currentTierData.discount * 100 }}%</span>
              </div>
              <div class="line result">
                <span class="breakdown-label">Policy add-on cost</span>
                <span class="breakdown-value"><BngUnit :money="props.insuranceData.proRatedVehiclePremium" /></span>
              </div>
            </div>
          </div>
        </section>

        <section class="breakdown-item">
          <span class="caption section-label">New premium</span>
          <div class="sheet">
            <div class="lines">
              <div v-if="props.insuranceData.futurePremiumDetails.items.vehsCoverage" class="line">
                <span class="breakdown-label">Vehicles coverage</span>
                <span class="breakdown-value" :class="{ 'strikethrough-grey': props.insuranceData.futurePremiumDetails.groupDiscountSavings > 0 }">
                  <BngUnit :money="props.insuranceData.futurePremiumDetails.items.vehsCoverage.priceWithoutGroupDiscount" />
                </span>
              </div>
              <div v-if="props.insuranceData.futurePremiumDetails.items.vehsCoverage && props.insuranceData.futurePremiumDetails.groupDiscountSavings > 0" class="line">
                <span class="breakdown-label">
                  {{ props.insuranceData.futurePremiumDetails.items.vehsCoverage.name }}
                  <span class="tier-discount-badge">Tier {{ props.insuranceData.groupDiscountData.currentTierData.id }}, -{{ props.insuranceData.groupDiscountData.currentTierData.discount * 100 }}%</span>
                </span>
                <span class="breakdown-value saving">
                  <BngUnit :money="props.insuranceData.futurePremiumDetails.items.vehsCoverage.price" />
                </span>
              </div>
              <template v-for="(item, key) in props.insuranceData.futurePremiumDetails.items" :key="key">
                <div v-if="key !== 'vehsCoverage'" class="line">
                  <span class="breakdown-label">{{ item.name }}</span>
                  <span class="breakdown-value"><BngUnit :money="item.price" /></span>
                </div>
              </template>
              <div class="line subtotal">
                <span class="breakdown-label">{{ $t("ui.career.insurance.subtotal") }}</span>
                <span class="breakdown-value"><BngUnit :money="props.insuranceData.futurePremiumDetails.totalPrice" /></span>
              </div>
              <div class="line">
                <span class="breakdown-label">Driver score adjustment</span>
                <span class="breakdown-value plain" :class="driverScoreClass">{{ driverScoreAdjustmentText }}</span>
              </div>
              <div class="line result">
                <span class="breakdown-label">Total premium</span>
                <span class="breakdown-value"><BngUnit :money="props.insuranceData.futurePremiumDetails.totalPriceWithDriverScore" /></span>
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>

    <!-- what you pay today, right above the button -->
    <div class="sum-to-pay">
      <span>{{ $t("ui.career.insurance.amountDueToday") }}</span>
      <BngUnit class="sum-to-pay-value" :money="props.insuranceData.addVehiclePrice"/>
    </div>

    <div class="closeButton">
      <HouseButton @click="closePopup">
        Close
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { BngUnit, BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import InsuranceTiers from "./insuranceTiers.vue"
import { computed, useAttrs } from "vue"
import { useBridge } from "@/bridge"
import "./insuranceStyle.css"

const { units } = useBridge()

const props = defineProps({
  insuranceData: Object,
  vehicleInfo: Object,
  driverScoreData: Object,
  popupActive: Boolean,
})

const attrs = useAttrs()
const scopeName = `_insuranceDetailsPopup__${attrs.__id}`
const popupScopeBinding = computed(() => ({
  scopeId: scopeName,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const emit = defineEmits(["return"])

const closePopup = () => {
  emit("return", true)
}

const driverScoreAdjustmentText = computed(() => {
  const multiplier = props.driverScoreData.tier.multiplier
  if (multiplier < 1.0) {
    return `↓${((1 - multiplier) * 100).toFixed(0)}%`
  } else if (multiplier > 1.0) {
    return `↑${((multiplier - 1) * 100).toFixed(0)}%`
  }
  return "0%"
})

const driverScoreClass = computed(() => {
  const multiplier = props.driverScoreData.tier.multiplier
  if (multiplier < 1.0) {
    return "driver-score-discount"
  } else if (multiplier > 1.0) {
    return "driver-score-penalty"
  }
  return ""
})

const moneyBracketLabel = tier => tier.max
  ? { txt: "ui.career.insurance.moneyBracketRange", context: { min: tier.min / 1000, max: tier.max / 1000 } }
  : { txt: "ui.career.insurance.moneyBracketMinPlus", context: { min: tier.min / 1000 } }

const groupDiscountText = computed(() => {
  if (props.insuranceData.groupDiscountData){
    if (props.insuranceData.groupDiscountData.willHaveGroupDiscountForTheFirstTime) {
      return "ui.career.insurance.multiVehicleDiscountAvailable"
    }else if (props.insuranceData.groupDiscountData.willBumpTheirDiscount){
      return "ui.career.insurance.biggerDiscountAvailable"
    }else if (props.insuranceData.groupDiscountData.currentTierData && props.insuranceData.groupDiscountData.currentTierData.id > 0){
      return "ui.career.insurance.multiVehicleDiscountActive"
    }
  }
  return null
})

const renewsEveryFormatted = computed(() => {
  if (!props.insuranceData?.renewsEvery) return ''
  return units.buildString('length', props.insuranceData.renewsEvery * 1000, 0)
})
</script>

<script>
import { popupPosition, popupContainer } from "@/services/popup"
export default {
  wrapper: {
    fade: true,
    blur: true,
    style: popupContainer.default,
  },
  position: [popupPosition.center, popupPosition.center],
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house popup: provider name as the title, the vehicle being added and its value on the
   right, the fleet discount as a quiet strip, two breakdown sheets, and the amount due pinned
   above Close on the same ground. Savings in ok ink, penalties red, money gold. */
.ins-pop {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  width: min(46em, 94vw);
  max-height: min(92vh, calc(100vh - 4rem));
  padding: 1.1em 1.1em 1em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  overflow: hidden;
  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
  }
}

.money-value {
  color: var(--money);
  font-variant-numeric: tabular-nums;
}

// Header
.header {
  flex: 0 0 auto;
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: var(--space-4);
}
.header-left {
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
.covers-renew-info {
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
.header-right {
  flex: 0 0 auto;
  max-width: 45%;
  display: grid;
  justify-items: end;
  gap: 0.1em;
  text-align: right;
}
.vehicle-name {
  max-width: 100%;
  font-weight: 800;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.vehicle-value {
  font-weight: 700;
}

// Scrolling body
.pop-body {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  align-content: start;
  gap: var(--space-4);
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
  margin-right: -0.55em;
  padding-right: 0.05em;
}

// Fleet discount
.group-discount-wrapper {
  display: grid;
  gap: var(--space-3);
  padding: 0.8em var(--inset) var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.group-discount-header {
  display: flex;
  align-items: center;
  gap: 0.4em;
}
.discount-check {
  --bng-icon-size: 1.15em;
  --bng-icon-color: var(--ok-ink);
  transform: translateY(-0.06em);
}
.group-discount-main-text {
  font-size: 1.08em;
  font-weight: 800;
}
.tiers-wrapper {
  display: grid;
  gap: 0.3em;
}
.textual-tiers-wrapper {
  display: flex;
  gap: 0.3em;
}
.tier {
  flex: 1 1 0;
  min-width: 0;
  display: grid;
  justify-items: center;
  gap: 0.05em;
  text-align: center;
}
.tier-number {
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint);
}
.money-bracket {
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.current-after-discount-price {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--space-2);
}
.tier-discount-price {
  display: grid;
  gap: 0.15em;
  padding: 0.6em 0.75em 0.55em;
  border-radius: var(--radius-tile);
  background: rgba(0, 0, 0, 0.22);
  &.isFutureTier {
    background: var(--panel-2);
  }
}
.policy-tier {
  font-size: 1.1em;
  font-weight: 800;
  .tier-off {
    margin-left: 0.3em;
    color: var(--muted);
  }
  &.isFuture .tier-off {
    color: var(--ok-ink);
  }
}
.policy-value {
  display: flex;
  align-items: baseline;
  gap: 0.35em;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

// Breakdown sheets
.prices-breakdown-header {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--space-3);
  align-items: start;
}
.breakdown-item {
  display: grid;
  gap: var(--space-2);
  min-width: 0;
}
.sheet .line {
  align-items: baseline;
}
.breakdown-label {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.1em;
  color: var(--muted);
  font-weight: 600;
}
.tier-discount-badge {
  color: var(--ok-ink);
  font-size: 0.82em;
  font-weight: 700;
}
.breakdown-value {
  flex: 0 0 auto;
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  &.plain {
    color: var(--muted);
  }
  &.saving {
    color: var(--ok-ink);
  }
  &.strikethrough-grey {
    color: var(--faint);
    :deep(.value-label) {
      text-decoration: line-through;
    }
  }
  &.driver-score-discount {
    color: var(--ok-ink);
  }
  &.driver-score-penalty {
    color: var(--bad);
  }
}
.line.subtotal .breakdown-label {
  color: #fff;
}
.line.result {
  .breakdown-label {
    color: #fff;
    font-weight: 800;
  }
  .breakdown-value :deep(.value-label) {
    font-weight: 800;
  }
}

// Total + footer (same ground, no divider)
.sum-to-pay {
  flex: 0 0 auto;
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: var(--space-4);
  padding: 0 0.15em;
  font-size: 1.3em;
  font-weight: 900;
}
.sum-to-pay-value {
  color: var(--money);
  font-variant-numeric: tabular-nums;
  :deep(.value-label) {
    font-weight: 900;
  }
}
.closeButton {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-end;
  > :deep(.house-button) {
    min-width: 7em;
  }
}
</style>
