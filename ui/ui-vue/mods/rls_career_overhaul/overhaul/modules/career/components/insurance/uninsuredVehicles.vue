<template>
  <div v-bng-scoped-nav="popupScopeBinding" v-bng-on-ui-nav:back,menu="closePopup" class="popup-content rls-house ins-pop">
    <div class="popup-header pop-head">
      <div class="head-copy" title="These vehicles have no insurance coverage. Add coverage to protect against repair costs.">
        <h2 class="pop-title header-title">Uninsured vehicles</h2>
        <span class="pop-sub">You pay full repair costs on these</span>
      </div>
    </div>

    <div v-if="props.uninsuredData.carsUninsured && props.uninsuredData.carsUninsured.length > 0" class="vehicle-list scroll" v-bng-ui-nav-scroll>
      <InsuranceVehTile
        v-for="(vehicle, index) in props.uninsuredData.carsUninsured"
        :key="index"
        :vehicle="vehicle"
        class="uninsured-vehicle-item"
      >
        <template #extra-info>
          <div class="no-coverage-warning">
            No coverage
          </div>
        </template>
        <template #rightContent>
          <HouseButton
            class="add-coverage-button"
            compact
            :icon="icons.shieldCheckmark"
            :disabled="vehicle.needsRepair"
            @click="!vehicle.needsRepair && openAddCoverage(vehicle)"
          >
            {{ vehicle.needsRepair ? $t("ui.career.insurance.uninsured.addCoverageNeedsRepair") : $t("ui.career.insurance.uninsured.addCoverage") }}
          </HouseButton>
        </template>
      </InsuranceVehTile>
    </div>

    <div v-else class="no-vehicles-wrapper">
      <BngIcon class="success-icon" :type="icons.checkmark" />
      <div class="success-title">All vehicles insured</div>
      <div class="success-message">You don't have any uninsured vehicles.</div>
    </div>

    <div class="closeButton pop-foot">
      <HouseButton class="close-button" variant="quiet" @click="closePopup">
        Back
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { computed, useAttrs } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import InsuranceVehTile from "./insuranceVehTile.vue"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import { lua } from "@/bridge"

const props = defineProps({
  uninsuredData: {
    type: Object,
    required: true,
  },
  popupActive: Boolean,
})

const attrs = useAttrs()
const scopeName = `_uninsuredVehicles__${attrs.__id}`
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

const openAddCoverage = async vehicle => {
  const nav = await lua.overhaul_career_repair_insurance.openChooseInsuranceScreen("change", { vehicleId: vehicle.id })
  if (nav?.success) closePopup()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house popup: plain near-black rows (no red cards); the only red is the short "No coverage"
   line, because that is the thing that is wrong. */
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
}
.pop-sub {
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 600;
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
  margin-right: -0.55em;
  padding-right: 0.05em;
}

.no-coverage-warning {
  color: var(--bad);
  font-size: 0.82em;
  font-weight: 700;
  line-height: 1.2;
}

.add-coverage-button {
  min-width: 9em;
}

.no-vehicles-wrapper {
  display: grid;
  justify-items: center;
  gap: var(--space-2);
  padding: 1.8em 1em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  text-align: center;
}
.success-icon {
  --bng-icon-size: 2.2em;
  --bng-icon-color: var(--ok-ink);
}
.success-title {
  font-size: 1.1em;
  font-weight: 800;
}
.success-message {
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 600;
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
