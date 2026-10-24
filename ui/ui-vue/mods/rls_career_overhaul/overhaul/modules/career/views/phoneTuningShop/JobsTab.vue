<template>
  <div class="tab-panel jobs-panel" v-bng-on-ui-nav:tab_l="event => switchSubTab(event)" v-bng-on-ui-nav:tab_r="event => switchSubTab(event)">
    <div class="segment-control">
      <button :class="{ active: subTab === 'active' }" @click="emit('select-sub-tab', 'active')">
        In Progress ({{ activeJobs.length }})
      </button>
      <button :class="{ active: subTab === 'available' }" @click="emit('select-sub-tab', 'available')">
        Available ({{ newJobs.length }})
      </button>
    </div>

    <div class="jobs-scroll" v-bng-ui-nav-scroll>
      <template v-if="subTab === 'active'">
        <div v-if="activeJobs.length === 0" class="empty-state-mini">
          <span>No jobs in progress</span>
        </div>
        <div v-else class="jobs-list">
          <div v-for="job in activeJobs" :key="`active-${job.id}`" class="job-card" :class="{ 'has-tech': job.techAssigned }">
            <div class="job-card-image">
              <img :src="job.vehicleImage" :alt="job.vehicleName" />
              <div v-if="job.techAssigned" class="tech-overlay">{{ getTechName(job.techAssigned) }}</div>
              <button type="button" v-else class="tech-overlay unassigned" @click.stop="emit('assign-job', job)">
                <span>+ Assign Tech</span>
              </button>
            </div>
            <div class="job-card-body">
              <div class="job-card-header">
                <span class="job-vehicle">{{ job.vehicleYear }} {{ job.vehicleName }}</span>
                <span class="job-reward">${{ job.reward.toLocaleString() }}</span>
              </div>
              <div class="job-goal">{{ job.goal }}</div>
              <div class="job-progress" v-if="job.techAssigned">
                <div class="progress-bar">
                  <div class="progress-fill" :style="{ width: `${getTechProgress(job.techAssigned)}%` }"></div>
                </div>
              </div>
              <div class="job-actions" v-if="!job.techAssigned">
                <div v-if="getCompletionBlockedMessage(job)" class="job-build-warning">
                  {{ getCompletionBlockedMessage(job) }}
                </div>
                <button v-if="canCompleteJob(job)" class="btn-complete" @click.stop="emit('complete', job)">Complete</button>
                <button class="btn-abandon" @click.stop="emit('abandon', job)">✕</button>
              </div>
            </div>
          </div>
        </div>
      </template>

      <template v-else>
        <div v-if="newJobs.length === 0" class="empty-state-mini">
          <span>No new jobs available</span>
        </div>
        <div v-else class="jobs-list">
          <div v-for="job in newJobs" :key="`new-${job.id}`" class="job-card new-job">
            <div class="job-card-image">
              <img :src="job.vehicleImage" :alt="job.vehicleName" />
              <div v-if="job.expiresInSeconds" class="expiry-badge" :class="{ urgent: job.expiresInSeconds < 60 }">
                {{ formatExpiry(job.expiresInSeconds) }}
              </div>
            </div>
            <div class="job-card-body">
              <div class="job-card-header">
                <span class="job-vehicle">{{ job.vehicleYear }} {{ job.vehicleName }}</span>
                <span class="job-reward">${{ job.reward.toLocaleString() }}</span>
              </div>
              <div class="job-goal">{{ job.goal }}</div>
              <div class="job-actions">
                <button class="btn-accept" @click.stop="emit('accept', job)">Accept</button>
                <button class="btn-decline" @click.stop="emit('decline', job)">✕</button>
              </div>
            </div>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<script setup>
function switchSubTab(event) { event?.stopPropagation(); emit('select-sub-tab', props.subTab === 'active' ? 'available' : 'active') }
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
// Jobs tab of the phone Tuning Shop: the In Progress and Available sub-tabs. Presentational. Every action is an
// event (the parent view makes the store and Lua calls). The sub-tab is owned by the parent so it survives tab
// switches. Status lookups come in as functions so the completion cache stays in the view.
import { formatExpiry } from "../../utils/businessUtils"

const props = defineProps({
  subTab: { type: String, required: true },
  activeJobs: { type: Array, required: true },
  newJobs: { type: Array, required: true },
  getTechName: { type: Function, required: true },
  getTechProgress: { type: Function, required: true },
  getCompletionBlockedMessage: { type: Function, required: true },
  canCompleteJob: { type: Function, required: true },
})

const emit = defineEmits(['select-sub-tab', 'assign-job', 'complete', 'abandon', 'accept', 'decline'])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/views/phoneTuningShop/tokens" as *;

.segment-control {
  display: flex;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 0.5em;
  padding: 0.25em;
  margin: 0.75em 0.75em 0.75em 0.75em;
  position: sticky;
  top: 0;
  z-index: 5;

  button {
    flex: 1;
    background: transparent;
    border: none;
    color: $text-secondary;
    padding: 0.5em;
    font-size: 0.75em;
    font-weight: 600;
    border-radius: 0.35em;
    cursor: pointer;
    transition: all 0.2s;

    &.active {
      background: rgba(255, 255, 255, 0.1);
      color: $text-primary;
    }
  }
}

.jobs-scroll { padding: 0 0.75em; }
.jobs-list { display: flex; flex-direction: column; gap: 0.75em; }

.empty-state-mini {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 3em 1em;
  color: $text-muted;
  gap: 0.5em;
}

.job-card {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.75em;
  overflow: hidden;
  transition: border-color 0.2s;

  &.has-tech { border-left: 3px solid $accent; }
  &.new-job { border-left: 3px solid #3b82f6; }
}

.job-card-image {
  position: relative;
  height: 80px;

  img { width: 100%; height: 100%; object-fit: cover; }
}

.tech-overlay {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 0.35em 0.6em;
  background: linear-gradient(transparent, rgba(0, 0, 0, 0.85));
  font-size: 0.7em;
  font-weight: 600;
  color: $accent-light;

  &.unassigned {
      font-family: inherit; border: 0; width: 100%;
    background: rgba($accent, 0.9);
    color: white;
    cursor: pointer;
    text-align: center;
    padding: 0.5em;
    transition: background 0.2s;

    &:hover { background: $accent; }
  }
}

.expiry-badge {
  position: absolute;
  top: 0.4em;
  right: 0.4em;
  background: rgba(0, 0, 0, 0.75);
  color: white;
  font-size: 0.65em;
  font-weight: 600;
  padding: 0.2em 0.5em;
  border-radius: 0.25em;

  &.urgent { background: $negative; }
}

.job-card-body { padding: 0.6em; }

.job-card-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 0.25em;
}

.job-vehicle {
  font-size: 0.8em;
  font-weight: 600;
  color: $text-primary;
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-right: 0.5em;
}

.job-reward {
  font-size: 0.85em;
  font-weight: 700;
  color: $positive;
  flex-shrink: 0;
}

.job-goal {
  font-size: 0.7em;
  color: $text-secondary;
  margin-bottom: 0.5em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-progress { margin-bottom: 0.35em; }

.progress-bar {
  height: 4px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 2px;
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: $accent;
  transition: width 0.3s;
}

.job-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
  justify-content: flex-end;
}

.job-build-warning {
  flex: 1 1 100%;
  color: #ef4444;
  font-size: 0.65em;
  font-weight: 600;
  text-align: right;
  line-height: 1.2;
}

.btn-accept, .btn-complete {
  background: $positive;
  color: white;
  border: none;
  padding: 0.4em 1em;
  border-radius: 0.35em;
  font-size: 0.75em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;

  &:hover { filter: brightness(1.1); }
}

.btn-decline, .btn-abandon {
  background: rgba($negative, 0.15);
  color: $negative;
  border: none;
  width: 28px;
  height: 28px;
  border-radius: 0.35em;
  font-size: 0.9em;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: all 0.2s;

  &:hover { background: rgba($negative, 0.25); }
}
</style>
