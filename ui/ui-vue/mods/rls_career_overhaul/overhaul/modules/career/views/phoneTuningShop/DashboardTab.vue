<template>
  <div class="tab-panel dashboard-panel">
    <div class="stats-row">
      <div class="stat-card">
        <span class="stat-value">{{ activeJobCount }}</span>
        <span class="stat-label">Active</span>
      </div>
      <div class="stat-card">
        <span class="stat-value">{{ workingTechCount }}</span>
        <span class="stat-label">Working</span>
      </div>
      <div class="stat-card accent">
        <span class="stat-value">{{ formatCurrency(accountBalance) }}</span>
        <span class="stat-label">Balance</span>
      </div>
    </div>

    <div class="section" v-if="idleTechs.length > 0">
      <div class="section-header alert">
        <span class="alert-dot"></span>
        <span>{{ idleTechs.length }} tech{{ idleTechs.length > 1 ? 's' : '' }} idle</span>
      </div>
      <div class="idle-techs-row">
        <button type="button" v-for="tech in idleTechs.slice(0, 3)" :key="tech.id" class="idle-tech-chip" @click="emit('assign-tech', tech)">
          {{ tech.name }}
          <span class="assign-hint">+</span>
        </button>
      </div>
    </div>

    <div class="section">
      <div class="section-header">
        <span>Jobs In Progress</span>
        <span class="section-count">{{ jobsInProgress.length }}</span>
      </div>
      <div v-if="jobsInProgress.length === 0" class="empty-mini">No active jobs</div>
      <div v-else class="jobs-mini-list">
        <div v-for="job in jobsInProgress.slice(0, 4)" :key="job.id" class="job-mini-card">
          <img :src="job.vehicleImage" class="job-mini-img" />
          <div class="job-mini-info">
            <span class="job-mini-name">{{ job.vehicleName }}</span>
            <span class="job-mini-goal">{{ job.goal }}</span>
          </div>
          <div class="job-mini-status">
            <span v-if="job.techAssigned" class="tech-badge">{{ getTechName(job.techAssigned) }}</span>
            <span v-else class="unassigned-badge">Unassigned</span>
          </div>
        </div>
      </div>
    </div>

    <div class="section">
      <div class="section-header">
        <span>24h Performance</span>
      </div>
      <div class="finance-mini">
        <span class="change-value" :class="periodChange >= 0 ? 'positive' : 'negative'">
          {{ periodChange >= 0 ? '+' : '' }}{{ formatCurrency(periodChange) }}
        </span>
        <span class="change-label">from yesterday</span>
      </div>
    </div>
  </div>
</template>

<script setup>
// Dashboard tab of the phone Tuning Shop. Presentational: the parent view computes every value and handles the
// assign request. Props: counts and lists from the store, the 24 h change, and a tech-name lookup.
import { formatCurrency } from "../../utils/businessUtils"

defineProps({
  activeJobCount: { type: Number, required: true },
  workingTechCount: { type: Number, required: true },
  accountBalance: { type: Number, required: true },
  idleTechs: { type: Array, required: true },
  jobsInProgress: { type: Array, required: true },
  periodChange: { type: Number, required: true },
  getTechName: { type: Function, required: true },
})

const emit = defineEmits(['assign-tech'])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/views/phoneTuningShop/tokens" as *;

.stats-row {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.5em;
  margin-bottom: 1em;
}

.stat-card {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.75em;
  padding: 0.75em 0.5em;
  text-align: center;
  display: flex;
  flex-direction: column;
  gap: 0.25em;

  &.accent {
    border-color: rgba($accent, 0.3);
    background: rgba($accent, 0.08);
    .stat-value { color: $accent; }
  }
}

.stat-value { font-size: 1.1em; font-weight: 700; color: $text-primary; }
.stat-label { font-size: 0.65em; color: $text-muted; text-transform: uppercase; letter-spacing: 0.05em; }

.section { margin-bottom: 1em; }
.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 0.5em;
  font-size: 0.8em;
  font-weight: 600;
  color: $text-secondary;

  &.alert { color: $accent; }
}

.alert-dot {
  width: 6px;
  height: 6px;
  background: $accent;
  border-radius: 50%;
  margin-right: 0.5em;
  animation: pulse 1.5s infinite;
}

@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }

.section-count {
  background: rgba(255, 255, 255, 0.1);
  padding: 0.15em 0.5em;
  border-radius: 0.25em;
  font-size: 0.7em;
}

.idle-techs-row {
  display: flex;
  gap: 0.5em;
  flex-wrap: wrap;
}

.idle-tech-chip {
    font-family: inherit; text-align: left;
  background: rgba($accent, 0.15);
  border: 1px solid rgba($accent, 0.3);
  color: $accent-light;
  padding: 0.4em 0.75em;
  border-radius: 2em;
  font-size: 0.75em;
  font-weight: 600;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 0.35em;
  transition: all 0.2s;

  &:hover { background: rgba($accent, 0.25); }
  .assign-hint { opacity: 0.7; }
}

.empty-mini {
  color: $text-muted;
  font-size: 0.8em;
  text-align: center;
  padding: 1em;
  font-style: italic;
}

.jobs-mini-list { display: flex; flex-direction: column; gap: 0.5em; }

.job-mini-card {
  display: flex;
  align-items: center;
  gap: 0.6em;
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6em;
  padding: 0.5em;
}

.job-mini-img {
  width: 44px;
  height: 32px;
  object-fit: cover;
  border-radius: 0.3em;
}

.job-mini-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.job-mini-name {
  font-size: 0.75em;
  font-weight: 600;
  color: $text-primary;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-mini-goal {
  font-size: 0.65em;
  color: $text-muted;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-mini-status { flex-shrink: 0; }

.tech-badge, .unassigned-badge {
  font-size: 0.6em;
  font-weight: 600;
  padding: 0.2em 0.5em;
  border-radius: 0.25em;
  text-transform: uppercase;
}

.tech-badge { background: rgba($accent, 0.2); color: $accent-light; }
.unassigned-badge { background: rgba(255, 255, 255, 0.1); color: $text-muted; }

.finance-mini {
  background: $bg-card;
  border: 1px solid $border;
  border-radius: 0.6em;
  padding: 0.75em;
  display: flex;
  align-items: baseline;
  gap: 0.5em;
}

.change-value {
  font-size: 1.1em;
  font-weight: 700;
  &.positive { color: $positive; }
  &.negative { color: $negative; }
}

.change-label { font-size: 0.7em; color: $text-muted; }
</style>
