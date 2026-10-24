<template>
  <div class="top-left-apps">
    <Transition name="app-fade">
      <div v-if="isScoreboard" class="app-slot app-slot--scoreboard">
        <Scoreboard />
      </div>
    </Transition>

    <Transition name="app-fade">
      <div v-if="isTasks && tasklistStore.hasItems" ref="taskSlot" class="app-slot app-slot--tasks">
        <TaskList :header="tasklistStore.header" :tasks="tasklistStore.tasks" />
        <div v-if="spawnAction.visible" class="spawn-action" :class="{ 'spawn-action--above': spawnAbove }">
          <button type="button" :disabled="!spawnAction.ready || spawnBusy" @click="spawnVehicle">
            {{ spawnBusy ? 'Spawning…' : 'Spawn vehicle' }}
          </button>
          <span v-if="spawnError" role="status">{{ spawnError }}</span>
        </div>
      </div>
    </Transition>

    <div
      v-if="spawnAction.visible && !(isTasks && tasklistStore.hasItems)"
      class="app-slot app-slot--tasks"
    >
      <div class="spawn-action">
        <button type="button" :disabled="!spawnAction.ready || spawnBusy" @click="spawnVehicle">
          {{ spawnBusy ? 'Spawning…' : 'Spawn vehicle' }}
        </button>
        <span v-if="spawnError" role="status">{{ spawnError }}</span>
      </div>
    </div>

    <div v-if="isDriftScores" class="drift-spacer"></div>

    <Transition name="app-fade">
      <div v-if="isDriftScores" class="app-slot app-slot--drift-scores">
        <DriftScores />
      </div>
    </Transition>

    <div v-if="isDriftScores" class="drift-spacer"></div>

    <div v-if="isMessages" class="app-slot app-slot--messages">
      <Messages />
    </div>

    <div v-if="isDragInfo" class="app-slot app-slot--drag-info">
      <DragInfo />
    </div>
  </div>

  <Teleport to="body">
    <div v-if="isDragDial" class="dial-overlay">
      <div class="dial-backdrop" @click="closeDragDial" />
      <div class="dial-popup">
        <DragDialControl @close="closeDragDial" />
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { reportFailure } from '../../overhaulAngular/reportFailure.js'
import { luaLiteral as encodeLuaString } from '../../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/luaLiteral.js'
import { ref, nextTick, watch, onMounted, onUnmounted } from "vue"
import { useRoute } from "vue-router"
import { TaskList, useTasksStore } from "@/modules/tasks"
import {
  Messages,
  Scoreboard,
  DriftScores,
  DragInfo,
  DragDialControl,
} from "@/modules/apps"
import { useEvents } from "@/services/events"
import { useBridge } from "@/bridge"

const { lua, api } = useBridge()
const events = useEvents()
const tasklistStore = useTasksStore()
const route = useRoute()
let refreshQueued = false
let mounted = false
const taskSlot = ref(null)
const spawnAction = ref({ visible: false, ready: false })
const spawnAbove = ref(false)
const spawnBusy = ref(false)
const spawnError = ref('')

function positionSpawnAction() {
  if (!mounted || !spawnAction.value.visible) return
  const rect = taskSlot.value?.getBoundingClientRect()
  if (rect) spawnAbove.value = (rect.top + rect.bottom) / 2 > window.innerHeight / 2
}

function setSpawnAction(data) {
  spawnAction.value = data || { visible: false, ready: false }
  spawnError.value = ''
}

function callModule(name, fn) {
  const expr = `(function() local m = rawget(_G, ${encodeLuaString(name)}) if type(m) ~= "table" or type(m[${encodeLuaString(fn)}]) ~= "function" then return false end local ok, result = pcall(m[${encodeLuaString(fn)}]) return ok and result and true or false end)()`
  return new Promise(resolve => api.engineLua(expr, resolve))
}

async function spawnVehicle() {
  if (spawnBusy.value || !spawnAction.value.visible || !spawnAction.value.ready) return
  spawnBusy.value = true
  spawnError.value = ''
  try {
    let ok = await callModule("overhaul_career_work_employment", "spawnBlockedEquipment")
    if (!ok) ok = await callModule("overhaul_career_logistics_loanerVehicles", "spawnBlockedOffers")
    if (!ok) spawnError.value = 'Move near the marked space and make sure it is clear.'
  } catch (_) {
    spawnError.value = 'Unable to spawn. Please try again.'
  } finally {
    spawnBusy.value = false
  }
}

function requestJobTasks() {
  if (!mounted || refreshQueued) return
  refreshQueued = true
  nextTick(() => {
    refreshQueued = false
    if (!mounted || !(route.name === "play" || route.path === "/play")) return
    api.engineLua("if overhaul_career_logistics_tasklist and overhaul_career_logistics_tasklist.restoreActiveJobGuidance then overhaul_career_logistics_tasklist.restoreActiveJobGuidance() end")
  })
}

watch(() => route.fullPath, requestJobTasks)

const isMessages = ref(false)
const isTasks = ref(false)
const isScoreboard = ref(false)
const isDriftScores = ref(false)
const isDragInfo = ref(false)
const isDragDial = ref(false)

const appStates = {
  messages: isMessages,
  tasks: isTasks,
  scoreboard: isScoreboard,
  driftScores: isDriftScores,
  dragInfo: isDragInfo,
  dragDialControl: isDragDial,
}

// Task content and visibility settle before measuring the rendered slot.
watch(() => [spawnAction.value.visible, isTasks.value, tasklistStore.hasItems,
  tasklistStore.header, tasklistStore.tasks], positionSpawnAction, { deep: true, flush: 'post' })

function closeDragDial() {
  isDragDial.value = false
  lua.ui_appContainers.hideApp("topLeft", "dragDialControl")
}

function setAppVisibility(data) {
  if (data.appId && appStates[data.appId]) {
    appStates[data.appId].value = data.visible
  }
  if (data.hideAll) {
    Object.values(appStates).forEach((s) => { s.value = false })
  }
  if (data.hideAll || (data.appId === "tasks" && !data.visible)) requestJobTasks()
}

async function loadInitialVisibility() {
  try {
    const visibleApps = await lua.ui_appContainers.getVisibleApps("topLeft")
    Object.values(appStates).forEach((s) => { s.value = false })
    if (Array.isArray(visibleApps)) {
      visibleApps.forEach((appId) => {
        if (appStates[appId]) appStates[appId].value = true
      })
    }
  } catch (error) { reportFailure(error, 'Read initial top-left app visibility') }
}

onMounted(() => {
  mounted = true
  window.addEventListener('resize', positionSpawnAction)
  events.on("setTopLeftAppVisibility", setAppVisibility)
  events.on("ClearTasklist", requestJobTasks)
  events.on("EmploymentSpawnAction", setSpawnAction)
  events.on("OverhaulSpawnVehicle", spawnVehicle)
  loadInitialVisibility().then(requestJobTasks)
})

onUnmounted(() => {
  mounted = false
  events.off("setTopLeftAppVisibility", setAppVisibility)
  events.off("ClearTasklist", requestJobTasks)
  events.off("EmploymentSpawnAction", setSpawnAction)
  events.off("OverhaulSpawnVehicle", spawnVehicle)
  window.removeEventListener('resize', positionSpawnAction)
})
</script>

<style lang="scss" scoped>
.top-left-apps {
  position: relative;
  display: flex;
  align-items: center;
  flex-direction: column;
  width: 100%;
  height: 100%;
  gap: 0;


  > .app-slot {
    flex: 0 0 auto;
    width: 100%;
    max-width: 36rem;
  }

  > .app-slot--tasks {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
    min-height: 0;
    padding-top: 0.25rem;
    padding-bottom: 0.25rem;
  }

  > .drift-spacer {
    flex: 1 1 0;
  }

  > .app-slot--drift-scores {
    padding-top: 0.25rem;

    &.app-fade-leave-active {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
    }
  }

  > .app-slot--drag-info {
    padding-top: 0.25rem;
  }
}

.app-fade-enter-active,
.app-fade-leave-active {
  transition: opacity 0.3s ease;
}

.app-fade-enter-from,
.app-fade-leave-to {
  opacity: 0;
}

.dial-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: all;
}

.dial-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
}

.dial-popup {
  position: relative;
  z-index: 1;
  width: 20rem;
}
</style>

<style lang="scss" scoped>
.spawn-action {
  flex: 0 0 auto;
  pointer-events: auto;
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
  padding: 0.4rem;
  color: white;
  background: rgba(15, 15, 15, 0.9);
  border-radius: 0.25rem;
  font-size: 0.85rem;
  &--above { order: -1; }
  button {
    padding: 0.45rem 0.75rem;
    border: 0;
    border-radius: 0.2rem;
    background: #f60;
    color: white;
    font: inherit;
    cursor: pointer;
    &:disabled { opacity: 0.5; cursor: default; }
    &.focus-visible { outline: 2px solid white; outline-offset: 2px; }
  }
}
</style>
