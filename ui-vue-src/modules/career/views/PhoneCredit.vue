<template>
    <PhoneWrapper app-name="Credit">
        <div class="phone-credit">
            <div class="section score-section">
                <div class="score-circle-wrap">
                    <svg viewBox="0 0 200 200" class="score-svg">
                        <circle
                            cx="100" cy="100" r="85"
                            fill="none"
                            stroke="rgba(0,0,0,0.1)"
                            stroke-width="12"
                            stroke-linecap="round"
                            :stroke-dasharray="circumference"
                            stroke-dashoffset="0"
                            transform="rotate(135 100 100)"
                        />
                        <circle
                            cx="100" cy="100" r="85"
                            fill="none"
                            :stroke="scoreColor"
                            stroke-width="12"
                            stroke-linecap="round"
                            :stroke-dasharray="arcDasharray"
                            stroke-dashoffset="0"
                            transform="rotate(135 100 100)"
                        />
                        <text x="100" y="90" text-anchor="middle" class="score-number" fill="#0f172a">{{ creditData.score || '—' }}</text>
                        <text x="100" y="115" text-anchor="middle" class="score-tier" :fill="scoreColor">{{ creditData.tier?.label || '' }}</text>
                        <text x="100" y="135" text-anchor="middle" class="score-range" fill="#94a3b8">300 – 850</text>
                    </svg>
                </div>
            </div>

            <div class="section">
                <div class="section-title">Credit Factors</div>
                <div class="factor-cards">
                    <div class="factor-card" v-for="f in factorCards" :key="f.label">
                        <div class="factor-header">
                            <span class="factor-name">{{ f.label }}</span>
                            <span class="factor-weight">{{ f.weight }}%</span>
                        </div>
                        <div class="factor-bar-track">
                            <div class="factor-bar-fill" :style="{ width: f.percent + '%', background: f.color }"></div>
                        </div>
                        <div class="factor-detail">{{ f.detail }}</div>
                    </div>
                </div>
            </div>

            <div class="section" v-if="historyPoints.length > 1">
                <div class="section-title">Score History</div>
                <div class="section-card">
                    <svg :viewBox="`0 0 ${chartW} ${chartH}`" class="history-chart">
                        <polyline
                            :points="chartPoints"
                            fill="none"
                            :stroke="scoreColor"
                            stroke-width="2"
                            stroke-linejoin="round"
                            stroke-linecap="round"
                        />
                        <circle
                            v-for="(p, i) in chartCoords" :key="i"
                            :cx="p.x" :cy="p.y" r="3"
                            :fill="scoreColor"
                        />
                    </svg>
                    <div class="chart-labels">
                        <span>Oldest</span>
                        <span>Now</span>
                    </div>
                </div>
            </div>
        </div>
    </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { lua } from '@/bridge'

const creditData = ref({ score: 0, tier: {}, factors: {}, history: {} })
let creditRefreshInterval = null

const circumference = 2 * Math.PI * 85 * 0.75
const arcDasharray = computed(() => {
    const s = creditData.value.score || 300
    const pct = Math.max(0, Math.min(1, (s - 300) / 550))
    const len = circumference * pct
    return `${len} 9999`
})

const scoreColor = computed(() => {
    const s = creditData.value.score || 300
    if (s >= 750) return '#22c55e'
    if (s >= 550) return '#eab308'
    if (s >= 450) return '#f97316'
    return '#ef4444'
})

function barColor(pct) {
    if (pct >= 75) return '#22c55e'
    if (pct >= 50) return '#eab308'
    if (pct >= 25) return '#f97316'
    return '#ef4444'
}

function ageDays(ts) {
    if (!ts) return 'No history'
    const now = creditData.value.simTime || 0
    const days = Math.max(0, Math.floor((now - ts) / 1200))
    return `${days} day${days !== 1 ? 's' : ''} since first loan`
}

const factorCards = computed(() => {
    const f = creditData.value.factors || {}
    const h = creditData.value.history || {}
    const totalPayments = (h.onTimePayments || 0) + (h.missedPayments || 0)

    return [
        {
            label: 'Payment History', weight: 35,
            percent: Math.min(100, (f.paymentHistory || 0) * 100),
            color: barColor((f.paymentHistory || 0) * 100),
            detail: `${h.onTimePayments || 0} on-time / ${totalPayments} total`
        },
        {
            label: 'Credit Utilization', weight: 30,
            percent: Math.min(100, (f.utilization || 0) * 100),
            color: barColor((f.utilization || 0) * 100),
            detail: `${((1 - (f.utilization || 0)) * 100).toFixed(0)}% utilized`
        },
        {
            label: 'Credit Age', weight: 15,
            percent: Math.min(100, (f.creditAge || 0) * 100),
            color: barColor((f.creditAge || 0) * 100),
            detail: ageDays(h.firstLoanTimestamp)
        },
        {
            label: 'New Credit', weight: 10,
            percent: Math.min(100, (f.newCredit || 0) * 100),
            color: barColor((f.newCredit || 0) * 100),
            detail: `${(h.recentInquiries?.length || 0)} recent inquiries`
        },
        {
            label: 'Credit Mix', weight: 10,
            percent: Math.min(100, (f.creditMix || 0) * 100),
            color: barColor((f.creditMix || 0) * 100),
            detail: `${Object.keys(h.uniqueOrgs || {}).length} unique lenders`
        }
    ]
})

const chartW = 280
const chartH = 100
const historyPoints = computed(() => {
    const arr = creditData.value.history?.scoreHistory || []
    return arr.slice(-20)
})

const chartCoords = computed(() => {
    const pts = historyPoints.value
    if (pts.length < 2) return []
    const scores = pts.map(p => p.score)
    const minS = Math.min(...scores, 300)
    const maxS = Math.max(...scores, 850)
    const range = maxS - minS || 1
    const pad = 10
    return pts.map((p, i) => ({
        x: pad + (i / (pts.length - 1)) * (chartW - 2 * pad),
        y: pad + (1 - (p.score - minS) / range) * (chartH - 2 * pad)
    }))
})

const chartPoints = computed(() => chartCoords.value.map(p => `${p.x},${p.y}`).join(' '))

const refreshCredit = async () => {
    try {
        creditData.value = await lua.career_modules_credit.getScore() || creditData.value
    } catch (e) {
        console.error('Failed to load credit score:', e)
    }
}

onMounted(async () => {
    await refreshCredit()
    creditRefreshInterval = setInterval(refreshCredit, 5000)
})

onBeforeUnmount(() => {
    if (creditRefreshInterval) { clearInterval(creditRefreshInterval); creditRefreshInterval = null }
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
    background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-credit {
    padding: 10px;
    padding-top: 60px;
    color: #0f172a;
    height: 95%;
    overflow-y: auto;
    overflow-x: hidden;
    box-sizing: border-box;
    background: linear-gradient(180deg, #ffffff 0%, #f7f8fb 100%);

    &::-webkit-scrollbar { width: 8px; }
    &::-webkit-scrollbar-track { background: rgba(0,0,0,0.05); border-radius: 4px; }
    &::-webkit-scrollbar-thumb { background: rgba(0,0,0,0.2); border-radius: 4px; &:hover { background: rgba(0,0,0,0.3); } }
}

.section { margin-bottom: 14px; }

.section-title {
    font-weight: 800;
    font-size: 1.4rem;
    margin: 6px 2px;
}

.section-card {
    background: #ffffff;
    border: 1px solid #d4e2ff;
    border-radius: 14px;
    padding: 10px;
    box-shadow: 0 1px 2px rgba(16, 24, 40, .04), 0 4px 12px rgba(16, 24, 40, .05);
}

.score-section { display: flex; justify-content: center; }
.score-circle-wrap { width: 200px; height: 200px; }
.score-svg { width: 100%; height: 100%; }
.score-number { font-size: 3rem; font-weight: 800; }
.score-tier { font-size: 1.1rem; font-weight: 700; }
.score-range { font-size: 0.7rem; }

.factor-cards { display: flex; flex-direction: column; gap: 8px; }

.factor-card {
    background: #eef4ff;
    border-radius: 12px;
    padding: 10px 12px;
}

.factor-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 6px;
}

.factor-name { font-weight: 700; font-size: 0.95rem; }
.factor-weight { font-size: 0.8rem; color: #64748b; font-weight: 600; }

.factor-bar-track {
    height: 8px;
    background: rgba(0,0,0,0.08);
    border-radius: 4px;
    overflow: hidden;
    margin-bottom: 4px;
}

.factor-bar-fill {
    height: 100%;
    border-radius: 4px;
    transition: width 0.4s ease;
}

.factor-detail { font-size: 0.8rem; color: #64748b; }

.history-chart { width: 100%; height: auto; }

.chart-labels {
    display: flex;
    justify-content: space-between;
    font-size: 0.7rem;
    color: #94a3b8;
    margin-top: 4px;
}
</style>
