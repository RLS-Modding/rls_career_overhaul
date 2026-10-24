<template>
  <section class="milestone-digest" bng-no-child-nav="true">
    <BngCardHeading type="ribbon" class="milestone-heading">
      {{ $t("ui.pause.career.unclaimedMilestonesTitle") }}
    </BngCardHeading>

    <div v-if="isLoading" class="milestone-empty">
      {{ $t("ui.common.loading") }}
    </div>
    <template v-else-if="claimableMilestones.length > 0">
      <div class="milestone-list">
        <div
          v-for="milestone in visibleMilestones"
          :key="milestone.claimId"
          class="milestone-row"
          :style="getMilestoneStyle(milestone)"
        >
          <div class="milestone-media">
            <div class="milestone-icon">
              <BngIcon class="milestone-glyph" :type="getMilestoneIcon(milestone)" />
            </div>
          </div>
          <div class="milestone-info">
            <div class="milestone-name">{{ $ctx_t(milestone.label) }}</div>
            <RewardsPills
              v-if="milestone.rewards"
              class="milestone-rewards"
              :rewards="milestone.rewards"
              :hideNumbers="false"
            />
          </div>
        </div>
        <div v-if="moreCount > 0" class="milestone-more">
          <div class="milestone-media">
            <div class="milestone-icon">
              <BngIcon class="milestone-glyph" :type="icons.plus" />
            </div>
          </div>
          <div class="milestone-info">
            <div class="milestone-name">{{ moreLabel }}</div>
          </div>
        </div>
      </div>
    </template>
    <div v-else class="milestone-empty">
      {{ $t("ui.pause.career.noClaimableMilestones") }}
    </div>
  </section>
</template>

<script setup>
import { computed, onMounted, ref } from "vue"
import { BngCardHeading, BngIcon, icons } from "@/common/components/base"
import { lua } from "@/bridge"
import "../career/utils/installLuaBridgeFallbacks.js"
import { $translate } from "@/services/translation"
import RewardsPills from "@/modules/career/components/progress/RewardsPills.vue"

defineOptions({ name: "OverhaulMilestoneDigest" })

const MAX_VISIBLE_ROWS = 4
const VISIBLE_MILESTONES_WITH_MORE_ROW = MAX_VISIBLE_ROWS - 1

const claimableMilestones = ref([])
const isLoading = ref(true)
const shouldShowMoreRow = computed(() => claimableMilestones.value.length > MAX_VISIBLE_ROWS)
const visibleMilestones = computed(() => {
  const visibleCount = shouldShowMoreRow.value ? VISIBLE_MILESTONES_WITH_MORE_ROW : MAX_VISIBLE_ROWS
  return claimableMilestones.value.slice(0, visibleCount)
})
const moreCount = computed(() => shouldShowMoreRow.value ? claimableMilestones.value.length - VISIBLE_MILESTONES_WITH_MORE_ROW : 0)
const moreLabel = computed(() =>
  $translate.contextTranslate({ txt: "ui.pause.career.moreClaimableMilestones", context: { count: moreCount.value } })
)

onMounted(loadMilestones)

async function loadMilestones() {
  isLoading.value = true
  try {
    const result = await lua.overhaul_career_progression_milestones_milestones.getMilestones()
    const claimable = result?.list?.filter(milestone => milestone.claimable) || []
    claimableMilestones.value = claimable
  } finally {
    isLoading.value = false
  }
}

function getMilestoneIcon(milestone) {
  return icons[milestone?.icon] || icons.star
}

function getMilestoneStyle(milestone) {
  const color = getColorValue(milestone?.color)
  if (!color) return undefined
  return {
    "--milestone-image-bg": color,
  }
}

function getColorValue(color) {
  if (!color) return undefined
  if (color.startsWith("#")) return hexToRgb(color)
  if (color.startsWith("var(--")) return color
  return undefined
}

function hexToRgb(hex) {
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `${r}, ${g}, ${b}`
}
</script>

<style lang="scss" scoped>
.milestone-digest {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  color: var(--bng-off-white);
  margin-bottom: 0.5rem;
}

.milestone-heading {
  margin: 0;
  margin-top: 0.5rem;
}

.milestone-list {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  min-height: 0;
  padding: 0 0.5rem;
}

.milestone-row {
  display: grid;
  grid-template-columns: 4.5rem minmax(0, 1fr);
  min-height: 4.5rem;
  border-radius: var(--bng-corners-2);
  background: rgba(var(--bng-cool-gray-750-rgb), 0.75);
  overflow: hidden;
}

.milestone-media {
  min-width: 0;
  padding: 1px;
}

.milestone-icon {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
  min-height: 4.5rem;
  border-radius: var(--bng-corners-2) 0 0 var(--bng-corners-2);
  background-color: rgb(var(--milestone-image-bg, var(--bng-cool-gray-700-rgb)));
  color: var(--bng-off-white);
  overflow: hidden;
}

.milestone-glyph {
  font-size: 2.8rem;
  opacity: 0.9;
}

.milestone-info {
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0.375rem;
  min-width: 0;
  padding: 0.5rem 0.625rem;
}

.milestone-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 700;
}

.milestone-rewards {
  --reward-pill-container-margin: 0;
  --reward-pill-margin: 0 0.125rem 0.125rem 0;
}

.milestone-more,
.milestone-empty {
  color: rgba(255, 255, 255, 0.75);
  font-size: 0.95rem;
}

.milestone-more {
  display: grid;
  grid-template-columns: 4.5rem minmax(0, 1fr);
  min-height: 2rem;
  border-radius: var(--bng-corners-2);
  background: rgba(var(--bng-cool-gray-800-rgb), 0.75);
  overflow: hidden;
  .milestone-icon {
    background: rgba(var(--bng-cool-gray-750-rgb), 0.75);
    --bng-icon-color: var(--bng-cool-gray-300);
  }
}

</style>
