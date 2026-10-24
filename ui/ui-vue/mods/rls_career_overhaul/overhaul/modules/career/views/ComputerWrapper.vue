<template>
  <LayoutMenu
    class="computer-wrapper-layout"
    nav-scope="root"
    :nav-active="false"
    :breadcrumbs="breadcrumbItems"
    @breadcrumb-click="breadcrumbClick"
    @breadcrumb-back="emit('back')"
  >
    <template #heading>
      <BngScreenHeadingV2 type="2">
        <slot name="title">{{ $t(title) }}</slot>
      </BngScreenHeadingV2>
    </template>

    <template #topbar-right>
      <BngCard class="status-container" v-bng-blur="true">
        <CareerStatus ref="elStatus" />
        <div v-if="$slots.status" class="status-add">
          <slot name="status"></slot>
        </div>
      </BngCard>
    </template>

    <div class="main-content-slotted" v-bng-on-ui-nav:back="() => emit('back')">
      <slot></slot>
    </div>

    <template v-if="store.tasks?.length || $slots.side" #side-tasklist>
      <div class="side-content-slotted">
        <TaskList
          class="task-list"
          :header="store.header"
          :tasks="store.tasks" />
        <slot name="side"></slot>
      </div>
    </template>
  </LayoutMenu>
</template>

<script setup>
import { ref, provide, computed } from "vue"
import { useBridge } from "@/bridge"
import { LayoutMenu } from "@/common/layouts"
import { BngCard, BngScreenHeadingV2 } from "@/common/components/base"
import { vBngOnUiNav, vBngBlur } from "@/common/directives"
import CareerStatus from "../components/careerStatus.vue"
import { TaskList } from '@/modules/tasks'
import { useTasksStore } from "@/services/tasklistStore"
import { useRouteDataStore } from "@/services/routeData"
import { $translate } from "@/services/translation"

const routeDataStore = useRouteDataStore()

defineProps({
  title: {
    type: String,
    default: () => $translate.instant("ui.career.shared.myComputer"),
  },
  wallpaperFull: Boolean,
  wallpaperHalf: Boolean,
  back: Boolean,
  close: Boolean,
})

const breadcrumbItems = computed(() => routeDataStore.breadcrumbs || [])

const elStatus = ref()
const store = useTasksStore()
const { lua } = useBridge()

provide('animationSettings', {
  animate: true,
  animateOnMount: false,
  animateOnMountIntervalDelay: 0.2,
  animateOnEmptyIntervalDelay: 0.1,
  animateOnEmpty: true,
  animateNextTask: true,
  successCallback: playAudio
})
function playAudio() {
  lua.Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Checkbox')
}

defineExpose({
  statusUpdate: () => elStatus.value.updateDisplay(),
})

async function breadcrumbClick(item) {
  if (!item) return
  if (item.closeAllMenus) {
    lua.overhaul_career_career.closeAllMenus()
    return
  }
  if (item.routeName && !item.abstract) {
    await lua.extensions.ui_router.navigate(item.routeName, item.params)
  }
}

const emit = defineEmits(["back", "close"])
</script>

<style lang="scss" scoped>
// RLS override of the vanilla ComputerWrapper: template and script are identical to the game file,
// only the chrome is restyled to the house look (near-black panels, one orange accent, gold money).
$house-black: rgba(var(--bng-off-black-rgb), 0.9);
$house-ring: 0 0 0 1px rgba(255, 255, 255, 0.06);
$money: #fde68a;

.computer-wrapper-layout {
  // BngScreenHeadingV2 reads these: near-black title chip instead of the 60% grey one
  --bng-heading-background: var(--bng-off-black);
  --bng-heading-background-opacity: 0.9;

  :deep(.bng-screen-heading > .header::before) {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.07), 0 8px 24px rgba(0, 0, 0, 0.35);
  }

  // Breadcrumb bar, house style: one near-black pill. Back is a soft inner button (no border),
  // earlier steps are muted, the current page is white and bold, slashes are faint.
  :deep(.menu-screen .menu-topbar .menu-breadcrumbs.menu-breadcrumbs) {
    align-items: center;
    gap: 0.1em;
    height: auto;
    padding: 0.2em 0.55em 0.2em 0.2em;
    background-color: $house-black;
    box-shadow: $house-ring, 0 8px 24px rgba(0, 0, 0, 0.35);
    font-size: 0.95em;
    // vanilla adds a trailing "/" after the last crumb
    &::after {
      display: none;
    }

    .back-button {
      --bng-bg-enabled: #fff;
      --bng-bg-enabled-opacity: 0.08;
      --bng-bg-hover: #fff;
      --bng-bg-hover-opacity: 0.16;
      --bng-bg-active: #fff;
      --bng-bg-active-opacity: 0.22;
      --bng-bg-border-enabled: transparent;
      --bng-bg-border-hover: transparent;
      --bng-bg-border-active: transparent;
      --bng-bg-border-radius: calc(var(--bng-corners-2) - 0.1em);
      --bng-button-padding: 0 0.75em 0 0.5em;
      --bng-button-padding-top: 0.32em;
      --bng-button-padding-bottom: 0.22em;
      --bng-content-align: center;
      gap: 0.3em;
      margin: 0 0.45em 0 0 !important;
      font-weight: 700;
      > .back-icon {
        width: auto;
        font-size: 1.05em;
        transform: translateY(-0.06em);
      }
    }

    .bng-path-item {
      --bng-bg-enabled-opacity: 0;
      --bng-bg-hover: #fff;
      --bng-bg-hover-opacity: 0.08;
      --bng-bg-active-opacity: 0.12;
      --bng-button-text-enabled-color: rgba(255, 255, 255, 0.58);
      --bng-button-text-hover-color: #fff;
      --bng-button-padding: 0 0.35em;
      --bng-button-padding-top: 0.32em;
      --bng-button-padding-bottom: 0.22em;
      --bng-bg-border-radius: 0.3em;
      font-weight: 600;
      // Lua names the root "career"
      &.bng-path-first {
        text-transform: capitalize;
      }
      &.bng-path-last {
        --bng-button-text-enabled-color: #fff;
        font-weight: 700;
        .label {
          text-decoration: none;
        }
      }
    }
    .bng-path-icon {
      padding: 0 0.05em;
      opacity: 0.3;
      font-size: 0.8em;
      align-self: center;
    }
  }
}

.status-container {
  --bg-opacity: 0.9;
  border-radius: var(--bng-corners-2);
  color: white;
  align-self: flex-start;
  overflow: hidden;
  box-shadow: $house-ring, 0 8px 24px rgba(0, 0, 0, 0.35);

  :deep(.card-cnt) {
    background-color: $house-black;
  }

  // slashes between the values: faint, not pure white
  :deep(.career-status-progress .vertical-divider) {
    background: rgba(255, 255, 255, 0.28);
  }
  // money is the last value in CareerStatus: gold, icon included
  :deep(.career-status-progress > .career-status-value:last-child) {
    color: $money;
    --units-icon-color: #{$money};
  }

  .status-add {
    text-align: center;
    padding: 0.35rem 0.6rem 0.25rem; // Overpass sits high
    border-top: 1px solid rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.72);
    font-size: 0.9em;
    font-weight: 600;
  }
}

.main-content-slotted {
  flex: 1 1 auto;
  min-width: 0;
  height: 100%;
  overflow: hidden;
}

.side-content-slotted {
  flex: 0 0 33rem;
  display: flex;
  flex-direction: column;
  flex-wrap: nowrap;
  .task-list {
    width: 33rem;
    align-self: flex-start;
  }
}
</style>
