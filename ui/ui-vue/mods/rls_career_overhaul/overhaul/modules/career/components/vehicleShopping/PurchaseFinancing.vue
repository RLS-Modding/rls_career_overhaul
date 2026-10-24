<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <section ref="root" class="purchase-financing" v-bng-on-ui-nav:back="onBack" v-bng-ui-nav-scroll>
    <h3>Finance this purchase</h3>
    <p>Taking a loan adds funds to your cash. Review the repayment before continuing.</p>
    <p v-if="loading">Loading lenders…</p>
    <template v-else-if="offer">
      <label>Lender<HouseMenu v-model="lender" :items="lenders" /></label>
      <HouseAmountField v-model="amount" label="Loan amount" :min="1" :max="offer.max" :step="500"
        :presets="[Math.min(shortfall, offer.max), offer.max]" allow-text />
      <label>Payments<HouseMenu v-model="term" :items="terms" /></label>
      <p>{{ term }} payments of <BngUnit :money="perPayment" />. Total repayment: <BngUnit :money="total" />.</p>
    </template>
    <p v-else-if="!loading">No lenders will offer you a loan right now. You can review your loans at the computer.</p>
    <p v-if="error" role="status">{{ error }}</p>
    <div class="actions">
      <HouseButton data-fk="cancel" bng-scoped-nav-autofocus :aria-disabled="busy" @click="cancel">Cancel</HouseButton>
      <HouseButton v-if="offer" data-fk="borrow" variant="primary" :aria-disabled="busy || !canBorrow" @click="borrow">
        {{ busy ? 'Taking loan…' : 'Take loan' }}
      </HouseButton>
    </div>
  </section>
</template>
<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { lua } from '@/bridge'
import { BngUnit } from '@/common/components/base'
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { HouseAmountField, HouseButton, HouseMenu } from '../house/index.js'
import { useActionFocus } from '../../composables/useActionFocus.js'

const props = defineProps({ shortfall: { type: Number, required: true } })
const emit = defineEmits(['return'])
const root = ref(null)
const { busy, run } = useActionFocus(root)
const offers = ref([])
const loading = ref(true)
const error = ref('')
const lender = ref('')
const amount = ref(1)
const term = ref(null)
const offer = computed(() => offers.value.find(row => row.id === lender.value))
const lenders = computed(() => offers.value.map(row => ({ value: row.id, label: row.name })))
const terms = computed(() => (offer.value?.terms || []).map(value => ({ value, label: `${value} payments` })))
const multiplier = computed(() => 1 + 0.1 * Math.max(0, (term.value || 0) / 12 - 1))
const perPayment = computed(() => term.value ? Math.round(amount.value / term.value * (1 + (offer.value?.rate || 0) * multiplier.value) * 100) / 100 : 0)
const total = computed(() => Math.round(perPayment.value * (term.value || 0) * 100) / 100)
const canBorrow = computed(() => offer.value && Number.isFinite(amount.value) && amount.value >= 1 && amount.value <= offer.value.max && offer.value.terms.includes(term.value))
watch(offer, row => {
  term.value = row?.terms?.[0] || null
  amount.value = Math.min(Math.max(1, Math.ceil(props.shortfall)), row?.max || 1)
})
onMounted(async () => {
  try {
    const rows = await lua.overhaul_career_economy_loans.getLoanOffers()
    offers.value = (Array.isArray(rows) ? rows : Object.values(rows || {})).filter(row => row.max >= 1 && row.terms?.length)
    lender.value = offers.value[0]?.id || ''
  } catch { error.value = 'Unable to load lenders. Try again later.' }
  finally { loading.value = false }
})
const cancel = () => { if (!busy.value) emit('return', false) }
const onBack = event => { event.stopPropagation(); cancel() }
const borrow = () => {
  if (!canBorrow.value) return
  return run(async () => {
    error.value = ''
    try {
      const result = await lua.overhaul_career_economy_loans.takeLoan(lender.value, Math.floor(amount.value), term.value, (offer.value.baseRate || 0) * multiplier.value, false, null)
      if (!result || result.error) {
        error.value = result?.error === 'invalid_amount' ? `Choose an amount up to ${result.max ?? offer.value.max}.` : 'This loan is no longer available. Close and try again.'
        return
      }
      emit('return', true)
    } catch { error.value = 'Unable to take this loan. Try again later.' }
  })
}
</script>
<style scoped>
.purchase-financing { width: min(32em, 85vw); max-height: 80vh; overflow: auto; padding: 1.5em; color: white; background: #1a1a1c; }
label { display: block; margin: 1em 0; }
.actions { display: flex; justify-content: flex-end; gap: .6em; margin-top: 1em; }
</style>
