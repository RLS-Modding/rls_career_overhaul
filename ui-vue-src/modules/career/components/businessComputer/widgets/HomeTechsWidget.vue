<template>
  <div class="home-widget techs-widget">
    <div class="widget-header">
      <h3>Technicians</h3>
      <div class="tech-count-badge" v-if="store.techs && store.techs.length">
        {{ store.techs.length }} Staff
      </div>
    </div>

    <div class="widget-content">
      <div v-if="!store.techs || store.techs.length === 0" class="empty-state">
        <div class="icon-circle">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
                <circle cx="9" cy="7" r="4"></circle>
                <path d="M23 21v-2a4 4 0 0 0-3-3.87"></path>
                <path d="M16 3.13a4 4 0 0 1 0 7.75"></path>
            </svg>
        </div>
        <p>No technicians hired</p>
        <button class="btn-link" @click="$emit('go-to-techs')" data-focusable>Hire Techs</button>
      </div>
      <div v-else class="techs-list">
        <div 
          v-for="tech in store.techs" 
          :key="tech.id" 
          class="tech-item"
          :class="{ 'working': tech.jobId }"
        >
          <div class="tech-info">
            <div class="status-dot" :class="{ active: tech.jobId }"></div>
            <span class="tech-name">{{ tech.name }}</span>
          </div>
          <div class="tech-status">
            <span v-if="tech.jobId" class="status-text working">{{ getTechStatusText(tech) }}</span>
            <span v-else class="status-text idle">Idle</span>
            <div class="progress-bar-mini" v-if="tech.jobId">
                <div class="fill" :style="{ width: `${Math.min(100, Math.round((tech.progress || 0) * 100))}%` }"></div>
            </div>
          </div>
        </div>
      </div>
      
      <div class="manager-status" v-if="hasManager">
          <div class="manager-info">
              <span class="label">Manager Status</span>
              <span class="value" :class="{ ready: managerReadyToAssign }">{{ managerStatusText }}</span>
          </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import { lua } from "@/bridge"

const store = useBusinessComputerStore()

const hasManager = computed(() => store.hasManager)
const managerReadyToAssign = computed(() => store.managerReadyToAssign)
const managerTimeRemainingFromStore = computed(() => store.managerTimeRemaining)
const localManagerTimeRemaining = ref(null)

const managerStatusText = computed(() => {
  if (managerReadyToAssign.value) {
    return "Ready"
  }
  const timeRemaining = localManagerTimeRemaining.value
  if (timeRemaining !== null && timeRemaining !== undefined && timeRemaining > 0) {
    const minutes = Math.floor(timeRemaining / 60)
    const seconds = Math.floor(timeRemaining % 60)
    if (minutes > 0) {
      return `${minutes}m ${seconds}s`
    }
    return `${seconds}s`
  }
  return "Waiting"
})

const getTechStatusText = (tech) => {
  if (!tech.jobId) return "Idle"
  
  const phaseMap = {
    baseline: "Baseline Run",
    validation: "Validation Run",
    postUpdate: "Verification",
    completed: "Completed",
    failed: "Failed",
    idle: "Idle",
    build: "Building",
    update: "Tuning",
    cooldown: "Cooling Down"
  }
  
  return tech.label || phaseMap[tech.phase] || tech.action || "Working"
}

let animationFrameId = null
let lastTime = performance.now()

const updateProgress = () => {
  const now = performance.now()
  const dt = (now - lastTime) / 1000
  lastTime = now
  
  if (localManagerTimeRemaining.value !== null && localManagerTimeRemaining.value !== undefined && localManagerTimeRemaining.value > 0) {
    localManagerTimeRemaining.value = Math.max(0, localManagerTimeRemaining.value - dt)
  }
  
  animationFrameId = requestAnimationFrame(updateProgress)
}

watch(managerTimeRemainingFromStore, (newValue) => {
  if (newValue !== null && newValue !== undefined) {
    localManagerTimeRemaining.value = newValue
  }
}, { immediate: true })

watch(managerReadyToAssign, (isReady) => {
  if (isReady) {
    localManagerTimeRemaining.value = 0
  }
})

onMounted(() => {
    lastTime = performance.now()
    updateProgress()
})

onUnmounted(() => {
    if (animationFrameId) cancelAnimationFrame(animationFrameId)
})

defineEmits(['go-to-techs'])
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1rem;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.widget-header {
  padding: 1rem 1.25rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1.1rem;
    font-weight: 600;
    color: #fff;
  }
}

.tech-count-badge {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.5);
    background: rgba(255, 255, 255, 0.1);
    padding: 0.2rem 0.5rem;
    border-radius: 0.25rem;
}

.widget-content {
  padding: 1rem;
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
}

.empty-state {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
  gap: 1rem;
  color: rgba(255, 255, 255, 0.5);
}

.icon-circle {
    width: 3rem;
    height: 3rem;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.05);
    display: flex;
    align-items: center;
    justify-content: center;
    color: rgba(255, 255, 255, 0.3);
}

.btn-link {
    background: none;
    border: none;
    color: #f97316;
    cursor: pointer;
    text-decoration: underline;
    font-size: 0.9rem;
    
    &:hover {
        color: #fff;
    }
}

.techs-list {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    flex: 1;
}

.tech-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.75rem;
    background: rgba(255, 255, 255, 0.03);
    border-radius: 0.5rem;
    border: 1px solid rgba(255, 255, 255, 0.05);
    
    &.working {
        border-left: 3px solid #f97316;
    }
}

.tech-info {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    flex-shrink: 0; /* Don't let name shrink */
}

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
    
    &.active {
        background: #f97316;
        box-shadow: 0 0 5px rgba(249, 115, 22, 0.5);
    }
}

.tech-name {
    font-weight: 500;
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.9rem;
}

.tech-status {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 0.25rem;
    flex: 1; /* Take remaining space */
    min-width: 0; /* Allow shrinking */
    padding-left: 1rem; /* Space from name */
}

.status-text {
    font-size: 0.65rem; /* Smaller text as requested */
    text-transform: uppercase;
    letter-spacing: 0.02em;
    text-align: right;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    width: 100%;
    font-weight: 600;
    
    &.working { color: #f97316; }
    &.idle { color: rgba(255, 255, 255, 0.4); }
}

.progress-bar-mini {
    width: 100%; /* Full width of container */
    height: 4px; 
    background: rgba(255, 255, 255, 0.1);
    border-radius: 2px;
    overflow: hidden;
    
    .fill {
        height: 100%;
        background: #f97316;
    }
}

.manager-status {
    margin-top: 1rem;
    padding-top: 0.75rem;
    border-top: 1px solid rgba(255, 255, 255, 0.1);
}

.manager-info {
    display: flex;
    justify-content: space-between;
    font-size: 0.8rem;
    
    .label { color: rgba(255, 255, 255, 0.5); }
    .value { 
        color: rgba(255, 255, 255, 0.9); 
        font-weight: 500;
        
        &.ready { color: #2ecc71; }
    }
}
</style>
