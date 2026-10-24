<template>
  <!-- Controller: B / Start unwind one level (damage details -> service list -> close). Results show in
       house popups, which carry their own scope, default focus and A. -->
  <div class="roadside-service-wrapper" bng-ui-scope="roadsideService" v-bng-on-ui-nav:back,menu="onBack">
    <div class="rls-house rs-shell">
      <BngCard class="rs-card" v-bng-blur="1">
        <div v-if="loading" class="rs-state">
          <p class="muted">Loading service options...</p>
          <div class="actions">
            <HouseButton variant="quiet" binding="back" @click="close">Close</HouseButton>
          </div>
        </div>

        <div v-else-if="error" class="rs-state">
          <p class="notice bad">{{ error }}</p>
          <div class="actions">
            <HouseButton class="rs-error-close" binding="back" @click="close">Close</HouseButton>
          </div>
        </div>

        <template v-else>
          <!-- the stop: where you pulled off, the car, what you can spend -->
          <header class="rs-head">
            <div v-if="vehiclePhoto" class="rs-photo">
              <img :src="vehiclePhoto" alt="" @error="photoFailed = true" />
            </div>
            <div class="rs-head-copy">
              <span class="caption">{{ uiData.spotName || 'Roadside Service' }}</span>
              <strong class="rs-veh-name">{{ uiData.vehicle?.niceName || uiData.vehicle?.model || 'Vehicle' }}</strong>
              <span v-if="uiData.vehicle?.mileage" class="hint tnum">{{ formatMileage(uiData.vehicle.mileage) }}</span>
            </div>
            <div class="rs-wallet">
              <span class="caption">Your Money</span>
              <strong class="rs-money tnum"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(uiData.playerMoney || 0) }}</strong>
            </div>
            <HouseButton class="rs-close" variant="quiet" compact :icon="icons.xmark" data-focusable @click="close" />
          </header>

          <!-- Repair damage detail (second screen) -->
          <div v-if="repairPending" class="rs-state" role="status" aria-live="polite">
            <strong>Repair in progress</strong>
            <p class="notice">Your vehicle is being prepared and repaired. Please wait.</p>
          </div>
          <template v-else-if="view === 'repairDetail' && repairService">
            <!-- read-only lines (focus is on the footer): the right stick scrolls them -->
            <div class="rs-body scroll" v-bng-ui-nav-scroll.force>
              <div class="rs-section-head">
                <span class="caption">Repair Details</span>
                <span class="hint tnum">{{ allDamageLines.length }} item{{ allDamageLines.length === 1 ? '' : 's' }} found</span>
              </div>

              <div v-if="visibleDamageLines.length" class="sheet">
                <div class="lines">
                  <div
                    v-for="line in visibleDamageLines"
                    :key="line.id || line.label"
                    class="line dmg-line"
                  >
                    <span class="dmg-copy">
                      <strong class="dmg-label">{{ line.label }}</strong>
                      <span v-if="line.detail" class="hint">{{ line.detail }}</span>
                    </span>
                    <span class="pill dmg-kind">{{ kindLabel(line.kind) }}</span>
                    <strong class="dmg-cost tnum"><template v-if="line.cost"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(line.cost) }}</template></strong>
                  </div>
                </div>
              </div>
              <p v-else class="notice">No line items returned.</p>

              <div v-if="hiddenDamageCount > 0" class="rs-more">
                <HouseButton variant="quiet" compact @click="showMoreDamage">
                  Show more ({{ hiddenDamageCount }} remaining)
                </HouseButton>
              </div>
            </div>

            <!-- totals pinned under the list -->
            <footer class="rs-foot">
              <div class="rs-totals">
                <div v-if="repairService.hasBrokenParts" class="rs-total-row">
                  <span class="rs-total-key">
                    {{ repairService.brokenParts }} fully broken part{{ repairService.brokenParts === 1 ? '' : 's' }}
                    <span class="hint">before labor</span>
                  </span>
                  <strong class="money tnum"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(repairService.brokenPartsCost) }}</strong>
                </div>
                <div v-if="repairService.hasFiniteDamage" class="rs-total-row">
                  <span class="rs-total-key">
                    Soft / cosmetic / tire work
                    <span class="hint">before labor</span>
                  </span>
                  <strong class="money tnum"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(repairService.finiteCost) }}</strong>
                </div>
                <div class="rs-total-row">
                  <span class="rs-total-key">Roadside labor</span>
                  <strong class="tnum">&times;{{ formatMultiplier(repairService.laborMultiplier) }}</strong>
                </div>
                <div class="rs-total-row grand">
                  <span>Estimated total</span>
                  <strong class="tnum" :class="repairService.canAfford ? 'money' : 'short'">
                    <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(repairService.cost) }}
                  </strong>
                </div>
              </div>
              <div class="actions">
                <p v-if="!repairService.canAfford" class="actions-note short">
                  Not enough money for this repair.
                </p>
                <HouseButton class="rs-detail-back" variant="quiet" binding="back" @click="view = 'main'">Back</HouseButton>
                <HouseButton
                  class="rs-repair-btn"
                  binding="ok"
                  :variant="repairService.canAfford ? 'primary' : 'neutral'"
                  :disabled="!repairService.canAfford"
                  @click="confirmRepairFromDetail"
                >
                  <template v-if="repairService.canAfford">Repair for <span class="btn-amt tnum"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(repairService.cost) }}</span></template>
                  <template v-else>Cannot afford</template>
                </HouseButton>
              </div>
            </footer>
          </template>

          <!-- Main service list -->
          <div v-else class="rs-body scroll" v-bng-ui-nav-scroll>
            <p v-if="repairState.message" class="notice" :class="{ bad: repairState.status === 'failed' }" role="status" aria-live="polite">
              {{ repairState.message }}
            </p>
            <p v-if="uiData.laborMultiplier > 1" class="notice">
              Roadside service rates are {{ Math.round((uiData.laborMultiplier - 1) * 100) }}% higher than garage rates.
            </p>

            <span class="caption">Services</span>
            <div class="rs-services">
              <button
                v-for="service in orderedServices"
                :key="service.id"
                type="button"
                class="rs-tile"
                :class="{
                  primary: isPrimaryService(service),
                  off: !service.available || (service.id !== 'repair' && service.cost && !service.canAfford),
                }"
                :aria-disabled="!service.available"
                :data-service="service.id"
                @click="selectService(service)"
                data-focusable
                bng-nav-item
              >
                <BngIcon class="rs-tile-icon" :type="serviceIcons[service.id]" />
                <span class="rs-tile-copy">
                  <strong class="rs-tile-name">{{ service.label }}</strong>
                  <span class="rs-tile-desc">{{ service.description }}</span>
                </span>
                <span v-if="service.cost !== undefined && service.available" class="rs-tile-cost">
                  <span class="hint">Cost</span>
                  <strong class="tnum" :class="service.canAfford ? 'money' : 'short'"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(service.cost) }}</strong>
                </span>
                <span v-if="service.reason" class="rs-tile-reason">{{ service.reason }}</span>
                <span v-else-if="service.id === 'repair' && service.available && !service.canAfford" class="rs-tile-reason short">
                  Not enough money
                </span>
                <span v-if="service.available" class="rs-tile-go">
                  {{ service.id === 'repair' ? 'Damage details' : 'Open' }}
                </span>
              </button>
            </div>
          </div>
        </template>
      </BngCard>
    </div>

  </div>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { BngCard, BngIcon, icons } from "@/common/components/base"
import { HouseButton, openHouseMessage } from "../components/house/index.js"
import { vBngBlur, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { lua, useBridge } from "@/bridge"
import { refocusIfLost } from "../composables/useScreenEntryFocus"
import { installLuaBridgeFallbacks, callModLua } from "../utils/installLuaBridgeFallbacks"
import { formatOdometer } from "../utils/units"

installLuaBridgeFallbacks()
const { units, events } = useBridge()
useUINavScope('roadsideService')

const DAMAGE_PAGE_SIZE = 12

const loading = ref(true)
const error = ref(null)
const uiData = ref({})
const view = ref('main') // 'main' | 'repairDetail'
const repairRequestPending = ref(false)
const repairRefreshPending = ref(false)
const repairState = computed(() => uiData.value.repairState || { status: 'idle' })
const repairPending = computed(() => repairRequestPending.value || repairRefreshPending.value || repairState.value.status === 'pending')
const damageVisibleCount = ref(DAMAGE_PAGE_SIZE)


const serviceIcons = {
  repair: icons.wrench,
  maintenance: icons.oilPressureIndicator,
  tuning: icons.cogs,
}

const serviceOrder = ['repair', 'maintenance', 'tuning']

const orderedServices = computed(() => {
  if (!uiData.value.services) return []
  return serviceOrder
    .filter(id => uiData.value.services[id])
    .map(id => uiData.value.services[id])
})

const repairService = computed(() => uiData.value?.services?.repair || null)

const allDamageLines = computed(() => repairService.value?.damageLines || [])

const visibleDamageLines = computed(() =>
  allDamageLines.value.slice(0, damageVisibleCount.value)
)

const hiddenDamageCount = computed(() =>
  Math.max(0, allDamageLines.value.length - damageVisibleCount.value)
)

// Display-only helpers
const photoFailed = ref(false)
const vehiclePhoto = computed(() => {
  if (photoFailed.value) return null
  const veh = uiData.value?.vehicle
  return veh?.thumbnail || veh?.preview || null
})
watch(() => uiData.value?.vehicle?.thumbnail, () => { photoFailed.value = false })

// Repair is the one orange tile, and only when it can actually be bought.
const isPrimaryService = (service) =>
  service.id === 'repair' && service.available && service.canAfford

const KIND_LABELS = {
  broken: 'Broken',
  soft: 'Soft',
  cosmetic: 'Cosmetic',
  state: 'System',
  tire: 'Tire',
  finite: 'Finite',
  info: 'Info',
  unknown: 'Other',
}
const kindLabel = (kind) => {
  if (!kind) return KIND_LABELS.info
  return KIND_LABELS[kind] || String(kind).charAt(0).toUpperCase() + String(kind).slice(1)
}

const formatMultiplier = (mult) => {
  const n = Number(mult)
  if (!Number.isFinite(n)) return '1'
  return n.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 2 })
}

// whole beams; the template puts the currency glyph in front
const formatMoney = (amount) => Math.round(Number(amount) || 0).toLocaleString()

// odometer arrives in metres; shown in the player's length unit
const formatMileage = (meters) => formatOdometer(units, meters)

const showMoreDamage = () => {
  damageVisibleCount.value = Math.min(
    allDamageLines.value.length,
    damageVisibleCount.value + DAMAGE_PAGE_SIZE
  )
}

watch(view, (next) => {
  if (next === 'repairDetail') damageVisibleCount.value = DAMAGE_PAGE_SIZE
})

const loadData = async () => {
  // only the first load blanks the card: a refresh after a repair keeps the list (and its focus) mounted
  if (!uiData.value?.services) loading.value = true
  error.value = null
  try {
    const data = await callModLua("overhaul_career_repair_roadsideService.getUiData")
    if (data?.error) {
      error.value = data.debugError || data.error
    } else if (data) {
      uiData.value = data
    } else {
      error.value = 'Failed to load service data.'
    }
  } catch (e) {
    reportUiFailure(e, "Failed to load roadside service data: (RoadsideServiceMain)")
    error.value = 'Failed to load service data.'
  }
  loading.value = false
}

const selectService = (service) => {
  if (repairPending.value) return
  if (!service.available) return
  if (service.cost !== undefined && !service.canAfford && service.id !== 'repair') return

  if (service.id === 'repair') {
    view.value = 'repairDetail'
  } else if (service.id === 'maintenance') {
    openMaintenance()
  } else if (service.id === 'tuning') {
    openTuning()
  }
}

const confirmRepairFromDetail = () => {
  if (!repairService.value?.canAfford) return
  performRepair()
}

// Results go to a house popup (scope, default focus, A = OK). The popup host only restores focus into
// scoped-nav scopes, which this screen has none of, so put it back on the screen afterwards.
const showResult = async (title, message) => {
  await openHouseMessage(title, message)
  // the promise settles on the click; the popup (and its focused OK) only leaves after its close
  // animation, which drops focus on <body>. Wait for that, then land back on the list.
  let tries = 0
  const settle = () => {
    const active = document.activeElement
    const lost = !active || active === document.body || !document.contains(active)
    if (lost) return refocusIfLost(pickViewFocus)
    if (++tries < 20) setTimeout(settle, 50)
  }
  setTimeout(settle, 50)
}

const performRepair = async () => {
  if (repairPending.value) return
  repairRequestPending.value = true
  try {
    const result = await callModLua("overhaul_career_repair_roadsideService.performRepair")
    await loadData()
    if (!result?.ok && repairState.value.status !== 'failed') {
      await showResult('Repair Failed', result?.message || 'Unable to complete repair.')
    }
    view.value = 'main'
  } catch (e) {
    reportUiFailure(e, "Repair failed: (RoadsideServiceMain)")
    await loadData()
    if (repairState.value.status !== 'pending') await showResult('Error', 'Unable to confirm the repair result.')
  } finally {
    repairRequestPending.value = false
  }
}

const onRepairState = async (state) => {
  if (String(state?.inventoryId) !== String(uiData.value.inventoryId)) return
  uiData.value = { ...uiData.value, repairState: state }
  if (state.status !== 'pending') {
    view.value = 'main'
    repairRefreshPending.value = true
    try {
      await loadData()
    } finally {
      repairRefreshPending.value = false
    }
  }
}

const openMaintenance = async () => {
  try {
    const result = await callModLua("overhaul_career_repair_roadsideService.openMaintenance")
    if (!result?.ok) await showResult('Unavailable', result?.message || 'Maintenance is unavailable.')
  } catch (e) {
    reportUiFailure(e, "Failed to open maintenance: (RoadsideServiceMain)")
  }
}

const openTuning = async () => {
  try {
    const result = await callModLua("overhaul_career_repair_roadsideService.openTuning")
    if (!result?.ok) await showResult('Unavailable', result?.message || 'Tuning is unavailable.')
  } catch (e) {
    reportUiFailure(e, "Failed to open tuning: (RoadsideServiceMain)")
  }
}

// ---- controller focus (the screen has no scoped-nav scope, so it places focus itself)
const rootEl = () => document.querySelector('.roadside-service-wrapper')
const pickServiceTile = (id) =>
  (id && rootEl()?.querySelector(`.rs-tile[data-service="${id}"]`))
  || rootEl()?.querySelector('.rs-tile.primary')
  || rootEl()?.querySelector('.rs-tile:not(.off)')
  || rootEl()?.querySelector('.rs-tile')
  || rootEl()?.querySelector('.rs-close')
const pickViewFocus = () => {
  if (error.value) return rootEl()?.querySelector('.rs-error-close')
  if (repairPending.value) return rootEl()?.querySelector('.rs-close')
  if (view.value === 'repairDetail') {
    return rootEl()?.querySelector('.rs-repair-btn:not(:disabled)') || rootEl()?.querySelector('.rs-detail-back')
  }
  return pickServiceTile()
}
// entry (and the error state): once the first load finished
watch(loading, isLoading => { if (!isLoading) refocusIfLost(pickViewFocus) }, { flush: 'post' })
// details <-> list is a deliberate swap: details land on Repair (else Back), the list on the repair tile
watch(view, (next, prev) => {
  refocusIfLost(next === 'main' && prev === 'repairDetail' ? () => pickServiceTile('repair') : pickViewFocus, { force: true })
}, { flush: 'post' })
// "Show more" disappears once every line is shown
watch(hiddenDamageCount, () => refocusIfLost(pickViewFocus), { flush: 'post' })
watch(repairPending, () => refocusIfLost(pickViewFocus), { flush: 'post' })

// B unwinds one level: damage details -> service list -> close
const onBack = () => {
  if (view.value === 'repairDetail') {
    view.value = 'main'
    return
  }
  close()
}

const close = async () => {
  try {
    await callModLua("overhaul_career_repair_roadsideService.closeMenu")
  } catch (e) {
    reportUiFailure(e, "Failed to close roadside service via module: (RoadsideServiceMain)")
  }
  // Hard fallback so Escape / X never strand the player in this route.
  try {
    await callModLua("overhaul_career_career.closeAllMenus")
  } catch (_) {
    lua.extensions?.ui_router?.navigate?.('play')
  }
}

onMounted(() => {
  events.on('roadsideServiceRepairState', onRepairState)
  loadData()
})
onUnmounted(() => events.off('roadsideServiceRepairState', onRepairState))
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* full-screen card, centred like the other pickup cards */
.roadside-service-wrapper {
  width: 100%;
  height: 100%;
  min-height: 100vh; // the route container has no height of its own, so fill the viewport to centre
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2em;
  box-sizing: border-box;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  color: #fff;
}

.rs-shell {
  width: min(48em, 100%);
  max-height: calc(100vh - 4em);
  min-height: 0;
  display: flex;
}

.rs-card {
  --bng-card-height: auto;
  --bng-icon-color: currentColor;
  font-size: inherit;
  flex: 1 1 auto;
  min-height: 0;
  max-height: 100%;
  border-radius: var(--radius-control);
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  :deep(.card-cnt) {
    display: flex;
    flex-direction: column;
    min-height: 0;
    max-height: calc(100vh - 4em);
    border-radius: var(--radius-control);
    background: rgba(21, 21, 23, 0.93);
  }
}

.tnum { font-variant-numeric: tabular-nums; }
/* currency glyph in front of an amount */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
.btn-amt { white-space: nowrap; }
.money { color: var(--money); }
.short { color: var(--bad); }

.rs-state {
  display: grid;
  gap: var(--space-3);
  padding: 1.4em 1.2em;
  .actions { justify-content: flex-start; }
}

/* ---- header: photo, spot + car, money, close */
.rs-head {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 1em;
  padding: 1em 0.8em 0.9em 1.1em;
  border-bottom: 1px solid var(--line);
}
.rs-photo {
  flex: 0 0 auto;
  width: 12em;
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
}
.rs-head-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.2em;
}
.rs-veh-name {
  font-size: 1.45em;
  font-weight: 800;
  line-height: 1.15;
}
.rs-wallet {
  flex: 0 0 auto;
  display: grid;
  gap: 0.15em;
  justify-items: end;
}
.rs-money {
  color: var(--money);
  font-size: 1.2em;
  font-weight: 800;
}
.rs-close {
  align-self: flex-start;
  margin-top: -0.3em;
}

/* ---- scrolling body */
.rs-body {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  padding: 1em 0.8em 1.1em 1.1em;
}
.rs-section-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 1em;
}

/* ---- service tiles */
.rs-services {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(12em, 1fr));
  gap: 0.6em;
}
.rs-tile {
  appearance: none;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.55em;
  min-width: 0;
  margin: 0;
  padding: 0.95em 0.95em 0.9em;
  border: 0;
  border-radius: var(--radius-tile);
  background: var(--panel);
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s;
  &:hover:not(.off) { background: var(--panel-2); }
  position: relative; // the game's focus frame is absolute: anchor it here, not on the card
  @include house-focus;
  &.off { cursor: default; }
  &.off .rs-tile-icon,
  &.off .rs-tile-copy { opacity: 0.5; }
}
.rs-tile-icon {
  font-size: 1.8em;
  line-height: 1;
  color: var(--muted);
}
.rs-tile.primary .rs-tile-icon { color: var(--accent-soft); }
.rs-tile-copy {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}
.rs-tile-name {
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
}
.rs-tile-desc {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.3;
}
.rs-tile-cost {
  display: flex;
  align-items: baseline;
  gap: 0.45em;
  strong {
    font-size: 1.2em;
    font-weight: 800;
  }
}
.rs-tile-reason {
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.3;
  &.short { color: var(--bad); }
}
/* the tile's call to action: orange only on the primary tile */
.rs-tile-go {
  margin-top: auto;
  padding: 0.62em 0.95em 0.5em;
  border-radius: var(--radius-control);
  background: var(--panel-2);
  font-weight: 700;
  line-height: 1;
}
.rs-tile:hover:not(.off) .rs-tile-go { background: var(--panel-hover); }
.rs-tile.primary .rs-tile-go { background: var(--accent); }
.rs-tile.primary:hover .rs-tile-go { background: var(--accent-hover); }

/* ---- damage sheet */
.dmg-line {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto 5.5em;
  align-items: center;
  gap: 0.9em;
}
.dmg-copy {
  display: grid;
  gap: 0.1em;
  min-width: 0;
}
.dmg-label {
  font-weight: 700;
  line-height: 1.2;
}
.dmg-kind { justify-self: end; }
.dmg-cost {
  justify-self: end;
  color: var(--money);
  font-weight: 800;
}
.rs-more {
  display: flex;
  justify-content: center;
}

/* ---- totals + actions, pinned under the scroll */
.rs-foot {
  flex: 0 0 auto;
  display: grid;
  gap: 0.75em;
  padding: 0.85em 1.1em 1.1em;
  border-top: 1px solid var(--line);
}
.rs-totals {
  display: grid;
  gap: 0.3em;
}
.rs-total-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1em;
  color: var(--muted);
  font-weight: 600;
  strong { font-weight: 700; }
  .hint { margin-left: 0.35em; }
  &.grand {
    margin-top: 0.25em;
    color: #fff;
    font-size: 1.3em;
    font-weight: 800;
    strong { font-weight: 900; }
  }
}
.rs-total-key { min-width: 0; }
.actions-note.short { color: var(--bad); }

</style>
