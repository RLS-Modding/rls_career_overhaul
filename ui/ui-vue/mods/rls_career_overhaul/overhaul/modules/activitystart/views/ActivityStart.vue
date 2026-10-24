<template>
  <div
    v-if="selectedActivity"
    class="activity-start"
    v-bng-scoped-nav="{
      scopeId: 'activityStart',
      type: 'nonav',
      activateOnMount: true,
      trapPolicy: 'always'
    }"
    v-bng-on-ui-nav:tab_l.up="goPrev"
    v-bng-on-ui-nav:tab_r.up="goNext"
    v-bng-on-ui-nav:menu="openPauseMenu"
  >
    <ActivitySelector
      ref="activitySelector"
      v-if="activityOptions && activityOptions.length > 1"
      :activities="activityOptions"
      :value="selectedActivityIndex"
      @valueChanged="onActivitySelected"
      navLeftEvent="tab_l"
      navRightEvent="tab_r"
    />
    <BngScreenHeading
      v-if="selectedActivity.heading"
      mute divider
      :preheadings="preheadings"
      :blur-delay="400"
    >
      {{ $ctx_t(selectedActivity.heading) }}<template v-if="selectedActivity.description">: {{ $ctx_t(selectedActivity.description) }}</template>
    </BngScreenHeading>
    <div class="activity-props">
      <BngMainStars
        v-if="selectedActivity.stars && selectedActivity.stars.defaultStarCount"
        :unlocked-stars="selectedActivity.stars.defaultUnlockedStarCount"
        :total-stars="selectedActivity.stars.defaultStarCount"
        class="main-stars" />
      <BngMainStars
        v-if="selectedActivity.stars && selectedActivity.stars.bonusStarCount"
        :unlocked-stars="selectedActivity.stars.bonusStarsUnlockedCount"
        :total-stars="selectedActivity.stars.bonusStarCount"
        class="bonus-stars" />
      <BngPropVal
        v-for="(label, index) of selectedActivity.labels"
        :key="index"
        :class="{ 'is-warning': label.warning }"
        :iconType="label.icon"
        :keyLabel="label.keyLabel"
        :valueLabel="label.valueLabel" />
    </div>
    <div v-if="!selectedActivity.startable && selectedActivity.reasonShown" class="activity-locked">
      <BngIcon :type="icons.lockClosed" class="locked-icon" />
      <span>{{ $ctx_t(selectedActivity.disableReason) }}</span>
    </div>
    <div>
      <BngButton
        :accent="ACCENTS.main"
        :disabled="!selectedActivity.startable"
        v-bng-on-ui-nav:gameplay_interact.asMouse
        bng-no-nav
        @click="invokeActivityAction"
        :sound-class="selectedActivity.buttonSoundClass"
      >
      <span class="binding-spacer">
        <BngBinding action="gameplay_interact"/>
      </span>
      {{ selectedActivity.startable || selectedActivity.disableReason ? $ctx_t(selectedActivity.buttonLabel) : $tt("ui.mission.action.locked") }}
      </BngButton>
      <BngButton
        :accent="ACCENTS.text"
        v-bng-on-ui-nav:back.asMouse
        bng-no-nav
        @click="onCancel"
      >
        <BngBinding ui-event="back" controller />
        {{ $tt("ui.common.close") }}
      </BngButton>
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeMount, onMounted, ref, onUnmounted, watch } from "vue"
import { storeToRefs } from "pinia"
import { BngButton, ACCENTS, BngScreenHeading, BngPropVal, BngMainStars, BngBinding, BngIcon, icons } from "@/common/components/base"
import { vBngScopedNav } from "@/common/directives"
import { $translate } from "@/services"
import { useOverhaulActivityPromptStore } from "../activityPromptStore.js"
import { vBngOnUiNav } from "@/common/directives"
import { lua } from "@/bridge"
import { getUINavServiceInstance, UI_EVENT_GROUPS } from "@/services/uiNav"
import ActivitySelector from "../components/ActivitySelector.vue"

getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)

const activitySelector = ref(null)
const goNext = () => {
  activitySelector.value && activitySelector.value.goNext()
}
const goPrev = () => {
  activitySelector.value && activitySelector.value.goPrev()
}

const promptStore = useOverhaulActivityPromptStore()

const { activities } = storeToRefs(promptStore)

const selectedActivityIndex = ref(0)
const availableActivities = ref([])
const activityOptions = computed(() => {
  return availableActivities.value ? availableActivities.value.map((x, index) => ({ id: index, value: index, icon: x.icon })) : []
})

const BNG_MAIN_STARS_TYPE = "BngMainStars"
// chips whose glyph says "blocked" read as warnings (Lua marks a blocking fact with one of these)
const WARNING_ICONS = new Set(["abandon", "warning", "danger", "xmark", "lockClosed"])
const disableReasonOf = activity => {
  const r = activity.disableReason ?? activity.disabledReason
  return typeof r === "string" && r.trim() ? r : null
}

const selectedActivity = computed(() => {
  if (selectedActivityIndex.value < 0 || !availableActivities.value || availableActivities.value.length === 0) return null

  const activity = availableActivities.value[selectedActivityIndex.value]
  const labels = activity.props && activity.props.length > 0 ? activity.props.filter(x => !x.type) : []

  return {
    heading: activity.heading,
    description: activity.description,
    icon: activity.icon,
    preheadings: activity.preheadings,
    labels: labels.map(x => ({ keyLabel: $translate.instant(x.keyLabel), valueLabel: $translate.instant(x.valueLabel), icon: icons[x.icon], warning: WARNING_ICONS.has(x.icon) })),
    stars: activity.props && activity.props.length > 0 ? activity.props.find(x => x.type === BNG_MAIN_STARS_TYPE) : null,
    // the game hard-coded true, so a locked entry still showed a live button
    startable: activity.disabled !== true && activity.startable !== false,
    disableReason: disableReasonOf(activity),
    // the lock line only when no chip already says the same thing
    reasonShown: !!disableReasonOf(activity) && !labels.some(x => {
      const reason = $translate.instant(disableReasonOf(activity)).toLowerCase()
      const text = ($translate.instant(x.valueLabel || '') + ' ' + $translate.instant(x.keyLabel || '')).toLowerCase()
      return text.includes(reason) || (x.valueLabel && reason.includes($translate.instant(x.valueLabel).toLowerCase()))
    }),
    buttonLabel: activity.buttonLabel,
    action: activity.action,
    missionInfoPerformActionIndex: activity.missionInfoPerformActionIndex,
    buttonSoundClass: activity.buttonSoundClass,
  }
})

const preheadings = computed(() =>
  selectedActivity.value && selectedActivity.value.preheadings ? selectedActivity.value.preheadings.map(x => $translate.contextTranslate(x)) : []
)

const invokeActivityAction = () => {
  // also reached by Shift+E (gameplay_interact) on a locked entry
  if (!selectedActivity.value?.startable) return
  lua.ui_missionInfo.performActivityAction(selectedActivity.value.missionInfoPerformActionIndex)
}

watch(selectedActivity, () => {
  lua.ui_missionInfo.setActivityIndexVisible(selectedActivityIndex.value)
})

const onActivitySelected = value => {
  selectedActivityIndex.value = value
}

// Close/Back is the player saying no: dismiss this place's prompt until they leave the marker.
const onCancel = () => {
  promptStore.dismiss()
}

const openPauseMenu = () => {
  onCancel()
  window.globalAngularRootScope && window.globalAngularRootScope.$broadcast("MenuToggle")
}

onBeforeMount(() => {
  availableActivities.value = activities.value
})

onMounted(() => {
  if (availableActivities.value?.length > 0) {
    lua.Engine.Audio.playOnce("AudioGui", "event:>UI>Missions>Info_Open")
  }
})

onUnmounted(() => {
  getUINavServiceInstance().clearFilteredEvents()
  lua.ui_missionInfo.setActivityIndexVisible(-1)
})
</script>

<style lang="scss" scoped>
@use "@/styles/modules/density" as *;

// house tokens (career rlsHouse.scss values): near-black surfaces with a faint ring, gold-free here
$house-black: rgba(21, 21, 23, 0.9);
$house-ring: 0 0 0 1px rgba(255, 255, 255, 0.07);
$house-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
$radius: 0.45rem;
$muted: rgba(255, 255, 255, 0.72);
$faint: rgba(255, 255, 255, 0.5);
$bad: #fca5a5;

.activity-start {
  display: flex;
  flex-direction: column;
  flex-wrap: nowrap;
  align-items: flex-start;
  justify-content: flex-start;
  padding-left: 5rem;
  max-width: 56em;

  > * {
    margin-bottom: 0.5rem;
  }

  // heading: same near-black chip as the computer screens' title
  .bng-screen-heading {
    margin-left: -5rem;
    max-width: 40rem;
    :deep(> .header) {
      background: $house-black;
      box-shadow: $house-ring, $house-shadow;
    }
    :deep(> .pre-header) {
      background: $house-black;
      color: $muted;
      font-weight: 700;
    }
  }

  // chips: icon + key (muted) + value (white), house black with a faint ring
  > .activity-props {
    display: flex;
    flex-direction: row;
    flex-wrap: wrap;
    margin: -0.2rem;

    --paddings: 0.3em 0.6em;

    & > * {
      margin: 0.2rem;
      min-height: 2rem;
    }

    > :deep(.info-item) {
      border-radius: $radius;
      background-color: $house-black;
      box-shadow: $house-ring;
      color: #fff;
      align-items: center;
      font-weight: 700;
      &:not(.with-icon) {
        padding: 0.25rem 0.75rem;
      }
      .key-label,
      .info-key {
        color: $muted;
        font-weight: 600;
      }
      .bng-icon,
      .icon-base {
        color: $faint;
      }
    }

    > .main-stars,
    > .bonus-stars {
      padding: 0.25rem 0.5rem;
      display: flex;
      flex-direction: row;
      flex-wrap: nowrap;
      align-items: center;
      justify-content: center;
      border-radius: $radius;
      background-color: $house-black;
      box-shadow: $house-ring;
    }
    > .main-stars {
      --star-color: var(--bng-ter-yellow-50);
    }
    > .bonus-stars {
      --star-color: var(--bng-add-blue-400);
    }
  }

  > :nth-last-child(2) {
    margin-bottom: 1rem;
  }

  > .details-button {
    border: 1px solid var(--bng-orange-b400);
  }

  // locked: why the main action is unavailable
  > .activity-locked {
    // the chip row above pulls itself up with a negative margin; without this the reason touched the chips
    margin-top: 0.3rem;
    display: flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.4rem 0.8rem 0.3rem;
    border-radius: $radius;
    background-color: $house-black;
    box-shadow: 0 0 0 1px rgba(252, 165, 165, 0.25);
    color: $bad;
    font-weight: 700;
    .locked-icon {
      transform: translateY(-0.08em);
    }
  }

  > .activity-props > :deep(.info-item.is-warning) {
    color: $bad;
    box-shadow: 0 0 0 1px rgba(252, 165, 165, 0.25);
    .bng-icon,
    .icon-base,
    .key-label,
    .info-key {
      color: $bad !important;
    }
  }

  // actions: solid orange main action, near-black Close (same BngButtons, house colours and shape)
  :deep(.bng-button) {
    --bng-bg-border-radius: #{$radius};
    --bng-button-padding: 0.5em 1.1em;
    --bng-button-padding-top: 0.5em;
    --bng-button-padding-bottom: 0.4em;
    font-weight: 800;
    margin-right: 0.4rem;
  }
  :deep(.bng-button[accent="main"]) {
    --bng-bg-enabled: var(--bng-orange-b400, #ff6600);
    --bng-bg-hover: #ff7a1f;
    --bng-bg-active: #e65c00;
    --bng-bg-enabled-opacity: 1;
    --bng-bg-hover-opacity: 1;
    --bng-bg-active-opacity: 1;
    // locked: a dimmed near-black button (a faint white tint vanished over bright scenery)
    --bng-bg-disabled: rgb(21, 21, 23);
    --bng-bg-disabled-opacity: 0.75;
    --bng-button-text-disabled-color: #{$faint};
    box-shadow: $house-shadow;
  }
  :deep(.bng-button[accent="text"]) {
    --bng-bg-enabled: rgb(21, 21, 23);
    --bng-bg-enabled-opacity: 0.9;
    --bng-bg-hover: rgb(44, 44, 48);
    --bng-bg-hover-opacity: 0.95;
    --bng-bg-active: rgb(56, 56, 60);
    --bng-bg-active-opacity: 1;
    box-shadow: $house-ring, $house-shadow;
    border-radius: $radius;
  }

  // key hint before the label; when no hint is shown the spacer is empty and must not take space,
  // or the label sits off-centre to the right
  .binding-spacer {
    margin-right: 0.5rem;
    margin-top: 0.15rem;
    &:empty {
      display: none;
    }
  }

  // activity selector (1 / 2): house black instead of the translucent grey
  :deep(.activity-selector .bng-select) {
    background: $house-black;
    box-shadow: $house-ring;
  }
}
</style>
