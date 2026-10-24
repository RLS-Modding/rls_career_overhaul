<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <EntryOverlayPopup :active="visible" :can-cancel="!busy" @cancel="close" @leave="leaveRepair">
    <Transition name="roadside-repair">
      <div
        v-if="visible"
        class="rls-house roadside-repair-root"
        role="dialog"
        aria-modal="true"
        aria-label="Roadside repair"
      >
        <div class="roadside-repair-backdrop" @click="close" />
        <aside class="modal roadside-repair-panel">
          <div class="rr-head">
            <span class="caption">Vehicle</span>
            <strong class="rr-vehicle">{{ vehicleName }}</strong>
          </div>
          <p class="rr-blurb">Instantly repair your vehicle on the go.</p>

          <div class="rr-options">
            <button
              type="button"
              class="rr-option"
              bng-nav-item
              :bng-no-nav="!privateOption?.canPay ? 'true' : null"
              :bng-scoped-nav-autofocus="autofocusKey === 'private' ? '' : null"
              :class="{ off: !privateOption?.canPay }"
              :disabled="!privateOption?.canPay || busy"
              @click="choosePrivate"
            >
              <span class="rr-option-copy">
                <strong class="rr-option-name">Private pay</strong>
                <span v-if="!privateOption?.canPay" class="rr-short">Not enough money</span>
              </span>
              <strong class="rr-price" :class="{ short: !privateOption?.canPay }"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(privateOption?.price) }}</strong>
            </button>

            <button
              v-if="insuranceOption"
              type="button"
              class="rr-option"
              bng-nav-item
              :bng-no-nav="!insuranceOption.canPay ? 'true' : null"
              :bng-scoped-nav-autofocus="autofocusKey === 'insurance' ? '' : null"
              :class="{ off: !insuranceOption.canPay }"
              :disabled="!insuranceOption.canPay || busy"
              @click="chooseInsurance"
            >
              <span class="rr-option-copy">
                <strong class="rr-option-name">Insurance Claim</strong>
                <span v-if="!insuranceOption.canPay" class="rr-short">Not enough money</span>
              </span>
              <strong class="rr-price" :class="{ short: !insuranceOption.canPay }"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(insuranceOption.price) }}</strong>
            </button>
          </div>

          <div class="rr-actions">
            <HouseButton
              variant="quiet"
              binding="back"
              :disabled="busy"
              :bng-scoped-nav-autofocus="autofocusKey === 'cancel' ? '' : null"
              @click="close">
              Cancel
            </HouseButton>
          </div>
        </aside>
      </div>
    </Transition>
  </EntryOverlayPopup>
</template>

<script setup>
import EntryOverlayPopup from "./EntryOverlayPopup.vue"
import { computed, onBeforeUnmount, onMounted, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import HouseButton from "./house/HouseButton.vue"
import { useAppLayoutsStore } from "@/modules/apps/appLayoutsStore"

const bridge = useBridge()
const appLayouts = useAppLayoutsStore()
const visible = ref(false)
const busy = ref(false)
const vehicleName = ref("")
const invVehId = ref(null)
const privateOption = ref(null)
const insuranceOption = ref(null)
let weHidHudApps = false

// game currency: the template puts the glyph in front, beamBucks formats in the player's locale
const formatMoney = amount => {
  const n = Number(amount)
  return bridge.units.beamBucks(Number.isFinite(n) ? n : 0)
}

const normalizePayload = raw => {
  if (Array.isArray(raw)) {
    raw = raw.find(entry => entry && typeof entry === "object") || raw[0]
  }
  if (!raw || typeof raw !== "object") return null
  return raw
}

const hideHudApps = () => {
  if (weHidHudApps) return
  appLayouts.setVisible(false)
  weHidHudApps = true
}

const restoreHudApps = () => {
  if (!weHidHudApps) return
  appLayouts.setVisible(true)
  weHidHudApps = false
}

const reset = () => {
  visible.value = false
  busy.value = false
  vehicleName.value = ""
  invVehId.value = null
  privateOption.value = null
  insuranceOption.value = null
  restoreHudApps()
}

const onPopup = (...args) => {
  const data = normalizePayload(args.length > 0 ? args[0] : null)
  if (!data || data.visible === false) {
    reset()
    return
  }

  vehicleName.value = String(data.vehicleName || "Vehicle")
  invVehId.value = data.invVehId ?? null
  privateOption.value = data.private || null
  insuranceOption.value = data.insurance || null
  busy.value = false
  hideHudApps()
  visible.value = true
}

const leaveRepair = () => {
  busy.value = false
  close()
}

const close = () => {
  if (busy.value) return
  reset()
  lua.overhaul_career_repair_repairScreen.closeRoadsidePopup()
}

const startRepair = async (isInsuranceRepair, option) => {
  if (!option || !option.canPay || invVehId.value == null || busy.value) return
  busy.value = true
  try {
    await lua.overhaul_career_repair_repairScreen.startRepairInGarage(invVehId.value, {
      repairOptionKey: isInsuranceRepair ? "insuranceRepairData" : "noInsuranceRepairData",
      repairTimeOptionId: option.repairTimeOptionId,
      quotedPrice: Number(option.price),
    })
  } finally {
    busy.value = false
  }
}

// Default focus: the first option you can pay for (private first, as listed), else Cancel.
const autofocusKey = computed(() => {
  if (privateOption.value?.canPay) return "private"
  if (insuranceOption.value?.canPay) return "insurance"
  return "cancel"
})
// trapPolicy always: while it is up, presses never fall through to the game behind it. No fixed
// scopeId: a quick close + reopen mounts the new root while the old one is still fading out.
const choosePrivate = () => startRepair(false, privateOption.value)
const chooseInsurance = () => startRepair(true, insuranceOption.value)

onMounted(() => {
  bridge.events.on("roadsideRepairPopup", onPopup)
})

onBeforeUnmount(() => {
  bridge.events.off("roadsideRepairPopup", onPopup)
  reset()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.roadside-repair-root {
  position: fixed;
  inset: 0;
  z-index: 13500;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: max(1.5em, env(safe-area-inset-top)) max(1.5em, env(safe-area-inset-right))
    max(1.5em, env(safe-area-inset-bottom)) max(1.5em, env(safe-area-inset-left));
  pointer-events: auto;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.roadside-repair-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.55);
}

.roadside-repair-panel {
  position: relative;
  z-index: 1;
  width: min(24em, calc(100vw - 3em));
  gap: 0.8em;
  padding: 1em 1em 0.9em;
  // Solid fill: the entry prompt sits right behind this dialog and any see-through
  // fill lets its text show inside the option rows.
  background: var(--page);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  color: #fff;
  outline: none;
}

.rr-head {
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.rr-vehicle {
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.15;
}
.modal p.rr-blurb {
  color: var(--faint);
  font-size: 0.88em;
}

.rr-options {
  display: grid;
  gap: 0.45em;
}
.rr-option {
  appearance: none;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.9em;
  width: 100%;
  margin: 0;
  padding: 0.8em 0.9em 0.7em;
  border: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s;
  &:hover:not(:disabled) { background: var(--panel-2); }
  @include house-focus;
  &:disabled { cursor: default; }
  &:disabled:not(.off) { opacity: 0.6; } // busy: the repair is already on its way
  &.off .rr-option-name { color: var(--faint); }
}
.rr-option-copy {
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.rr-option-name {
  font-size: 1.05em;
  font-weight: 700;
  line-height: 1.2;
}
.rr-short {
  color: var(--bad);
  font-size: 0.8em;
  font-weight: 600;
}
.rr-price {
  flex: 0 0 auto;
  color: var(--money);
  font-size: 1.1em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  &.short { color: var(--bad); }
  .cur {
    margin-right: 0.1em;
    transform: translateY(0.08em);
  }
}

.rr-actions {
  display: flex;
  justify-content: flex-start;
}

.roadside-repair-enter-active,
.roadside-repair-leave-active {
  transition: opacity 0.16s ease;
}

.roadside-repair-enter-active .roadside-repair-panel,
.roadside-repair-leave-active .roadside-repair-panel {
  transition: transform 0.16s ease, opacity 0.16s ease;
}

.roadside-repair-enter-from,
.roadside-repair-leave-to {
  opacity: 0;
}

.roadside-repair-enter-from .roadside-repair-panel,
.roadside-repair-leave-to .roadside-repair-panel {
  opacity: 0;
  transform: translateY(0.4em) scale(0.98);
}
</style>
