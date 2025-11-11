<template>
  <div class="business-computer-wrapper">
    <BngCard v-if="!store.loading" class="business-computer-container" :class="{ 'vehicle-view': store.vehicleView === 'parts' || store.vehicleView === 'tuning', 'collapsed': isVehicleViewCollapsed && (store.vehicleView === 'parts' || store.vehicleView === 'tuning') }" v-bng-blur>
      <div class="main-header" :class="{ 'collapsed': isVehicleViewCollapsed && (store.vehicleView === 'parts' || store.vehicleView === 'tuning') }">
        <h1>{{ store.vehicleView === 'parts' ? 'Parts Customization' : store.vehicleView === 'tuning' ? 'Tuning' : store.businessName }}</h1>
        <div class="header-actions">
          <button 
            v-if="store.vehicleView === 'parts' || store.vehicleView === 'tuning'"
            class="collapse-toggle-vehicle"
            @click="isVehicleViewCollapsed = !isVehicleViewCollapsed"
          >
            <svg v-if="isVehicleViewCollapsed" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="18 15 12 9 6 15"/>
            </svg>
            <svg v-else width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="6 9 12 15 18 9"/>
            </svg>
          </button>
          <button class="close-button" @click="close">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="18" y1="6" x2="6" y2="18"/>
              <line x1="6" y1="6" x2="18" y2="18"/>
            </svg>
          </button>
        </div>
      </div>
      
      <div class="content-layout" :class="{ 'vehicle-view': store.vehicleView === 'parts' || store.vehicleView === 'tuning' }">
        <aside v-if="store.vehicleView !== 'parts' && store.vehicleView !== 'tuning'" :class="['sidebar', { collapsed: isCollapsed }]">
          <div class="sidebar-header">
            <button class="collapse-toggle" @click="isCollapsed = !isCollapsed">
              <svg v-if="isCollapsed" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M9 18l6-6-6-6"/>
              </svg>
              <svg v-else width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M15 18l-6-6 6-6"/>
              </svg>
            </button>
          </div>
          
          <nav class="sidebar-nav">
            <div class="nav-section">
              <div class="nav-section-title">{{ isCollapsed ? 'B' : 'BASIC' }}</div>
              <ul class="nav-list">
                <li>
                  <button 
                    :class="['nav-item', { active: store.activeView === 'home' }]"
                    @click="store.switchView('home')"
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>
                      <polyline points="9 22 9 12 15 12 15 22"/>
                    </svg>
                    <span v-if="!isCollapsed">Home</span>
                  </button>
                </li>
                <li>
                  <button 
                    :class="['nav-item', { active: store.activeView === 'active-jobs' }]"
                    @click="store.switchView('active-jobs')"
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
                      <polyline points="22 4 12 14.01 9 11.01"/>
                    </svg>
                    <span v-if="!isCollapsed">Active Jobs</span>
                  </button>
                </li>
                <li>
                  <button 
                    :class="['nav-item', { active: store.activeView === 'new-jobs' }]"
                    @click="store.switchView('new-jobs')"
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/>
                      <polyline points="14 2 14 8 20 8"/>
                      <line x1="16" y1="13" x2="8" y2="13"/>
                      <line x1="16" y1="17" x2="8" y2="17"/>
                      <polyline points="10 9 9 9 8 9"/>
                    </svg>
                    <span v-if="!isCollapsed">New Jobs</span>
                  </button>
                </li>
                <li>
                  <button 
                    :class="['nav-item', { active: store.activeView === 'inventory' }]"
                    @click="store.switchView('inventory')"
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M16.5 9.4l-9-5.19M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
                      <polyline points="3.27 6.96 12 12.01 20.73 6.96"/>
                      <line x1="12" y1="22.08" x2="12" y2="12"/>
                    </svg>
                    <span v-if="!isCollapsed">Inventory</span>
                  </button>
                </li>
              </ul>
            </div>
            
            <div v-if="store.pulledOutVehicle" class="nav-section">
              <div class="nav-section-title">{{ isCollapsed ? 'V' : 'VEHICLE' }}</div>
              <ul class="nav-list">
                <li>
                  <button 
                    :class="['nav-item', { active: store.vehicleView === 'tuning' }]"
                    @click="store.switchVehicleView('tuning')"
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <circle cx="12" cy="12" r="3"/>
                      <path d="M12 1v6m0 6v6M5.64 5.64l4.24 4.24m4.24 4.24l4.24 4.24M1 12h6m6 0h6M5.64 18.36l4.24-4.24m4.24-4.24l4.24-4.24"/>
                    </svg>
                    <span v-if="!isCollapsed">Tuning</span>
                  </button>
                </li>
                <li>
                  <button 
                    :class="['nav-item', { active: store.vehicleView === 'parts' }]"
                    @click="store.switchVehicleView('parts')"
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
                    </svg>
                    <span v-if="!isCollapsed">Parts</span>
                  </button>
                </li>
              </ul>
            </div>
          </nav>
        </aside>

        <main v-if="!store.vehicleView" class="main-content">
          <div class="content-body">
            <BusinessHomeView v-if="store.activeView === 'home'" />
            <BusinessActiveJobsTab v-else-if="store.activeView === 'active-jobs'" />
            <BusinessNewJobsTab v-else-if="store.activeView === 'new-jobs'" />
            <BusinessInventoryTab v-else-if="store.activeView === 'inventory'" />
            <BusinessPartsInventoryTab v-else-if="store.activeView === 'parts-inventory'" />
          </div>
        </main>

        <div v-if="store.vehicleView === 'parts' && store.pulledOutVehicle && !isVehicleViewCollapsed" class="parts-panel">
          <div class="content-body">
            <BusinessPartsCustomizationTab />
          </div>
        </div>

        <div v-else-if="store.vehicleView === 'tuning' && store.pulledOutVehicle && !isVehicleViewCollapsed" class="tuning-panel">
          <div class="content-body">
            <BusinessTuningTab />
          </div>
        </div>
      </div>
    </BngCard>
    
    <div v-else class="loading">
      Loading...
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from "vue"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import BusinessHomeView from "../components/businessComputer/BusinessHomeView.vue"
import BusinessActiveJobsTab from "../components/businessComputer/BusinessActiveJobsTab.vue"
import BusinessNewJobsTab from "../components/businessComputer/BusinessNewJobsTab.vue"
import BusinessInventoryTab from "../components/businessComputer/BusinessInventoryTab.vue"
import BusinessPartsInventoryTab from "../components/businessComputer/BusinessPartsInventoryTab.vue"
import BusinessTuningTab from "../components/businessComputer/BusinessTuningTab.vue"
import BusinessPartsCustomizationTab from "../components/businessComputer/BusinessPartsCustomizationTab.vue"
import { lua } from "@/bridge"
import { BngCard } from "@/common/components/base"
import { vBngBlur } from "@/common/directives"

const props = defineProps({
  businessType: String,
  businessId: String
})

const store = useBusinessComputerStore()
const isCollapsed = ref(false)
const isVehicleViewCollapsed = ref(false)

const close = () => {
  // If we're in parts or tuning view, go back to home instead of closing
  if (store.vehicleView === 'parts' || store.vehicleView === 'tuning') {
    store.switchView('home')
    store.clearVehicleView()
  } else {
    store.onMenuClosed()
    lua.career_career.closeAllMenus()
  }
}

const start = async () => {
  if (props.businessType && props.businessId) {
    await store.loadBusinessData(props.businessType, props.businessId)
  }
}

const kill = () => {
  store.onMenuClosed()
}

onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
.business-computer-wrapper {
  position: fixed;
  bottom: 2em;
  left: 2em;
  width: auto;
  height: auto;
  max-width: calc(100vw - 4em);
  max-height: calc(85vh - 2em);
  display: flex;
  flex-direction: column;
  background: transparent;
  padding: 0;
  overflow: hidden;
  z-index: 1000;
}

.business-computer-container {
  display: flex;
  flex-direction: column;
  width: 60em;
  height: 85vh;
  background: rgba(15, 15, 15, 0.85);
  border: 2px solid rgba(245, 73, 0, 0.4);
  border-radius: 0.5em;
  overflow: hidden;
  transition: width 0.3s, transform 0.3s ease, bottom 0.3s ease;
  
  &.vehicle-view {
    width: 30em;
    
    &.collapsed {
      position: fixed;
      bottom: 0;
      left: 2em;
      height: auto;
      width: 30em;
      transform: translateY(0);
    }
  }
}

.main-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1em 1.5em;
  border-bottom: 2px solid rgba(245, 73, 0, 0.4);
  background: transparent;
  flex-shrink: 0;
  transition: all 0.3s ease;
  
  &.collapsed {
    border-bottom: none;
    border-top: 2px solid rgba(245, 73, 0, 0.4);
    border-radius: 0.5em 0.5em 0 0;
  }
  
  h1 {
    margin: 0;
    color: white;
    font-size: 1.5em;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 0.75em;
    
    &::before {
      content: '';
      width: 0.25em;
      height: 2em;
      background: #F54900;
      border-radius: 0.125em;
    }
  }
  
  .header-actions {
    display: flex;
    align-items: center;
    gap: 0.5em;
  }
  
  .collapse-toggle-vehicle {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 2em;
    height: 2em;
    padding: 0;
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.6);
    cursor: pointer;
    border-radius: 0.25em;
    transition: all 0.2s;
    
    &:hover {
      color: #F54900;
      background: rgba(255, 255, 255, 0.05);
    }
    
    svg {
      width: 20px;
      height: 20px;
    }
  }
}

.content-layout {
  display: flex;
  flex: 1;
  gap: 0;
  padding: 0;
  overflow: hidden;
  min-height: 0;
  
  &.vehicle-view {
    .main-content,
    .parts-panel,
    .tuning-panel {
      width: 100%;
    }
  }
}

.sidebar {
  width: 14em;
  background: transparent;
  border: none;
  border-right: 2px solid rgba(245, 73, 0, 0.4);
  border-radius: 0;
  display: flex;
  flex-direction: column;
  transition: width 0.3s;
  flex-shrink: 0;
  
  &.collapsed {
    width: 4em;
  }
}

.sidebar-header {
  border-bottom: 1px solid rgba(245, 73, 0, 0.3);
  padding: 0;
}

.collapse-toggle {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0.75em;
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.6);
  cursor: pointer;
  transition: color 0.2s;
  
  &:hover {
    color: #F54900;
    background: rgba(255, 255, 255, 0.05);
  }
  
  svg {
    flex-shrink: 0;
  }
}

.sidebar-nav {
  flex: 1;
  overflow-y: auto;
  
  /* Custom scrollbar */
  &::-webkit-scrollbar {
    width: 8px;
  }
  
  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;
  }
  
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 4px;
    
    &:hover {
      background: rgba(255, 255, 255, 0.15);
    }
  }
}

.nav-section {
  margin-bottom: 1em;
}

.nav-section-title {
  padding: 0.5em 0.75em;
  font-size: 0.75em;
  color: #F54900;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  text-align: center;
  font-weight: 600;
  letter-spacing: 0.05em;
}

.nav-list {
  list-style: none;
  padding: 0;
  margin: 0;
}

.nav-item {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 0.75em;
  padding: 0.75em;
  background: transparent;
  border: none;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  color: rgba(255, 255, 255, 0.9);
  cursor: pointer;
  transition: all 0.2s;
  text-align: left;
  font-size: 0.875em;
  
  svg {
    flex-shrink: 0;
    width: 20px;
    height: 20px;
  }
  
  &:hover {
    background: rgba(255, 255, 255, 0.05);
    color: #F54900;
  }
  
  &.active {
    background: #F54900;
    color: #FFFFFF;
    box-shadow: 0 0 10px rgba(245, 73, 0, 0.2);
  }
}

.sidebar.collapsed .nav-item {
  justify-content: center;
  gap: 0;
}

.main-content,
.vehicle-panel,
.parts-panel,
.tuning-panel {
  flex: 1;
  background: transparent;
  border: none;
  border-radius: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  min-height: 0;
}

.vehicle-panel {
  max-width: 28em;
  flex-shrink: 0;
}

.parts-panel,
.tuning-panel {
  width: 100%;
}

.close-button {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 2em;
  height: 2em;
  padding: 0;
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.6);
  cursor: pointer;
  border-radius: 0.25em;
  transition: all 0.2s;
  
  &:hover {
    color: #F54900;
    background: rgba(255, 255, 255, 0.05);
  }
  
  svg {
    width: 20px;
    height: 20px;
  }
}

.content-body {
  flex: 1;
  overflow-y: auto;
  padding: 1.5em;
  background: transparent;
  
  /* Custom scrollbar */
  &::-webkit-scrollbar {
    width: 8px;
  }
  
  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;
  }
  
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 4px;
    
    &:hover {
      background: rgba(255, 255, 255, 0.15);
    }
  }
}

.loading {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
  color: white;
  font-size: 1.5em;
}
</style>

