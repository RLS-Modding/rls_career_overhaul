<template>
  <div class="home-view">
    <BusinessVehicleCard v-if="store.pulledOutVehicle" :vehicle="store.pulledOutVehicle" @put-away="handlePutAway" />
    
    <div class="section-card">
      <div class="card-header">
        <div class="card-header-content">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="2" y="7" width="20" height="14" rx="2" ry="2"/>
            <path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>
          </svg>
          <h3>Active Jobs</h3>
        </div>
        <p class="card-description">Jobs currently in progress</p>
      </div>
      <div class="card-content">
        <div v-if="store.activeJobs.length === 0" class="empty-state">
          No active jobs
        </div>
        <div v-else class="jobs-list">
          <BusinessJobCard
            v-for="job in store.activeJobs"
            :key="job.id"
            :job="job"
            :is-active="true"
            @pull-out="handlePullOut"
            @put-away="handlePutAway"
            @abandon="handleAbandon"
          />
        </div>
      </div>
    </div>

    <div class="section-card">
      <div class="card-header">
        <div class="card-header-content">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="2" y="7" width="20" height="14" rx="2" ry="2"/>
            <path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>
          </svg>
          <h3>New Jobs</h3>
        </div>
        <p class="card-description">Available jobs ready to start</p>
      </div>
      <div class="card-content">
        <div v-if="store.newJobs.length === 0" class="empty-state">
          No new jobs available
        </div>
        <div v-else class="jobs-list">
          <BusinessJobCard
            v-for="job in store.newJobs.slice(0, 3)"
            :key="job.id"
            :job="job"
            :is-active="false"
            @accept="handleAccept"
            @decline="handleDecline"
          />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import BusinessVehicleCard from "./BusinessVehicleCard.vue"
import BusinessJobCard from "./BusinessJobCard.vue"

const store = useBusinessComputerStore()

const handlePullOut = async (job) => {
  if (!Array.isArray(store.vehicles)) {
    console.error("handlePullOut: vehicles is not an array", store.vehicles)
    return
  }
  
  const vehicle = store.vehicles.find(v => {
    return v.jobId == job.id || v.jobId === job.id || String(v.jobId) === String(job.id)
  })
  if (vehicle) {
    await store.pullOutVehicle(vehicle.vehicleId)
  } else {
    console.error("handlePullOut: No vehicle found for job.id", job.id, "Available vehicles:", store.vehicles.map(v => ({ vehicleId: v.vehicleId, jobId: v.jobId })))
  }
}

const handlePutAway = async () => {
  await store.putAwayVehicle()
}

const handleAbandon = async (job) => {
  await store.abandonJob(parseInt(job.id))
}

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
}
</script>

<style scoped lang="scss">
.home-view {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.section-card {
  background: rgba(26, 26, 26, 0.5);
  border: 1px solid rgba(245, 73, 0, 0.3);
  border-radius: 0.5rem;
  overflow: hidden;
}

.card-header {
  padding: 1rem 1.5rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.3);
}

.card-header-content {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 0.5rem;
  
  svg {
    color: rgba(245, 73, 0, 1);
    flex-shrink: 0;
  }
  
  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125rem;
    font-weight: 600;
  }
}

.card-description {
  margin: 0;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.875rem;
}

.card-content {
  padding: 1.5rem;
}

.jobs-list {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.empty-state {
  padding: 2rem;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}
</style>

