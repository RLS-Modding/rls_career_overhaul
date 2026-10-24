<template>
  <div class="insurance-perks-container">
    <div
    v-for="perk in sortedPerks"
    :key="perk.id"
    class="insurance-perk"
    :class="{highlighted: perk.isSignaturePerk, 'no-insurance': insuranceData.id === -1}"
    :title="noDescription ? perk.description : null"
    >
      <div class="left">
        <div class="insurance-perk-icon-wrapper">
          <InsurancePerkIcon v-if="insuranceData.id !== -1" :perkIconData="{ iconOnly: true, isSignaturePerk: perk.isSignaturePerk && perk.isSignaturePerk || false }"/>
          <span v-else class="minus-glyph">-</span>
        </div>
        <div class="insurance-perk-texts">
          <div class="insurance-perk-intro">
            {{ perk.intro }}
          </div>
          <div v-if="!noDescription" class="insurance-perk-description" :title="perk.description">
            {{ perk.description }}
          </div>
        </div>
      </div>
      <div v-if="perk.isSignaturePerk" class="signature-perk-wrapper">
        <div class="signature-perk">
          {{ $t("ui.career.insurance.signaturePerk") }}
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import InsurancePerkIcon from "./insurancePerkIcon.vue"
import "./insuranceStyle.css"

const props = defineProps({
  insuranceData: Object,
  noDescription: Boolean,
})

const sortedPerks = computed(() => {
  if (!props.insuranceData.perks) return []

  // convert perks object to array and sort by signature perk
  const perksArray = Array.isArray(props.insuranceData.perks)
    ? props.insuranceData.perks
    : Object.values(props.insuranceData.perks)

  return [...perksArray].sort((a, b) => Number(b.isSignaturePerk || false) - Number(a.isSignaturePerk || false))
})

</script>

<style scoped lang="scss">
/* RLS house: perks are a text list with hairlines, not a stack of boxes. Plain shield glyph
   (ok ink for the signature perk, faint otherwise), the perk itself in bold, the explanation faint
   and clamped (full text in the tooltip). No coloured side bars, no tinted rows. */
.insurance-perks-container {
  display: grid;
  width: 100%;
  text-align: left;
}

.insurance-perk {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.6em;
  min-width: 0;
  padding: 0.5em 0 0.4em;
  border-bottom: 1px solid var(--line, rgba(255, 255, 255, 0.1));

  &:last-child {
    border-bottom: 0;
  }

  &.no-insurance {
    color: var(--muted, rgba(255, 255, 255, 0.72));
  }
}

.left {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: row;
  align-items: flex-start;
  gap: 0.5em;
}

.insurance-perk-icon-wrapper {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 1.3em;
  height: 1.3em;
  :deep(.glowing-icon) {
    --bng-icon-size: 1.15em;
  }
}

.minus-glyph {
  color: var(--bad, #fca5a5);
  font-weight: 800;
  line-height: 1;
}

.insurance-perk-texts {
  min-width: 0;
  display: grid;
  gap: 0.15em;
  padding-top: 0.12em;
}

.insurance-perk-intro {
  font-weight: 700;
  line-height: 1.25;
}

.insurance-perk-description {
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.3;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.signature-perk-wrapper {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
}

.signature-perk {
  padding: 0.4em 0.5em 0.12em;
  border-radius: var(--radius-pill, 0.3em);
  background: rgba(74, 222, 128, 0.16);
  color: var(--ok-ink, #86efac);
  font-size: 0.72em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
}
</style>
