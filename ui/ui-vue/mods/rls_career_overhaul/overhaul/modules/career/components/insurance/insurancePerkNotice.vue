<template>
  <div class="insurance-perk-notice">
    <InsurancePerkIcon :perkIconData="{ iconOnly: true }" />
    {{ props.perkText }}
  </div>
</template>

<script setup>

import InsurancePerkIcon from "./insurancePerkIcon.vue"


const props = defineProps({
  perkText: {
    type: String,
    required: true,
  },
})
</script>

<style scoped lang="scss">
/* RLS house callout: sits beside the coverage option (outside the popup's right edge), same
   near-black ground as the popup, saving shown in the ok ink. No gradient, no coloured border. */
.insurance-perk-notice {
  position: absolute;
  top: 50%;
  right: 0;
  z-index: 1000;
  transform: translateX(calc(100% + 2.8em)) translateY(-50%);
  transform-origin: right center;
  pointer-events: none;

  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 0.45em;
  padding: 0.6em 0.85em 0.45em 0.7em;
  border-radius: var(--radius-panel, 0.5em);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 10px 26px rgba(0, 0, 0, 0.45);

  color: var(--ok-ink, #86efac);
  font-size: 0.92em;
  font-weight: 700;
  line-height: 1.2;
  white-space: nowrap;

  :deep(.glowing-icon) {
    --bng-icon-color: var(--ok-ink, #86efac);
  }

  /* small pointer back to the option it belongs to, in the callout's own ground */
  &::before {
    content: "";
    position: absolute;
    left: 0;
    top: 50%;
    width: 0.6em;
    height: 0.6em;
    background: #1a1a1c;
    transform: translateX(-50%) translateY(-50%) rotate(45deg);
  }
}
</style>
