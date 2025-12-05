<template>
  <div class="business-account-balance">
    <div class="balance-content">
      <div class="balance-label">Business Account</div>
      <div class="balance-value">${{ formattedBalance }}</div>
      <div class="xp-value" v-if="xp !== null">
        {{ xp }} <span class="xp-label">XP</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"

const store = useBusinessComputerStore()
const events = useEvents()

const balance = ref(0)
const xp = ref(0)

const formattedBalance = computed(() => {
  return balance.value.toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  })
})

const loadBalance = async () => {
  if (!store.businessType || !store.businessId) {
    balance.value = 0
    return
  }
  
  try {
    const accountBalance = await lua.career_modules_business_businessComputer.getBusinessAccountBalance(
      store.businessType,
      store.businessId
    )
    balance.value = accountBalance || 0
    
    const businessXP = await lua.career_modules_business_businessComputer.getBusinessXP(
      store.businessType,
      store.businessId
    )
    xp.value = businessXP || 0
  } catch (error) {
    balance.value = 0
    xp.value = 0
  }
}

const handleAccountUpdate = async (data) => {
  if (!data || !store.businessType || !store.businessId) return
  
  const accountId = "business_" + store.businessType + "_" + store.businessId
  
  if (data.accountId === accountId) {
    balance.value = data.balance || 0
    
    try {
      const businessXP = await lua.career_modules_business_businessComputer.getBusinessXP(
        store.businessType,
        store.businessId
      )
      xp.value = businessXP || 0
    } catch (error) {
      xp.value = 0
    }
  }
}

watch([() => store.businessType, () => store.businessId], () => {
  loadBalance()
}, { immediate: true })

onMounted(() => {
  events.on('bank:onAccountUpdate', handleAccountUpdate)
  loadBalance()
})

onBeforeUnmount(() => {
  events.off('bank:onAccountUpdate', handleAccountUpdate)
})
</script>

<style scoped lang="scss">
.business-account-balance {
  position: fixed;
  top: 2em;
  right: 2em;
  z-index: 2000;
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.4);
  border-radius: 0.5em;
  padding: 1em 1.5em;
  min-width: 12em;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
  
  .balance-content {
    display: flex;
    flex-direction: column;
    gap: 0.25em;
    
    .balance-label {
      font-size: 0.75em;
      color: rgba(255, 255, 255, 0.6);
      text-transform: uppercase;
      letter-spacing: 0.05em;
      font-weight: 500;
    }
    
    .balance-value {
      font-size: 1.5em;
      color: rgba(245, 73, 0, 1);
      font-weight: 600;
      font-family: 'Courier New', monospace;
    }
    
    .xp-value {
      font-size: 1em;
      color: rgba(245, 73, 0, 1);
      font-weight: 600;
      font-family: 'Courier New', monospace;
      display: flex;
      align-items: center;
      align-self: flex-end;
      gap: 0.25em;
      
      .xp-label {
        font-size: 0.75em;
        color: rgba(255, 255, 255, 0.6);
        text-transform: uppercase;
        letter-spacing: 0.05em;
        font-weight: 500;
      }
    }
  }
}
</style>

