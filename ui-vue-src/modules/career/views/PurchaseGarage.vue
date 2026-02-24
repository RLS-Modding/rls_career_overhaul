<template>
  <LayoutSingle class="purchase-layout">
    <div class="confirmation-overlay">
      <BngCard class="confirmation-card">
        <BngCardHeading class="card-heading">Purchase {{ garageName }}</BngCardHeading>

        <div class="modal-content">
          <div class="summary-panel">
            <div class="summary-title">You are about to purchase a garage</div>
            <div class="summary-title-value">{{ garageName }}</div>
            <div class="summary-subtitle">
              This property adds <strong>{{ garageCapacity }} vehicle slot{{ garageCapacity === 1 ? '' : 's' }}</strong>
            </div>
          </div>

          <div class="price-breakdown">
            <div class="line-item">
              <span>Purchase Price</span>
              <BngUnit class="money" :money="price" />
            </div>
            <div class="line-item">
              <span>Closing Fee ({{ closingFeeRatePercent }})</span>
              <BngUnit class="money" :money="closingFee" />
            </div>
            <div class="line-item">
              <span>Property Tax ({{ propertyTaxRatePercent }})</span>
              <BngUnit class="money" :money="propertyTax" />
            </div>
            <div class="line-item total">
              <span>Estimated Total</span>
              <BngUnit class="money" :money="estimatedTotal" />
            </div>
          </div>

          <p class="funds-warning" v-if="cantPay">You don't have enough funds for the total.</p>
        </div>

        <div class="confirm-button-container">
          <BngButton
            ref="purchaseButton"
            class="confirm-button"
            @click="confirmPurchase"
            :accent="ACCENTS.primary"
            :disabled="cantPay"
          >
            Confirm Purchase
          </BngButton>
          <BngButton
            class="cancel-button"
            @click="cancelPurchase"
            :accent="ACCENTS.secondary"
          >
            Cancel
          </BngButton>
        </div>
      </BngCard>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { ref, onMounted, computed } from 'vue'
import { lua } from '@/bridge'
import {
  BngButton,
  ACCENTS,
  BngCard,
  BngCardHeading,
  BngUnit
} from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'

const purchaseButton = ref(null)
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

onMounted(async () => {
  const garageData = await lua.career_modules_garageManager.requestGarageData()
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
    cantPay.value = !(await lua.career_modules_garageManager.canPay(estimatedTotal.value))
  }
})

async function confirmPurchase() {
  await lua.career_modules_garageManager.buyGarage(estimatedTotal.value)
}

function cancelPurchase() {
  lua.career_modules_garageManager.cancelGaragePurchase()
  lua.career_career.closeAllMenus()
}

</script>

<style scoped lang="scss">
.purchase-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
  background: radial-gradient(circle at top left, rgba(26, 45, 61, 0.95), rgba(8, 16, 26, 0.95));
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
  padding: 1.5rem;
  background: radial-gradient(circle at top right, rgba(12, 39, 59, 0.72), rgba(3, 7, 10, 0.9));
  z-index: 100;
}

.confirmation-card {
  width: min(34rem, calc(100vw - 2rem));
  max-width: 34rem;

  :deep(.card-cnt) {
    background: linear-gradient(155deg, rgba(16, 27, 36, 0.95), rgba(4, 9, 15, 0.92));
    border-radius: 0.75em;
    padding: 1.1rem 1.2rem 1.2rem;
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.45);
    border: 1px solid rgba(255, 255, 255, 0.18);
    backdrop-filter: blur(0.35rem);
    overflow: hidden;
  }
}

.modal-content {
  margin: 0.75rem 0 0;

  .summary-panel {
    border: 1px solid rgba(255, 255, 255, 0.16);
    border-radius: 0.65rem;
    padding: 0.75rem;
    background: rgba(0, 0, 0, 0.25);
    margin-bottom: 0.9rem;
  }

  .summary-title {
    font-size: 0.8rem;
    letter-spacing: 0.03rem;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.62);
    margin-bottom: 0.4rem;
  }

  .summary-title-value {
    font-size: 1.25rem;
    font-weight: 800;
    margin-bottom: 0.25rem;
  }

  .summary-subtitle {
    color: rgba(255, 255, 255, 0.78);
  }

  p {
    margin: 0.25em 0;
  }

  .price-breakdown {
    margin-top: 0.8rem;
    display: flex;
    flex-direction: column;
    gap: 0.45rem;
    align-items: stretch;
    padding: 0.2rem;

    .line-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 0.94rem;
      color: rgba(255, 255, 255, 0.85);
      gap: 0.75rem;
      padding: 0.24rem 0.4rem;
      border-radius: 0.45rem;
      background: rgba(255, 255, 255, 0.03);

      span {
        font-weight: 300;
      }

      .money :deep(.info-item) {
        padding: 0;
        min-width: 0.7rem;
      }
    }

    .total {
      margin-top: 0.35rem;
      border: 1px solid rgba(255, 255, 255, 0.2);
      padding-top: 0.25rem;
      font-weight: 700;
      font-size: 1rem;
      color: white;
      background: rgba(255, 255, 255, 0.06);
    }
  }

  .funds-warning {
    margin-top: 0.7rem;
    text-align: center;
    color: #ff9b9b;
    font-weight: 600;
  }
}

.confirm-button-container {
  display: flex;
  justify-content: center;
  gap: 1em;
  margin-top: 1.05rem;

  .confirm-button,
  .cancel-button {
    min-width: 9.5rem;
  }
}

.card-heading :deep(*) {
  letter-spacing: 0.02rem;
}
</style>
