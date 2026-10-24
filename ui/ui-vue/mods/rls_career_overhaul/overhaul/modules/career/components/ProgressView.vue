<!-- Reusable Progress View Layout Component -->
<template>
  <LayoutMenu
    class="progress-view-layout"
    :style="branchStyle"
    nav-scope="root"
    :nav-active="false"
    :nav-auto-focus="true"
    :nav-options="navOptions"
    :breadcrumbs="breadcrumbItems"
    :hide-breadcrumb-last-item="false"
    @breadcrumb-click="handleBreadcrumbClick"
    @breadcrumb-back="handleBreadcrumbBack"
  >
    <template #heading>
      <div v-if="skillInfo" class="progress-view-header">
        <div class="header-skill" :class="{ 'is-locked': !skillInfo.unlocked }" @click="$emit('skill-click', skillInfo.id)">
          <div class="branch-icon-assembly large">
            <div class="branch-background" :style="getIconBackgroundStyle(skillInfo.color)"></div>
            <BngIcon :type="icons[skillInfo.unlocked ? skillInfo.icon : 'lockClosed']" class="assembly-icon large" />
          </div>
          <div class="skill-progress">
            <BranchSkillProgressBar
              class="main-stat-progress-bar skill-progress-bar"
              :skill="skillInfo"
              :showLevel="false"
              :showLockedIcon="true"
              :isMainProgress="true"
            />
            <div class="skill-progress-caption">{{ skillCaption }}</div>
          </div>
        </div>
        <div class="reward-multiplier" v-if="skillInfo.rewardMultiplier">
          <div class="reward-multiplier-label">
            <BngIcon :type="skillInfo.rewardMultiplierSourceIcon" />
            {{ $t("ui.career.rewards.rewardMultiplier") }}:
          </div>
          <div class="reward-multiplier-value">
            <BngIcon :type="icons.beamCurrency" />
            ×{{ skillInfo.rewardMultiplier.toFixed(2) }}
          </div>
        </div>
      </div>
      <BngScreenHeadingV2 v-else type="2" class="header-title-v2">
        {{ headingText }}
      </BngScreenHeadingV2>
    </template>

    <template #topbar-right>
      <BngCard class="status-container" v-bng-blur="true">
        <CareerStatus class="career-page-status" />
      </BngCard>
    </template>

    <div class="progress-view-page" v-bng-blur>
      <div class="progress-view-contents">
        <div class="progress-view-description">
          <slot name="description"></slot>
        </div>
        <div class="progress-view-divider"></div>
        <div class="progress-view-scrollable" v-bng-ui-nav-scroll.force>
          <slot></slot>
        </div>
      </div>
    </div>
  </LayoutMenu>
</template>

<script setup>
import { LayoutMenu } from "@/common/layouts"
import { BngScreenHeadingV2, BngIcon, icons, BngCard } from "@/common/components/base"
import { vBngBlur, vBngUiNavScroll } from "@/common/directives"
import CareerStatus from "./careerStatus.vue"
import BranchSkillProgressBar from "@/modules/career/components/progress/BranchSkillProgressBar.vue"
import { getIconBackgroundStyle } from "@/utils/colorUtils"
import { $translate } from "@/services/translation"
import { computed } from "vue"

const props = defineProps({
  skillInfo: {
    type: Object,
    default: null
  },
  headingText: {
    type: String,
    default: ""
  },
  breadcrumbItems: {
    type: Array,
    required: true
  },
  branchStyle: {
    type: Object,
    required: true
  },
  navOptions: {
    type: Object,
    default: () => ({})
  }
})

const emit = defineEmits(['breadcrumb-click', 'breadcrumb-back', 'skill-click'])

// The stock bar prints raw XP ("5789366 XP"); this caption groups the digits and keeps the stock wording.
const skillCaption = computed(() => {
  const skill = props.skillInfo
  if (!skill) return ""
  if (!skill.unlocked && skill.lockedReason) return $translate.contextTranslate(skill.lockedReason.label || "ui.career.locked")
  if (skill.isInDevelopment) return $translate.contextTranslate("ui.career.inDevelopment")
  if (!skill.unlocked) return $translate.contextTranslate("ui.career.locked")
  if (skill.isMaxLevel || skill.showProgressAsStars) return ""
  const xp = Intl.NumberFormat().format(Math.floor(Number(skill.value) || 0))
  return $translate.contextTranslate({ txt: "ui.career.justXP", context: { cur: xp } })
})

const handleBreadcrumbClick = (item) => {
  emit('breadcrumb-click', item)
}

const handleBreadcrumbBack = () => {
  emit('breadcrumb-back')
}
</script>

<style lang="scss" scoped>
$textcolor: #fff;
$fontsize: 1rem;

.progress-view-layout {
  color: $textcolor;
  font-size: $fontsize;
}

.status-container {
  border-radius: var(--bng-corners-2);
  color: white;
  align-self: flex-start;
  flex: 0 0 auto;
}

.career-page-status {
  padding: 0.5rem 0.75rem 0.5rem 0.5rem;
  font-weight: 800;
  display: flex;
  justify-content: center;
  align-items: center;
}

.progress-view-page {
  display: flex;
  flex-direction: column;
  // Fits its cards and scrolls only when they outgrow the screen; a full-height panel left an empty block.
  flex: 0 1 auto;
  align-self: flex-start;
  margin-right: auto;
  background: rgba(0, 0, 0, 0.6);
  border-radius: var(--bng-corners-2);
  width: 100%;
  max-width: 76rem;
  position: relative;
  min-height: 0;
  max-height: 100%;
  overflow: hidden;

  &::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background-color: #424242;
    opacity: 0.8;
    border-radius: var(--bng-corners-2);
    z-index: 0;
  }

  &::after {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: linear-gradient(to bottom,
      rgba(var(--branch-color), 0.2),
      rgba(var(--branch-color), 0.2) 10rem,
      rgba(var(--branch-color), 0.05) 20rem,
      rgba(var(--branch-color), 0.01) 100%),
      rgba(3, 1, 1, 0.6);
    border-radius: var(--bng-corners-2);
    z-index: 1;
  }

  > * {
    position: relative;
    z-index: 2;
  }
}

.progress-view-header {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background-color: rgba(0, 0, 0, 0.5);
  border-radius: var(--bng-corners-2);
  --bng-heading-background-opacity: 0;
  min-height: 3.6rem;
  min-width: 40rem;
  overflow: hidden;
}

.header-title-v2 {
  margin-left: 0.5rem;
  margin-bottom: 0.25rem;
}

.progress-view-contents {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
}

.progress-view-description {
  display: flex;
  align-items: flex-start;
  justify-content: flex-start;
  text-align: left;
  background-color: rgba(var(--branch-color), 0.2);
  border-radius: var(--bng-corners-2);
  margin: 1rem;
  margin-top: 0.5rem;
  margin-bottom: 0rem;
  padding: 0.5rem;

}

.progress-view-divider {
  width: 100%;
  height: 1px;
  margin: 0.5rem 0;
  position: relative;

  &::after {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 1px;
    background: linear-gradient(
      90deg,
      rgba(var(--branch-accent-color), 0.5),
      rgba(var(--branch-accent-color), 0.15) 40%,
      transparent 70%
    );
  }
}
.progress-view-scrollable {
  flex: 0 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding-bottom: 1rem;
  overflow-y: scroll;
}

.header-skill {
  display: flex;
  padding: 0.5rem 1rem;
  position: relative;
  z-index: 2;
  flex: 1 1 auto;
  gap: 0.5rem;
  background-color: rgba(var(--branch-accent-color), 0.1);
  height: 100%;
  box-sizing: border-box;
  align-items: center;

  .skill-progress {
    flex: 1 1 auto;
    display: flex;
    flex-direction: column;
  }

  .skill-progress-bar {
    :deep(.header) {
      font-size: 2rem;
    }
  }

  .skill-progress-caption {
    // Keeps the row height when the caption is empty (max level), like the stock zero-width space.
    min-height: 1.2em;
    padding-right: 0.25rem;
    font-size: 0.8rem;
    font-weight: 600;
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
}
.reward-multiplier {
  flex: 0 1 auto;
  font-size: 1.2rem;
  height: 100%;
  font-weight: 600;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  border-left: 1px solid rgba(255, 255, 255, 0.1);
  padding: 0.25rem 1rem;
  background-color: rgba(var(--branch-accent-color), 0.15);
  .reward-multiplier-label {
    font-size: 0.8rem;
    font-weight: 600;
  }
  .reward-multiplier-value {
    font-size: 1.2rem;
    font-weight: 600;
  }
}

.branch-icon-assembly {
  position: relative;
  flex: 0 0 auto;
  height: 2.4em;
  width: 2.4em;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-right: 0;

  &.large {
    height: 3.8em;
    width: 3.8em;
  }

  .branch-background {
    position: absolute;
    top: -0.18rem;
    bottom: -0.18rem;
    left: -0.18rem;
    right: -0.18rem;
    mask-image: url(/ui/assets/SVG/24/branchXP-bg.svg);
    -webkit-mask-image: url(/ui/assets/SVG/24/branchXP-bg.svg);
    mask-repeat: no-repeat;
    -webkit-mask-repeat: no-repeat;
    mask-size: contain;
    -webkit-mask-size: contain;
    mask-position: 50% 50%;
    -webkit-mask-position: 50% 50%;
    z-index: 1;
  }

  .assembly-icon {
    position: relative;
    font-size: 2.4em;
    z-index: 2;
    justify-self: center;
    font-style: normal;

    &.large {
      font-size: 3.8em;
    }
  }
}

.is-locked {
  color: rgba(255, 255, 255, 0.6);

  .branch-icon-assembly {
    opacity: 0.6;
  }
}
</style>

