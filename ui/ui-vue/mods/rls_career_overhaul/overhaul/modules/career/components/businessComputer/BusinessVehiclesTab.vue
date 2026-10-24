<!-- Business computer Vehicles tab, house style. Title + faint hint, a neutral "Vehicle Shopping" for the
     racing team, then the Garage caption with a count and one row per fleet car like VehicleTileRow: big
     photo first, name biggest, class / power / year as faint spec lines, book value in gold with the
     estimated sale value faint, short status pills (Pulled out accent, Stored neutral, Cooling down warn)
     and a chevron. Expanded: a sheet of detail lines and HouseButtons with at most one primary. -->
<template>
  <div ref="rootRef" class="rls-house vehicles-tab">
    <header class="page-head">
      <div class="page-head__copy">
        <h2 class="page-title">Vehicles</h2>
        <p class="hint">
          {{
            sessionStore.hasCapability('fleetVehicles')
              ? "Garage vehicles and shopping"
              : "Garage inventory"
          }}
        </p>
      </div>
      <div
        v-if="sessionStore.hasCapability('fleetVehicles')"
        class="header-actions"
      >
        <HouseButton
          :icon="icons.shoppingCart"
          @click.stop="goTeamVehicleShop"
          @mousedown.stop
        >
          Vehicle Shopping
        </HouseButton>
      </div>
    </header>

    <section v-if="hasVehiclesTabContent" class="garage-section">
      <h3 class="caption section-caption">
        Garage
        <span class="pill">{{ fleetVehicles.length }}</span>
      </h3>
      <div class="vehicle-list">
        <article
          v-for="v in fleetVehicles"
          :key="`fleet-${v.vehicleId ?? v.id}`"
          class="vehicle-row"
          :class="{ expanded: isExpanded(v) }"
          v-bng-on-ui-nav:back.focusRequired="() => collapseRow(v)"
          @click.stop="interceptEvent"
          @mousedown.stop="interceptEvent"
        >
          <div
            class="vehicle-row__header"
            role="button"
            tabindex="0"
            bng-nav-item
            :data-veh-key="expandedKeyForVehicle(v)"
            :aria-expanded="isExpanded(v)"
            @click.stop="toggleExpanded(v)"
            @mousedown.stop
            @keydown.enter.prevent="toggleExpanded(v)"
            @keydown.space.prevent="toggleExpanded(v)"
          >
            <div class="veh-photo" :class="{ dim: isDeliveryPending(v) }">
              <img :src="fleetCardImage(v)" :alt="fleetCardName(v)" />
              <div v-if="isDeliveryPending(v)" class="photo-lock">
                <strong>{{ deliveryOverlayText(v) }}</strong>
              </div>
            </div>

            <div class="veh-info">
              <div class="veh-name" :title="fleetCardName(v)">{{ fleetCardName(v) }}</div>
              <div class="veh-specs">
                <span v-if="sessionStore.hasCapability('fleetVehicles') && fleetSanctionedClassDisplay(v)" class="spec">
                  {{ fleetSanctionedClassDisplay(v) }}
                </span>
                <span
                  v-if="sessionStore.hasCapability('fleetVehicles') && (fleetEffectiveHpDisplay(v) != null || fleetEffectivePwDisplay(v) != null)"
                  class="spec num"
                >
                  <template v-if="fleetEffectiveHpDisplay(v) != null">{{ fleetEffectiveHpDisplay(v) }}</template>
                  <template v-if="fleetEffectiveHpDisplay(v) != null && fleetEffectivePwDisplay(v) != null">, </template>
                  <template v-if="fleetEffectivePwDisplay(v) != null">{{ fleetEffectivePwDisplay(v) }} hp/kg</template>
                </span>
                <span v-if="v.vehicleYear && v.vehicleYear !== 'Unknown'" class="spec">
                  {{ v.vehicleYear }}{{ v.vehicleType && v.vehicleType !== 'Unknown' ? ` ${v.vehicleType}` : '' }}
                </span>
              </div>
            </div>

            <div class="veh-side">
              <span
                class="veh-value num"
                v-bng-tooltip:top="'Book value: recorded value for this vehicle on the business books.'"
              >
                <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(v.vehicleValue) }}
              </span>
              <span
                class="veh-value-note num"
                v-bng-tooltip:top="'Approximate payout if you sell this vehicle now.'"
              >
                Est. sale <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(v.sellValue) }}
              </span>
              <div class="veh-flags">
                <span v-if="isDeliveryPending(v)" class="pill">Delivering</span>
                <span v-else-if="isPulledOut(v)" class="pill accent">Pulled out</span>
                <span v-else class="pill">Stored</span>
                <span
                  v-if="!isDeliveryPending(v) && sessionStore.hasCapability('fleetVehicles') && fleetVehicleCooldownSec(v) > 0"
                  class="pill warn num"
                >
                  Cooling down {{ formatCooldownMSS(fleetVehicleCooldownSec(v)) }}
                </span>
                <span v-if="sessionStore.hasCapability('fleetVehicles') && v.fleetRepairNeeded" class="pill bad">Needs repair</span>
              </div>
            </div>

            <svg class="chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
          </div>

          <div v-if="isExpanded(v)" class="vehicle-row__expanded">
            <p v-if="isDeliveryPending(v)" class="notice">
              Vehicle is not selectable until delivery completes.
            </p>
            <p
              v-if="showLiftSlotsWarning(v)"
              class="notice warn"
            >
              {{ liftSlotsWarningText }}
            </p>
            <p
              v-else-if="!isDeliveryPending(v) && !isPulledOut(v)"
              class="hint expanded-hint"
            >
              Pull out vehicle to work on it
            </p>

            <div class="sheet lines detail-lines">
              <div v-if="sessionStore.hasCapability('fleetVehicles') && fleetSanctionedClassDisplay(v)" class="line">
                <span class="line-key">Class</span>
                <span class="line-value">{{ fleetSanctionedClassDisplay(v) }}</span>
              </div>
              <div v-if="sessionStore.hasCapability('fleetVehicles') && fleetEffectiveHpDisplay(v) != null" class="line">
                <span class="line-key">Effective power</span>
                <span class="line-value num">{{ fleetEffectiveHpDisplay(v) }}</span>
              </div>
              <div v-if="sessionStore.hasCapability('fleetVehicles') && fleetEffectivePwDisplay(v) != null" class="line">
                <span class="line-key">Power to weight</span>
                <span class="line-value num">{{ fleetEffectivePwDisplay(v) }} hp/kg</span>
              </div>
              <div class="line">
                <span class="line-key">Book value</span>
                <span class="line-value num money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(v.vehicleValue) }}</span>
              </div>
              <div class="line">
                <span class="line-key">Est. sale value</span>
                <span class="line-value num"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(v.sellValue) }}</span>
              </div>
            </div>

            <!-- garage actions: Pull Out is the one primary while stored; Repair takes it once pulled out -->
            <div class="row-actions">
              <div class="row-actions__group">
                <HouseButton
                  v-if="!isPulledOut(v)"
                  compact
                  variant="primary"
                  :disabled="isVehicleLockedForDelivery(v) || pullOutBlockedByFleetCooldown(v) || pullOutBlockedByLiftsFull(v)"
                  :title="pullOutDisabledTitle(v)"
                  @click.stop="handlePullOut(v)"
                  @mousedown.stop
                >
                  Pull Out
                </HouseButton>
                <HouseButton
                  v-if="showLiftSlotsWarning(v) && canUpgradeGarageSlots"
                  compact
                  @click.stop="goToGarageSlotsSkillTree"
                  @mousedown.stop
                >
                  Skill Trees
                </HouseButton>
                <HouseButton
                  v-if="isPulledOut(v)"
                  compact
                  :disabled="isVehicleLockedForDelivery(v)"
                  :title="vehicleDisabledTitle(v)"
                  @click.stop="handlePutAway(v)"
                  @mousedown.stop
                >
                  Put Away
                </HouseButton>
              </div>
              <HouseButton
                compact
                variant="quiet-danger"
                :disabled="isVehicleLockedForDelivery(v)"
                :title="vehicleDisabledTitle(v)"
                :data-fk="`vehicle-${v.vehicleId}-handleSell`" @click.stop="handleSell(v)"
                @mousedown.stop
              >
                Sell
              </HouseButton>
            </div>

            <div class="row-actions__group">
              <HouseButton
                compact
                :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                @click.stop="goToVehicleParts(v)"
                @mousedown.stop
              >
                Parts
              </HouseButton>
              <HouseButton
                compact
                :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                @click.stop="goToVehicleTuning(v)"
                @mousedown.stop
              >
                Tuning
              </HouseButton>
              <HouseButton
                v-if="sessionStore.hasCapability('fleetVehicles')"
                compact
                :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                @click.stop="startVehiclePaint(v)"
                @mousedown.stop
              >
                Paint
              </HouseButton>
              <HouseButton
                v-if="sessionStore.isMaintenanceEnabled"
                compact
                :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                @click.stop="openMaintenanceModal(v)"
                @mousedown.stop
              >
                Maintain
              </HouseButton>
              <HouseButton
                v-if="sessionStore.hasCapability('fleetVehicles') && v.fleetRepairNeeded"
                compact
                :variant="isPulledOut(v) ? 'primary' : 'neutral'"
                :disabled="isVehicleLockedForDelivery(v)"
                :title="vehicleDisabledTitle(v)"
                :data-fk="`vehicle-${v.vehicleId}-openRepairModal`" @click.stop="openRepairModal(v)"
                @mousedown.stop
              >
                Repair
              </HouseButton>
            </div>
          </div>
        </article>
      </div>
    </section>

    <div v-else class="empty">
      <p>No vehicles available right now</p>
    </div>

    <BusinessMaintenanceModal
      ref="maintenanceModalComponentRef"
      v-model:open="showMaintenanceModal"
      :vehicle="vehicleToMaintain"
      @close="closeMaintenanceModal"
    />
    <!-- teleported to body: the overlay carries .rls-house and the em scale itself -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="showRepairModal"
          class="rls-house modal-overlay"
          @click.self.stop="cancelRepair"
          @mousedown.self.stop
        >
          <div class="modal confirm-card" v-bng-scoped-nav="repairModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="cancelRepair">
            <h3>Repair vehicle</h3>
            <p>
              Team insurance covers the repair. Your deductible is
              <span class="money num"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(confirmRepairDeductible) }}</span>
              (charged from the business account).
            </p>
            <div class="actions">
              <HouseButton variant="quiet" bng-scoped-nav-autofocus @click.stop="cancelRepair" @mousedown.stop>
                Cancel
              </HouseButton>
              <HouseButton variant="primary" :aria-disabled="actionBusy" @click.stop="confirmRepair" @mousedown.stop>
                Pay &amp; repair
              </HouseButton>
            </div>
          </div>
        </div>
      </transition>
      <transition name="modal-fade">
        <div
          v-if="showAbandonModal"
          class="rls-house modal-overlay"
          @click.self.stop="cancelAbandon"
          @mousedown.self.stop
        >
          <div class="modal confirm-card" v-bng-scoped-nav="sellModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="cancelAbandon">
            <h3>Sell vehicle</h3>
            <p>
              Are you sure you want to sell this vehicle for
              <span class="money num"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(confirmSellAmount) }}</span>? It will be removed from your garage.
            </p>
            <div class="actions">
              <HouseButton variant="quiet" bng-scoped-nav-autofocus @click.stop="cancelAbandon" @mousedown.stop>
                Cancel
              </HouseButton>
              <HouseButton variant="danger" :aria-disabled="actionBusy" @click.stop="confirmAbandon" @mousedown.stop>
                Yes, sell
              </HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { useActionFocus } from "../../composables/useActionFocus.js"
import { formatMoney as formatAmount } from "../../utils/units.js"
import { useNowSeconds } from "../../composables/useNowSeconds.js"
import { secondsUntil } from "../../stores/businessComputer/businessTime.js"
import { ref, computed, Teleport, watch, nextTick, onMounted, onUnmounted } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { useBusinessVehiclesStore } from "../../stores/businessComputer/businessVehiclesStore.js"
import { normalizeId } from "../../utils/businessUtils"
import { formatSanctionedClassWithBucket } from "../../utils/sanctionedClassFormat"
import { vBngTooltip, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { refocusIfLost } from "../../composables/useScreenEntryFocus"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"
import { lua, useBridge } from "@/bridge"
import BusinessMaintenanceModal from "./BusinessMaintenanceModal.vue"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"

const computerStore = useBusinessComputerStore()
const sessionStore = useBusinessSessionStore()
const vehiclesStore = useBusinessVehiclesStore()
const bridge = useBridge()
const GARAGE_SLOTS_MAX_LEVEL = 2
// number only: the template puts the game currency glyph in front

const fleetVehicles = computed(() => {
  const v = sessionStore.vehicles
  return Array.isArray(v) ? v.filter(Boolean) : []
})

const hasVehiclesTabContent = computed(() => fleetVehicles.value.length > 0)

/** Wall-clock countdown per inventory id; keys match Lua racingTeamFleetCooldowns (tostring(vehicleId)). */
const nowSeconds = useNowSeconds()
const pendingDeliveryRefreshInFlight = ref(false)
const pendingDeliveryLastRefreshMs = ref(0)

function formatCooldownMSS(totalSec) {
  const s = Math.max(0, Math.floor(Number(totalSec) || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
  }
  return `${m}:${String(r).padStart(2, "0")}`
}

function fleetVehicleCooldownSec(vehicle) {
  if (!sessionStore.hasCapability('fleetVehicles')) return 0
  const id = vehicle?.vehicleId
  const expiries = sessionStore.businessData?.fleetCooldownExpiresAtSeconds
  return secondsUntil(expiries?.[String(id)] ?? expiries?.[String(normalizeId(id))], nowSeconds.value)
}

function isDeliveryPending(vehicle) {
  return vehicle?.deliveryPending === true
}

function deliveryPendingSec(vehicle) {
  if (!isDeliveryPending(vehicle)) {
    return 0
  }
  const dueEpoch = Number(vehicle?.deliveryDueEpoch)
  if (Number.isFinite(dueEpoch) && dueEpoch > 0) {
    return Math.max(0, Math.floor(dueEpoch - nowSeconds.value))
  }
  return secondsUntil(vehicle?.deliveryExpiresAtSeconds, nowSeconds.value)
}

function deliveryOverlayText(vehicle) {
  if (!isDeliveryPending(vehicle)) {
    return ""
  }
  if (vehicle?.deliveryMode === "drive") {
    return "Drive to team garage"
  }
  const sec = deliveryPendingSec(vehicle)
  return sec > 0 ? `Arrives in ${formatCooldownMSS(sec)}` : "Finalizing delivery"
}

function isVehicleLockedForDelivery(vehicle) {
  return isDeliveryPending(vehicle)
}

const hasPendingDeliveries = computed(() => fleetVehicles.value.some((v) => isDeliveryPending(v)))

async function refreshPendingDeliveriesIfNeeded(nowMs) {
  if (!sessionStore.hasCapability('fleetVehicles') || !hasPendingDeliveries.value) {
    return
  }
  if (pendingDeliveryRefreshInFlight.value) {
    return
  }
  // Reconcile only after arrival; the visible countdown needs no bridge traffic.
  if (!fleetVehicles.value.some(vehicle => isDeliveryPending(vehicle) && deliveryPendingSec(vehicle) <= 0)) return
  if (nowMs - pendingDeliveryLastRefreshMs.value < 10000) {
    return
  }
  const businessType = sessionStore.businessType
  const businessId = sessionStore.businessId
  if (!businessType || businessId === undefined || businessId === null || businessId === "") {
    return
  }
  pendingDeliveryRefreshInFlight.value = true
  pendingDeliveryLastRefreshMs.value = nowMs
  try {
    await sessionStore.loadBusinessData(businessType, businessId)
  } finally {
    pendingDeliveryRefreshInFlight.value = false
  }
}

function pullOutBlockedByFleetCooldown(_vehicle) {
  // Fleet post-race cooldown must not block pull-out / garage work.
  return false
}

function pullOutCooldownTitle(vehicle) {
  return `Vehicle cooling down (${formatCooldownMSS(fleetVehicleCooldownSec(vehicle))} remaining)`
}

function vehicleDisabledTitle(vehicle, fallback = "") {
  if (isVehicleLockedForDelivery(vehicle)) {
    return "Delivery in progress."
  }
  return fallback
}

function fleetCardName(v) {
  if (!v) return "Vehicle"
  return v.vehicleName || v.name || `Vehicle #${v.vehicleId ?? v.id ?? ""}`
}

/** Effective fleet HP from Lua (dyno/catalog, metric hp) in the player's power unit; null if unknown. */
function fleetEffectiveHpDisplay(v) {
  const n = Number(v?.fleetEffectiveHp)
  if (!Number.isFinite(n) || n <= 0) return null
  return bridge.units.buildString("power", n, 0)
}

function fleetEffectivePwDisplay(v) {
  const n = Number(v?.fleetEffectivePw)
  if (!Number.isFinite(n) || n <= 0) return null
  return (Math.round(n * 100) / 100).toFixed(2)
}

/** Sanctioned P/W sub-bracket label from Lua (matches race offers). */
function fleetSanctionedClassDisplay(v) {
  return formatSanctionedClassWithBucket(v?.fleetSanctionedClassLabel, v?.fleetEffectivePw)
    || (typeof v?.fleetClassStatusMessage === "string" ? v.fleetClassStatusMessage : "")
}

function fleetCardImage(v) {
  const src = v?.vehicleImage
  if (typeof src === "string" && src.length > 0) return src
  return "/ui/images/appDefault.png"
}

function formatMoney(value) {
  const n = Number(value)
  return formatAmount(Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0, { decimals: 0, locale: "en-US" })
}

const shopNavBusy = ref(false)
async function goTeamVehicleShop() {
  if (shopNavBusy.value) return
  const id = sessionStore.businessId
  if (id === null || id === undefined || id === "") return
  shopNavBusy.value = true
  try {
    await lua.overhaul_career_market_vehicleShopping.setRtBiz(String(id))
    await lua.extensions.ui_router.navigate("overhaul.computer.vehicleShopping", {
      screenTag: "buying",
      buyingAvailable: "true",
      marketplaceAvailable: "true",
      selectedSellerId: "",
    })
  } finally {
    shopNavBusy.value = false
  }
}

const sellModalScope = bcModalScope("vehicle-sell")
const repairModalScope = bcModalScope("vehicle-repair")
const maintenanceModalComponentRef = ref(null)
const showAbandonModal = ref(false)
const showRepairModal = ref(false)
const showMaintenanceModal = ref(false)
const vehicleToSell = ref(null)
const vehicleToRepair = ref(null)
const vehicleToMaintain = ref(null)
const expandedVehicleId = ref(null)
const interceptEvent = () => {}
const confirmSellAmount = computed(() => {
  const v = vehicleToSell.value
  if (!v || v.sellValue === undefined || v.sellValue === null) return 0
  return v.sellValue
})

const confirmRepairDeductible = computed(() => {
  const v = vehicleToRepair.value
  const n = Number(v?.fleetRepairDeductible)
  return Number.isFinite(n) && n >= 0 ? n : 750
})

const pulledOutVehicleIds = computed(() => {
  const list = Array.isArray(sessionStore.pulledOutVehicles) ? sessionStore.pulledOutVehicles : []
  return new Set(list.map((v) => normalizeId(v?.vehicleId)).filter((id) => id !== null))
})

const garageSlotsSkillLevel = ref(0)

const liftsFull = computed(() => {
  const list = sessionStore.pulledOutVehicles
  if (Array.isArray(list)) {
    return list.length >= sessionStore.maxPulledOutVehicles
  }
  return !!sessionStore.pulledOutVehicle
})

const canUpgradeGarageSlots = computed(() => garageSlotsSkillLevel.value < GARAGE_SLOTS_MAX_LEVEL)

const liftSlotsWarningText =
  "All garage slots are in use. Put away vehicle or upgrade skill tree"

const showLiftSlotsWarning = (vehicle) => {
  return (
    sessionStore.hasCapability('fleetVehicles')
    && !isDeliveryPending(vehicle)
    && !isPulledOut(vehicle)
    && liftsFull.value
  )
}

const pullOutBlockedByLiftsFull = (vehicle) => showLiftSlotsWarning(vehicle)

const pullOutDisabledTitle = (vehicle) => {
  if (pullOutBlockedByFleetCooldown(vehicle)) {
    return vehicleDisabledTitle(vehicle, pullOutCooldownTitle(vehicle))
  }
  if (pullOutBlockedByLiftsFull(vehicle)) {
    return liftSlotsWarningText
  }
  return vehicleDisabledTitle(vehicle, "")
}

const refreshGarageSlotsSkillLevel = async () => {
  if (!sessionStore.hasCapability('fleetVehicles') || !sessionStore.businessId) {
    garageSlotsSkillLevel.value = 0
    return
  }
  try {
    const level = await lua.overhaul_career_business_skillTree.getNodeProgress(
      sessionStore.businessId,
      "qol",
      "garageSlots"
    )
    garageSlotsSkillLevel.value = Number(level) || 0
  } catch {
    garageSlotsSkillLevel.value = 0
  }
}

const goToGarageSlotsSkillTree = () => {
  computerStore.switchView("skill-tree")
}

const isPulledOut = (vehicle) => {
  const vid = normalizeId(vehicle?.vehicleId)
  return vid !== null && pulledOutVehicleIds.value.has(vid)
}

const expandedKeyForVehicle = (vehicle) => String(normalizeId(vehicle?.vehicleId) ?? vehicle?.vehicleId ?? vehicle?.id ?? "")

const isExpanded = (vehicle) => expandedVehicleId.value === expandedKeyForVehicle(vehicle)

const toggleExpanded = (vehicle) => {
  const key = expandedKeyForVehicle(vehicle)
  expandedVehicleId.value = expandedVehicleId.value === key ? null : key
}

// Controller: the row header is the anchor when an action swaps the focused button out (Pull Out <-> Put Away)
const rowHeader = (vehicle) => document.querySelector(`.vehicle-row__header[data-veh-key="${expandedKeyForVehicle(vehicle)}"]`)
const refocusRow = (vehicle) => refocusIfLost(() => rowHeader(vehicle))

// B inside an expanded row folds it and returns focus to its header; on a folded row B goes on to the screen
const collapseRow = (vehicle) => {
  if (!isExpanded(vehicle)) return true
  expandedVehicleId.value = null
  nextTick(() => rowHeader(vehicle)?.focus())
  return false
}

const handlePullOut = async (vehicle) => {
  if (pullOutBlockedByFleetCooldown(vehicle) || pullOutBlockedByLiftsFull(vehicle)) {
    return
  }
  await vehiclesStore.pullOutVehicle(vehicle.vehicleId)
  refocusRow(vehicle)
}

const handlePutAway = async (vehicle) => {
  await vehiclesStore.putAwayVehicle(vehicle?.vehicleId)
  refocusRow(vehicle)
}

const activateVehicleAndOpenView = async (vehicle, view) => {
  const vid = vehicle?.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  if (!isPulledOut(vehicle)) return
  await computerStore.setActiveVehicleSelection(vid)
  await computerStore.switchVehicleView(view)
}

const goToVehicleParts = async (vehicle) => {
  await activateVehicleAndOpenView(vehicle, "parts")
}

const goToVehicleTuning = async (vehicle) => {
  await activateVehicleAndOpenView(vehicle, "tuning")
}

const startVehiclePaint = async (vehicle) => {
  if (!isPulledOut(vehicle)) return
  const vid = vehicle?.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  await computerStore.setActiveVehicleSelection(vid)
  await vehiclesStore.startVehiclePainting(vid)
}

const handleSell = (vehicle) => {
  if (!vehicle) return
  remember()
  vehicleToSell.value = vehicle
  showAbandonModal.value = true
}

const openMaintenanceModal = (vehicle) => {
  if (!vehicle) return
  vehicleToMaintain.value = vehicle
  showMaintenanceModal.value = true
}

const openRepairModal = (vehicle) => {
  if (!vehicle) return
  remember()
  vehicleToRepair.value = vehicle
  showRepairModal.value = true
}

const cancelRepair = () => {
  showRepairModal.value = false
  vehicleToRepair.value = null
}

const rootRef = ref(null)
const { remember, restore } = useActionFocus(rootRef)
const actionBusy = ref(false)

const confirmRepair = async () => {
  const v = vehicleToRepair.value
  if (!v || actionBusy.value) return
  actionBusy.value = true
  try {
    const result = await vehiclesStore.repairBusinessVehicle(v.vehicleId)
    if (result?.success) {
      await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
      if (showMaintenanceModal.value && normalizeId(vehicleToMaintain.value?.vehicleId) === normalizeId(v?.vehicleId)) {
        await maintenanceModalComponentRef.value?.reload?.()
      }
      showRepairModal.value = false
      vehicleToRepair.value = null
    }
  } finally {
    actionBusy.value = false
    await restore()
  }
}

const closeMaintenanceModal = () => {
  vehicleToMaintain.value = null
}

const confirmAbandon = async () => {
  if (!vehicleToSell.value || actionBusy.value) return
  actionBusy.value = true
  try {
    await vehiclesStore.sellVehicle(vehicleToSell.value.vehicleId)
    showAbandonModal.value = false
    vehicleToSell.value = null
  } finally {
    actionBusy.value = false
    await restore()
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  vehicleToSell.value = null
}

watch(
  () => [sessionStore.businessId, sessionStore.businessType],
  () => {
    refreshGarageSlotsSkillLevel()
  },
  { immediate: true }
)

watch(nowSeconds, seconds => {
  refreshPendingDeliveriesIfNeeded(seconds * 1000)
})

onMounted(() => {
  bridge.events.on("businessSkillTree:onTreesUpdated", refreshGarageSlotsSkillLevel)

})

onUnmounted(() => {
  bridge.events.off("businessSkillTree:onTreesUpdated", refreshGarageSlotsSkillLevel)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.vehicles-tab {
  display: flex;
  flex-direction: column;
  gap: 1.1em;
}

.num {
  font-variant-numeric: tabular-nums;
}

/* ---- title + shopping */
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.8em 1em;
}

.page-head__copy {
  display: grid;
  gap: 0.3em;
  min-width: 0;
}

.page-title {
  margin: 0;
  color: #fff;
  font-size: 1.4em;
  font-weight: 800;
  line-height: 1.15;
}

.page-head .hint {
  font-size: 0.9em;
}

.header-actions {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--space-2);
}

/* ---- garage list */
.garage-section {
  display: grid;
  gap: 0.6em;
}

.section-caption {
  display: flex;
  align-items: center;
  gap: 0.6em;
  margin: 0;

  .pill {
    font-size: 0.95em;
    letter-spacing: 0;
    font-variant-numeric: tabular-nums;
  }
}

.vehicle-list {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.vehicle-row {
  border-radius: var(--radius-panel);
  background: var(--panel);
  transition: background-color 0.12s;

  &.expanded {
    background: var(--panel-2);
  }
}

/* header: photo, name + specs, value + pills, chevron (VehicleTileRow layout) */
.vehicle-row__header {
  display: grid;
  grid-template-columns: 11.5em minmax(0, 1fr) auto auto;
  gap: 1em;
  align-items: center;
  min-height: 7.6em;
  padding: 0.5em 0.9em 0.5em 0.5em;
  border-radius: var(--radius-panel);
  color: #fff;
  cursor: pointer;
  text-align: left;

  &:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  &:focus {
    outline: none;
  }

  @include house-focus;
}

.veh-photo {
  position: relative;
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

  &.dim img {
    filter: brightness(45%) saturate(50%);
  }
}

.photo-lock {
  position: absolute;
  inset: 0;
  display: grid;
  place-content: center;
  padding: 0.4em;
  text-align: center;
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.9);

  strong {
    font-size: 0.9em;
    font-weight: 800;
    line-height: 1.15;
    font-variant-numeric: tabular-nums;
  }
}

.veh-info {
  display: grid;
  gap: 0.45em;
  min-width: 0;
}

.veh-name {
  min-width: 0;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.15;
  overflow-wrap: anywhere;
  /* long names: two lines, then ellipsis */
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.veh-specs {
  display: grid;
  gap: 0.25em;
}

.spec {
  min-width: 0;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.25;
}

.veh-side {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  align-self: start;
  gap: 0.3em;
  padding-top: 0.55em;
  text-align: right;
}

.veh-value {
  color: var(--money);
  font-size: 1.05em;
  font-weight: 800;
  white-space: nowrap;
}

.veh-value-note {
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 600;
  white-space: nowrap;
}

.veh-flags {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.35em;
  margin-top: 0.2em;
}

.chevron {
  width: 1em;
  height: 1em;
  fill: none;
  stroke: var(--faint);
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
  transform: rotate(-90deg);
  transition: transform 0.16s ease;

  .expanded & {
    transform: rotate(0deg);
  }
}

/* ---- expanded details */
.vehicle-row__expanded {
  display: grid;
  gap: 0.65em;
  padding: 0.2em 0.9em 0.9em;
}

.expanded-hint {
  font-size: 0.85em;
}

.detail-lines {
  background: rgba(0, 0, 0, 0.2);
}

.line-key {
  color: var(--faint);
  font-size: 0.88em;
  font-weight: 600;
}

.line-value {
  font-weight: 700;
  text-align: right;

  &.money {
    color: var(--money);
  }
}

.row-actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: var(--space-2);
}

.row-actions__group {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--space-2);
}

/* ---- empty */
.empty:not(.bng-button) {
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* ---- house modal (teleported to body, so it carries its own em scale) */
.modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.confirm-card {
  width: min(28em, 92vw);
  padding: 1.1em 1.1em 1em;

  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }

  .money {
    color: var(--money);
    font-weight: 800;
  }

  .actions {
    margin-top: 0.3em;
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .confirm-card {
    transition: transform 0.18s ease, opacity 0.18s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .confirm-card {
    transform: scale(0.96);
    opacity: 0;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
