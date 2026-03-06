<template>
  <PhoneWrapper app-name="Prepay Loan">
    <div class="phone-loan-details">
      <div v-if="!loan" class="none">Loading...</div>
      <div v-else class="section">
      <div class="section-title">Prepay Loan</div>
      <div class="section-card content">
        <div class="top-row">
          <div class="org">{{ loan.orgName || loan.orgId }}</div>
          <div class="left-chip">{{ loan.paymentsRemaining }} left</div>
        </div>

        <div class="kv-list">
          <div class="kv"><span>Per payment</span><strong>
              <BngUnit :money="loan.perPayment" no-icon />
            </strong></div>
          <div class="kv"><span>Next payment</span><strong>
              <BngUnit
                :money="(loan.nextPaymentDue === 0 || loan.nextPaymentDue) ? loan.nextPaymentDue : loan.perPayment" no-icon />
            </strong></div>
          <div class="kv"><span>Outstanding</span><strong>
              <BngUnit :money="loan.principalOutstanding" no-icon />
            </strong></div>
          <div class="kv"><span>Next due</span><strong>{{ formatDue(loan.secondsUntilNextPayment) }}</strong></div>
          <div class="kv"><span>Rate</span><strong>{{ (((loan.currentRate ?? loan.rate) || 0) *
            100).toFixed(1).replace(/\.0$/, '') }}%</strong></div>
        </div>

        <div class="amount-field">
          <span class="currency">$</span>
          <input class="amount-input" type="number" :min="0" :max="maxPrepay(loan)" step="100" inputmode="numeric"
            v-bng-text-input v-model.number="prepay" @keydown.stop @keypress.stop @keyup.stop @focus="pauseTicks = true"
            @blur="onAmountBlur" />
        </div>
        <button class="pay-full-btn" :disabled="!loan || maxPrepay(loan) <= 0" @click="prepay = maxPrepay(loan)">
          Pay full amount
        </button>

        <div v-if="prepayError" class="prepay-error">{{ prepayError }}</div>
        <div class="actions">
          <button class="prepay-btn" :disabled="!(prepay > 0) || prepaying" @click="prepayLoan">{{ prepaying ? 'Processing...' : 'Prepay' }}</button>
          <button class="cancel-btn" @click="cancel">Cancel</button>
        </div>
      </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngUnit } from '@/common/components/base'
import { vBngTextInput } from '@/common/directives'
import { lua, useBridge } from '@/bridge'
import { useRouter, useRoute } from 'vue-router'

const router = useRouter()
const route = useRoute()
const { events } = useBridge()

const loanId = ref(route.params.loanId)
const isMortgage = String(loanId.value).startsWith('mortgage-')
const mortgageGarageId = isMortgage ? String(loanId.value).replace('mortgage-', '') : null
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
    if (isMortgage) {
      const m = await lua.career_modules_propertyMortgage.getMortgagePaymentInfo(mortgageGarageId)
      if (m) {
        loan.value = {
          id: loanId.value,
          orgName: m.garageName || 'Property Mortgage',
          orgId: 'mortgage',
          principalOutstanding: m.remainingBalance || 0,
          perPayment: m.monthlyPayment || 0,
          nextPaymentDue: m.monthlyPayment || 0,
          paymentsRemaining: m.remainingPayments || 0,
          secondsUntilNextPayment: m.secondsUntilNextPayment ?? null,
          currentRate: m.interestRate || 0,
          isMortgage: true,
          garageId: mortgageGarageId,
        }
      } else {
        loan.value = null
      }
    } else {
      const loans = await lua.career_modules_loans.getActiveLoans()
      const list = Array.isArray(loans) ? loans : []
      loan.value = list.find(l => String(l.id) === String(loanId.value)) || null
    }
  } catch { }
}

const onAmountBlur = () => { pauseTicks.value = false }

const maxPrepay = (l) => Math.min(
  availableFunds.value,
  Math.ceil((l.principalOutstanding || 0) + 1e-6)
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
    let result
    if (isMortgage) {
      result = await lua.career_modules_propertyMortgage.prepayMortgage(mortgageGarageId, amt)
    } else {
      result = await lua.career_modules_loans.prepayLoan(loan.value.id, amt)
    }
    const isSuccess = result && !result.error && (result.id != null || result.status === 'paid_off')
    if (!isSuccess) {
      prepayError.value = result?.error ? (errorMessages[result.error] || result.error) : 'Payment failed.'
      return
    }
    prepay.value = 0
    await loadLoan()
    if (result.status === 'paid_off') {
      router.push({ name: 'phone-loans' })
    }
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
  if (!isMortgage) {
    events.on('loans:activeUpdated', loadLoan)
    events.on('loans:tick', loadLoan)
  }
  events.on('loans:funds', onFunds)
})

onBeforeUnmount(() => {
  if (!isMortgage) {
    events.off('loans:activeUpdated', loadLoan)
    events.off('loans:tick', loadLoan)
  }
  events.off('loans:funds', onFunds)
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
  background:
    radial-gradient(110% 80% at 50% -10%, rgba(99, 102, 241, 0.35) 0%, rgba(99, 102, 241, 0) 70%),
    linear-gradient(180deg, #030712 0%, #0b1227 56%, #0f172a 100%);
}

.phone-loan-details {
  padding: 12px;
  padding-top: 58px;
  color: #e2e8f0;
  height: 95%;
  overflow-y: auto;
  overflow-x: hidden;
  box-sizing: border-box;

  &::-webkit-scrollbar { width: 7px; }
  &::-webkit-scrollbar-track { background: rgba(148, 163, 184, 0.12); border-radius: 999px; }
  &::-webkit-scrollbar-thumb {
    background: rgba(148, 163, 184, 0.4);
    border-radius: 999px;
    &:hover { background: rgba(148, 163, 184, 0.55); }
  }
}

.section {
  margin-bottom: 12px;
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

.section-card {
  background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.8) 100%);
  border: 1px solid rgba(148, 163, 184, 0.3);
  border-radius: 14px;
  padding: 12px;
  backdrop-filter: blur(12px);
  box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);
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
  font-size: 1.35rem;
  color: #f8fafc;
}

.left-chip {
  color: #cbd5e1;
  font-weight: 700;
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
  color: #cbd5e1;
}

.kv span { color: #94a3b8; }

.kv strong {
  justify-self: end;
  color: #f8fafc;
}

.amount-field {
  display: flex;
  align-items: center;
  font-size: 1.4rem;
  gap: 8px;
  background: rgba(15, 23, 42, 0.72);
  border: 1px solid rgba(125, 211, 252, 0.24);
  border-radius: 12px;
  padding: 10px 12px;
}

.currency {
  font-size: 0.85rem;
  color: #fde68a;
  line-height: 1;
  font-weight: 800;
  transform: translateY(-0.03em);
}

.amount-input {
  width: 100%;
  font-size: 1em;
  font-weight: 700;
  background: transparent;
  color: #f8fafc;
  border: none;
  outline: none;
}

.pay-full-btn {
  background: rgba(30, 41, 59, 0.88);
  color: #dbeafe;
  border: 1px solid rgba(125, 211, 252, 0.2);
  padding: 6px 0;
  border-radius: 10px;
  font-size: 0.85rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s ease, transform .12s ease;
}

.pay-full-btn:hover:enabled { background: rgba(30, 41, 59, 1); transform: translateY(-1px) scale(1.02); }
.pay-full-btn:disabled { opacity: 0.55; cursor: not-allowed; transform: none; }
.pay-full-btn:disabled:hover { background: rgba(30, 41, 59, 0.88); transform: none; }

.prepay-error {
  color: #ef4444;
  font-size: 0.9rem;
  font-weight: 600;
  padding: 8px;
  background: rgba(239, 68, 68, 0.18);
  border-radius: 8px;
}

.actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
  margin-top: 4px;
}

.prepay-btn {
  background: #0ea5e9;
  color: #ffffff;
  border: none;
  padding: 8px 0;
  border-radius: 12px;
  font-weight: 700;
  transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
}

.cancel-btn {
  background: rgba(30, 41, 59, 0.88);
  color: #dbeafe;
  border: 1px solid rgba(125, 211, 252, 0.2);
  padding: 8px 0;
  border-radius: 12px;
  font-weight: 700;
  transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
}

.prepay-btn:hover, .cancel-btn:hover { transform: translateY(-1px) scale(1.02); box-shadow: 0 2px 8px rgba(16,24,40,.12); }
.prepay-btn:active { background: #0284c7; transform: scale(0.98); }
.cancel-btn:active { background: rgba(51, 65, 85, 1); transform: scale(0.98); }

.none {
  color: #94a3b8;
  opacity: .6;
  padding-top: 40px;
  text-align: center;
}
</style>





