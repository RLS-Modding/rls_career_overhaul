<template>
  <LayoutSingle class="purchase-layout">
    <!-- Active scope routes Back through purchase cleanup, even with focus on body. -->
    <div class="confirmation-overlay" bng-ui-scope="purchaseGarage" v-bng-on-ui-nav:back,menu="onNavCancel">
      <!-- RLS house popup: the garage, what you pay in total as the hero (slots beside it), how that total
           is made up, then Cancel (quiet, B) and Confirm purchase (the one orange) -->
      <section class="rls-house purchase-card">
        <header class="card-head">
          <span class="caption kind"><BngIcon class="kind-icon" :type="icons.garage01" />Garage for sale</span>
          <h2 class="card-title">{{ garageName }}</h2>
        </header>

        <div class="price-strip">
          <div class="price-main">
            <span class="caption">Total cost</span>
            <strong class="price-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(estimatedTotal) }}</strong>
          </div>
          <dl class="strip-facts">
            <div class="fact">
              <dt class="fact-key">Vehicle slots</dt>
              <dd class="fact-value">{{ garageCapacity }}</dd>
            </div>
          </dl>
        </div>

        <div class="lines breakdown">
          <div class="line">
            <span>Purchase price</span>
            <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(price) }}</strong>
          </div>
          <div class="line">
            <span>Closing fee <small>{{ closingFeeRatePercent }}</small></span>
            <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(closingFee) }}</strong>
          </div>
          <div class="line">
            <span>Property tax <small>{{ propertyTaxRatePercent }}</small></span>
            <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(propertyTax) }}</strong>
          </div>
        </div>

        <p class="notice bad" v-if="cantPay">Not enough money for the total.</p>

        <div class="actions">
          <HouseButton
            ref="cancelButton"
            class="cancel-button"
            variant="quiet"
            binding="back"
            @click="cancelPurchase">Cancel</HouseButton>
          <span class="actions-gap"></span>
          <HouseButton
            ref="purchaseButton"
            class="confirm-button"
            variant="primary"
            :disabled="cantPay"
            @click="confirmPurchase">Confirm purchase</HouseButton>
        </div>
      </section>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { useUINavScope } from "@/services/uiNav"
import { ref, onMounted, computed } from 'vue'
import { lua } from '@/bridge'
import { BngIcon, icons } from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'
import { vBngOnUiNav } from '@/common/directives'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
import { HouseButton } from '../components/house/index.js'

useUINavScope("purchaseGarage")

const purchaseButton = ref(null)
const cancelButton = ref(null)
const price = ref(0)
const garageName = ref('')
const garageCapacity = ref(0)
const cantPay = ref(true)
const closingFee = ref(0)
const propertyTax = ref(0)
const closingFeeRate = ref(0.03)
const propertyTaxRate = ref(0.012)
const estimatedTotalOverride = ref(null)

const closingFeeRatePercent = computed(() => `${(closingFeeRate.value * 100).toFixed(1)}%`)
const propertyTaxRatePercent = computed(() => `${(propertyTaxRate.value * 100).toFixed(1)}%`)
const estimatedTotal = computed(() => estimatedTotalOverride.value ?? (price.value + closingFee.value + propertyTax.value))
// number only: the template puts the game currency glyph in front
const formatMoney = value => Math.round(Number(value) || 0).toLocaleString("en-US")

onMounted(async () => {
  const garageData = await lua.overhaul_career_garage_garageManager.requestGarageData()
  if (garageData) {
    price.value = garageData.price
    garageName.value = garageData.name
    garageCapacity.value = garageData.capacity
    if (garageData.closingFeeRate !== undefined) {
      closingFeeRate.value = garageData.closingFeeRate
    }
    if (garageData.propertyTaxRate !== undefined) {
      propertyTaxRate.value = garageData.propertyTaxRate
    }
    closingFee.value = garageData.closingFee ?? Math.round(price.value * closingFeeRate.value)
    propertyTax.value = garageData.propertyTax ?? Math.round(price.value * propertyTaxRate.value)
    estimatedTotalOverride.value = garageData.estimatedTotal ?? null
    cantPay.value = !(await lua.overhaul_career_garage_garageManager.canPay(estimatedTotal.value))
  }
  // Controller entry: the purchase button when it can be paid, else Cancel
  refocusIfLost(() => (!cantPay.value && purchaseButton.value?.$el) || cancelButton.value?.$el)
})

async function confirmPurchase() {
  await lua.overhaul_career_garage_garageManager.buyGarage(estimatedTotal.value)
}

// B / Start handler for this purchase screen: the directive's listener does not stop the ui_nav event by
// itself, so without stopPropagation it also reaches the game's global fallback (ui_router.back())
function onNavCancel(event) {
  event?.stopPropagation?.()
  cancelPurchase()
}

function cancelPurchase() {
  lua.overhaul_career_garage_garageManager.cancelGaragePurchase()
  lua.overhaul_career_career.closeAllMenus()
}

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.purchase-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
}

.confirmation-overlay {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.5);
  z-index: 100;
}

/* house popup card: near-black ground, faint ring, sized in em off the screen height */
.purchase-card {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(32em, 100%);
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

/* what you pay is the hero; the slot count sits beside it on the same panel */
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
  > .confirm-button {
    min-width: 10em;
  }
}
.actions-gap {
  flex: 1 1 auto;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
