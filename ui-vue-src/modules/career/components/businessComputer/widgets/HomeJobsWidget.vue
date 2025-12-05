<template>
  <div class="home-widget jobs-widget">
    <div class="widget-header">
      <h3>Jobs Overview</h3>
      <div class="tabs">
        <button :class="{ active: activeTab === 'active' }" @click="activeTab = 'active'" data-focusable>
          Active ({{ store.activeJobs.length }})
        </button>
        <button :class="{ active: activeTab === 'new' }" @click="activeTab = 'new'" data-focusable>
          New ({{ store.newJobs.length }})
        </button>
      </div>
    </div>

    <div class="widget-content">
      <div v-if="currentList.length === 0" class="empty-state">
        <p>No {{ activeTab }} jobs available.</p>
      </div>
      <div v-else class="jobs-grid">
        <div v-for="job in displayList" :key="job.id || job.jobId" class="grid-item">
          <BusinessJobCard :job="job" :is-active="activeTab === 'active'" :business-id="store.businessId"
            layout="compact" @pull-out="$emit('pull-out', job)" @put-away="$emit('put-away', job)"
            @abandon="$emit('abandon', job)" @complete="$emit('complete', job)" @accept="$emit('accept', job)"
            @decline="$emit('decline', job)" />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from "vue"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import BusinessJobCard from "../BusinessJobCard.vue"

const store = useBusinessComputerStore()
const activeTab = ref('active')

const currentList = computed(() => {
  return activeTab.value === 'active' ? store.activeJobs : store.newJobs
})

const displayList = computed(() => {
  // No strict limit, let grid handle it, or maybe limit to 6-8
  return currentList.value.slice(0, 8)
})

defineEmits(['pull-out', 'put-away', 'abandon', 'complete', 'accept', 'decline'])
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1em;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.widget-header {
  padding: 1em 1.25em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1.1em;
    font-weight: 600;
    color: #fff;
  }
}

.tabs {
  display: flex;
  gap: 0.5em;
  background: rgba(0, 0, 0, 0.3);
  padding: 0.25em;
  border-radius: 0.5em;

  button {
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.6);
    padding: 0.35em 0.75em;
    border-radius: 0.25em;
    font-size: 0.8em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;

    &:hover {
      color: #fff;
    }

    &.active {
      background: rgba(255, 255, 255, 0.1);
      color: #fff;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
    }
  }
}

.widget-content {
  padding: 1em;
  flex: 1;
  overflow-y: auto;

  &::-webkit-scrollbar {
    width: 6px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.1);
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 3px;
  }
}

.jobs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 1em;
}

.grid-item {
  height: 100%;
}

.empty-state {
  text-align: center;
  padding: 2em;
  color: rgba(255, 255, 255, 0.4);
  font-style: italic;
}
</style>
