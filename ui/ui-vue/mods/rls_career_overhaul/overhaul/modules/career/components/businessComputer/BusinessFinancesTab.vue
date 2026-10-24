<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div ref="rootRef" class="rls-house finances-tab">
    <header class="tab-header">
      <h2 class="block-title">Finances</h2>
      <p class="hint">Overview of your business financial status and operating costs.</p>
    </header>

    <div v-if="financesData && !loading" class="finances-content">
      <section v-if="!operatingCosts.solarPowerActive" class="fin-block operating-costs-section">
        <div class="block-head">
          <span class="caption">Operating costs</span>
          <span class="hint">Next payment in {{ timeUntilNextPayment }}</span>
        </div>
        <div class="sheet lines">
          <button
            type="button"
            class="line cost-toggle"
            :class="{ open: showBreakdown }"
            :aria-expanded="showBreakdown"
            @click="showBreakdown = !showBreakdown"
          >
            <span class="line-key">Current cost <small>per 30 min</small></span>
            <span class="line-end">
              <strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.total) }}</strong>
              <svg class="chev" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
            </span>
          </button>
          <template v-if="showBreakdown">
            <div class="line sub">
              <span class="line-key">Base lift</span>
              <span class="money">+<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.baseLift) }}</span>
            </div>
            <div class="line sub" v-if="operatingCosts.additionalLifts > 0">
              <span class="line-key">Additional lifts <small>{{ operatingCosts.additionalLifts }}</small></span>
              <span class="money">+<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.additionalLiftsCost) }}</span>
            </div>
            <div class="line sub" v-if="operatingCosts.techs > 0">
              <span class="line-key">Techs <small>{{ operatingCosts.techs }}</small></span>
              <span class="money">+<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.techsCost) }}</span>
            </div>
            <div class="line sub" v-if="operatingCosts.manager > 0">
              <span class="line-key">Manager</span>
              <span class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.managerCost) }}</span>
            </div>
            <div class="line sub" v-if="operatingCosts.generalManager > 0">
              <span class="line-key">General manager</span>
              <span class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.generalManagerCost) }}</span>
            </div>
          </template>
        </div>
      </section>

      <section class="panel account-history-section" v-if="chartData.length > 0">
        <div class="account-head">
          <div class="account-copy">
            <span class="caption">Business account</span>
            <div class="account-figures">
              <strong class="balance-value" :class="{ negative: accountBalance < 0 }">
                {{ moneySign(accountBalance) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(accountBalance) }}
              </strong>
              <span class="balance-change" :class="{ negative: periodChange < 0, positive: periodChange > 0 }">
                {{ periodChange >= 0 ? '+' : '-' }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(periodChange) }}
              </span>
            </div>
          </div>
          <div class="seg bar time-scale-buttons" role="group" aria-label="Time range">
            <button
              v-for="scale in timeScales"
              :key="scale.value"
              type="button"
              :class="{ active: selectedTimeScale === scale.value }"
              @click.stop="selectedTimeScale = scale.value"
            >
              {{ scale.label }}
            </button>
          </div>
        </div>

        <div class="chart-container" bng-nav-item tabindex="0" aria-label="Account history" v-bng-on-ui-nav-focus.repeat="stepChart" @blur="hideTooltip" @mousemove="handleChartHover" @mouseleave="hideTooltip">
          <svg class="chart-svg" :viewBox="`0 0 ${chartWidth} ${chartHeight}`" preserveAspectRatio="none" aria-hidden="true">
            <defs>
              <linearGradient id="bizFinancesChartFill" x1="0%" y1="0%" x2="0%" y2="100%">
                <stop offset="0%" stop-color="#ffb27a" stop-opacity="0.16" />
                <stop offset="100%" stop-color="#ffb27a" stop-opacity="0" />
              </linearGradient>
            </defs>

            <g class="chart-grid">
              <line v-for="i in 5" :key="`grid-${i}`"
                :x1="0"
                :y1="chartHeight - chartBottomPadding - ((i - 1) * (chartHeight - chartPadding - chartBottomPadding) / 4)"
                :x2="chartWidth"
                :y2="chartHeight - chartBottomPadding - ((i - 1) * (chartHeight - chartPadding - chartBottomPadding) / 4)"
                stroke="rgba(255,255,255,0.05)"
                stroke-width="1"
                vector-effect="non-scaling-stroke"
              />
            </g>

            <line
              v-if="zeroLineY !== null"
              :x1="0"
              :y1="zeroLineY"
              :x2="chartWidth"
              :y2="zeroLineY"
              stroke="rgba(255,255,255,0.22)"
              stroke-width="1"
              stroke-dasharray="4,4"
              vector-effect="non-scaling-stroke"
              class="zero-line"
            />

            <path
              :d="chartPath"
              fill="url(#bizFinancesChartFill)"
              class="chart-area"
            />

            <path
              :d="chartLinePath"
              fill="none"
              stroke="#ffb27a"
              stroke-width="2"
              vector-effect="non-scaling-stroke"
              class="chart-line"
            />

            <line
              v-if="hoveredIndex !== null && chartData[hoveredIndex]"
              :x1="chartData[hoveredIndex].x"
              :y1="chartPadding"
              :x2="chartData[hoveredIndex].x"
              :y2="chartHeight - chartBottomPadding"
              stroke="rgba(255,255,255,0.25)"
              stroke-width="1"
              stroke-dasharray="4,4"
              vector-effect="non-scaling-stroke"
            />
          </svg>

          <!-- hover marker in HTML so it stays round on the stretched chart -->
          <span
            v-if="hoveredIndex !== null && chartData[hoveredIndex]"
            class="chart-marker"
            :style="{
              left: (chartData[hoveredIndex].x / chartWidth * 100) + '%',
              top: (chartData[hoveredIndex].y / chartHeight * 100) + '%'
            }"
            aria-hidden="true"
          ></span>

          <div v-if="tooltip.visible" class="chart-tooltip" :style="{ left: tooltip.x + 'px', top: tooltip.y + 'px' }">
            <div class="tooltip-balance" :class="{ negative: tooltip.balance < 0 }">{{ moneySign(tooltip.balance) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(tooltip.balance) }}</div>
            <div class="tooltip-date">{{ tooltip.date }}</div>
          </div>
        </div>
      </section>

      <section class="fin-block" v-if="businessLoans.length > 0">
        <span class="caption">Business loans</span>
        <div class="loans-list">
          <div v-for="loan in businessLoans" :key="loan.id" class="sheet lines loan-card">
            <div class="line loan-head">
              <strong class="loan-org">{{ loan.orgName || loan.orgId }}</strong>
              <span class="pill">{{ (loan.rate * 100).toFixed(1) }}%</span>
            </div>
            <div class="line">
              <span class="line-key">Principal outstanding</span>
              <span class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(loan.principalOutstanding) }}</span>
            </div>
            <div class="line">
              <span class="line-key">Next payment</span>
              <span class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(loan.nextPaymentDue) }}</span>
            </div>
            <div class="line">
              <span class="line-key">Payments remaining</span>
              <span class="line-value">{{ loan.paymentsRemaining }}</span>
            </div>
          </div>
        </div>
      </section>

      <section class="panel sale-section">
        <div class="sale-header">
          <div class="sale-copy">
            <strong>Sell Business</strong>
            <p class="hint">Liquidate this business and close its account.</p>
          </div>
          <HouseButton
            variant="quiet-danger"
            :aria-disabled="saleLoading" data-fk="sell-business"
            @click="openSaleModal"
          >
            {{ saleLoading ? 'Quoting...' : 'Sell Business' }}
          </HouseButton>
        </div>
      </section>
    </div>

    <div v-else class="empty loading-state">
      <p>{{ loading ? 'Loading financial data...' : 'No financial data available' }}</p>
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showSaleModal" class="rls-house sale-modal-overlay" @click.self="closeSaleModal">
          <div class="modal sale-modal" v-bng-scoped-nav="saleModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="onSaleModalBack">
            <h3>Sell {{ saleQuote?.businessName || 'Business' }}</h3>
            <p class="sale-warning">
              Vehicles, parts, jobs, staff, kits, offers, and business progress will be liquidated or reset.
            </p>

            <div class="sheet lines sale-summary" v-if="saleQuote">
              <div class="line">
                <span class="line-key">Base resale</span>
                <strong class="money">{{ moneySign(saleQuote.baseResaleValue) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(saleQuote.baseResaleValue || 0) }}</strong>
              </div>
              <div class="line">
                <span class="line-key">Asset liquidation</span>
                <strong class="money">{{ moneySign(saleQuote.assetLiquidationValue) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(saleQuote.assetLiquidationValue || 0) }}</strong>
              </div>
              <div class="line">
                <span class="line-key">Upgrade liquidation</span>
                <strong class="money">{{ moneySign(saleQuote.upgradeLiquidationValue) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(saleQuote.upgradeLiquidationValue || 0) }}</strong>
              </div>
              <div class="line">
                <span class="line-key">Account balance</span>
                <strong class="money" :class="{ negative: (saleQuote.accountBalance || 0) < 0 }">{{ moneySign(saleQuote.accountBalance) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(saleQuote.accountBalance || 0) }}</strong>
              </div>
              <div class="line">
                <span class="line-key">Loan payoff</span>
                <strong class="negative">-<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(saleQuote.loanPayoffAmount || 0) }}</strong>
              </div>
              <div class="line">
                <span class="line-key">Debt converted</span>
                <strong class="money" :class="{ negative: (saleQuote.convertedDebt || 0) > 0 }">{{ moneySign(saleQuote.convertedDebt) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(saleQuote.convertedDebt || 0) }}</strong>
              </div>
              <div class="line total">
                <span class="line-key">Net payout</span>
                <strong class="money" :class="{ negative: (saleQuote.netPayout || 0) < 0 }">{{ moneySign(saleQuote.netPayout) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(saleQuote.netPayout || 0) }}</strong>
              </div>
            </div>

            <div class="actions sale-actions">
              <HouseButton
                variant="quiet"
                :aria-disabled="saleSubmitting"
                bng-scoped-nav-autofocus
                @click="closeSaleModal"
              >Cancel</HouseButton>
              <HouseButton
                variant="danger"
                :aria-disabled="saleSubmitting"
                @click="confirmSale"
              >
                {{ saleSubmitting ? 'Selling...' : 'Confirm Sale' }}
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
import { useNowSeconds } from "../../composables/useNowSeconds.js"
import { computed, ref, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { useBridge, lua } from '@/bridge'
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { formatMoneyCompact, moneySign, formatTime } from "../../utils/businessUtils"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { vBngOnUiNavFocus, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"

const sessionStore = useBusinessSessionStore()

const props = defineProps({
  data: {
    type: Object,
    default: () => ({})
  }
})

const { events } = useBridge()
const financesData = ref(null)
const loading = ref(true)
const showBreakdown = ref(false)
const operatingCosts = computed(() => financesData.value?.operatingCosts || {})
const accountBalance = computed(() => financesData.value?.account?.balance || 0)
const transactions = computed(() => financesData.value?.transactions || [])
const businessLoans = computed(() => financesData.value?.loans || [])
const operatingCostTimer = computed(() => financesData.value?.operatingCostTimer || null)
const showSaleModal = ref(false)
const saleQuote = ref(null)
const rootRef = ref(null)
const { remember, restore } = useActionFocus(rootRef)
const saleLoading = ref(false)
const saleSubmitting = ref(false)
// destructive: the modal opens on Cancel; B cancels unless the sale is already being submitted
const saleModalScope = bcModalScope("business-sale")
const onSaleModalBack = () => {
  if (!saleSubmitting.value) closeSaleModal()
  return false
}

let lastTimerUpdateTime = ref(null)
let lastRemainingTime = ref(null)
const nowSeconds = useNowSeconds()

watch(operatingCostTimer, (timer) => {
  if (timer && timer.remainingTime !== null && timer.remainingTime !== undefined) {
    const now = Date.now()
    lastTimerUpdateTime.value = now
    lastRemainingTime.value = timer.remainingTime
  }
}, { immediate: true })

const timeUntilNextPayment = computed(() => {
  const timer = operatingCostTimer.value
  const currentTime = nowSeconds.value * 1000
  
  if (!timer || timer.remainingTime === null || timer.remainingTime === undefined) {
    return 'Calculating...'
  }
  
  if (lastTimerUpdateTime.value === null || lastRemainingTime.value === null) {
    return 'Calculating...'
  }
  
  const elapsedSinceUpdate = (currentTime - lastTimerUpdateTime.value) / 1000
  const currentRemaining = Math.max(0, lastRemainingTime.value - elapsedSinceUpdate)
  
  if (currentRemaining <= 0) {
    return 'Calculating...'
  }
  
  return formatTime(Math.floor(currentRemaining))
})

const requestFinancesData = async () => {
  if (!props.data?.businessId || !props.data?.businessType) {
    return
  }
  
  loading.value = true
  try {
    await sessionStore.requestFinancesData(props.data.businessType, props.data.businessId)
  } catch (error) {
    loading.value = false
  }
}

const openSaleModal = async () => {
  if (!props.data?.businessId || !props.data?.businessType || saleLoading.value) return
  remember()
  saleLoading.value = true
  try {
    const quote = await lua.overhaul_career_business_manager.requestBusinessSaleData(
      props.data.businessType,
      props.data.businessId
    )
    if (quote?.success) {
      saleQuote.value = quote
      showSaleModal.value = true
    }
  } finally {
    saleLoading.value = false
    if (!showSaleModal.value) await restore()
  }
}

const closeSaleModal = () => {
  if (saleSubmitting.value) return
  showSaleModal.value = false
  saleQuote.value = null
}

const confirmSale = async () => {
  if (!props.data?.businessId || !props.data?.businessType || saleSubmitting.value) return
  saleSubmitting.value = true
  try {
    await lua.overhaul_career_business_manager.sellBusiness(
      props.data.businessType,
      props.data.businessId
    )
    showSaleModal.value = false
  } finally {
    saleSubmitting.value = false
  }
}

const handleFinancesData = (data) => {
  if (!data || !data.success) {
    loading.value = false
    return
  }
  
  if (String(data.businessId) !== String(props.data?.businessId)) {
    return
  }
  
  financesData.value = data.finances
  
  loading.value = false
}

const handleAccountUpdate = (data) => {
  if (!data || !props.data?.businessType || !props.data?.businessId) return
  
  const accountId = "business_" + props.data.businessType + "_" + props.data.businessId
  
  if (data.accountId === accountId) {
    requestFinancesData()
  }
}

onMounted(() => {
  events.on('businessComputer:onFinancesData', handleFinancesData)
  events.on('bank:onOverhaulAccountUpdate', handleAccountUpdate)
  if (props.data?.businessId && props.data?.businessType) {
    requestFinancesData()
  }
  
})

onUnmounted(() => {
  events.off('businessComputer:onFinancesData', handleFinancesData)
  events.off('bank:onOverhaulAccountUpdate', handleAccountUpdate)
})

const chartWidth = 800
const chartHeight = 300
// plot insets in viewBox units (the range toggles moved out of the chart, so the bottom inset is small)
const chartPadding = 28
const chartBottomPadding = 20

const selectedTimeScale = ref('all')
const timeScales = [
  { label: 'All Time', value: 'all' },
  { label: '24hrs', value: '24h' },
  { label: '3hrs', value: '3h' },
  { label: '1hr', value: '1h' }
]

const hoveredIndex = ref(null)
const tooltip = ref({
  visible: false,
  x: 0,
  y: 0,
  date: '',
  balance: 0
})

const filteredHistoryPoints = computed(() => {
  if (!transactions.value || transactions.value.length === 0) {
    return [{
      balance: accountBalance.value,
      timestamp: Date.now() / 1000,
      date: new Date()
    }]
  }

  const sortedTransactions = [...transactions.value].sort((a, b) => {
    return (a.timestamp || 0) - (b.timestamp || 0)
  })

  let initialBalance = accountBalance.value
  for (let i = sortedTransactions.length - 1; i >= 0; i--) {
    const trans = sortedTransactions[i]
    const amount = trans.amount || 0
    initialBalance -= amount
  }

  let runningBalance = initialBalance
  const historyPoints = []
  
  if (sortedTransactions.length > 0) {
    historyPoints.push({
      balance: initialBalance,
      timestamp: sortedTransactions[0].timestamp,
      date: new Date((sortedTransactions[0].timestamp || 0) * 1000)
    })
  }
  
  for (let i = 0; i < sortedTransactions.length; i++) {
    const trans = sortedTransactions[i]
    const amount = trans.amount || 0
    runningBalance += amount
    
    historyPoints.push({
      balance: runningBalance,
      timestamp: trans.timestamp,
      date: new Date((trans.timestamp || 0) * 1000)
    })
  }

  historyPoints.push({
    balance: accountBalance.value,
    timestamp: Date.now() / 1000,
    date: new Date()
  })

  const now = Date.now() / 1000
  let cutoffTime = 0

  if (selectedTimeScale.value === '1h') {
    cutoffTime = now - 3600
  } else if (selectedTimeScale.value === '3h') {
    cutoffTime = now - 10800
  } else if (selectedTimeScale.value === '24h') {
    cutoffTime = now - 86400
  }

  if (cutoffTime > 0) {
    return historyPoints.filter(point => point.timestamp >= cutoffTime)
  }

  return historyPoints
})

const periodChange = computed(() => {
  if (filteredHistoryPoints.value.length === 0) return 0
  const firstBalance = filteredHistoryPoints.value[0].balance
  const lastBalance = filteredHistoryPoints.value[filteredHistoryPoints.value.length - 1].balance
  return lastBalance - firstBalance
})

const chartData = computed(() => {
  const historyPoints = filteredHistoryPoints.value

  if (historyPoints.length === 0) {
    return [{
      x: chartWidth,
      y: chartHeight - chartBottomPadding - ((chartHeight - chartPadding - chartBottomPadding) * 0.5),
      balance: accountBalance.value,
      date: 'Now',
      timestamp: Date.now() / 1000
    }]
  }

  const firstTimestamp = historyPoints[0].timestamp
  const lastTimestamp = historyPoints[historyPoints.length - 1].timestamp
  const timeRange = lastTimestamp - firstTimestamp || 1
  
  const balances = historyPoints.map(p => p.balance)
  const minBalance = Math.min(...balances)
  const maxBalance = Math.max(...balances)
  const range = maxBalance - minBalance || 1
  const availableHeight = chartHeight - chartPadding - chartBottomPadding

  const points = historyPoints.map((point) => {
    const timeOffset = point.timestamp - firstTimestamp
    const x = (timeOffset / timeRange) * chartWidth
    
    const normalizedBalance = (point.balance - minBalance) / range
    
    const y = chartHeight - chartBottomPadding - (normalizedBalance * availableHeight)
    
    return {
      x,
      y,
      balance: point.balance,
      date: point.date.toLocaleDateString() + ' ' + point.date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
      timestamp: point.timestamp
    }
  })

  return points
})

const zeroLineY = computed(() => {
  const historyPoints = filteredHistoryPoints.value
  if (historyPoints.length === 0) return null

  const balances = historyPoints.map(p => p.balance)
  const minBalance = Math.min(...balances)
  const maxBalance = Math.max(...balances)
  const range = maxBalance - minBalance || 1
  const availableHeight = chartHeight - chartPadding - chartBottomPadding

  if (minBalance > 0 || maxBalance < 0) return null

  const normalizedZero = (0 - minBalance) / range
  return chartHeight - chartBottomPadding - (normalizedZero * availableHeight)
})

const chartPath = computed(() => {
  if (chartData.value.length === 0) return ''
  
  const points = chartData.value
  const bottomY = chartHeight - chartBottomPadding
  let path = `M ${points[0].x} ${bottomY}`
  path += ` L ${points[0].x} ${points[0].y}`
  
  if (points.length === 1) {
    path += ` L ${points[0].x} ${bottomY} Z`
    return path
  }
  
  for (let i = 0; i < points.length - 1; i++) {
    const p1 = points[i]
    const p2 = points[i + 1]
    
    const dx = p2.x - p1.x
    const dy = p2.y - p1.y
    
    const tension = 0.3
    const cp1x = p1.x + dx * tension
    const cp1y = p1.y + dy * tension
    const cp2x = p2.x - dx * tension
    const cp2y = p2.y - dy * tension
    
    path += ` C ${cp1x} ${cp1y}, ${cp2x} ${cp2y}, ${p2.x} ${p2.y}`
  }
  
  path += ` L ${points[points.length - 1].x} ${bottomY} Z`
  return path
})

const chartLinePath = computed(() => {
  if (chartData.value.length === 0) return ''
  
  const points = chartData.value
  
  if (points.length === 1) {
    return `M ${points[0].x} ${points[0].y}`
  }
  
  let path = `M ${points[0].x} ${points[0].y}`
  
  for (let i = 0; i < points.length - 1; i++) {
    const p1 = points[i]
    const p2 = points[i + 1]
    
    const dx = p2.x - p1.x
    const dy = p2.y - p1.y
    
    const tension = 0.3
    const cp1x = p1.x + dx * tension
    const cp1y = p1.y + dy * tension
    const cp2x = p2.x - dx * tension
    const cp2y = p2.y - dy * tension
    
    path += ` C ${cp1x} ${cp1y}, ${cp2x} ${cp2y}, ${p2.x} ${p2.y}`
  }
  
  return path
})

const handleChartHover = (event) => {
  const rect = event.currentTarget.getBoundingClientRect()
  const scaleX = rect.width / chartWidth
  const scaleY = rect.height / chartHeight
  const pointerX = (event.clientX - rect.left) / scaleX
  
  let closestIndex = null
  let minDistance = Infinity
  
  chartData.value.forEach((point, index) => {
    const distance = Math.abs(point.x - pointerX)
    if (distance < minDistance && distance < 35) {
      minDistance = distance
      closestIndex = index
    }
  })
  
  if (closestIndex !== null) {
    hoveredIndex.value = closestIndex
    const point = chartData.value[closestIndex]
    const tooltipX = Math.min(Math.max(point.x * scaleX, 80), rect.width - 80)
    const mouseY = event.clientY - rect.top
    const tooltipY = Math.max(mouseY - 15, 16)

    tooltip.value = {
      visible: true,
      x: tooltipX,
      y: tooltipY,
      date: point.date,
      balance: point.balance
    }
  } else {
    hideTooltip()
  }
}

const stepChart = direction => {
  if (!chartData.value.length) return
  const index = Math.max(0, Math.min(chartData.value.length - 1, (hoveredIndex.value ?? (direction > 0 ? -1 : chartData.value.length)) + direction))
  const point = chartData.value[index]
  const target = document.activeElement
  const rect = target.getBoundingClientRect()
  handleChartHover({ currentTarget: target, clientX: rect.left + point.x * rect.width / chartWidth, clientY: rect.top + point.y * rect.height / chartHeight })
}
const hideTooltip = () => {
  tooltip.value.visible = false
  hoveredIndex.value = null
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Finances, house style: caption section titles, operating costs and loans as .sheet lines (money
   gold, negatives --bad), the account balance big gold with an ok-ink / bad delta, an accent-soft
   balance line with a faint fill, time range as a .seg.bar. */

.finances-tab {
  display: flex;
  flex-direction: column;
  gap: var(--space-4);
  padding-bottom: 1.5em;
  font-variant-numeric: tabular-nums;
}

.tab-header {
  display: grid;
  gap: 0.25em;
}

.finances-content {
  display: flex;
  flex-direction: column;
  gap: 1.25em;
}

.fin-block {
  display: grid;
  gap: var(--space-2);
}

.block-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--space-3);
  flex-wrap: wrap;
}

.money {
  color: var(--money);
  font-weight: 700;
}
.negative,
.money.negative {
  color: var(--bad);
}

/* .sheet lines */
.line-key {
  min-width: 0;
  color: var(--muted);
  font-weight: 600;

  small {
    margin-left: 0.35em;
    color: var(--faint);
    font-size: 0.82em;
    font-weight: 600;
  }
}
.line-value {
  font-weight: 700;
}

.cost-toggle {
  .line-key {
    color: #fff;
    font-weight: 700;
  }
  .line-end {
    display: inline-flex;
    align-items: center;
    gap: 0.55em;
  }
  .money {
    font-size: 1.1em;
  }
  .chev {
    width: 0.85em;
    height: 0.85em;
    fill: none;
    stroke: var(--faint);
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
    transition: transform 0.12s;
  }
  &.open .chev {
    transform: rotate(180deg);
  }
}
.line.sub {
  font-size: 0.92em;
}

/* business account */
.account-history-section {
  gap: var(--space-3);
}

.account-head {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: var(--space-4);
  flex-wrap: wrap;
}

.account-copy {
  display: grid;
  gap: 0.2em;
}

.account-figures {
  display: flex;
  align-items: baseline;
  gap: 0.6em;
  flex-wrap: wrap;
}

.balance-value {
  font-size: 2em;
  font-weight: 800;
  line-height: 1.1;
  color: var(--money);

  &.negative {
    color: var(--bad);
  }
}

.balance-change {
  font-size: 0.92em;
  font-weight: 700;
  color: var(--faint);

  &.positive {
    color: var(--ok-ink);
  }
  &.negative {
    color: var(--bad);
  }
}

.time-scale-buttons {
  flex: 0 0 auto;

  button {
    flex: 0 0 auto;
    white-space: nowrap;
  }
}

.chart-container {
  position: relative;
  height: 17em;
  border-radius: var(--radius-tile);
  background: rgba(0, 0, 0, 0.25);
  overflow: hidden;
}

.chart-svg {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  display: block;
}

.chart-line {
  stroke-linecap: round;
  stroke-linejoin: round;
}

.chart-marker {
  position: absolute;
  width: 0.6em;
  height: 0.6em;
  border-radius: 50%;
  background: var(--accent-soft);
  box-shadow: 0 0 0 0.2em rgba(255, 178, 122, 0.22);
  transform: translate(-50%, -50%);
  pointer-events: none;
}

.chart-tooltip {
  position: absolute;
  z-index: 2;
  min-width: 6em;
  padding: 0.45em 0.7em 0.35em;
  border-radius: var(--radius-thumb);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 8px 20px rgba(0, 0, 0, 0.45);
  text-align: center;
  pointer-events: none;
  transform: translate(-50%, -100%);

  .tooltip-balance {
    font-weight: 700;
    color: var(--money);

    &.negative {
      color: var(--bad);
    }
  }

  .tooltip-date {
    margin-top: 0.1em;
    font-size: 0.75em;
    font-weight: 600;
    color: var(--faint);
  }
}

/* loans */
.loans-list {
  display: grid;
  gap: var(--space-2);
}

.loan-head {
  .loan-org {
    font-size: 1.05em;
    font-weight: 800;
    line-height: 1.2;
  }
}

/* sell business */
.sale-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-4);
}

.sale-copy {
  display: grid;
  gap: 0.2em;

  strong {
    font-size: 1.05em;
    font-weight: 800;
  }
}

.loading-state {
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* sale modal (teleported to body: carries .rls-house + the shell's em scale itself) */
.sale-modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 100000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.sale-modal {
  width: min(28em, 92vw);
}

.sale-summary {
  .line.total {
    font-size: 1.08em;

    .line-key {
      color: #fff;
      font-weight: 700;
    }
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .sale-modal {
    transition: transform 0.18s ease, opacity 0.18s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .sale-modal {
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
