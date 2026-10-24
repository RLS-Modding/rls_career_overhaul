<template>
  <div
    class="insurance-card-container rls-house"
    :class="{
      selected: isSelected,
      'no-insurance-card': hasNoInsurance,
      'current-provider': isCurrentProvider
    }"
    :style="cardStyles"
    @click="selectCard"
    @focusin.self="onFocus"
    bng-nav-item
  >
    <!-- status chip row: always reserved so every card's logo starts at the same height -->
    <div class="pill-row">
      <span class="top-pill"
        v-if="pillText !== null"
        :class="{
          'no-insurance': hasNoInsurance,
          'orange-pill': insuranceData.groupDiscountData?.willHaveGroupDiscountForTheFirstTime,
          'current-provider-pill': isCurrentProvider
        }"
      >
        {{ pillText }}
      </span>
    </div>

    <div class="content">
      <InsuranceIdentity class="insurance-identity" :insuranceData="insuranceData" />

      <div class="insurance-perks-div">
        <div class="perks-header caption" :class="{ 'no-insurance': hasNoInsurance }" v-if="hasNoInsurance">
          {{ hasNoInsurance ? $t("ui.career.insurance.card.consequences") : $t("ui.career.insurance.card.includedBenefits") }}
        </div>
        <InsurancePerks :insuranceData="insuranceData" />
      </div>

      <div class="card-bottom">
        <div
          v-if="hasNoInsurance && insuranceData.leavingInsuranceInfo && !isCurrentProvider"
          class="leaving-insurance-wrapper"
        >
          <span class="caption">Cancellation refund</span>
          <div class="sheet">
            <div class="lines">
              <div class="line">
                <span class="label">
                  Unused coverage
                  <span class="sub">{{ leavingInsuranceRenewsInFormatted }}</span>
                </span>
                <span class="price credit">
                  +<BngUnit :money="insuranceData.leavingInsuranceInfo.coverageRefundPrice" />
                </span>
              </div>
              <div class="line">
                <span class="label">Early cancellation fee (25%)</span>
                <span class="price cost">
                  -<BngUnit :money="insuranceData.leavingInsuranceInfo.earlyTerminationPenalty" />
                </span>
              </div>
              <div class="line total">
                <span class="label">{{ $t("ui.career.insurance.card.youWillReceive") }}</span>
                <span class="price">
                  <BngUnit :money="insuranceData.leavingInsuranceInfo.netRefundPrice" />
                </span>
              </div>
            </div>
          </div>
        </div>

        <div v-if="hasNoInsurance" class="no-insurance-wrapper notice bad" title="No coverage or benefits included">
          You will pay full repair costs
        </div>

        <div
          v-if="!hasNoInsurance && insuranceData.groupDiscountData?.mainText"
          class="group-discount-wrapper"
          :title="insuranceData.groupDiscountData?.secondaryText"
        >
          <div class="discount-main">
            <BngIcon class="discount-check" :type="icons.checkmark" />
            <span class="group-discount-main-text">
              {{ insuranceData.groupDiscountData?.mainText }}
            </span>
          </div>
          <div class="discount-meta">
            <span class="insured-count">
              <BngIcon class="vehicles-icon" :type="icons.car" />
              {{ insuranceData.carsInsuredCount }}
            </span>
            <template v-if="insuranceData.groupDiscountData?.currentTierData?.id > 0">
              <span class="tier-text">
                {{ $ctx_t({ txt: "ui.career.insurance.tier", context: { id: insuranceData.groupDiscountData?.currentTierData?.id } }) }}
              </span>
              <span class="discount-text">
                -{{ insuranceData.groupDiscountData?.currentTierData?.discount * 100 }}%
              </span>
            </template>
          </div>
        </div>

        <div v-if="!hasNoInsurance" class="price-details-wrapper sheet">
          <div class="lines">
            <div class="line" title="You pay your deductible for each crash repair. You can change it after purchase.">
              <span class="label">
                Deductible
                <span v-if="insuranceData.baseDeductibledData.perkData" class="sub deductible-discount">
                  {{ $ctx_t({ txt: "ui.career.insurance.card.discountApplied", context: { percent: insuranceData.baseDeductibledData.perkData.discount * 100 } }) }}
                </span>
                <span v-else class="sub">per repair</span>
              </span>
              <span class="price">
                <BngUnit v-if="insuranceData.baseDeductibledData?.oldPrice" class="old-price" :money="insuranceData.baseDeductibledData.oldPrice" />
                <BngUnit
                  :money="insuranceData.baseDeductibledData.price"
                  :class="insuranceData.baseDeductibledData.oldPrice ? 'green-price' : null"
                />
              </span>
            </div>
            <div class="line">
              <span class="label">
                Total policy
                <span class="sub">Renews in {{ renewsInFormatted }}</span>
              </span>
              <span class="price">
                <BngUnit :money="insuranceData.futurePremiumDetails.totalPriceWithDriverScore" />
              </span>
            </div>
            <div class="line total">
              <span class="label">{{ insuranceData.amountDue > 0 ? 'Amount due' : 'Credit received' }}</span>
              <span class="price" :class="{ credit: !(insuranceData.amountDue > 0) }">
                <BngUnit :money="Math.abs(insuranceData.amountDue)" />
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngIcon, icons, BngUnit } from "@/common/components/base"
import { useBridge } from "@/bridge"
import InsurancePerks from "./insurancePerks.vue"
import InsuranceIdentity from "./insuranceIdentity.vue"
import { hexToRgb } from "@/utils/colorUtils"

const props = defineProps({
  insuranceData: Object,
  isSelected: Boolean,
  isCurrentProvider: {
    type: Boolean,
    default: false
  }
})

const { units } = useBridge()

const emit = defineEmits(['select', 'focus'])

const hasNoInsurance = computed(() => props.insuranceData?.id === -1)

const pillText = computed(() => {
  if (props.isCurrentProvider) {
    return "Current provider"
  }
  if (props.insuranceData.groupDiscountData) {
    if (props.insuranceData.groupDiscountData?.willHaveGroupDiscountForTheFirstTime) {
      return "Multi-vehicle discount"
    } else if (props.insuranceData.groupDiscountData?.willBumpTheirDiscount) {
      return "Bigger discount"
    } else if (props.insuranceData.groupDiscountData?.currentTierData && props.insuranceData.groupDiscountData?.currentTierData.id > 0) {
      return "Discount active"
    }
  }
  return null
})

const renewsInFormatted = computed(() => {
  if (!props.insuranceData?.renewsIn) return ''
  return units.buildString('length', props.insuranceData.renewsIn * 1000, 0)
})

const leavingInsuranceRenewsInFormatted = computed(() => {
  if (!props.insuranceData?.leavingInsuranceInfo?.renewsIn) return ''
  return units.buildString('length', props.insuranceData.leavingInsuranceInfo.renewsIn * 1000, 0)
})

const selectCard = () => {
  emit('select', props.insuranceData.id)
}

const onFocus = () => {
  emit('focus', props.insuranceData.id)
}

const cardStyles = computed(() => {
  const styles = {}

  if (!hasNoInsurance.value && props.insuranceData.color) {
    styles['--insurance-card-rgb'] = hexToRgb(props.insuranceData.color)
  }

  return styles
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house provider card (Choose Insurance shelf). Translucent panel; the selected card is the
   brighter panel with accent-soft name text, no orange ring, no brand-colour stripe, no scale.
   Chip row and logo have fixed heights and the price sheet sits at the bottom, so cards in the
   shelf line up row for row. */
.insurance-card-container {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
  min-height: 100%;
  padding: 0.7em var(--inset) var(--inset);
  border-radius: var(--radius-control);
  background: var(--panel);
  cursor: pointer;
  opacity: 0.78;
  transition: opacity 0.15s ease;

  &:hover {
    opacity: 0.92;
  }

  &.selected {
    opacity: 1;
    background: var(--panel-2);
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.35);
    :deep(.insurance-name) {
      color: var(--accent-soft);
    }
  }

  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
  }

  // Prevent the global focus frame - selection is shown by .selected
  &::before {
    content: none !important;
  }
}

.pill-row {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  height: 1.5em;
}

.top-pill {
  display: inline-flex;
  align-items: center;
  padding: 0.42em 0.55em 0.14em;
  border-radius: var(--radius-pill);
  background: rgba(74, 222, 128, 0.16);
  color: var(--ok-ink);
  font-size: 0.74em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;

  &.current-provider-pill {
    background: rgba(255, 255, 255, 0.09);
    color: rgba(255, 255, 255, 0.82);
  }

  &.no-insurance {
    background: rgba(252, 165, 165, 0.16);
    color: var(--bad);
  }
}

.content {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  min-height: 0;
}

.insurance-identity {
  height: 6em;
  flex: 0 0 auto;
}

.insurance-perks-div {
  display: grid;
  gap: 0.15em;
  padding-top: var(--space-1);
  border-top: 1px solid var(--line);
}

.perks-header.no-insurance {
  color: var(--bad);
  padding-top: 0.35em;
}

/* everything with a price lives at the bottom of the card */
.card-bottom {
  margin-top: auto;
  display: grid;
  gap: var(--space-2);
}

.leaving-insurance-wrapper {
  display: grid;
  gap: var(--space-2);
}

.no-insurance-wrapper {
  font-weight: 800;
  text-align: center;
}

.group-discount-wrapper {
  display: grid;
  gap: 0.25em;
  min-height: 3.6em;
  align-content: center;
  padding: 0.55em var(--inset) 0.45em;
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.22);
}
.discount-main {
  display: flex;
  align-items: center;
  gap: 0.4em;
}
.discount-check {
  --bng-icon-size: 1.1em;
  --bng-icon-color: var(--ok-ink);
  transform: translateY(-0.06em);
}
.group-discount-main-text {
  font-weight: 800;
  line-height: 1.2;
}
.discount-meta {
  display: flex;
  align-items: center;
  gap: 1em;
  padding-left: 1.5em;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
}
.insured-count {
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
}
.vehicles-icon {
  --bng-icon-size: 1.2em;
  --bng-icon-color: var(--faint);
  transform: translateY(-0.08em);
}
.discount-text {
  color: var(--ok-ink);
  font-weight: 800;
}

/* price sheet */
.sheet .line {
  align-items: flex-start;
  .label {
    flex: 1 1 auto;
    min-width: 0;
    display: grid;
    gap: 0.1em;
    font-weight: 700;
  }
  .sub {
    color: var(--faint);
    font-size: 0.82em;
    font-weight: 600;
  }
  .deductible-discount {
    color: var(--ok-ink);
  }
}
.price {
  flex: 0 0 auto;
  display: flex;
  align-items: baseline;
  gap: 0.45em;
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  &.credit {
    color: var(--ok-ink);
  }
  &.cost {
    color: var(--bad);
  }
  .old-price {
    color: var(--faint);
    font-size: 0.85em;
    :deep(.value-label) {
      text-decoration: line-through;
    }
  }
  .green-price {
    color: var(--ok-ink);
  }
}
.line.total {
  align-items: baseline;
  .label {
    font-size: 1.1em;
    font-weight: 900;
  }
  .price {
    font-size: 1.25em;
    :deep(.value-label) {
      font-weight: 900;
    }
  }
}
</style>
