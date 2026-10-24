<template>
  <div class="popup-content rls-house ins-pop" v-bng-scoped-nav="popupScopeBinding" v-bng-on-ui-nav:back,menu="closePopup">
    <div class="popup-header pop-head">
      <div class="top-info head-copy" title="Pick a vehicle to adjust its deductible">
        <span class="caption">Insured vehicles</span>
        <h2 class="pop-title">{{ $translate.instant(props.insuranceData.name) }}</h2>
        <div class="pop-sub">
          Total value <BngUnit class="money-value" :money="props.insuranceData.totalInsuranceVehsValue" />
        </div>
      </div>

      <HouseButton
        class="policy-coverage-button"
        compact
        :icon="icons.adjust"
        @click="openEditPolicy"
      >
        Policy coverage
      </HouseButton>
    </div>

    <div class="vehicle-list scroll" v-bng-ui-nav-scroll>
      <InsuranceVehTile
        v-for="(vehicle, index) in props.insuranceData.carsInsured"
        :key="index"
        :vehicle="vehicle"
      >
        <template #rightContent>
          <HouseButton
            class="edit-coverage-button"
            compact
            :disabled="vehicle.needsRepair"
            :title="vehicle.needsRepair ? 'Repair this vehicle before changing its coverage' : null"
            @click="!vehicle.needsRepair && openEditVehicleCoverage(vehicle)"
          >
            {{ vehicle.needsRepair ? 'Needs repair' : 'Edit coverage' }}
          </HouseButton>
        </template>
      </InsuranceVehTile>
    </div>

    <div class="closeButton pop-foot">
      <HouseButton class="close-button" variant="quiet" @click="closePopup">
        Close
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { computed, useAttrs } from "vue"
import { BngUnit, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import EditVehicleCoverage from "./editVehicleCoverage.vue"
import InsuranceVehTile from "./insuranceVehTile.vue"
import EditPolicy from "./editPolicy.vue"
import { addPopup } from "@/services/popup"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import "./insuranceStyle.css"

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

const emit = defineEmits(["return"])

const attrs = useAttrs()
const scopeName = `_vehicleInsuranceListPopup__${attrs.__id}`
const popupScopeBinding = computed(() => ({
  scopeId: scopeName,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const closePopup = () => {
  emit("return", true)
}

const openEditVehicleCoverage = async vehicle => {
  const result = await addPopup(EditVehicleCoverage, { insuranceData: props.insuranceData, vehicleData: vehicle }).promise.catch(() => null)
  if (result === "navigated") closePopup()
}

const openEditPolicy = () => {
  addPopup(EditPolicy, { insuranceData: props.insuranceData, driverScoreData: props.driverScoreData })
  closePopup()
}

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house popup: policy name as the title, fleet value in gold, one row per vehicle with its
   own compact action. Nothing here is the "buy" step, so no orange. */
.ins-pop {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  width: min(34em, 94vw);
  max-height: min(86vh, calc(100vh - 4rem));
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
  align-items: baseline;
  gap: 0.4em;
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 600;
}
.money-value {
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.vehicle-list {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: var(--space-1);
  overflow-y: auto;
  overflow-x: hidden;
  overscroll-behavior: contain;
  /* the stable scrollbar gutter sits in the popup's right padding */
  margin-right: -0.55em;
  padding-right: 0.05em;
}

.edit-coverage-button {
  min-width: 8.5em;
}

.pop-foot {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-end;
  > :deep(.house-button) {
    min-width: 7em;
  }
}
</style>
