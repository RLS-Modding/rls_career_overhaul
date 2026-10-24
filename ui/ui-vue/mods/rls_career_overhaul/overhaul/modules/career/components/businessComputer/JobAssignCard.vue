<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <article class="rls-house job-assign-card">
    <div class="job-assign-card__photo">
      <img :src="job.vehicleImage" :alt="job.vehicleName" />
      <span class="photo-pill">{{ jobTierLabel }}</span>
    </div>
    <div class="job-assign-card__body">
      <div class="job-assign-card__head">
        <strong class="job-name" :title="`${job.vehicleYear || ''} ${job.vehicleName || ''}`.trim()">{{ job.vehicleYear }} {{ job.vehicleName }}</strong>
        <strong class="job-pay"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPayment(job.reward) }}</strong>
      </div>
      <span v-if="job.vehicleType" class="hint">{{ job.vehicleType }}</span>
      <div v-if="goalSummary" class="job-goal">
        <span class="caption">Goal</span>
        <span class="goal-value">{{ goalSummary }}</span>
      </div>
      <HouseButton
        variant="primary"
        block
        class="job-assign-card__button"
        :bng-scoped-nav-autofocus="navAutofocus ? true : null"
        @click.stop="$emit('assign', job)"
        @mousedown.stop
      >
        Assign
      </HouseButton>
    </div>
  </article>
</template>

<script setup>
import { computed } from "vue"
import { HouseButton } from "../house/index.js"
import { BngIcon, icons } from "@/common/components/base"

const props = defineProps({
  job: Object,
  // controller: the picker modal lands on the first card's Assign button
  navAutofocus: Boolean
})

const emit = defineEmits(['assign'])

const jobTier = computed(() => {
  const tier = props.job?.tier
  return typeof tier === "number" ? tier : 1
})

const jobTierLabel = computed(() => `Tier ${jobTier.value}`)

const goalTimeText = computed(() => {
  const goal = props.job?.goal
  if (!goal) {
    return ""
  }
  const raceLabel = props.job?.raceLabel
  if (raceLabel) {
    const suffix = ` ${raceLabel}`
    if (goal.endsWith(suffix)) {
      return goal.slice(0, goal.length - suffix.length).trim()
    }
  }
  return goal
})

const goalSummary = computed(() => {
  const raceLabel = props.job?.raceLabel
  const timeText = goalTimeText.value
  if (raceLabel && timeText) {
    return `${raceLabel}, ${timeText}`
  }
  return timeText || raceLabel || ""
})

const formatPayment = (amount) => {
  if (typeof amount !== 'number') return '0'
  return amount.toLocaleString()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.job-assign-card {
  display: flex;
  flex-direction: column;
  min-width: 0;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--panel);
}

.job-assign-card__photo {
  position: relative;
  width: 100%;
  aspect-ratio: 16 / 9;
  overflow: hidden;
  background: var(--photo);

  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.photo-pill {
  position: absolute;
  top: 0.55em;
  right: 0.55em;
  padding: 0.45em 0.6em 0.25em;
  border-radius: var(--radius-pill);
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  font-size: 0.78em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
}

.job-assign-card__body {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
  padding: var(--inset);
}

.job-assign-card__head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.2em 0.8em;
}

.job-name {
  flex: 1 1 9em;
  min-width: 0;
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
  /* long names: two lines, then ellipsis */
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.job-pay {
  flex: 0 0 auto;
  color: var(--money);
  font-size: 1.05em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.job-goal {
  display: grid;
  gap: 0.2em;

  .goal-value {
    color: #fff;
    font-size: 0.95em;
    font-weight: 600;
    line-height: 1.3;
    font-variant-numeric: tabular-nums;
  }
}

.job-assign-card__button {
  margin-top: auto;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
