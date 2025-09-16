<template>
  <ComputerWrapper ref="wrapper" :path="[computerStore.computerData.facilityName]" title="Insurance policies" back @back="close">
    <div class="insurance-dashboard">
      <!-- Main Content -->
      <div class="dashboard-content glass-panel" v-bng-blur>
        <InsurancePoliciesList />
      </div>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { lua, useBridge } from "@/bridge"
import { onBeforeMount, onUnmounted } from "vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useInsurancePoliciesStore } from "../stores/insurancePoliciesStore"
import { vBngBlur } from "@/common/directives"
import InsurancePoliciesList from "../components/insurancePolicies/insurancePoliciesList.vue"
import { useComputerStore } from "../stores/computerStore"

const computerStore = useComputerStore()
const insurancePoliciesStore = useInsurancePoliciesStore()
const { units } = useBridge()

// Reactive data from store
const { careerMoney } = insurancePoliciesStore

const start = () => {
  insurancePoliciesStore.requestInitialData()
}

const kill = () => {
  lua.extensions.hook("onExitInsurancePoliciesList")
  //insuranceStore.partInventoryClosed()
  insurancePoliciesStore.$dispose()
}

onBeforeMount(start)
onUnmounted(kill)

const close = () => {
  insurancePoliciesStore.closeMenu()
}
</script>

<style scoped lang="scss">
.insurance-dashboard {
  height: 100%;
  max-height: calc(100vh - 2rem);
  background: rgba(var(--bng-cool-gray-900-rgb), 0.96);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: var(--bng-corners-2);
  backdrop-filter: blur(16px);
  box-shadow:
    0 0 0 1px rgba(255,255,255,0.04) inset,
    0 20px 40px rgba(0,0,0,0.6),
    0 0 20px rgba(0,0,0,0.3);
  overflow: hidden;
  position: relative;
}

.insurance-dashboard::before {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  border-radius: var(--bng-corners-2);
  z-index: 1;
}

.dashboard-header {
  background: rgba(var(--bng-cool-gray-900-rgb), 0.96);
  backdrop-filter: blur(16px);
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  position: sticky;
  top: 0;
  z-index: 102;
  box-shadow:
    0 4px 24px rgba(0,0,0,0.4),
    0 1px 0 rgba(255,255,255,0.05) inset;
  padding: 1.5rem 2rem;
  position: relative;

  &::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: linear-gradient(45deg, rgba(var(--bng-orange-rgb), 0.05) 0%, transparent 100%);
    pointer-events: none;
  }
}

.header-content {
  display: flex;
  justify-content: space-between;
  align-items: center;
  max-width: 1400px;
  margin: 0 auto;
  position: relative;
  z-index: 1;
}

.header-left {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.header-icon {
  width: 3rem;
  height: 3rem;
  background: rgba(var(--bng-orange-rgb), 0.1);
  border: 1px solid rgba(var(--bng-orange-rgb), 0.25);
  border-radius: var(--bng-corners-1);
  display: flex;
  align-items: center;
  justify-content: center;
  backdrop-filter: blur(10px);
}

.header-title {
  font-size: 2rem;
  font-weight: 700;
  color: var(--bng-off-white);
  margin: 0;
  text-shadow: 0 2px 4px rgba(0, 0, 0, 0.5);
}

.header-subtitle {
  font-size: 0.875rem;
  color: var(--bng-cool-gray-300);
  margin: 0;
  font-weight: 400;
}

.header-right {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.balance-display {
  background: rgba(var(--bng-orange-rgb), 0.1);
  border: 1px solid rgba(var(--bng-orange-rgb), 0.25);
  border-radius: var(--bng-corners-1);
  padding: 0.75rem 1rem;
  backdrop-filter: blur(10px);
  text-align: right;
  min-width: 150px;
}

.balance-label {
  font-size: 0.75rem;
  color: var(--bng-cool-gray-400);
  margin-bottom: 0.25rem;
  font-weight: 500;
}

.balance-amount {
  font-size: 1.125rem;
  font-weight: 700;
  color: var(--bng-orange);
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
}

.dashboard-content {
  position: relative;
  padding: 1.5rem;
  max-width: 1400px;
  margin: 0 auto;
  height: 100%;
  overflow-y: auto;
  background: transparent;
  border: none;
  box-shadow: none;
  z-index: 2;
  border-radius: calc(var(--bng-corners-2) - 0.25rem);
  /* allow inner sections to scroll */
}

/* Scrollbar style (match VehicleList.vue) */
.dashboard-content::-webkit-scrollbar { width: 8px; }
.dashboard-content::-webkit-scrollbar-track { background: rgba(0, 0, 0, 0.2); border-radius: 4px; }
.dashboard-content::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.1); border-radius: 4px; }
.dashboard-content::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.15); }

.dashboard-content.glass-panel::before {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(120% 80% at 10% 0%, rgba(var(--bng-orange-rgb), 0.06) 0%, rgba(var(--bng-orange-rgb), 0.02) 20%, transparent 60%),
              radial-gradient(120% 80% at 90% 0%, rgba(var(--bng-orange-rgb), 0.06) 0%, rgba(var(--bng-orange-rgb), 0.02) 20%, transparent 60%);
  border-radius: inherit;
}

/* Glass card utility classes */
.glass-card {
  background: rgba(255, 255, 255, 0.05);
  backdrop-filter: blur(20px);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: var(--bng-corners-1);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3);
  transition: all 0.3s ease;
}

.glass-card-hover:hover {
  background: rgba(255, 255, 255, 0.08);
  border-color: rgba(var(--bng-orange-rgb), 0.25);
  transform: translateY(-2px);
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.4);
}

/* Responsive design */
@media (max-width: 768px) {
  .dashboard-header {
    padding: 1rem;
  }

  .header-content {
    flex-direction: column;
    gap: 1rem;
    align-items: flex-start;
  }

  .header-right {
    width: 100%;
    justify-content: space-between;
  }

  .balance-display {
    min-width: auto;
    flex: 1;
  }

  .dashboard-content {
    padding: 1rem;
  }

  .header-title {
    font-size: 1.5rem;
  }

  .header-icon {
    width: 2.5rem;
    height: 2.5rem;
  }
}
</style>
