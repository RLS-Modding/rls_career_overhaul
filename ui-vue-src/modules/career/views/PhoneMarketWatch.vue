<template>
  <PhoneWrapper app-name="Market Watch" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="mw-app">
      <div v-if="!loaded" class="empty-state">
        <p>Loading market data...</p>
      </div>

      <template v-if="loaded">
        <!-- Trend Charts Section -->
        <div class="section-header">Market Trends</div>
        <div class="charts-section">
          <div v-for="sector in sectors" :key="sector.key" class="chart-card">
            <div class="chart-header">
              <span class="chart-label">{{ sector.name }}</span>
              <span class="chart-trend" :class="getTrendClass(sector.key)">{{ getTrendLabel(sector.key) }}</span>
            </div>
            <svg class="sparkline" viewBox="0 0 200 50" preserveAspectRatio="none">
              <!-- Baseline at 1.0 -->
              <line x1="0" y1="25" x2="200" y2="25" stroke="rgba(255,255,255,0.15)" stroke-width="1" stroke-dasharray="4,3" />
              <!-- Trend line -->
              <polyline
                :points="getSparklinePoints(sector.key)"
                fill="none"
                :stroke="getLineColor(sector.key)"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
              <!-- Area fill -->
              <polygon
                :points="getAreaPoints(sector.key)"
                :fill="getAreaFill(sector.key)"
              />
            </svg>
          </div>
        </div>

        <!-- News Feed Section -->
        <div class="section-header">Latest News</div>
        <div class="news-section">
          <div v-if="articles.length === 0" class="empty-news">
            <p>No news yet. Check back later.</p>
          </div>
          <div v-for="(article, idx) in reversedArticles" :key="idx" class="news-card">
            <div class="news-sector-badge" :class="'sector-' + article.sector">{{ sectorLabel(article.sector) }}</div>
            <h3 class="news-headline">{{ article.headline }}</h3>
            <p class="news-body">{{ article.body }}</p>
            <span class="news-time">{{ formatTimestamp(article.timestamp) }}</span>
          </div>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import PhoneWrapper from './PhoneWrapper.vue'

const events = useEvents()

const loaded = ref(false)
const history = ref({ global: [], jobs: [], housing: [], vehicles: [] })
const articles = ref([])
const currentIndices = ref({ global: 1, jobs: 1, housing: 1, vehicles: 1 })
const simTime = ref(0)

const sectors = [
  { key: 'global', name: 'Global Economy' },
  { key: 'jobs', name: 'Job Market' },
  { key: 'housing', name: 'Housing' },
  { key: 'vehicles', name: 'Vehicles' },
]

const reversedArticles = computed(() => {
  return [...articles.value].reverse()
})

function getTrendClass(key) {
  const data = history.value[key]
  if (!data || data.length < 2) return 'stable'
  const last = data[data.length - 1]
  const prev = data[data.length - 2]
  const diff = last - prev
  if (diff > 0.02) return 'rising'
  if (diff < -0.02) return 'falling'
  return 'stable'
}

function getTrendLabel(key) {
  const cls = getTrendClass(key)
  if (cls === 'rising') return '▲ Rising'
  if (cls === 'falling') return '▼ Falling'
  return '● Stable'
}

function getLineColor(key) {
  const idx = currentIndices.value[key] || 1
  if (idx > 1.05) return '#22c55e'
  if (idx < 0.95) return '#ef4444'
  return '#f59e0b'
}

function getAreaFill(key) {
  const idx = currentIndices.value[key] || 1
  if (idx > 1.05) return 'rgba(34,197,94,0.1)'
  if (idx < 0.95) return 'rgba(239,68,68,0.1)'
  return 'rgba(245,158,11,0.08)'
}

function getSparklinePoints(key) {
  const data = history.value[key]
  if (!data || data.length === 0) return '0,25 200,25'
  const points = data.map((val, i) => {
    const x = data.length === 1 ? 100 : (i / (data.length - 1)) * 200
    // Map value range 0.5-1.5 to 50-0 (inverted Y)
    const y = 50 - ((val - 0.5) / 1.0) * 50
    return `${x},${Math.max(2, Math.min(48, y))}`
  })
  return points.join(' ')
}

function getAreaPoints(key) {
  const data = history.value[key]
  if (!data || data.length === 0) return '0,25 200,25 200,50 0,50'
  const linePoints = data.map((val, i) => {
    const x = data.length === 1 ? 100 : (i / (data.length - 1)) * 200
    const y = 50 - ((val - 0.5) / 1.0) * 50
    return `${x},${Math.max(2, Math.min(48, y))}`
  })
  const lastX = data.length === 1 ? 100 : 200
  return linePoints.join(' ') + ` ${lastX},50 0,50`
}

function sectorLabel(sector) {
  const labels = { global: 'Economy', jobs: 'Jobs', housing: 'Housing', vehicles: 'Vehicles' }
  return labels[sector] || sector
}

function formatTimestamp(timestamp) {
  if (!timestamp || !simTime.value) return ''
  const SIM_SECONDS_PER_DAY = 1200
  const diffSim = simTime.value - timestamp
  const daysAgo = Math.floor(diffSim / SIM_SECONDS_PER_DAY)
  if (daysAgo <= 0) return 'Today'
  if (daysAgo === 1) return 'Yesterday'
  if (daysAgo < 7) return `${daysAgo} days ago`
  if (daysAgo < 14) return '1 week ago'
  return `${Math.floor(daysAgo / 7)} weeks ago`
}

function onMarketData(data) {
  if (!data) return
  history.value = data.history || { global: [], jobs: [], housing: [], vehicles: [] }
  articles.value = data.articles || []
  currentIndices.value = data.currentIndices || { global: 1, jobs: 1, housing: 1, vehicles: 1 }
  simTime.value = data.simTime || 0
  loaded.value = true
}

onMounted(async () => {
  events.on('MarketWatchData', onMarketData)
  await lua.extensions.load('career_modules_globalEconomy')
  lua.career_modules_globalEconomy.requestMarketWatchData()
  setTimeout(() => { if (!loaded.value) loaded.value = true }, 1000)
})

onUnmounted(() => {
  events.off('MarketWatchData', onMarketData)
})
</script>

<style scoped lang="scss">
.mw-app {
  height: 100%;
  position: relative;
  background: #111;
  color: white;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 44px 0 80px;
  border-radius: 0 0 16px 16px;

  &::-webkit-scrollbar { width: 3px; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 2px; }
}

.empty-state {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(255,255,255,0.4);
  font-size: 14px;
}

.section-header {
  padding: 12px 16px 6px;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: rgba(255,255,255,0.35);
}

/* ── Charts ── */
.charts-section {
  padding: 0 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.chart-card {
  background: #1a1a1a;
  border-radius: 14px;
  padding: 12px 14px 8px;
  border: 1px solid rgba(255,255,255,0.05);
}

.chart-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.chart-label {
  font-size: 13px;
  font-weight: 600;
  color: rgba(255,255,255,0.9);
}

.chart-trend {
  font-size: 11px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 6px;

  &.rising {
    color: #22c55e;
    background: rgba(34,197,94,0.12);
  }
  &.falling {
    color: #ef4444;
    background: rgba(239,68,68,0.12);
  }
  &.stable {
    color: #f59e0b;
    background: rgba(245,158,11,0.12);
  }
}

.sparkline {
  width: 100%;
  height: 40px;
  display: block;
}

/* ── News Feed ── */
.news-section {
  padding: 0 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.empty-news {
  padding: 30px 20px;
  text-align: center;
  color: rgba(255,255,255,0.3);
  font-size: 13px;
}

.news-card {
  background: #1a1a1a;
  border-radius: 14px;
  padding: 14px 16px;
  border: 1px solid rgba(255,255,255,0.05);
}

.news-sector-badge {
  display: inline-block;
  font-size: 9px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  padding: 2px 8px;
  border-radius: 5px;
  margin-bottom: 8px;

  &.sector-global { background: rgba(59,130,246,0.15); color: #60a5fa; }
  &.sector-jobs { background: rgba(168,85,247,0.15); color: #c084fc; }
  &.sector-housing { background: rgba(249,115,22,0.15); color: #fb923c; }
  &.sector-vehicles { background: rgba(34,197,94,0.15); color: #4ade80; }
}

.news-headline {
  font-size: 15px;
  font-weight: 700;
  margin: 0 0 6px;
  color: rgba(255,255,255,0.95);
  line-height: 1.3;
}

.news-body {
  font-size: 13px;
  color: rgba(255,255,255,0.5);
  margin: 0 0 8px;
  line-height: 1.5;
}

.news-time {
  font-size: 11px;
  color: rgba(255,255,255,0.25);
}
</style>
