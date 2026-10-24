<!-- House confirmation / message popup. Same props as the game's Confirmation popup (title, HTML or
     bbcode message, buttons [{ label, value, extras: { default, cancel, confirm, destructive, accent,
     disabled } }]) so openHouseConfirmation / openHouseMessage are drop-in for openConfirmation /
     openMessage. Buttons map to house variants: destructive -> danger, cancel -> quiet, the default /
     confirm button -> primary (one orange), anything else neutral. Primary sits on the right. -->
<template>
  <div
    class="rls-house house-confirm"
    v-bng-scoped-nav="popupScopeBinding"
    v-bng-on-ui-nav:back,menu="cancel">
    <div class="modal confirm-card">
      <h3 v-if="title">{{ title }}</h3>
      <div class="confirm-body" v-if="messageIsComponent"><component :is="message.component" v-bind="message.props" /></div>
      <div class="confirm-body" v-else-if="message"><DynamicComponent :template="message" bbcode /></div>

      <div class="actions">
        <HouseButton
          v-for="(button, index) in orderedButtons"
          :key="index"
          :variant="variantFor(button)"
          :disabled="isDisabled(button)"
          v-bng-ui-nav-focus="popupActive && button === focusButton ? 1000 : undefined"
          v-bng-focus-if="popupActive && button === focusButton"
          :bng-scoped-nav-autofocus="popupActive && button === focusButton ? true : null"
          @click="emit('return', button.value)">
          {{ button.label }}
        </HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, unref, useAttrs, watch } from "vue"
import { DynamicComponent } from "@/common/components/utility"
import { vBngFocusIf, vBngOnUiNav, vBngScopedNav, vBngUiNavFocus } from "@/common/directives"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { ACCENTS } from "@/common/components/base"
import { playCancelSound } from "@/common/modules/popup/buttonRoles.js"
import HouseButton from "./HouseButton.vue"

const props = defineProps({
  popupActive: Boolean,
  title: String,
  message: { type: [String, Object], default: "" },
  buttons: { type: Array, default: () => [] },
})
const emit = defineEmits(["return"])

const attrs = useAttrs()
const popupScopeBinding = computed(() => ({
  scopeId: `_houseConfirm__${attrs.__id}`,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const navBlocker = useUINavBlocker()
watch(
  () => props.popupActive,
  active => (active ? navBlocker.allowNavigationOnly() : navBlocker.clear()),
  { immediate: true }
)

const messageIsComponent = computed(() => props.message && typeof props.message === "object" && props.message.component)

const extrasOf = b => b?.extras || {}
const isCancelish = b => !!(extrasOf(b).cancel || extrasOf(b).accent === ACCENTS.text || extrasOf(b).accent === ACCENTS.secondary)
const isFlaggedPrimary = b => !isCancelish(b) && !!(extrasOf(b).confirm || extrasOf(b).default || extrasOf(b).accent === ACCENTS.main)
// unflagged buttons are orange in the game's popup, so with no flags the first non-cancel button is the primary
const implicitPrimary = computed(() => {
  const list = props.buttons || []
  return list.some(isFlaggedPrimary) ? null : list.find(b => !isCancelish(b)) || null
})
const isPrimaryish = b => isFlaggedPrimary(b) || b === implicitPrimary.value
const isDestructive = b => {
  const x = extrasOf(b)
  return !!(x.destructive || x.accent === ACCENTS.attention || x.accent === ACCENTS.destructive)
}

// cancel-type buttons first, others, then the primary on the right
const orderedButtons = computed(() => {
  const list = props.buttons || []
  const cancels = list.filter(isCancelish)
  const primaries = list.filter(b => !isCancelish(b) && isPrimaryish(b))
  const rest = list.filter(b => !isCancelish(b) && !isPrimaryish(b))
  return [...cancels, ...rest, ...primaries]
})

const variantFor = b => {
  if (isDestructive(b)) return "danger"
  if (isCancelish(b)) return "quiet"
  if (isPrimaryish(b)) return "primary"
  return "neutral"
}
const isDisabled = b => !!unref(extrasOf(b).disabled)

// focus: a destructive choice focuses Cancel; otherwise the primary, else the first button
const focusButton = computed(() => {
  const list = orderedButtons.value
  if (list.some(isDestructive)) return list.find(b => isCancelish(b) && !isDisabled(b)) || list.find(b => !isDisabled(b))
  return list.find(isPrimaryish) || list.find(b => extrasOf(b).default) || list[0]
})

// Back/Menu: like the game's Confirmation, only a cancel-type button can be backed out of (with the
// native cancel sound); an OK-only message ignores Back so callers never get a value they didn't offer.
const cancel = () => {
  const c = (props.buttons || []).find(isCancelish)
  if (!c) return
  playCancelSound(c)
  emit("return", c.value)
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.house-confirm {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.confirm-card {
  width: min(28em, 92vw);
  gap: var(--space-3);
  padding: 1.1em 1.1em 1em;
  background: #1a1a1c;
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
}
.confirm-body {
  color: var(--muted);
  font-size: 0.95em;
  font-weight: 600;
  line-height: 1.45;
  :deep(strong),
  :deep(b) {
    color: #fff;
  }
}
.actions {
  display: flex;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: var(--space-2);
  margin-top: var(--space-1);
  > :deep(.house-button) {
    min-width: 6.5em;
  }
}
</style>
