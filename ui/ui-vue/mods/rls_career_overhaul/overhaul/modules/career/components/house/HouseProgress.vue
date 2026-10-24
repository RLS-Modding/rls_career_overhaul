<!-- House progress popup. Same props and tunnel contract as the game's Progress popup, so
     openHouseProgress is drop-in for openProgress (popup.progress.update(value, message) / .done()).
     Determinate: an orange fill scaled with transform. Indeterminate: a soft orange sweep. -->
<template>
  <div
    class="rls-house house-progress"
    v-bng-scoped-nav="popupScopeBinding"
    v-bng-on-ui-nav:back,menu="handleCancelWithBack">
    <div class="modal progress-card">
      <h3 v-if="title">{{ title }}</h3>
      <p v-if="msg" class="progress-message">{{ msg }}</p>

      <div class="progress-row">
        <div class="progress-track" :class="{ indeterminate }">
          <span v-if="indeterminate" class="sweep" />
          <span v-else class="fill" :style="{ transform: `scaleX(${fraction})` }" />
        </div>
        <span v-if="!indeterminate && valueLabel" class="progress-value">{{ valueLabel }}</span>
      </div>

      <div v-if="displayButtons.length" class="actions">
        <HouseButton
          v-for="(button, index) in displayButtons"
          :key="index"
          :variant="isCancel(button) ? 'quiet' : 'neutral'"
          v-bng-ui-nav-focus="popupActive && button === focusButton ? 1000 : undefined"
          v-bng-focus-if="popupActive && button === focusButton"
          :bng-scoped-nav-autofocus="popupActive && button === focusButton ? true : null"
          @click="emitButtonValue(button)">
          {{ button.label }}
        </HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, ref, useAttrs, watch } from "vue"
import { vBngFocusIf, vBngOnUiNav, vBngScopedNav, vBngUiNavFocus } from "@/common/directives"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { isCancel, playCancelSound, resolveFocusButton } from "@/common/modules/popup/buttonRoles.js"
import HouseButton from "./HouseButton.vue"

const emit = defineEmits(["return"])

const props = defineProps({
  title: String,
  message: String,
  popupActive: Boolean,
  buttons: Array,
  indeterminate: Boolean,
  min: { type: Number, default: 0 },
  max: { type: Number, default: 100 },
  initialValue: { type: Number, default: 0 },
  valueLabelFormat: { type: [String, Function], default: () => val => `${val}%` },
  timeout: { type: Number, default: 0 },
  cancellable: Boolean,
  tunnel: Object,
})

const displayButtons = computed(() => props.buttons || [])
const focusButton = computed(() => resolveFocusButton(displayButtons.value, false))
const cancelButton = computed(() => displayButtons.value.find(button => isCancel(button)))

const popupNavEvents = ["focus_u", "focus_d", "focus_l", "focus_r", "back", "menu", "ok"]
const navBlocker = useUINavBlocker()
watch(
  () => props.popupActive,
  active => (active ? navBlocker.allowOnly(popupNavEvents) : navBlocker.clear()),
  { immediate: true }
)

const attrs = useAttrs()
const popupScopeBinding = computed(() => ({
  scopeId: `_houseProgress__${attrs.__id}`,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const progressValue = ref(props.initialValue)
const msg = ref(props.message)

const fraction = computed(() => {
  const span = props.max - props.min
  if (!span) return 0
  return Math.min(1, Math.max(0, (progressValue.value - props.min) / span))
})
const valueLabel = computed(() => {
  const f = props.valueLabelFormat
  if (!f) return ""
  return typeof f === "function" ? f(progressValue.value) : String(f).replace("{value}", progressValue.value)
})

const emitButtonValue = button => emit("return", typeof button.value === "function" ? button.value() : button.value)

const close = () => emit("return", cancelButton.value ? cancelButton.value.value : null)

const handleCancelWithBack = () => {
  if (!props.cancellable) return
  if (cancelButton.value) playCancelSound(cancelButton.value)
  close()
}

const updateProgress = (value, message = undefined) => {
  progressValue.value = +value
  if (message !== undefined) msg.value = message
}

if (props.tunnel) {
  props.tunnel.update = updateProgress
  props.tunnel.flushPendingUpdate?.(updateProgress)
  props.tunnel.done = close
  props.tunnel.ready = true
}

const timeoutId = props.timeout ? setTimeout(close, props.timeout * 1000) : null
onBeforeUnmount(() => { if (timeoutId) clearTimeout(timeoutId) })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.house-progress {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.progress-card {
  width: min(24em, 92vw);
  gap: 0.8em;
  padding: 1.1em 1.1em 1.2em;
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
}
.progress-message {
  color: var(--muted);
}
.progress-row {
  display: flex;
  align-items: center;
  gap: 0.7em;
}
.progress-track {
  position: relative;
  flex: 1 1 auto;
  height: 0.45em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
}
.fill {
  position: absolute;
  inset: 0;
  border-radius: inherit;
  background: var(--accent);
  transform-origin: left center;
  /* updates arrive in steps; a short linear glide keeps it smooth without lagging behind */
  transition: transform 0.2s linear;
}
.sweep {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  width: 40%;
  border-radius: inherit;
  background: linear-gradient(90deg, rgba(255, 102, 0, 0), var(--accent) 50%, rgba(255, 102, 0, 0));
  animation: house-progress-sweep 1.15s cubic-bezier(0.45, 0, 0.55, 1) infinite;
}
@keyframes house-progress-sweep {
  from {
    transform: translateX(-100%);
  }
  to {
    transform: translateX(250%);
  }
}
@media (prefers-reduced-motion: reduce) {
  .sweep {
    animation: none;
    width: 100%;
    opacity: 0.5;
  }
  .fill {
    transition: none;
  }
}
.progress-value {
  flex: 0 0 auto;
  min-width: 2.8em;
  text-align: right;
  color: #fff;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
.actions {
  display: flex;
  justify-content: flex-end;
  gap: var(--space-2);
}
</style>
