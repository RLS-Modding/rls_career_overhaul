<template>
  <div ref="root" class="overhaul-popup" :class="{ 'rls-house': !preserveLayout }" role="dialog" aria-modal="true"
    v-bng-scoped-nav="scope" v-bng-on-ui-nav:back="cancel">
    <component :is="view" v-bind="viewProps" :popup-active="popupActive" @return="finish" />
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onUnmounted, ref, useAttrs } from "vue"
import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import { returnFocusToOpener } from "../../composables/useScreenEntryFocus.js"

const props = defineProps({ view: Object, viewProps: Object, opener: Object, popupActive: Boolean, beforeCancel: Function, preserveLayout: Boolean })
const emit = defineEmits(["return"])
const attrs = useAttrs()
const root = ref(null)
const scope = computed(() => ({
  scopeId: `overhaul-popup-${attrs.__id}`, activated: props.popupActive,
  activateOnMount: props.popupActive, preferAutoFocus: true,
  canDeactivate: () => false, trapPolicy: "always",
}))
const finish = value => { if (props.popupActive) emit("return", value) }
const cancel = event => {
  event?.stopPropagation()
  if (props.beforeCancel?.() === false) return
  finish(false)
}
let closingRoot, parentPopup, dialog
onBeforeUnmount(() => {
  closingRoot = root.value
  parentPopup = props.opener?.closest?.('.overhaul-popup')
  dialog = closingRoot?.closest("dialog")
})
onUnmounted(() => {
  // Another popup or a new screen may already own focus. Restore only ours.
  const restore = () => nextTick().then(async () => {
    const active = document.activeElement
    // Stock scope resumption can focus the parent's default before this tick.
    // Restore its actual opener, while leaving another popup's focus alone.
    if (!active?.closest?.('dialog[open], [aria-modal="true"]') || closingRoot?.contains(active)
      || (parentPopup?.contains(active) && active.closest('.overhaul-popup') === parentPopup)) {
      const restored = await returnFocusToOpener(() => props.opener)
      // Scope resumption can choose its default instead of the requested item.
      // Once it is active, restore the actual nested opener with stock focus.
      if (restored && parentPopup?.contains(document.activeElement)
        && props.opener?.isConnected) setFocus(props.opener)
    }
  })
  // Stock removes popup content before closing its native dialog. Focus requests
  // made while that dialog remains modal cannot reach the underlying opener.
  if (dialog?.open && dialog.isConnected) {
    const observer = new MutationObserver(() => {
      if (dialog.isConnected && (dialog.open || dialog.classList?.contains("popup-wrapper"))) return
      observer.disconnect()
      restore()
    })
    observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ["open"] })
  } else restore()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.overhaul-popup { pointer-events: auto; }
// Phone-local forms provide their original overlay inside the native dialog.
:global(dialog.popup-wrapper:has(.overhaul-popup-local-backdrop)::backdrop),
:global(dialog.popup-wrapper:has(.overhaul-popup-local-backdrop) > .popup-background) {
  background: transparent;
  backdrop-filter: none;
}
</style>
