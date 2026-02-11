<template>
  <PhoneWrapper app-name="New Loan">
    <div class="phone-offer-details" v-if="offer">
      <div class="credit-summary" v-if="creditData.score">
        <span class="credit-label">Credit</span>
        <span class="credit-value" :style="{ color: scoreColor }">{{ creditData.score }}</span>
        <span class="credit-tier" :style="{ color: scoreColor }">({{ creditData.tier?.label || '—' }})</span>
      </div>

      <div class="title">{{ offer.name }}</div>
      <div class="subtitle">New Loan</div>

      <div class="max-amount">
        Max: <BngUnit :money="offer.max" no-icon />
      </div>

      <div class="amount-box">
        <BngIcon class="currency" :type="icons.beamCurrency" />
        <input class="amount-input" type="number" :min="0" :max="offer.max" :step="500" inputmode="numeric"
          v-bng-text-input v-model.number="amount" @keydown.stop @keypress.stop @keyup.stop @blur="onAmountBlur" />
      </div>
      <input class="amount-slider" type="range" min="0" :max="Math.max(0, offer.max)" step="500" v-model.number="amount"
        @input="onAmountSlide" />

      <div class="term-label">Term</div>
      <div class="terms">
        <button v-for="t in offer.terms" :key="t" class="term-choice" :class="{ active: term === t }"
          @click="setTerm(t)">{{ formatTermDuration(t) }}</button>
      </div>

      <div class="summary">
        <div class="row"><span>Rate</span><strong>{{ rateDisplay }}</strong></div>
        <div class="row"><span>Per payment</span><strong class="pill">
            <BngUnit :money="perPayment" />
          </strong></div>
        <div class="row"><span>Total repay</span><strong>
            <BngUnit :money="totalRepay" />
          </strong></div>
        <div class="row"><span>Fees</span><strong>
            <BngUnit :money="0" />
          </strong></div>
      </div>

      <div v-if="loanError" class="loan-error">{{ loanError }}</div>
      <button class="take-loan" :disabled="!canTakeLoan || taking" @click="takeLoan">{{ taking ? 'Taking…' : 'Take Loan' }}</button>

      <div v-if="offer.max <= 0" class="no-loans-msg">No loans available. Improve your credit or pay off existing loans.</div>
    </div>
    <div v-else class="none">Loading…</div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngUnit, BngIcon, icons } from '@/common/components/base'
import { vBngTextInput } from '@/common/directives'
import { lua } from '@/bridge'
import { useRoute, useRouter } from 'vue-router'

const route = useRoute()
const router = useRouter()

const orgId = ref(route.params.orgId)
const offer = ref(null)
const amount = ref(0)
const term = ref(null)
const perPayment = ref(0)
const totalRepay = ref(0)
const loanError = ref('')
const taking = ref(false)
const creditData = ref({ score: 0, tier: {} })

const scoreColor = computed(() => {
  const s = creditData.value.score || 300
  if (s >= 750) return '#22c55e'
  if (s >= 550) return '#eab308'
  if (s >= 450) return '#f97316'
  return '#ef4444'
})

const canTakeLoan = computed(() => {
  if (!offer.value || !term.value || amount.value <= 0 || offer.value.max <= 0) return false
  return amount.value <= offer.value.max
})

const rate = computed(() => {
  if (!offer.value || !term.value) return offer.value?.rate || 0
  const base = offer.value.rate || offer.value.adjustedRate || 0
  const step = (term.value / 12) - 1
  const mul = step > 0 ? (1 + 0.1 * step) : 1
  return base * mul
})
const rateDisplay = computed(() => ((rate.value * 100).toFixed(1).replace(/\.0$/, '')) + '%')

const formatTermDuration = (numPayments) => {
  const totalMinutes = numPayments * 5
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  return `${hours > 0 ? hours + 'h ' : ''}${minutes > 0 ? minutes + 'm' : ''}`
}

const setTerm = (t) => { term.value = t; compute() }

const compute = async () => {
  if (!offer.value || !term.value || amount.value <= 0) { perPayment.value = 0; totalRepay.value = 0; return }
  const clamped = Math.min(Math.max(0, amount.value), offer.value.max)
  amount.value = Math.round(clamped / 500) * 500
  try {
    const result = await lua.career_modules_loans.calculatePayment(amount.value, rate.value, term.value)
    if (Array.isArray(result)) { perPayment.value = result[0] || 0; totalRepay.value = result[1] || 0 }
    else if (result && typeof result === 'object') { perPayment.value = result.perPayment || 0; totalRepay.value = result.total || result.totalRepay || 0 }
    else { const total = amount.value * (1 + rate.value); perPayment.value = total / term.value; totalRepay.value = total }
  } catch { const total = amount.value * (1 + rate.value); perPayment.value = total / term.value; totalRepay.value = total }
}

const loadOffer = async () => {
  loanError.value = ''
  try {
    const [loansResult, creditResult] = await Promise.allSettled([
      lua.career_modules_loans.getLoanOffers(),
      lua.career_modules_credit && lua.career_modules_credit.getScore ? lua.career_modules_credit.getScore() : Promise.resolve(null)
    ])
    const res = loansResult.status === 'fulfilled' ? loansResult.value : []
    const cred = creditResult.status === 'fulfilled' ? creditResult.value : null
    const list = Array.isArray(res) ? res : []
    offer.value = list.find(o => String(o.id) === String(orgId.value)) || null
    if (cred && cred.score) {
      creditData.value = { score: cred.score, tier: cred.tier || {} }
    } else if (offer.value?.creditScore != null) {
      creditData.value = { score: offer.value.creditScore, tier: offer.value.creditTier ? { label: offer.value.creditTier } : {} }
    }
    amount.value = 0
    term.value = offer.value?.terms?.[0] || null
    await compute()
  } catch { }
}

const onAmountSlide = () => compute()
const onAmountBlur = () => compute()

const takeLoan = async () => {
  if (!canTakeLoan.value) return
  loanError.value = ''
  taking.value = true
  try {
    const result = await lua.career_modules_loans.takeLoan(offer.value.id, Math.floor(amount.value), term.value, rate.value, false, null)
    if (result && result.error) {
      if (result.error === 'invalid_amount') {
        const maxVal = result.max ?? offer.value?.max ?? 0
        loanError.value = `Amount must be between 1 and $${maxVal.toLocaleString()}`
      }
      else if (result.error === 'term_not_available') loanError.value = 'This term is not available for your credit'
      else if (result.error === 'no_offer') loanError.value = 'Loan offer no longer available'
      else loanError.value = 'Loan failed: ' + (result.error || 'unknown')
    } else {
      router.push('/career/phone-loans')
    }
  } catch (e) {
    loanError.value = 'Failed to take loan'
  } finally {
    taking.value = false
  }
}

onMounted(loadOffer)

// no custom style needed for native buttons
</script>

<style scoped lang="scss">
:deep(.phone-content) {
  background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-offer-details {
  padding: 10px;
  padding-top: 60px;
  color: #0f172a;
  height: 95%;
  overflow-y: auto;
  box-sizing: border-box;
}

.title {
  font-weight: 800;
  font-size: 1.8rem;
  line-height: 1.2;
  margin-bottom: 4px;
}

.subtitle {
  color: #475569;
  font-weight: 700;
  margin-bottom: 10px;
}

.credit-summary {
  display: flex;
  align-items: baseline;
  gap: 6px;
  margin-bottom: 12px;
  font-size: 0.9rem;
}
.credit-label { color: #64748b; font-weight: 600; }
.credit-value { font-weight: 800; font-size: 1.1rem; }
.credit-tier { font-weight: 700; font-size: 0.85rem; }

.max-amount {
  color: #475569;
  font-size: 0.9rem;
  font-weight: 600;
  margin-bottom: 8px;
}

.amount-box {
  display: flex;
  align-items: center;
  gap: 6px;
  background: #ffffff;
  border: 1px solid #c9d8ff; /* blue border */
  border-radius: 12px;
  padding: 6px 7px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, .04);
}

.currency {
  font-size: 2rem;
  color: #0f172a;
}

.amount-input {
  width: 100%;
  font-size: 1.8rem;
  background: transparent;
  border: none;
  outline: none;
  color: #0f172a;
}

.amount-slider {
  width: 100%;
  margin: 12px 0 6px;
  height: 6px;
  background: linear-gradient(90deg, #ffb37a 0%, #cc4c00 100%);
  border-radius: 999px;
  appearance: none;
}

.amount-slider::-webkit-slider-thumb {
  appearance: none;
  height: 18px;
  width: 18px;
  border-radius: 50%;
  background: #cc4c00;
  border: 2px solid #fff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, .25);
}

.amount-slider::-moz-range-thumb {
  height: 18px;
  width: 18px;
  border-radius: 50%;
  background: #cc4c00;
  border: 2px solid #fff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, .25);
}

.term-label {
  font-weight: 700;
  margin: 6px 2px;
}

.terms {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 8px;
  margin-bottom: 6px;
}

.term-choice {
  width: 100%;
  padding: 6px 0; /* thinner */
  border-radius: 18px; /* extra round */
  font-weight: 700; /* stronger label */
  border: none;
  background: #576176; /* deeper slate */
  color: #fff;
  transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
}

.term-choice.active { background: #cc4c00; }

.term-choice:hover { transform: translateY(-1px) scale(1.03); box-shadow: 0 2px 8px rgba(16,24,40,.12); }
.term-choice:active { background: #b54500; transform: scale(0.98); }

.summary {
  font-weight: 600;
  display: grid;
  gap: 10px;
  margin: 10px 0 14px;
}

.row {
  display: grid;
  grid-template-columns: auto 1fr;
  align-items: center;
  column-gap: 8px;
}

.row strong {
  justify-self: end;
}

.pill {
  background: #cc4c00;
  color: #fff;
  padding: 4px 10px;
  border-radius: 999px;
}

.take-loan {
  background: #cc4c00; /* accent orange retained */
  color: #fff;
  padding: 8px 0; /* thinner */
  border-radius: 18px; /* very round */
  width: 100%;
  display: block;
  font-weight: 700;
  border: none;
  transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
}

.take-loan:hover { transform: translateY(-1px) scale(1.02); box-shadow: 0 4px 12px rgba(204,76,0,.3); }
.take-loan:active { background: #b54500; transform: scale(0.98); }
.take-loan:disabled { opacity: 0.6; cursor: not-allowed; transform: none; }

.loan-error {
  color: #ef4444;
  font-size: 0.9rem;
  font-weight: 600;
  margin-bottom: 10px;
  padding: 8px;
  background: #fef2f2;
  border-radius: 8px;
}

.no-loans-msg {
  color: #64748b;
  font-size: 0.9rem;
  margin-top: 12px;
  padding: 8px;
}

.none {
  color: #0f172a;
  opacity: .6;
  padding-top: 40px;
  text-align: center;
}
</style>
