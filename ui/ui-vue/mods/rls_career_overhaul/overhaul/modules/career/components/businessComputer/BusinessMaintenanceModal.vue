<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Business computer: vehicle maintenance popup, house .modal look. Caption + vehicle name, then a
     caption per system over a sheet of lines (name, faint health, colour only when low). Check is quiet,
     service / replace are neutral with the price in gold; the only orange is Buy and Install. -->
<template>
  <Teleport to="body">
    <transition name="modal-fade">
      <div
        v-if="open"
        class="maintenance-overlay rls-house"
        @click.self.stop="close"
        @mousedown.self.stop
      >
        <div class="modal maintenance-modal" ref="modalRef" v-bng-scoped-nav="modalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="onBack">
          <div class="modal-head">
            <span class="caption">Vehicle maintenance</span>
            <h3>{{ vehicleTitle }}</h3>
          </div>
          <div v-if="errorMessage" class="notice bad">{{ errorMessage }}</div>
          <!-- refreshes after Check/Service keep the list mounted so controller focus is not dropped -->
          <p v-else-if="loading && !uiData" class="hint">Loading maintenance data…</p>
          <div v-else class="maintenance-content scroll" v-bng-ui-nav-scroll>
            <section v-for="category in categories" :key="category.name" class="category">
              <h4 class="caption category-title">{{ category.label }}</h4>
              <div class="sheet">
                <div class="lines">
                  <div
                    v-for="row in category.rows || []"
                    :key="`${row.category}:${row.item}`"
                    class="line row-line"
                  >
                    <div class="row-copy-block">
                      <strong>{{ row.label }}</strong>
                      <span v-if="row.isRevealed" :class="healthTone(row.revealedPercent)">{{ row.revealedPercent }}% health</span>
                      <span v-else>Unknown condition</span>
                    </div>
                    <div class="row-actions">
                      <HouseButton
                        compact
                        variant="quiet"
                        :data-nav-key="busyKey(row, 'check')"
                        :disabled="isBusy(row, 'check')"
                        @click.stop="runCheck(row)"
                        @mousedown.stop
                      >
                        Check
                      </HouseButton>
                      <HouseButton
                        compact
                        :data-nav-key="busyKey(row, 'service')"
                        :disabled="!row.canAffordService || isBusy(row, 'service')"
                        @click.stop="runService(row)"
                        @mousedown.stop
                      >
                        {{ row.actionLabel }} <span class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(row.servicePrice) }}</span>
                      </HouseButton>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <section class="category tire-category">
              <h4 class="caption category-title">Tires</h4>
              <p v-if="tireShop?.provider" class="hint">
                Using {{ tireShop.provider.name }} {{ tireShop.provider.version || "" }}
              </p>
              <p v-if="!tireShop?.available" class="hint">
                {{ tireShop?.message || "Tire service is unavailable." }}
              </p>
              <template v-else-if="!tireShop.inspected">
                <div class="sheet">
                  <div class="lines">
                    <div class="line row-line">
                      <div class="row-copy-block">
                        <strong>Tread and pressure</strong>
                        <span>Tire condition has not been inspected.</span>
                      </div>
                      <HouseButton
                        compact
                        data-nav-key="tires:check"
                        :disabled="busyActionKey === 'tires:check'"
                        @click.stop="runTireCheck"
                        @mousedown.stop
                      >Check All Tires <span class="free">Free</span></HouseButton>
                    </div>
                  </div>
                </div>
              </template>
              <template v-else>
                <div class="sheet">
                  <div class="lines">
                    <div v-for="axle in tireShop.axles || []" :key="axle.id" class="line row-line">
                      <div class="row-copy-block">
                        <strong>{{ axle.label }}: {{ axle.tireName }}</strong>
                        <span>
                          <span :class="{ 'tire-flat': axle.flat }">{{ axle.flat ? "Flat/popped" : `${axle.remainingPercent}% tread` }}</span>,
                          <span class="price-inline"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(axle.perTirePrice) }}</span> each
                        </span>
                        <span class="wheels">
                          <span
                            v-for="wheel in axle.wheelStates || []"
                            :key="wheel.name"
                            class="pill"
                            :class="wheel.flat ? 'bad' : healthTone(wheel.remainingPercent)">
                            {{ wheel.name }} {{ wheel.flat ? "Flat" : `${wheel.remainingPercent}%` }}
                          </span>
                        </span>
                      </div>
                      <HouseButton
                        compact
                        :data-nav-key="`tires:replace:${axle.id}`"
                        :disabled="Boolean(pendingTireAxles.length)"
                        @click.stop="beginTireCheckout([axle.id])"
                        @mousedown.stop
                      >Replace <span class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(axle.subtotal) }}</span></HouseButton>
                    </div>
                  </div>
                </div>
                <div class="tire-replace-all">
                  <HouseButton
                    compact
                    data-nav-key="tires:replace:all"
                    :disabled="Boolean(pendingTireAxles.length)"
                    @click.stop="beginTireCheckout((tireShop.axles || []).map(axle => axle.id))"
                    @mousedown.stop
                  >Replace All <span class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(tireShop.replaceAllSubtotal) }}</span></HouseButton>
                </div>
              </template>

              <div v-if="pendingTireAxles.length" class="tire-confirm">
                <span class="caption">Confirm fresh tire purchase</span>
                <div class="lines">
                  <div v-for="axle in selectedTireGroups" :key="axle.id" class="line">
                    <span>{{ axle.label }}</span>
                    <span class="price-inline"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(axle.subtotal) }}</span>
                  </div>
                  <div class="line total-line">
                    <strong>Total</strong>
                    <strong class="price-inline"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(selectedTireTotal) }}</strong>
                  </div>
                </div>
                <div class="tire-confirm-actions">
                  <HouseButton variant="quiet" @click.stop="cancelTireCheckout" @mousedown.stop>Cancel</HouseButton>
                  <HouseButton
                    variant="primary"
                    data-nav-key="tires:buy"
                    :disabled="busyActionKey === 'tires:checkout'"
                    @click.stop="confirmTireCheckout"
                    @mousedown.stop
                  >Buy and Install</HouseButton>
                </div>
              </div>
            </section>
          </div>
          <div class="modal-buttons">
            <HouseButton @click.stop="close" @mousedown.stop>
              Close
            </HouseButton>
          </div>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { formatMoney as formatAmount } from "../../utils/units.js"
import { ref, computed, watch } from "vue"
import { useBusinessVehiclesStore } from "../../stores/businessComputer/businessVehiclesStore.js"
import { HouseButton } from "../house/index.js"
import { BngIcon, icons } from "@/common/components/base"
import { vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { refocusIfLost } from "../../composables/useScreenEntryFocus"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"

const props = defineProps({
  open: { type: Boolean, default: false },
  vehicle: { type: Object, default: null },
})

const emit = defineEmits(["update:open", "close"])

const vehiclesStore = useBusinessVehiclesStore()
const modalRef = ref(null)
const modalScope = bcModalScope("maintenance")

// Controller: a button that disables itself while busy (Check, Service, Replace) drops focus; put it back on
// the same button (by data-nav-key) or, failing that, the first live button in the list.
const refocusKey = (key) => refocusIfLost(() =>
  modalRef.value?.querySelector(`[data-nav-key="${key}"]:not(:disabled)`)
  || modalRef.value?.querySelector(".maintenance-content button:not(:disabled)")
  || modalRef.value?.querySelector(".modal-buttons button"))

// B: an open tire purchase confirm closes first, then the popup
const onBack = () => {
  if (pendingTireAxles.value.length) cancelTireCheckout()
  else close()
  return false
}
const loading = ref(false)
const errorMessage = ref("")
const uiData = ref(null)
const busyActionKey = ref("")
const pendingTireAxles = ref([])

// number only: the template puts the game currency glyph in front

const vehicleTitle = computed(() => {
  const v = props.vehicle
  if (!v) return "Vehicle"
  return v.vehicleName || v.name || `Vehicle #${v.vehicleId ?? v.id ?? ""}`
})

const categories = computed(() => uiData.value?.categories || [])
const tireShop = computed(() => uiData.value?.tireShop || null)
const selectedTireGroups = computed(() => {
  const selected = new Set(pendingTireAxles.value)
  return (tireShop.value?.axles || []).filter(axle => selected.has(axle.id))
})
const selectedTireTotal = computed(() =>
  selectedTireGroups.value.reduce((total, axle) => total + (Number(axle.subtotal) || 0), 0)
)

const formatMoney = (value) => {
  const n = Number(value)
  return formatAmount(Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0, { decimals: 0, locale: "en-US" })
}

// health text / pill tone: colour only when low (display only)
const healthTone = (percent) => {
  const n = Number(percent)
  if (!Number.isFinite(n)) return null
  if (n <= 25) return "bad"
  if (n <= 50) return "warn"
  return null
}

const busyKey = (row, action) => `${row?.category || ""}:${row?.item || ""}:${action}`
const isBusy = (row, action) => busyActionKey.value === busyKey(row, action)

const loadData = async () => {
  const vehicle = props.vehicle
  if (!vehicle) {
    errorMessage.value = "No vehicle selected."
    uiData.value = null
    return
  }
  loading.value = true
  errorMessage.value = ""
  try {
    const result = await vehiclesStore.getBusinessMaintenanceUiData(vehicle.vehicleId)
    if (!result?.enabled) {
      errorMessage.value = result?.errorMessage || "Maintenance is unavailable for this vehicle."
      uiData.value = null
      return
    }
    uiData.value = result
  } catch {
    errorMessage.value = "Failed to load maintenance data."
    uiData.value = null
  } finally {
    loading.value = false
  }
}

const runCheck = async (row) => {
  const v = props.vehicle
  if (!v || !row) return
  busyActionKey.value = busyKey(row, "check")
  try {
    const result = await vehiclesStore.startBusinessMaintenanceCheck(v.vehicleId, row.category, row.item)
    if (result?.ok) {
      await loadData()
    }
  } finally {
    busyActionKey.value = ""
    refocusKey(busyKey(row, "check"))
  }
}

const runService = async (row) => {
  const v = props.vehicle
  if (!v || !row) return
  busyActionKey.value = busyKey(row, "service")
  try {
    const result = await vehiclesStore.startBusinessMaintenanceService(v.vehicleId, row.category, row.item)
    if (result?.ok) {
      await loadData()
    }
  } finally {
    busyActionKey.value = ""
    refocusKey(busyKey(row, "service"))
  }
}

const runTireCheck = async () => {
  const v = props.vehicle
  if (!v) return
  busyActionKey.value = "tires:check"
  try {
    const result = await vehiclesStore.inspectBusinessVehicleTires(v.vehicleId)
    if (result?.ok) await loadData()
  } finally {
    busyActionKey.value = ""
    refocusKey("tires:replace:all")
  }
}

const beginTireCheckout = axleIds => {
  pendingTireAxles.value = [...axleIds]
  refocusKey("tires:buy")
}

const cancelTireCheckout = () => {
  const first = pendingTireAxles.value.length === 1 ? pendingTireAxles.value[0] : "all"
  pendingTireAxles.value = []
  refocusKey(`tires:replace:${first}`)
}

const confirmTireCheckout = async () => {
  const v = props.vehicle
  if (!v) return
  busyActionKey.value = "tires:checkout"
  try {
    const result = await vehiclesStore.checkoutBusinessVehicleTires(
      v.vehicleId, pendingTireAxles.value, tireShop.value?.quoteRevision
    )
    if (result?.ok) {
      pendingTireAxles.value = []
      await loadData()
    } else if (result?.staleQuote) {
      await loadData()
    }
  } finally {
    busyActionKey.value = ""
    refocusKey("tires:buy")
  }
}

const close = () => {
  emit("update:open", false)
  emit("close")
}

watch(
  () => props.open,
  async (isOpen) => {
    if (isOpen) {
      await loadData()
    } else {
      uiData.value = null
      errorMessage.value = ""
      busyActionKey.value = ""
      pendingTireAxles.value = []
    }
  }
)

watch(
  () => props.vehicle?.vehicleId,
  async () => {
    if (props.open) {
      await loadData()
    }
  }
)

defineExpose({ reload: loadData })
</script>


<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.maintenance-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.maintenance-modal {
  width: min(46em, 100%);
  max-height: 88vh;
  grid-template-rows: auto auto minmax(0, 1fr) auto;
  gap: var(--space-4);
  padding: 1.1em 1.1em 1em;
}
.modal-head {
  display: grid;
  gap: 0.25em;
  h3 {
    font-size: 1.3em;
    line-height: 1.2;
    overflow-wrap: anywhere;
  }
}

.maintenance-content {
  display: flex;
  flex-direction: column;
  gap: 1em;
  min-height: 0;
  max-height: 58vh;
  padding-right: 0.3em;
}

.category {
  display: grid;
  gap: 0.45em;
}
.category-title {
  margin: 0;
}

.row-line {
  gap: 1em;
}
.row-copy-block {
  display: grid;
  gap: 0.2em;
  min-width: 0;

  strong {
    font-weight: 700;
    line-height: 1.2;
    overflow-wrap: anywhere;
  }
  > span {
    color: var(--faint);
    font-size: 0.8em;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
  .warn {
    color: var(--warn);
  }
  .bad {
    color: var(--bad);
  }
}
.row-actions {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.35em;
}

.price {
  margin-left: 0.35em;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
.price-inline {
  color: var(--money);
  font-variant-numeric: tabular-nums;
}
.free {
  margin-left: 0.35em;
  color: var(--faint);
}

.row-copy-block > .wheels {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
  margin-top: 0.15em;
  font-size: 1em;
}

.tire-flat {
  color: var(--bad);
}

.tire-replace-all {
  display: flex;
  justify-content: flex-end;
}

.tire-confirm {
  display: grid;
  gap: 0.45em;
  padding: 0.75em var(--inset) var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel-2);

  .line {
    padding-left: 0;
    padding-right: 0;
  }
  .total-line {
    font-size: 1.05em;
  }
}
.tire-confirm-actions {
  display: flex;
  justify-content: space-between;
  gap: var(--space-2);
}

.modal-buttons {
  display: flex;
  justify-content: flex-end;
  gap: var(--space-2);
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;

  .maintenance-modal {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .maintenance-modal {
    transform: scale(0.97);
    opacity: 0;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
