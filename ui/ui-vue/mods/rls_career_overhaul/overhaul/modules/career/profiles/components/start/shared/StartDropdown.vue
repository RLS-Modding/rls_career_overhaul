<template>
  <div class="start-dropdown">
    <label v-if="label" class="start-dropdown-label">{{ label }}</label>
    <div v-if="isSingleOption" class="start-dropdown-static">{{ selectedLabel }}</div>
    <div v-else ref="rootRef" class="start-dropdown-wrap">
      <button
        type="button"
        class="start-dropdown-trigger"
        :disabled="disabled"
        @click.stop="toggle"
        @mousedown.stop>
        <span class="start-dropdown-text">{{ selectedLabel }}</span>
        <span class="start-dropdown-chevron">&#x25BE;</span>
      </button>
      <teleport to="body">
        <!-- The teleported menu needs its own navigation scope. -->
        <div
          v-if="open"
          v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (close(), false) }"
          v-bng-on-ui-nav:menu="close"
          class="start-dropdown-menu css-start-dropdown-menu"
          :style="menuStyle"
          @click.stop
          @mousedown.stop>
          <div
            v-for="opt in options"
            :key="opt.value"
            class="start-dropdown-option"
            :class="{ 'start-dropdown-option--active': opt.value === modelValue }"
            role="button"
            tabindex="0"
            bng-nav-item
            :bng-scoped-nav-autofocus="opt.value === modelValue ? '' : null"
            @click.stop="select(opt.value)"
            @keydown.enter.prevent="select(opt.value)"
            @mousedown.stop>
            {{ opt.label }}
          </div>
        </div>
      </teleport>
    </div>
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from "vue"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { returnFocusToOpener } from "../../../../composables/useScreenEntryFocus"

const props = defineProps({
  label: { type: String, default: "" },
  modelValue: { type: [String, Number, null], default: null },
  options: { type: Array, default: () => [] },
  placeholder: { type: String, default: "Select..." },
  disabled: { type: Boolean, default: false },
})

const emit = defineEmits(["update:modelValue"])

const open = ref(false)
const rootRef = ref(null)
const menuStyle = ref("")

const selectedLabel = computed(() => {
  const match = props.options.find(o => o.value === props.modelValue)
  return match ? match.label : props.placeholder
})

/**
 * A dropdown holding one option is not a decision. Showing it as a control makes
 * the player stop and consider a choice that does not exist — worst of all on a
 * first run, where every fake decision reads as something they might get wrong.
 */
const isSingleOption = computed(() => props.options.length === 1)

function positionMenu() {
  if (!rootRef.value) return
  const trigger = rootRef.value.querySelector(".start-dropdown-trigger")
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  menuStyle.value = `position:fixed;z-index:2100;top:${rect.bottom + 6}px;left:${rect.left}px;min-width:${rect.width}px;`
}

const triggerEl = () => rootRef.value?.querySelector(".start-dropdown-trigger")

function toggle() {
  if (props.disabled) return
  if (open.value) {
    close()
    return
  }
  open.value = true
  nextTick(positionMenu)
}

function close() {
  if (!open.value) return
  open.value = false
  returnFocusToOpener(triggerEl)
}

function select(value) {
  emit("update:modelValue", value)
  close()
}

function onDocClick(e) {
  if (!open.value) return
  const menu = document.querySelector(".css-start-dropdown-menu")
  const trigger = rootRef.value?.querySelector(".start-dropdown-trigger")
  if (menu && menu.contains(e.target)) return
  if (trigger && trigger.contains(e.target)) return
  close()
}

defineExpose({ isOpen: () => open.value })

onMounted(() => {
  document.addEventListener("mousedown", onDocClick)
  window.addEventListener("resize", positionMenu)
  window.addEventListener("scroll", positionMenu, true)
})

onBeforeUnmount(() => {
  document.removeEventListener("mousedown", onDocClick)
  window.removeEventListener("resize", positionMenu)
  window.removeEventListener("scroll", positionMenu, true)
})
</script>

<style lang="scss" scoped>
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/start/careerStartTheme.scss" as theme;

.start-dropdown {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.start-dropdown-static {
  padding: 0.62em 0.1em;
  font-size: 0.9em;
  color: rgba(255, 255, 255, 0.62);
}

.start-dropdown-label {
  font-weight: 600;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.75);
}

.start-dropdown-wrap {
  position: relative;
}

.start-dropdown-trigger {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  background: rgba(30, 41, 59, 0.9);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  color: #fff;
  padding: 0.62em 0.8em;
  font-size: 0.9em;
  cursor: pointer;

  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  &:hover:not(:disabled) {
    border-color: rgba(71, 85, 105, 0.8);
  }
}

.start-dropdown-text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  text-align: left;
}

.start-dropdown-chevron {
  opacity: 0.6;
  flex-shrink: 0;
}

.start-dropdown-menu {
  background: rgba(10, 14, 24, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  padding: 0.3em;
  box-shadow: 0 12px 32px rgba(0, 0, 0, 0.55);
  max-height: 16em;
  overflow-y: auto;

  /**
   * The native bar is wide, pale and nothing like the rest of this UI.
   *
   * Styled through the -webkit- pseudo-elements only: Chromium ignores those
   * entirely if scrollbar-width or scrollbar-color is also set on the element,
   * so specifying both left this at the standard "thin" bar instead.
   */
  &::-webkit-scrollbar {
    width: 6px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(30, 41, 59, 0.5);
    border-radius: 3px;
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(100, 116, 139, 0.5);
    border-radius: 3px;
  }

  &::-webkit-scrollbar-thumb:hover {
    background: rgba(100, 116, 139, 0.7);
  }
}

.start-dropdown-option {
  padding: 0.5em 0.65em;
  border-radius: 8px;
  cursor: pointer;
  color: #fff;
  font-size: 0.88em;

  &:hover,
  &:focus {
    background: theme.$start-accent-hover;
    outline: none;
  }

  &--active {
    background: theme.$start-accent-soft;
    color: theme.$start-accent-text;
  }
}
</style>
