<!-- Owns the one disclosure look used across Motorsport screens. HouseAccordion owns input and focus. -->
<template>
  <HouseAccordion :id="id" class="ms-fold" :class="{ open: modelValue, flat }" :title="title" :model-value="modelValue" @update:model-value="value => emit('update:modelValue', value)">
    <template #title="{ expanded }">
      <BngIcon v-if="icon" class="ms-fold-icon" :type="icons[icon] || icon" aria-hidden="true" />
      <span class="ms-fold-title">{{ title }}</span>
      <span v-if="meta || $slots.meta" class="ms-fold-meta"><slot name="meta">{{ meta }}</slot></span>
      <span class="ms-fold-chevron" :class="{ open: expanded }" aria-hidden="true">›</span>
    </template>
    <slot />
  </HouseAccordion>
</template>

<script setup>
import { BngIcon, icons } from '@/common/components/base'
import { HouseAccordion } from '../house/index.js'

defineProps({ id: { type: String, required: true }, title: { type: String, default: '' }, meta: { type: String, default: '' }, icon: { type: String, default: '' }, modelValue: Boolean, flat: Boolean })
const emit = defineEmits(['update:modelValue'])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
// Spacing comes from the --ms-* scale set by the Motorsport screen that hosts the fold.
.ms-fold { border: 1px solid var(--line); border-radius: var(--radius-panel); background: rgba(255, 255, 255, 0.03); overflow: hidden; }
.ms-fold.flat { border: 0; background: transparent; border-radius: 0; }
.ms-fold > :deep(.house-button) { width: 100%; min-height: 0; justify-content: flex-start; padding: var(--ms-row, .45em) var(--ms-pad, var(--inset)); border-radius: 0; background: transparent; text-align: left; font-size: 1em; }
.ms-fold > :deep(.house-button:hover) { background: rgba(255, 255, 255, 0.04); }
.ms-fold > :deep(.house-button .btn-label) { display: flex; align-items: center; gap: var(--ms-stack, var(--space-2)); width: 100%; white-space: normal; }
.ms-fold :deep(.accordion-body) { max-height: none; overflow: visible; display: grid; gap: var(--ms-stack, var(--space-2)); padding: 0 var(--ms-pad, var(--inset)) var(--ms-pad, var(--inset)); }
.ms-fold.flat :deep(.accordion-body) { padding: 0 0 var(--ms-stack, var(--space-2)); }
.ms-fold-icon { --bng-icon-color: var(--accent); color: var(--accent); font-size: var(--ms-icon, 1.1em); flex: 0 0 auto; }
.ms-fold-title { flex: 1 1 auto; min-width: 0; font-size: 1em; font-weight: 700; line-height: 1.2; }
.ms-fold-meta { flex: 0 0 auto; font-size: .8em; font-weight: 600; color: var(--faint); white-space: nowrap; font-variant-numeric: tabular-nums; }
.ms-fold-chevron { display: inline-flex; align-items: center; justify-content: center; flex: 0 0 1em; height: 1em; color: var(--accent); font-size: 1.25em; line-height: 1; transition: transform .12s ease; }
.ms-fold-chevron.open { transform: rotate(90deg); }
// Controller and keyboard focus: no outer ring (the fold clips it into a heavy frame). The fold's own border turns
// orange, the header takes a faint tint and the title follows, so the focused fold reads at a glance.
.ms-fold { transition: border-color .12s ease; }
.ms-fold:has(> .house-button.focus-visible) { border-color: rgba(255, 102, 0, 0.55); }
// overhaulFocus.scss draws a 2px inset outline on every focused phone control with !important; the fold replaces it.
.ms-fold > :deep(.house-button.focus-visible) { outline: none !important; box-shadow: none !important; background: rgba(255, 102, 0, 0.1); }
.ms-fold > :deep(.house-button.focus-visible::before) { display: none !important; }
.ms-fold > :deep(.house-button.focus-visible) .ms-fold-title { color: var(--accent-soft, #ffb27a); }
.ms-fold.flat:has(> .house-button.focus-visible) { border-color: transparent; }
</style>
