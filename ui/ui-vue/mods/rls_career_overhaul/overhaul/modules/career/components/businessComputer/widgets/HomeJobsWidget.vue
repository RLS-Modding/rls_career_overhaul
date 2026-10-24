<template>
  <div class="rls-house home-widget jobs-widget" :class="{ 'home-widget--compact': compact }">
    <div class="widget-header">
      <h3>{{ sessionStore.hasCapability('fleetVehicles') ? 'Driver Overview' : 'Jobs Overview' }}</h3>
      <div v-if="!sessionStore.hasCapability('fleetVehicles')" class="seg bar tabs">
        <button type="button" :class="{ active: activeTab === 'active' }" @click="activeTab = 'active'">
          Active <span class="count">{{ sessionStore.activeJobs.length }}</span>
        </button>
        <button type="button" :class="{ active: activeTab === 'new' }" @click="activeTab = 'new'">
          New <span class="count">{{ sessionStore.newJobs.length }}</span>
        </button>
      </div>
    </div>

    <div class="widget-content" :bng-nav-item="sessionStore.hasCapability('fleetVehicles') ? true : null" :tabindex="sessionStore.hasCapability('fleetVehicles') ? 0 : null" aria-label="Job and driver overview" v-bng-ui-nav-scroll.force>
      <template v-if="sessionStore.hasCapability('fleetVehicles')">
        <div v-if="!driverCards.length" class="empty-state">
          <p>No drivers to show.</p>
        </div>
        <div v-else :class="compact ? 'drivers-list-compact' : 'drivers-grid'">
          <div v-for="d in displayDriverCards" :key="d.id" class="driver-card">
            <span class="driver-card__name">{{ d.name }}</span>
            <span class="driver-card__car">{{ d.fleetLabel }}</span>
          </div>
        </div>
      </template>
      <template v-else>
        <div v-if="currentList.length === 0" class="empty-state">
          <p>No {{ activeTab }} jobs available.</p>
        </div>
        <div v-else class="jobs-grid">
          <div v-for="job in displayList" :key="job.id || job.jobId" class="grid-item">
            <BusinessJobCard
              :job="job"
              :is-active="activeTab === 'active'"
              :business-id="sessionStore.businessId"
              layout="compact"
              @pull-out="$emit('pull-out', job)"
              @put-away="$emit('put-away', job)"
              @abandon="$emit('abandon', job)"
              @complete="$emit('complete', job)"
              @accept="$emit('accept', job)"
              @decline="$emit('decline', job)"
            />
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<script setup>
import { vBngUiNavScroll } from "@/common/directives"
import { ref, computed } from "vue"
import { useBusinessSessionStore } from "../../../stores/businessComputer/businessSessionStore.js"
import { useBusinessTechsStore } from "../../../stores/businessComputer/businessTechsStore.js"
import BusinessJobCard from "../BusinessJobCard.vue"

const props = defineProps({
  compact: { type: Boolean, default: false },
})

defineEmits(["open-tab", "pull-out", "put-away", "abandon", "complete", "accept", "decline"])

const sessionStore = useBusinessSessionStore()
const techsStore = useBusinessTechsStore()
const activeTab = ref("active")

const currentList = computed(() => {
  return activeTab.value === "active" ? sessionStore.activeJobs : sessionStore.newJobs
})

const displayList = computed(() => {
  return currentList.value.slice(0, 8)
})

const driverCards = computed(() => {
  const list = techsStore.techs
  if (!Array.isArray(list)) return []
  return list
    .filter((t) => t && !t.fired)
    .map((t) => ({
      id: t.id,
      name: t.name || `Driver #${t.id}`,
      fleetLabel: t.fleetVehicleName || "No fleet car assigned",
    }))
})

const displayDriverCards = computed(() => {
  const max = props.compact ? 5 : 8
  return driverCards.value.slice(0, max)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.home-widget {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.widget-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  padding: 0.8em var(--inset) 0.55em;
  flex-shrink: 0;

  h3 {
    margin: 0;
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }
}

.tabs {
  flex: 0 0 auto;

  button {
    font-size: 0.85em;
    white-space: nowrap;
  }

  .count {
    margin-left: 0.2em;
    color: var(--faint);
    font-variant-numeric: tabular-nums;
  }

  button.active .count {
    color: #fff;
  }
}

.widget-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 0.15em var(--inset) var(--inset);
}

.jobs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(15em, 1fr));
  gap: 0.75em;
}

.grid-item {
  height: 100%;
  min-width: 0;
}

.drivers-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(12.5em, 1fr));
  gap: 0.5em;
}

.drivers-list-compact {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.driver-card {
  display: grid;
  gap: 0.2em;
  min-width: 0;
  padding: 0.65em 0.8em 0.55em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.driver-card__name {
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
}

.driver-card__car {
  font-size: 0.85em;
  font-weight: 600;
  color: var(--faint);
}

.empty-state {
  padding: 2em 1em;
  text-align: center;
  color: var(--faint);
  font-weight: 600;

  p {
    margin: 0;
  }
}

.home-widget--compact {
  min-height: 0;
  height: auto;
  flex-shrink: 0;

  .widget-header {
    padding: 0.42em 0.55em;
  }

  .widget-content {
    padding: 0.2em 0.55em 0.5em;
  }

  .driver-card {
    padding: 0.4em 0.5em 0.35em;
  }

  .driver-card__name {
    font-size: 0.85em;
  }

  .driver-card__car {
    font-size: 0.75em;
  }

  .empty-state {
    padding: 0.75em;
    font-size: 0.8em;
  }
}
</style>
