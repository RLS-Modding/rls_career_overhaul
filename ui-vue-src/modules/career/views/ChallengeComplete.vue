<template>
    <div class="cc-overlay">
        <div class="cc-modal" @click.stop>
            <div class="cc-header">
                <div class="cc-title">{{ name }}</div>
                <div class="cc-sub">{{ winConditionName }}</div>
            </div>

            <div class="cc-body">
                <div class="cc-section">
                    <div class="cc-section-title">Objective</div>
                    <div class="cc-kv">
                        <div class="cc-key">What you accomplished</div>
                        <div class="cc-val">
                            <template v-if="winCondition === 'payOffLoan'">
                                Paid off loan
                                <span v-if="loans && loans.amount">(${{ formatCurrency(loans.amount) }})</span>
                            </template>
                            <template v-else-if="winCondition === 'reachTargetMoney'">
                                Reached target: ${{ formatCurrency(targetMoney) }}
                            </template>
                            <template v-else>
                                {{ winConditionDescription || winConditionName || 'Completed challenge' }}
                            </template>
                        </div>
                    </div>
                </div>

                <div class="cc-section">
                    <div class="cc-section-title">Starting Conditions</div>
                    <div class="cc-grid2">
                        <div class="cc-kv">
                            <div class="cc-key">Starting Capital</div>
                            <div class="cc-val">${{ formatCurrency(startingCapital || 0) }}</div>
                        </div>
                        <div class="cc-kv">
                            <div class="cc-key">Starting Loan</div>
                            <div class="cc-val">
                                <span v-if="loans && loans.amount">${{ formatCurrency(loans.amount) }} @ {{
                                    toPercent(loans.interest) }}
                                    • {{ loans.payments }} payments</span>
                                <span v-else>None</span>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="cc-section">
                    <div class="cc-section-title">Highlights</div>
                    <div class="cc-grid2">
                        <div class="cc-kv">
                            <div class="cc-key">Top Earner</div>
                            <div class="cc-val">{{ topEarner.label }} (+${{ formatCurrency(topEarner.amount) }})</div>
                        </div>
                        <div class="cc-kv">
                            <div class="cc-key">Top Expense</div>
                            <div class="cc-val">{{ topExpense.label }} (-${{ formatCurrency(topExpense.amount) }})</div>
                        </div>
                        <div class="cc-kv">
                            <div class="cc-key">Time Spent</div>
                            <div class="cc-val">{{ formatDuration(simulationTimeSpent) }}</div>
                        </div>
                    </div>
                </div>

            </div>

            <div class="cc-footer">
                <button class="cc-primary" @click="onContinue">Continue</button>
            </div>
        </div>
    </div>
</template>

<script setup>
import { onMounted, onBeforeUnmount, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useEvents } from '@/services/events'
import { lua } from '@/bridge'

const events = useEvents()
const router = useRouter()

const id = ref('')
const name = ref('')
const description = ref('')
const winCondition = ref('')
const winConditionName = ref('')
const winConditionDescription = ref('')
const targetMoney = ref(0)
const simulationTimeSpent = ref(0)
const startingCapital = ref(0)
const loans = ref(null)

const topEarner = ref({ label: '—', amount: 0 })
const topExpense = ref({ label: '—', amount: 0 })

const formatCurrency = (v) => {
    v = Number(v || 0)
    if (v >= 1e6) return (v / 1e6).toFixed(2).replace(/\.00$/, '') + 'M'
    if (v >= 1e3) return (v / 1e3).toFixed(2).replace(/\.00$/, '') + 'k'
    return v.toFixed(0)
}
const toPercent = (v) => `${Math.round((Number(v || 0)) * 100)}%`
const formatDuration = (seconds) => {
    seconds = Math.max(0, Number(seconds || 0))
    const h = Math.floor(seconds / 3600)
    const m = Math.floor((seconds % 3600) / 60)
    const s = Math.floor(seconds % 60)
    const ms = Math.floor((seconds % 1) * 1000)
    const parts = []
    if (h) parts.push(`${h}h`)
    if (m) parts.push(`${m}m`)
    parts.push(`${s}s`)
    if (ms || (!h && !m && s === 0)) parts.push(`${ms}ms`)
    return parts.join(' ')
}

async function loadTopEntries() {
    try {
        const log = await lua.career_modules_playerAttributes.getAttributeLog()
        if (Array.isArray(log)) {
            const gains = {}
            const losses = {}
            for (const entry of log) {
                if (!entry || !entry.attributeChange || !entry.reason) continue
                const money = Number(entry.attributeChange.money || 0)
                const label = String(entry.reason.label || 'Unknown')
                if (money > 0) {
                    gains[label] = (gains[label] || 0) + money
                } else if (money < 0) {
                    losses[label] = (losses[label] || 0) + Math.abs(money)
                }
            }
            let topGain = { label: '—', amount: 0 }
            for (const [label, amt] of Object.entries(gains)) {
                if (amt > topGain.amount) topGain = { label, amount: amt }
            }
            let topLoss = { label: '—', amount: 0 }
            for (const [label, amt] of Object.entries(losses)) {
                if (amt > topLoss.amount) topLoss = { label, amount: amt }
            }
            topEarner.value = topGain
            topExpense.value = topLoss
        }
    } catch (e) {
        // ignore
    }
}

function onContinue() {
    router.back()
}

onMounted(() => {
    events.on('challengeCompleteData', (data) => {
        console.log('Challenge completion data:', data)
        
        if (data) {
            id.value = data.id || ''
            name.value = data.name || 'Challenge Complete'
            description.value = data.description || ''
            winCondition.value = data.winCondition || ''
            winConditionName.value = data.winConditionName || ''
            winConditionDescription.value = data.winConditionDescription || ''
            targetMoney.value = Number(data.targetMoney || 0)
            simulationTimeSpent.value = Number(data.simulationTimeSpent || 0)
            startingCapital.value = Number(data.startingCapital || 0)
            loans.value = data.loans || null
            
            loadTopEntries()
        }
    })
    
    lua.career_challengeModes.requestChallengeCompleteData()
})

onBeforeUnmount(() => {
    events.off('challengeCompleteData')
})
</script>

<style scoped lang="scss">
.cc-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.45);
    backdrop-filter: blur(6px);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 3000;
}

.cc-modal {
    width: min(56rem, calc(100% - 2rem));
    background: rgba(15, 23, 42, 0.98);
    border: 1px solid rgba(71, 85, 105, 0.6);
    border-radius: 16px;
    box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
    color: #fff;
    padding: 1rem;
}

.cc-header {
    text-align: center;
}

.cc-title {
    font-size: 1.8rem;
    font-weight: 700;
}

.cc-sub {
    opacity: 0.9;
    margin-top: 0.25rem;
}

.cc-body {
    margin-top: 0.75rem;
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.cc-section {
    background: rgba(30, 41, 59, 0.6);
    border: 1px solid rgba(100, 116, 139, 0.35);
    border-radius: 12px;
    padding: 0.75rem;
}

.cc-section-title {
    font-weight: 600;
    margin-bottom: 0.5rem;
}

.cc-grid2 {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0.5rem 1rem;
}

.cc-kv {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 0.5rem;
    align-items: center;
}

.cc-key {
    color: #cbd5e1;
}

.cc-val {
    font-weight: 700;
}

.cc-footer {
    display: flex;
    justify-content: flex-end;
    margin-top: 0.75rem;
}

.cc-primary {
    background: linear-gradient(90deg, #2563eb, #1d4ed8);
    border: 0;
    color: #fff;
    padding: 0.6rem 1rem;
    border-radius: 8px;
    cursor: pointer;
}
</style>
