<template>
  <PhoneWrapper app-name="Prepay Loan">
    <div class="phone-loan-details">
      <div v-if="!loan" class="none">Loading…</div>
      <div v-else class="content">
        <div class="top-row">
          <div class="org">{{ loan.orgName || loan.orgId }}</div>
          <div class="left-chip">{{ loan.paymentsRemaining }} left</div>
        </div>

        <div class="kv-list">
          <div class="kv"><span>Per payment</span><strong>
              <BngUnit :money="loan.perPayment" />
            </strong></div>
          <div class="kv"><span>Next payment</span><strong>
              <BngUnit
                :money="(loan.nextPaymentDue === 0 || loan.nextPaymentDue) ? loan.nextPaymentDue : loan.perPayment" />
            </strong></div>
          <div class="kv"><span>Outstanding</span><strong>
              <BngUnit :money="loan.principalOutstanding" />
            </strong></div>
          <div class="kv"><span>Next due</span><strong>{{ formatDue(loan.secondsUntilNextPayment) }}</strong></div>
          <div class="kv"><span>Rate</span><strong>{{ (((loan.currentRate ?? loan.rate) || 0) *
            100).toFixed(1).replace(/\.0$/, '') }}%</strong></div>
        </div>

        <div class="amount-field">
          <BngIcon class="currency" :type="icons.beamCurrency" />
          <input class="amount-input" type="number" :min="0" :max="maxPrepay(loan)" step="100" inputmode="numeric"
            v-bng-text-input v-model.number="prepay" @keydown.stop @keypress.stop @keyup.stop @focus="pauseTicks = true"
            @blur="onAmountBlur" />
        </div>
        <button class="pay-full-btn" @click="prepay = maxPrepay(loan)" v-if="maxPrepay(loan) > 0">Pay full amount</button>

        <div v-if="prepayError" class="prepay-error">{{ prepayError }}</div>
        <div class="actions">
          <button class="prepay-btn" :disabled="!(prepay > 0) || prepaying" @click="prepayLoan">{{ prepaying ? 'Processing…' : 'Prepay' }}</button>
          <button class="cancel-btn" @click="cancel">Cancel</button>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngUnit, BngIcon, icons } from '@/common/components/base'
import { vBngTextInput } from '@/common/directives'
import { lua, useBridge } from '@/bridge'
import { useRouter, useRoute } from 'vue-router'

const router = useRouter()
const route = useRoute()
const { events } = useBridge()

const loanId = ref(route.params.loanId)
const loan = ref(null)
const prepay = ref(0)
const pauseTicks = ref(false)
const availableFunds = ref(0)
const prepayError = ref('')
const prepaying = ref(false)

const formatDue = (secondsUntilNextPayment) => {
  if (secondsUntilNextPayment == null) return 'soon'
  const d = Math.max(0, Math.floor(secondsUntilNextPayment))
  const m = Math.floor(d / 60)
  const s = d % 60
  if (m > 0) return `${m}m ${s}s`
  return `${s}s`
}

const loadLoan = async () => {
  try {
    const loans = await lua.career_modules_loans.getActiveLoans()
    const list = Array.isArray(loans) ? loans : []
    loan.value = list.find(l => String(l.id) === String(loanId.value)) || null
  } catch { }
}

const onAmountBlur = () => { pauseTicks.value = false }

const maxPrepay = (l) => Math.min(
  availableFunds.value,
  Math.ceil(((l.principalOutstanding || 0) + Math.max(0, (l.nextPaymentInterest ?? Math.max(0, (l.perPayment - (l.basePayment || 0)))))) + 1e-6)
)

const setPayMax = (l) => { prepay.value = maxPrepay(l) }

const errorMessages = {
  invalid_amount: 'Please enter a valid amount.',
  nothing_owed: 'Nothing owed on this payment.',
  insufficient_funds: 'Insufficient funds.',
  pay_failed: 'Payment failed. Make sure you have enough money.',
  loan_not_found: 'Loan not found.'
}

const prepayLoan = async () => {
  const amt = Math.max(0, Math.floor(prepay.value || 0))
  if (!amt || !loan.value) return
  prepayError.value = ''
  prepaying.value = true
  try {
    const result = await lua.career_modules_loans.prepayLoan(loan.value.id, amt)
    const isSuccess = result && !result.error && (result.id != null || result.status === 'paid_off')
    if (!isSuccess) {
      prepayError.value = result?.error ? (errorMessages[result.error] || result.error) : 'Payment failed.'
      return
    }
    prepay.value = 0
    await loadLoan()
    router.push({ name: 'phone-loans' })
  } catch (e) {
    prepayError.value = 'Payment failed.'
  } finally {
    prepaying.value = false
  }
}

const cancel = () => { router.back() }

const onFunds = (money) => { if (typeof money === 'number') availableFunds.value = money }

onMounted(async () => {
  await loadLoan()
  try { availableFunds.value = await lua.career_modules_loans.getAvailableFunds() } catch { }
  events.on('loans:activeUpdated', loadLoan)
  events.on('loans:tick', loadLoan)
  events.on('loans:funds', onFunds)
})

onBeforeUnmount(() => {
  events.off('loans:activeUpdated', loadLoan)
  events.off('loans:tick', loadLoan)
  events.off('loans:funds', onFunds)
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
  background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-loan-details {
  padding: 5px;
  padding-top: 60px;
  color: #0f172a;
  height: 95%;
  overflow-y: auto;
  box-sizing: border-box;
}

.content {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.top-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.org {
  font-weight: 800;
  font-size: 1.3rem;
}

.left-chip {
  color: #64748b;
}

.kv-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
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

.amount-field {
  display: flex;
  align-items: center;
  gap: 8px;
  background: #ffffff;
  border: 1px solid #c9d8ff;
  border-radius: 12px;
  padding: 10px 12px;
}

.currency {
  font-size: 1.6rem;
  color: #000;
}

.amount-input {
  width: 100%;
  font-size: 1.4rem;
  font-weight: 700;
  background: transparent;
  color: #0f172a;
  border: none;
  outline: none;
}

.pay-full-btn {
  background: #eef2f7;
  color: #475569;
  border: none;
  padding: 6px 0;
  border-radius: 10px;
  font-size: 0.85rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s ease;
}
.pay-full-btn:hover { background: #e2e8f0; }

.prepay-error {
  color: #ef4444;
  font-size: 0.9rem;
  font-weight: 600;
  padding: 8px;
  background: #fef2f2;
  border-radius: 8px;
}

.actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
  margin-top: 4px;
}

.prepay-btn {
  background: #cc4c00;
  color: #ffffff;
  border: none;
  padding: 8px 0;
  border-radius: 12px;
  font-weight: 700;
  transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
}

.cancel-btn {
  background: #eef2f7;
  color: #0f172a;
  border: none;
  padding: 8px 0;
  border-radius: 12px;
  font-weight: 700;
  transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
}

.prepay-btn:hover, .cancel-btn:hover { transform: translateY(-1px) scale(1.02); box-shadow: 0 2px 8px rgba(16,24,40,.12); }
.prepay-btn:active { background: #b54500; transform: scale(0.98); }
.cancel-btn:active { background: #dbe3ee; transform: scale(0.98); }

.none {
  color: #0f172a;
  opacity: .6;
  padding-top: 40px;
  text-align: center;
}
</style>
