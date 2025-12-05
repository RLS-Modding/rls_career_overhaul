<template>
  <LayoutSingle class="purchase-layout">
    <div class="confirmation-overlay" >
        <BngCard class="confirmation-card">
          <BngCardHeading>Purchase {{ businessName }} </BngCardHeading>

          <div class="modal-content">
            <p>Purchase this business for ${{ price }}?</p>
            <p v-if="description">{{ description }}</p>
          </div>

          <div class="confirm-button-container">
            <BngButton
              ref="purchaseButton"
              @click="confirmPurchase"
              :accent="ACCENTS.primary"
              :disabled="cantPay"
            >
              Purchase
            </BngButton>
            <BngButton
              @click="showFinanceModal = true"
              :accent="ACCENTS.primary"
            >
              Finance
            </BngButton>
            <BngButton
              @click="cancelPurchase"
              :accent="ACCENTS.secondary"
            >
              Cancel
            </BngButton>
          </div>
        </BngCard>
      </div>

    <div v-if="showFinanceModal" class="confirmation-overlay finance-overlay" v-bng-blur @click.stop>
      <BngCard class="confirmation-card" @click.stop>
        <BngCardHeading>Finance {{ businessName }}</BngCardHeading>

        <div class="modal-content">
          <p>Finance this business with a down payment?</p>
          <div class="finance-details">
            <p><strong>Down Payment:</strong> <BngUnit :money="downPayment" /></p>
            <p><strong>Amount to Finance:</strong> <BngUnit :money="financedAmount" /></p>
            <p><strong>Terms:</strong> 0% interest, 6 hours (72 payments every 5 minutes)</p>
          </div>
        </div>

        <div class="confirm-button-container">
          <BngButton
            @click="confirmFinance"
            :accent="ACCENTS.primary"
            :disabled="!canAffordDownPayment"
          >
            Confirm Finance
          </BngButton>
          <BngButton
            @click="showFinanceModal = false"
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
import { ref, computed, onMounted } from 'vue'
import { lua } from '@/bridge'
import {
  BngButton,
  ACCENTS,
  BngCard,
  BngCardHeading,
  BngUnit
} from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'
import { vBngBlur } from '@/common/directives'

const purchaseButton = ref(null)
const price = ref(0)
const businessName = ref('')
const description = ref('')
const downPayment = ref(0)
const cantPay = ref(true)
const showFinanceModal = ref(false)
const canAffordDownPayment = ref(false)

const financedAmount = computed(() => {
  return Math.max(0, price.value - downPayment.value)
})

onMounted(async () => {
  const businessData = await lua.career_modules_business_businessManager.requestBusinessData()
  if (businessData) {
    price.value = businessData.price
    businessName.value = businessData.name
    description.value = businessData.description || ''
    downPayment.value = businessData.downPayment || 0
    cantPay.value = !(await lua.career_modules_business_businessManager.canPayBusiness())
    canAffordDownPayment.value = await lua.career_modules_business_businessManager.canAffordDownPayment()
  }
})

function confirmPurchase() {
  lua.career_modules_business_businessManager.buyBusiness()
  lua.career_career.closeAllMenus()
}

function cancelPurchase() {
  lua.career_modules_business_businessManager.cancelBusinessPurchase()
  lua.career_career.closeAllMenus()
}

function confirmFinance() {
  lua.career_modules_business_businessManager.financeBusiness()
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
  background: rgba(0, 0, 0, 0.5);
  z-index: 100;
}

.confirmation-card {
  :deep(.card-cnt) {
    background: rgba(0, 0, 0, 0.8);
    border-radius: 0.75em;
    padding: 1em;
    box-shadow: 0 0 20px rgba(0, 0, 0, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.15);
  }
}

.modal-content {
  text-align: center;
  margin: 0.25em 0;
  p {
    margin: 0.25em 0;
  }
}

.confirm-button-container {
  display: flex;
  justify-content: center;
  gap: 1em;
  margin-top: 0.25em;
}

.finance-overlay {
  z-index: 101;
  background: rgba(0, 0, 0, 0.85);
}

.finance-details {
  margin-top: 1em;
  text-align: left;
  p {
    margin: 0.5em 0;
  }
}
</style>

