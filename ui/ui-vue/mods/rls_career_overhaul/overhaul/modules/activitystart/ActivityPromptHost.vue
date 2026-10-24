<template>
  <span v-if="false" />
</template>

<script setup>
import { defineAsyncComponent, onBeforeUnmount } from "vue"
import { lua, useBridge } from "@/bridge"
import { openScreenOverlay } from "@/services/popup"
import { useOverhaulActivityPromptStore } from "./activityPromptStore.js"
const ActivityStart = defineAsyncComponent(() => import("./views/ActivityStart.vue"))

const OPEN_EVENT = "OverhaulActivityAcceptUpdate"
const CLOSE_EVENTS = ["ActivityAcceptUpdate", "ActivityAcceptClose", "MenuOpenModule", "ChangeState"]

const { events } = useBridge()
const store = useOverhaulActivityPromptStore()
let screen = null
let updateVersion = 0

async function isPlayRoute() {
  try {
    const current = await lua.extensions.ui_router.getCurrent()
    return !!(current && current.resolved.name === "play")
  } catch {
    return false
  }
}

function close() {
  updateVersion++
  if (!screen) return
  screen.close(true)
  screen = null
}

async function open(data) {
  close()
  const version = ++updateVersion
  const isPlay = await isPlayRoute()
  if (version !== updateVersion || !isPlay) return
  store.activities = Array.isArray(data) ? data : []
  if (store.activities.length > 0) screen = openScreenOverlay(ActivityStart)
}

events.on(OPEN_EVENT, open)
CLOSE_EVENTS.forEach(name => events.on(name, close))

onBeforeUnmount(() => {
  events.off(OPEN_EVENT, open)
  CLOSE_EVENTS.forEach(name => events.off(name, close))
  close()
})
</script>
