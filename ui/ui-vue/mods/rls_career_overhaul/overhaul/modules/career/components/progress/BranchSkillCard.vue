<template>
  <BngCard v-if="branchData" class="branch-skill-card" :class="{
    'row-mode': displayMode === 'row',
    'locked': !branchData.unlocked,
    'half': isHalf,

  }"
  :data-branch-id="branchKey"
  :bng-scoped-nav-autofocus="autofocus ? 'true' : null"
  v-bng-on-ui-nav:ok.asMouse.focusRequired
  bng-nav-item
  tabindex="0"
  @click.stop="openBranchPage(branchKey)"
  :style="{ '--branch-color': branchColor, '--branch-accent-color': branchAccentColor }">

    <div class="branch-details">
      <div class="indicator left"></div>
      <div class="indicator right"></div>
      <div class="branch-progress" v-if="!branchData.isDomain" :class="{ 'in-development': branchData.isInDevelopment }">
        <div v-if="!branchData.isDomain" class="badge" :class="{ 'row-badge': displayMode === 'row' }">
          <div class="backdrop"></div>
          <BngIcon class="icon-branch" :type="branchIconType" />
        </div>
      </div>
      <AspectRatio
        v-if="branchData.isDomain"
        :external-image="branchData.cover"
        :ratio="'16:9'"
        class="image-container aspect-ratio"
      />
      <div class="skill-levels-wrapper">
        <template v-if="displayMode === 'row'">
          <div class="branch-name-container">
            <BranchSkillProgressBar
              v-if="branchData"
              class="main-stat-progress-bar"
              :skill="branchData"
              :showLevel="true"
            />

          </div>


        </template>


      </div>
      <div class="branch-footer" v-if="!isHalf">
        <template v-if="branchData.isInDevelopment">
          <div class="branch-description">{{ $ctx_t('ui.career.inDevelopment') }}</div>
        </template>
        <template v-else>
          <div class="branch-description" v-if="branchData.shortDescription">{{ $ctx_t(branchData.shortDescription) }}</div>
          <div class="branch-footer-content">
            <div v-for="skill in branchData.skills" v-if="branchData.skills">
              <BranchSkillProgressBar
                v-if="branchData"
                :skill="skill"
                mode="simple"
              />
            </div>
          </div>
        </template>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { lua } from "@/bridge"
import { BngCard, BngProgressBar, BngIcon, icons } from "@/common/components/base"
import { onMounted, ref, computed, nextTick } from "vue"
import { vBngOnUiNav } from "@/common/directives"
import { getAssetURL } from "@/utils"
import { AspectRatio } from "@/common/components/utility"
import BranchSkillProgressBar from "@/modules/career/components/progress/BranchSkillProgressBar.vue"
import { hexToRgb } from "@/utils/colorUtils"

const props = defineProps({
  branchKey: String,
  displayMode: {
    type: String,
    default: 'card', // can be 'card' or 'row'
  },
  autofocus: {
    type: Boolean,
    default: false,
  },
})
const emit = defineEmits(["openBranchPage", "ready"])

const branchData = ref()

const iconImageUrl = computed(() => branchData.value && `url(${getAssetURL(branchData.value.icon)})`)
// const branchColor = computed(() => branchData.value && branchData.value.color)

const branchColor = computed(() => {
  const color = branchData.value && branchData.value.color
  if (!color) return ""
  if (color.startsWith("#")) {
    return hexToRgb(color)
  } else if (color.startsWith("var(--")) {
    return `${color}`
  } else {
    return "transparent"
  }
})

const branchAccentColor = computed(() => {
  const color = branchData.value && (branchData.value.accentColor || branchData.value.color)
  if (!color) return ""
  if (color.startsWith("#")) {
    return hexToRgb(color)
  } else if (color.startsWith("var(--")) {
    return `${color}`
  } else {
    return "transparent"
  }
})

const branchIconType = computed(() => {
  if (branchData.value && branchData.value.isInDevelopment) {
    return icons.roadblockL
  }
  if (branchData.value && branchData.value.unlocked) {
    return icons[branchData.value.glyphIcon]
  }
  return icons.lockClosed
})

const CIVIL_SERVICE_LIST_CARD_ID = 'careerSkills-civilService'

const isCivilServiceListCard = data => {
  if (!data) return false
  return data.id === CIVIL_SERVICE_LIST_CARD_ID || data.attributeKey === CIVIL_SERVICE_LIST_CARD_ID
}

const isHalf = computed(() => {
  if (!branchData.value) return false
  if (isCivilServiceListCard(branchData.value)) return true
  const hasSkills = branchData.value.skills && branchData.value.skills.length > 0
  const hasDescription = branchData.value.shortDescription
  return !hasSkills && !hasDescription
})

const safeArray = arr => Array.isArray(arr) ? arr : []
const openBranchPage = branchKey => emit("openBranchPage", branchKey)
function setup(data) {
  branchData.value = data
  branchData.value.skills = safeArray(data.skills)
  if (isCivilServiceListCard(branchData.value)) {
    branchData.value.skills = []
  }
  //data.skills = data.skills || []
}

onMounted(async () => {
  setup(await lua.overhaul_career_progression_skillsPage.getBranchSkillCardData(props.branchKey))
  await nextTick()
  emit("ready", props.branchKey)
})
</script>

<style scoped lang="scss">
$backdrop-shape: polygon(26% 8%, 73% 8%, 92% 39%, 64% 100%, 19% 100%, 0 70%);

.branch-skill-card {
  cursor: pointer;
  display: flex;
  flex-flow: column;
  position: relative;
  border-radius: var(--bng-corners-2);
  height: 100%;
  background-color: rgba(255, 255, 255, 0.25);
  translate: all ease-in 50ms;
  border: 1px solid rgba(var(--branch-accent-color), 0.5);
  &:hover {
    background-color: rgba(255, 255, 255, 0.5);
    //transform: scale(1.02);
    //box-shadow: inset 0 0 0 0.25rem rgb(var(--branch-accent-color));
    .branch-details .indicator {
      opacity: 0.75;
      width: 0.75rem;
    }
  }
  &:focus {
    background-color: rgba(255, 255, 255, 0.5);
    //transform: scale(1.02);
    .branch-details .indicator {
      opacity: 1;
      width: 0.75rem;
    }
  }

  &.half {
    flex-direction: row;
    grid-column: span 1 !important;
  }

  &.locked {
    .image-container {
      opacity: 0.5;
    }

    .icon-branch {
      opacity: 0.6;
    }

    .branch-name {
      opacity: 0.5;
    }
    .branch-description {
      opacity: 0.5;
    }
  }

  .no-bg {
    height: 5rem;
    content: "";
    background: rgba(var(--branch-color), 0.35);
  }

  .image-container {
    flex: 1 0 12rem;
    padding: 0;
    width: auto;
    height: 100%;
    align-self: center;
    max-width: 30rem;
    //border-bottom: 4rem solid v-bind(branchColor);
    box-shadow: inset 0rem -0.125rem 0rem 0rem rgb(var(--branch-color));

  }


  .branch-details {
    flex: 1 1 auto;
    display: flex;
    flex-flow: column;

    .indicator {
      position: absolute;
      top: 0;
      width: 0.33rem;
      height: 100%;
      background-color: rgba(var(--branch-accent-color), 0.75);
      opacity: 0;
      z-index: 1;
      transition: width 0.25s ease-in-out;
      &.left {
        left: 0;
        border-radius:  var(--bng-corners-2) 0 0 var(--bng-corners-2);
      }
      &.right {
        right: 0;
        border-radius:  0 var(--bng-corners-2) var(--bng-corners-2) 0;
      }

    }
    .branch-progress {
      position: relative;
      padding: 1rem 0 0.5rem 0;
      background: rgb(var(--branch-color));
      padding: 0.5rem;

      .badge {
        position: absolute;
        top: -4.75rem;
        width: 6rem;
        height: 6rem;
        left: 50%;
        transform: translateX(-50%);
        > .icon-branch {
          position: absolute;
          font-size: 4.5rem;
          top: 50%;
          left: 50%;
          transform-origin: 50% 50%;
          transform: translate(-55%, -50%) rotate(-3deg);
          z-index: 2;
        }
        > .backdrop {
          position: absolute;
          display: inline-block;
          width: 100%;
          height: 90%;
          clip-path: $backdrop-shape;
          background: rgba(0, 0, 0, 0.4);
          z-index: 1;

          // Inner layer
          &::before {
            position: absolute;
            content: "";
            display: inline-block;
            width: calc(100% - 8px);
            height: calc(100% - 8px);
            top: 4px;
            left: 4px;
            clip-path: $backdrop-shape;
            opacity: 0.4;
            background-color: rgb(var(--branch-color));
          }

          // Middle layer
          &::after {
            position: absolute;
            content: "";
            display: inline-block;
            width: calc(100% - 16px);
            height: calc(100% - 16px);
            top: 8px;
            left: 8px;
            clip-path: $backdrop-shape;
            background-color: rgb(var(--branch-color));
          }
        }
      }
      :deep(.header) {
        padding-bottom: 0.25rem;
        .header-left {
          font-size: 2rem;
        }
      }
      :deep(.progress-bar) {
        background-color: rgba(0, 0, 0, 0.25);
      }

      .locked-reason {
        font-size: 0.8rem;
        font-weight: 600;
        text-align: center;
        color: rgba(255, 255, 255, 0.5);
      }

    }
    .skill-levels-wrapper {
      flex: 1 1 5rem;
      display: flex;
      flex-direction: column;

      background: border-box 50% 100% / 100% 105% linear-gradient(to bottom, rgba(var(--branch-color), 0.75), rgba(var(--branch-color), 0.2) 80%);
      gap: 0.25rem;
    }
    .branch-footer {
      flex: 0 0 auto;
      padding: 0.5rem;
      height: 100%;
      background: rgba(var(--branch-color), 0.2);
    }

    .main-stat-progress-bar {
      padding: 0 0.5rem 0;
      font-size: 1.5rem;
      width: 100%;
    }
    .long {
      min-width: 10rem;
      max-width: 25rem;
      width: 100%;
    }
  }

  &.row-mode {
    flex-direction: row;

    :deep(.card-cnt) {
      flex: 1 1 auto;
    }

    .branch-details {
      flex: 1 1 auto;
      width: 100%;
      flex-direction: row;
      align-items: center;

      .branch-progress {
        flex: 0 0 auto;
        background: #0000;

        &.in-development {
          background: repeating-linear-gradient(-45deg, rgba(white, 0.05), rgba(white, 0.05) 1rem, rgba(white, 0) 1rem, rgba(white, 0) 2rem);
        }

        .badge.row-badge {
          position: relative;
          top: auto;
          left: auto;
          transform: none;
          width: 4rem;
          height: 4rem;
          margin-left: 0.5rem;
          margin-right: 0.2rem;

          .icon-branch {
            font-size: 3rem;
          }
        }
      }

      .skill-levels-wrapper {
        flex: 1 1 20rem;
        padding: 0.5rem 0.25rem;
        display: flex;
        background: border-box 50% 100% / 100% 105% linear-gradient(to right, rgba(var(--branch-color), 0.75), rgba(var(--branch-color), 0.25) 80%);
        height: 100%;
        align-items: flex-start;

        .branch-name-container {
          display: flex;
          flex-direction: row;
          align-items: center;
          justify-self: center;

          gap: 0.5rem;
          width: 100%;
        }

        .branch-name {
          flex: 0 0 auto;
          font-size: 1.8rem;
          font-weight: 800;
          font-style: italic;
        }
        .divider {
          width: 100%;
          height: 1px;
          background-color: rgba(255, 255, 255, 0.1);
        }
        .locked-reason {
          flex: 1 1 auto;
          text-align: right;
          font-size: 1rem;
          opacity: 0.5;
          font-style: italic;
          padding-right: 0.5rem;
        }
        .branch-description {
          font-size: 1rem;
          color: rgba(255, 255, 255, 0.7);
        }
      }

      .branch-footer {
        flex: 0 1 50%;
        .branch-footer-content {
          display: flex;
          flex-wrap: wrap;
          align-items: flex-start;
          justify-content: flex-start;
          column-gap: 0.5rem;
          row-gap: 0.25rem;

          > * {
            flex: 1 1 calc(50% - 0.25rem);
            min-width: fit-content;
            align-self: flex-start;
          }
        }
      }
    }
  }

}

.in-development {
  background: repeating-linear-gradient(-45deg, rgba(white, 0.02), rgba(white, 0.02) 1rem, rgba(white, 0) 1rem, rgba(white, 0) 2rem);
}
</style>
