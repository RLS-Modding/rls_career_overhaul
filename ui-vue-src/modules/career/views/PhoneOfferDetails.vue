<template>
  <PhoneWrapper app-name="New Loan" status-font-color="#FFFFFF" status-blend-mode="">
    <div class="phone-offer-details" v-if="offer">
      <div class="title">{{ offer.name }}</div>
      <div class="subtitle">New Loan</div>

      <div class="amount-box">
        <BngIcon class="currency" :type="icons.beamCurrency" />
        <input class="amount-input" type="number" :min="0" :max="offer.max" :step="500" inputmode="numeric"
          v-bng-text-input v-model.number="amount" @keydown.stop @keypress.stop @keyup.stop @blur="compute" />
      </div>
      <input class="amount-slider" type="range" min="0" :max="offer.max" step="500" v-model.number="amount"
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

      <button class="take-loan" :disabled="!canTakeLoan" @click="takeLoan">Take Loan</button>
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

const canTakeLoan = computed(() => offer.value && amount.value > 0 && term.value)

const rate = computed(() => {
  if (!offer.value || !term.value) return offer.value?.rate || 0
  const base = offer.value.rate || 0
  const step = (term.value / 12) - 1
  const mul = step > 0 ? (1 + 0.1 * step) : 1
  return base * mul
})
const rateDisplay = computed(() => ((rate.value * 100).toFixed(1).replace(/\.0$/, '')) + '%')

const formatTermDuration = (numPayments) => {
  const totalMinutes = numPayments * 5
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  const hm = `${hours > 0 ? hours + 'h ' : ''}${minutes > 0 ? minutes + 'm' : ''}`
  return `${hm}`
}

const setTerm = (t) => { term.value = t; compute() }

const compute = async () => {
  if (!offer.value || !term.value || amount.value <= 0) { perPayment.value = 0; totalRepay.value = 0; return }
  try {
    const result = await lua.career_modules_loans.calculatePayment(amount.value, rate.value, term.value)
    if (Array.isArray(result)) { perPayment.value = result[0] || 0; totalRepay.value = result[1] || 0 }
    else if (result && typeof result === 'object') { perPayment.value = result.perPayment || 0; totalRepay.value = result.total || result.totalRepay || 0 }
    else { const total = amount.value * (1 + rate.value); perPayment.value = total / term.value; totalRepay.value = total }
  } catch { const total = amount.value * (1 + rate.value); perPayment.value = total / term.value; totalRepay.value = total }
}

const loadOffer = async () => {
  try {
    const res = await lua.career_modules_loans.getLoanOffers()
    const list = Array.isArray(res) ? res : []
    offer.value = list.find(o => String(o.id) === String(orgId.value)) || null
    amount.value = 0
    term.value = offer.value?.terms?.[0] || null
    await compute()
  } catch { }
}

const onAmountSlide = () => compute()

const takeLoan = async () => {
  if (!canTakeLoan.value) return
  try {
    await lua.career_modules_loans.takeLoan(offer.value.id, Math.floor(amount.value), term.value, rate.value)
    router.push('/career/phone-loans')
  } catch { }
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

.none {
  color: #0f172a;
  opacity: .6;
  padding-top: 40px;
  text-align: center;
}
</style>
