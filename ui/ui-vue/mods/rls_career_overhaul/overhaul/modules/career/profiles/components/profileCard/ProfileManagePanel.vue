<template>
  <div v-if="menu === MENU_ITEMS.RENAME" class="pc-manage-section">
    <div class="pc-section-head">
      <div class="pc-section-title">{{ $ctx_t("ui.career.rename") }}</div>
      <div v-if="!hero" class="pc-section-sub">{{ originalName }}</div>
    </div>
    <BngInput
      :modelValue="name"
      :maxlength="maxLength"
      :validate="validate"
      :errorMessage="nameError"
      externalLabel="Save Name"
      @update:modelValue="value => emit('update:name', value)"
      @blur="onInputBlur"
      @keydown.enter.prevent />
    <div class="pc-btns">
      <button ref="startButton" class="pc-btn pc-btn--primary" :disabled="nameError !== null || name === originalName" @click="emit('save-name')">Save</button>
      <button ref="cancelButton" class="pc-btn pc-btn--secondary" @click="emit('back')">Back</button>
    </div>
  </div>
  <div v-else-if="menu === MENU_ITEMS.DELETE" class="pc-manage-section">
    <div class="pc-section-head">
      <div class="pc-section-title pc-section-title--danger">{{ $ctx_t("ui.career.delete") }}</div>
      <div v-if="!hero" class="pc-section-sub">{{ originalName }}</div>
    </div>
    <span class="pc-delete-prompt">{{ $ctx_t("ui.career.deletePrompt") }}</span>
    <span class="pc-delete-prompt">{{ $ctx_t("ui.career.deleteCannotUndo") }}</span>
    <div class="pc-btns">
      <button class="pc-btn pc-btn--secondary" v-bng-focus-if="true" bng-scoped-nav-autofocus @click="emit('back')">{{ $ctx_t("ui.common.cancel") }}</button>
      <button class="pc-btn pc-btn--danger" @click="emit('confirm-delete')">{{ $ctx_t("ui.common.delete") }}</button>
    </div>
  </div>
  <div v-else class="pc-manage-section">
    <div class="pc-section-head">
      <div class="pc-section-title">Manage</div>
      <div v-if="!hero" class="pc-section-sub">{{ originalName }}</div>
    </div>
    <!-- Rows, not a stack of identical grey buttons: each one says what it
         does to the save, and the destructive one does not look like the
         other two. -->
    <div class="pc-actions">
      <button class="pc-action" type="button" :disabled="active" @click="emit('open-rename')">
        <span class="pc-action-label">{{ $ctx_t("ui.career.rename") }}</span>
        <span class="pc-action-desc">Change the name shown on this card</span>
      </button>
      <button
        v-bng-sound-class="'bng_click_generic'"
        class="pc-action"
        type="button"
        :disabled="incompatibleVersion"
        @click="emit('backup')">
        <span class="pc-action-label">Backup</span>
        <span class="pc-action-desc">Copy everything into a new named save</span>
      </button>
      <button class="pc-action pc-action--danger" type="button" :disabled="active" @click="emit('open-delete')">
        <span class="pc-action-label">{{ $ctx_t("ui.career.delete") }}</span>
        <span class="pc-action-desc">{{ active ? "Cannot delete the save you are playing" : "Remove this save and all of its progress" }}</span>
      </button>
    </div>
    <div class="pc-btns pc-btns--back">
      <button class="pc-btn pc-btn--secondary" @click="emit('back')">Back</button>
    </div>
  </div>
</template>

<script setup>
import { nextTick, ref } from "vue"
import { BngInput } from "@/common/components/base"
import { vBngFocusIf, vBngSoundClass } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import { MENU_ITEMS } from "./menuItems.js"

const props = defineProps({
  /** null for the menu, or one of MENU_ITEMS for a sub-view. */
  menu: { type: String, default: null },
  hero: Boolean,
  active: Boolean,
  incompatibleVersion: Boolean,
  originalName: { type: String, default: "" },
  /** The rename field's text. The card owns it so a rename survives this panel being remounted. */
  name: { type: String, default: "" },
  nameError: { type: String, default: null },
  maxLength: Number,
  /** The card's name check, handed to BngInput, which runs it as the user types. */
  validate: Function,
})

const emit = defineEmits(["open-rename", "open-delete", "backup", "back", "save-name", "confirm-delete", "update:name"])

const startButton = ref(null)
const cancelButton = ref(null)

// Leaving the field on an unusable or unchanged name lands on Back, so the Save button is not the default.
function onInputBlur() {
  const focusButton = props.nameError || props.name === props.originalName ? cancelButton : startButton
  if (focusButton.value) nextTick(() => setFocus(focusButton.value))
}
</script>

<style lang="scss" scoped>
.pc-actions {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.pc-action {
  display: flex;
  flex-direction: column;
  gap: 0.05em;
  width: 100%;
  text-align: left;
  border: 0;
  border-radius: 8px;
  padding: 0.45em 0.6em;
  background: #1e2533;
  color: #f3f4f6;
  font-family: inherit;
  cursor: pointer;
  transition: background 0.12s ease, box-shadow 0.12s ease, transform 0.06s ease;

  &:hover:not(:disabled) {
    background: #2c3548;
    box-shadow: 0 0 0 1px rgba(148, 163, 184, 0.55);
  }

  &:active:not(:disabled) {
    background: #161c27;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }

  &.focus-visible {
    outline: 2px solid #ff7a1a;
    outline-offset: 2px;
  }

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.pc-action--danger {
  background: rgba(127, 29, 29, 0.35);

  .pc-action-label {
    color: #fca5a5;
  }

  &:hover:not(:disabled) {
    background: rgba(153, 27, 27, 0.55);
    box-shadow: 0 0 0 1px rgba(248, 113, 113, 0.6);
  }

  &:active:not(:disabled) {
    background: rgba(87, 20, 20, 0.7);
  }
}

.pc-action-label {
  font-size: 0.9em;
  font-weight: 600;
}

.pc-action-desc {
  font-size: 0.7em;
  line-height: 1.25;
  color: rgba(255, 255, 255, 0.5);
}

.pc-delete-prompt {
  font-size: 0.88em;
  padding: 0.5em 0;
}
</style>
