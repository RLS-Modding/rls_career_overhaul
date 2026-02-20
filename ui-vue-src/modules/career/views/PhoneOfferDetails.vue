<template>
  <PhoneWrapper app-name="New Loan">
    <div class="phone-offer-details" v-if="offer">
      <div class="section">
        <div class="section-card">
      <div class="credit-summary" v-if="creditData.score">
        <span class="credit-label">Credit</span>
        <span class="credit-value" :style="{ color: scoreColor }">{{ creditData.score }}</span>
        <span class="credit-tier" :style="{ color: scoreColor }">({{ creditData.tier?.label || '-' }})</span>
      </div>

      <div class="title">{{ offer.name }}</div>
      <div class="subtitle">New Loan</div>

      <div class="max-amount">
        Max: <BngUnit :money="offer.max" no-icon />
      </div>

      <div class="amount-box">
        <span class="currency">$</span>
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
            <BngUnit :money="perPayment" no-icon />
          </strong></div>
        <div class="row"><span>Total repay</span><strong>
            <BngUnit :money="totalRepay" no-icon />
          </strong></div>
        <div class="row"><span>Fees</span><strong>
            <BngUnit :money="0" no-icon />
          </strong></div>
      </div>

      <div v-if="loanError" class="loan-error">{{ loanError }}</div>
      <button class="take-loan" :disabled="!canTakeLoan || taking" @click="takeLoan">{{ taking ? 'Taking...' : 'Take Loan' }}</button>

      <div v-if="offer.max <= 0" class="no-loans-msg">No loans available. Improve your credit or pay off existing loans.</div>
        </div>
      </div>
    </div>
    <div v-else class="none">Loading...</div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngUnit } from '@/common/components/base'
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
    background:
      radial-gradient(110% 80% at 50% -10%, rgba(99, 102, 241, 0.35) 0%, rgba(99, 102, 241, 0) 70%),
      linear-gradient(180deg, #030712 0%, #0b1227 56%, #0f172a 100%);
  }

.phone-offer-details {
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

  .title {
    font-weight: 800;
    font-size: 1.5rem;
    line-height: 1.2;
    margin-bottom: 4px;
    color: #f8fafc;
  }

  .subtitle {
    color: #93c5fd;
    font-weight: 700;
    text-transform: uppercase;
    font-size: 0.76rem;
    letter-spacing: 0.08em;
    margin-bottom: 10px;
  }

  .credit-summary {
    display: flex;
    align-items: baseline;
    gap: 6px;
    margin-bottom: 12px;
    font-size: 0.9rem;
  }

  .credit-label { color: #93c5fd; font-weight: 700; text-transform: uppercase; font-size: 0.76rem; letter-spacing: 0.08em; }
  .credit-value { font-weight: 800; font-size: 1.1rem; }
  .credit-tier { font-weight: 700; font-size: 0.85rem; }

  .max-amount {
    color: #cbd5e1;
    font-size: 0.9rem;
    font-weight: 600;
    margin-bottom: 8px;
  }

  .amount-box {
    display: flex;
    align-items: center;
    font-size: 1.8rem;
    gap: 6px;
    background: rgba(15, 23, 42, 0.72);
    border: 1px solid rgba(125, 211, 252, 0.24);
    border-radius: 12px;
    padding: 6px 7px;
    box-shadow: 0 1px 2px rgba(2, 6, 23, 0.2);
  }

  .currency {
    font-size: 1.05rem;
    color: #fde68a;
    line-height: 1;
    font-weight: 800;
    transform: translateY(-0.03em);
  }

  .amount-input {
    width: 100%;
    font-size: 1em;
    background: transparent;
    border: none;
    outline: none;
    color: #f8fafc;
  }

  .amount-slider {
    width: 100%;
    margin: 12px 0 6px;
    height: 6px;
    background: linear-gradient(90deg, #38bdf8 0%, #818cf8 100%);
    border-radius: 999px;
    appearance: none;
  }

  .amount-slider::-webkit-slider-thumb {
    appearance: none;
    height: 18px;
    width: 18px;
    border-radius: 50%;
    background: #22d3ee;
    border: 2px solid #fff;
    box-shadow: 0 1px 3px rgba(0, 0, 0, .25);
  }

  .amount-slider::-moz-range-thumb {
    height: 18px;
    width: 18px;
    border-radius: 50%;
    background: #22d3ee;
    border: 2px solid #fff;
    box-shadow: 0 1px 3px rgba(0, 0, 0, .25);
  }

  .term-label {
    font-weight: 700;
    margin: 10px 2px 8px;
    color: #cbd5e1;
  }

  .terms {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 8px;
    margin-bottom: 6px;
  }

  .term-choice {
    width: 100%;
    padding: 6px 0;
    border-radius: 18px;
    font-weight: 700;
    border: none;
    background: rgba(30, 41, 59, 0.88);
    color: #fff;
    border: 1px solid rgba(125, 211, 252, 0.2);
    transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
  }

  .term-choice.active { background: #7dd3fc; color: #0f172a; }
  .term-choice:hover { transform: translateY(-1px) scale(1.03); box-shadow: 0 2px 8px rgba(16,24,40,.12); }
  .term-choice:active { transform: scale(0.98); }

  .summary {
    font-weight: 600;
    display: grid;
    gap: 10px;
    margin: 10px 0 14px;
    color: #cbd5e1;
  }

  .row {
    display: grid;
    grid-template-columns: auto 1fr;
    align-items: center;
    column-gap: 8px;
  }

  .row strong {
    justify-self: end;
    color: #f8fafc;
  }

  .pill {
    background: #0ea5e9;
    color: #fff;
    padding: 4px 10px;
    border-radius: 999px;
  }

  .take-loan {
    background: linear-gradient(135deg, #38bdf8 0%, #0ea5e9 100%);
    color: #fff;
    padding: 8px 0;
    border-radius: 18px;
    width: 100%;
    display: block;
    font-weight: 700;
    border: none;
    border: 1px solid rgba(125, 211, 252, 0.5);
    transition: transform .12s ease, background-color .12s ease, box-shadow .2s ease;
  }

  .take-loan:hover { transform: translateY(-1px) scale(1.02); box-shadow: 0 4px 12px rgba(14, 165, 233,.35); }
  .take-loan:active { background: linear-gradient(135deg, #0ea5e9 0%, #0284c7 100%); transform: scale(0.98); }
  .take-loan:disabled { opacity: 0.6; cursor: not-allowed; transform: none; }

  .loan-error {
    color: #ef4444;
    font-size: 0.9rem;
    font-weight: 600;
    margin-bottom: 10px;
    padding: 8px;
    background: rgba(239, 68, 68, 0.18);
    border-radius: 8px;
  }

  .no-loans-msg {
    color: #cbd5e1;
    font-size: 0.9rem;
    margin-top: 12px;
    padding: 8px;
  }

  .none {
    color: #94a3b8;
    opacity: .6;
    padding-top: 40px;
    text-align: center;
  }
</style>






