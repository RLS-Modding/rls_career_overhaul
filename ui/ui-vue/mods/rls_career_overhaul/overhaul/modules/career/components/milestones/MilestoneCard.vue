<!-- Milestone tile for the Milestones screen. Overhaul's own copy of the stock card:
     a flat Claim strip instead of the spinning gradient border, a labelled tier,
     and the milestone colour as a tint so orange stays the claim colour. -->
<template>
  <Button
    class="milestone-card"
    :class="`milestone-${cardState}`"
    :style="milestoneStyle"
    :sound-class="claimable ? 'bng_click_hover_generic' : 'bng_hover_generic'"
    v-bng-on-ui-nav:ok.focusRequired.asMouse
    @click="claimMilestone"
  >
    <div class="media">
      <BngIcon class="glyph" :type="icons[milestone.icon]" />
      <div v-if="milestone.completed" class="complete-badge"><BngIcon :type="icons.checkmark" /></div>
      <div v-if="milestone.rewards" class="media-rewards">
        <RewardPill
          v-for="(reward, index) in milestone.rewards"
          :key="index"
          class="reward-pill"
          :icon="reward.icon"
          :attributeKey="reward.attributeKey"
          :rewardAmount="reward.rewardAmount"
          :highlight="reward.highlight"
          :hideNumbers="true"
        />
      </div>
    </div>
    <div class="content">
      <div class="heading-row">
        <div class="heading">{{ $ctx_t(milestone.label) }}</div>
        <div v-if="tierLabel" class="tier">{{ tierLabel }}</div>
      </div>
      <div v-if="milestone.description" class="description">{{ $ctx_t(milestone.description) }}</div>

      <div v-if="cardState === 'claimable'" class="claim-strip">
        {{ $translate.instant("ui.career.milestones.status.clickToClaim") }}
      </div>
      <div v-else-if="cardState === 'complete'" class="complete-line">
        <BngIcon :type="icons.checkmark" />
        {{ $translate.instant("ui.career.milestones.status.complete") }}
      </div>
      <div v-else-if="milestone.progress" class="progress">
        <BngProgressBar
          v-for="(prog, index) in milestone.progress"
          :key="index"
          :value="prog.currValue"
          :max="prog.maxValue"
          :min="prog.minValue"
          :valueLabelFormat="$ctx_t(prog.label)"
        />
      </div>
    </div>
  </Button>
</template>

<script>
const tileSize = {
  width: 36,
  height: 8.25,
  margin: 0.5,
}

const getSizeCalc = () => () => tileSize

export default {
  getSizeCalc,
}
</script>

<script setup>
import { computed } from "vue"
import { Button } from "@/common/components/utility"
import { BngIcon, icons, BngProgressBar } from "@/common/components/base"
import { vBngOnUiNav } from "@/common/directives"
import { $translate } from "@/services/translation"
import RewardPill from "@/modules/career/components/progress/RewardPill.vue"

const props = defineProps({
  milestone: Object,
})
const emit = defineEmits(["claim"])

const claimable = computed(() => !!props.milestone.claimable)

const cardState = computed(() => {
  if (props.milestone.completed) return "complete"
  if (props.milestone.claimable) return "claimable"
  return "open"
})

// Lua sends `step` as the number of claimed tiers. The card shows the tier it is about:
// the next one while open, the last one once the milestone is done.
const tierLabel = computed(() => {
  const { step, maxStep, completed, hideTier } = props.milestone
  if (hideTier) return ""
  if (typeof step !== "number") return ""
  const tier = completed ? step : step + 1
  if (typeof maxStep !== "number") {
    return $translate.instant("ui.career.milestones.tierOpenEnded", { tier })
  }
  if (maxStep < 1) return ""
  return $translate.instant("ui.career.milestones.tier", { tier, tiers: maxStep })
})

// Lua sends "#rrggbb" or a "var(--name-rgb)" triplet; both become an "r, g, b" value for rgba().
const milestoneTint = computed(() => {
  const color = props.milestone.color
  if (typeof color !== "string") return ""
  if (color === "orange") return "var(--bng-orange-500-rgb)"
  if (color.startsWith("#") && color.length >= 7) {
    const channel = start => parseInt(color.slice(start, start + 2), 16)
    return `${channel(1)}, ${channel(3)}, ${channel(5)}`
  }
  if (color.startsWith("var(--")) return color
  return ""
})

const milestoneStyle = computed(() => (milestoneTint.value ? { "--milestone-tint": milestoneTint.value } : {}))

function claimMilestone() {
  if (!props.milestone.claimable) return
  emit("claim", props.milestone)
}
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;

.milestone-card {
  @include modify-focus(var(--bng-corners-2), 0rem);

  --bng-content-flow: row;
  --bng-content-align: stretch;
  --bng-content-justify: flex-start;
  --bng-button-margin: 0;
  --bng-button-padding: 0;
  --bng-button-padding-top: 0;
  --bng-button-padding-bottom: 0;
  --bng-button-min-width: 0;
  --bng-button-max-width: 100%;
  --bng-bg-border-radius: var(--bng-corners-2);
  --bng-bg-border-width: 0.0625rem;
  --bng-bg-enabled: var(--bng-cool-gray-750);
  --bng-bg-hover: var(--bng-cool-gray-700);
  --bng-bg-active: var(--bng-cool-gray-700);
  --bng-bg-disabled: var(--bng-cool-gray-700);
  --bng-bg-focus: var(--bng-cool-gray-700);
  --bng-bg-enabled-opacity: 0.75;
  --bng-bg-hover-opacity: 0.75;
  --bng-bg-active-opacity: 0.9;
  --bng-bg-disabled-opacity: 0.55;
  --bng-bg-focus-opacity: 0.85;
  --bng-bg-border-enabled: var(--bng-cool-gray-600);
  --bng-bg-border-hover: var(--bng-cool-gray-500);
  --bng-bg-border-active: var(--bng-cool-gray-500);
  --bng-bg-border-disabled: var(--bng-cool-gray-600);
  --bng-bg-border-focus: var(--bng-cool-gray-300);
  --milestone-tint: var(--bng-cool-gray-700-rgb);

  display: flex;
  flex-direction: row;
  position: relative;
  width: 100%;
  height: 100%;
  border-radius: var(--bng-corners-2);
  overflow: hidden;
  text-align: left;
  color: var(--bng-off-white);
}

.media {
  flex: 0 0 8.25rem;
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  margin: 1px 0 1px 1px;
  border-radius: var(--bng-corners-2) 0 0 var(--bng-corners-2);
  background-color: rgba(var(--milestone-tint), 0.4);
  overflow: hidden;

  .glyph {
    font-size: 4.25rem;
  }

  .complete-badge {
    position: absolute;
    top: 0;
    left: 0;
    padding: 0.3rem 0.45rem;
    font-size: 1.5rem;
    line-height: 1;
    background-color: rgba(var(--bng-cool-gray-900-rgb), 0.6);
    border-radius: 0 0 var(--bng-corners-2);
  }

  .media-rewards {
    position: absolute;
    left: 0.25rem;
    right: 0.25rem;
    bottom: 0.25rem;
    display: flex;
    align-items: flex-end;
    overflow: hidden;
    font-size: 0.75rem;

    :deep(.icon) {
      width: 1rem;
      height: 1rem;
      --icon-size: 1rem;
    }

    .reward-pill {
      --reward-pill-container-margin: 0;
      --reward-pill-margin: 0;
      --reward-pill-padding: 0 0.2rem;
      --reward-pill-icon-padding-top: 0;
      --reward-pill-icon-padding-right: 0.1rem;
    }
  }
}

.content {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  min-width: 0;
  min-height: 0;
  padding: 0.5rem 0.6rem 0.6rem;
}

.heading-row {
  display: flex;
  align-items: baseline;
  gap: 0.75rem;
}

.heading {
  flex: 1 1 auto;
  min-width: 0;
  font-weight: 800;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.tier {
  flex: 0 0 auto;
  font-size: 0.8rem;
  font-weight: 600;
  color: var(--bng-cool-gray-200);
  font-variant-numeric: tabular-nums;
}

.description {
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
  font-size: 0.85rem;
  line-height: 1.15rem;
  color: var(--bng-cool-gray-100);
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 3;
  line-clamp: 3;
}

.progress {
  flex: 0 0 auto;
  border-radius: var(--bng-corners-1);
  overflow: hidden;
  font-variant-numeric: tabular-nums;

  :deep(.progress-bar) {
    border-radius: var(--bng-corners-1);
  }

  // keep the "3 / 15" label above the fill (the fill sets z-index: 1 inline)
  :deep(.info) {
    position: relative;
    z-index: 2;
  }
}

// The whole card is the button; the strip only says what pressing it does.
.claim-strip {
  flex: 0 0 auto;
  padding: 0.2rem 0.5rem;
  border: 0.0625rem solid rgba(var(--bng-orange-400-rgb), 0.7);
  border-radius: var(--bng-corners-1);
  background-color: rgba(var(--bng-orange-500-rgb), 0.18);
  color: var(--bng-orange-200);
  font-weight: 700;
  text-align: center;
  transition: background-color 120ms ease, color 120ms ease;

  @media (prefers-reduced-motion: reduce) {
    transition: none;
  }
}

.milestone-claimable:is(:hover, .focus-visible) .claim-strip {
  background-color: var(--bng-orange-b400, #ff6600);
  color: var(--bng-off-white);
}

.complete-line {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.35rem;
  font-size: 0.85rem;
  font-weight: 700;
  color: var(--bng-add-green-300, #86efac);
}
</style>
