<template>
  <div class="new-jobs-tab">
    <div class="tab-header">
      <h2>New Jobs</h2>
      <p>Browse and accept new tuning opportunities</p>
    </div>
    
    <div class="jobs-grid">
      <BusinessJobCard
        v-for="job in store.newJobs"
        :key="job.id"
        :job="job"
        :is-active="false"
        :is-vertical="true"
        @accept="handleAccept"
        @decline="handleDecline"
      />
    </div>
    
    <div v-if="store.newJobs.length === 0" class="empty-state">
      No new jobs available
    </div>
  </div>
</template>

<script setup>
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import BusinessJobCard from "./BusinessJobCard.vue"

const store = useBusinessComputerStore()

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
}
</script>

<style scoped lang="scss">
.new-jobs-tab {
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

