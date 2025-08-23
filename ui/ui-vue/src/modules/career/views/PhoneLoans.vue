<template>
    <PhoneWrapper app-name="Loans" status-font-color="#FFFFFF" status-blend-mode="">
        <div class="phone-loans">
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
import { ref, computed, onMounted } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngButton, BngUnit, BngIcon, icons, ACCENTS } from '@/common/components/base'
import { vBngTextInput } from '@/common/directives'
import { lua, useBridge } from '@/bridge'
import { useRouter } from 'vue-router'

const { events } = useBridge()

const router = useRouter()

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

const canTakeLoan = computed(() => selectedOffer.value && amount.value > 0 && term.value)

const formatDue = (secondsUntilNextPayment) => {
    if (secondsUntilNextPayment == null) return 'soon'
    const d = Math.max(0, Math.floor(secondsUntilNextPayment))
    const m = Math.floor(d / 60)
    const s = d % 60
    if (m > 0) return `${m}m ${s}s`
    return `${s}s`
}

// This screen only lists loans/offers. Keep compute utilities for later but don't render the form here.
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
    await refreshOffers()
    await refreshActiveLoans()
    events.on('loans:activeUpdated', async () => { await refreshActiveLoans(); await refreshOffers() })
    events.on('loans:tick', (data) => { if (!pauseTicks.value && Array.isArray(data)) activeLoans.value = data })
    events.on('loans:funds', (money) => { if (typeof money === 'number') availableFunds.value = money })
    events.on('loans:completed', async () => { await refreshActiveLoans(); await refreshOffers() })
    try { availableFunds.value = await lua.career_modules_loans.getAvailableFunds() } catch { }
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

// Navigation helpers -------------------------------------------------
const openLoan = (id) => { router.push({ name: 'phone-loan-details', params: { loanId: String(id) } }) }
const openOffer = (id) => { router.push({ name: 'phone-offer-details', params: { orgId: String(id) } }) }

// visual helpers
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
    border: 1px solid #d4e2ff; /* stronger blue border */
    border-radius: 14px;
    padding: 10px;
    box-shadow: 0 1px 2px rgba(16, 24, 40, .04), 0 4px 12px rgba(16, 24, 40, .05);
}

.loan-cards {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.loan-card {
    background: #eef4ff; /* richer light blue */
    border: 1px solid #c9d8ff; /* saturated blue border */
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

.loan-card .name {
    font-weight: 700;
}

.loan-card .rate {
    color: #475569;
    font-weight: 700;
}

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
    background: #e2ecff; /* more saturated light blue */
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
    background: #eef4ff; /* richer light blue */
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

.percent {
    font-weight: 800;
}

.max {
    color: #475569;
}

.none {
    color: #475569;
}
</style>
