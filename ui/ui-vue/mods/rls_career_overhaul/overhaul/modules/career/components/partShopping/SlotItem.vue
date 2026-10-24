<template>
  <AccordionItem
    v-bng-tooltip:right="slotPathTooltip(nicePath)"
    :static="isStatic"
    :expanded="expanded"
    :primary-action="() => openSlot()"
    :expand-on-context="false"
    navigable
    expand-hint-inline
    primary-hint-inline
    @expanded="itemExpanded"
    @focus="onFocus"
    @unfocus="onUnfocus"
    @selected="selectSlot"
  >
    <template #caption>
      <div v-if="partShoppingStore.slotToScrollTo === path" class="highlighted">
      </div>
      <span class="slot-path" v-if="nicePath">
        {{ compactSlotPath(nicePath) }}
      </span>
      <span ref="slotItem" class="slot-name">
        {{ slotNiceName }}
      </span>
    </template>
    <template #controls>
      <HouseButton
        bng-no-nav="true"
        class="buy-button"
        compact
        @click="openSlot()"
        v-bng-tooltip:top="nicePath ? null : partNiceName"
        :style="{backgroundColor: partShoppingStore.slotToScrollTo && partShoppingStore.slotToScrollTo == path ? 'rgba(255,255,255,0.18)' : '' }"
      >
        <span class="buy-button-label">
          {{ partNiceName ? partNiceName : "-" }}
        </span>
      </HouseButton>
    </template>
    <slot></slot>
  </AccordionItem>
</template>

<script setup>
import { ref, computed, onMounted, watch, nextTick } from "vue"
import { lua } from "@/bridge"
import { vBngTooltip } from "@/common/directives"
import { compactSlotPath, slotPathTooltip } from "../../utils/partSlotBreadcrumb.js"
import { HouseButton } from "../house/index.js"
import { AccordionItem } from "@/common/components/utility"
import { usePartShoppingStore } from "../../stores/partShoppingStore"
import useControls from "@/services/controls"

const slotItem = ref()
const focused = ref(false)

const props = defineProps({
  static: Boolean,
  expanded: Boolean,
  path: String,
  nicePath: String,
  slotNiceName: String,
  partNiceName: String
})

const partShoppingStore = usePartShoppingStore()

const isStatic = computed(() => props.static)

const scrollIntoViewIfTarget = () => {
  const caption = slotItem.value?.closest?.(".bng-accitem-caption")
  const isTarget = !!partShoppingStore.slotToScrollTo && props.path === partShoppingStore.slotToScrollTo
  // Controller: back from a slot's parts lands on that slot. The scope (preferAutoFocus) takes its
  // autofocus mark on route entry; a pad that already landed elsewhere is moved over as well.
  if (caption) {
    if (isTarget && partShoppingStore.activePanel === "slots") caption.setAttribute("bng-scoped-nav-autofocus", "")
    else caption.removeAttribute("bng-scoped-nav-autofocus")
  }
  if (!isTarget) return
  if (!slotItem.value) return
  // Skip while hidden (v-show); store re-triggers on return to slots.
  if (partShoppingStore.activePanel !== "slots") return
  slotItem.value.scrollIntoView({ block: "center" })
  if (caption && useControls().focusIfController && document.activeElement !== caption) caption.focus()
}

const scheduleScrollIntoView = () => {
  nextTick(() => {
    requestAnimationFrame(() => {
      requestAnimationFrame(scrollIntoViewIfTarget)
    })
  })
}

onMounted(scheduleScrollIntoView)

// Store clears then re-sets this on back so keep-alive rows always re-scroll.
watch(
  () => partShoppingStore.slotToScrollTo,
  scheduleScrollIntoView
)

const itemExpanded = val => {
  partShoppingStore.setSlotExpanded(props.path, val)
}

const onFocus = () => {
  focused.value = true
}

const onUnfocus = () => {
  focused.value = false
}

const openSlot = () =>
  lua.extensions.ui_router.navigate("overhaul.computer.partShopping.category.slot", {
    category: partShoppingStore.category,
    slotPath: props.path,
  })

const selectSlot = () => {
  openSlot()
}
</script>

<style lang="scss" scoped>
// House tokens come from the .rls-house panel in PartShoppingMain.
.bng-accitem .buy-button.house-button {
  max-width: 13em !important;
  min-height: unset;
  margin: 0 0 0 0.35em;
  padding: 0.45em 0.7em 0.32em;
  border-radius: var(--radius-tile, 0.4em);
  color: var(--muted, rgba(255, 255, 255, 0.72));
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.2;
  &:hover:not(:disabled),
  &.focus-visible {
    color: #fff;
  }
  .buy-button-label {
    display: inline-block;
    max-width: 100%;
    white-space: normal;
    overflow-wrap: anywhere;
    text-align: right;
  }
}
.slot-name,
.slot-path {
  display: block;
  max-width: 100%;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
}
.slot-name {
  font-weight: 600;
}
.slot-path {
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-size: 0.7em;
  line-height: 1.25;
}
:deep() {
  .bng-accitem-caption-content {
    overflow: hidden !important;
    z-index: 0;
  }
  .bng-accitem-caption-controls {
    overflow: visible !important;
    z-index: 1;
  }
  .bng-accitem-caption-expander {
    z-index: 1;
  }
}

// Expanded / selected rows: slightly brighter panel + accent-soft text, no grey-blue fill or orange gradient.
.bng-accitem.bng-accitem.bng-accitem-expanded > :deep(.bng-accitem-caption) {
  background-color: var(--panel-2, rgba(255, 255, 255, 0.1));
}
.bng-accitem.bng-accitem.bng-accitem-selected > :deep(.bng-accitem-caption) {
  background-image: none !important;
  background-color: var(--panel-2, rgba(255, 255, 255, 0.1));
  .slot-name {
    color: var(--accent-soft, #ffb27a);
  }
}

// Return-to-slot marker: the slot you came back from keeps a slightly brighter panel;
// an accent tint flashes over it and fades out (opacity only). No side bar.
@keyframes slot-flash {
  0% { opacity: 1; }
  60% { opacity: 1; }
  100% { opacity: 0; }
}

.highlighted {
  position: absolute;
  top: 0;
  right: 0;
  left: 0;
  bottom: 0;
  overflow: hidden;
  z-index: -1;
  border-radius: var(--radius-panel, 0.5em);
  background: var(--panel-2, rgba(255, 255, 255, 0.1));
  pointer-events: none;
  &::after {
    content: "";
    position: absolute;
    inset: 0;
    background: var(--accent-ink, rgba(255, 102, 0, 0.25));
    opacity: 0;
    animation: slot-flash 1s ease-out;
  }
}
</style>
