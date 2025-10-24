<template>
  <div class="profile-status">
    <div class="profile-status-progress">

      <div class="status-progress-item">
        <BngUnit :vouchers="vouchers?.value || 0" :formatter="vouchersFormatter" />
      </div>
      <BngDivider />
      <div class="status-progress-item">
        <BngUnit :money="money?.value || 0" :formatter="moneyFormatter" />
      </div>
    </div>

    <Transition name="expand-height">
      <div v-if="branches" v-show="expanded" class="profile-status-levels">
        <div v-for="branch in branches" class="profile-status-level">
          <div class="branch-icon-assembly">
            <div class="branch-background" :style="getBranchStyle(branch.color)"></div>
            <BngIcon :type="branch.icon" class="assembly-icon" />
          </div>
          <div class="level-content-wrapper">
            <BngProgressBar
              class="slim"
              :value="branch.curLvlProgress"
              :min="0"
              :max="branch.neededForNext"
              :headerLeft="$ctx_t(branch.label)"
              :headerRight="`${$ctx_t(branch.levelLabel)} `"
              :valueColor="'white'"
              :showValueLabel="false"
            />
          </div>
        </div>
      </div>
    </Transition>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngDivider, BngIcon, BngProgressBar, BngUnit, icons } from "@/common/components/base"
import { shrinkNum } from "@/utils/format"
import { getIconBackgroundStyle } from "@/utils/colorUtils"

const props = defineProps({
  beamXP: {
    type: Object,
    required: true,
  },
  vouchers: {
    type: Object,
    required: true,
  },
  money: {
    type: Object,
    required: true,
  },
  branches: {
    type: Array,
    required: true,
  },
  expanded: Boolean,
})

const BRANCH_STYLES = {

}

const formatterFn = num => shrinkNum(num, 1)
const moneyFormatter = computed(() => (props.money && props.money > 100000 ? formatterFn : undefined))
const beamXPFormatter = computed(() => (props.beamXP && props.beamXP > 100000 ? formatterFn : undefined))
const vouchersFormatter = computed(() => (props.vouchers && props.vouchers > 100000 ? formatterFn : undefined))

function getBranchStyle(color) {
  return getIconBackgroundStyle(color)
}

function getBranchIcon(branchId) {
  const style = BRANCH_STYLES[branchId]
  return style ? style.icon : icons.questionMark
}

function getBranchColor(branch) {
  const color = branch.color
  return getIconBackgroundStyle(color)['background-color']
}


</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.profile-status {
  display: flex;
  flex-direction: column;
  padding: 0.75em 1em 0.5em;
  color: #fff;
  background: hsla(217, 22%, 12%, 1);

  // &.expanded {
  //   animation: expandContainer 0.5s cubic-bezier(0.25, 0.1, 0.25, 1);
  // }
}

// @keyframes expandContainer {
//   0% {
//     transform: translateY(16em);
//   }
//   100% {
//     transform: translateY(0);
//   }
// }

.profile-status-progress {
  display: flex;
  flex-direction: row;
  justify-content: flex-end;

  > .status-progress-item {
    display: flex;
    align-items: center;
    font-size: calc-ui-rem(1.35);
  }
}

.profile-status-levels {
  display: flex;
  overflow: hidden;
  flex-direction: column;
  background: hsla(217, 22%, 12%, 1);
  padding-top: 0.5em;

  > .profile-status-level {
    display: flex;
    padding: 0.4em 0 0;
    flex-direction: row;
    justify-content: flex-start;
    align-items: flex-end;

    > .branch-icon-assembly {
      position: relative;
      flex: 0 0 auto;
      height: 2.25em;
      width: 2.25em;
      margin-right: 0.5em;

      > .branch-background {
        position: absolute;
        top: 0;
        bottom: 0;
        left: 0;
        right: 0;
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

      > .assembly-icon {
        position: relative;
        font-size: 2.25em;
        z-index: 2;
      }
    }

    > .level-content-wrapper {
      flex-grow: 1;
      align-self: stretch;
      .slim {
        :deep(.progress-bar) {
          height: 0.75em;
          border-radius: var(--bng-corners-2);

        }
      }
    }
  }
}

.expand-height-enter-active {
  transition: all 0.5s cubic-bezier(0.25, 0.1, 0.25, 1);
}

.expand-height-enter-from {
  // transform: translateY(4em);
  max-height: 0;
}

.expand-height-enter-to {
  // transform: translateY(0);
  max-height: 16em;
}

.expand-height-leave-active {
  // transform: translateY(16em);
  max-height: 0;
}

.expand-height-leave-to {
  max-height: 16em;
}
</style>
