<template>
  <div class="active-jobs-tab">
    <div class="tab-header">
      <h2>Active Jobs</h2>
      <p>Jobs you're currently working on</p>
    </div>
    
    <div class="jobs-grid">
      <BusinessJobCard
        v-for="job in store.activeJobs"
        :key="job.id"
        :job="job"
        :is-active="true"
        :is-vertical="true"
        :business-id="store.businessId"
        @pull-out="handlePullOut"
        @put-away="handlePutAway"
        @abandon="handleAbandon"
        @complete="handleComplete"
      />
    </div>
    
    <div v-if="store.activeJobs.length === 0" class="empty-state">
      No active jobs
    </div>
  </div>
</template>

<script setup>
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
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

const handleComplete = async (job) => {
  await store.completeJob(parseInt(job.id))
}
</script>

<style scoped lang="scss">
.active-jobs-tab {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.tab-header {
  h2 {
    margin: 0 0 0.5rem 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.5rem;
  }
  
  p {
    margin: 0;
    color: rgba(255, 255, 255, 0.6);
  }
}

.jobs-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 1em;
  
  @media (min-width: 1024px) {
    grid-template-columns: repeat(2, 1fr);
  }
}

.empty-state {
  padding: 3rem;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}
</style>

