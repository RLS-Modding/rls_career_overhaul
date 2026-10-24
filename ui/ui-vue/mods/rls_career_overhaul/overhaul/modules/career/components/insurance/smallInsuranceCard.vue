<template>
  <!-- a plan you are not on has only disabled buttons; the card itself stays a d-pad stop so a pad can
       still browse and read every plan (yours is an A-to-enter scope) -->
  <div
    v-bng-scoped-nav="buttonsDisabled ? null : { scopeId: `small-insurance-card-${props.insuranceData.id}` }"
    :bng-nav-item="buttonsDisabled ? '' : undefined"
    :tabindex="buttonsDisabled ? 0 : undefined"
    :class="{ 'no-vehicles': buttonsDisabled, 'is-mine': !buttonsDisabled }"
    class="small-insurance-card themed rls-house"
    >
    <!-- provider (logo or name) and its slogan, left aligned like everything under it -->
    <span v-if="!buttonsDisabled" class="pill accent mine-pill">Your plan</span>
    <InsuranceIdentity class="insurance-identity" :insuranceData="props.insuranceData" />

    <!-- the price is the headline -->
    <div class="premium">
      <span class="caption">
        {{ $ctx_t({ txt: "ui.career.insurance.smallCard.premiumPerPeriod", context: { period: renewsEveryFormatted } }) }}
      </span>
      <span class="premium-value"><BngUnit :money="props.insuranceData.currentPremiumDetails.totalPriceWithDriverScore" /></span>
    </div>

    <div class="facts">
      <div class="fact">
        <span class="fact-key">{{ $t("ui.career.insurance.smallCard.renewsIn") }}</span>
        <span class="fact-value">{{ props.insuranceData.carsInsuredCount === 0 ? "-" : renewsInFormatted }}</span>
      </div>
      <div class="fact">
        <span class="fact-key">{{ $t("ui.career.insurance.smallCard.vehicles") }}</span>
        <span class="fact-value">{{ props.insuranceData.carsInsuredCount }}</span>
      </div>
      <div class="fact money">
        <span class="fact-key">{{ $t("ui.career.insurance.smallCard.vehicleCoverage") }}</span>
        <span class="fact-value"><BngUnit :money="props.insuranceData.totalInsuranceVehsValue" /></span>
      </div>
    </div>

    <div class="perks">
      <InsurancePerks :insuranceData="props.insuranceData" :noDescription="true" />
    </div>

    <!-- multi-vehicle discount: one quiet line until it applies -->
    <div class="discount">
      <p v-if="props.insuranceData.carsInsuredCount === 0" class="hint">
        {{ $t("ui.career.insurance.smallCard.noVehiclesInsured") }}
      </p>
      <p v-else-if="props.insuranceData.carsInsuredCount === 1" class="hint">
        {{ $ctx_t(tierOneUnlockMessage) }}
      </p>
      <template v-else>
        <div class="discount-head">
          <span class="discount-name">{{ $t("ui.career.insurance.smallCard.multiVehicleDiscount") }}</span>
          <span class="discount-savings">
            {{ $t("ui.career.insurance.smallCard.savings") }}<BngUnit :money="props.insuranceData.currentPremiumDetails.groupDiscountSavings" />
          </span>
        </div>
        <span class="hint">{{ $ctx_t(coverageRangeLabel) }}</span>
        <InsuranceTiers :showTier="true" :tiers="props.insuranceData.groupDiscountData.groupDiscountTiers" />
      </template>
    </div>

    <div class="buttons">
      <HouseButton class="edit-policy-button" :icon="icons.adjust" @click="openEditPolicy" :disabled="buttonsDisabled">
        {{ $t("ui.career.insurance.smallCard.editPolicy") }}
      </HouseButton>
      <HouseButton class="see-vehicles-button" :icon="icons.car" @click="openVehicleList" :disabled="buttonsDisabled">
        {{ $t("ui.career.insurance.smallCard.seeVehicles") }}
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { icons, BngUnit } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { vBngScopedNav } from "@/common/directives"
import { addPopup } from "@/services/popup"
import { useBridge } from "@/bridge"

import InsuranceTiers from "./insuranceTiers.vue"
import InsurancePerks from "./insurancePerks.vue"
import InsuranceIdentity from "./insuranceIdentity.vue"
import VehicleInsuranceList from "./vehicleInsuranceList.vue"
import EditPolicy from "./editPolicy.vue"
import "./insuranceStyle.css"

const { units } = useBridge()

const props = defineProps({
  insuranceData: {
    type: Object,
    required: true,
  },
  driverScoreData: {
    type: Object,
    required: true,
  },
})

const renewsEveryFormatted = computed(() => {
  return units.buildString('length', props.insuranceData.renewsEvery * 1000, 0)
})

const renewsInFormatted = computed(() => {
  return units.buildString('length', props.insuranceData.renewsIn * 1000, 0)
})

const buttonsDisabled = computed(() => props.insuranceData.carsInsuredCount === 0)

const openVehicleList = () => {
  addPopup(VehicleInsuranceList, { insuranceData: props.insuranceData, driverScoreData: props.driverScoreData })
}

const openEditPolicy = () => {
  addPopup(EditPolicy, { insuranceData: props.insuranceData, driverScoreData: props.driverScoreData })
}

// if the player hasn't reached any discount tier, display the first tier anyway
const tierToDisplay = computed(() => {
  if (props.insuranceData.groupDiscountData.currentTierData.id > 0) {
    return props.insuranceData.groupDiscountData.currentTierData
  }else{
    return props.insuranceData.groupDiscountData.groupDiscountTiers[0]
  }
})

const tierOneUnlockMessage = computed(() => ({
  txt: "ui.career.insurance.smallCard.addSecondVehicleTierUnlock",
  context: {
    discount: props.insuranceData.groupDiscountData.groupDiscountTiers[0].discount * 100,
  },
}))

const coverageRangeLabel = computed(() => {
  const tier = tierToDisplay.value
  const min = tier.min / 1000
  if (tier.max) {
    return {
      txt: "ui.career.insurance.smallCard.coverageRange",
      context: { min, max: tier.max / 1000 },
    }
  }
  return {
    txt: "ui.career.insurance.smallCard.coverageRangeMinPlus",
    context: { min },
  }
})
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house policy card. Everything left aligned on one grid: provider, the premium as the one
   big gold number, three short facts, perks, a one-line discount note, then the two actions pinned
   to the bottom so every card in the row lines up. Cards with no vehicles stay full strength; only
   their buttons are disabled. */
.small-insurance-card {
  $f-offset: 0.25rem;
  $rad: var(--radius-control);
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 1em;
  width: 24em;
  padding: 1.1em 1.1em 1em;
  border-radius: var(--radius-control);
  background: var(--panel);

  // the card is an A-to-enter scope: it takes focus itself until entered; house ring for that
  @include house-focus;

  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
  }

  // the plan you're on: a soft warm glow from the top and a "Your plan" pill
  &.is-mine {
    background:
      radial-gradient(120% 60% at 0% 0%, rgba(255, 102, 0, 0.16), rgba(255, 102, 0, 0) 60%),
      var(--panel-2);
    box-shadow: inset 0 0 0 1px rgba(255, 178, 122, 0.18);
    &.focus-visible {
      box-shadow: var(--focus), inset 0 0 0 1px rgba(255, 178, 122, 0.18);
    }
    :deep(.insurance-perk-icon-wrapper) {
      color: var(--accent-soft);
    }
  }
}
.mine-pill {
  position: absolute;
  top: 1.1em;
  right: 1.1em;
}
/* keep the provider name / logo clear of the "Your plan" pill (a long name ran under it) */
.is-mine .insurance-identity :deep(.insurance-icon) {
  box-sizing: border-box;
  padding-right: 4.8em;
}

/* provider: compact and left aligned (logos keep their aspect inside a fixed box) */
.insurance-identity {
  width: 100%;
  height: auto !important;
  min-height: 3.4em;
  justify-content: flex-start !important;
  gap: 0.25em !important;
  // one height for every card in the row: two lines of a text name (2 x 1.35em x 1.15), logos centred in it.
  // It was 2.4em, so a two-line provider name was centred in a box shorter than itself and clipped top and bottom.
  :deep(.insurance-icon) {
    flex: 0 0 auto;
    height: 3.1em;
    object-position: left center;
  }
  :deep(.insurance-name) {
    justify-content: flex-start !important;
    font-size: 1.35em !important;
    text-align: left !important;
  }
  // text name: at most two lines, then an ellipsis (never cut mid-glyph)
  :deep(.insurance-icon.is-text .insurance-name) {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    height: auto;
    max-height: 100%;
    overflow: hidden;
    align-self: center;
  }
  :deep(.insurance-icon.is-text) {
    display: flex;
    align-items: center;
  }
  :deep(.insurance-slogan) {
    text-align: left !important;
  }
}

.premium {
  display: grid;
  gap: 0.2em;
  padding-top: 0.9em;
  border-top: 1px solid var(--line);
}
.premium-value {
  color: var(--money);
  font-size: 1.9em;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
  --units-icon-color: var(--money);
  :deep(.info-item),
  :deep(.value-label),
  :deep(.unit) {
    color: var(--money);
    font-size: inherit;
    font-weight: 800;
  }
}

.facts {
  grid-template-columns: auto auto minmax(0, 1fr);
  column-gap: 1.4em;
  .fact.money {
    justify-items: end;
    text-align: right;
  }
}
.fact-value {
  font-variant-numeric: tabular-nums;
}

.perks {
  flex: 1 1 auto;
  min-height: 6.4em;
  padding-top: 0.9em;
  border-top: 1px solid var(--line);
}

.discount {
  display: grid;
  gap: 0.4em;
  min-height: 2.6em;
  align-content: center;
  .hint {
    margin: 0;
    line-height: 1.35;
  }
}
.discount-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: var(--space-3);
}
.discount-name {
  font-weight: 800;
}
.discount-savings {
  display: inline-flex;
  align-items: baseline;
  gap: 0.25em;
  color: var(--ok-ink);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.buttons {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--space-2);
  > * {
    width: 100%;
  }
}
</style>
