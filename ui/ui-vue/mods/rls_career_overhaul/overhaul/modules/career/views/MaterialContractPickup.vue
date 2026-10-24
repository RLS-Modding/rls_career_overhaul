<template>
  <div
    class="material-loader-shell"
    v-bng-blur
    bng-ui-scope="materialContractPickup"
    v-bng-on-ui-nav:back,menu="close">
    <div class="rls-shell loader-shell">
      <BngCard class="rls-card">
        <BngCardHeading type="ribbon">
          <span class="hd-name">{{ data.material?.name || 'Material loader' }}</span>
          <span v-if="ready" class="hd-status" :class="statusTone">{{ statusText }}</span>
        </BngCardHeading>

        <div class="card-content" v-bng-ui-nav-scroll>
          <!-- where it goes -->
          <div v-if="data.contract" class="route">
            <span class="route-end"><small>From</small><strong>{{ data.contract.sourceName }}</strong></span>
            <svg class="route-arrow" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6" /></svg>
            <span class="route-end"><small>To</small><strong>{{ data.contract.destinationName }}</strong></span>
          </div>

          <section v-if="!ready" class="block">
            <p class="muted">Connecting to the loading equipment…</p>
            <div class="actions"><HouseButton class="btn-back" binding="back" @click="close">Back</HouseButton></div>
          </section>

          <section v-else-if="!data.available" class="block">
            <p class="notice-bad">{{ data.reason || 'The loader is unavailable right now.' }}</p>
            <div class="actions"><HouseButton class="btn-back" binding="back" @click="close">Back</HouseButton></div>
          </section>

          <template v-else>
            <!-- the whole contract -->
            <section class="block">
              <div class="block-head">
                <div class="kicker">Contract progress</div>
                <span v-if="!data.companyEmployment && data.contract.quotedRewards?.money != null" class="money-text">
                  <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(data.contract.quotedRewards?.money) }} total
                </span>
              </div>
              <div class="progress-bar" aria-label="Contract delivery progress">
                <span class="delivered" :style="{ width: deliveredPercent + '%' }"></span>
                <span class="transit" :style="{ width: transitPercent + '%' }"></span>
              </div>
              <div class="legend">
                <span><i class="dot delivered"></i><b>{{ amount(data.contract.deliveredAmount) }}</b> delivered</span>
                <span><i class="dot transit"></i><b>{{ amount(data.contract.inTransitAmount) }}</b> in transit</span>
                <span><i class="dot left"></i><b>{{ amount(data.contract.remainingAmount) }}</b> to go</span>
                <span v-if="!data.companyEmployment" class="held">
                  <b class="money-text"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(data.contract.escrowedMoney ?? data.contract.paidMoney) }}</b> held so far
                </span>
              </div>
            </section>

            <div class="columns">
              <!-- this trip -->
              <section class="block">
                <div class="block-head">
                  <div class="kicker">This trip</div>
                  <span class="hint" v-if="data.maximumLoad > 0">Up to {{ amount(data.maximumLoad) }}</span>
                </div>
                <div class="panel trip">
                  <template v-if="data.maximumLoad > 0">
                    <span class="big">{{ amount(selectedAmount) }}</span>
                    <HouseSlider :min="1" :max="data.maximumLoad" :step="1" v-model="selectedAmount" />
                    <div class="chips">
                      <button v-if="standardLoad > 0" type="button" bng-nav-item
                        :class="{ active: selectedAmount === standardLoad }" @click="selectStandardLoad">
                        Standard, {{ amount(standardLoad) }}
                      </button>
                      <button type="button" bng-nav-item
                        :class="{ active: selectedAmount === data.maximumLoad }" @click="selectedAmount = data.maximumLoad">
                        Fill free space
                      </button>
                    </div>
                  </template>
                  <div v-else class="no-capacity">
                    <strong>No free space nearby</strong>
                    <span class="hint">Bring a {{ containerTypeLabel }} with empty capacity into the loading area.</span>
                  </div>
                </div>
                <p v-if="resultMessage" :class="resultError ? 'status-error' : 'status-ok'">{{ resultMessage }}</p>
              </section>

              <!-- what's parked in the loading area -->
              <section class="block">
                <div class="block-head">
                  <div class="kicker">Nearby equipment</div>
                  <span class="hint">{{ amount(data.compatibleCapacity) }} free</span>
                </div>
                <!-- read-only list: the right stick scrolls it without moving focus -->
                <ul v-if="data.equipment?.length" class="equipment scroll-list" v-bng-ui-nav-scroll.force>
                  <li v-for="item in data.equipment" :key="`${item.vehId}-${item.containerId}`" class="equip" :class="{ off: !item.eligible }">
                    <div class="equip-top">
                      <span class="equip-copy">
                        <strong>{{ item.vehicleName }}</strong>
                        <span class="hint">{{ item.containerName }}</span>
                      </span>
                      <span v-if="item.eligible" class="pill ok">{{ amount(item.free) }} free</span>
                      <span v-else class="pill bad">{{ item.reason }}</span>
                    </div>
                    <div class="fill-bar"><span :style="{ width: usedPercent(item) + '%' }"></span></div>
                    <span class="hint">{{ amount(item.used) }} of {{ amount(item.capacity) }} used</span>
                  </li>
                </ul>
                <p v-else class="muted">No cargo containers in the loading area.</p>
                <p v-if="!data.compatibleCapacity && data.equipmentHint" class="muted">{{ data.equipmentHint }}</p>
              </section>
            </div>

            <div class="actions">
              <p class="actions-note">Your route switches to {{ data.contract.destinationName }} once loaded.</p>
              <HouseButton class="btn-back" variant="quiet" binding="back" @click="close">Back</HouseButton>
              <HouseButton
                class="btn-load"
                variant="primary"
                binding="ok"
                :disabled="data.maximumLoad <= 0 || loading || selectedAmount <= 0"
                @click="loadSelected">
                {{ loading ? 'Loading…' : `Load ${amount(selectedAmount)}` }}
              </HouseButton>
            </div>
          </template>
        </div>
      </BngCard>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { BngCard, BngCardHeading, BngIcon, icons } from '@/common/components/base'
import { HouseButton, HouseSlider } from '../components/house/index.js'
import { vBngBlur, vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { useUINavScope } from '@/services/uiNav'
import { refocusIfLost } from '../composables/useScreenEntryFocus'

useUINavScope('materialContractPickup')

const { events } = useBridge()
const ready = ref(false)
const loading = ref(false)
const selectedAmount = ref(0)
const resultMessage = ref('')
const resultError = ref(false)
const data = reactive({
  available: false,
  contract: null,
  material: null,
  equipment: [],
  equipmentHint: '',
  compatibleCapacity: 0,
  maximumLoad: 0,
  companyEmployment: false,
})

const standardLoad = computed(() => Math.min(data.contract?.standardLoad || 0, data.maximumLoad || 0))
const total = computed(() => Math.max(1, data.contract?.totalAmount || 1))
const deliveredPercent = computed(() => Math.min(100, ((data.contract?.deliveredAmount || 0) / total.value) * 100))
const transitPercent = computed(() => Math.min(100 - deliveredPercent.value, ((data.contract?.inTransitAmount || 0) / total.value) * 100))
const containerTypeLabel = computed(() => {
  if (data.material?.type === 'fluid') return 'tank'
  if (data.material?.type === 'dryBulk' || data.material?.type === 'cement') return 'bulk container'
  return 'secure cargo container'
})

// heading status pill
const statusText = computed(() => {
  if (!data.available) return 'Unavailable'
  return data.maximumLoad > 0 ? 'Ready to load' : 'No free space'
})
const statusTone = computed(() => (!data.available ? 'bad' : data.maximumLoad > 0 ? 'ready' : 'warn'))

function usedPercent(item) {
  const cap = Number(item?.capacity) || 0
  return cap > 0 ? Math.min(100, Math.max(0, ((Number(item.used) || 0) / cap) * 100)) : 0
}

function amount(value) {
  const n = Math.max(0, Math.round(Number(value) || 0))
  return `${n.toLocaleString()} ${pluralUnit(data.material?.units || data.contract?.units || 'L', n)}`
}

function pluralUnit(unit, n) {
  // Only word units pluralise (Box -> Boxes, Pallet -> Pallets); symbols like L or kg stay as they are.
  if (n === 1 || !/^[A-Za-z]{3,}$/.test(unit) || /s$/i.test(unit)) return unit
  return /(x|ch|sh)$/i.test(unit) ? `${unit}es` : `${unit}s`
}

// number only: the template puts the game currency glyph in front
function money(value) {
  return Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
}

function applyData(payload) {
  Object.assign(data, payload || {})
  ready.value = true
  loading.value = Boolean(payload?.loading)
  const preferred = Math.min(payload?.contract?.standardLoad || payload?.maximumLoad || 0, payload?.maximumLoad || 0)
  if (selectedAmount.value <= 0 || selectedAmount.value > (payload?.maximumLoad || 0)) selectedAmount.value = preferred
}

function applyResult(payload) {
  loading.value = false
  resultMessage.value = payload?.message || ''
  resultError.value = payload?.success === false
}

function selectStandardLoad() {
  selectedAmount.value = standardLoad.value || data.maximumLoad
}

function loadSelected() {
  if (loading.value || selectedAmount.value <= 0) return
  loading.value = true
  resultMessage.value = ''
  lua.overhaul_career_logistics_cargoScreen.loadMaterialContract(data.contract.id, Math.round(selectedAmount.value))
}

function close() {
  lua.overhaul_career_logistics_cargoScreen.closeMaterialContractPickupScreen(false)
}

watch(() => data.maximumLoad, max => {
  if (selectedAmount.value > max) selectedAmount.value = max
})

// Controller: no scoped-nav scope here, so focus Load once the loader answered (or Back when it can't
// load), and again whenever loading / a data refresh disabled or swapped the focused button.
const pickMainAction = () => {
  const root = document.querySelector('.material-loader-shell')
  return root?.querySelector('.actions .btn-load:not(:disabled)') || root?.querySelector('.actions .btn-back')
}
watch([ready, loading, () => data.available, () => data.maximumLoad], () => refocusIfLost(pickMainAction), { flush: 'post' })

onMounted(() => {
  events.on('materialContractPickupData', applyData)
  events.on('materialContractPickupResult', applyResult)
  lua.overhaul_career_logistics_cargoScreen.requestMaterialContractPickupData()
})

onUnmounted(() => {
  events.off('materialContractPickupData', applyData)
  events.off('materialContractPickupResult', applyResult)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsCard.scss" as *;


.material-loader-shell {
  width: 100%;
  height: 100%;
  min-height: 100vh; // the route container has no height of its own, so fill the viewport to centre
  display: flex;
  align-items: center; // centred on screen
  justify-content: center;
  padding: 2em;
  box-sizing: border-box;
  color: #fff;
  background: rgba(5, 8, 10, 0.55);
}
.loader-shell {
  width: min(60em, 100%);
}
.hd-status.bad {
  background: rgba(252, 165, 165, 0.18);
  color: var(--bad);
}
.money-text {
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

/* ---- route */
.route {
  display: flex;
  align-items: center;
  gap: 1em;
  padding-bottom: 0.8em;
  border-bottom: 1px solid var(--line);
}
.route-end {
  display: grid;
  gap: 0.1em;
  min-width: 0;
  small {
    color: var(--faint);
    font-size: 0.7em;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }
  // facility names wrap to two lines before they clip
  strong {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    overflow: hidden;
    overflow-wrap: anywhere;
    font-size: 1.05em;
  }
}
.route-arrow {
  flex: 0 0 auto;
  width: 1.2em;
  height: 1.2em;
  fill: none;
  stroke: var(--faint);
  stroke-width: 2.2;
  stroke-linecap: round;
  stroke-linejoin: round;
}

/* ---- contract progress: delivered (green), in transit (soft orange), the rest empty */
.progress-bar {
  display: flex;
  height: 0.55em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);
  > span {
    display: block;
    height: 100%;
  }
  .delivered {
    background: var(--ok);
  }
  .transit {
    background: var(--accent);
    opacity: 0.6;
  }
}
.legend {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35em 1.3em;
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  b {
    color: #fff;
    font-weight: 800;
    margin-right: 0.2em;
  }
  .held {
    margin-left: auto;
  }
  .dot {
    display: inline-block;
    width: 0.6em;
    height: 0.6em;
    margin-right: 0.4em;
    border-radius: 50%;
    vertical-align: 0.05em;
    &.delivered { background: var(--ok); }
    &.transit { background: var(--accent); opacity: 0.6; }
    &.left { background: rgba(255, 255, 255, 0.2); }
  }
}

/* ---- this trip */
.trip {
  gap: 0.6em;
  .big {
    color: #fff;
    font-variant-numeric: tabular-nums;
  }
}
.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em;
  > button {
    appearance: none;
    margin: 0;
    padding: 0.55em 0.75em 0.42em;
    border: 0;
    border-radius: 0.6em;
    background: var(--panel);
    color: var(--muted);
    font: inherit;
    font-weight: 700;
    line-height: 1;
    cursor: pointer;
    &:hover {
      background: var(--panel-2);
      color: #fff;
    }
    &.active {
      background: var(--panel-2);
      color: #fff;
    }
    @include card-focus;
  }
}
.no-capacity {
  display: grid;
  gap: 0.25em;
  strong {
    color: var(--warn);
  }
}

/* ---- nearby equipment */
.equipment {
  list-style: none;
  margin: 0;
  padding: 0;
  max-height: clamp(12em, 36vh, 26em);
}
.equip {
  display: grid;
  gap: 0.4em;
  padding: 0.65em 0.75em 0.55em;
  border-radius: 0.5em;
  background: var(--panel);
  &.off strong {
    color: var(--faint);
  }
}
.equip-top {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 0.8em;
}
.equip-copy {
  display: grid;
  gap: 0.1em;
  min-width: 0;
  // vehicle names wrap to two lines before they clip (one line cut "Gavril T-Series Heritage Grand Tou...")
  strong {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    overflow: hidden;
    overflow-wrap: anywhere;
  }
}
.fill-bar {
  height: 0.35em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);
  > span {
    display: block;
    height: 100%;
    background: rgba(255, 255, 255, 0.55);
  }
}
.notice-bad {
  margin: 0;
  padding: 0.7em 0.85em 0.6em;
  border-radius: 0.5em;
  background: rgba(252, 165, 165, 0.14);
  color: var(--bad);
  font-weight: 600;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
