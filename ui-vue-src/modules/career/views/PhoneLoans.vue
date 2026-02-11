<template>
    <PhoneWrapper app-name="Loans">
        <div class="phone-loans">
            <!-- Credit Score -->
            <div class="section score-section">
                <div class="score-circle-wrap">
                    <svg viewBox="0 0 200 200" class="score-svg">
                        <circle cx="100" cy="100" r="85" fill="none" stroke="rgba(0,0,0,0.1)" stroke-width="12" />
                        <circle
                            cx="100" cy="100" r="85"
                            fill="none"
                            :stroke="scoreColor"
                            stroke-width="12"
                            stroke-linecap="round"
                            :stroke-dasharray="circumference"
                            :stroke-dashoffset="arcOffset"
                            transform="rotate(-225 100 100)"
                        />
                        <text x="100" y="90" text-anchor="middle" class="score-number" fill="#0f172a">{{ creditData.score || '—' }}</text>
                        <text x="100" y="115" text-anchor="middle" class="score-tier" :fill="scoreColor">{{ creditData.tier?.label || '' }}</text>
                        <text x="100" y="135" text-anchor="middle" class="score-range" fill="#94a3b8">300 – 850</text>
                    </svg>
                </div>
            </div>

            <!-- Credit Factors -->
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

            <!-- Score History -->
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

            <!-- Credit Tip -->
            <div class="section" v-if="creditTip">
                <div class="section-card tip-card">
                    <span class="tip-icon">💡</span>
                    <p class="tip-text">{{ creditTip }}</p>
                </div>
            </div>

            <div class="section">
                <div class="section-title">Settings</div>
                <div class="section-card">
                    <div class="notification-toggle">
                        <label class="toggle-label">
                            <input type="checkbox" v-model="notificationsEnabled" @change="toggleNotifications" />
                            <span class="toggle-slider"></span>
                            <span class="toggle-text">Enable Loan Notifications</span>
                        </label>
                    </div>
                </div>
            </div>

            <div class="section">
                <div class="section-title">My Loans</div>
                <div class="section-card">
                    <div v-if="activeLoans.length === 0" class="none">No active loans</div>
                    <div v-else class="loan-cards">
                        <button class="loan-card" v-for="l in activeLoans" :key="l.id" @click="openLoan(l.id)">
                            <div class="header">
                                <div class="name">{{ l.orgName || l.orgId }}</div>
                                <div class="rate">{{ (((l.currentRate ?? l.rate) || 0) * 100).toFixed(1).replace(/\.0$/,
                                    '') }}%</div>
                            </div>
                            <div class="amount">
                                <BngIcon class="amount-icon" :type="icons.beamCurrency" />
                                <BngUnit :money="l.principalOutstanding" no-icon />
                            </div>
                            <div class="chips">
                                <span class="chip">{{ l.paymentsRemaining }} left</span>
                                <span class="chip">Next {{ formatDue(l.secondsUntilNextPayment) }}</span>
                            </div>
                        </button>
                    </div>
                </div>
            </div>

            <div class="section">
                <div class="section-title">New Loan</div>
                <div class="section-card">
                    <div class="offers" v-if="offers.length">
                        <button class="offer" v-for="o in offers" :key="o.id" @click="openOffer(o.id)">
                            <div class="offer-left">
                <div class="symbol" :style="{ background: getColorForOrg(o.id) }">
                  <BngIcon :type="icons.beamCurrency" :style="{ color: '#fff' }" />
                                </div>
                                <div class="name">{{ o.name }}</div>
                            </div>
                            <div class="offer-right">
                                <div class="percent" :style="{ color: getRateColor(o.rate) }">{{ (o.rate *
                                    100).toFixed(0) }}%</div>
                                <div class="max">
                                    <BngUnit :money="o.max" no-icon />
                                </div>
                            </div>
                        </button>
                    </div>
                    <div v-else class="none">No offers</div>
                </div>
            </div>
        </div>
    </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngButton, BngUnit, BngIcon, icons, ACCENTS } from '@/common/components/base'
import { vBngTextInput } from '@/common/directives'
import { lua, useBridge } from '@/bridge'
import { useRouter } from 'vue-router'

const { events } = useBridge()
const router = useRouter()

// ── Credit Score State ──────────────────────────────────────────────
const creditData = ref({ score: 0, tier: {}, factors: {}, history: {} })
let creditRefreshInterval = null

const circumference = 2 * Math.PI * 85 * 0.75 // 270° arc
const arcOffset = computed(() => {
    const s = creditData.value.score || 300
    const pct = Math.max(0, Math.min(1, (s - 300) / 550))
    return circumference * (1 - pct)
})

const scoreColor = computed(() => {
    const s = creditData.value.score || 0
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
    const now = Date.now() / 1000
    const days = Math.max(0, Math.floor((now - ts) / 86400))
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
            percent: Math.min(100, 100 - (f.utilization || 0) * 100),
            color: barColor(100 - (f.utilization || 0) * 100),
            detail: `${((f.utilization || 0) * 100).toFixed(0)}% utilized`
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
            detail: `${h.recentInquiries || 0} recent inquiries`
        },
        {
            label: 'Credit Mix', weight: 10,
            percent: Math.min(100, (f.creditMix || 0) * 100),
            color: barColor((f.creditMix || 0) * 100),
            detail: `${h.uniqueOrgs || 0} unique lenders`
        }
    ]
})

// Score history chart
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

// Contextual tip
const creditTips = {
    paymentHistory: 'Make all loan payments on time to build a strong payment history.',
    utilization: 'Try to keep your credit utilization below 30% of available credit.',
    creditAge: 'A longer credit history improves your score — keep old accounts active.',
    newCredit: 'Avoid applying for too many loans in a short period.',
    creditMix: 'Having loans from different lenders shows financial diversity.'
}

const creditTip = computed(() => {
    const f = creditData.value.factors || {}
    let weakest = null
    let weakVal = Infinity
    const keys = ['paymentHistory', 'utilization', 'creditAge', 'newCredit', 'creditMix']
    for (const k of keys) {
        const v = f[k] ?? 1
        if (v < weakVal) { weakVal = v; weakest = k }
    }
    return weakest ? creditTips[weakest] : null
})

const refreshCredit = async () => {
    try {
        creditData.value = await lua.career_modules_credit.getScore() || creditData.value
    } catch (e) {
        console.error('Failed to load credit score:', e)
    }
}

// ── Loans State ─────────────────────────────────────────────────────
const offers = ref([])
const selectedOrgId = ref(null)
const selectedOffer = computed(() => offers.value.find(o => o.id === selectedOrgId.value))
const amount = ref(0)
const term = ref(null)
const perPayment = ref(0)
const totalRepay = ref(0)
const activeLoans = ref([])
const prepayAmounts = ref({})
const pauseTicks = ref(false)
const availableFunds = ref(0)
const notificationsEnabled = ref(true)

const canTakeLoan = computed(() => selectedOffer.value && amount.value > 0 && term.value)

const formatDue = (secondsUntilNextPayment) => {
    if (secondsUntilNextPayment == null) return 'soon'
    const d = Math.max(0, Math.floor(secondsUntilNextPayment))
    const m = Math.floor(d / 60)
    const s = d % 60
    if (m > 0) return `${m}m ${s}s`
    return `${s}s`
}

const computePayment = async () => { /* no-op for main list */ }
const onOrgChange = () => { amount.value = 0; term.value = selectedOffer.value?.terms?.[0] || null }
const setTerm = (t) => { term.value = t; computePayment() }

const formatTermDuration = (numPayments) => {
    const totalMinutes = numPayments * 5
    const hours = Math.floor(totalMinutes / 60)
    const minutes = totalMinutes % 60
    const hm = `${hours > 0 ? hours + 'h ' : ''}${minutes > 0 ? minutes + 'm' : ''}`
    return `${hm}`
}

const onAmountSlide = () => { }
const onAmountInput = () => {
    if (!selectedOffer.value) return
    if (amount.value < 0) amount.value = 0
    if (amount.value > selectedOffer.value.max) amount.value = selectedOffer.value.max
    amount.value = Math.round(amount.value / 500) * 500
    computePayment()
}
const onAmountBlur = () => { pauseTicks.value = false; computePayment() }

const selectOffer = (id) => { selectedOrgId.value = id; onOrgChange() }
const takeLoan = async () => { }

const refreshActiveLoans = async () => {
    try {
        const loans = await lua.career_modules_loans.getActiveLoans()
    activeLoans.value = Array.isArray(loans) ? loans : []
    const map = {}
    for (const l of activeLoans.value) map[l.id] = prepayAmounts.value[l.id] || 0
    prepayAmounts.value = map
    } catch { activeLoans.value = [] }
}

const refreshOffers = async () => {
    try {
        const res = await lua.career_modules_loans.getLoanOffers()
    const prev = selectedOrgId.value
    offers.value = Array.isArray(res) ? res : []
    if (!offers.value.find(o => o.id === prev)) selectedOrgId.value = offers.value[0]?.id || null
    onOrgChange()
    } catch { }
}

onMounted(async () => {
    // Credit score
    await refreshCredit()
    creditRefreshInterval = setInterval(refreshCredit, 5000)

    // Loans
    await refreshOffers()
    await refreshActiveLoans()
    events.on('loans:activeUpdated', async () => { await refreshActiveLoans(); await refreshOffers() })
    events.on('loans:tick', (data) => { if (!pauseTicks.value && Array.isArray(data)) activeLoans.value = data })
    events.on('loans:funds', (money) => { if (typeof money === 'number') availableFunds.value = money })
    events.on('loans:completed', async () => { await refreshActiveLoans(); await refreshOffers() })
    events.on('loans:notificationsUpdated', (enabled) => {
        notificationsEnabled.value = enabled
    })
    try { availableFunds.value = await lua.career_modules_loans.getAvailableFunds() } catch { }
})

onBeforeUnmount(() => {
    if (creditRefreshInterval) { clearInterval(creditRefreshInterval); creditRefreshInterval = null }
})

const adjustedRate = computed(() => {
    if (!selectedOffer.value || !term.value) return selectedOffer.value?.rate || 0
    const base = selectedOffer.value.rate || 0
    const step = (term.value / 12) - 1
    const mul = step > 0 ? (1 + 0.1 * step) : 1
    return base * mul
})
const adjustedRateDisplay = computed(() => ((adjustedRate.value * 100).toFixed(1).replace(/\.0$/, '')) + '%')

const prepay = async (loanId) => {
    const amount = Math.max(0, Math.floor(prepayAmounts.value[loanId] || 0))
    if (!amount) return
    try {
        await lua.career_modules_loans.prepayLoan(loanId, amount)
    prepayAmounts.value[loanId] = 0
        await refreshActiveLoans()
        await refreshOffers()
    } catch { }
}

const setPayMax = (loan) => {
    const nextInterest = Math.max(0, (loan.nextPaymentInterest ?? Math.max(0, (loan.perPayment - (loan.basePayment || 0)))))
    const rawMax = (loan.principalOutstanding || 0) + nextInterest
    const roundedUp = Math.ceil(rawMax + 1e-6)
    const amount = Math.min(availableFunds.value, roundedUp)
    prepayAmounts.value[loan.id] = amount
}

const toggleNotifications = () => {
    lua.career_modules_loans.setNotificationsEnabled(notificationsEnabled.value)
}

const loadNotificationSetting = () => {
    const enabled = lua.career_modules_loans.getNotificationsEnabled()
    notificationsEnabled.value = enabled
}

const termBtnCustomStyle = {
    '--bng-button-custom-enabled': '#666',
    '--bng-button-custom-hover': '#777',
    '--bng-button-custom-active': '#555',
    '--bng-button-custom-disabled': '#666',
    '--bng-button-custom-enabled-opacity': 1,
    '--bng-button-custom-hover-opacity': 1,
    '--bng-button-custom-active-opacity': 1,
    '--bng-button-custom-disabled-opacity': 1,
}

// Navigation helpers
const openLoan = (id) => { router.push({ name: 'phone-loan-details', params: { loanId: String(id) } }) }
const openOffer = (id) => { router.push({ name: 'phone-offer-details', params: { orgId: String(id) } }) }

// Visual helpers
const getRateColor = (rate) => {
    const p = (rate || 0)
    if (p >= 0.24) return '#ff7a00'
    if (p >= 0.2) return '#2ecc71'
    return '#5a8dee'
}
const orgColors = ['#ff7a00', '#2ecc71', '#5a8dee', '#8e44ad', '#27ae60']
const getColorForOrg = (id) => orgColors[Math.abs(String(id).split('').reduce((a, c) => a + c.charCodeAt(0), 0)) % orgColors.length]
</script>

<style scoped lang="scss">
:deep(.phone-content) {
    background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-loans {
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

.section {
    margin-bottom: 14px;
}

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

/* Credit Score Circle */
.score-section { display: flex; justify-content: center; }

.score-circle-wrap {
    width: 200px;
    height: 200px;
}

.score-svg { width: 100%; height: 100%; }
.score-number { font-size: 3rem; font-weight: 800; }
.score-tier { font-size: 1.1rem; font-weight: 700; }
.score-range { font-size: 0.7rem; }

/* Factor Cards */
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

/* History Chart */
.history-chart { width: 100%; height: auto; }

.chart-labels {
    display: flex;
    justify-content: space-between;
    font-size: 0.7rem;
    color: #94a3b8;
    margin-top: 4px;
}

/* Tip */
.tip-card {
    display: flex;
    align-items: flex-start;
    gap: 10px;
}

.tip-icon { font-size: 1.3rem; flex-shrink: 0; margin-top: 1px; }
.tip-text { margin: 0; font-size: 0.9rem; color: #475569; line-height: 1.4; }

/* Loans */
.loan-cards {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.loan-card {
    background: #eef4ff;
    border: 1px solid #c9d8ff;
    border-radius: 12px;
    padding: 12px;
    text-align: left;
    width: 100%;
    border: 0;
    color: inherit;
    transition: transform .08s ease, box-shadow .2s ease;
}

.loan-card:hover {
    transform: translateY(-1px);
    box-shadow: 0 2px 8px rgba(16, 24, 40, .07);
}

.loan-card .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.loan-card .name { font-weight: 700; }
.loan-card .rate { color: #475569; font-weight: 700; }

.loan-card .amount {
    margin: 6px 0;
    display: flex;
    align-items: baseline;
    font-size: 2.25rem;
    gap: 8px;
}

.amount-icon {
    color: #000;
    font-size: 2rem;
}

.chips {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
}

.chip {
    background: #e2ecff;
    color: #334155;
    padding: 4px 10px;
    border-radius: 999px;
    border: 1px solid #c9d8ff;
}

.offers {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.offer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: #eef4ff;
    border: 1px solid #c9d8ff;
    padding: 10px;
    border-radius: 12px;
    width: 100%;
    border: 0;
    color: inherit;
    text-align: left;
    transition: transform .12s ease, box-shadow .2s ease;
}

.offer:hover { transform: translateY(-1px) scale(1.02); box-shadow: 0 4px 12px rgba(16,24,40,.12); }
.offer:active { transform: scale(0.98); }

.offer-left {
    display: flex;
    align-items: center;
    gap: 10px;
}

.symbol {
    width: 36px;
    height: 36px;
    border-radius: 10px;
    display: grid;
    place-items: center;
    font-weight: 800;
    color: #ffffff;
    box-shadow: inset 0 -2px 0 rgba(0, 0, 0, .15);
}

.offer-right {
    display: grid;
    gap: 2px;
    justify-items: end;
}

.percent { font-weight: 800; }
.max { color: #475569; }
.none { color: #475569; }

/* Notification Toggle */
.notification-toggle { padding: 8px 0; }

.toggle-label {
    display: flex;
    align-items: center;
    gap: 12px;
    cursor: pointer;
    font-size: 0.95em;
}

.toggle-label input[type="checkbox"] { display: none; }

.toggle-slider {
    position: relative;
    width: 44px;
    height: 24px;
    background: rgba(255, 255, 255, 0.2);
    border-radius: 12px;
    transition: background-color 0.3s ease;
}

.toggle-slider::before {
    content: '';
    position: absolute;
    top: 2px;
    left: 2px;
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    transition: transform 0.3s ease;
}

.toggle-label input[type="checkbox"]:checked + .toggle-slider { background: #cc4c00; }
.toggle-label input[type="checkbox"]:checked + .toggle-slider::before { transform: translateX(20px); }
.toggle-text { color: #0f172a; font-weight: 600; }
</style>
