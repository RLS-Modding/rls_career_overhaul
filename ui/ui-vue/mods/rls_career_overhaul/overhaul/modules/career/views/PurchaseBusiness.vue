<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <!-- no scope on the purchase card: B / Start cancel the purchase; the finance step is its own trapping
       scope (B / Start close it and focus goes back to Finance) -->
  <LayoutSingle class="purchase-layout">
    <!-- display: contents wrapper so B / Start reach one handler from the card (and from the Engine Works overview) -->
    <div class="nav-root" v-bng-on-ui-nav:back,menu="onBack">
    <div class="confirmation-overlay purchase-overlay">
        <EngineShopOverview
          v-if="loaded && showsEngineProduction"
          purchase-mode
          :price="price"
          :down-payment="downPayment"
          :cant-pay="cantPay"
          :financing-allowed="financingAllowed"
          :nav-locked="showFinanceModal"
          @purchase="confirmPurchase"
          @finance="showFinanceModal = true"
          @cancel="cancelPurchase"
        />
        <!-- RLS house popup: kind + name, the description, the price as the hero with the financing facts
             beside it, then Cancel (quiet, B) on the left and Finance / Purchase (the one orange) on the right -->
        <section v-else-if="loaded" class="rls-house purchase-card">
          <header class="card-head">
            <span class="caption kind"><BngIcon class="kind-icon" :type="kind.icon" />{{ kindCaption }}</span>
            <h2 class="card-title">{{ businessName }}</h2>
            <p v-if="description" class="lead">{{ description }}</p>
          </header>

          <div class="price-strip">
            <div class="price-main">
              <span class="caption">Price</span>
              <strong class="price-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(price) }}</strong>
            </div>
            <dl class="strip-facts">
              <div v-if="financingAllowed" class="fact money">
                <dt class="fact-key">Down payment</dt>
                <dd class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(downPayment) }}</dd>
              </div>
              <div class="fact">
                <dt class="fact-key">Financing</dt>
                <dd class="fact-value">{{ financingAllowed ? `${FINANCE_PAYMENTS} days at 0%` : "Cash only" }}</dd>
              </div>
            </dl>
          </div>

          <p v-if="cantPay" class="notice bad">
            Not enough money to buy it outright.<template v-if="financingAllowed && canAffordDownPayment"> Financing only needs the down payment.</template>
          </p>

          <!-- while the finance step is open these leave controller navigation (nav-item false = bng-no-nav) -->
          <div class="actions">
            <HouseButton class="cancel-button" variant="quiet" binding="back" :nav-item="!showFinanceModal" @click="cancelPurchase">Cancel</HouseButton>
            <span class="actions-gap"></span>
            <HouseButton v-if="financingAllowed" class="finance-button" :nav-item="!showFinanceModal" @click="showFinanceModal = true">Finance</HouseButton>
            <HouseButton
              ref="purchaseButton"
              class="purchase-button"
              variant="primary"
              :disabled="cantPay"
              :nav-item="!showFinanceModal"
              @click="confirmPurchase">Purchase</HouseButton>
          </div>
        </section>
        <div v-else class="loading-copy">Loading business details...</div>
      </div>

    <!-- Controller: a trapping scope while open (focus on Confirm, else Back); B / Start close it -->
    <div
      v-if="financingAllowed && showFinanceModal"
      class="confirmation-overlay finance-overlay"
      v-bng-blur
      v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', canDeactivate: () => (closeFinance(), false) }"
      v-bng-on-ui-nav:menu="closeFinance"
      @click.stop>
      <!-- finance step: what is due today as the hero, the daily payment beside it, the breakdown below -->
      <section class="rls-house purchase-card finance-card" @click.stop>
        <header class="card-head">
          <span class="caption kind"><BngIcon class="kind-icon" :type="icons.banknotes" />Finance</span>
          <h2 class="card-title">{{ businessName }}</h2>
          <p class="lead">Pay the down payment now. The business account pays off the rest in {{ FINANCE_PAYMENTS }} daily payments, interest free.</p>
        </header>

        <div class="price-strip">
          <div class="price-main">
            <span class="caption">Due today</span>
            <strong class="price-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(downPayment) }}</strong>
          </div>
          <dl class="strip-facts">
            <div class="fact money">
              <dt class="fact-key">Per payment</dt>
              <dd class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(perPayment) }}<small>/ day</small></dd>
            </div>
            <div class="fact">
              <dt class="fact-key">Payments</dt>
              <dd class="fact-value">{{ FINANCE_PAYMENTS }} daily</dd>
            </div>
          </dl>
        </div>

        <div class="lines breakdown">
          <div class="line">
            <span>Price</span>
            <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(price) }}</strong>
          </div>
          <div class="line">
            <span>Down payment</span>
            <strong>&minus;<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(downPayment) }}</strong>
          </div>
          <div class="line">
            <span>Financed at 0%</span>
            <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(financedAmount) }}</strong>
          </div>
          <div class="line total">
            <span>Total cost</span>
            <strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(price) }}</strong>
          </div>
        </div>

        <p v-if="!canAffordDownPayment" class="notice bad">Not enough money for the down payment.</p>

        <div class="actions">
          <HouseButton
            class="finance-cancel"
            variant="quiet"
            binding="back"
            :bng-scoped-nav-autofocus="canAffordDownPayment ? null : ''"
            @click="closeFinance">Back</HouseButton>
          <span class="actions-gap"></span>
          <HouseButton
            class="finance-confirm"
            variant="primary"
            :disabled="!canAffordDownPayment"
            :bng-scoped-nav-autofocus="canAffordDownPayment ? '' : null"
            @click="confirmFinance">Confirm finance</HouseButton>
        </div>
      </section>
    </div>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { lua } from '@/bridge'
import { BngIcon, icons } from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'
import { vBngBlur, vBngOnUiNav, vBngScopedNav } from '@/common/directives'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
import { HouseButton } from '../components/house/index.js'
import EngineShopOverview from '../components/businessComputer/types/engineShop/EngineShopOverview.vue'
import { businessTypeHasCapability } from '../utils/businessTypeCatalog.js'

// businessManager.financeBusiness() always books the rest as one 0% loan of 72 payments, one per
// in-game day, drawn from the business account (overhaul_career_economy_loans.takeLoan(..., 72, 0, ..., 1440))
const FINANCE_PAYMENTS = 72

// facility type -> what the player is buying (the caption over the name)
const KINDS = {
  tuningShop: { label: "Tuning shop", icon: icons.gearTuningOutline },
  racingTeam: { label: "Racing team", icon: icons.raceFlag },
  engineShop: { label: "Engine works", icon: icons.engine },
  passiveBusiness: { label: "Retail business", icon: icons.shoppingCart },
}

const purchaseButton = ref(null)
const price = ref(0)
// number only: the template puts the game currency glyph in front
const formatMoney = value => Math.round(Number(value) || 0).toLocaleString("en-US")
const businessName = ref('')
const description = ref('')
const downPayment = ref(0)
const cantPay = ref(true)
const showFinanceModal = ref(false)
const canAffordDownPayment = ref(false)
const financingAllowed = ref(true)
const businessType = ref('')
const showsEngineProduction = computed(() => businessTypeHasCapability(businessType.value, 'engineProduction'))
const loaded = ref(false)

const financedAmount = computed(() => {
  return Math.max(0, price.value - downPayment.value)
})
const perPayment = computed(() => financedAmount.value / FINANCE_PAYMENTS)

const kind = computed(() => KINDS[businessType.value] || { label: "Business", icon: icons.banknotes })
// "Tuning shop for sale" over "Tuning Shop" would say the same thing twice
const kindCaption = computed(() =>
  kind.value.label.toLowerCase() === businessName.value.trim().toLowerCase() ? "Business for sale" : `${kind.value.label} for sale`)

onMounted(async () => {
  try {
    const businessData = await lua.overhaul_career_business_manager.requestBusinessData()
    if (businessData) {
      price.value = businessData.price
      businessName.value = businessData.name
      description.value = businessData.description || ''
      downPayment.value = businessData.downPayment || 0
      financingAllowed.value = businessData.financingAllowed !== false
      businessType.value = businessData.businessType || ''
      cantPay.value = !(await lua.overhaul_career_business_manager.canPayBusiness())
      canAffordDownPayment.value = financingAllowed.value
        ? await lua.overhaul_career_business_manager.canAffordDownPayment()
        : false
    }
  } finally {
    loaded.value = true
  }
})

function confirmPurchase() {
  lua.overhaul_career_business_manager.buyBusiness()
  lua.overhaul_career_career.closeAllMenus()
}

function cancelPurchase() {
  lua.overhaul_career_business_manager.cancelBusinessPurchase()
  lua.overhaul_career_career.closeAllMenus()
}

// Controller (no scope on this screen): entry lands on the first usable action in priority order
// (Purchase, else Finance, else Cancel; the buttons sit Cancel-first in the row, so DOM order is not
// enough); the finance step takes focus while open (Confirm, else Back) and hands it back to Finance.
const usable = ':not([disabled]):not([bng-no-nav="true"])'
const firstAction = (root, sels) => {
  for (const sel of sels) {
    const el = document.querySelector(`${root} ${sel}${usable}`)
    if (el) return el
  }
  return null
}
const purchaseEntry = () => firstAction(".purchase-overlay", [".btn-primary", ".finance-button", "button"])
watch(loaded, isLoaded => {
  if (isLoaded) refocusIfLost(purchaseEntry)
}, { flush: "post" })
watch(showFinanceModal, open => {
  refocusIfLost(() => (open
    ? firstAction(".finance-overlay", [".btn-primary", "button"])
    : document.querySelector(`.purchase-overlay .finance-button${usable}`) || purchaseEntry()), { force: true })
}, { flush: "post" })

// (unscoped card: stop the event, or it also reaches the game's global ui_router.back() fallback). While the
// finance step's scope is active it takes B itself; the check stays for a press that slips past it.
function onBack(event) {
  event?.stopPropagation?.()
  if (showFinanceModal.value) closeFinance()
  else cancelPurchase()
}

function closeFinance() {
  showFinanceModal.value = false
}

function confirmFinance() {
  lua.overhaul_career_business_manager.financeBusiness()
  lua.overhaul_career_career.closeAllMenus()
}

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.nav-root {
  display: contents;
}

.purchase-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
}

.confirmation-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.5);
  z-index: 100;
}

.finance-overlay {
  z-index: 101;
  background: rgba(0, 0, 0, 0.6);
}

/* house popup card: near-black ground, faint ring, sized in em off the screen height */
.purchase-card {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(34em, 100%);
  max-height: calc(100vh - 2em);
  overflow-y: auto;
  display: grid;
  gap: 1.05em;
  padding: 1.3em 1.4em 1.2em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
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

.lead {
  margin: 0.15em 0 0;
  color: var(--muted);
  font-size: 0.98em;
  font-weight: 600;
  line-height: 1.45;
}

/* the price is the hero; the financing facts sit beside it on the same panel */
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
    small {
      margin-left: 0.2em;
      color: var(--faint);
      font-size: 0.72em;
      font-weight: 700;
    }
  }
}

.breakdown {
  padding: 0 0.15em;
  .line {
    font-size: 0.98em;
    > span {
      color: var(--muted);
      font-weight: 600;
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

.actions {
  flex-wrap: nowrap;
  margin-top: 0.1em;
  > :deep(.house-button) {
    min-width: 7em;
  }
  > .purchase-button,
  > .finance-confirm {
    min-width: 9.5em;
  }
}
.actions-gap {
  flex: 1 1 auto;
}

.loading-copy {
  color: rgba(255, 255, 255, 0.72);
  font-size: 0.9rem;
  letter-spacing: 0.04em;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
