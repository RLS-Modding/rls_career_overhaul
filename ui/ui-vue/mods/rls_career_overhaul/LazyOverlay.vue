<template>
  <component v-if="component" :is="component" @vue:mounted="onReady" />
</template>

<script setup>
// Own the first-event handoff until the child's mounted listeners can receive it.
// Activation, cancellation events and optional boot resync live in coreUi.json.
import { onBeforeUnmount, onMounted, shallowRef } from "vue"
import { useBridge } from "@/bridge"
import { callModLua } from "./overhaul/modules/career/utils/installLuaBridgeFallbacks.js"
import { reportUiFailure, safeLua } from "./overhaul/modules/career/utils/safeLua.js"

const props = defineProps({ overlay: { type: Object, required: true } })
const { events } = useBridge()
const component = shallowRef(null)
const { mountOn, resync } = props.overlay
const subscriptions = new Map()
let pending = []
let loading = false
let disposed = false

function matches(payload) {
  if (!mountOn.when) return true
  const data = Array.isArray(payload) ? payload.find(item => item && typeof item === "object") : payload
  return data && Object.entries(mountOn.when).every(([key, value]) => data[key] === value)
}

async function receive(event, args) {
  if (disposed) return
  if (!loading && (event !== mountOn.event || !matches(args[0]))) return
  pending.push({ event, args })
  if (loading) return
  loading = true
  try {
    const loaded = await props.overlay.component.__asyncLoader()
    if (!disposed) component.value = loaded
  } catch (error) {
    loading = false
    pending = []
    if (!disposed) reportUiFailure(error, `Load ${props.overlay.id} overlay`)
  }
}

function stopListening() {
  for (const [event, handler] of subscriptions) events.off(event, handler)
  subscriptions.clear()
}

function onReady() {
  stopListening()
  const buffered = pending
  pending = []
  if (disposed) return
  // Replay synchronously so a close received during compilation wins before paint.
  for (const { event, args } of buffered) events.emit(event, ...args)
}

for (const event of new Set([mountOn.event, ...(mountOn.bufferEvents || [])])) {
  const handler = (...args) => receive(event, args)
  subscriptions.set(event, handler)
  events.on(event, handler)
}

onMounted(() => {
  // These methods publish their current state; no component compile is needed
  // when the owner has nothing visible, including after a Vue debug mod reload.
  if (resync) safeLua(() => callModLua(resync.method, ...(resync.args || [])), `Resync ${props.overlay.id} overlay`)
})

onBeforeUnmount(() => {
  disposed = true
  pending = []
  stopListening()
})
</script>
