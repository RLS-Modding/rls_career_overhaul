<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="mw-app" v-bng-on-ui-nav:tab_l="() => changeTab(-1)" v-bng-on-ui-nav:tab_r="() => changeTab(1)">
    <div v-if="!loaded" class="empty-state">
      <p>Loading market data...</p>
    </div>

    <template v-if="loaded">
      <nav class="tabs" role="tablist" aria-label="Market Watch">
        <button
          id="mw-tab-opportunities"
          type="button"
          role="tab"
          :aria-selected="tab === 'opportunities'"
          aria-controls="mw-panel-opportunities"
          :tabindex="tab === 'opportunities' ? 0 : -1"
          :class="{ active: tab === 'opportunities' }"
          @click="tab = 'opportunities'"
        >
          Opportunities
        </button>
        <button
          id="mw-tab-news"
          type="button"
          role="tab"
          :aria-selected="tab === 'news'"
          aria-controls="mw-panel-news"
          :tabindex="tab === 'news' ? 0 : -1"
          :class="{ active: tab === 'news' }"
          @click="tab = 'news'"
        >
          News
        </button>
      </nav>

      <!-- Opportunities: high demand first, then the rest -->
      <section
        v-if="tab === 'opportunities'"
        id="mw-panel-opportunities"
        class="tab-panel"
        role="tabpanel"
        aria-labelledby="mw-tab-opportunities"
      >
        <div class="section-header">High Demand</div>
        <div class="job-list">
          <div v-if="highDemandJobs.length === 0" class="empty-surges">
            <p>Nothing paying a premium right now.</p>
          </div>
          <div
            v-for="job in highDemandJobs"
            :key="'hot-' + job.key"
            class="surge-card is-surge"
          >
            <div class="surge-info">
              <span class="surge-label">{{ job.label }}</span>
              <span class="surge-sub">{{ job.branchLabel }}, paying more</span>
            </div>
            <span class="surge-mult">{{ pctLabel(job.factor) }}</span>
          </div>
        </div>

        <div class="section-header">Other Jobs</div>
        <div class="job-list">
          <div v-if="otherJobs.length === 0" class="empty-surges">
            <p>No other jobs on this map.</p>
          </div>
          <div
            v-for="job in otherJobs"
            :key="'all-' + job.key"
            class="surge-card"
            :class="polarityClass(job)"
          >
            <div class="surge-info">
              <span class="surge-label">{{ job.label }}</span>
              <span class="surge-sub">{{ job.branchLabel }}, {{ polarityText(job) }}</span>
            </div>
            <span class="surge-mult">{{ pctLabel(job.factor) }}</span>
          </div>
        </div>
      </section>

      <!-- News: trends + feed -->
      <section
        v-else
        id="mw-panel-news"
        class="tab-panel"
        role="tabpanel"
        aria-labelledby="mw-tab-news"
      >
        <div class="section-header">Market Trends</div>
        <div class="charts-section">
          <div v-for="sector in sectors" :key="sector.key" class="chart-card">
            <div class="chart-header">
              <span class="chart-label">{{ sector.name }}</span>
              <span class="chart-trend" :class="getTrendClass(sector.key)">{{ getTrendLabel(sector.key) }}</span>
            </div>
            <svg class="sparkline" viewBox="0 0 200 50" preserveAspectRatio="none">
              <line x1="0" y1="25" x2="200" y2="25" stroke="rgba(255,255,255,0.15)" stroke-width="1" stroke-dasharray="4,3" />
              <polyline
                :points="getSparklinePoints(sector.key)"
                fill="none"
                :stroke="getLineColor(sector.key)"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
              <polygon
                :points="getAreaPoints(sector.key)"
                :fill="getAreaFill(sector.key)"
              />
            </svg>
          </div>
        </div>

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
      </section>
    </template>
  </div>
</template>

<script setup>
import { vBngOnUiNav } from "@/common/directives"
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { acquireScope } from '../../utils/luaScopes'

const events = useEvents()

const DEFAULT_HOT_THRESHOLD = 1.10

const loaded = ref(false)
const tab = ref('opportunities')
const TAB_IDS = ['opportunities', 'news']
const TAB_BUTTON_IDS = {
  opportunities: 'mw-tab-opportunities',
  news: 'mw-tab-news',
}

function changeTab(direction) {
  const idx = Math.max(0, TAB_IDS.indexOf(tab.value))
  const nextIdx = (idx + direction + TAB_IDS.length) % TAB_IDS.length
  const nextTab = TAB_IDS[nextIdx]
  tab.value = nextTab
  requestAnimationFrame(() => {
    const el = document.getElementById(TAB_BUTTON_IDS[nextTab])
    if (el) el.focus()
  })
}
const history = ref({ global: [], jobs: [], housing: [], vehicles: [] })
const articles = ref([])
const currentIndices = ref({ global: 1, jobs: 1, housing: 1, vehicles: 1 })
const simTime = ref(0)
const jobMarket = ref({ branches: [], hottest: null, softest: null, hotThreshold: DEFAULT_HOT_THRESHOLD })

const sectors = [
  { key: 'global', name: 'Global Economy' },
  { key: 'jobs', name: 'Job Market' },
  { key: 'housing', name: 'Housing' },
  { key: 'vehicles', name: 'Vehicles' },
]

const reversedArticles = computed(() => [...articles.value].reverse())

const flatJobs = computed(() => {
  const out = []
  for (const branch of jobMarket.value.branches || []) {
    for (const leaf of branch.leaves || []) {
      if (!leaf || !leaf.available) continue
      out.push({
        key: leaf.key,
        label: leaf.label,
        branchLabel: branch.label || '',
        factor: leaf.factor || 1,
        polarity: leaf.polarity,
      })
    }
  }
  out.sort((a, b) => (b.factor || 1) - (a.factor || 1))
  return out
})

const hotThreshold = computed(() => {
  const t = Number(jobMarket.value.hotThreshold)
  return Number.isFinite(t) && t > 0 ? t : DEFAULT_HOT_THRESHOLD
})

const highDemandJobs = computed(() =>
  flatJobs.value.filter(j => (j.factor || 1) >= hotThreshold.value)
)

const otherJobs = computed(() =>
  flatJobs.value.filter(j => (j.factor || 1) < hotThreshold.value)
)

function polarityClass(row) {
  if ((row.factor || 1) < 0.999) return 'is-cooldown'
  if ((row.factor || 1) > 1.001) return 'is-surge'
  return ''
}

function polarityText(row) {
  if ((row.factor || 1) < 0.999) return 'Cooling off'
  if ((row.factor || 1) > 1.001) return 'Paying more'
  return 'Baseline'
}

function pctLabel(factor) {
  const pct = Math.round(((factor || 1) - 1) * 100)
  return (pct > 0 ? '+' : '') + pct + '%'
}

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

function normalizeJobMarket(raw) {
  const threshold = Number(raw && raw.hotThreshold)
  if (raw && Array.isArray(raw.branches)) {
    return {
      branches: raw.branches,
      hottest: raw.hottest || null,
      softest: raw.softest || null,
      hotThreshold: Number.isFinite(threshold) && threshold > 0 ? threshold : DEFAULT_HOT_THRESHOLD,
    }
  }
  return { branches: [], hottest: null, softest: null, hotThreshold: DEFAULT_HOT_THRESHOLD }
}

function onMarketData(data) {
  if (!data) return
  history.value = Object.fromEntries(sectors.map(({ key }) => [
    key, Array.isArray(data.history?.[key]) ? data.history[key] : [],
  ]))
  articles.value = Array.isArray(data.articles) ? data.articles : []
  currentIndices.value = data.currentIndices || { global: 1, jobs: 1, housing: 1, vehicles: 1 }
  simTime.value = data.simTime || 0
  jobMarket.value = normalizeJobMarket(data.jobSurges)
  loaded.value = true
}

onMounted(async () => {
  events.on('MarketWatchData', onMarketData)
  if (await lua.overhaul_career_career.isActive()) {
    await acquireScope(lua, 'career.marketWatch')
    lua.overhaul_career_economy_globalEconomy.requestMarketWatchData()
  }
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
  padding: 44px 12px 80px;
  border-radius: 0 0 16px 16px;
  font-size: 0.9em;

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

.tabs {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 6px;
  padding: 3px;
  margin-bottom: 8px;
  border-radius: 16px;
  border: 1px solid rgba(255, 255, 255, 0.06);
  background: rgba(13, 16, 22, 0.62);
}

.tabs button {
  padding: 10px 8px;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.01em;
  color: rgba(214, 222, 235, 0.72);
  border: none;
  border-radius: 12px;
  background: transparent;
  cursor: pointer;
  white-space: nowrap;
  transition: transform 0.16s ease, background-color 0.16s ease, border-color 0.16s ease, color 0.16s ease;

  &:active { transform: scale(0.985); }

  &.active {
    color: #fff7f1;
    background: linear-gradient(180deg, rgba(224, 107, 50, 0.92), rgba(180, 76, 28, 0.92));
    box-shadow: 0 8px 18px rgba(180, 76, 28, 0.26);
  }
}

.tab-panel {
  display: flex;
  flex-direction: column;
  gap: 0;
}

.section-header {
  padding: 12px 4px 6px;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: rgba(255,255,255,0.35);
}

.job-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.empty-surges,
.empty-news {
  padding: 16px 12px;
  text-align: center;
  color: rgba(255,255,255,0.3);
  font-size: 12px;

  p { margin: 0; }
}

.empty-news {
  padding: 30px 20px;
  font-size: 13px;
}

.surge-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  background: #1a1a1a;
  border-radius: 14px;
  padding: 12px 16px;
  border: 1px solid rgba(255,255,255,0.05);
  border-left: 3px solid rgba(255,255,255,0.2);

  &.is-surge { border-left-color: #34d399; }
  &.is-cooldown { border-left-color: #f87171; }
}

.surge-info {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.surge-label {
  font-size: 13px;
  font-weight: 700;
  color: #f8fafc;
}

.surge-sub {
  font-size: 10px;
  color: rgba(255,255,255,0.45);
}

.surge-mult {
  flex: none;
  font-size: 15px;
  font-weight: 800;

  .is-surge & { color: #34d399; }
  .is-cooldown & { color: #f87171; }
}

.charts-section {
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

.news-section {
  display: flex;
  flex-direction: column;
  gap: 8px;
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
