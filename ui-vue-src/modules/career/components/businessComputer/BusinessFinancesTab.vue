<template>
  <div class="finances-tab">
    <div class="tab-header">
      <h2>Finances</h2>
      <p>Overview of your business financial status and operating costs.</p>
    </div>

    <div v-if="financesData && !loading" class="finances-content">
      <div v-if="!operatingCosts.solarPowerActive" class="finances-section operating-costs-section">
        <div class="operating-costs-header">
          <div>
            <h3>Operating Costs</h3>
            <p class="next-payment-text">
              Next payment in: {{ timeUntilNextPayment }}
            </p>
          </div>
          <div class="operating-cost-display">
            <span class="cost-label-small">Current Cost:</span>
            <span class="cost-value-large">
              {{ formatCurrency(operatingCosts.total) }}
            </span>
            <button class="info-button" @click="showBreakdown = !showBreakdown" :class="{ active: showBreakdown }" data-focusable>
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                <circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.5"/>
                <path d="M8 5V5.01M8 11V8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
              </svg>
            </button>
          </div>
        </div>
        
        <div v-if="showBreakdown" class="operating-costs-breakdown">
          <div class="cost-item">
            <span class="cost-label">Base Lift:</span>
            <span class="cost-value">+{{ formatCurrency(operatingCosts.baseLift) }}</span>
          </div>
          <div class="cost-item" v-if="operatingCosts.additionalLifts > 0">
            <span class="cost-label">Additional Lifts ({{ operatingCosts.additionalLifts }}):</span>
            <span class="cost-value">+{{ formatCurrency(operatingCosts.additionalLiftsCost) }}</span>
          </div>
          <div class="cost-item" v-if="operatingCosts.techs > 0">
            <span class="cost-label">Techs ({{ operatingCosts.techs }}):</span>
            <span class="cost-value">+{{ formatCurrency(operatingCosts.techsCost) }}</span>
          </div>
          <div class="cost-item" v-if="operatingCosts.manager > 0">
            <span class="cost-label">Manager:</span>
            <span class="cost-value">{{ formatCurrency(operatingCosts.managerCost) }}</span>
          </div>
          <div class="cost-item" v-if="operatingCosts.generalManager > 0">
            <span class="cost-label">General Manager:</span>
            <span class="cost-value">{{ formatCurrency(operatingCosts.generalManagerCost) }}</span>
          </div>
          <div class="cost-item cost-total">
            <span class="cost-label">Total (per 30 min):</span>
            <span class="cost-value">{{ formatCurrency(operatingCosts.total) }}</span>
          </div>
        </div>
      </div>

      <div class="finances-section account-history-section" v-if="chartData.length > 0">
        <div class="account-history-header">
          <div>
            <h3>Business Account</h3>
          </div>
          <div class="account-balance merged">
            <span class="balance-value" :class="{ negative: accountBalance < 0 }">
              {{ formatCurrency(accountBalance) }}
            </span>
            <span class="balance-change" :class="{ negative: periodChange < 0, positive: periodChange >= 0 }">
              {{ periodChange >= 0 ? '+' : '' }}{{ formatCurrency(periodChange) }}
            </span>
          </div>
        </div>
        <div class="chart-container" @mousemove="handleChartHover" @mouseleave="hideTooltip">
          <svg class="chart-svg" width="100%" height="100%" viewBox="0 0 800 300" preserveAspectRatio="none">
            <defs>
              <linearGradient id="chartGradient" x1="0%" y1="0%" x2="0%" y2="100%">
                <stop offset="0%" style="stop-color:#2ecc71;stop-opacity:0.2" />
                <stop offset="100%" style="stop-color:#2ecc71;stop-opacity:0" />
              </linearGradient>
              <filter id="glow">
                <feGaussianBlur stdDeviation="2" result="coloredBlur"/>
                <feMerge>
                  <feMergeNode in="coloredBlur"/>
                  <feMergeNode in="SourceGraphic"/>
                </feMerge>
              </filter>
            </defs>
            
            <g class="chart-grid">
              <line v-for="i in 5" :key="`grid-${i}`" 
                :x1="0" 
                :y1="chartHeight - chartBottomPadding - ((i - 1) * (chartHeight - chartPadding - chartBottomPadding) / 4)"
                :x2="chartWidth"
                :y2="chartHeight - chartBottomPadding - ((i - 1) * (chartHeight - chartPadding - chartBottomPadding) / 4)"
                stroke="rgba(255,255,255,0.03)"
                stroke-width="1"
              />
            </g>

            <line
              v-if="zeroLineY !== null"
              :x1="0"
              :y1="zeroLineY"
              :x2="chartWidth"
              :y2="zeroLineY"
              stroke="rgba(255,255,255,0.2)"
              stroke-width="1.5"
              stroke-dasharray="4,4"
              class="zero-line"
            />

            <path 
              :d="chartPath" 
              fill="url(#chartGradient)" 
              class="chart-area"
            />
            
            <path 
              :d="chartLinePath" 
              fill="none" 
              stroke="#2ecc71" 
              stroke-width="2.5"
              class="chart-line"
              filter="url(#glow)"
            />

            <circle
              v-for="(point, index) in chartData"
              :key="`point-${index}`"
              :cx="point.x"
              :cy="point.y"
              r="3"
              fill="#2ecc71"
              class="chart-point"
              :class="{ 'chart-point--hover': hoveredIndex === index }"
              opacity="0.6"
            />

            <g v-if="hoveredIndex !== null && chartData[hoveredIndex]" class="tooltip-group">
              <line
                :x1="chartData[hoveredIndex].x"
                :y1="chartPadding"
                :x2="chartData[hoveredIndex].x"
                :y2="chartHeight - chartBottomPadding"
                stroke="#F54900"
                stroke-width="1"
                stroke-dasharray="4,4"
                opacity="0.5"
              />
            </g>
          </svg>
          
          <div v-if="tooltip.visible" class="chart-tooltip" :style="{ left: tooltip.x + 'px', top: tooltip.y + 'px' }">
            <div class="tooltip-balance">{{ formatCurrency(tooltip.balance) }}</div>
            <div class="tooltip-date">{{ tooltip.date }}</div>
          </div>
          
          <div class="time-scale-buttons">
            <button 
              v-for="(scale, index) in timeScales" 
              :key="scale.value"
              :class="{ 
                active: selectedTimeScale === scale.value,
                'button-first': index === 0,
                'button-middle': index > 0 && index < timeScales.length - 1,
                'button-last': index === timeScales.length - 1
              }"
              @click.stop="selectedTimeScale = scale.value"
            >
              {{ scale.label }}
            </button>
          </div>
        </div>
      </div>

      <div class="finances-section" v-if="businessLoans.length > 0">
        <h3>Business Loans</h3>
        <div class="loans-list">
          <div v-for="loan in businessLoans" :key="loan.id" class="loan-card">
            <div class="loan-header">
              <span class="loan-org">{{ loan.orgName || loan.orgId }}</span>
              <span class="loan-rate">{{ (loan.rate * 100).toFixed(1) }}%</span>
            </div>
            <div class="loan-details">
              <div class="loan-row">
                <span class="loan-label">Principal Outstanding:</span>
                <span class="loan-value">{{ formatCurrency(loan.principalOutstanding) }}</span>
              </div>
              <div class="loan-row">
                <span class="loan-label">Next Payment:</span>
                <span class="loan-value">{{ formatCurrency(loan.nextPaymentDue) }}</span>
              </div>
              <div class="loan-row">
                <span class="loan-label">Payments Remaining:</span>
                <span class="loan-value">{{ loan.paymentsRemaining }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div v-else class="loading-state">
      <p>{{ loading ? 'Loading financial data...' : 'No financial data available' }}</p>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from 'vue'
import { useBridge, lua } from '@/bridge'

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
const currentTime = ref(null)
const operatingCosts = computed(() => financesData.value?.operatingCosts || {})
const accountBalance = computed(() => financesData.value?.account?.balance || 0)
const transactions = computed(() => financesData.value?.transactions || [])
const businessLoans = computed(() => financesData.value?.loans || [])
const operatingCostTimer = computed(() => financesData.value?.operatingCostTimer || null)

let timeUpdateInterval = null
let simulationTimeInterval = null
let paymentTimerInterval = null
let simulationTimeOffset = 0
let lastTimerUpdateTime = ref(null)
let lastRemainingTime = ref(null)
const currentTimeForPayment = ref(Date.now())

watch(operatingCostTimer, (timer) => {
  if (timer && timer.remainingTime !== null && timer.remainingTime !== undefined) {
    const now = Date.now()
    lastTimerUpdateTime.value = now
    lastRemainingTime.value = timer.remainingTime
    currentTimeForPayment.value = now
  }
}, { immediate: true })

const timeUntilNextPayment = computed(() => {
  const timer = operatingCostTimer.value
  const currentTime = currentTimeForPayment.value
  
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
  
  return formatTimeRemaining(Math.floor(currentRemaining))
})

const formatTimeRemaining = (seconds) => {
  if (seconds < 60) {
    return `${seconds}s`
  }
  const minutes = Math.floor(seconds / 60)
  const remainingSeconds = seconds % 60
  if (minutes < 60) {
    return remainingSeconds > 0 ? `${minutes}m ${remainingSeconds}s` : `${minutes}m`
  }
  const hours = Math.floor(minutes / 60)
  const remainingMinutes = minutes % 60
  return remainingMinutes > 0 ? `${hours}h ${remainingMinutes}m` : `${hours}h`
}

const requestFinancesData = async () => {
  if (!props.data?.businessId || !props.data?.businessType) {
    return
  }
  
  loading.value = true
  try {
    await lua.career_modules_business_businessComputer.requestFinancesData(
      props.data.businessType,
      props.data.businessId
    )
  } catch (error) {
    loading.value = false
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
  if (data.simulationTime) {
    const clientTime = Math.floor(Date.now() / 1000)
    simulationTimeOffset = data.simulationTime - clientTime
    currentTime.value = data.simulationTime
  }
  
  loading.value = false
}

const handleSimulationTime = (data) => {
  if (!data || !data.success) return
  
  const clientTime = Math.floor(Date.now() / 1000)
  simulationTimeOffset = data.simulationTime - clientTime
  currentTime.value = data.simulationTime
}

const handleAccountUpdate = (data) => {
  if (!data || !props.data?.businessType || !props.data?.businessId) return
  
  const accountId = "business_" + props.data.businessType + "_" + props.data.businessId
  
  if (data.accountId === accountId) {
    requestFinancesData()
  }
}

const requestSimulationTime = async () => {
  try {
    await lua.career_modules_business_businessComputer.requestSimulationTime()
  } catch (error) {
  }
}

onMounted(() => {
  simulationTimeOffset = 0
  events.on('businessComputer:onFinancesData', handleFinancesData)
  events.on('businessComputer:onSimulationTime', handleSimulationTime)
  events.on('bank:onAccountUpdate', handleAccountUpdate)
  if (props.data?.businessId && props.data?.businessType) {
    requestFinancesData()
  }
  
  requestSimulationTime()
  timeUpdateInterval = setInterval(() => {
    if (currentTime.value !== null) {
      const clientTime = Math.floor(Date.now() / 1000)
      currentTime.value = clientTime + simulationTimeOffset
    }
  }, 1000)
  
  simulationTimeInterval = setInterval(() => {
    requestSimulationTime()
  }, 30000)
  
  paymentTimerInterval = setInterval(() => {
    currentTimeForPayment.value = Date.now()
  }, 1000)
})

onUnmounted(() => {
  events.off('businessComputer:onFinancesData', handleFinancesData)
  events.off('businessComputer:onSimulationTime', handleSimulationTime)
  events.off('bank:onAccountUpdate', handleAccountUpdate)
  if (timeUpdateInterval) {
    clearInterval(timeUpdateInterval)
  }
  if (simulationTimeInterval) {
    clearInterval(simulationTimeInterval)
  }
  if (paymentTimerInterval) {
    clearInterval(paymentTimerInterval)
  }
})

const chartWidth = 800
const chartHeight = 300
const chartPadding = 40
const chartBottomPadding = 60

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

const hideTooltip = () => {
  tooltip.value.visible = false
  hoveredIndex.value = null
}

const formatCurrency = (amount) => {
  if (amount === null || amount === undefined) return '$0'
  const num = Math.abs(amount)
  const sign = amount < 0 ? '-' : ''
  if (num >= 1000000) {
    return sign + '$' + (num / 1000000).toFixed(2) + 'M'
  } else if (num >= 1000) {
    return sign + '$' + (num / 1000).toFixed(1) + 'k'
  }
  return sign + '$' + Math.floor(num).toLocaleString()
}
</script>

<style scoped lang="scss">
.finances-tab {
  display: flex;
  flex-direction: column;
  gap: 2rem;
  padding-bottom: 2rem;
  color: rgba(255, 255, 255, 0.9);
}

.tab-header {
  margin-bottom: 0.75em;
  
  h2 {
    margin: 0 0 0.5rem 0;
    font-size: 1.5rem;
    font-weight: 600;
    color: #fff;
  }
  
  p {
    margin: 0;
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.9rem;
  }
}

.finances-content {
  display: flex;
  flex-direction: column;
  gap: 2rem;
  
  > .operating-costs-section:first-child {
    margin-top: -2rem;
  }
}

.finances-section {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  padding: 1.5rem;
  
  h3 {
    margin: 0 0 1rem 0;
    font-size: 1.1rem;
    font-weight: 600;
    color: #F54900;
  }
}

.operating-costs-section {
  padding: 1rem 1.25rem;
  
  .operating-costs-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 0;
    
    h3 {
      margin: 0 0 0.25rem 0;
      font-size: 1rem;
    }
    
    .next-payment-text {
      margin: 0;
      font-size: 0.8rem;
      color: rgba(255, 255, 255, 0.6);
    }
  }
  
  .operating-cost-display {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    
    .cost-label-small {
      color: rgba(255, 255, 255, 0.7);
      font-size: 0.85rem;
    }
    
    .cost-value-large {
      font-size: 1.25rem;
      font-weight: 600;
      color: #F54900;
      
      &.solar-active {
        color: #2ecc71;
      }
    }
  }
  
  .info-button {
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 50%;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: rgba(255, 255, 255, 0.7);
    transition: all 0.2s;
    
    &:hover {
      background: rgba(245, 73, 0, 0.2);
      border-color: #F54900;
      color: #F54900;
    }
    
    &.active {
      background: rgba(245, 73, 0, 0.3);
      border-color: #F54900;
      color: #F54900;
    }
    
    svg {
      width: 12px;
      height: 12px;
    }
  }
  
  .operating-costs-breakdown {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    margin-top: 0.75rem;
    padding-top: 0.75rem;
    border-top: 1px solid rgba(255, 255, 255, 0.1);
  }
}

.operating-costs-panel {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.cost-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.35rem 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  
  &:last-child {
    border-bottom: none;
  }
  
  &.cost-total {
    border-top: 2px solid rgba(245, 73, 0, 0.3);
    padding-top: 0.75rem;
    margin-top: 0.25rem;
    font-weight: 600;
  }
  
  .cost-label {
    color: rgba(255, 255, 255, 0.7);
  }
  
  .cost-value {
    color: #fff;
    font-weight: 500;
  }
}

.account-history-section {
  padding: 0;
}

.account-history-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 1.5rem;
  padding: 1rem 1.5rem 0 1.5rem;
  
  h3 {
    margin: 0;
    font-size: 1.5rem;
    font-weight: 600;
  }
}

.account-balance {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  align-items: flex-start;
  padding: 1rem;
  background: rgba(0, 0, 0, 0.2);
  border-radius: 0.5rem;
  
  &.merged {
    background: transparent;
    padding: 0;
    align-items: flex-end;
  }
  
  .balance-label {
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.95rem;
  }
  
  .balance-value {
    font-size: 1.75rem;
    font-weight: 600;
    color: #2ecc71;
    
    &.negative {
      color: #e74c3c;
    }
  }

  .balance-change {
    font-size: 0.85rem;
    font-weight: 500;
    color: #2ecc71;
    margin-bottom: 0.5rem;
    
    &.negative {
      color: #e74c3c;
    }
    
    &.positive {
      color: #2ecc71;
    }
  }
}

.time-scale-buttons {
  position: absolute;
  bottom: 0.75rem;
  left: 1rem;
  display: flex;
  z-index: 10;

  button {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.15);
    padding: 0.5rem 1.2rem;
    color: rgba(255, 255, 255, 0.75);
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.2s ease;
    position: relative;
    margin: 0;

    &.button-first {
      border-top-left-radius: 0.375rem;
      border-bottom-left-radius: 0.375rem;
      border-right: none;
    }

    &.button-middle {
      border-radius: 0;
      border-left: none;
      border-right: none;
      
      &:not(:last-child) {
        border-right: none;
      }
    }

    &.button-last {
      border-top-right-radius: 0.375rem;
      border-bottom-right-radius: 0.375rem;
      border-left: none;
    }

    &:hover {
      background: rgba(255, 255, 255, 0.1);
      color: rgba(255, 255, 255, 0.9);
      z-index: 1;
    }

    &.active {
      background: rgba(245, 73, 0, 0.25);
      color: #F54900;
      z-index: 2;
      border-color: #F54900;

      &.button-first {
        border-right-color: transparent;
      }

      &.button-middle {
        border-left-color: transparent;
        border-right-color: transparent;
      }

      &.button-last {
        border-left-color: transparent;
      }
    }
  }
}

.chart-container {
  position: relative;
  width: 100%;
  height: 100%;
  min-height: 340px;
  background: rgba(0, 0, 0, 0.25);
  border-radius: 0 0 0.5rem 0.5rem;
  padding: 0;
  overflow: hidden;
  display: flex;
  align-items: flex-end;
  padding-bottom: 1%;
}

.chart-svg {
  width: 100%;
  height: 100%;
}

.chart-area {
  opacity: 0.5;
}

.chart-line {
  stroke-linecap: round;
  stroke-linejoin: round;
}

.chart-point {
  cursor: pointer;
  transition: all 0.2s;
  
  &:hover,
  &.chart-point--hover {
    r: 5;
    opacity: 1;
    filter: drop-shadow(0 0 6px rgba(46, 204, 113, 0.8));
  }
}

.chart-tooltip {
  position: absolute;
  background: rgba(15, 15, 15, 0.95);
  border: 1px solid rgba(245, 73, 0, 0.5);
  border-radius: 0.25rem;
  padding: 0.35rem 0.75rem;
  pointer-events: none;
  z-index: 1000;
  transform: translateX(-50%) translateY(-100%);
  min-width: 90px;
  text-align: center;
  box-shadow: 0 4px 10px rgba(0, 0, 0, 0.35);
  
  .tooltip-balance {
    font-size: 1rem;
    font-weight: 600;
    color: #F54900;
  }
  
  .tooltip-date {
    font-size: 0.7rem;
    color: rgba(255, 255, 255, 0.7);
  }
}

.loans-list {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.loan-card {
  background: rgba(0, 0, 0, 0.2);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  padding: 1rem;
}

.loan-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.75rem;
  padding-bottom: 0.75rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  
  .loan-org {
    font-weight: 600;
    color: #fff;
  }
  
  .loan-rate {
    color: #F54900;
    font-weight: 500;
  }
}

.loan-details {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.loan-row {
  display: flex;
  justify-content: space-between;
  
  .loan-label {
    color: rgba(255, 255, 255, 0.7);
  }
  
  .loan-value {
    color: #fff;
    font-weight: 500;
  }
}

.loading-state {
  text-align: center;
  padding: 3rem;
  color: rgba(255, 255, 255, 0.6);
}
</style>

