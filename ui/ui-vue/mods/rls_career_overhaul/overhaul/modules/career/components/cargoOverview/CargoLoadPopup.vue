<template>
  <div v-bng-scoped-nav="popupScopeBinding" class="rls-house discard-popup">
    <!-- Throwing away is one quantity choice, laid out like the house confirmation popup -->
    <div class="modal discard-card">
      <h3>{{ discardTitle }}</h3>
      <CargoDiscardGroups v-if="discardGroups?.length > 1" :groups="discardGroups" v-model="discardAmounts" />
      <div v-else-if="cargo && cargo.throwAwayInfo && totalAvailableAmount" class="amount-controls">
        <HouseButton class="less" compact variant="quiet" :icon="icons.minus" aria-label="Less" @click="less()" />
        <HouseSlider class="slider" :min="0" :max="totalAvailableAmount" :step="1" v-model="throwAwayValue" />
        <HouseButton class="more" compact variant="quiet" :icon="icons.plus" aria-label="More" @click="more()" />
        <div class="amount">
          <strong>{{ throwAwayValue }}</strong><span> / {{ totalAvailableAmount }}</span>
        </div>
      </div>
      <p v-if="discardError" role="alert">{{ discardError }}</p>
      <div class="actions">
        <HouseButton
          variant="quiet"
          binding="back"
          v-bng-on-ui-nav:back,menu.asMouse
          bng-scoped-nav-autofocus
          @click="cancelClickHandler">
          {{ $t("ui.common.cancel") }}
        </HouseButton>
        <HouseButton v-if="cargo && cargo.throwAwayInfo" variant="danger" :disabled="discardBusy || !discardAmount" @click="acceptClickHandler">
          {{ $t("ui.career.cargoCard.throwAway") }}
          <BngUnit :money="-discardPenalty" />
        </HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { BngUnit, icons } from "@/common/components/base"
import { computed, onMounted, ref, useAttrs } from "vue"
import { useBridge } from "@/bridge"
import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
import { useCargoOverviewStore } from "../../stores/cargoOverviewStore"
import HouseButton from "../house/HouseButton.vue"
import HouseSlider from "../house/HouseSlider.vue"
import CargoDiscardGroups from "./CargoDiscardGroups.vue"

const cargoOverviewStore = useCargoOverviewStore()
const { lua } = useBridge()

const emit = defineEmits(["return"])

const props = defineProps({
  cargo: Object,
  discardGroups: Array,
  discardHandler: Function,
  popupActive: Boolean,
})

const attrs = useAttrs()
const scopeName = `_cargoLoadPopup__${attrs.__id}`
const popupScopeBinding = computed(() => ({
  scopeId: scopeName,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  // Cancel is the initial target; preserve the last row after updates.
  preferAutoFocus: false,
  trapPolicy: "always",
}))

const throwAwayValue = ref(0)
const discardAmounts = ref({})
const discardBusy = ref(false)
const discardError = ref("")
const discardAmount = computed(() => props.discardGroups?.length > 1
  ? props.discardGroups.reduce((sum, group) => sum + (discardAmounts.value[group.id] || 0), 0) : throwAwayValue.value)
const discardPenalty = computed(() => props.discardGroups?.length > 1
  ? props.discardGroups.reduce((sum, group) => sum + (discardAmounts.value[group.id] || 0) * group.penalty, 0)
  : (props.cargo?.throwAwayInfo?.penalty || 0) * throwAwayValue.value)

const loadingName = ref("")
const discardTitle = computed(() => props.discardGroups?.length > 1
  ? "Throw away cargo" : `Throw away ${loadingName.value.toLocaleLowerCase()}`)
const totalAvailableAmount = ref(0)
const less = () => { throwAwayValue.value = Math.max(0, throwAwayValue.value - 1) }
const more = () => { throwAwayValue.value = Math.min(totalAvailableAmount.value, throwAwayValue.value + 1) }

const acceptClickHandler = async () => {
  if (props.discardHandler) {
    if (discardBusy.value || !discardAmount.value) return
    discardBusy.value = true
    try {
      const selections = props.discardGroups.map(group => ({ id: group.id,
        amount: props.discardGroups.length > 1 ? discardAmounts.value[group.id] || 0 : throwAwayValue.value }))
      const result = await props.discardHandler(selections)
      if (result?.ok) emit("return", true)
      else discardError.value = result?.message || "Unable to discard this cargo. Reopen the picker to refresh the load."
    } catch {
      discardError.value = "Unable to discard this cargo. Reopen the picker to refresh the load."
    } finally { discardBusy.value = false }
    return
  }
  let loadIdx = 0
  if (props.cargo) {
    for (const id of props.cargo.ids) lua.overhaul_career_logistics_cargoScreen.clearTransientMoveForCargo(id)
  }

  if (props.cargo && props.cargo.throwAwayInfo) {
    const discardEnd = Math.min(loadIdx + throwAwayValue.value, props.cargo.ids.length)
    for (; loadIdx < discardEnd; loadIdx++) {
      const id = props.cargo.ids[loadIdx]
      cargoOverviewStore.requestMoveCargoToLocation(id, props.cargo.throwAwayInfo, true)
    }
    lua.overhaul_career_logistics_cargoScreen.applyTransientMoves()
  }

  cargoOverviewStore.requestCargoDataSimple()

  emit("return", true)
}

const cancelClickHandler = () => {
  if (!discardBusy.value) emit("return", false)
}

const start = () => {
  loadingName.value = props.cargo?.name || "cargo"
  totalAvailableAmount.value = props.discardGroups?.length === 1
    ? props.discardGroups[0].amount : props.cargo?.ids?.length || 0
  throwAwayValue.value = totalAvailableAmount.value
}

onMounted(start)
</script>

<script>
import { popupPosition, popupContainer } from "@/services/popup"
export default {
  wrapper: {
    fade: true, // everything but popup will fade away (become semi-transparent and desaturated)
    blur: true, // fullscreen in-game blur
    style: popupContainer.default, // can be multiple in array
  },
  position: [popupPosition.center, popupPosition.center], // can be single w/o array
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Discard popup: house confirmation card (HouseConfirm) with the drop-off amount row (CargoDropOff)
.discard-popup {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.discard-card {
  width: min(24em, 92vw);
  gap: var(--space-3);
  padding: 1.1em 1.1em 1em;
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
}
.amount-controls {
  display: flex;
  align-items: center;
  gap: 0.4em;
  .slider {
    flex: 1 1 auto;
    min-width: 0;
  }
  .amount {
    flex: 0 0 auto;
    min-width: 4.5em;
    text-align: right;
    font-variant-numeric: tabular-nums;
    strong {
      font-size: 1.15em;
      font-weight: 800;
    }
    span {
      color: var(--faint);
      font-weight: 700;
    }
  }
}
.actions {
  display: flex;
  justify-content: flex-end;
  gap: var(--space-2);
  margin-top: var(--space-1);
  > :deep(.house-button) {
    min-width: 6.5em;
  }
  // Size the penalty like MoneyAmount: inline with the label, glyph at text size
  :deep(.info-item) {
    padding: 0;
    gap: 0.18em;
    line-height: 1;
    .icon {
      font-size: 1em;
    }
    .value-label {
      line-height: 1;
    }
  }
}

</style>
