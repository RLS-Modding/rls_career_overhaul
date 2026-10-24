<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <LayoutSingle class="garage-listing-layout">
    <!-- Active scope keeps Back on purchase cleanup; finance/rent handle their own Back. -->
    <div class="listing-backdrop" bng-ui-scope="garageListing" v-bng-on-ui-nav:back,menu="onNavCancel" @pointerdown.self="cancel">
      <!-- RLS house popup: photo with the name, the price as the hero (property facts beside it), the cost
           breakdown with the total right above the actions, other ways in (offer / rent / finance) as
           neutral buttons, Cancel quiet with B, and Buy as the one orange action -->
      <div class="rls-house listing-panel" @click.stop>
        <div class="panel-preview" :class="{ 'no-photo': !preview }">
          <img v-if="preview" :src="preview" alt="" class="preview-img" />
          <span class="pill photo-pill" :class="{ ok: starterGarage }">{{ starterGarage ? 'Starter' : 'For sale' }}</span>
          <div class="preview-copy">
            <h1 class="prop-name">{{ name }}</h1>
            <div class="prop-location" v-if="neighborhood">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
              {{ neighborhood }}
            </div>
          </div>
        </div>

        <div class="panel-body">
          <div class="price-strip">
            <div class="price-main">
              <span class="caption">
                {{ negotiatedPrice ? 'Negotiated price' : 'Listed price' }}
                <s v-if="negotiatedPrice" class="was"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(listedPrice) }}</s>
              </span>
              <strong class="price-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(effectivePrice) }}</strong>
            </div>
            <dl class="strip-facts">
              <div class="fact">
                <dt class="fact-key">Vehicle slots</dt>
                <dd class="fact-value">{{ capacity }}</dd>
              </div>
              <div class="fact">
                <dt class="fact-key">Parking spots</dt>
                <dd class="fact-value">{{ parkingSpots }}</dd>
              </div>
            </dl>
          </div>

          <div class="price-tools" v-if="(isFrozen && cooldownRemaining > 0) || (negotiatedPrice && !isFrozen)">
            <span class="pill frozen-badge" v-if="isFrozen && cooldownRemaining > 0">
              <BngIcon class="pill-icon" :type="icons.snowflake" />Price frozen for {{ formatCooldown(cooldownRemaining) }}
            </span>
            <HouseButton
              v-if="negotiatedPrice && !isFrozen"
              class="btn-freeze"
              compact
              :icon="icons.snowflake"
              @click="freezeNegotiatedPrice">Freeze this price</HouseButton>
          </div>

          <!-- the price itself is the hero above, so the breakdown lists only what is added to it (and is
               left out when nothing is: the total would just repeat the price) -->
          <div class="lines breakdown" v-if="closingFee > 0 || propertyTax > 0">
            <div class="line" v-if="closingFee > 0">
              <span>Closing costs <small>3%</small></span>
              <strong>+ <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(closingFee) }}</strong>
            </div>
            <div class="line" v-if="propertyTax > 0">
              <span>Property tax <small>1.2%</small></span>
              <strong>+ <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(propertyTax) }}</strong>
            </div>
            <div class="line total">
              <span>Estimated total</span>
              <strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(estimatedTotal) }}</strong>
            </div>
          </div>

          <p class="notice" v-if="starterGarage">This is a starter garage and cannot be negotiated.</p>
          <p class="notice bad" v-if="cantPay && !starterGarage">Not enough money to buy this property.</p>
          <p class="notice warn" v-if="cooldownRemaining > 0 && !negotiatedPrice">Negotiation on cooldown: {{ formatCooldown(cooldownRemaining) }}</p>
          <p class="notice" v-if="mortgageAvailable === false && mortgageCreditTier === 'Bad' && !starterGarage">Cash only. Improve your credit score to unlock financing.</p>

          <!-- disabled HouseButtons carry bng-no-nav: crossfire would otherwise dead-end the d-pad on them -->
          <div class="btn-row">
            <div class="alt-actions">
              <HouseButton
                class="btn-offer"
                :disabled="!canNegotiate || starterGarage || cooldownRemaining > 0"
                @click="startNegotiation">Make an offer</HouseButton>
              <HouseButton
                v-if="showRent"
                class="btn-rent"
                :disabled="!garageId"
                @click="openRentalModal">Rent</HouseButton>
              <HouseButton
                v-if="mortgageAvailable && !starterGarage"
                class="btn-finance"
                :disabled="!garageId"
                @click="openMortgageModal">Finance</HouseButton>
            </div>
            <div class="actions">
              <HouseButton class="btn-cancel" variant="quiet" binding="back" @click="cancel">Cancel</HouseButton>
              <span class="actions-gap"></span>
              <HouseButton
                class="btn-buy"
                variant="primary"
                :disabled="!garageId || cantPay || starterGarage"
                @click="negotiatedPrice ? purchaseAtNegotiatedPrice() : purchaseAtListedPrice()">
                {{ negotiatedPrice ? 'Buy at negotiated price' : 'Buy at listed price' }}
              </HouseButton>
            </div>
          </div>
        </div>
      </div>
    </div>

    <Teleport to="body">
      <!-- Controller: a trapping scope while open (focus on Apply, else Back); B / Start close it and focus
           goes back to Finance -->
      <div
        v-if="showMortgageModal"
        class="modal-overlay"
        v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', canDeactivate: () => (closeMortgageModal(), false) }"
        v-bng-on-ui-nav:menu="closeMortgageModal"
        @click="closeMortgageModal">
        <div class="rls-house modal-card modal-finance" @click.stop>
          <header class="card-head">
            <span class="caption kind"><BngIcon class="kind-icon" :type="icons.banknotes" />Finance</span>
            <h2 class="card-title">{{ name }}</h2>
          </header>

          <div class="price-strip">
            <div class="price-main">
              <span class="caption">Cash to close</span>
              <strong class="price-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(cashToClose) }}</strong>
            </div>
            <dl class="strip-facts">
              <div class="fact" :class="tierTone(mortgageData.creditTier)">
                <dt class="fact-key">Credit tier</dt>
                <dd class="fact-value">{{ mortgageData.creditTier }}</dd>
              </div>
              <div class="fact">
                <dt class="fact-key">Interest</dt>
                <dd class="fact-value">{{ mortgageData.interestRate.toFixed(1) }}%</dd>
              </div>
            </dl>
          </div>

          <div class="lines breakdown">
            <div class="line" v-if="mortgageData.downPayment > 0">
              <span>Down payment <small>{{ mortgageData.downPaymentPct }}%</small></span>
              <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(mortgageData.downPayment) }}</strong>
            </div>
            <div class="line" v-if="propertyTax > 0">
              <span>Property tax</span>
              <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(propertyTax) }}</strong>
            </div>
            <div class="line" v-if="closingFee > 0">
              <span>Closing fees</span>
              <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(closingFee) }}</strong>
            </div>
          </div>

          <div class="field-block">
            <span class="caption">Loan term</span>
            <div class="seg bar term-options">
              <button
                v-for="term in mortgageData.availableTerms"
                :key="term"
                class="term-btn"
                :class="{ active: selectedTerm === term }"
                @click="selectedTerm = term"
              >
                {{ term }} payments
                <span class="term-duration">{{ formatDuration(term * PAYMENT_INTERVAL_MINUTES) }}</span>
              </button>
            </div>
          </div>

          <div class="lines breakdown">
            <div class="line total">
              <span>Per payment <small>every 10 min</small></span>
              <strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(monthlyPayment) }}</strong>
            </div>
            <div class="line">
              <span>Total cost over loan</span>
              <strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(totalLoanCost) }}</strong>
            </div>
            <div class="line" v-if="totalLoanCost > effectivePrice">
              <span>Interest paid</span>
              <strong>+ <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(totalLoanCost - effectivePrice + mortgageData.downPayment) }}</strong>
            </div>
          </div>

          <p class="notice bad" v-if="!canAffordCashToClose">
            You need <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(cashToClose) }} at closing (down payment, closing costs and property tax).
          </p>

          <div class="actions">
            <HouseButton
              class="modal-close"
              variant="quiet"
              binding="back"
              :bng-scoped-nav-autofocus="canApplyMortgage ? null : ''"
              @click="closeMortgageModal">Back</HouseButton>
            <span class="actions-gap"></span>
            <HouseButton
              class="modal-action-btn finance-action"
              variant="primary"
              :disabled="!canApplyMortgage"
              :bng-scoped-nav-autofocus="canApplyMortgage ? '' : null"
              @click="applyForMortgage">Apply for mortgage</HouseButton>
          </div>
        </div>
      </div>
    </Teleport>

    <Teleport to="body">
      <!-- Controller: same as the finance modal (focus on the first Sign lease you can use, else Back) -->
      <div
        v-if="showRentalModal && rentalBreakdown"
        class="modal-overlay"
        v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', canDeactivate: () => (closeRentalModal(), false) }"
        v-bng-on-ui-nav:menu="closeRentalModal"
        @click="closeRentalModal">
        <div class="rls-house modal-card modal-rental" @click.stop>
          <header class="card-head">
            <span class="caption kind"><BngIcon class="kind-icon" :type="icons.keys1" />Rent</span>
            <h2 class="card-title">{{ name }}</h2>
          </header>

          <div class="price-strip">
            <div class="price-main">
              <span class="caption">Security deposit</span>
              <strong class="price-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(rentalBreakdown.deposit) }}</strong>
            </div>
            <dl class="strip-facts">
              <div class="fact" :class="rentalTierTone(rentalBreakdown.tierId)">
                <dt class="fact-key">Rental tier</dt>
                <dd class="fact-value">{{ rentalBreakdown.tier }}</dd>
              </div>
              <div class="fact ok" v-if="rentalBreakdown.creditEnhanced">
                <dt class="fact-key">Credit discount</dt>
                <dd class="fact-value">Applied</dd>
              </div>
            </dl>
          </div>

          <p v-if="!rentalBreakdown.canRent" class="notice bad">Maximum rental properties reached.</p>
          <p v-if="rentalBreakdown.cooldownActive" class="notice bad">Eviction cooldown active for this property.</p>
          <p v-if="rentalBreakdown.isOwned" class="notice bad">You already own this property.</p>
          <p v-if="rentalBreakdown.isRented" class="notice bad">You are already renting this property.</p>

          <div class="field-block">
            <span class="caption">Lease length <small class="caption-note">a payment every 10 min</small></span>
            <div class="seg bar term-options">
              <button class="term-btn" :class="{ active: selectedLeaseTerm === 6 }" @click="selectedLeaseTerm = 6">
                6 payments
                <span class="term-duration">1 hr</span>
              </button>
              <button class="term-btn" :class="{ active: selectedLeaseTerm === 12 }" @click="selectedLeaseTerm = 12">
                12 payments
                <span class="term-duration">2 hrs</span>
              </button>
            </div>
          </div>

          <div class="field-block">
            <span class="caption">Lease options</span>
            <div class="lease-list">
              <div v-if="rentalBreakdown.availableTypes.includes('fixed')" class="lease-card">
                <div class="lease-copy">
                  <strong class="lease-card-type">Fixed rent</strong>
                  <span class="lease-card-detail">Stable payments regardless of market changes.</span>
                  <span class="lease-card-total">
                    <b class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(rentalBreakdown.fixedRent) }}</b> / payment
                    <small>Total <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(rentalBreakdown.fixedRent * selectedLeaseTerm + rentalBreakdown.deposit) }} with deposit</small>
                  </span>
                </div>
                <HouseButton
                  class="modal-action-btn rental-action"
                  :disabled="!canSignLease"
                  :bng-scoped-nav-autofocus="canSignLease ? '' : null"
                  @click="signLease('fixed')">Sign lease</HouseButton>
              </div>

              <div v-if="rentalBreakdown.availableTypes.includes('dynamic')" class="lease-card">
                <div class="lease-copy">
                  <strong class="lease-card-type">Dynamic rent</strong>
                  <span class="lease-card-detail">Tracks market value: cheaper in downturns, pricier in booms.</span>
                  <span class="lease-card-total">
                    <b class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(rentalBreakdown.dynamicRent) }}</b> / payment
                    <small>Est. total <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(rentalBreakdown.dynamicRent * selectedLeaseTerm + rentalBreakdown.deposit) }} with deposit</small>
                  </span>
                </div>
                <HouseButton
                  class="modal-action-btn rental-action"
                  :disabled="!canSignLease"
                  @click="signLease('dynamic')">Sign lease</HouseButton>
              </div>

              <div v-if="rentalBreakdown.availableTypes.includes('upfront')" class="lease-card">
                <div class="lease-copy">
                  <strong class="lease-card-type">Upfront lease</strong>
                  <span class="lease-card-detail">Pay it all now for a 13% discount. No recurring payments.</span>
                  <span class="lease-card-total">
                    <b class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(selectedLeaseTerm === 6 ? rentalBreakdown.upfrontTotal6 : rentalBreakdown.upfrontTotal12) }}</b> once
                    <small>Total <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice((selectedLeaseTerm === 6 ? rentalBreakdown.upfrontTotal6 : rentalBreakdown.upfrontTotal12) + rentalBreakdown.deposit) }} with deposit</small>
                  </span>
                </div>
                <HouseButton
                  class="modal-action-btn rental-action"
                  :disabled="!canSignLease"
                  @click="signLease('upfront')">Sign lease</HouseButton>
              </div>
            </div>
          </div>

          <div class="actions">
            <HouseButton
              class="modal-close"
              variant="quiet"
              binding="back"
              :bng-scoped-nav-autofocus="canSignLease ? null : ''"
              @click="closeRentalModal">Back</HouseButton>
          </div>
        </div>
      </div>
    </Teleport>
  </LayoutSingle>
</template>

<script setup>
import { useUINavScope } from "@/services/uiNav"
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { LayoutSingle } from '@/common/layouts'
import { BngIcon, icons } from '@/common/components/base'
import { vBngOnUiNav, vBngScopedNav } from '@/common/directives'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
import { HouseButton } from '../components/house/index.js'

useUINavScope("garageListing")

const { events } = useBridge()

const PAYMENT_INTERVAL_MINUTES = 10

const garageId = ref('')
const name = ref('')
const preview = ref('')
const listedPrice = ref(0)
const negotiatedPrice = ref(null)
const closingFee = ref(0)
const propertyTax = ref(0)
const estimatedTotal = ref(0)
const capacity = ref(0)
const parkingSpots = ref(0)
const neighborhood = ref('')
const canNegotiate = ref(true)
const cooldownRemaining = ref(0)
const isFrozen = ref(false)
const starterGarage = ref(false)
const cantPay = ref(true)
const mortgageAvailable = ref(false)
const mortgageCreditTier = ref('')
const showMortgageModal = ref(false)
const showRentalModal = ref(false)
const selectedTerm = ref(24)
const mortgageData = ref({
  creditTier: '',
  downPaymentPct: 0,
  downPayment: 0,
  cashToClose: 0,
  interestRate: 0,
  availableTerms: [12, 24, 36, 48],
})
const rentalBreakdown = ref(null)
const selectedLeaseTerm = ref(12)

const effectivePrice = computed(() => negotiatedPrice.value || listedPrice.value)

const cashToClose = computed(() => {
  if (mortgageData.value.cashToClose > 0) {
    return mortgageData.value.cashToClose
  }
  return mortgageData.value.downPayment + closingFee.value + propertyTax.value
})

const loanAmount = computed(() => effectivePrice.value - mortgageData.value.downPayment)

const monthlyPayment = computed(() => {
  const P = loanAmount.value
  const annualRate = mortgageData.value.interestRate / 100
  const n = selectedTerm.value
  if (n === 0) return P
  const r = annualRate / n
  if (r === 0) return P / n
  return (P * r * Math.pow(1 + r, n)) / (Math.pow(1 + r, n) - 1)
})

const totalLoanCost = computed(() => monthlyPayment.value * selectedTerm.value + mortgageData.value.downPayment)

const canAffordCashToClose = ref(true)

const canApplyMortgage = computed(() => garageId.value && canAffordCashToClose.value && selectedTerm.value > 0)
// Rent shows only for a property you could rent (not a starter, not already yours / rented)
const showRent = computed(() => {
  const r = rentalBreakdown.value
  return !!r && !starterGarage.value && !r.isOwned && !r.isRented
})

// tier names -> house tone: green for good news, amber for middling, red for bad, plain otherwise
const tierTone = tier => ({ excellent: 'ok', good: 'ok', fair: 'warn', poor: 'bad', bad: 'bad' })[String(tier || '').toLowerCase()] || null
const rentalTierTone = tierId => ({ veteran: 'ok', experienced: 'ok', new: 'warn', risky: 'bad' })[tierId] || null

const canSignLease = computed(() => {
  const r = rentalBreakdown.value
  return !!r && r.canRent && !r.cooldownActive && !r.isOwned && !r.isRented
})

const applyListingData = (data) => {
  if (!data) return
  const raw = data.garageId ?? data.id ?? ''
  garageId.value = (typeof raw === 'string' && raw) ? raw : ''
  name.value = data.name || 'Property'
  preview.value = data.preview || ''
  listedPrice.value = data.listedPrice || 0
  negotiatedPrice.value = data.negotiatedPrice || null
  closingFee.value = data.closingFee || 0
  propertyTax.value = data.propertyTax || 0
  estimatedTotal.value = data.estimatedTotal || data.listedPrice || 0
  capacity.value = data.capacity || 0
  parkingSpots.value = data.parkingSpots || 0
  neighborhood.value = data.neighborhood || ''
  canNegotiate.value = data.canNegotiate !== false
  cooldownRemaining.value = data.cooldownRemaining || 0
  isFrozen.value = data.isFrozen || false
  starterGarage.value = data.starterGarage || false
  mortgageAvailable.value = data.mortgageAvailable || false
  mortgageCreditTier.value = data.creditTier || ''
  rentalBreakdown.value = data.rentalBreakdown || null
  if (data.mortgageInfo) {
    mortgageData.value = {
      creditTier: data.mortgageInfo.creditTier || '',
      downPaymentPct: data.mortgageInfo.downPaymentPct || 0,
      downPayment: data.mortgageInfo.downPayment || 0,
      cashToClose: data.mortgageInfo.cashToClose || data.mortgageInfo.downPayment || 0,
      interestRate: (data.mortgageInfo.interestRate || 0) * 100,
      availableTerms: data.mortgageInfo.availableTerms || [12, 24, 36, 48],
    }
    if (data.mortgageInfo.availableTerms && data.mortgageInfo.availableTerms.length) {
      selectedTerm.value = data.mortgageInfo.availableTerms[1] || data.mortgageInfo.availableTerms[0]
    }
  }
}

const fetchGarageListing = async () => {
  if (!garageId.value || !lua.overhaul_career_garage_garageManager.requestGarageListing) return null
  try {
    return await lua.overhaul_career_garage_garageManager.requestGarageListing(garageId.value)
  } catch (error) {
    return null
  }
}

const handleGarageListingData = async (data) => {
  if (!data) return
  applyListingData(data)
  if (!garageId.value) return
  if (!data.name || data.listedPrice == null || data.closingFee == null) {
    const fetchedListing = await fetchGarageListing()
    if (fetchedListing) {
      applyListingData(fetchedListing)
      return
    }
  }
  if (!data.name || data.listedPrice == null) {
    const fallback = await lua.overhaul_career_garage_garageManager.requestGarageData()
    if (fallback) {
      name.value = fallback.name || name.value
      listedPrice.value = fallback.price ?? listedPrice.value
      capacity.value = fallback.capacity ?? capacity.value
      starterGarage.value = fallback.starterGarage ?? starterGarage.value
      canNegotiate.value = fallback.canNegotiate ?? canNegotiate.value
    }
  }
}

let cooldownTimer = null

onMounted(async () => {
  events.on('openGarageListing', handleGarageListingData)
  const pending = await lua.overhaul_career_garage_garageManager.getPendingGarageListing()
  if (pending) await handleGarageListingData(pending)
  try {
    cantPay.value = !(await lua.overhaul_career_garage_garageManager.canPay(estimatedTotal.value))
  } catch (error) {
    cantPay.value = true
  }

  // controller entry (no scope on this screen): the buy button when usable, else Finance, Rent, an offer,
  // then Cancel (the row is laid out Offer / Rent / Finance above Cancel / Buy, so DOM order is not enough)
  refocusIfLost(() => firstListingAction(['.btn-buy', '.btn-finance', '.btn-rent', '.btn-offer', 'button']))

  cooldownTimer = setInterval(() => {
    if (cooldownRemaining.value > 0) {
      cooldownRemaining.value = Math.max(0, cooldownRemaining.value - 1)
    }
    if (cooldownRemaining.value <= 0 && negotiatedPrice.value) {
      negotiatedPrice.value = null
    }
  }, 1000)
})

onUnmounted(() => {
  events.off('openGarageListing', handleGarageListingData)
  if (cooldownTimer) clearInterval(cooldownTimer)
})

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const formatCooldown = (seconds) => {
  if (seconds <= 0) return ''
  const minutes = Math.floor(seconds / 60)
  const secs = seconds % 60
  if (minutes > 0) return `${minutes}m ${secs}s`
  return `${secs}s`
}

const formatDuration = (totalMinutes) => {
  if (totalMinutes < 60) return `${totalMinutes} min`
  const hrs = totalMinutes / 60
  if (hrs === Math.floor(hrs)) return `${hrs} hr${hrs > 1 ? 's' : ''}`
  return `${hrs.toFixed(1)} hrs`
}

const purchaseAtListedPrice = async () => {
  if (!garageId.value || typeof garageId.value !== 'string') return
  await lua.overhaul_career_garage_garageManager.purchaseGarageAtListedPrice(garageId.value)
}

const purchaseAtNegotiatedPrice = async () => {
  if (!garageId.value || typeof garageId.value !== 'string') return
  await lua.overhaul_career_garage_garageManager.purchaseGarageAtNegotiatedPrice(garageId.value)
}

const startNegotiation = () => {
  if (!garageId.value || typeof garageId.value !== 'string') return
  lua.overhaul_career_garage_garageManager.startGarageNegotiation(garageId.value)
}

const freezeNegotiatedPrice = () => {
  if (!garageId.value || typeof garageId.value !== 'string' || !negotiatedPrice.value) return
  lua.overhaul_career_garage_garageManager.freezeNegotiatedPrice(garageId.value, negotiatedPrice.value)
  isFrozen.value = true
}

const openMortgageModal = async () => {
  showRentalModal.value = false
  showMortgageModal.value = true
  try {
    const playerMoney = await lua.overhaul_career_economy_playerAttributes.getAttributeValue("money")
    canAffordCashToClose.value = playerMoney >= cashToClose.value
  } catch (e) {
    canAffordCashToClose.value = false
  }
}

const firstListingAction = sels => {
  for (const sel of sels) {
    const el = document.querySelector(`.listing-panel .btn-row ${sel}:not([disabled])`)
    if (el) return el
  }
  return null
}

// Close a modal and put a pad back on the button that opened it (the modal content is unmounted)
const refocusOpener = (sel) => refocusIfLost(() =>
  document.querySelector(`.listing-panel ${sel}:not([disabled])`) ||
  firstListingAction(['.btn-buy', 'button']), { force: true })
const closeMortgageModal = () => {
  if (!showMortgageModal.value) return
  showMortgageModal.value = false
  refocusOpener('.btn-finance')
}
const closeRentalModal = () => {
  if (!showRentalModal.value) return
  showRentalModal.value = false
  refocusOpener('.btn-rent')
}
// the cash check finishes after the modal opened: if Apply turned disabled under focus, move to close
watch(canApplyMortgage, can => {
  if (!can && showMortgageModal.value) refocusIfLost(() => document.querySelector('.modal-finance .modal-close'), { force: !!document.activeElement?.disabled })
}, { flush: 'post' })

const openRentalModal = () => {
  showMortgageModal.value = false
  showRentalModal.value = true
}

const applyForMortgage = async () => {
  if (!garageId.value || typeof garageId.value !== 'string') return
  await lua.overhaul_career_garage_garageManager.buyGarage(null, true, selectedTerm.value)
}

const signLease = async (rentalType) => {
  if (!garageId.value || typeof garageId.value !== 'string') return
  const result = await lua.overhaul_career_garage_property_propertyRentals.signLease(garageId.value, rentalType, selectedLeaseTerm.value)
  if (result && !result.error) {
    showRentalModal.value = false
    lua.overhaul_career_career.closeAllMenus()
  }
}

// B / Start handler for this unscoped screen: the directive's listener does not stop the ui_nav event by
// itself, so without stopPropagation it also reaches the game's global fallback (ui_router.back())
const onNavCancel = (event) => {
  event?.stopPropagation?.()
  cancel()
}

const cancel = () => {
  lua.overhaul_career_garage_garageManager.cancelGaragePurchase()
  lua.overhaul_career_career.closeAllMenus()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.garage-listing-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
}

.listing-backdrop {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.55);
  z-index: 100;
}

/* house popup cards: near-black ground, faint ring, sized in em off the screen height */
.listing-panel,
.modal-card {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  max-height: calc(100vh - 2em);
  overflow-y: auto;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  color: #fff;
}

.listing-panel {
  width: min(40em, 100%);
}

/* slim translucent scrollbar when a short screen makes a card scroll (no reserved gutter: the photo
   runs edge to edge) */
.listing-panel,
.modal-card {
  &::-webkit-scrollbar { width: 0.45em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    border-radius: 1em;
    background: rgba(255, 255, 255, 0.22);
  }
}

/* photo with the name on a bottom scrim */
.panel-preview {
  position: relative;
  aspect-ratio: 16 / 6.5;
  overflow: hidden;
  background: var(--photo);
  &::after {
    content: "";
    position: absolute;
    inset: 0;
    background: linear-gradient(to top, rgba(26, 26, 28, 1) 0%, rgba(26, 26, 28, 0.55) 38%, rgba(26, 26, 28, 0) 72%);
    pointer-events: none;
  }
  &.no-photo {
    aspect-ratio: auto;
    min-height: 6.5em;
  }
}

.preview-img {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.photo-pill {
  position: absolute;
  top: 0.9em;
  left: 1em;
  z-index: 1;
  background: rgba(0, 0, 0, 0.6);
  color: rgba(255, 255, 255, 0.9);
  &.ok {
    background: rgba(22, 101, 52, 0.85);
    color: var(--ok-ink);
  }
}

.preview-copy {
  position: absolute;
  left: 1.4em;
  right: 1.4em;
  bottom: 0.55em;
  z-index: 1;
  display: grid;
  gap: 0.25em;
}

.prop-name {
  margin: 0;
  font-size: 1.6em;
  font-weight: 800;
  line-height: 1.15;
  text-shadow: 0 1px 3px rgba(0, 0, 0, 0.8);
}

.prop-location {
  display: flex;
  align-items: center;
  gap: 0.35em;
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
  svg {
    width: 0.9em;
    height: 0.9em;
    flex: 0 0 auto;
    transform: translateY(-0.05em);
  }
}

.panel-body {
  display: grid;
  gap: 1em;
  padding: 0.6em 1.4em 1.2em;
}

/* modal cards (finance / rent) */
.modal-overlay {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  z-index: 200;
}

.modal-card {
  width: min(34em, 100%);
  display: grid;
  gap: 1em;
  padding: 1.3em 1.4em 1.2em;
}

.card-head {
  display: grid;
  gap: 0.3em;
}

.kind {
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
}
.kind-icon {
  font-size: 1.35em;
  line-height: 1;
  transform: translateY(-0.08em);
}

.card-title {
  margin: 0;
  font-size: 1.55em;
  font-weight: 800;
  line-height: 1.15;
}

/* the price is the hero; facts sit beside it on the same panel */
.price-strip {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  justify-content: space-between;
  gap: 0.8em 2em;
  padding: 0.95em 1.05em 0.85em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.price-main {
  display: grid;
  gap: 0.25em;
}

.was {
  margin-left: 0.4em;
  color: var(--faint);
  letter-spacing: 0;
  font-variant-numeric: tabular-nums;
}

.price-amount {
  color: var(--money);
  font-size: 2.15em;
  font-weight: 800;
  line-height: 1;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.strip-facts {
  display: flex;
  gap: 1.6em;
  margin: 0;
  dd {
    margin: 0;
  }
  .fact-value {
    font-size: 1.1em;
    font-variant-numeric: tabular-nums;
    overflow: visible;
    text-overflow: clip;
  }
}

.price-tools {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--space-2);
  margin-top: -0.35em;
}
.frozen-badge {
  padding: 0.55em 0.75em 0.3em;
  font-size: 0.82em;
}
.pill-icon {
  font-size: 1.2em;
  line-height: 1;
  transform: translateY(-0.12em);
}

.breakdown {
  padding: 0 0.15em;
  .line {
    font-size: 0.98em;
    > span {
      color: var(--muted);
      font-weight: 600;
    }
    small {
      margin-left: 0.25em;
      color: var(--faint);
      font-size: 0.82em;
      font-variant-numeric: tabular-nums;
    }
    strong {
      font-weight: 700;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
  }
  .line.total {
    > span {
      color: #fff;
      font-weight: 700;
    }
    strong {
      font-size: 1.12em;
    }
  }
  .money {
    color: var(--money);
  }
}

.notice {
  font-size: 0.95em;
}

/* term pickers: a joined .seg bar, two-line buttons */
.term-options {
  .term-btn {
    display: grid;
    justify-items: center;
    gap: 0.3em;
    padding: 0.6em 0.4em 0.45em;
    font-size: 0.92em;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  .term-duration {
    color: var(--faint);
    font-size: 0.8em;
    font-weight: 600;
  }
  .term-btn.active .term-duration {
    color: var(--muted);
  }
}

.caption-note {
  margin-left: 0.4em;
  color: var(--faint);
  font-size: 1em;
  font-weight: 600;
  letter-spacing: 0.02em;
  text-transform: none;
}

/* lease options: one panel per lease, its own Sign lease button on the right */
.lease-list {
  display: grid;
  gap: var(--space-2);
}
.lease-card {
  display: flex;
  align-items: center;
  gap: 1em;
  padding: 0.8em 0.9em 0.75em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.lease-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.25em;
}
.lease-card-type {
  font-size: 1.05em;
  font-weight: 700;
  line-height: 1.2;
}
.lease-card-detail {
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 600;
  line-height: 1.35;
}
.lease-card-total {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.15em 0.4em;
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  b {
    font-size: 1.12em;
    font-weight: 800;
  }
  small {
    flex-basis: 100%;
    color: var(--faint);
    font-size: 0.88em;
  }
}
.money {
  color: var(--money);
}

/* actions: other ways in as equal neutral buttons, then Cancel / Buy */
.btn-row {
  display: grid;
  gap: var(--space-2);
  margin-top: 0.1em;
}
.alt-actions {
  display: flex;
  gap: var(--space-2);
  > :deep(.house-button) {
    flex: 1 1 0;
  }
}
.actions {
  flex-wrap: nowrap;
  > :deep(.house-button) {
    min-width: 7em;
  }
  > .btn-buy,
  > .finance-action {
    min-width: 12em;
  }
}
.actions-gap {
  flex: 1 1 auto;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
