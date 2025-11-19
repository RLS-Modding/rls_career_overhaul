<template>
  <div class="business-computer-wrapper">
    <BusinessAccountBalance v-if="!store.loading && store.businessId && store.businessType" />
    <BusinessShoppingCart v-if="!store.loading && (store.vehicleView === 'parts' || store.vehicleView === 'tuning')" :key="store.pulledOutVehicle?.vehicleId || 'no-vehicle'" />
    <!-- Confirmation Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showConfirmModal" class="modal-overlay" @click.self="cancelClose">
          <div class="modal-content">
            <h2>Confirm Exit</h2>
            <p>Are you sure you want to leave this view? You will be losing progress.</p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" @click="cancelClose">Cancel</button>
              <button class="btn btn-primary" @click="confirmClose">Yes, Leave</button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
    
    <BngCard v-if="!store.loading" class="business-computer-container" :class="{ 'vehicle-view': store.vehicleView === 'parts' || store.vehicleView === 'tuning', 'collapsed': isVehicleViewCollapsed && (store.vehicleView === 'parts' || store.vehicleView === 'tuning'), 'vehicle-sidebar-expanded': !isVehicleSidebarCollapsed && (store.vehicleView === 'parts' || store.vehicleView === 'tuning') }" v-bng-blur ref="containerRef">
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
        <aside v-if="store.vehicleView === 'parts' || store.vehicleView === 'tuning'" :class="['vehicle-sidebar', { collapsed: isVehicleSidebarCollapsed }]">
          <div class="sidebar-header">
            <button class="collapse-toggle" @click="isVehicleSidebarCollapsed = !isVehicleSidebarCollapsed">
              <svg v-if="isVehicleSidebarCollapsed" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M9 18l6-6-6-6"/>
              </svg>
              <svg v-else width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M15 18l-6-6 6-6"/>
              </svg>
            </button>
          </div>
          
          <nav class="sidebar-nav">
            <div class="nav-section">
              <div class="nav-section-title">{{ isVehicleSidebarCollapsed ? 'V' : 'VEHICLE' }}</div>
              <ul class="nav-list">
                <li>
                  <button 
                    :class="['nav-item', { active: store.vehicleView === 'parts', disabled: store.isDamageLocked }]"
                    :disabled="store.isDamageLocked"
                    @click="store.switchVehicleView('parts')"
                    @mousedown.stop
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
                    </svg>
                    <span v-if="!isVehicleSidebarCollapsed">Parts</span>
                  </button>
                </li>
                <li>
                  <button 
                    :class="['nav-item', { active: store.vehicleView === 'tuning', disabled: store.isDamageLocked }]"
                    :disabled="store.isDamageLocked"
                    @click="store.switchVehicleView('tuning')"
                    @mousedown.stop
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <circle cx="12" cy="12" r="3"/>
                      <path d="M12 1v6m0 6v6M5.64 5.64l4.24 4.24m4.24 4.24l4.24 4.24M1 12h6m6 0h6M5.64 18.36l4.24-4.24m4.24-4.24l4.24-4.24"/>
                    </svg>
                    <span v-if="!isVehicleSidebarCollapsed">Tuning</span>
                  </button>
                </li>
              </ul>
            </div>
          </nav>
        </aside>
        
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
            <div v-for="(tabs, section) in store.tabsBySection" :key="section" class="nav-section">
              <div class="nav-section-title">{{ isCollapsed ? section.charAt(0) : section }}</div>
              <ul class="nav-list">
                <li v-for="tab in tabs" :key="tab.id">
                  <button 
                    :class="['nav-item', { active: store.activeView === tab.id }]"
                    @click.stop="store.switchView(tab.id)"
                    @mousedown.stop
                  >
                    <svg v-if="tab.icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" v-html="tab.icon"></svg>
                    <span v-if="!isCollapsed">{{ tab.label }}</span>
                  </button>
                </li>
              </ul>
            </div>
            
            <div v-if="store.pulledOutVehicle" class="nav-section">
              <div class="nav-section-title">{{ isCollapsed ? 'V' : 'VEHICLE' }}</div>
              <ul class="nav-list">
                <li>
                  <button 
                    :class="['nav-item', { active: store.vehicleView === 'parts', disabled: store.isDamageLocked }]"
                    :disabled="store.isDamageLocked"
                    @click="store.switchVehicleView('parts')"
                    @mousedown.stop
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
                    </svg>
                    <span v-if="!isCollapsed">Parts</span>
                  </button>
                </li>
                <li>
                  <button 
                    :class="['nav-item', { active: store.vehicleView === 'tuning', disabled: store.isDamageLocked }]"
                    :disabled="store.isDamageLocked"
                    @click="store.switchVehicleView('tuning')"
                    @mousedown.stop
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <circle cx="12" cy="12" r="3"/>
                      <path d="M12 1v6m0 6v6M5.64 5.64l4.24 4.24m4.24 4.24l4.24 4.24M1 12h6m6 0h6M5.64 18.36l4.24-4.24m4.24-4.24l4.24-4.24"/>
                    </svg>
                    <span v-if="!isCollapsed">Tuning</span>
                  </button>
                </li>
              </ul>
            </div>
          </nav>
        </aside>

        <main v-if="!store.vehicleView" class="main-content">
          <div class="content-body">
            <component 
              :is="activeTabComponent" 
              v-if="activeTabComponent"
              :data="activeTabData"
            />
          </div>
        </main>

        <transition name="panel-collapse">
          <div v-if="store.vehicleView === 'parts' && store.pulledOutVehicle && !isVehicleViewCollapsed" class="parts-panel">
            <div class="content-body">
              <BusinessPartsCustomizationTab />
            </div>
          </div>
        </transition>

        <transition name="panel-collapse">
          <div v-if="store.vehicleView === 'tuning' && store.pulledOutVehicle && !isVehicleViewCollapsed" class="tuning-panel">
            <div class="content-body">
              <BusinessTuningTab />
            </div>
          </div>
        </transition>
      </div>
    </BngCard>
    
    <div v-else class="loading">
      Loading...
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, watch, nextTick, Teleport, computed } from "vue"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import BusinessHomeView from "../components/businessComputer/BusinessHomeView.vue"
import BusinessActiveJobsTab from "../components/businessComputer/BusinessActiveJobsTab.vue"
import BusinessNewJobsTab from "../components/businessComputer/BusinessNewJobsTab.vue"
import BusinessInventoryTab from "../components/businessComputer/BusinessInventoryTab.vue"
import BusinessPartsInventoryTab from "../components/businessComputer/BusinessPartsInventoryTab.vue"
import BusinessTuningTab from "../components/businessComputer/BusinessTuningTab.vue"
import BusinessPartsCustomizationTab from "../components/businessComputer/BusinessPartsCustomizationTab.vue"
import BusinessAccountBalance from "../components/businessComputer/BusinessAccountBalance.vue"
import BusinessShoppingCart from "../components/businessComputer/BusinessShoppingCart.vue"
import { getTabComponent } from "../components/businessComputer/tabComponents"
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
const isVehicleSidebarCollapsed = ref(true)
const containerRef = ref(null)

const activeTab = computed(() => {
  return store.registeredTabs.find(tab => tab.id === store.activeView) || null
})

const activeTabComponent = computed(() => {
  if (!activeTab.value) {
    return null
  }
  const component = getTabComponent(activeTab.value.component)
  return component
})

const activeTabData = computed(() => {
  if (!activeTab.value) return null
  return {
    ...activeTab.value.data,
    businessId: store.businessId,
    businessType: store.businessType
  }
})

watch(() => store.registeredTabs, (tabs) => {
  if (tabs.length > 0 && store.activeView === 'home' && !tabs.find(t => t.id === 'home')) {
    store.switchView(tabs[0].id)
  }
}, { immediate: true })

watch(() => store.vehicleView, (newView) => {
  if (!newView || (newView !== 'parts' && newView !== 'tuning')) {
    isVehicleViewCollapsed.value = false
    isVehicleSidebarCollapsed.value = true
  }
})

watch(() => isVehicleViewCollapsed.value, async (collapsed) => {
  if (!containerRef.value || !store.vehicleView) return
  
  const container = containerRef.value.$el || containerRef.value
  const header = container.querySelector('.main-header')
  if (!header) return
  
  const headerHeight = header.offsetHeight
  const fullHeight = window.innerHeight * 0.85
  
  if (collapsed) {
    container.style.height = fullHeight + 'px'
    container.style.transition = 'height 0.4s ease'
    await nextTick()
    requestAnimationFrame(() => {
      container.style.height = headerHeight + 'px'
    })
  } else {
    container.style.height = headerHeight + 'px'
    container.style.transition = 'height 0.6s ease'
    await nextTick()
    requestAnimationFrame(() => {
      container.style.height = fullHeight + 'px'
      setTimeout(() => {
        container.style.height = ''
        container.style.transition = ''
      }, 600)
    })
  }
})

const showConfirmModal = ref(false)
const wasInVehicleView = ref(false)

const close = async () => {
  // Check if we're in parts/tuning view and have items in cart
  if ((store.vehicleView === 'parts' || store.vehicleView === 'tuning') && 
      (store.partsCart.length > 0 || store.tuningCart.length > 0)) {
    // Show confirmation modal
    showConfirmModal.value = true
    return
  }
  
  // No items in cart, proceed with close
  await performClose()
}

const confirmClose = async () => {
  showConfirmModal.value = false
  
  // Track if we were in a vehicle view
  const wasVehicleView = store.vehicleView === 'parts' || store.vehicleView === 'tuning'
  wasInVehicleView.value = wasVehicleView
  
  // Reset vehicle and clear cart (closeVehicleView handles this)
  if (wasVehicleView) {
    await store.closeVehicleView()
  }
  
  // Continue with close animation logic
  await performClose()
}

const cancelClose = () => {
  showConfirmModal.value = false
}

const performClose = async () => {
  // If we were in parts or tuning view (or still are), switch to home and animate expansion
  if (wasInVehicleView.value || store.vehicleView === 'parts' || store.vehicleView === 'tuning') {
    if (containerRef.value) {
      const container = containerRef.value.$el || containerRef.value
      const header = container.querySelector('.main-header')
      if (!header) {
        // Fallback if no header
        store.switchView('home')
        // Note: closeVehicleView was already called in confirmClose if needed
        isVehicleViewCollapsed.value = false
        return
      }
      
      const headerHeight = header.offsetHeight
      const wasCollapsed = isVehicleViewCollapsed.value
      const currentHeight = wasCollapsed ? headerHeight : container.offsetHeight
      const currentWidth = container.offsetWidth
      const fullHeight = window.innerHeight * 0.85
      const computedStyle = getComputedStyle(container)
      const fontSize = parseFloat(computedStyle.fontSize) || 16
      const fullWidth = 60 * fontSize // 60em in pixels
      
      // Capture current position if collapsed
      const wasFixed = wasCollapsed && getComputedStyle(container).position === 'fixed'
      const currentBottom = wasCollapsed ? '0' : ''
      const currentLeft = wasCollapsed ? '2em' : ''
      
      // Set initial state BEFORE switching views to prevent reset
      if (wasCollapsed) {
        container.style.position = 'fixed'
        container.style.bottom = currentBottom
        container.style.left = currentLeft
      }
      container.style.width = currentWidth + 'px'
      container.style.height = currentHeight + 'px'
      container.style.transition = 'none'
      container.style.transform = 'none'
      
      // Switch views immediately so header shows "Tuning Shop"
      store.switchView('home')
      // Note: closeVehicleView was already called in confirmClose if needed
      
      // Reset collapse state
      isVehicleViewCollapsed.value = false
      
      // Wait for DOM update
      await nextTick()
      
      // Re-apply styles after view switch (in case they were reset)
      if (wasCollapsed) {
        container.style.position = 'fixed'
        container.style.bottom = currentBottom
        container.style.left = currentLeft
      }
      container.style.width = currentWidth + 'px'
      container.style.height = currentHeight + 'px'
      container.style.transition = 'none'
      
      // Force a reflow
      container.offsetHeight
      
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          // Now set transition and animate
          container.style.transition = 'width 0.6s ease, height 0.6s ease'
          container.style.width = fullWidth + 'px'
          container.style.height = fullHeight + 'px'
          
          // Clean up after animation completes
          setTimeout(() => {
            container.style.width = ''
            container.style.height = ''
            container.style.position = ''
            container.style.bottom = ''
            container.style.left = ''
            container.style.transition = ''
            container.style.transform = ''
            wasInVehicleView.value = false
          }, 600)
        })
      })
      return
    }
    
    // Fallback if no container ref
    store.switchView('home')
    // Note: closeVehicleView was already called in confirmClose if needed
    isVehicleViewCollapsed.value = false
    wasInVehicleView.value = false
  } else {
    // Reset collapse state immediately and reset container height
    isVehicleViewCollapsed.value = false
    
    if (containerRef.value) {
      const container = containerRef.value.$el || containerRef.value
      container.style.height = ''
      container.style.transition = ''
    }
    
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
  transition: width 0.4s ease, transform 0.4s ease, bottom 0.4s ease;
  
  &.vehicle-view {
    width: 32em;
    transition: width 0.3s ease;
    
    &.collapsed {
      position: fixed;
      bottom: 0;
      left: 2em;
      height: auto;
      width: 32em;
      transform: translateY(0);
    }
    
    &.vehicle-sidebar-expanded {
      width: 42em;
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
  transition: all 0.4s ease;
  
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

.vehicle-sidebar {
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

  &.disabled {
    opacity: 0.4;
    cursor: not-allowed;
    pointer-events: none;
  }
}

.sidebar.collapsed .nav-item,
.vehicle-sidebar.collapsed .nav-item {
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
  display: flex;
  flex-direction: column;
  overflow: hidden;
  flex-shrink: 0;
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

.panel-collapse-enter-active,
.panel-collapse-leave-active {
  transition: opacity 0.2s ease;
}

.panel-collapse-enter-from,
.panel-collapse-leave-to {
  opacity: 0;
}

.panel-collapse-enter-to,
.panel-collapse-leave-from {
  opacity: 1;
}

.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  backdrop-filter: blur(4px);
}

.modal-content {
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.5em;
  padding: 2em;
  max-width: 30em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  
  h2 {
    margin: 0 0 1em 0;
    color: white;
    font-size: 1.5em;
    font-weight: 600;
  }
  
  p {
    margin: 0 0 2em 0;
    color: rgba(255, 255, 255, 0.8);
    font-size: 1em;
    line-height: 1.5;
  }
  
  .modal-buttons {
    display: flex;
    gap: 1em;
    justify-content: flex-end;
  }
  
  .btn {
    padding: 0.75em 1.5em;
    border: none;
    border-radius: 0.25em;
    font-size: 0.875em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
    
    &.btn-secondary {
      background: rgba(255, 255, 255, 0.1);
      color: rgba(255, 255, 255, 0.9);
      
      &:hover {
        background: rgba(255, 255, 255, 0.15);
      }
    }
    
    &.btn-primary {
      background: #F54900;
      color: white;
      
      &:hover {
        background: #ff5a14;
        box-shadow: 0 0 10px rgba(245, 73, 0, 0.4);
      }
    }
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;
  
  .modal-content {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
  
  .modal-content {
    transform: scale(0.95);
    opacity: 0;
  }
}
</style>

