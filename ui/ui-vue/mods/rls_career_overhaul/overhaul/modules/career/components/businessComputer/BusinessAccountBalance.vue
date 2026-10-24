<template>
  <!-- inline: a line under the career status chip (workshop views), instead of the floating box -->
  <div class="rls-house business-account-balance" :class="{ inline }">
    <div class="balance-content">
      <span class="balance-label">Business account</span>
      <span class="balance-value">{{ balance < 0 ? "-" : "" }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formattedBalance }}</span>
      <span class="xp-value" v-if="xp !== null">
        {{ xp }} <span class="xp-label">XP</span>
      </span>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount, watch } from "vue"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { lua } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { useEvents } from "@/services/events"

defineProps({ inline: Boolean })

const sessionStore = useBusinessSessionStore()
const events = useEvents()

const balance = ref(0)
const xp = ref(0)

const formattedBalance = computed(() => {
  // sign is rendered before the currency glyph
  return Math.abs(balance.value).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  })
})

const loadBalance = async () => {
  if (!sessionStore.businessType || !sessionStore.businessId) {
    balance.value = 0
    return
  }
  
  try {
    const accountBalance = await lua.overhaul_career_business_computer.getBusinessAccountBalance(
      sessionStore.businessType,
      sessionStore.businessId
    )
    balance.value = accountBalance || 0
    
    const businessXP = await lua.overhaul_career_business_computer.getBusinessXP(
      sessionStore.businessType,
      sessionStore.businessId
    )
    xp.value = businessXP || 0
  } catch (error) {
    balance.value = 0
    xp.value = 0
  }
}

const handleAccountUpdate = async (data) => {
  if (!data || !sessionStore.businessType || !sessionStore.businessId) return
  
  const accountId = "business_" + sessionStore.businessType + "_" + sessionStore.businessId
  
  if (data.accountId === accountId) {
    balance.value = data.balance || 0
    
    try {
      const businessXP = await lua.overhaul_career_business_computer.getBusinessXP(
        sessionStore.businessType,
        sessionStore.businessId
      )
      xp.value = businessXP || 0
    } catch (error) {
      xp.value = 0
    }
  }
}

watch([() => sessionStore.businessType, () => sessionStore.businessId], () => {
  loadBalance()
}, { immediate: true })

onMounted(() => {
  events.on('bank:onOverhaulAccountUpdate', handleAccountUpdate)
  loadBalance()
})

onBeforeUnmount(() => {
  events.off('bank:onOverhaulAccountUpdate', handleAccountUpdate)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Floating Business Account box: near-black house card, caption label, balance in gold. */
.business-account-balance {
  position: fixed;
  top: 2em;
  right: 2em;
  z-index: 2000;
  min-width: 12em;
  padding: 0.85em 1.1em 0.75em;
  border-radius: var(--radius-control);
  background: rgba(21, 21, 23, 0.94);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 0.5em 1.5em rgba(0, 0, 0, 0.45);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);

  .balance-content {
    display: grid;
    gap: 0.2em;
  }

  .balance-label {
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }

  .balance-value {
    font-size: 1.45em;
    font-weight: 800;
    line-height: 1.15;
    color: var(--money);
    font-variant-numeric: tabular-nums;
  }

  .xp-value {
    display: flex;
    align-items: baseline;
    gap: 0.3em;
    color: var(--muted);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }

  .xp-label {
    font-size: 0.75em;
    font-weight: 700;
    letter-spacing: 0.06em;
    color: var(--faint);
  }
}

/* inline: one line inside the workshop header; inherits that view's font size */
.business-account-balance.inline {
  position: static;
  min-width: 0;
  padding: 0;
  background: transparent;
  box-shadow: none;
  border-radius: 0;
  font-size: inherit;

  .balance-content {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    justify-content: center;
    gap: 0.5em;
  }

  .balance-label {
    font-size: 0.78em;
  }

  .balance-value {
    font-size: 1em;
  }

  .xp-value {
    font-size: 0.9em;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
