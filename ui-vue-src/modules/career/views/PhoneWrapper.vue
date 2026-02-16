<template>
  <div 
    ref="phoneRef"
    class="phone-wrapper" 
    :class="{ 'phone-entered': isEntered }"
    :style="wrapperStyle">
    <div class="phone-bevel"></div>
    <div class="phone-screen">
      <!-- Status Bar -->
      <div class="phone-status-bar">
        <div class="status-bar-cell status-bar-left">
          <button class="status-back" v-bng-on-ui-nav:back,menu.asMouse @click="back">
            <span class="status-back-icon" aria-hidden="true">
              <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor"><path d="M8 2L4 6l4 4" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>
            </span>
            <span class="status-time">{{ timeParts.main }}<span class="status-time-period" v-if="timeParts.period">{{ timeParts.period }}</span></span>
          </button>
        </div>
        <div class="status-bar-cell status-bar-center">
          <div class="dynamic-island">
            <span v-if="appName" class="dynamic-island-label">{{ appName }}</span>
          </div>
        </div>
        <div class="status-bar-cell status-bar-right" v-if="cashDisplay">
          <div class="status-right-pill">
            <span class="status-cash">{{ cashDisplay }}</span>
          </div>
        </div>
      </div>
      
      <!-- Optional Header Slot -->
      <template v-if="$slots.header">
        <slot name="header"></slot>
      </template>
      
      <!-- Main Content -->
      <div class="phone-content" :class="{ 'content-fade-in': contentFadeIn }">
        <slot></slot>
      </div>
    </div>
  </div>
</template>

<script setup>
import { useEvents } from '@/services/events'
import { ref, onMounted, onUnmounted, nextTick, computed } from 'vue'
import { vBngOnUiNav } from "@/common/directives"
import { useRouter, useRoute, onBeforeRouteUpdate, onBeforeRouteLeave } from 'vue-router'
import { lua } from "@/bridge"
import { usePhoneSettings, getPhoneScale } from '../composables/usePhoneSettings'

function formatCash(m) {
  if (m == null || typeof m !== 'number') return '$0'
  if (m >= 1e12) return `$${(m / 1e12).toFixed(1)}T`
  if (m >= 1e9) return `$${(m / 1e9).toFixed(1)}B`
  if (m >= 1e6) return `$${(m / 1e6).toFixed(1)}M`
  if (m >= 1000) return `$${Math.round(m).toLocaleString()}`
  return `$${Math.round(m)}`
}

const props = defineProps({
  scale: {
    type: Number,
    default: null
  },
  appName: {
    type: String,
    default: ''
  },
  customBack: {
    type: Function
  }
})

const PHONE_TIME_KEY = 'phone_last_time'
const PHONE_MONEY_KEY = 'phone_last_money'
const PHONE_IS_CAREER_KEY = 'phone_is_career'
const { phoneSettings } = usePhoneSettings()
const events = useEvents()
const timeString = ref(sessionStorage.getItem(PHONE_TIME_KEY) || '9:10')
const router = useRouter()
const route = useRoute()
const phoneRef = ref(null)
const isEntered = ref(false)
const contentFadeIn = ref(false)
const cachedMoney = sessionStorage.getItem(PHONE_MONEY_KEY)
const careerMoney = ref(cachedMoney !== null && cachedMoney !== '' ? Number(cachedMoney) : null)
const isCareer = ref(sessionStorage.getItem(PHONE_IS_CAREER_KEY) === 'true')
let careerStatusInterval = null

function refreshCareerStatus() {
  if (!lua.career_career?.isActive) return
  lua.career_career.isActive().then(active => {
    isCareer.value = !!active
    sessionStorage.setItem(PHONE_IS_CAREER_KEY, String(active))
    if (!active || !lua.career_modules_uiUtils?.getCareerStatusData) return
    return lua.career_modules_uiUtils.getCareerStatusData()
  }).then(data => {
    const money = data != null ? data?.money ?? null : null
    careerMoney.value = money
    sessionStorage.setItem(PHONE_MONEY_KEY, money != null ? String(money) : '')
  }).catch(() => {
    careerMoney.value = null
    sessionStorage.setItem(PHONE_MONEY_KEY, '')
  })
}

const cashDisplay = computed(() => {
  if (!isCareer.value || careerMoney.value == null) return null
  return formatCash(careerMoney.value)
})

const wrapperStyle = computed(() => ({
  '--scale': String(props.scale ?? getPhoneScale(phoneSettings)),
}))

const timeParts = computed(() => {
  const s = timeString.value || ''
  const m = s.match(/^(.+?)\s+(AM|PM)$/i)
  if (m) return { main: m[1], period: ` ${m[2]}` }
  return { main: s, period: '' }
})

// Check if a route name is a phone route
const isPhoneRoute = (routeName) => {
  if (!routeName) return false
  return routeName.startsWith('phone-') || routeName === 'car-meets-phone'
}

const updateTime = (data) => {
  if (data) {
    timeString.value = data
    sessionStorage.setItem(PHONE_TIME_KEY, data)
  }
}

onMounted(async () => {
  lua.extensions.load("ui_phone_time")
  events.on("phone_time_update", data => updateTime(data))
  events.on("closePhone", close)
  refreshCareerStatus()
  careerStatusInterval = setInterval(refreshCareerStatus, 5000)
  lua.ui_phone_time?.requestTime?.()

  const wasPhoneVisible = sessionStorage.getItem('phoneVisible') === 'true'
  if (wasPhoneVisible) contentFadeIn.value = true

  if (phoneRef.value) {
    await nextTick()
    
    if (wasPhoneVisible) {
      // Coming from another phone route - skip animation, show immediately
      // Set transform immediately without transition
      if (phoneRef.value) {
        phoneRef.value.style.transition = 'none'
        isEntered.value = true
        // Re-enable transition after a frame
        requestAnimationFrame(() => {
          if (phoneRef.value) {
            phoneRef.value.style.transition = ''
          }
        })
      }
    } else {
      // First time opening phone - animate up
      requestAnimationFrame(() => {
        isEntered.value = true
      })
      sessionStorage.setItem('phoneVisible', 'true')
    }
  }
})

// Handle route updates (navigating between phone routes)
onBeforeRouteUpdate((to, from) => {
  // If navigating between phone routes, keep phone visible (no animation)
  if (isPhoneRoute(to.name) && isPhoneRoute(from.name)) {
    isEntered.value = true
  }
})

// Handle route leave - check if we're going to another phone route
onBeforeRouteLeave((to, from) => {
  // If going to another phone route, keep phone visible
  if (isPhoneRoute(to.name)) {
    sessionStorage.setItem('phoneVisible', 'true')
    // Don't animate down - phone stays visible
    return true // Allow navigation
  } else {
    // Going to non-phone route - animate down
    if (phoneRef.value && isEntered.value) {
      isEntered.value = false
      // Wait for animation before allowing navigation
      return new Promise(resolve => {
        setTimeout(() => {
          sessionStorage.removeItem('phoneVisible')
          resolve(true)
        }, 500)
      })
    }
    sessionStorage.removeItem('phoneVisible')
    return true
  }
})

onUnmounted(async () => {
  if (careerStatusInterval) {
    clearInterval(careerStatusInterval)
    careerStatusInterval = null
  }
  const nextRoute = router.currentRoute.value
  const isNavigatingToPhoneRoute = isPhoneRoute(nextRoute.name)
  if (!isNavigatingToPhoneRoute) {
    sessionStorage.removeItem('phoneVisible')
  }
})

const close = async () => {
  // Animate phone down before closing
  if (phoneRef.value && isEntered.value) {
    isEntered.value = false
    // Wait for animation to complete
    await new Promise(resolve => setTimeout(resolve, 500))
  }
  sessionStorage.removeItem('phoneVisible')
  lua.extensions.unload("ui_phone_time")
  lua.career_career.closeAllMenus()
}

const back = () => {
  if (props.customBack && props.customBack()) return
  router.back()
}

</script>

<style scoped lang="scss">
.phone-wrapper {
  position: fixed;
  bottom: -1.25em;
  right: 2em;
  z-index: 1000;
  transform: scale(var(--scale)) translateY(100%);
  transform-origin: bottom right;
  opacity: 1;
  transition: transform 0.5s cubic-bezier(0.34, 1.56, 0.64, 1);
  
  &.phone-entered {
    transform: scale(var(--scale)) translateY(0);
  }
  
  .phone-bevel {
    position: absolute;
    top: -0.35em;
    left: -0.35em;
    right: -0.35em;
    bottom: -0.35em;
    border-radius: 2.5em;
    background: linear-gradient(160deg, #2a2a2a 0%, #0a0a0a 40%, #000 100%);
    border: 1px solid rgba(120, 120, 120, 0.35);
    box-shadow:
      0 0 0 1px rgba(0, 0, 0, 0.8),
      0 4px 20px rgba(0, 0, 0, 0.6),
      inset 0 1px 0 rgba(255, 255, 255, 0.06);
  }

  .phone-screen {
    position: relative;
    width: 360px;
    height: 640px;
    border-radius: 2em;
    overflow: hidden;
    background: transparent;
    
    :deep(.card-cnt) {
      height: 100%;
      border-radius: 2em;
      overflow: hidden;
    }
  }

  .phone-content {
    height: 100%;
    overflow-y: hidden;
    color: white;
    border-radius: 1.5em;

    &.content-fade-in {
      animation: phoneContentFadeIn 0.25s ease-out;
    }
  }
}

@keyframes phoneContentFadeIn {
  from { opacity: 0; }
  to { opacity: 1; }
}

.phone-status-bar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.5em 1em 0.6em;
  min-height: 36px;
  z-index: 10;
  pointer-events: none;

  &::before {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(to bottom, rgba(0,0,0,0.35) 0%, rgba(0,0,0,0) 100%);
    pointer-events: none;
    z-index: -1;
  }
}

.status-bar-cell {
  display: flex;
  align-items: center;
  min-height: 28px;
}

.status-bar-left {
  justify-content: flex-start;
  flex: 1;
  min-width: 0;
}

.status-bar-center {
  position: absolute;
  left: 50%;
  transform: translateX(-50%);
  flex-shrink: 0;
}

.status-bar-right {
  justify-content: flex-end;
  flex: 1;
  min-width: 0;
}

.status-right-pill {
  display: flex;
  align-items: center;
  height: 24px;
  padding: 0 0.6em;
  background: rgba(0, 0, 0, 0.55);
  backdrop-filter: blur(8px);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 12px;
}

.dynamic-island {
  display: flex;
  align-items: center;
  justify-content: center;
  min-width: 80px;
  max-width: 140px;
  height: 24px;
  padding: 0 0.75em;
  background: #000;
  border-radius: 12px;
  flex-shrink: 0;
}

.dynamic-island-label {
  font-size: 0.8em;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.65);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.status-time {
  display: inline-flex;
  align-items: flex-end;
  font-size: 1.2em;
  font-weight: 500;
  line-height: 1;
  margin-left: 0.5em;
}

.status-time-period {
  font-size: 0.6em;
  font-weight: 400;
  margin-left: 0.25em;
}

.status-cash {
  font-size: 0.95em;
  font-weight: 500;
  color: #fff;
}

.status-back {
  display: flex;
  align-items: center;
  gap: 0.5em;
  height: 24px;
  padding: 0 0.75em;
  line-height: 1;
  background: rgba(0, 0, 0, 0.55);
  backdrop-filter: blur(8px);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 12px;
  outline: none;
  cursor: pointer;
  pointer-events: auto;
  font-size: 14px;
  font-weight: 500;
  color: #fff;
  transition: background 0.15s ease, transform 0.12s ease;

  &:hover {
    background: rgba(0, 0, 0, 0.7);
  }

  &:active {
    background: rgba(0, 0, 0, 0.8);
    transform: scale(0.96);
  }
}

.status-back-icon {
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
</style>
