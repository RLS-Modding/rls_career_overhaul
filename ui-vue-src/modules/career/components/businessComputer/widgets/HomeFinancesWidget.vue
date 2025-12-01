<template>
  <div class="home-widget finances-widget">
    <div class="widget-header">
      <h3>Finances</h3>
      <div class="balance-badge" :class="{ negative: accountBalance < 0 }">
        {{ formatCurrency(accountBalance) }}
      </div>
    </div>

    <div class="widget-content">
      <div v-if="loading" class="loading-state">
        Loading...
      </div>
      <div v-else class="chart-wrapper">
        <div class="chart-container">
          <svg class="chart-svg" width="100%" height="100%" viewBox="0 0 400 120" preserveAspectRatio="none">
            <defs>
              <linearGradient id="widgetChartGradient" x1="0%" y1="0%" x2="0%" y2="100%">
                <stop offset="0%" style="stop-color:#2ecc71;stop-opacity:0.1" />
                <stop offset="100%" style="stop-color:#2ecc71;stop-opacity:0" />
              </linearGradient>
            </defs>
            
            <path 
              :d="chartPath" 
              fill="url(#widgetChartGradient)" 
              class="chart-area"
            />
            
            <path 
              :d="chartLinePath" 
              fill="none" 
              stroke="#2ecc71" 
              stroke-width="2"
              class="chart-line"
            />
          </svg>
        </div>
        
        <div class="finance-summary">
            <div class="summary-item">
                <span class="label">24h Change</span>
                <span class="value" :class="periodChange >= 0 ? 'positive' : 'negative'">
                    {{ periodChange >= 0 ? '+' : '' }}{{ formatCurrency(periodChange) }}
                </span>
            </div>
            <div class="summary-divider"></div>
            <div class="summary-item">
                <span class="label">Operating Costs</span>
                <span class="value cost">{{ formatCurrency(operatingCosts.total || 0) }}</span>
            </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted } from 'vue'
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import { useBridge, lua } from '@/bridge'
import { formatCurrency } from "../../../utils/businessUtils"

const store = useBusinessComputerStore()
const { events } = useBridge()

const financesData = ref(null)
const loading = ref(true)
const accountBalance = computed(() => financesData.value?.account?.balance || 0)
const transactions = computed(() => financesData.value?.transactions || [])
const operatingCosts = computed(() => financesData.value?.operatingCosts || {})

const requestFinancesData = async () => {
  if (!store.businessId || !store.businessType) return
  
  loading.value = true
  try {
    if (store.businessType === 'tuningShop') {
      await lua.career_modules_business_tuningShop.requestFinancesData(store.businessId)
    } else {
      await lua.career_modules_business_businessComputer.requestFinancesData(
        store.businessType,
        store.businessId
      )
    }
  } catch (error) {
    loading.value = false
  }
}

const handleFinancesData = (data) => {
  if (!data || !data.success) {
    loading.value = false
    return
  }
  if (String(data.businessId) !== String(store.businessId)) return
  
  financesData.value = data.finances
  loading.value = false
}

const handleAccountUpdate = (data) => {
  if (!data || !store.businessType || !store.businessId) return
  const accountId = "business_" + store.businessType + "_" + store.businessId
  if (data.accountId === accountId) {
    requestFinancesData()
  }
}

onMounted(() => {
  events.on('businessComputer:onFinancesData', handleFinancesData)
  events.on('bank:onAccountUpdate', handleAccountUpdate)
  if (store.businessId && store.businessType) {
    requestFinancesData()
  }
})

onUnmounted(() => {
  events.off('businessComputer:onFinancesData', handleFinancesData)
  events.off('bank:onAccountUpdate', handleAccountUpdate)
})

// Chart Logic (Simplified)
const chartWidth = 400
const chartHeight = 120
const chartPadding = 10

const filteredHistoryPoints = computed(() => {
  if (!transactions.value || transactions.value.length === 0) {
    return [{ balance: accountBalance.value, timestamp: Date.now() / 1000 }]
  }

  const sortedTransactions = [...transactions.value].sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0))
  let initialBalance = accountBalance.value
  
  // Calculate backwards to find start balance
  for (let i = sortedTransactions.length - 1; i >= 0; i--) {
    initialBalance -= (sortedTransactions[i].amount || 0)
  }

  let runningBalance = initialBalance
  const historyPoints = []
  
  if (sortedTransactions.length > 0) {
    historyPoints.push({
      balance: initialBalance,
      timestamp: sortedTransactions[0].timestamp
    })
  }
  
  for (const trans of sortedTransactions) {
    runningBalance += (trans.amount || 0)
    historyPoints.push({
      balance: runningBalance,
      timestamp: trans.timestamp
    })
  }

  historyPoints.push({
    balance: accountBalance.value,
    timestamp: Date.now() / 1000
  })

  // Filter last 24h
  const now = Date.now() / 1000
  const cutoffTime = now - 86400
  return historyPoints.filter(point => point.timestamp >= cutoffTime)
})

const periodChange = computed(() => {
  if (filteredHistoryPoints.value.length === 0) return 0
  const first = filteredHistoryPoints.value[0].balance
  const last = filteredHistoryPoints.value[filteredHistoryPoints.value.length - 1].balance
  return last - first
})

const chartData = computed(() => {
  const historyPoints = filteredHistoryPoints.value
  if (historyPoints.length === 0) return []

  const firstTimestamp = historyPoints[0].timestamp
  const lastTimestamp = historyPoints[historyPoints.length - 1].timestamp
  const timeRange = lastTimestamp - firstTimestamp || 1
  
  const balances = historyPoints.map(p => p.balance)
  const minBalance = Math.min(...balances)
  const maxBalance = Math.max(...balances)
  const range = maxBalance - minBalance || 1

  return historyPoints.map(point => ({
    x: ((point.timestamp - firstTimestamp) / timeRange) * chartWidth,
    y: chartHeight - chartPadding - (((point.balance - minBalance) / range) * (chartHeight - 2 * chartPadding)) - chartPadding
  }))
})

const chartPath = computed(() => {
  if (chartData.value.length === 0) return ''
  const points = chartData.value
  const bottomY = chartHeight
  let path = `M ${points[0].x} ${bottomY} L ${points[0].x} ${points[0].y}`
  for (let i = 1; i < points.length; i++) path += ` L ${points[i].x} ${points[i].y}`
  path += ` L ${points[points.length - 1].x} ${bottomY} Z`
  return path
})

const chartLinePath = computed(() => {
  if (chartData.value.length === 0) return ''
  const points = chartData.value
  let path = `M ${points[0].x} ${points[0].y}`
  for (let i = 1; i < points.length; i++) path += ` L ${points[i].x} ${points[i].y}`
  return path
})
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1rem;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.widget-header {
  padding: 1rem 1.25rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1.1rem;
    font-weight: 600;
    color: #fff;
  }
}

.balance-badge {
    font-size: 1rem;
    font-weight: 600;
    color: #2ecc71;
    
    &.negative { color: #e74c3c; }
}

.widget-content {
  padding: 0; /* No padding for chart to flush */
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.loading-state {
    padding: 2rem;
    text-align: center;
    color: rgba(255, 255, 255, 0.5);
}

.chart-wrapper {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-height: 0;
    overflow: hidden;
}

.chart-container {
    flex: 1;
    min-height: 120px;
    width: 100%;
    background: rgba(0, 0, 0, 0.2);
    position: relative;
    overflow: hidden;
}

.finance-summary {
    padding: 0.75rem 1rem;
    display: flex;
    justify-content: space-around;
    align-items: center;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(0, 0, 0, 0.1);
    flex-shrink: 0;
    margin-top: auto; /* Push to bottom */
}

.summary-divider {
    width: 1px;
    height: 2rem;
    background: rgba(255, 255, 255, 0.1);
}

.summary-item {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.25rem;
    flex: 1;
    
    .label {
        font-size: 0.7rem;
        color: rgba(255, 255, 255, 0.5);
        text-transform: uppercase;
        letter-spacing: 0.05em;
        white-space: nowrap;
    }
    
    .value {
        font-size: 0.9rem;
        font-weight: 600;
        color: #fff;
        white-space: nowrap;
        
        &.positive { color: #2ecc71; }
        &.negative { color: #e74c3c; }
        &.cost { color: #f97316; }
    }
}
</style>
