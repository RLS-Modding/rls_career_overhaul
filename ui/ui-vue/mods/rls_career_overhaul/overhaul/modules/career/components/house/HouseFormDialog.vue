<!-- House form dialog. Same props and return contract as the game's FormDialog ({ value, formData? }),
     so openHouseFormDialog is drop-in for openFormDialog. The view gets v-model on the form model;
     the validator's message replaces the description, and buttons with disableIfInvalid wait for a
     valid form. Buttons map like HouseConfirm: cancel -> quiet (left), the confirming one -> primary. -->
<template>
  <div
    class="rls-house house-form-dialog"
    :style="{ '--form-max': maxWidth }"
    v-bng-scoped-nav="popupScopeBinding"
    v-bng-on-ui-nav:back,menu="handleCancelWithBack">
    <div class="modal form-card">
      <h3 v-if="title">{{ title }}</h3>
      <p v-if="message" class="form-message" :class="{ invalid: !formValid }">{{ message }}</p>

      <div class="form-view">
        <component :is="view" v-model="formModel" />
      </div>

      <div class="actions">
        <HouseButton
          v-for="(button, index) in orderedButtons"
          :key="index"
          :variant="variantFor(button)"
          :disabled="button.disableIfInvalid && !formValid"
          v-bng-ui-nav-focus="popupActive && button === focusButton ? 1000 : undefined"
          v-bng-focus-if="popupActive && button === focusButton"
          :bng-scoped-nav-autofocus="popupActive && button === focusButton ? true : null"
          @click="onClick(button)">
          {{ button.label }}
        </HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, useAttrs, watch } from "vue"
import { vBngFocusIf, vBngOnUiNav, vBngScopedNav, vBngUiNavFocus } from "@/common/directives"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { isCancel, playCancelSound } from "@/common/modules/popup/buttonRoles.js"
import { ACCENTS } from "@/common/components/base"
import HouseButton from "./HouseButton.vue"

const props = defineProps({
  title: String,
  description: String,
  popupActive: Boolean,
  view: { type: [Object, String], required: true },
  formValidator: { type: Function, default: () => ({ error: false }) },
  buttons: { type: Array, required: true },
  maxWidth: { type: String, default: "40em" },
})
const emit = defineEmits(["return"])
const formModel = defineModel("formModel")

const popupNavEvents = ["focus_u", "focus_d", "focus_l", "focus_r", "back", "menu", "ok"]
const navBlocker = useUINavBlocker()
watch(
  () => props.popupActive,
  active => (active ? navBlocker.allowOnly(popupNavEvents) : navBlocker.clear()),
  { immediate: true }
)

const attrs = useAttrs()
const popupScopeBinding = computed(() => ({
  scopeId: `_houseFormDialog__${attrs.__id}`,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const extrasOf = b => b?.extras || {}
const isCancelish = b => isCancel(b) || extrasOf(b).accent === ACCENTS.text || extrasOf(b).accent === ACCENTS.secondary
const orderedButtons = computed(() => {
  const list = props.buttons || []
  return [...list.filter(isCancelish), ...list.filter(b => !isCancelish(b))]
})
// the first non-cancel button confirms the form (the game's default OK carries no flags)
const primaryButton = computed(() => (props.buttons || []).find(b => !isCancelish(b)) || null)
const variantFor = b => {
  if (extrasOf(b).destructive) return "danger"
  if (isCancelish(b)) return "quiet"
  return b === primaryButton.value ? "primary" : "neutral"
}
const focusButton = computed(() => primaryButton.value || orderedButtons.value[0])

const formValid = ref(false)
const message = ref(null)
watch(
  formModel,
  () => {
    const res = props.formValidator(formModel.value) || {}
    message.value = res.error ? res.message : props.description
    formValid.value = !res.error
  },
  { immediate: true, deep: true }
)

const onClick = button => {
  const data = { value: button.value }
  if (button.emitData) data.formData = formModel.value
  emit("return", data)
}

const handleCancelWithBack = () => {
  const cancelButton = (props.buttons || []).find(isCancelish)
  if (cancelButton) {
    playCancelSound(cancelButton)
    onClick(cancelButton)
  } else {
    emit("return")
  }
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.house-form-dialog {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.form-card {
  /* the view sets its own width; maxWidth only caps it */
  width: fit-content;
  min-width: min(24em, 94vw);
  max-width: min(var(--form-max, 40em), 94vw);
  gap: 0.9em;
  padding: 1.1em 1.1em 1em;
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
}
.form-message {
  color: var(--muted);
  &.invalid {
    color: var(--bad);
  }
}
.form-view {
  min-width: 0;
}
.actions {
  display: flex;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: var(--space-2);
  > :deep(.house-button) {
    min-width: 6.5em;
  }
}
</style>
