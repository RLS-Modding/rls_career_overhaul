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
                        <text x="100" y="90" text-anchor="middle" class="score-number" fill="#0f172a">{{ creditData.score || '-' }}</text>
                        <text x="100" y="115" text-anchor="middle" class="score-tier" :fill="scoreColor">{{ creditData.tier?.label || '' }}</text>
                        <text x="100" y="135" text-anchor="middle" class="score-range" fill="#94a3b8">300 - 850</text>
                    </svg>
                </div>
            </div>

            <div class="section section-card">
                <div class="section-title">Credit Factors</div>
                <div class="factor-list">
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
import { lua, useBridge } from '@/bridge'

const creditData = ref({ score: 0, tier: {}, factors: {}, history: {} })
const { events } = useBridge()
let creditUpdatedHandler

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
    creditUpdatedHandler = (payload = {}) => {
        if (payload && typeof payload === 'object' && payload.score !== undefined) {
            creditData.value = payload
            return
        }
        void refreshCredit()
    }
    events.on('credit:updated', creditUpdatedHandler)
    await refreshCredit()
})

onBeforeUnmount(() => {
    if (creditUpdatedHandler) events.off('credit:updated', creditUpdatedHandler)
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
    background:
        radial-gradient(110% 80% at 50% -10%, rgba(99, 102, 241, 0.35) 0%, rgba(99, 102, 241, 0) 70%),
        linear-gradient(180deg, #030712 0%, #0b1227 56%, #0f172a 100%);
}

.phone-credit {
    padding: 12px;
    padding-top: 58px;
    color: #e2e8f0;
    height: 95%;
    overflow-y: auto;
    overflow-x: hidden;
    box-sizing: border-box;
    background: transparent;

    &::-webkit-scrollbar { width: 7px; }
    &::-webkit-scrollbar-track { background: rgba(148, 163, 184, 0.12); border-radius: 999px; }
    &::-webkit-scrollbar-thumb {
        background: rgba(148, 163, 184, 0.4);
        border-radius: 999px;
        &:hover { background: rgba(148, 163, 184, 0.55); }
    }
}

.section { margin-bottom: 14px; }

.section-title {
    font-size: 0.75rem;
    letter-spacing: 0.11em;
    text-transform: uppercase;
    font-weight: 700;
    margin: 2px 3px 8px;
    color: #93c5fd;
    opacity: 0.95;
}

.section-card {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.8) 100%);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 14px;
    padding: 12px;
    backdrop-filter: blur(12px);
    box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);
}

.score-section { display: flex; justify-content: center; }
.score-circle-wrap { width: 200px; height: 200px; }
.score-svg { width: 100%; height: 100%; }
.score-number { font-size: 3rem; font-weight: 800; fill: #f8fafc; }
.score-tier { font-size: 1.1rem; font-weight: 700; }
.score-range { font-size: 0.7rem; }

.factor-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.factor-card {
    background: transparent;
    border: 0;
    padding: 10px 12px;
}

.factor-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 6px;
}

.factor-name { font-weight: 700; font-size: 0.95rem; color: #f8fafc; }
.factor-weight { font-size: 0.8rem; color: #94a3b8; font-weight: 600; }

.factor-bar-track {
    height: 8px;
    background: rgba(15, 23, 42, 0.8);
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


