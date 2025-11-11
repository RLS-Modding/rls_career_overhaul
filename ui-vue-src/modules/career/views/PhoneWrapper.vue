<template>
  <div 
    ref="phoneRef"
    class="phone-wrapper" 
    :class="{ 'phone-entered': isEntered }"
    :style="{ 
      '--scale': scale,
      '--status-font-color': statusFontColor,
      '--status-blend-mode': statusBlendMode
    }">
    <div class="phone-bevel"></div>
    <div class="phone-screen">
      <!-- Status Bar -->
      <div class="phone-status-bar">
        <div class="phone-status-bar-left">
          <span>{{ timeString }}</span>
          <button class="status-back" v-bng-on-ui-nav:back,menu.asMouse @click="back"> <- Back</button>
        </div>
        <div class="phone-status-bar-right">
          <span>{{ appName }}</span>
        </div>
      </div>
      
      <!-- Optional Header Slot -->
      <template v-if="$slots.header">
        <slot name="header"></slot>
      </template>
      
      <!-- Main Content -->
      <div class="phone-content">
        <slot></slot>
      </div>
    </div>
  </div>
</template>

<script setup>
import { useEvents } from '@/services/events'
import { ref, onMounted, onUnmounted, nextTick } from 'vue'
import { vBngOnUiNav } from "@/common/directives"
import { useRouter, useRoute, onBeforeRouteUpdate, onBeforeRouteLeave } from 'vue-router'
import { lua } from "@/bridge"

const props = defineProps({
  scale: {
    type: Number,
    default: 0.8
  },
  appName: {
    type: String,
    default: ''
  },
  statusFontColor: {
    type: String,
    default: '#ffffff'
  },
  statusBlendMode: {
    type: String,
    default: 'difference'
  }
})

const events = useEvents()
const timeString = ref('9:10')
const router = useRouter()
const route = useRoute()
const phoneRef = ref(null)
const isEntered = ref(false)

// Check if a route name is a phone route
const isPhoneRoute = (routeName) => {
  if (!routeName) return false
  return routeName.startsWith('phone-') || routeName === 'car-meets-phone'
}

const updateTime = (data) => {
  if (data) {
    timeString.value = data
  }
}

onMounted(async () => {
  lua.extensions.load("ui_phone_time")
  events.on("phone_time_update", data => updateTime(data))
  events.on("closePhone", close)
  
  // Check if phone was already visible (navigating between phone routes)
  const wasPhoneVisible = sessionStorage.getItem('phoneVisible') === 'true'
  
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
        }, 400)
      })
    }
    sessionStorage.removeItem('phoneVisible')
    return true
  }
})

onUnmounted(async () => {
  // Cleanup - animation is handled by onBeforeRouteLeave
  // Only clean up if we're actually leaving phone routes (not navigating between them)
  const nextRoute = router.currentRoute.value
  const isNavigatingToPhoneRoute = isPhoneRoute(nextRoute.name)
  
  if (!isNavigatingToPhoneRoute) {
    // Already handled by onBeforeRouteLeave, but ensure cleanup
    sessionStorage.removeItem('phoneVisible')
  }
})

const close = async () => {
  // Animate phone down before closing
  if (phoneRef.value && isEntered.value) {
    isEntered.value = false
    // Wait for animation to complete
    await new Promise(resolve => setTimeout(resolve, 400))
  }
  sessionStorage.removeItem('phoneVisible')
  lua.extensions.unload("ui_phone_time")
  lua.career_career.closeAllMenus()
}

const back = () => {
  // Just navigate back - let onBeforeRouteLeave handle the animation logic
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
  transition: transform 0.4s ease;
  
  &.phone-entered {
    transform: scale(var(--scale)) translateY(0);
  }
  
  .phone-bevel {
    position: absolute;
    top: -0.7em;
    left: -0.7em;
    right: -0.7em;
    bottom: -0.7em;
    border-radius: 2.5em;
    background: linear-gradient(145deg,
    rgba(0,0,0,1) 100%,
      rgb(0, 0, 0) 100%
      
    );
    border: 0.15em solid rgba(168, 168, 168, 0.5)
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
  }
}

.phone-status-bar {
  position: absolute;
  top: 0.35em;
  left: 1em;
  right: 1em;
  display: flex;
  justify-content: space-between;
  font-size: 1.35em;
  font-weight: bold;
  color: var(--status-font-color);
  background-color: transparent;
  z-index: 10;
  mix-blend-mode: var(--status-blend-mode);
  text-shadow: 0 1px 2px rgba(0,0,0,0.3);
  pointer-events: none;

  &::before {
    content: '';
    position: absolute;
    top: -0.6em;
    left: -1em;
    right: -1em;
    height: calc(0.5em + 1.7em);
    background: linear-gradient(to bottom, var(--status-font-color), rgba(0,0,0,0) 100%);
    filter: invert(1);
    opacity: 1;
    z-index: -1;
  }
}

.phone-status-bar-left {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: flex-start;
}

.phone-status-bar-right {
  display: flex;
  align-items: flex-start;
  justify-content: flex-end;
}

.status-back {
  background-color: transparent;
  outline: none;
  border: none;
  z-index: -1;
  cursor: pointer;
  pointer-events: auto;
  font-size: 13px;
  font-weight: bold;
  color: var(--status-font-color);
}
</style>