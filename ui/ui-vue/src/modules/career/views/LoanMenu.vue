<template>
    <ComputerWrapper :path="[computerStore.computerData.facilityName]" title="Loans" back @back="close">
        <div class="loan-menu">
            <div class="left-col">
                <div class="offers" v-if="offers.length">
                    <div class="field">
                        <label>Organization</label>
                        <div class="offer-cards">
                            <div class="offer-card" v-for="o in offers" :key="o.id"
                                :class="{ active: selectedOrgId === o.id }" @click="selectOffer(o.id)">
                                <div class="name">{{ o.name }}</div>
                                <div class="meta">
                                    <span>Rate {{ (o.rate * 100).toFixed(0) }}%</span>
                                    <span class="max">Max
                                        <BngUnit :money="o.max" no-icon />
                                    </span>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <BngCard class="calc-card">
                    <BngCardHeading type="ribbon">New Loan</BngCardHeading>
                    <div class="card-content">
                        <div class="field" v-if="selectedOffer">
                            <label>Amount</label>
                            <div class="amount-row">
                                <input class="amount-slider" type="range" min="0" :max="selectedOffer.max" step="500"
                                    v-model.number="amount" @input="onAmountSlide" />
                            </div>
                            <div class="amount-edit">
                                <BngIcon :type="icons.beamCurrency" />
                                <input class="amount-number" type="number" :min="0" :step="500" inputmode="numeric"
                                    v-bng-text-input v-model.number="amount" @keydown.stop @keypress.stop @keyup.stop
                                    @focus="pauseTicks = true" @blur="onAmountBlur" @input="onAmountInput" />
                            </div>
                            <div class="hint">Max:
                                <BngUnit :money="selectedOffer.max" />
                            </div>
                        </div>

                        <div class="field" v-if="selectedOffer">
                            <label>Term</label>
                            <div class="terms no-wrap">
                                <BngButton v-for="t in selectedOffer.terms" :key="t" :class="{ active: term === t }"
                                    :accent="term === t ? ACCENTS.primary : ACCENTS.custom"
                                    :style="term === t ? null : termBtnCustomStyle" @click="setTerm(t)">
                                    {{ formatTermDuration(t) }}
                                </BngButton>
                            </div>
                        </div>

                        <div class="summary" v-if="selectedOffer">
                            <div>
                                <span>Rate</span>
                                <strong>{{ adjustedRateDisplay }}</strong>
                            </div>
                            <div>
                                <span>Per payment</span>
                                <strong>
                                    <BngUnit :money="perPayment" />
                                </strong>
                            </div>
                            <div>
                                <span>Total repay</span>
                                <strong>
                                    <BngUnit :money="totalRepay" />
                                </strong>
                            </div>
                        </div>

                        <div class="actions" v-if="selectedOffer">
                            <BngButton class="take-loan" :disabled="!canTakeLoan" @click="takeLoan">Take Loan
                            </BngButton>
                        </div>

                        <!-- Notification Settings -->
                        <div class="field">
                            <div class="notification-toggle">
                                <label class="toggle-label">
                                    <input type="checkbox" v-model="notificationsEnabled" @change="toggleNotifications" />
                                    <span class="toggle-slider"></span>
                                    <span class="toggle-text">Enable Loan Notifications</span>
                                </label>
                            </div>
                        </div>
                    </div>
                </BngCard>
            </div>

            <div class="right-col">
                <BngCard class="active-card">
                    <BngCardHeading type="ribbon">Active Loans</BngCardHeading>
                    <div class="card-content">
                        <div v-if="activeLoans.length === 0" class="none">No active loans</div>
                        <div v-else class="loan-list">
                            <div class="loan-item" v-for="l in activeLoans" :key="l.id">
                                <div class="row header">
                                    <div class="org org-title">{{ l.orgName || l.orgId }}</div>
                                    <div class="chip">{{ l.paymentsRemaining }} payments left</div>
                                </div>
                                <div class="two-col-grid">
                                    <div class="kv"><span>Per payment</span><strong>
                                            <BngUnit :money="l.perPayment" />
                                        </strong></div>
                                    <div class="kv"><span>Next payment</span><strong>
                                            <BngUnit
                                                :money="(l.nextPaymentDue === 0 || l.nextPaymentDue) ? l.nextPaymentDue : l.perPayment" />
                                        </strong></div>

                                    <div class="kv"><span>Principal</span><strong>
                                            <BngUnit :money="l.principal" />
                                        </strong></div>
                                    <div class="kv"><span>Outstanding</span><strong>
                                            <BngUnit :money="l.principalOutstanding" />
                                        </strong></div>

                                    <div class="kv"><span>Interest left</span><strong>
                                            <BngUnit :money="l.interestRemaining" />
                                        </strong></div>
                                    <div class="kv"><span>Next due</span><strong>{{ formatDue(l.secondsUntilNextPayment)
                                            }}</strong></div>

                                    <div class="kv"><span>Rate</span><strong>{{ (((l.currentRate ?? l.rate) || 0) *
                                            100).toFixed(1).replace(/\.0$/, '') }}%</strong></div>
                                    <div></div>
                                </div>
                                <div class="row prepay-row">
                                    <div class="amount-edit inline">
                                        <BngIcon :type="icons.beamCurrency" />
                                        <input class="amount-number" type="number" :min="0"
                                            :max="Math.min(availableFunds, (l.principalOutstanding || 0) + ((l.nextPaymentInterest === 0 || l.nextPaymentInterest) ? l.nextPaymentInterest : Math.max(0, (l.perPayment - (l.basePayment || 0)))))"
                                            step="100" inputmode="numeric" v-bng-text-input
                                            v-model.number="prepayAmounts[l.id]" @keydown.stop @keypress.stop
                                            @keyup.stop @focus="pauseTicks = true" @blur="onAmountBlur" />
                                        <BngButton class="max-btn" :accent="ACCENTS.custom" @click="setPayMax(l)">Max
                                        </BngButton>
                                    </div>
                                    <BngButton class="prepay-btn" :disabled="!(prepayAmounts[l.id] > 0)"
                                        @click="prepay(l.id)">Prepay</BngButton>
                                </div>
                            </div>
                        </div>
                    </div>
                </BngCard>
            </div>
        </div>
    </ComputerWrapper>

</template>

<script setup>
import { ref, computed, onMounted } from 'vue'
import { BngButton, BngCard, BngCardHeading, BngUnit, BngIcon, icons, ACCENTS } from "@/common/components/base"
import { vBngTextInput } from "@/common/directives"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useComputerStore } from "../stores/computerStore"
import { lua, useBridge } from "@/bridge"

const computerStore = useComputerStore()
const { events } = useBridge()

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

const formatCurrency = (v) => `${Math.round(v).toLocaleString()} ` + ''

const formatDue = (secondsUntilNextPayment) => {
    if (secondsUntilNextPayment == null) return 'soon'
    const d = Math.max(0, Math.floor(secondsUntilNextPayment))
    const m = Math.floor(d / 60)
    const s = d % 60
    if (m > 0) return `${m}m ${s}s`
    return `${s}s`
}

const computePayment = async () => {
    if (!selectedOffer.value || !term.value || amount.value <= 0) { perPayment.value = 0; totalRepay.value = 0; return }
    try {
        const result = await lua.career_modules_loans.calculatePayment(amount.value, adjustedRate.value, term.value)
        // calculatePayment returns nothing typed; assume [perPayment, total]? Lua bridge will return array-like or object; handle common cases
        if (Array.isArray(result)) {
            perPayment.value = result[0] || 0
            totalRepay.value = result[1] || 0
        } else if (result && typeof result === 'object') {
            perPayment.value = result.perPayment || 0
            totalRepay.value = result.total || result.totalRepay || 0
        } else {
            // fallback compute in JS
            const total = amount.value * (1 + adjustedRate.value)
            perPayment.value = total / term.value
            totalRepay.value = total
        }
    } catch (e) {
        const total = amount.value * (1 + adjustedRate.value)
        perPayment.value = total / term.value
        totalRepay.value = total
    }
}

const onOrgChange = () => {
    amount.value = 0
    term.value = selectedOffer.value?.terms?.[0] || null
    computePayment()
}

const setTerm = (t) => { term.value = t; computePayment() }

const formatTermDuration = (numPayments) => {
    const totalMinutes = numPayments * 5
    const hours = Math.floor(totalMinutes / 60)
    const minutes = totalMinutes % 60
    const hm = `${hours > 0 ? hours + 'h ' : ''}${minutes > 0 ? minutes + 'm' : ''}`
    return `${hm}`
}

const onAmountSlide = () => computePayment()
const onAmountInput = () => {
    if (!selectedOffer.value) return
    if (amount.value < 0) amount.value = 0
    if (amount.value > selectedOffer.value.max) amount.value = selectedOffer.value.max
    // Snap to 500 steps
    amount.value = Math.round(amount.value / 500) * 500
    computePayment()
}
const onAmountBlur = () => { pauseTicks.value = false; computePayment() }

const selectOffer = (id) => { selectedOrgId.value = id; onOrgChange() }

const takeLoan = async () => {
    if (!canTakeLoan.value) return
    try {
        await lua.career_modules_loans.takeLoan(selectedOrgId.value, Math.floor(amount.value), term.value, adjustedRate.value)
        await refreshActiveLoans()
        await refreshOffers()
    } catch (e) {
        // noop
    }
}

const refreshActiveLoans = async () => {
    try {
        const loans = await lua.career_modules_loans.getActiveLoans()
        activeLoans.value = Array.isArray(loans) ? loans : []
        // reset prepay inputs for any new/removed loans
        const map = {}
        for (const l of activeLoans.value) map[l.id] = prepayAmounts.value[l.id] || 0
        prepayAmounts.value = map
    } catch (e) {
        activeLoans.value = []
    }
}

const refreshOffers = async () => {
    try {
        const res = await lua.career_modules_loans.getLoanOffers()
        const prev = selectedOrgId.value
        offers.value = Array.isArray(res) ? res : []
        if (!offers.value.find(o => o.id === prev)) {
            selectedOrgId.value = offers.value[0]?.id || null
        }
        onOrgChange()
    } catch (e) { }
}

onMounted(async () => {
    await refreshOffers()
    await computePayment()
    await refreshActiveLoans()
    await loadNotificationSetting()
    // subscribe to live loan events
    events.on('loans:activeUpdated', async () => { await refreshActiveLoans(); await refreshOffers() })
    events.on('loans:tick', (data) => {
        if (pauseTicks.value) return
        if (!Array.isArray(data)) return
        activeLoans.value = data
    })
    events.on('loans:funds', (money) => { if (typeof money === 'number') availableFunds.value = money })
    events.on('loans:completed', async () => { await refreshActiveLoans(); await refreshOffers() })
    events.on('loans:notificationsUpdated', (enabled) => { notificationsEnabled.value = enabled })
    // fetch funds initially
    try { availableFunds.value = await lua.career_modules_loans.getAvailableFunds() } catch { }
})

const close = () => { lua.career_modules_loans.closeMenu() }

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
    } catch (e) {
        // noop
    }
}

const onPrepayInput = (e) => {
    const el = e?.target
    if (!el) return
    let val = parseInt(el.value || 0, 10)
    if (isNaN(val)) val = 0
    el.value = String(val)
}

const setPayMax = (loan) => {
    const nextInterest = Math.max(0, (loan.nextPaymentInterest ?? Math.max(0, (loan.perPayment - (loan.basePayment || 0)))))
    const rawMax = (loan.principalOutstanding || 0) + nextInterest
    const roundedUp = Math.ceil(rawMax + 1e-6)
    const amount = Math.min(availableFunds.value, roundedUp)
    prepayAmounts.value[loan.id] = amount
}

const toggleNotifications = async () => {
    try {
        await lua.career_modules_loans.setNotificationsEnabled(notificationsEnabled.value)
    } catch (e) {
        console.error('Failed to toggle notifications:', e)
    }
}

const loadNotificationSetting = async () => {
    try {
        const enabled = await lua.career_modules_loans.getNotificationsEnabled()
        notificationsEnabled.value = enabled
    } catch (e) {
        console.error('Failed to load notification setting:', e)
        notificationsEnabled.value = true // Default to enabled
    }
}

// gray for unselected custom-accent buttons
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
</script>

<style scoped lang="scss">
.loan-menu {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 24px;
    padding: 30px 40px;
    color: white;
    background-color: rgba(0, 0, 0, 0.8);
    border-radius: 8px;
    min-width: 820px;
}

.left-col {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.right-col {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.calc-card .card-content,
.active-card .card-content {
    padding: 12px;
}

.offers .field {
    margin-bottom: 16px;
}

.offers label {
    display: block;
    margin-bottom: 8px;
    font-weight: 600;
}

.offer-cards {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 12px;
}

.offer-card {
    background: rgba(255, 255, 255, 0.06);
    border-radius: 6px;
    padding: 10px;
    cursor: pointer;
    border: 2px solid transparent;
}

.offer-card .name {
    font-weight: 600;
    margin-bottom: 6px;
}

.offer-card .meta {
    display: flex;
    justify-content: space-between;
    font-size: 0.9em;
    opacity: 0.9;
    gap: 8px;
}

.offer-card.active {
    border-color: #fff;
}

.amount-row {
    display: grid;
    grid-template-columns: 1fr;
    align-items: center;
    gap: 10px;
}

.amount-slider {
    width: 100%;
}

.amount-number {
    width: 140px;
}

.amount-edit {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 6px;
}

.amount-number::-webkit-outer-spin-button,
.amount-number::-webkit-inner-spin-button {
    -webkit-appearance: none;
    margin: 0;
}

.amount-number[type=number] {
    -moz-appearance: textfield;
    appearance: textfield;
}

.amount {
    min-width: 120px;
    text-align: right;
}

.hint {
    opacity: 0.8;
    font-size: 0.9em;
    margin-top: 2px;
}

.terms {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 5px;
}

/* button visuals handled via ACCENTS + CSS vars set in script */

.terms .active {
    outline: 2px solid #fff;
    filter: brightness(1.1);
    background-color: #cc4c00 !important;
}

.summary {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
    margin-top: 6px;
    padding: 10px;
    background: rgba(255, 255, 255, 0.1);
    border-radius: 4px;
}

.summary>div {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.actions {
    display: flex;
    justify-content: flex-end;
    margin-top: 10px;
}

.take-loan {
    background-color: #cc4c00;
    padding: 8px 20px;
}

.active-loans h3 {
    margin-top: 0;
}

.none {
    opacity: 0.8;
}

.loan-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.loan-item {
    background: rgba(255, 255, 255, 0.06);
    padding: 12px;
    border-radius: 6px;
}

.loan-item .row {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.loan-item .header {
    margin-bottom: 8px;
}

.two-col-grid {
    display: grid;
    grid-template-columns: 1fr 1.1fr;
    /* bigger gap by unequal columns */
    column-gap: 40px;
    /* larger space between columns */
    row-gap: 4px;
    /* tighter rows */
    align-items: center;
    /* align labels and values across */
    margin-bottom: 8px;
}

.kv {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 8px;
    align-items: baseline;
}

.kv strong {
    justify-self: end;
}

.kv span {
    opacity: 0.9;
}

.loan-item .org {
    font-weight: 600;
}

.org-title { font-size: 1.2rem; line-height: 1.2; }

.loan-item .chip {
    background: rgba(0, 0, 0, 0.4);
    padding: 4px 8px;
    border-radius: 999px;
}

.loan-item .stats {
    opacity: 0.95;
    font-size: 0.95em;
}

.loan-details {
    gap: 12px;
    flex-wrap: wrap;
}

.prepay-row {
    margin-top: 8px;
    gap: 8px;
    justify-content: space-between;
}

.prepay-btn {
    background-color: #cc4c00;
}

.amount-edit.inline {
    display: inline-flex;
    align-items: center;
    gap: 8px;
}

.max-btn {
    background: rgba(255, 255, 255, 0.12);
}

/* Notification Toggle Styles */
.notification-toggle {
    margin-top: 16px;
    padding: 12px;
    background: rgba(255, 255, 255, 0.05);
    border-radius: 6px;
}

.toggle-label {
    display: flex;
    align-items: center;
    gap: 12px;
    cursor: pointer;
    font-size: 0.95em;
}

.toggle-label input[type="checkbox"] {
    display: none;
}

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

.toggle-label input[type="checkbox"]:checked + .toggle-slider {
    background: #cc4c00;
}

.toggle-label input[type="checkbox"]:checked + .toggle-slider::before {
    transform: translateX(20px);
}

.toggle-text {
    color: white;
    opacity: 0.9;
}
</style>
