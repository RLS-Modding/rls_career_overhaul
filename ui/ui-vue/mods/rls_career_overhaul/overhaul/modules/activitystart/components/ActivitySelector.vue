<template>
  <div class="activity-selector">
    <div class="activities-container">
      <div
        v-for="activity in activities"
        :key="activity"
        class="activity-icon"
        :class="{ highlighted: activity.value === selectedValue }"
        @click="onValueChanged(activity.value)">
        <span v-if="isGlyph(activity.icon)" class="glyph-badge"><BngIcon :type="icons[activity.icon]" /></span>
        <BngSpriteIcon v-else :src="'map_' + activity.icon" style="width: 100%; height: 100%" />
      </div>
    </div>
    <BngSelect
      ref="selectComponent"
      :value="selectedValue"
      :options="activityOptions"
      :config="selectConfig"
      bng-no-nav
      mute
      loop
      @change="onValueChanged"
      :navLeftEvent="navLeftEvent"
      :navRightEvent="navRightEvent"
    >
      <template #display="{ label }">
        <div class="selector-display">
          <span>{{ label }}</span>
          <BngDivider />
          <span>{{ activities.length }}</span>
        </div>
      </template>
    </BngSelect>
  </div>
</template>

<script>
const selectConfig = {
  label: x => x.label,
  value: x => x.value,
}
</script>

<script setup>
import { computed, ref, watch } from "vue"
import { BngSelect, BngDivider, BngSpriteIcon, BngIcon, icons } from "@/common/components/base"
import { getAssetURL } from "@/utils"

const props = defineProps({
  activities: {
    type: Array,
    required: true,
  },
  value: {
    type: [String, Number],
  },
  navLeftEvent: {
    type: String,
  },
  navRightEvent: {
    type: String,
  },
})

const selectComponent = ref()

// map sprites are named poi_* / mission_*; a name that is a glyph in the icon font draws as that glyph
const isGlyph = name => typeof name === "string" && !/^(poi_|mission_)/.test(name) && !!icons[name]

const emit = defineEmits(["valueChanged"])

const activityOptions = computed(() => props.activities.map((x, index) => ({ label: index + 1, value: x.value })))
const selectedOption = computed(
  () => (activityOptions.value ? activityOptions.value.find(x => x.value === selectedValue.value) : null) || { label: "?", value: selectedValue.value }
)
const selectedValue = ref(1)

watch(
  () => props.value,
  val => (selectedValue.value = val || props.activities[0].value),
  { immediate: true }
)

const onValueChanged = value => {
  selectedValue.value = value
  emit("valueChanged", value)
}

defineExpose({
  goNext: () => selectComponent.value.goNext(),
  goPrev: () => selectComponent.value.goPrev(),
})

const defaultMissionIcon = computed(() => `url("${getAssetURL("icons/temp_debug/map_poi_target.svg")}")`)
</script>

<style scoped lang="scss">
@use "@/styles/modules/density" as *;

.activity-selector {
  display: flex;
  flex-direction: column;
  flex-wrap: nowrap;
  align-items: stretch;
  justify-content: flex-start;
  min-width: 10rem;

  > .activities-container {
    display: flex;
    justify-content: center;
    align-items: flex-end;
    height: 4rem;
    border-radius: $border-rad-1;
    margin-bottom: 0.5rem;
    align-items: center;

    > .activity-icon {
      background: center / contain no-repeat;
      width: 3rem;
      height: 3rem;
      transition: all 0.2s ease;

      &:not(:last-child) {
        margin-right: 0.25rem;
      }

      > .glyph-badge {
        display: grid;
        place-items: center;
        width: 100%;
        height: 100%;
        border-radius: 50%;
        background: var(--bng-orange-b400, #ff6600);
        box-shadow: inset 0 0 0 0.15rem #fff;
        color: #fff;
        font-size: 1.5rem;
      }

      &.highlighted {
        width: 3.5rem;
        height: 3.5rem;
        filter: drop-shadow(0rem 0.125rem 0.5rem var(--bng-orange-500));
      }
    }
  }

  :deep(.bng-select) {
    padding: 0 0 0.25rem 0;
  }

  .selector-display {
    display: flex;
    flex-direction: row;
    flex-wrap: nowrap;
    align-items: center;
    justify-content: center;
    color: white;
  }
}
</style>
