<template>
    <PhoneWrapper app-name="Loans">
        <div class="phone-loans">
            <!-- My Loans (always at top) -->
            <div class="section" v-if="allLoans.length > 0">
                <div class="section-header">
                    <div class="section-title">My Loans</div>
                    <button class="settings-gear" @click="openSettings">
                        <BngIcon class="settings-icon" :type="icons.cogs" />
                    </button>
                </div>

                <!-- Single loan: show directly -->
                <div v-if="allLoans.length === 1" class="section-card">
                    <button class="loan-card" :class="{ 'mortgage-loan': allLoans[0].isMortgage }" @click="!allLoans[0].isMortgage && openLoan(allLoans[0].id)">
                        <div class="header">
                            <div class="name">{{ allLoans[0].orgName || allLoans[0].orgId }}</div>
                            <div class="rate">{{ fmtRate(allLoans[0]) }}</div>
                        </div>
                        <div class="amount">
                            <span class="currency-symbol">$</span>
                            <BngUnit :money="allLoans[0].principalOutstanding" no-icon />
                        </div>
                        <div class="chips">
                            <span class="chip" v-if="allLoans[0].isMortgage">Mortgage</span>
                            <span class="chip">{{ allLoans[0].paymentsRemaining }} left</span>
                            <span class="chip" v-if="!allLoans[0].isMortgage">Next {{ formatDue(allLoans[0].secondsUntilNextPayment) }}</span>
                        </div>
                    </button>
                </div>

                <!-- Multiple loans: summary with dropdown -->
                <div v-else class="section-card">
                    <div class="summary-row">
                        <div class="summary-label">Total Outstanding</div>
                        <div class="summary-amount">
                            <span class="currency-symbol">$</span>
                            <BngUnit :money="totalOutstanding" no-icon />
                        </div>
                        <div class="summary-meta">
                            {{ allLoans.length }} loans
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
                            <button class="loan-card" :class="{ 'mortgage-loan': l.isMortgage }" v-for="l in allLoans" :key="l.id" @click="!l.isMortgage && openLoan(l.id)">
                                <div class="header">
                                    <div class="name">{{ l.orgName || l.orgId }}</div>
                                    <div class="rate">{{ fmtRate(l) }}</div>
                                </div>
                                <div class="amount">
                                    <span class="currency-symbol">$</span>
                                    <BngUnit :money="l.principalOutstanding" no-icon />
                                </div>
                                <div class="chips">
                                    <span class="chip" v-if="l.isMortgage">Mortgage</span>
                                    <span class="chip">{{ l.paymentsRemaining }} left</span>
                                    <span class="chip" v-if="!l.isMortgage">Next {{ formatDue(l.secondsUntilNextPayment) }}</span>
                                </div>
                            </button>
                        </div>
                    </transition>
                </div>
            </div>

            <div class="section" v-else>
                <div class="section-header">
                    <div class="section-title">My Loans</div>
                    <button class="settings-gear" @click="openSettings">
                        <BngIcon class="settings-icon" :type="icons.cogs" />
                    </button>
                </div>
                <div class="section-card">
                    <div class="none">No active loans</div>
                </div>
            </div>

            <!-- Credit Score -->
            <button class="credit-widget" @click="openCredit">
                <div class="credit-left">
                    <div class="credit-label">Credit Score</div>
                    <div class="credit-score" :style="{ color: scoreColor }">{{ creditData.score || '--' }}</div>
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
                                    <span class="currency-symbol symbol-text">$</span>
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
let creditUpdatedHandler
let loansUpdatedHandler
let loansTickHandler
let loansFundsHandler
let loansCompletedHandler
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
const activeMortgages = ref([])
const prepayAmounts = ref({})
const pauseTicks = ref(false)
const availableFunds = ref(0)

const allLoans = computed(() => {
    const mortgageLoans = activeMortgages.value.map(m => ({
        id: 'mortgage-' + m.garageId,
        orgName: m.garageName || 'Property Mortgage',
        orgId: 'mortgage',
        principalOutstanding: m.remainingBalance || 0,
        currentRate: m.interestRate || 0,
        rate: m.interestRate || 0,
        paymentsRemaining: m.remainingPayments || 0,
        secondsUntilNextPayment: null,
        isMortgage: true,
        garageId: m.garageId,
        monthlyPayment: m.monthlyPayment || 0,
        missedPayments: m.missedPayments || 0,
    }))
    return [...activeLoans.value, ...mortgageLoans]
})

const totalOutstanding = computed(() => allLoans.value.reduce((sum, l) => sum + (l.principalOutstanding || 0), 0))
const avgRate = computed(() => {
    if (allLoans.value.length === 0) return '0%'
    const avg = allLoans.value.reduce((sum, l) => sum + ((l.currentRate ?? l.rate) || 0), 0) / allLoans.value.length
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

const refreshMortgages = async () => {
    try {
        const data = await lua.career_modules_propertyMortgage.getAllMortgages()
        if (data && typeof data === 'object' && !Array.isArray(data)) {
            activeMortgages.value = Object.entries(data).map(([gId, m]) => ({
                garageId: gId,
                garageName: m.garageName || gId,
                monthlyPayment: m.monthlyPayment || 0,
                remainingBalance: m.remainingBalance || 0,
                remainingPayments: m.remainingPayments || 0,
                interestRate: m.interestRate || 0,
                missedPayments: m.missedPayments || 0,
            }))
        } else {
            activeMortgages.value = []
        }
    } catch { activeMortgages.value = [] }
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
    await refreshOffers()
    await refreshActiveLoans()
    await refreshMortgages()
    loansUpdatedHandler = async () => { await refreshActiveLoans(); await refreshOffers() }
    loansTickHandler = (data) => { if (!pauseTicks.value && Array.isArray(data)) activeLoans.value = data }
    loansFundsHandler = (money) => { if (typeof money === 'number') availableFunds.value = money }
    loansCompletedHandler = async () => { await refreshActiveLoans(); await refreshOffers() }
    events.on('loans:activeUpdated', loansUpdatedHandler)
    events.on('loans:tick', loansTickHandler)
    events.on('loans:funds', loansFundsHandler)
    events.on('loans:completed', loansCompletedHandler)
    creditUpdatedHandler = () => { void refreshCredit() }
    events.on('credit:updated', creditUpdatedHandler)
    try { availableFunds.value = await lua.career_modules_loans.getAvailableFunds() } catch { }
})

onBeforeUnmount(() => {
    if (loansUpdatedHandler) events.off('loans:activeUpdated', loansUpdatedHandler)
    if (loansTickHandler) events.off('loans:tick', loansTickHandler)
    if (loansFundsHandler) events.off('loans:funds', loansFundsHandler)
    if (loansCompletedHandler) events.off('loans:completed', loansCompletedHandler)
    if (creditUpdatedHandler) events.off('credit:updated', creditUpdatedHandler)
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
    background:
        radial-gradient(110% 80% at 50% -10%, rgba(99, 102, 241, 0.35) 0%, rgba(99, 102, 241, 0) 70%),
        linear-gradient(180deg, #030712 0%, #0b1227 56%, #0f172a 100%);
}

.phone-loans {
    padding: 12px;
    padding-top: 58px;
    color: #e2e8f0;
    height: 95%;
    overflow-y: auto;
    overflow-x: hidden;
    box-sizing: border-box;
    background: transparent;
    position: relative;

    &::-webkit-scrollbar { width: 7px; }
    &::-webkit-scrollbar-track { background: rgba(148, 163, 184, 0.12); border-radius: 999px; }
    &::-webkit-scrollbar-thumb {
        background: rgba(148, 163, 184, 0.4);
        border-radius: 999px;
        &:hover { background: rgba(148, 163, 184, 0.55); }
    }
}

.settings-gear {
    width: 28px;
    height: 28px;
    display: grid;
    place-items: center;
    background: rgba(15, 23, 42, 0.62);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 12px;
    cursor: pointer;
    z-index: 5;
    padding: 0;
    backdrop-filter: blur(10px);
    box-shadow: 0 8px 22px rgba(2, 6, 23, 0.3);
    transition: transform 0.12s ease, box-shadow 0.2s ease, border-color 0.2s ease;

    &:hover {
        transform: translateY(-1px);
        border-color: rgba(125, 211, 252, 0.48);
        box-shadow: 0 10px 24px rgba(2, 6, 23, 0.42);
    }
    &:active { transform: scale(0.95); }
}

.settings-icon {
    color: #dbeafe;
    font-size: 18px;
    width: 18px;
    height: 18px;
}

.section { margin-bottom: 12px; }

.section-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin: 2px 3px 8px;
}

.section-title {
    font-size: 0.75rem;
    letter-spacing: 0.11em;
    text-transform: uppercase;
    font-weight: 700;
    margin: 2px 3px 8px;
    color: #93c5fd;
    opacity: 0.95;
}

.section-header .section-title { margin: 0; }

.section-card {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.8) 100%);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 14px;
    padding: 10px;
    backdrop-filter: blur(12px);
    box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);
}

.summary-row { padding: 4px 2px 8px; }
.summary-label {
    font-size: 0.72rem;
    color: #93c5fd;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
}

.summary-amount {
    display: flex;
    align-items: baseline;
    font-size: 1.85rem;
    font-weight: 800;
    gap: 4px;
    margin: 2px 0;
    color: #f8fafc;
}

.summary-meta {
    font-size: 0.76rem;
    color: #cbd5e1;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 6px;
}

.summary-dot {
    width: 3px;
    height: 3px;
    border-radius: 50%;
    background: #7dd3fc;
}

.expand-toggle {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    padding: 8px 4px;
    border: 0;
    border-top: 1px solid rgba(148, 163, 184, 0.24);
    background: none;
    color: #cbd5e1;
    font-size: 0.78rem;
    font-weight: 600;
    cursor: pointer;

    &:hover { color: #e2e8f0; }
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

.loan-cards {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding-top: 8px;
}

.loan-card {
    background: linear-gradient(180deg, rgba(15, 23, 42, 0.72) 0%, rgba(15, 23, 42, 0.92) 100%);
    border: 1px solid rgba(125, 211, 252, 0.22);
    border-radius: 12px;
    padding: 11px;
    text-align: left;
    width: 100%;
    min-height: 88px;
    color: inherit;
    font-family: inherit;
    transition: transform .08s ease, box-shadow .2s ease;
    cursor: pointer;
}

.loan-card:hover {
    transform: translateY(-1px);
    box-shadow: 0 8px 18px rgba(2, 6, 23, 0.35);
}

.loan-card .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.loan-card .name { font-weight: 700; color: #f8fafc; }
.loan-card .rate { color: #93c5fd; font-weight: 700; }

.loan-card .amount {
    margin: 4px 0 7px;
    display: flex;
    align-items: baseline;
    font-size: 1.85rem;
    font-weight: 800;
    gap: 4px;
    color: #f8fafc;
}

.currency-symbol {
    color: #fde68a;
    font-weight: 800;
    line-height: 1;
    font-size: 1.18rem;
    display: inline-block;
    font-style: normal;
    font-stretch: normal;
    letter-spacing: normal;
    transform: translateY(-0.03em);
}

.chips { display: flex; gap: 6px; flex-wrap: wrap; }

.chip {
    background: rgba(59, 130, 246, 0.15);
    color: #dbeafe;
    padding: 3px 10px;
    border-radius: 999px;
    border: 1px solid rgba(125, 211, 252, 0.3);
    font-size: 0.72rem;
    font-weight: 600;
}

.credit-widget {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.84) 100%);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 14px;
    padding: 14px 16px;
    width: 100%;
    margin-bottom: 12px;
    cursor: pointer;
    transition: transform 0.08s ease, box-shadow 0.2s ease;
    box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);
    backdrop-filter: blur(12px);

    &:hover {
        transform: translateY(-1px);
        box-shadow: 0 12px 28px rgba(2, 6, 23, .45);
    }

    border: 0;
    color: inherit;
    text-align: left;
    overflow: hidden;
    position: relative;
}

.credit-label {
    font-size: 0.72rem;
    color: #93c5fd;
    font-weight: 700;
    margin-bottom: 2px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
}
.credit-score { font-size: 1.9rem; font-weight: 800; }
.credit-right { display: flex; align-items: center; gap: 8px; }
.credit-tier { font-size: 0.88rem; font-weight: 700; color: #dbeafe; }
.credit-arrow { color: #7dd3fc; font-size: 1.4rem; font-weight: 600; line-height: 1; }

.offers { display: flex; flex-direction: column; gap: 6px; }

.offer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: linear-gradient(180deg, rgba(15, 23, 42, 0.72) 0%, rgba(15, 23, 42, 0.92) 100%);
    border: 1px solid rgba(125, 211, 252, 0.22);
    padding: 10px;
    border-radius: 12px;
    width: 100%;
    color: inherit;
    text-align: left;
    transition: transform .12s ease, box-shadow .2s ease;
}

.offer:hover { transform: translateY(-1px); box-shadow: 0 8px 20px rgba(2, 6, 23, 0.38); }
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
    box-shadow: inset 0 -2px 0 rgba(0, 0, 0, .2), 0 4px 10px rgba(2, 6, 23, 0.35);
}

.symbol-text {
    color: #ffffff;
    font-size: 1.15rem;
    font-weight: 800;
}

.offer-right { display: grid; gap: 2px; justify-items: end; }
.percent { font-weight: 800; }
.max { color: #cbd5e1; font-size: 0.83rem; }
.none { color: #cbd5e1; font-size: 0.85rem; }

.mortgage-loan {
    border-color: rgba(249, 115, 22, 0.35);
    cursor: default;
}
</style>
