<template>
    <PhoneWrapper app-name="Loans">
        <div class="phone-loans">
            <!-- Gear icon -->
            <button class="settings-gear" @click="openSettings">
                <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="#475569" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
                    <circle cx="10" cy="10" r="3" />
                    <path d="M16.5 12.3a1.2 1.2 0 0 0 .2 1.3l.1.1a1.5 1.5 0 1 1-2.1 2.1l-.1-.1a1.2 1.2 0 0 0-1.3-.2 1.2 1.2 0 0 0-.7 1.1v.1a1.5 1.5 0 1 1-3 0v-.1a1.2 1.2 0 0 0-.8-1.1 1.2 1.2 0 0 0-1.3.2l-.1.1a1.5 1.5 0 1 1-2.1-2.1l.1-.1a1.2 1.2 0 0 0 .2-1.3 1.2 1.2 0 0 0-1.1-.7h-.1a1.5 1.5 0 0 1 0-3h.1a1.2 1.2 0 0 0 1.1-.8 1.2 1.2 0 0 0-.2-1.3l-.1-.1a1.5 1.5 0 1 1 2.1-2.1l.1.1a1.2 1.2 0 0 0 1.3.2h.1a1.2 1.2 0 0 0 .7-1.1v-.1a1.5 1.5 0 0 1 3 0v.1a1.2 1.2 0 0 0 .7 1.1 1.2 1.2 0 0 0 1.3-.2l.1-.1a1.5 1.5 0 0 1 2.1 2.1l-.1.1a1.2 1.2 0 0 0-.2 1.3v.1a1.2 1.2 0 0 0 1.1.7h.1a1.5 1.5 0 0 1 0 3h-.1a1.2 1.2 0 0 0-1.1.7z" />
                </svg>
            </button>

            <!-- My Loans (always at top) -->
            <div class="section" v-if="activeLoans.length > 0">
                <div class="section-title">My Loans</div>

                <!-- Single loan: show directly -->
                <div v-if="activeLoans.length === 1" class="section-card">
                    <button class="loan-card" @click="openLoan(activeLoans[0].id)">
                        <div class="header">
                            <div class="name">{{ activeLoans[0].orgName || activeLoans[0].orgId }}</div>
                            <div class="rate">{{ fmtRate(activeLoans[0]) }}</div>
                        </div>
                        <div class="amount">
                            <BngIcon class="amount-icon" :type="icons.beamCurrency" />
                            <BngUnit :money="activeLoans[0].principalOutstanding" no-icon />
                        </div>
                        <div class="chips">
                            <span class="chip">{{ activeLoans[0].paymentsRemaining }} left</span>
                            <span class="chip">Next {{ formatDue(activeLoans[0].secondsUntilNextPayment) }}</span>
                        </div>
                    </button>
                </div>

                <!-- Multiple loans: summary with dropdown -->
                <div v-else class="section-card">
                    <div class="summary-row">
                        <div class="summary-label">Total Outstanding</div>
                        <div class="summary-amount">
                            <BngIcon class="summary-icon" :type="icons.beamCurrency" />
                            <BngUnit :money="totalOutstanding" no-icon />
                        </div>
                        <div class="summary-meta">
                            {{ activeLoans.length }} loans
                            <span class="summary-dot"></span>
                            Avg {{ avgRate }}
                        </div>
                    </div>
                    <button class="expand-toggle" @click="loansExpanded = !loansExpanded">
                        <span>{{ loansExpanded ? 'Hide' : 'Show' }} all loans</span>
                        <span class="expand-chevron" :class="{ open: loansExpanded }">&#9662;</span>
                    </button>
                    <transition name="expand">
                        <div v-if="loansExpanded" class="loan-cards">
                            <button class="loan-card" v-for="l in activeLoans" :key="l.id" @click="openLoan(l.id)">
                                <div class="header">
                                    <div class="name">{{ l.orgName || l.orgId }}</div>
                                    <div class="rate">{{ fmtRate(l) }}</div>
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
                    </transition>
                </div>
            </div>

            <div class="section" v-else>
                <div class="section-title">My Loans</div>
                <div class="section-card">
                    <div class="none">No active loans</div>
                </div>
            </div>

            <!-- Credit Score -->
            <button class="credit-widget" @click="openCredit">
                <div class="credit-left">
                    <div class="credit-label">Credit Score</div>
                    <div class="credit-score" :style="{ color: scoreColor }">{{ creditData.score || '—' }}</div>
                </div>
                <div class="credit-right">
                    <div class="credit-tier" :style="{ color: scoreColor }">{{ creditData.tier?.label || '' }}</div>
                    <span class="credit-arrow">&#8250;</span>
                </div>
            </button>

            <!-- New Loan -->
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
                                <div class="percent" :style="{ color: getRateColor(o.rate) }">{{ (o.rate * 100).toFixed(0) }}%</div>
                                <div class="max"><BngUnit :money="o.max" no-icon /></div>
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
import { BngUnit, BngIcon, icons } from '@/common/components/base'
import { lua, useBridge } from '@/bridge'
import { useRouter } from 'vue-router'

const { events } = useBridge()
const router = useRouter()

const creditData = ref({ score: 0, tier: {}, factors: {}, history: {} })
let creditRefreshInterval = null
const loansExpanded = ref(false)

const scoreColor = computed(() => {
    const s = creditData.value.score || 300
    if (s >= 750) return '#22c55e'
    if (s >= 550) return '#eab308'
    if (s >= 450) return '#f97316'
    return '#ef4444'
})

const refreshCredit = async () => {
    try {
        creditData.value = await lua.career_modules_credit.getScore() || creditData.value
    } catch (e) {
        console.error('Failed to load credit score:', e)
    }
}

const offers = ref([])
const selectedOrgId = ref(null)
const activeLoans = ref([])
const prepayAmounts = ref({})
const pauseTicks = ref(false)
const availableFunds = ref(0)

const totalOutstanding = computed(() => activeLoans.value.reduce((sum, l) => sum + (l.principalOutstanding || 0), 0))
const avgRate = computed(() => {
    if (activeLoans.value.length === 0) return '0%'
    const avg = activeLoans.value.reduce((sum, l) => sum + ((l.currentRate ?? l.rate) || 0), 0) / activeLoans.value.length
    return (avg * 100).toFixed(1).replace(/\.0$/, '') + '%'
})

const fmtRate = (l) => (((l.currentRate ?? l.rate) || 0) * 100).toFixed(1).replace(/\.0$/, '') + '%'

const formatDue = (secondsUntilNextPayment) => {
    if (secondsUntilNextPayment == null) return 'soon'
    const d = Math.max(0, Math.floor(secondsUntilNextPayment))
    const m = Math.floor(d / 60)
    const s = d % 60
    if (m > 0) return `${m}m ${s}s`
    return `${s}s`
}

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
    } catch { }
}

onMounted(async () => {
    await refreshCredit()
    creditRefreshInterval = setInterval(refreshCredit, 5000)
    await refreshOffers()
    await refreshActiveLoans()
    events.on('loans:activeUpdated', async () => { await refreshActiveLoans(); await refreshOffers() })
    events.on('loans:tick', (data) => { if (!pauseTicks.value && Array.isArray(data)) activeLoans.value = data })
    events.on('loans:funds', (money) => { if (typeof money === 'number') availableFunds.value = money })
    events.on('loans:completed', async () => { await refreshActiveLoans(); await refreshOffers() })
    try { availableFunds.value = await lua.career_modules_loans.getAvailableFunds() } catch { }
})

onBeforeUnmount(() => {
    if (creditRefreshInterval) { clearInterval(creditRefreshInterval); creditRefreshInterval = null }
})

const openLoan = (id) => { router.push({ name: 'phone-loan-details', params: { loanId: String(id) } }) }
const openOffer = (id) => { router.push({ name: 'phone-offer-details', params: { orgId: String(id) } }) }
const openCredit = () => { router.push({ name: 'phone-credit' }) }
const openSettings = () => { router.push({ name: 'phone-loan-settings' }) }

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
    position: relative;

    &::-webkit-scrollbar { width: 8px; }
    &::-webkit-scrollbar-track { background: rgba(0,0,0,0.05); border-radius: 4px; }
    &::-webkit-scrollbar-thumb { background: rgba(0,0,0,0.2); border-radius: 4px; &:hover { background: rgba(0,0,0,0.3); } }
}

.settings-gear {
    position: absolute;
    top: 64px;
    right: 12px;
    width: 34px;
    height: 34px;
    display: grid;
    place-items: center;
    background: #ffffff;
    border: 1px solid #d4e2ff;
    border-radius: 10px;
    cursor: pointer;
    z-index: 5;
    box-shadow: 0 1px 3px rgba(16, 24, 40, .06);
    transition: transform 0.12s ease, box-shadow 0.2s ease;

    &:hover { transform: scale(1.08); box-shadow: 0 2px 6px rgba(16, 24, 40, .12); }
    &:active { transform: scale(0.95); }
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

/* Summary */
.summary-row { padding: 4px 2px 8px; }
.summary-label { font-size: 0.8rem; color: #64748b; font-weight: 600; }

.summary-amount {
    display: flex;
    align-items: baseline;
    font-size: 2rem;
    font-weight: 800;
    gap: 6px;
    margin: 2px 0;
}

.summary-icon { color: #000; font-size: 1.6rem; }

.summary-meta {
    font-size: 0.8rem;
    color: #64748b;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 6px;
}

.summary-dot {
    width: 3px;
    height: 3px;
    border-radius: 50%;
    background: #94a3b8;
}

/* Expand toggle */
.expand-toggle {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    padding: 8px 4px;
    border: 0;
    border-top: 1px solid #e8edf5;
    background: none;
    color: #475569;
    font-size: 0.85rem;
    font-weight: 600;
    cursor: pointer;

    &:hover { color: #1e293b; }
}

.expand-chevron {
    font-size: 0.9rem;
    transition: transform 0.2s ease;
    &.open { transform: rotate(180deg); }
}

.expand-enter-active, .expand-leave-active {
    transition: all 0.25s ease;
    overflow: hidden;
}
.expand-enter-from, .expand-leave-to {
    opacity: 0;
    max-height: 0;
}
.expand-enter-to, .expand-leave-from {
    opacity: 1;
    max-height: 600px;
}

/* Loan cards */
.loan-cards {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding-top: 8px;
}

.loan-card {
    background: #eef4ff;
    border-radius: 12px;
    padding: 12px;
    text-align: left;
    width: 100%;
    border: 0;
    color: inherit;
    transition: transform .08s ease, box-shadow .2s ease;
    cursor: pointer;
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

.amount-icon { color: #000; font-size: 2rem; }

.chips { display: flex; gap: 6px; flex-wrap: wrap; }

.chip {
    background: #e2ecff;
    color: #334155;
    padding: 4px 10px;
    border-radius: 999px;
    border: 1px solid #c9d8ff;
}

/* Credit widget */
.credit-widget {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: #ffffff;
    border: 1px solid #d4e2ff;
    border-radius: 14px;
    padding: 14px 16px;
    width: 100%;
    margin-bottom: 14px;
    cursor: pointer;
    transition: transform 0.08s ease, box-shadow 0.2s ease;
    box-shadow: 0 1px 2px rgba(16, 24, 40, .04), 0 4px 12px rgba(16, 24, 40, .05);

    &:hover {
        transform: translateY(-1px);
        box-shadow: 0 2px 8px rgba(16, 24, 40, .1);
    }

    border: 0;
    color: inherit;
    text-align: left;
}

.credit-label { font-size: 0.85rem; color: #64748b; font-weight: 600; margin-bottom: 2px; }
.credit-score { font-size: 2rem; font-weight: 800; }
.credit-right { display: flex; align-items: center; gap: 8px; }
.credit-tier { font-size: 0.9rem; font-weight: 700; }
.credit-arrow { color: #94a3b8; font-size: 1.4rem; font-weight: 600; line-height: 1; }

/* Offers */
.offers { display: flex; flex-direction: column; gap: 6px; }

.offer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: #eef4ff;
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

.offer-left { display: flex; align-items: center; gap: 10px; }

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

.offer-right { display: grid; gap: 2px; justify-items: end; }
.percent { font-weight: 800; }
.max { color: #475569; }
.none { color: #475569; }
</style>
