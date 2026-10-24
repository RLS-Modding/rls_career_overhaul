<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- House text prompt popup. Open it with openHousePrompt() from ./index.js (same contract as the
     game's openPrompt: resolves to the entered text, or false on cancel). -->
<template>
  <div
    class="rls-house house-prompt"
    v-bng-scoped-nav="popupScopeBinding"
    v-bng-on-ui-nav:back,menu="cancel">
    <div class="modal prompt-card">
      <h3 v-if="title">{{ title }}</h3>
      <p v-if="message">{{ message }}</p>

      <div class="field-wrap" :class="{ invalid: showError }">
        <input
          ref="inputEl"
          v-model="text"
          v-bng-text-input
          class="field"
          type="text"
          :maxlength="maxLength"
          :placeholder="placeholder"
          spellcheck="false"
          bng-nav-item
          :bng-scoped-nav-autofocus="popupActive ? true : null"
          @keyup.enter="confirm" />
        <button v-if="text" type="button" class="field-clear" tabindex="-1" aria-label="Clear" @click="clearText">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
      </div>
      <div class="field-foot">
        <span class="error">{{ showError ? errorMessage : "" }}</span>
        <span v-if="maxLength" class="count">{{ Array.from(text).length }} / {{ maxLength }}</span>
      </div>

      <div class="actions">
        <HouseButton variant="quiet" @click="cancel">{{ cancelLabel }}</HouseButton>
        <HouseButton variant="primary" :disabled="!valid" @click="confirm">{{ confirmLabel }}</HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, nextTick, ref, useAttrs, watch } from "vue"
import { vBngOnUiNav, vBngScopedNav, vBngTextInput } from "@/common/directives"
import HouseButton from "./HouseButton.vue"

const props = defineProps({
  popupActive: Boolean,
  title: String,
  message: String,
  defaultValue: { type: String, default: "" },
  placeholder: String,
  maxLength: Number,
  validate: Function,
  errorMessage: String,
  confirmLabel: { type: String, default: "Save" },
  cancelLabel: { type: String, default: "Cancel" },
})
const emit = defineEmits(["return"])

const attrs = useAttrs()
const popupScopeBinding = computed(() => ({
  scopeId: `_housePrompt__${attrs.__id}`,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const text = ref(props.defaultValue || "")
const inputEl = ref(null)
const touched = ref(false)
watch(text, () => (touched.value = true))

const valid = computed(() => (props.validate ? !!props.validate(text.value) : text.value.trim().length > 0))
const showError = computed(() => touched.value && !valid.value && !!props.errorMessage)

const confirm = () => {
  if (!valid.value) {
    touched.value = true
    return
  }
  emit("return", text.value)
}
const cancel = () => emit("return", false)
const clearText = () => {
  text.value = ""
  inputEl.value?.focus()
}

watch(
  () => props.popupActive,
  async active => {
    if (!active) return
    await nextTick()
    inputEl.value?.focus()
    inputEl.value?.select()
  },
  { immediate: true }
)
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.house-prompt {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.prompt-card {
  width: min(26em, 92vw);
  gap: var(--space-2);
  padding: 1.1em 1.1em 1em;
  background: #1a1a1c;
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }
  p {
    margin-bottom: var(--space-1);
  }
}

.field-wrap {
  position: relative;
  .field {
    padding-right: 2.4em;
    font-weight: 600;
  }
  .field:focus {
    outline: none;
    box-shadow: var(--focus);
  }
  &.invalid .field {
    border-color: rgba(252, 165, 165, 0.6);
  }
}
.field-clear {
  appearance: none;
  position: absolute;
  top: 50%;
  right: 0.55em;
  display: grid;
  place-items: center;
  width: 1.45em;
  height: 1.45em;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: var(--panel-2);
  color: var(--muted);
  transform: translateY(-50%);
  cursor: pointer;
  &:hover {
    background: var(--panel-hover);
    color: #fff;
  }
  svg {
    width: 0.7em;
    height: 0.7em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.6;
    stroke-linecap: round;
  }
}

.field-foot {
  display: flex;
  justify-content: space-between;
  gap: 1em;
  min-height: 1.1em;
  font-size: 0.8em;
  font-weight: 600;
  .error {
    color: var(--bad);
  }
  .count {
    margin-left: auto;
    color: var(--faint);
    font-variant-numeric: tabular-nums;
  }
}

.actions {
  display: flex;
  justify-content: flex-end;
  gap: var(--space-2);
  margin-top: var(--space-1);
  > :deep(.house-button) {
    min-width: 6.5em;
  }
}
</style>
