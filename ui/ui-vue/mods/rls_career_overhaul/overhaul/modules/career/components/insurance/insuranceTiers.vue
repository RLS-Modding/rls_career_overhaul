<template>
  <div class="insurance-tiers">
    <div class="tier" v-for="tier in props.tiers" :key="tier.id">
      <div class="tier-discount" :class="{'isCurrent':tier.isCurrent}">
        <div v-if="props.showTier" class="tier-name">
          {{ $ctx_t({ txt: "ui.career.insurance.tier", context: { id: tier.id } }) }}
        </div>
        <div class="tier-value">
          {{ tier.discount * 100 }}%
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import "./insuranceStyle.css"

const props = defineProps({
  tiers: {
    type: Array,
    required: true,
  },
  showTier: {
    type: Boolean,
    default: false,
  }
})

</script>

<style scoped lang="scss">
/* RLS house: a strip of equal cells. The tier you are on is the brighter panel with accent-soft
   text; the rest stay quiet. No orange fill, no rings. */
.insurance-tiers {
  display: flex;
  flex-direction: row;
  gap: 0.3em;
  width: 100%;
}

.tier {
  flex: 1 1 0;
  min-width: 0;
  display: flex;
}

.tier-discount {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.1em;
  min-height: 2.4em;
  padding: 0.45em 0.3em 0.3em;
  border-radius: var(--radius-tile, 0.4em);
  background: var(--panel, rgba(255, 255, 255, 0.06));
  color: var(--muted, rgba(255, 255, 255, 0.72));
  text-align: center;
  line-height: 1.1;

  &.isCurrent {
    background: var(--panel-2, rgba(255, 255, 255, 0.1));
    color: var(--accent-soft, #ffb27a);
    .tier-name {
      color: inherit;
    }
  }
}

.tier-name {
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint, rgba(255, 255, 255, 0.55));
}

.tier-value {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
</style>
