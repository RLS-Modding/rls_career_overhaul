<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <EntryOverlayPopup :active="visible" :can-cancel="!capturing" @cancel="hide" @leave="hide">
    <div
      v-if="visible"
      class="rls-tester"
      >
      <button type="button" class="rls-tester__backdrop" bng-no-nav="true" tabindex="-1" aria-label="Close tester menu" @click="hide" />
      <div class="rls-tester__panel" role="dialog" aria-label="RLS Tester Menu" v-bng-ui-nav-scroll>
        <h2>RLS Tester</h2>
        <p class="rls-tester__money">Money: <BngIcon class="cur" :type="icons.beamCurrency" />{{ Math.floor(money || 0) }}</p>
        <p v-if="status" class="rls-tester__status" :class="{ error: statusIsError }">{{ status }}</p>

        <h3>Weather</h3>
        <div class="rls-tester__row">
          <button type="button" @click="run('sunny')">Sunny</button>
          <button type="button" @click="run('rain')">Heavy Rain</button>
          <button type="button" @click="run('overcast')">Overcast</button>
        </div>

        <h3>Time of day</h3>
        <div class="rls-tester__row">
          <button type="button" @click="run('sleep6am')">6am</button>
          <button type="button" @click="run('sleep12pm')">12pm</button>
          <button type="button" @click="run('sleep9pm')">9pm</button>
          <button type="button" @click="run('sleep12am')">12am</button>
        </div>
        <button type="button" @click="run('cycle')">Toggle day/night cycle</button>

        <h3>Economy / skills</h3>
        <div class="rls-tester__row">
          <button type="button" @click="run('money')">Add <BngIcon class="cur" :type="icons.beamCurrency" />1,000,000</button>
          <button type="button" @click="run('moneySmall')">Add <BngIcon class="cur" :type="icons.beamCurrency" />10,000</button>
        </div>
        <div class="rls-tester__row">
          <button type="button" @click="run('xp')">Add 100,000 XP</button>
          <button type="button" @click="run('xpSmall')">Add 1,000 XP</button>
        </div>
        <div class="rls-tester__row">
          <button type="button" @click="run('tuningShopXp')">Add 10,000 tuning shop XP</button>
          <button type="button" @click="run('tuningShopTree')">Max tuning shop skill tree</button>
          <button type="button" @click="run('dealerships')">Discover + max all dealerships</button>
        </div>
        <button type="button" @click="run('skipLevelUps')">Skip level-up notifications</button>

        <h3>Quick spawn (owned)</h3>
        <div class="rls-tester__row">
          <button type="button" @click="run('drift')">Drift</button>
          <button type="button" @click="run('race')">Race</button>
          <button type="button" @click="run('rally')">Rally</button>
          <button type="button" @click="run('work')">Work Truck</button>
        </div>
        <div class="rls-tester__row">
          <button type="button" @click="run('random')">Random car, random parts</button>
          <button type="button" @click="run('own')">Own current vehicle</button>
        </div>

        <h3>World</h3>
        <div class="rls-tester__row">
          <button type="button" @click="run('switcher')">Open map switcher</button>
          <button type="button" @click="run('waypoint')">Teleport to waypoint</button>
          <button type="button" @click="run('repair')">Repair + refuel</button>
          <button type="button" @click="run('save')">Save career</button>
        </div>

        <h3>Clean Up Club</h3>
        <div class="rls-tester__row">
          <button type="button" @click="run('cleanupSpawn')">Spawn vehicle container</button>
          <button type="button" @click="run('cleanupFocus')">Focus camera</button>
        </div>

        <h3>Shortcut</h3>
        <div class="rls-tester__row">
          <button type="button" :class="{ listening: capturing }" @click.stop="startCapture">
            {{ capturing ? "Press a key…" : ("Change shortcut (" + shortcutLabel + ")") }}
          </button>
        </div>

        <p class="rls-tester__hint">{{ shortcutLabel }} toggles this menu. Click outside to cancel a bind or hide.</p>
      </div>
    </div>
  </EntryOverlayPopup>
</template>

<script setup>
import EntryOverlayPopup from "./EntryOverlayPopup.vue"
import { ref, computed, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { callModLuaIfAvailable } from "../utils/installLuaBridgeFallbacks"

const bridge = useBridge()
const visible = ref(false)
const money = ref(0)
const status = ref("")
const statusIsError = ref(false)
const toggleControl = ref("f9")
const toggleLabel = ref("")
const deviceName = ref("keyboard0")
const capturing = ref(false)

function formatShortcut(control, device) {
  const c = String(control || "")
  const dev = String(device || "")
  if (!c) return "F9"
  if (dev.startsWith("mouse")) {
    const match = c.match(/^button(\d+)$/i)
    if (match) {
      const n = Number(match[1])
      if (n === 0) return "Mouse Left"
      if (n === 1) return "Mouse Right"
      if (n === 2) return "Mouse Middle"
      return "Mouse Button " + (n + 1)
    }
    return "Mouse " + c
  }
  const symbols = {
    backslash: "\\",
    slash: "/",
    comma: ",",
    period: ".",
    semicolon: ";",
    apostrophe: "'",
    grave: "`",
    minus: "-",
    equals: "=",
    leftbracket: "[",
    rightbracket: "]",
  }
  const lower = c.toLowerCase()
  if (symbols[lower]) return symbols[lower]
  if (/^f\d+$/i.test(c)) return c.toUpperCase()
  if (lower === "space") return "Space"
  if (lower === "enter" || lower === "return") return "Enter"
  if (lower === "tab") return "Tab"
  return c.replace(/_/g, " ").replace(/^\w/, ch => ch.toUpperCase())
}

const shortcutLabel = computed(() => toggleLabel.value || formatShortcut(toggleControl.value, deviceName.value))

function applyPayload(raw) {
  const data = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : (Array.isArray(raw) ? raw[0] : null)
  if (!data || typeof data !== "object") return
  visible.value = data.visible === true
  if (typeof data.money === "number") money.value = data.money
  if (typeof data.status === "string") status.value = data.status
  statusIsError.value = data.statusIsError === true
  if (typeof data.toggleControl === "string" && data.toggleControl) toggleControl.value = data.toggleControl
  if (typeof data.deviceName === "string" && data.deviceName) deviceName.value = data.deviceName
  if (typeof data.toggleLabel === "string" && data.toggleLabel) {
    toggleLabel.value = data.toggleLabel
  } else if (data.toggleControl || data.deviceName) {
    toggleLabel.value = formatShortcut(toggleControl.value, deviceName.value)
  }
}

function engineLua(snippet) {
  const api = window.bngApi || window.beamng
  if (typeof api?.engineLua === "function") api.engineLua(snippet)
}

function rawPayload(eventOrData, dataArg) {
  const data = dataArg !== undefined ? dataArg : eventOrData
  if (Array.isArray(data) && data[0] && typeof data[0] === "object") return data[0]
  return data && typeof data === "object" ? data : null
}

const eventsRegister = {}
let controlCaptured = false
let angularOff = null

function stopBindingHardware() {
  engineLua("pcall(function() WinInput.setForwardRawEvents(false) end)")
  engineLua("pcall(function() setCEFTyping(false) end)")
  engineLua("pcall(function() ActionMap.enableBindingCapturing(false) end)")
}

function luaQuote(value) {
  return String(value || "").replace(/\\/g, "\\\\").replace(/'/g, "\\'")
}

function onRawInput(eventOrData, dataArg) {
  if (!capturing.value || controlCaptured) return
  const data = rawPayload(eventOrData, dataArg)
  if (!data || !data.control) return

  const control = String(data.control)
  const controlType = data.controlType
  const devName = data.devName || "keyboard0"
  const isMouse = String(devName).startsWith("mouse")
  if (controlType === "axis") return
  if (isMouse && control === "button0") return
  if (control === "escape" || control === "esc") {
    stopCapture(true)
    return
  }

  if (!eventsRegister[devName]) {
    eventsRegister[devName] = { key: [null, null] }
  }
  const eventData = eventsRegister[devName]
  eventData.key = [eventData.key[eventData.key.length - 1], control]
  const key0 = eventData.key[0]
  const key1 = eventData.key[1]
  if (!(key0 && key1 && key0 === key1)) return
  if (data.value === 0) eventData.key = [null, null]

  controlCaptured = true
  capturing.value = false
  toggleControl.value = control
  deviceName.value = devName
  toggleLabel.value = formatShortcut(control, devName)
  stopBindingHardware()
  engineLua(
    "if overhaul_dev_testerMenu then overhaul_dev_testerMenu.setToggleControl('" +
      luaQuote(control) +
      "', '" +
      luaQuote(devName) +
      "') end",
  )
}

function startCapture(event) {
  if (event) {
    event.preventDefault()
    event.stopPropagation()
  }
  if (capturing.value) return
  capturing.value = true
  controlCaptured = false
  Object.keys(eventsRegister).forEach(key => delete eventsRegister[key])
  callModLuaIfAvailable("overhaul_dev_testerMenu.beginRebind")
}

function stopCapture(cancelLua) {
  capturing.value = false
  controlCaptured = false
  stopBindingHardware()
  if (cancelLua) callModLuaIfAvailable("overhaul_dev_testerMenu.cancelRebind")
}

function run(actionId) {
  callModLuaIfAvailable("overhaul_dev_testerMenu.run", String(actionId || ""))
}

function hide() {
  if (capturing.value) {
    stopCapture(true)
    return
  }
  callModLuaIfAvailable("overhaul_dev_testerMenu.toggle")
}

onMounted(() => {
  bridge.events.on("RlsTesterMenu", applyPayload)
  bridge.events.on("RawInputChanged", onRawInput)
  const extraBridge = window.bridge
  if (extraBridge?.events && extraBridge.events !== bridge.events && extraBridge.events !== window.vueEventBus) {
    extraBridge.events.on("RawInputChanged", onRawInput)
  }
  const angularRoot = window.globalAngularRootScope
  if (angularRoot && typeof angularRoot.$on === "function") {
    angularOff = angularRoot.$on("RawInputChanged", onRawInput)
  }
})

onBeforeUnmount(() => {
  if (capturing.value) stopCapture(true)
  else stopBindingHardware()
  bridge.events.off("RlsTesterMenu", applyPayload)
  bridge.events.off("RawInputChanged", onRawInput)
  const extraBridge = window.bridge
  if (extraBridge?.events && extraBridge.events !== bridge.events && extraBridge.events !== window.vueEventBus) {
    extraBridge.events.off("RawInputChanged", onRawInput)
  }
  if (typeof angularOff === "function") angularOff()
})
</script>

<style scoped lang="scss">
.rls-tester {
  position: fixed;
  inset: 0;
  z-index: 16000;
  display: flex;
  align-items: flex-start;
  justify-content: flex-end;
  padding: 1.25rem;
  background: rgba(0, 0, 0, 0.25);
  pointer-events: auto;
}
.rls-tester__backdrop { position: absolute; inset: 0; width: 100%; height: 100%; padding: 0; background: transparent; border-radius: 0; }
.rls-tester__backdrop:hover { background: transparent; }
.rls-tester__panel {
  position: relative;
  width: min(26rem, 100%);
  max-height: calc(100vh - 2.5rem);
  overflow: auto;
  padding: 1rem 1.1rem 1.2rem;
  border-radius: 10px;
  background: rgba(18, 20, 26, 0.96);
  color: #f3f4f6;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.4);
}
h2 {
  margin: 0 0 0.35rem;
  font-size: 1.15rem;
}
h3 {
  margin: 0.85rem 0 0.35rem;
  font-size: 0.78rem;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: #9ca3af;
}
.rls-tester__row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  margin-bottom: 0.4rem;
}
button {
  border: 0;
  border-radius: 6px;
  padding: 0.4rem 0.65rem;
  background: #374151;
  color: inherit;
  cursor: pointer;
}
button:hover {
  background: #4b5563;
}
// keyboard / controller focus: the house ring (rlsHouse --focus values) on a positioned button, with
// the game's ::before frame hidden (teleported to <body>)
button {
  position: relative;
  &.focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600),
      0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
  }
  &.focus-visible::before {
    display: none !important;
  }
}
button.listening {
  background: #b45309;
}
.rls-tester__money,
.rls-tester__status,
.rls-tester__hint {
  margin: 0.2rem 0;
  font-size: 0.85rem;
}
.rls-tester__status.error {
  color: #fca5a5;
}
.rls-tester__hint {
  margin-top: 0.9rem;
  color: #9ca3af;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
