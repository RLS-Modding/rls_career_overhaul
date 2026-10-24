<template>
  <div :class="{ 'insurance-perk-icon': !perkIconData.iconOnly, [computedColor]: computedColor }" v-bng-tooltip:top="!perkIconData.iconOnly ? perkIconData.tooltipText : null">
    <BngIcon :type="icons.shieldCheckmark" :class="{ 'glowing-icon': true, [computedColor]: computedColor }"/>
    <span v-if="!perkIconData.iconOnly" :class="{ 'small-text': true, [computedColor]: computedColor }">{{ perkIconData.smallText }}</span>
  </div>
</template>

<script setup>

import { computed } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngTooltip } from "@/common/directives"
import "./insuranceStyle.css"

const props = defineProps({
  perkIconData:{
    type: Object,
    required: true,
  },
})

const computedColor = computed(() => {
  if (props.perkIconData.isSignaturePerk !== undefined) {
    return props.perkIconData.isSignaturePerk ? 'green' : 'blue'
  }
  return props.perkIconData.color
})
</script>

<style scoped lang="scss">
/* RLS house: a plain shield glyph. In chip mode (icon + short text, e.g. the fuel discount) it is a
   house pill: Overpass-tuned padding, no circle behind the glyph, no glow. Also rendered outside
   house screens (refuel app), so every token has a literal fallback. */
.insurance-perk-icon {
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  font-style: normal !important;
  padding: 0.38em 0.55em 0.16em 0.4em;
  border-radius: 0.3em;
  background: rgba(255, 255, 255, 0.09);
  color: rgba(255, 255, 255, 0.8);
  line-height: 1;

  &.green {
    background: rgba(74, 222, 128, 0.16);
    color: var(--ok-ink, #86efac);
  }

  &.red {
    background: rgba(252, 165, 165, 0.16);
    color: var(--bad, #fca5a5);
  }
}

.small-text {
  font-size: 0.9em;
  font-weight: 700;
  white-space: nowrap;
}

.glowing-icon {
  --bng-icon-size: 1.25em;
  --bng-icon-color: currentColor;
  transform: translateY(-0.06em);

  /* the vanilla "blue" = an ordinary perk: neutral, not a colour */
  &.blue {
    --bng-icon-color: var(--faint, rgba(255, 255, 255, 0.55));
  }

  &.green {
    --bng-icon-color: var(--ok-ink, #86efac);
  }

  &.red {
    --bng-icon-color: var(--bad, #fca5a5);
  }
}
</style>
