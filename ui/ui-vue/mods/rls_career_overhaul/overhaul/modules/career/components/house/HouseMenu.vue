<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Style Guide dropdown (.menu / .menu-btn / .menu-list / .menu-item). Never a native select.
     items: [{ value, label, meta?, disabled? }]  (same shape BngDropdown takes). -->
<template>
  <div ref="root" class="rls-house menu house-menu" :class="{ open, compact, up: openUp, disabled }" @focusout="onFocusOut" @keydown="onKeydown">
    <button
      ref="btn"
      type="button"
      class="menu-btn"
      :disabled="disabled"
      aria-haspopup="listbox"
      :aria-expanded="open"
      v-bind="navAttrs(disabled)"
      v-bng-sound-class="!disabled && 'bng_click_hover_generic'"
      @click="toggle">
      <span class="menu-value">{{ selected ? selected.label : placeholder }}</span>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
    </button>
    <!-- controller: the open list is its own scope (d-pad stays inside and wraps top/bottom), B closes it
         and gives focus back to the trigger instead of leaving the screen -->
    <Teleport to="body" :disabled="!teleport">
    <div
      ref="list"
      v-if="open"
      :style="teleport ? listStyle : undefined"
      @focusout="onFocusOut"
      @keydown="onKeydown"
      class="rls-house menu-list house-menu-list"
      :class="{ scrolls: items.length > SCROLL_AFTER }"
      role="listbox"
      v-bng-scoped-nav="listScope"
      v-bng-on-ui-nav:back,menu="onNavBack"
      v-bng-ui-nav-scroll>
      <button
        v-for="(item, idx) in items"
        :key="item.value"
        type="button"
        class="menu-item"
        role="option"
        :data-idx="idx"
        :class="{ selected: item.value === modelValue }"
        :aria-selected="item.value === modelValue"
        :disabled="item.disabled"
        v-bind="navAttrs(item.disabled)"
        @click="pick(item)">
        {{ item.label }}
        <span v-if="item.meta" class="meta">{{ item.meta }}</span>
      </button>
    </div>
    </Teleport>
  </div>
</template>

<script setup>
import { useDropdown } from "../../composables/useDropdown.js"
import { returnFocusToOpener } from "../../composables/useScreenEntryFocus"
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue"
import { vBngSoundClass, vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"

const props = defineProps({
  modelValue: [String, Number, Boolean],
  items: { type: Array, default: () => [] },
  placeholder: { type: String, default: "Choose…" },
  compact: Boolean,
  teleport: Boolean,
  disabled: Boolean,
  active: { type: Boolean, default: true },
})
const emit = defineEmits(["update:modelValue", "change"])

const root = ref(null)
const btn = ref(null)
const list = ref(null)
const listStyle = ref({})
const contains = target => root.value?.contains(target) || list.value?.contains(target)
// disabled triggers / options leave controller navigation: crossfire would still step onto them and
// strand the d-pad (it never filters `disabled`)
const navAttrs = isDisabled => (isDisabled ? { "bng-nav-item": "", "bng-no-nav": "true" } : { "bng-nav-item": "" })
let disposed = false
const open = ref(false)
const openUp = ref(false)

const selected = computed(() => props.items.find(i => i.value === props.modelValue))

// short lists never scroll: the game's focus frame sits just outside the focused item, and in a
// scroll box that overflow alone was enough to show scrollbars under "100 per page"
const SCROLL_AFTER = 8

const onDocDown = e => {
  if (root.value && !contains(e.target)) close(false)
}

const positionList = () => {
  if (!props.teleport || !btn.value || !list.value) return
  const rect = btn.value.getBoundingClientRect()
  const width = Math.min(Math.max(rect.width, 160), window.innerWidth - 16)
  const height = Math.min(list.value.scrollHeight, window.innerHeight - 16)
  const below = window.innerHeight - rect.bottom - 8
  listStyle.value = {
    position: "fixed", zIndex: 10000, width: `${width}px`, minWidth: "0",
    fontSize: getComputedStyle(btn.value).fontSize,
    left: `${Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8))}px`,
    top: `${Math.max(8, below >= height ? rect.bottom + 8 : rect.top - height - 8)}px`,
    bottom: "auto", maxHeight: `${window.innerHeight - 16}px`, overflowY: "auto",
  }
}
const clipBottom = () => {
  let bottom = window.innerHeight
  for (let el = root.value?.parentElement; el && el !== document.body; el = el.parentElement) {
    if (getComputedStyle(el).overflowY !== "visible") bottom = Math.min(bottom, el.getBoundingClientRect().bottom)
  }
  return bottom
}

const { toggle } = useDropdown({
  open,
  canOpen: () => !disposed && props.active !== false && !props.disabled && props.items.some(item => !item.disabled),
  closeOnToggle: () => close(false),
  positionTiming: "caller",
  beforeOpen: () => {
    // Ancestor clipping decides upward opening, including cards with hidden overflow.
    const rect = btn.value?.getBoundingClientRect()
    openUp.value = !!rect && clipBottom() - rect.bottom < Math.min(260, props.items.length * 40 + 20)
  },
  onOpen: () => {
    document.addEventListener("mousedown", onDocDown, true)
    document.addEventListener("scroll", positionList, true)
    window.addEventListener("resize", positionList)
  },
  afterOpen: () => {
    if (disposed || props.active === false) return
    let index = props.items.findIndex(item => item.value === props.modelValue && !item.disabled)
    if (index < 0) index = props.items.findIndex(item => !item.disabled)
    positionList();
    (list.value || root.value)?.querySelector(`.menu-item[data-idx="${index}"]`)?.focus()
  },
})

// the list is a container scope: focus cannot leave it, and back/menu never bubble up to the screen
// (which would close the screen or cancel a purchase). Same shape as the game's container escape guard.
// ok stays too: the scope already clicks the focused item, and bubbling made the global handler click it
// a second time.
const listScope = {
  type: "container",
  activateOnMount: props.teleport,
  trapPolicy: props.teleport ? "always" : undefined,
  canActivate: () => !disposed && props.active !== false,
  canDeactivate: () => !props.teleport || !open.value,
  preventNavigationEscape: ["top", "bottom", "left", "right"],
  canBubbleEvent: event => !["back", "menu", "ok"].includes(event?.detail?.name),
}

const onNavBack = event => {
  event?.stopPropagation()
  close(true)
  return false
}

// focus moved somewhere outside the menu (d-pad elsewhere, a click on the page): close quietly
const onFocusOut = event => {
  if (!open.value) return
  const next = event.relatedTarget
  if (next && contains(next)) return
  nextTick(() => {
    if (open.value && !contains(document.activeElement)) close(false)
  })
}

const close = (refocus = false) => {
  const wasOpen = open.value
  open.value = false
  document.removeEventListener("mousedown", onDocDown, true)
  document.removeEventListener("scroll", positionList, true)
  window.removeEventListener("resize", positionList)
  if (!wasOpen) return
  // Wait until the teleported scope is removed before resuming its owning screen.
  if (props.teleport) returnFocusToOpener(() => {
    if (disposed || props.active === false) return null
    const active = document.activeElement
    return !refocus && active !== document.body && !contains(active) ? active : btn.value
  })
  if (refocus) nextTick(() => { if (!disposed && props.active !== false) btn.value?.focus() })
}

const pick = item => {
  if (item.disabled) return
  if (item.value !== props.modelValue) {
    emit("update:modelValue", item.value)
    emit("change", item.value)
  }
  close(true)
}

const onKeydown = event => {
  if (event.key === "Escape" && open.value) {
    event.preventDefault(); event.stopPropagation(); close(true); return
  }
  if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return
  event.preventDefault(); event.stopPropagation()
  if (!open.value) { toggle(); return }
  const options = [...(list.value?.querySelectorAll(".menu-item:not([disabled])") || [])]
  const index = options.indexOf(document.activeElement)
  const next = event.key === "Home" ? 0 : event.key === "End" ? options.length - 1
    : (index + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length
  options[next]?.focus()
}

watch(() => props.disabled, d => d && close(false))
watch(() => props.active, active => { if (active === false) close(false) })
onBeforeUnmount(() => { disposed = true; close(false) })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.house-menu {
  min-width: 0;
  &.disabled {
    opacity: 0.45;
  }
  &.up .menu-list {
    top: auto;
    bottom: calc(100% + 0.45em);
  }
}
.menu-btn {
  font-weight: 700;
  &:disabled {
    cursor: default;
  }
}
.menu-value {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  // room for descenders ("g", "y") inside the clip box without changing the trigger's height
  padding-bottom: 0.15em;
  margin-bottom: -0.15em;
}
.house-menu-list {
  padding: 0.5em;
  overflow: visible;
}
.menu-list.scrolls {
  max-height: 16em;
  overflow-x: hidden;
  overflow-y: auto;
  // slim house scrollbar; no scrollbar-width / scrollbar-color, which make Chromium 121+ ignore these rules
  &::-webkit-scrollbar { width: 0.45em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
  }
}
.menu-item {
  white-space: nowrap;
}
.menu-item.focus-visible {
  outline: none;
  background: rgba(255, 255, 255, 0.08);
}
.menu-item:disabled {
  opacity: 0.45;
  cursor: default;
}
</style>
