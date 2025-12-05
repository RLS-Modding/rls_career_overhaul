<template>
  <div class="business-shopping-cart" :class="{ expanded }" v-bng-blur>
    <!-- Confirmation Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showConfirmModal" class="modal-overlay" @click.self="cancelClose">
          <div class="modal-content" ref="confirmModalRef">
            <h2>Confirm Exit</h2>
            <p>Are you sure you want to leave this view? You will be losing progress.</p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" @click="cancelClose" data-focusable>Cancel</button>
              <button class="btn btn-primary" @click="confirmCancel" data-focusable>Yes, Leave</button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <!-- Tab Options Modal -->
    <Teleport to="body">
      <transition name="dropdown-fade">
        <div v-if="tabMenuVisible" class="tab-menu-overlay" @click.self="hideTabMenu">
          <div class="tab-menu-modal" :style="{ left: tabMenuX + 'px', top: tabMenuY + 'px' }" @click.stop ref="tabMenuRef">
            <button class="menu-item" @click="startRenaming(tabMenuTabId)" data-focusable>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
                <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
              </svg>
              Rename
            </button>
            <button class="menu-item" @click="store.duplicateTab(tabMenuTabId); hideTabMenu()" data-focusable>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
              </svg>
              Duplicate
            </button>
            <button class="menu-item" @click="clearCurrentTab(); hideTabMenu()" data-focusable>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <polyline points="3 6 5 6 21 6" />
                <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
              </svg>
              Clear
            </button>
          </div>
        </div>
      </transition>
    </Teleport>

    <div class="cart-header">
      <h3>Shopping Cart</h3>
      <button class="expand-toggle" @click="expanded = !expanded">
        <svg class="chevron-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
          stroke-width="2" :class="{ rotated: !expanded }">
          <polyline points="6 9 12 15 18 9" />
        </svg>
      </button>
    </div>

    <transition name="cart-collapse">
      <div v-if="expanded" class="cart-main">
        <div class="cart-tabs">
          <div class="tabs-list">
            <div v-for="tab in store.cartTabs" :key="tab.id" class="tab-wrapper"
              @contextmenu.prevent="showTabMenu($event, tab.id)">
              <button class="tab-button" :class="{ active: tab.id === store.activeTabId }"
                @click="handleTabClick(tab.id, $event)">
                <input v-if="editingTabId === tab.id" v-model="editingTabName" type="text" @focus="onRenameFocus"
                  @blur="onRenameBlur(tab.id)" @keydown.enter.stop="finishRenaming(tab.id)"
                  @keydown.esc.stop="cancelRenaming" @keydown.stop @keyup.stop @keypress.stop class="tab-rename-input"
                  v-bng-text-input :ref="el => { if (el) renameInput = el }" @click.stop @mousedown.stop />
                <span v-else>{{ tab.name }}</span>
                <button v-if="store.cartTabs.length > 1" class="tab-close" @click.stop="store.deleteTab(tab.id)">
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <line x1="18" y1="6" x2="6" y2="18" />
                    <line x1="6" y1="6" x2="18" y2="18" />
                  </svg>
                </button>
              </button>
            </div>
            <button class="tab-add" @click="store.createNewTab" title="New Build">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="12" y1="5" x2="12" y2="19" />
                <line x1="5" y1="12" x2="19" y2="12" />
              </svg>
            </button>
          </div>
        </div>
        <div class="cart-list">
          <div v-if="partsItems.length === 0 && tuningItems.length === 0" class="empty-cart">
            <p>Cart is empty</p>
          </div>

          <template v-if="partsItems.length > 0">
            <div class="cart-section">
              <button class="cart-section-header" @click="partsSectionCollapsed = !partsSectionCollapsed">
                <div class="section-header-content">
                  <h3>Parts</h3>
                  <span class="section-subtotal">Subtotal: ${{ partsCost.toLocaleString('en-US', {
                    minimumFractionDigits: 2, maximumFractionDigits: 2
                  }) }}</span>
                </div>
                <svg class="section-chevron" width="20" height="20" viewBox="0 0 24 24" fill="none"
                  stroke="currentColor" stroke-width="2" :class="{ rotated: partsSectionCollapsed }">
                  <polyline points="6 9 12 15 18 9" />
                </svg>
              </button>
              <transition name="section-collapse">
                <div v-if="!partsSectionCollapsed" class="section-content">
                  <PartsTreeItem v-for="node in store.partsTree" :key="node.id" :node="node" :level="0"
                    @remove="store.removePartFromCart" />
                </div>
              </transition>
            </div>
          </template>

          <template v-if="tuningItems.length > 0">
            <div class="cart-section">
              <button class="cart-section-header" @click="tuningSectionCollapsed = !tuningSectionCollapsed">
                <div class="section-header-content">
                  <h3>Tuning</h3>
                  <span class="section-subtotal">Subtotal: ${{ tuningCost.toLocaleString('en-US', {
                    minimumFractionDigits: 2, maximumFractionDigits: 2
                  }) }}</span>
                </div>
                <svg class="section-chevron" width="20" height="20" viewBox="0 0 24 24" fill="none"
                  stroke="currentColor" stroke-width="2" :class="{ rotated: tuningSectionCollapsed }">
                  <polyline points="6 9 12 15 18 9" />
                </svg>
              </button>
              <transition name="section-collapse">
                <div v-if="!tuningSectionCollapsed" class="section-content">
                  <div v-for="item in tuningItems" :key="`${item.type}-${item.varName}-${item.level || 1}`"
                    class="cart-item" :class="{
                      'cart-item-category': item.type === 'category',
                      'cart-item-subcategory': item.type === 'subCategory',
                      'cart-item-variable': item.type === 'variable'
                    }" :style="{ paddingLeft: `${((item.level || 1) - 1) * 1.5}em` }">
                    <button v-if="item.type === 'variable'" class="remove-button"
                      @click="store.removeTuningFromCart(item.varName)">
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                        stroke-width="2">
                        <line x1="18" y1="6" x2="6" y2="18" />
                        <line x1="6" y1="6" x2="18" y2="18" />
                      </svg>
                    </button>
                    <div v-else class="remove-button-spacer"></div>
                    <div class="item-info">
                      <div class="item-name" :class="{ 'item-name-header': item.type !== 'variable' }">
                        {{ item.title || item.varName }}
                      </div>
                      <div
                        v-if="item.type === 'variable' && item.value !== undefined && item.originalValue !== undefined"
                        class="item-slot">
                        {{ convertToDisplayValue(item, item.originalValue) }} → {{ convertToDisplayValue(item,
                          item.value) }}
                      </div>
                    </div>
                    <div class="item-price">${{ (item.visualPrice !== undefined ? item.visualPrice : (item.price ||
                      0)).toLocaleString('en-US', {
                        minimumFractionDigits: 2,
                        maximumFractionDigits: 2
                      }) }}</div>
                  </div>
                </div>
              </transition>
            </div>
          </template>
        </div>

        <div class="cart-footer">
          <transition name="footer-collapse">
            <div v-if="!footerCollapsed" class="footer-details">
              <div v-if="store.hasDynoUpgrade" class="power-weight-stats">

                <div class="performance-section-header">
                  <span class="section-title">Performance</span>
                  <div class="view-toggles">
                    <button class="toggle-btn" :class="{ active: performanceViewMode === 'stats' }"
                      :disabled="!hasDynoData" @click="performanceViewMode = 'stats'">
                      Stats
                    </button>
                    <button class="toggle-btn" :class="{ active: performanceViewMode === 'dyno' }"
                      :disabled="!hasDynoData" @click="performanceViewMode = 'dyno'">
                      Dyno
                    </button>
                  </div>
                </div>

                <div v-if="hasDynoData && performanceViewMode === 'stats'" class="stats-container">
                  <div class="stat-row">
                    <div class="stat-label-col">Power:</div>
                    <div class="stat-value-col">{{ Math.round(store.originalPower || 0) }} PS</div>
                    <div class="stat-arrow-col">
                      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                        stroke-width="2">
                        <path d="M5 12h14M12 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div class="stat-value-col">{{ Math.round(store.currentPower || 0) }} PS</div>
                  </div>
                  <div class="stat-row">
                    <div class="stat-label-col">Weight:</div>
                    <div class="stat-value-col">{{ Math.round(store.originalWeight) }} kg</div>
                    <div class="stat-arrow-col">
                      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                        stroke-width="2">
                        <path d="M5 12h14M12 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div class="stat-value-col">{{ Math.round(store.currentWeight) }} kg</div>
                  </div>
                  <div class="stat-row">
                    <div class="stat-label-col">Power/Weight:</div>
                    <div class="stat-value-col">{{ store.originalPowerToWeightRatio ?
                      store.originalPowerToWeightRatio.toFixed(2) : '-' }}</div>
                    <div class="stat-arrow-col">
                      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                        stroke-width="2">
                        <path d="M5 12h14M12 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div class="stat-value-col">{{ store.powerToWeightRatio ? store.powerToWeightRatio.toFixed(2) : '-'
                    }}</div>
                  </div>
                </div>

                <div v-else-if="hasDynoData && performanceViewMode === 'dyno'" class="dyno-container">
                  <svg class="dyno-graph" width="100%" height="100%" viewBox="0 0 300 140" preserveAspectRatio="none"
                    @mousemove="handleGraphMouseMove" @mouseleave="handleGraphLeave">
                    <defs>
                      <linearGradient id="torqueGradient" x1="0%" y1="0%" x2="0%" y2="100%">
                        <stop offset="0%" style="stop-color:#F54900;stop-opacity:0.3" />
                        <stop offset="100%" style="stop-color:#F54900;stop-opacity:0" />
                      </linearGradient>
                    </defs>

                    <!-- Grid lines -->
                    <line x1="30" y1="30" x2="270" y2="30" stroke="rgba(255,255,255,0.1)" stroke-width="1" />
                    <line x1="30" y1="60" x2="270" y2="60" stroke="rgba(255,255,255,0.1)" stroke-width="1" />
                    <line x1="30" y1="90" x2="270" y2="90" stroke="rgba(255,255,255,0.1)" stroke-width="1" />

                    <!-- Y Axis Labels (Torque - Left) -->
                    <text x="25" y="34" text-anchor="end" fill="rgba(255,255,255,0.4)" font-size="10">{{
                      Math.round(maxTorque *
                        0.75) }}</text>
                    <text x="25" y="64" text-anchor="end" fill="rgba(255,255,255,0.4)" font-size="10">{{
                      Math.round(maxTorque *
                        0.5) }}</text>
                    <text x="25" y="94" text-anchor="end" fill="rgba(255,255,255,0.4)" font-size="10">{{
                      Math.round(maxTorque *
                        0.25) }}</text>

                    <!-- Y Axis Labels (Power - Right) -->
                    <text x="275" y="34" text-anchor="start" fill="#FF4444" font-size="10">{{ Math.round(maxPower *
                      0.75)
                    }}</text>
                    <text x="275" y="64" text-anchor="start" fill="#FF4444" font-size="10">{{ Math.round(maxPower * 0.5)
                    }}</text>
                    <text x="275" y="94" text-anchor="start" fill="#FF4444" font-size="10">{{ Math.round(maxPower *
                      0.25)
                    }}</text>

                    <!-- X Axis Labels -->
                    <text x="30" y="135" text-anchor="start" fill="rgba(255,255,255,0.4)" font-size="10">0</text>
                    <text x="150" y="135" text-anchor="middle" fill="rgba(255,255,255,0.4)" font-size="10">{{
                      Math.round(maxRpm
                        * 0.5) }}</text>
                    <text x="270" y="135" text-anchor="end" fill="rgba(255,255,255,0.4)" font-size="10">{{
                      Math.round(maxRpm)
                    }}</text>

                    <!-- Graphs -->
                    <!-- Original (Before) - Dashed -->
                    <path v-if="originalTorquePath" :d="originalTorquePath" fill="none" stroke="rgba(255,255,255,0.3)"
                      stroke-width="2" stroke-dasharray="4" />
                    <path v-if="originalPowerPath" :d="originalPowerPath" fill="none" stroke="rgba(255,68,68,0.3)"
                      stroke-width="2" stroke-dasharray="4" />

                    <!-- Current (After) - Solid -->
                    <path :d="torquePath" fill="none" stroke="rgba(255,255,255,0.8)" stroke-width="2" />
                    <path :d="powerPath" fill="none" stroke="#FF4444" stroke-width="2" />

                    <!-- Hover Indicator -->
                    <g v-if="graphHover">
                      <line :x1="graphHover.x" y1="0" :x2="graphHover.x" y2="120" stroke="rgba(255,255,255,0.5)"
                        stroke-width="1" stroke-dasharray="4" />

                      <!-- Tooltip Background -->
                      <rect :x="graphHover.tooltipX" :y="graphHover.tooltipY" width="110" height="60" rx="4"
                        fill="rgba(0,0,0,0.9)" stroke="rgba(255,255,255,0.2)" stroke-width="1" />

                      <!-- Tooltip Text -->
                      <text :x="graphHover.tooltipX + 55" :y="graphHover.tooltipY + 14" text-anchor="middle"
                        fill="#FF4444" font-size="10" font-weight="bold">
                        {{ Math.round(graphHover.power) }} hp
                        <tspan v-if="graphHover.originalPower" fill="rgba(255,68,68,0.5)" font-size="9"> ({{
                          Math.round(graphHover.originalPower) }})</tspan>
                      </text>
                      <text :x="graphHover.tooltipX + 55" :y="graphHover.tooltipY + 26" text-anchor="middle"
                        fill="rgba(255,255,255,0.7)" font-size="10">
                        {{ Math.round(graphHover.torque) }} Nm
                        <tspan v-if="graphHover.originalTorque" fill="rgba(255,255,255,0.4)" font-size="9"> ({{
                          Math.round(graphHover.originalTorque) }})</tspan>
                      </text>
                      <text :x="graphHover.tooltipX + 55" :y="graphHover.tooltipY + 38" text-anchor="middle"
                        fill="rgba(255,255,255,0.5)" font-size="9">@ {{ Math.round(graphHover.rpm) }} RPM</text>
                    </g>

                    <!-- Transparent interaction layer -->
                    <rect x="0" y="0" width="300" height="140" fill="transparent" />
                  </svg>
                </div>
                <div v-else class="dyno-placeholder">
                  <p>Waiting for dyno data...</p>
                  <button class="btn btn-secondary" @click.stop="requestDynoData" @mousedown.stop="requestDynoData">
                    Refresh Dyno
                  </button>
                </div>
              </div>
              <div class="cart-summary-breakdown">
                <div class="summary-row">
                  <span>Subtotal:</span>
                  <span>${{ subtotal.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
                  }}</span>
                </div>
                <div class="summary-row">
                  <span>Tax (7%):</span>
                  <span>${{ taxAmount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
                  }}</span>
                </div>
              </div>
            </div>
          </transition>
          <div class="cart-total-wrapper">
            <div class="cart-total">
              <span>Total:</span>
              <span class="total-amount">${{ totalCost.toLocaleString('en-US', {
                minimumFractionDigits: 2,
                maximumFractionDigits: 2
              }) }}</span>
            </div>
            <button class="footer-toggle" @click="footerCollapsed = !footerCollapsed"
              :title="footerCollapsed ? 'Show details' : 'Hide details'">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
                :class="{ rotated: footerCollapsed }">
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
          </div>
          <div class="cart-buttons">
            <button class="btn btn-secondary" @click="cancel">Cancel</button>
            <button 
              class="btn btn-primary btn-hold" 
              :class="{ 'is-holding': isHolding, 'is-processing': isProcessing }"
              :disabled="!canPurchase || isProcessing"
              @mousedown.stop="startHold"
              @mouseup.stop="endHold"
              @mouseleave="endHold"
              @touchstart.stop.prevent="startHold"
              @touchend.stop.prevent="endHold"
              @touchcancel.stop="endHold"
              @click.stop.prevent
            >
              <span class="hold-progress" :style="{ width: holdProgress + '%' }"></span>
              <span class="btn-label">{{ isProcessing ? 'Processing...' : (totalCost > 0 ? 'Hold to Purchase' : 'Hold to Apply') }}</span>
            </button>
          </div>
        </div>
      </div>
    </transition>

    <transition name="cart-collapse">
      <div v-if="!expanded" class="cart-collapsed">
        <div class="cart-summary">
          <span>{{ totalItems }} item{{ totalItems !== 1 ? 's' : '' }}</span>
          <span class="summary-total">${{ totalCost.toLocaleString('en-US', {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2
          }) }}</span>
        </div>
      </div>
    </transition>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount, Teleport, nextTick, inject } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"

const controllerNav = inject('controllerNav', null)
const confirmModalRef = ref(null)
const tabMenuRef = ref(null)
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"
import { vBngBlur, vBngTextInput } from "@/common/directives"
import PartsTreeItem from "./PartsTreeItem.vue"

const store = useBusinessComputerStore()
const events = useEvents()

// Handle power/weight data from Lua
const handlePowerWeightData = (data) => {
  store.handlePowerWeightData(data)
  // Legacy handling removed in favor of TorqueCurveChanged
}

const torqueData = ref(null)
const powerData = ref(null)
const originalTorqueData = ref(null)
const originalPowerData = ref(null)
const maxPowerValue = ref(0)
const maxTorqueValue = ref(0)
const maxRpmValue = ref(0)

const processCurveData = (data) => {
  if (!data) return null

  let curves = []
  if (data.curves) {
    if (Array.isArray(data.curves)) {
      curves = data.curves
    } else if (typeof data.curves === 'object') {
      curves = Object.values(data.curves)
    }
  } else if (Array.isArray(data)) {
    curves = data
  } else {
    curves = [data]
  }

  let bestCurve = null
  let highestMaxPower = -1

  for (const curve of curves) {
    let currentMaxPower = 0
    for (const rpm in curve.power) {
      const val = curve.power[rpm]
      if (val > currentMaxPower) currentMaxPower = val
    }

    if (currentMaxPower > highestMaxPower) {
      highestMaxPower = currentMaxPower
      bestCurve = curve
    }
  }

  if (bestCurve) {
    const tPoints = []
    for (const rpm in bestCurve.torque) {
      tPoints.push([parseInt(rpm), bestCurve.torque[rpm]])
    }
    tPoints.sort((a, b) => a[0] - b[0])

    const pPoints = []
    for (const rpm in bestCurve.power) {
      const rawVal = bestCurve.power[rpm]
      const hpVal = rawVal > 10000 ? rawVal * 0.00134102 : rawVal * 1.34102
      pPoints.push([parseInt(rpm), hpVal])
    }
    pPoints.sort((a, b) => a[0] - b[0])

    return {
      torque: tPoints,
      power: pPoints,
      maxRpm: data.maxRPM || 8000
    }
  }
  return null
}

const onTorqueCurveChanged = (data) => {
  if (!data) return

  const processed = processCurveData(data)
  if (processed) {
    // If cart is empty and we don't have original data yet, save it
    if (store.partsCart.length === 0 && store.tuningCart.length === 0 && !store.originalCurveData) {
      store.originalCurveData = data
    }

    // If we have original data in store, process it for display
    if (store.originalCurveData) {
      const originalProcessed = processCurveData(store.originalCurveData)
      if (originalProcessed) {
        originalTorqueData.value = originalProcessed.torque
        originalPowerData.value = originalProcessed.power
      }
    }

    torqueData.value = processed.torque
    powerData.value = processed.power
    maxRpmValue.value = processed.maxRpm

    // Calculate max values across both datasets
    let maxT = 0
    const allTorque = [...(torqueData.value || []), ...(originalTorqueData.value || [])]
    for (const p of allTorque) {
      if (p[1] > maxT) maxT = p[1]
    }
    maxTorqueValue.value = maxT

    let maxP = 0
    const allPower = [...(powerData.value || []), ...(originalPowerData.value || [])]
    for (const p of allPower) {
      if (p[1] > maxP) maxP = p[1]
    }
    maxPowerValue.value = maxP
  }
}

onMounted(() => {
  events.on('TorqueCurveChanged', onTorqueCurveChanged)
  if (window.bngApi) {
    window.bngApi.activeObjectLua('controller.mainController.sendTorqueData()')
  }
  loadBalance()
})

onBeforeUnmount(() => {
  events.off('TorqueCurveChanged', onTorqueCurveChanged)
})
const performanceViewMode = ref('stats') // 'stats' or 'dyno'

const torqueGraphPoints = computed(() => {
  if (!torqueData.value) return []
  return torqueData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const powerGraphPoints = computed(() => {
  if (!powerData.value) return []
  return powerData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const originalTorqueGraphPoints = computed(() => {
  if (!originalTorqueData.value) return []
  return originalTorqueData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const originalPowerGraphPoints = computed(() => {
  if (!originalPowerData.value) return []
  return originalPowerData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const maxRpm = computed(() => maxRpmValue.value || 8000)
const maxTorque = computed(() => maxTorqueValue.value || 500)
const maxPower = computed(() => maxPowerValue.value || 500)

const graphHover = ref(null)

const handleGraphMouseMove = (e) => {
  if (!torqueGraphPoints.value.length && !powerGraphPoints.value.length) return

  const svg = e.currentTarget
  const pt = svg.createSVGPoint()
  pt.x = e.clientX
  pt.y = e.clientY
  const svgP = pt.matrixTransform(svg.getScreenCTM().inverse())

  const width = 300
  const height = 120
  const paddingLeft = 30
  const paddingRight = 30

  const availableWidth = width - paddingLeft - paddingRight

  let clickRpm = ((svgP.x - paddingLeft) / availableWidth) * maxRpm.value
  clickRpm = Math.max(0, Math.min(maxRpm.value, clickRpm))

  // Find closest points
  const findClosest = (points) => {
    if (!points.length) return null
    let closest = points[0]
    let minDiff = Math.abs(points[0].rpm - clickRpm)
    for (let i = 1; i < points.length; i++) {
      const diff = Math.abs(points[i].rpm - clickRpm)
      if (diff < minDiff) {
        minDiff = diff
        closest = points[i]
      }
    }
    return closest
  }

  const closestTorque = findClosest(torqueGraphPoints.value)
  const closestPower = findClosest(powerGraphPoints.value)
  const closestOriginalTorque = findClosest(originalTorqueGraphPoints.value)
  const closestOriginalPower = findClosest(originalPowerGraphPoints.value)

  const displayRpm = closestTorque ? closestTorque.rpm : (closestPower ? closestPower.rpm : 0)

  const scaleX = availableWidth / maxRpm.value
  const x = paddingLeft + displayRpm * scaleX

  let tooltipX = x - 45
  let tooltipY = 10

  if (tooltipX < 0) tooltipX = 0
  if (tooltipX > width - 90) tooltipX = width - 90

  graphHover.value = {
    x,
    rpm: displayRpm,
    torque: closestTorque ? closestTorque.val : 0,
    power: closestPower ? closestPower.val : 0,
    originalTorque: closestOriginalTorque ? closestOriginalTorque.val : 0,
    originalPower: closestOriginalPower ? closestOriginalPower.val : 0,
    tooltipX,
    tooltipY
  }
}

const handleGraphLeave = () => {
  graphHover.value = null
}

const makePath = (points, maxValue) => {
  if (!points.length) return ''

  const width = 300
  const height = 120
  const paddingLeft = 30
  const paddingRight = 30

  const availableWidth = width - paddingLeft - paddingRight
  const availableHeight = height

  const scaleX = availableWidth / maxRpm.value
  const scaleY = availableHeight / (maxValue * 1.1)

  let path = ''
  points.forEach((p, i) => {
    const x = paddingLeft + p.rpm * scaleX
    const y = height - p.val * scaleY
    if (i === 0) path = `M ${x} ${y}`
    else path += ` L ${x} ${y}`
  })
  return path
}

const torquePath = computed(() => makePath(torqueGraphPoints.value, maxTorque.value))
const powerPath = computed(() => makePath(powerGraphPoints.value, maxPower.value))
const originalTorquePath = computed(() => makePath(originalTorqueGraphPoints.value, maxTorque.value))
const originalPowerPath = computed(() => makePath(originalPowerGraphPoints.value, maxPower.value))

const expanded = ref(true)
const hasDynoData = computed(() => store.originalPower !== null && store.currentPower !== null)
const requestDynoData = () => {
  try {
    if (store.updatePowerWeight) {
      store.updatePowerWeight()
    }
  } catch (error) {
  }
}
const businessBalance = ref(0)
const tabMenuVisible = ref(false)
const tabMenuTabId = ref(null)
const tabMenuX = ref(0)
const tabMenuY = ref(0)
const editingTabId = ref(null)
const editingTabName = ref('')
const renameInput = ref(null)
const showConfirmModal = ref(false)
const footerCollapsed = ref(false)
const partsSectionCollapsed = ref(false)
const tuningSectionCollapsed = ref(false)

const HOLD_DURATION = 1000
const isHolding = ref(false)
const holdProgress = ref(0)
const holdStartTime = ref(null)
const holdAnimationId = ref(null)
const isProcessing = ref(false)

const partsItems = computed(() => store.partsCart || [])
const tuningItems = computed(() => store.tuningCart || [])

const normalizeJobId = (value) => {
  if (value === undefined || value === null) {
    return 'nojob'
  }
  return String(value)
}

const getVehicleCacheKey = () => {
  if (!store.pulledOutVehicle) {
    return null
  }
  return normalizeJobId(store.pulledOutVehicle.jobId)
}

const convertToDisplayValue = (item, actualValue) => {
  if (actualValue === null || actualValue === undefined) return '0'
  if (!store.tuningDataCache || !store.pulledOutVehicle) return actualValue.toFixed(2)

  const cacheKey = getVehicleCacheKey()
  if (!cacheKey) return actualValue.toFixed(2)
  const tuningData = store.tuningDataCache[cacheKey]
  if (!tuningData || !tuningData[item.varName]) return actualValue.toFixed(2)

  const varData = tuningData[item.varName]

  // Removed Wheel Alignment conversion to show real values as requested
  // Relaxed check for Wheel Alignment to ensure display values are shown
  if (varData.category === "Wheel Alignment" && varData.min !== undefined && varData.max !== undefined) {
    const actualMin = varData.min
    const actualMax = varData.max
    const range = actualMax - actualMin
    if (range > 0) {
      // Formula to convert actual value back to -1 to 1 slider range (or 0-100 depending on implementation)
      // Assuming standard BeamNG slider behavior where min/max maps to -1/1 or 0/100
      // If the original value was 0-100, we want to show that.

      // Try to determine if it's a centered slider (-1 to 1) or 0-100
      // Usually Wheel Alignment is centered.

      const sliderValue = ((actualValue - actualMin) / range) * 2 - 1
      const displayValue = Math.round(sliderValue * 100)
      return displayValue.toString()
    }
  }

  return actualValue.toFixed(2)
}

const tuningCost = computed(() => {
  return store.tuningCost || 0
})

const partsCost = computed(() => {
  const total = store.getCartTotal || 0
  const tuning = tuningCost.value
  return total - tuning
})

const salesTaxRate = 0.07 // 7% sales tax (matching vanilla)

const subtotal = computed(() => {
  return store.getCartTotal || 0
})

const taxAmount = computed(() => {
  return subtotal.value * salesTaxRate
})

const totalCost = computed(() => {
  return subtotal.value + taxAmount.value
})

const totalItems = computed(() => {
  return partsItems.value.length + tuningItems.value.length
})

const canPurchase = computed(() => {
  if (!store.businessId || !store.businessType) return false
  const hasItems = totalItems.value > 0
  if (!hasItems) return false
  if (totalCost.value > businessBalance.value) return false
  return true
})

const loadBalance = async () => {
  if (!store.businessType || !store.businessId) {
    businessBalance.value = 0
    return
  }

  try {
    const balance = await lua.career_modules_business_businessComputer.getBusinessAccountBalance(
      store.businessType,
      store.businessId
    )
    businessBalance.value = balance || 0
  } catch (error) {
    businessBalance.value = 0
  }
}

const handleAccountUpdate = (data) => {
  if (!data || !store.businessType || !store.businessId) return

  const accountId = "business_" + store.businessType + "_" + store.businessId

  if (data.accountId === accountId) {
    businessBalance.value = data.balance || 0
  }
}

const purchase = async () => {
  if (!canPurchase.value) return

  try {
    const accountId = "business_" + store.businessType + "_" + store.businessId
    const success = await lua.career_modules_business_businessComputer.purchaseCartItems(
      store.businessId,
      accountId,
      {
        parts: partsItems.value,
        tuning: tuningItems.value
      }
    )

    if (success) {
      store.clearCart()
      store.clearCachesForJob(store.pulledOutVehicle?.jobId)
      expanded.value = false

      if (store.businessId && store.pulledOutVehicle?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            store.businessId,
            store.pulledOutVehicle.vehicleId
          )
          await lua.career_modules_business_businessComputer.initializePreviewVehicle(
            store.businessId,
            store.pulledOutVehicle.vehicleId
          )
        } catch (error) {
        }
      }

      await loadBalance()
      
      await finishAndReturnHome()
    }
  } catch (error) {
  }
}

const finishAndReturnHome = async () => {
  store.vehicleView = null
  store.switchView('home')
}

const cancel = () => {
  if (partsItems.value.length > 0 || tuningItems.value.length > 0) {
    showConfirmModal.value = true
    return
  }

  performCancel()
}

const startHold = () => {
  if (!canPurchase.value || isProcessing.value) return
  
  isHolding.value = true
  holdStartTime.value = Date.now()
  holdProgress.value = 0
  
  const updateProgress = () => {
    if (!isHolding.value) return
    
    const elapsed = Date.now() - holdStartTime.value
    holdProgress.value = Math.min(100, (elapsed / HOLD_DURATION) * 100)
    
    if (holdProgress.value >= 100) {
      isHolding.value = false
      holdProgress.value = 0
      handlePrimaryAction()
    } else {
      holdAnimationId.value = requestAnimationFrame(updateProgress)
    }
  }
  
  holdAnimationId.value = requestAnimationFrame(updateProgress)
}

const endHold = () => {
  if (!isHolding.value) return
  
  isHolding.value = false
  holdProgress.value = 0
  holdStartTime.value = null
  
  if (holdAnimationId.value) {
    cancelAnimationFrame(holdAnimationId.value)
    holdAnimationId.value = null
  }
}

const handlePrimaryAction = async () => {
  if (isProcessing.value || !canPurchase.value) return
  
  isProcessing.value = true
  
  try {
    await purchase()
  } finally {
    isProcessing.value = false
  }
}

const confirmCancel = async () => {
  showConfirmModal.value = false
  await performCancel()
}

const cancelClose = async () => {
  showConfirmModal.value = false

  store.switchView('home')

  if (store.vehicleView) {
    await store.closeVehicleView()
  }
}

const performCancel = async () => {
  if (store.businessId && store.pulledOutVehicle?.vehicleId) {
    try {
      await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
        store.businessId,
        store.pulledOutVehicle.vehicleId
      )

      setTimeout(() => {
        if (store.vehicleView === 'parts') {
          store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
        if (store.vehicleView === 'tuning') {
          store.requestVehicleTuningData(store.pulledOutVehicle.vehicleId)
        }
      }, 100)
    } catch (error) {
    }
  }

  store.clearCart()
  expanded.value = false
}

const handleTabClick = (tabId, event) => {
  // Don't do anything if we're currently editing this tab
  if (editingTabId.value === tabId) {
    return
  }

  // If clicking on active tab, show context menu
  if (tabId === store.activeTabId) {
    // Show context menu positioned under the button
    if (event) {
      showTabMenu(event, tabId)
    }
    return
  }
  // Otherwise switch to the tab
  store.switchTab(tabId)
  hideTabMenu()
}

const showTabMenu = (event, tabId) => {
  if (tabId !== store.activeTabId) return

  // Use the button element from the event
  const button = event.currentTarget || event.target.closest('.tab-button')
  if (!button) return

  const rect = button.getBoundingClientRect()

  tabMenuTabId.value = tabId
  tabMenuX.value = rect.left
  tabMenuY.value = rect.bottom + 4 // Position just below the button with small gap
  tabMenuVisible.value = true
}

const hideTabMenu = () => {
  tabMenuVisible.value = false
  tabMenuTabId.value = null
}

watch(showConfirmModal, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (confirmModalRef.value) {
        controllerNav.pushModal(confirmModalRef.value, cancelClose)
      }
    })
  } else if (confirmModalRef.value) {
    controllerNav.removeModal(confirmModalRef.value)
  }
})

watch(tabMenuVisible, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (tabMenuRef.value) {
        controllerNav.pushModal(tabMenuRef.value, hideTabMenu)
      }
    })
  } else if (tabMenuRef.value) {
    controllerNav.removeModal(tabMenuRef.value)
  }
})

const onRenameFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) { }
}

const onRenameBlur = (tabId) => {
  try { lua.setCEFTyping(false) } catch (_) { }
  finishRenaming(tabId)
}

const startRenaming = async (tabId) => {
  const tab = store.cartTabs.find(t => t.id === tabId)
  if (!tab) return

  editingTabId.value = tabId
  editingTabName.value = tab.name
  hideTabMenu()

  // Wait for Vue to update the DOM, then focus the input
  await nextTick()
  await nextTick() // Double nextTick to ensure DOM is fully updated

  // Use requestAnimationFrame to ensure input is rendered
  requestAnimationFrame(() => {
    if (renameInput.value) {
      renameInput.value.focus()
      renameInput.value.select()
    }
  })
}

const finishRenaming = (tabId) => {
  if (editingTabName.value && editingTabName.value.trim()) {
    store.renameTab(tabId, editingTabName.value)
  }
  editingTabId.value = null
  editingTabName.value = ''
}

const cancelRenaming = () => {
  editingTabId.value = null
  editingTabName.value = ''
}

const clearCurrentTab = async () => {
  // Clear only the current tab's cart (not all tabs)
  store.partsCart = []
  store.tuningCart = []

  // Reset vehicle to original state
  if (store.businessId && store.pulledOutVehicle?.vehicleId) {
    try {
      await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
        store.businessId,
        store.pulledOutVehicle.vehicleId
      )
      // Power/weight will be updated automatically by Lua after vehicle replacement

      // Wait a bit for vehicle replacement to complete, then reload parts tree
      setTimeout(async () => {
        if (store.pulledOutVehicle?.vehicleId) {
          await store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
      }, 300)
    } catch (error) {
    }
  }

  // Note: Tuning UI will reload when tuning data is refreshed after vehicle reset

  // Save the cleared state to the current tab
  store.saveCurrentTabState()
}

watch([() => store.businessType, () => store.businessId], () => {
  loadBalance()
}, { immediate: true })

watch(() => store.vehicleView, (newView) => {
  if (newView !== 'parts' && newView !== 'tuning') {
    expanded.value = false
  }
})

onMounted(async () => {
  // Register event listener for power/weight data (sent automatically by Lua)
  events.on('businessComputer:onVehiclePowerWeight', handlePowerWeightData)
  // Update dyno upgrade status when skill trees are updated
  events.on('businessSkillTree:onTreesUpdated', () => {
    store.updateDynoUpgradeStatus()
  })
  // Initial update
  store.updateDynoUpgradeStatus()

  events.on('bank:onAccountUpdate', handleAccountUpdate)
  loadBalance()

  // Close context menu when clicking outside
  document.addEventListener('click', hideTabMenu)

  // Don't initialize cart here - let switchVehicleView handle it
  // This prevents clearing cart when switching between parts/tuning views
})

// Track if we've initialized for the current job to prevent re-initialization when switching views
const initializedJobId = ref(null)

watch(() => store.pulledOutVehicle, async (newVehicle, oldVehicle) => {
  const newJobKey = newVehicle ? normalizeJobId(newVehicle.jobId) : null
  const oldJobKey = oldVehicle ? normalizeJobId(oldVehicle.jobId) : null

  if (newVehicle &&
    newJobKey !== initializedJobId.value &&
    (store.vehicleView === 'parts' || store.vehicleView === 'tuning')) {
    // Delay until UI animation completes (600ms) to avoid vehicle spawning during animation
    setTimeout(async () => {
      // Double-check we're still in the vehicle view and vehicle is still pulled out
      if (newVehicle &&
        newJobKey === normalizeJobId(store.pulledOutVehicle?.jobId) &&
        (store.vehicleView === 'parts' || store.vehicleView === 'tuning')) {
        await store.initializeCartForVehicle()
        initializedJobId.value = newJobKey
      }
    }, oldVehicle ? 100 : 600)
  }

  // Reset initialized flag when vehicle is put away or switched
  if (!newVehicle && oldVehicle) {
    initializedJobId.value = null
  } else if (oldVehicle && newVehicle && newJobKey !== oldJobKey) {
    initializedJobId.value = null
  }
}, { immediate: true })

onBeforeUnmount(() => {
  // Clean up event listeners
  events.off('businessComputer:onVehiclePowerWeight', handlePowerWeightData)
  events.off('businessSkillTree:onTreesUpdated', store.updateDynoUpgradeStatus)
  events.off('bank:onAccountUpdate', handleAccountUpdate)
  document.removeEventListener('click', hideTabMenu)
})
</script>

<style scoped lang="scss">
.business-shopping-cart {
  position: fixed;
  bottom: 2em;
  right: 2em;
  width: 28em;
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.4);
  border-radius: 0.5em;
  z-index: 2000;
  display: flex;
  flex-direction: column;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);

  &.expanded {
    height: 40em;
  }
}

.cart-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1em 1.5em;
  border-bottom: 2px solid rgba(245, 73, 0, 0.4);

  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125em;
    font-weight: 600;
  }

  .expand-toggle {
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.6);
    cursor: pointer;
    padding: 0.25em;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s;

    &:hover {
      color: rgba(245, 73, 0, 1);
    }

    svg {
      width: 20px;
      height: 20px;
    }

    .chevron-icon {
      transition: transform 0.3s ease;

      &.rotated {
        transform: rotate(180deg);
      }
    }
  }
}

.cart-collapsed {
  padding: 1em 1.5em;

  .cart-summary {
    display: flex;
    justify-content: space-between;
    align-items: center;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.875em;

    .summary-total {
      color: rgba(245, 73, 0, 1);
      font-weight: 600;
      font-size: 1.125em;
    }
  }
}

.cart-main {
  display: flex;
  flex-direction: column;
  flex: 1;
  overflow: hidden;
}

.cart-tabs {
  padding: 0.75em 1em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.5);

  .tabs-list {
    display: flex;
    gap: 0.5em;
    align-items: center;
    overflow-x: auto;
    position: relative;

    &::-webkit-scrollbar {
      height: 4px;
    }

    &::-webkit-scrollbar-track {
      background: rgba(0, 0, 0, 0.2);
    }

    &::-webkit-scrollbar-thumb {
      background: rgba(255, 255, 255, 0.1);
      border-radius: 2px;
    }
  }

  .tab-wrapper {
    position: relative;
  }

  .tab-button {
    display: flex;
    align-items: center;
    gap: 0.5em;
    padding: 0.5em 0.75em;
    background: rgba(55, 55, 55, 1);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.25em;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.875em;
    cursor: pointer;
    transition: all 0.2s;
    white-space: nowrap;
    flex-shrink: 0;

    &:hover {
      background: rgba(75, 75, 75, 1);
      border-color: rgba(245, 73, 0, 0.5);
    }

    &.active {
      background: rgba(245, 73, 0, 1);
      border-color: rgba(245, 73, 0, 1);
      color: white;
    }

    .tab-close {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 0.125em;
      background: transparent;
      border: none;
      color: inherit;
      cursor: pointer;
      opacity: 0.6;
      transition: opacity 0.2s;
      flex-shrink: 0;

      &:hover {
        opacity: 1;
      }

      svg {
        width: 12px;
        height: 12px;
      }
    }
  }

  .tab-rename-input {
    flex: 1;
    min-width: 0;
    padding: 0;
    background: transparent;
    border: none;
    border-radius: 0.25em;
    color: inherit;
    font-size: inherit;
    font-family: inherit;
    font-weight: inherit;
    outline: none;
    text-align: left;

    &::placeholder {
      color: rgba(255, 255, 255, 0.5);
    }

    &:focus {
      outline: none;
    }
  }

  .tab-button.active .tab-rename-input {
    color: white;
  }


  .tab-add {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0.5em;
    background: rgba(55, 55, 55, 1);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.25em;
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;

    &:hover {
      background: rgba(75, 75, 75, 1);
      border-color: rgba(245, 73, 0, 0.5);
      color: rgba(245, 73, 0, 1);
    }

    svg {
      width: 16px;
      height: 16px;
    }
  }
}

.cart-collapse-enter-active,
.cart-collapse-leave-active {
  transition: max-height 0.3s ease, opacity 0.3s ease;
  overflow: hidden;
}

.cart-collapse-enter-from {
  max-height: 0;
  opacity: 0;
}

.cart-collapse-enter-to {
  max-height: 40em;
  opacity: 1;
}

.cart-collapse-leave-from {
  max-height: 40em;
  opacity: 1;
}

.cart-collapse-leave-to {
  max-height: 0;
  opacity: 0;
}

.cart-list {
  flex: 1;
  overflow-y: auto;
  padding: 1em;

  &::-webkit-scrollbar {
    width: 8px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 4px;

    &:hover {
      background: rgba(255, 255, 255, 0.15);
    }
  }
}

.empty-cart {
  padding: 2em;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.cart-section {
  margin-bottom: 1em;

  &:last-child {
    margin-bottom: 0;
  }
}

.cart-section-header {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75em 1em;
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(245, 73, 0, 0.3);
  border-radius: 0.375em;
  cursor: pointer;
  transition: all 0.2s;
  margin-bottom: 0.5em;

  &:hover {
    background: rgba(23, 23, 23, 0.7);
    border-color: rgba(245, 73, 0, 0.5);
  }

  .section-header-content {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 0.25em;
    flex: 1;

    h3 {
      margin: 0;
      color: rgba(245, 73, 0, 1);
      font-weight: 600;
      font-size: 0.875em;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    .section-subtotal {
      color: rgba(255, 255, 255, 0.7);
      font-size: 0.75em;
      font-family: 'Courier New', monospace;
    }
  }

  .section-chevron {
    color: rgba(255, 255, 255, 0.4);
    flex-shrink: 0;
    transition: transform 0.3s ease;

    &.rotated {
      transform: rotate(180deg);
    }
  }
}

.section-content {
  overflow: hidden;
}

.section-collapse-enter-active,
.section-collapse-leave-active {
  transition: max-height 0.3s ease, opacity 0.3s ease;
  overflow: hidden;
}

.section-collapse-enter-from {
  max-height: 0;
  opacity: 0;
}

.section-collapse-enter-to {
  max-height: 2000px;
  opacity: 1;
}

.section-collapse-leave-from {
  max-height: 2000px;
  opacity: 1;
}

.section-collapse-leave-to {
  max-height: 0;
  opacity: 0;
}

.cart-item {
  display: flex;
  align-items: center;
  gap: 1em;
  padding: 0.75em 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);

  .remove-button {
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    padding: 0.25em;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s;
    flex-shrink: 0;

    &:hover {
      color: rgba(255, 0, 0, 0.8);
    }

    svg {
      width: 16px;
      height: 16px;
    }
  }

  .remove-button-spacer {
    width: 24px;
    flex-shrink: 0;
  }

  &.cart-item-category {
    border-bottom: 1px solid rgba(245, 73, 0, 0.3);
    padding-top: 1em;
    padding-bottom: 0.5em;

    &:first-child {
      padding-top: 0;
    }
  }

  &.cart-item-subcategory {
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    padding-top: 0.5em;
    padding-bottom: 0.5em;
  }

  &.cart-item-variable {
    padding-top: 0.25em;
    padding-bottom: 0.25em;
  }

  .item-info {
    flex: 1;
    min-width: 0;

    .item-name {
      color: rgba(255, 255, 255, 0.9);
      font-size: 0.875em;
      font-weight: 500;
      margin-bottom: 0.25em;

      &.item-name-header {
        color: rgba(245, 73, 0, 1);
        font-weight: 600;
        font-size: 0.9375em;
        margin-bottom: 0;
      }
    }

    .item-slot {
      color: rgba(255, 255, 255, 0.5);
      font-size: 0.75em;
    }
  }

  .item-price {
    color: rgba(245, 73, 0, 1);
    font-weight: 600;
    font-size: 0.875em;
    flex-shrink: 0;
    font-family: 'Courier New', monospace;
  }
}

.cart-footer {
  padding: 1em 1.5em;
  border-top: 2px solid rgba(245, 73, 0, 0.4);
  background: rgba(23, 23, 23, 0.5);

  .footer-details {
    overflow: hidden;
  }

  .power-weight-stats {
    margin-bottom: 1em;
    background: rgba(0, 0, 0, 0.3);
    border-radius: 0.25em;
    padding: 0.75em;
    position: relative;

    .performance-section-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 0.75em;

      .section-title {
        color: rgba(255, 255, 255, 0.9);
        font-weight: 600;
        font-size: 0.9em;
      }

      .view-toggles {
        display: flex;
        background: rgba(0, 0, 0, 0.5);
        border-radius: 4px;
        padding: 2px;
        gap: 2px;

        .toggle-btn {
          background: transparent;
          border: none;
          color: rgba(255, 255, 255, 0.5);
          font-size: 0.75em;
          padding: 2px 8px;
          cursor: pointer;
          border-radius: 2px;
          transition: all 0.2s;

          &:hover {
            color: rgba(255, 255, 255, 0.8);
          }

          &.active {
            background: rgba(245, 73, 0, 0.2);
            color: #F54900;
          }
        }
      }
    }

    .dyno-container {
      height: 140px;
      width: 100%;
      position: relative;
      background: rgba(0, 0, 0, 0.2);
      border-radius: 4px;
      overflow: hidden;

      .dyno-graph {
        display: block;
        cursor: crosshair;
      }
    }

    .dyno-placeholder {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.5em;
      color: rgba(255, 255, 255, 0.7);
      font-size: 0.875em;
      padding: 0.5em 0.25em;

      p {
        margin: 0;
      }
    }

    .stats-container {
      display: flex;
      flex-direction: column;
      gap: 0.5em;
    }

    .stat-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 0.875em;

      .stat-label-col {
        color: rgba(255, 255, 255, 0.6);
        width: 100px;
      }

      .stat-value-col {
        color: rgba(255, 255, 255, 0.9);
        font-family: 'Courier New', monospace;
        width: 80px;
        text-align: right;
      }

      .stat-arrow-col {
        color: rgba(245, 73, 0, 0.8);
        display: flex;
        align-items: center;
        justify-content: center;
        width: 24px;

        svg {
          width: 16px;
          height: 16px;
        }
      }
    }
  }

  .stat-change {
    padding: 0.125em 0.5em;
    border-radius: 0.25em;
    font-size: 0.875em;
    font-weight: 600;
    font-family: 'Courier New', monospace;

    &.positive {
      background: rgba(0, 200, 0, 0.2);
      color: rgba(0, 255, 0, 0.9);
    }

    &.negative {
      background: rgba(200, 0, 0, 0.2);
      color: rgba(255, 100, 100, 0.9);
    }
  }

  .cart-summary-breakdown {
    margin-bottom: 0.75em;
    padding-bottom: 0.75em;
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);

    .summary-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 0.25em;
      color: rgba(255, 255, 255, 0.7);
      font-size: 0.875em;

      &:last-child {
        margin-bottom: 0;
      }

      span:last-child {
        font-family: 'Courier New', monospace;
        color: rgba(255, 255, 255, 0.8);
      }
    }
  }

  .cart-total-wrapper {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 1em;
    gap: 0.5em;
  }

  .cart-total {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex: 1;
    color: rgba(255, 255, 255, 0.9);
    font-size: 1em;

    .total-amount {
      color: rgba(245, 73, 0, 1);
      font-weight: 600;
      font-size: 1.25em;
      font-family: 'Courier New', monospace;
    }
  }

  .footer-toggle {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 2em;
    height: 2em;
    padding: 0;
    background: transparent;
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 0.25em;
    color: rgba(255, 255, 255, 0.6);
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;

    &:hover {
      color: rgba(245, 73, 0, 1);
      border-color: rgba(245, 73, 0, 0.6);
      background: rgba(245, 73, 0, 0.1);
    }

    svg {
      width: 16px;
      height: 16px;
      transition: transform 0.2s ease;

      &.rotated {
        transform: rotate(180deg);
      }
    }
  }

  .cart-buttons {
    display: flex;
    gap: 0.5em;
  }
}

.btn {
  flex: 1;
  padding: 0.75em 1em;
  border-radius: 0.375em;
  font-size: 0.875em;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;

  &.btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;

    &:hover:not(:disabled) {
      background: rgba(245, 73, 0, 0.9);
    }

    &:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  }

  &.btn-hold {
    position: relative;
    overflow: hidden;
    user-select: none;
    -webkit-user-select: none;

    .hold-progress {
      position: absolute;
      top: 0;
      left: 0;
      height: 100%;
      background: rgba(255, 255, 255, 0.25);
      transition: width 0.05s linear;
      pointer-events: none;
      z-index: 0;
    }

    .btn-label {
      position: relative;
      z-index: 1;
    }

    &.is-holding {
      transform: scale(0.98);
      box-shadow: 0 0 15px rgba(245, 73, 0, 0.5);
    }

    &.is-processing {
      opacity: 0.7;
      cursor: wait;
    }

    &:not(:disabled):active {
      transform: scale(0.98);
    }
  }

  &.btn-secondary {
    background: rgba(55, 55, 55, 1);
    color: white;

    &:hover {
      background: rgba(75, 75, 75, 1);
    }
  }
}

.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  backdrop-filter: blur(4px);
}

.modal-content {
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.5em;
  padding: 2em;
  max-width: 30em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);

  h2 {
    margin: 0 0 1em 0;
    color: white;
    font-size: 1.5em;
    font-weight: 600;
  }

  p {
    margin: 0 0 2em 0;
    color: rgba(255, 255, 255, 0.8);
    font-size: 1em;
    line-height: 1.5;
  }

  .modal-buttons {
    display: flex;
    gap: 1em;
    justify-content: flex-end;
  }

  .btn {
    padding: 0.75em 1.5em;
    border: none;
    border-radius: 0.25em;
    font-size: 0.875em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;

    &.btn-secondary {
      background: rgba(255, 255, 255, 0.1);
      color: rgba(255, 255, 255, 0.9);

      &:hover {
        background: rgba(255, 255, 255, 0.15);
      }
    }

    &.btn-primary {
      background: #F54900;
      color: white;

      &:hover {
        background: #ff5a14;
        box-shadow: 0 0 10px rgba(245, 73, 0, 0.4);
      }
    }
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;

  .modal-content {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .modal-content {
    transform: scale(0.95);
    opacity: 0;
  }
}

.tab-menu-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: transparent;
  z-index: 9999;
  pointer-events: auto;
}

.tab-menu-modal {
  position: fixed;
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.5em;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  z-index: 10000;
  min-width: 180px;
  padding: 0.5em;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  backdrop-filter: blur(4px);

  .menu-item {
    display: flex;
    align-items: center;
    gap: 0.75em;
    padding: 0.75em 1em;
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.875em;
    cursor: pointer;
    text-align: left;
    transition: all 0.2s;
    border-radius: 0.375em;

    &:hover {
      background: rgba(245, 73, 0, 0.3);
      color: white;
    }

    &:active {
      background: rgba(245, 73, 0, 0.4);
    }

    svg {
      width: 16px;
      height: 16px;
      flex-shrink: 0;
      stroke-width: 2;
    }
  }
}

.dropdown-fade-enter-active,
.dropdown-fade-leave-active {
  transition: opacity 0.15s ease;

  .tab-menu-modal {
    transition: transform 0.15s ease, opacity 0.15s ease;
  }
}

.dropdown-fade-enter-from,
.dropdown-fade-leave-to {
  opacity: 0;

  .tab-menu-modal {
    transform: translateY(-8px) scale(0.95);
    opacity: 0;
  }
}

.footer-collapse-enter-active,
.footer-collapse-leave-active {
  transition: all 0.3s ease;
  overflow: hidden;
}

.footer-collapse-enter-from,
.footer-collapse-leave-to {
  max-height: 0;
  opacity: 0;
  margin-bottom: 0;
  padding-bottom: 0;
}

.footer-collapse-enter-to,
.footer-collapse-leave-from {
  max-height: 500px;
  opacity: 1;
}
</style>
