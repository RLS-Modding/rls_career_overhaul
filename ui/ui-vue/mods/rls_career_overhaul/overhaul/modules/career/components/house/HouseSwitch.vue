<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Style Guide switch (.switch + .knob). Label text left, switch right when `row` is set. -->
<template>
  <label
    class="rls-house switch house-switch"
    :class="{ 'switch-row': row, disabled }"
    :tabindex="disabled ? -1 : 0"
    bng-nav-item
    v-bng-sound-class="!disabled && 'bng_click_hover_generic'"
    @keydown.enter.prevent="toggle"
    @keydown.space.prevent="toggle">
    <!-- input then knob must stay adjacent: the house .switch draws "on" with input:checked + .knob -->
    <!-- the hidden checkbox never keeps focus: clicking the label (mouse or controller A) would move
         focus onto it, and the next d-pad press then landed back on the label (one wasted press) -->
    <input
      type="checkbox"
      tabindex="-1"
      bng-no-nav="true"
      :checked="modelValue"
      :disabled="disabled"
      @change="onChange"
      @focus="returnFocus" />
    <span class="knob"></span>
    <span v-if="$slots.default" class="switch-label"><slot /></span>
  </label>
</template>

<script setup>
import { vBngSoundClass } from "@/common/directives"

const props = defineProps({
  modelValue: Boolean,
  disabled: Boolean,
  // full-width row: label on the left, switch on the right
  row: Boolean,
})
const emit = defineEmits(["update:modelValue"])

const onChange = e => emit("update:modelValue", e.target.checked)
const returnFocus = e => e.target.closest("label")?.focus({ preventScroll: true })
const toggle = () => {
  if (!props.disabled) emit("update:modelValue", !props.modelValue)
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.house-switch {
  border-radius: var(--radius-thumb);
  @include house-focus;
  /* full-width row: label left, switch right. Not ".row": that is the Style Guide list-row class
     (panel background + padding) and would draw a second box inside the line. */
  &.switch-row {
    display: flex;
    flex-direction: row-reverse;
    width: 100%;
    justify-content: space-between;
    gap: 1em;
  }
  &.disabled {
    opacity: 0.45;
    cursor: default;
  }
}
.switch-label {
  min-width: 0;
  padding-top: 0.1em; /* Overpass sits high */
  line-height: 1.25;
}
</style>
