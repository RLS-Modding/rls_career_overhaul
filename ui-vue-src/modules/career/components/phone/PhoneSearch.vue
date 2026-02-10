<template>
  <div class="phone-search">
    <div class="search-input-wrap">
      <svg class="search-icon-svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="11" cy="11" r="8"/>
        <line x1="21" y1="21" x2="16.65" y2="16.65"/>
      </svg>
      <input
        ref="searchInputRef"
        v-model="query"
        v-bng-text-input
        class="search-input"
        placeholder="Search apps..."
      />
    </div>
    <div class="search-results">
      <div
        v-for="app in filteredApps"
        :key="app.id"
        class="search-result-item"
        @click="$emit('launch', app)"
      >
        <div class="search-result-icon" :style="{ backgroundColor: app.color }">
          <BngIcon :type="app.icon" :style="{ color: app.iconColor }" />
        </div>
        <div class="search-result-info">
          <span class="search-result-name">{{ app.name }}</span>
          <span class="search-result-category" v-if="app.category">{{ app.category }}</span>
        </div>
        <span class="search-result-new" v-if="!seenApps.has(app.id)">NEW</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'
import { BngIcon } from '@/common/components/base'
import { vBngTextInput } from '@/common/directives'

const props = defineProps({
  apps: { type: Array, required: true },
  seenApps: { type: Set, default: () => new Set() },
})

defineEmits(['launch'])

const query = ref('')
const searchInputRef = ref(null)

const filteredApps = computed(() => {
  const sorted = [...props.apps].sort((a, b) => a.name.localeCompare(b.name))
  if (!query.value.trim()) return sorted
  const q = query.value.toLowerCase()
  return sorted.filter(a =>
    a.name.toLowerCase().includes(q) ||
    (a.category && a.category.toLowerCase().includes(q))
  )
})

// Input handled by v-bng-text-input directive
</script>

<style scoped lang="scss">
.phone-search {
  display: flex;
  flex-direction: column;
  height: 100%;
  padding: 52px 0 8px;
}

.search-input-wrap {
  display: flex;
  align-items: center;
  background: rgba(255, 255, 255, 0.12);
  border-radius: 999px;
  width: min(100%, 300px);
  align-self: center;
  padding: 7px 12px;
  margin: 0 auto 12px;
}

.search-icon-svg {
  margin-right: 8px;
  opacity: 0.6;
  color: rgba(255, 255, 255, 0.8);
  flex-shrink: 0;
}

.search-input {
  flex: 1;
  background: none;
  border: none;
  outline: none;
  color: white;
  font-size: 14px;
  font-family: inherit;

  &::placeholder {
    color: rgba(255, 255, 255, 0.45);
  }
}

.search-results {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 2px;

  &::-webkit-scrollbar {
    width: 4px;
  }
  &::-webkit-scrollbar-track {
    background: transparent;
  }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.25);
    border-radius: 2px;
  }
  &::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.4);
  }
}

.search-result-item {
  display: flex;
  align-items: center;
  padding: 8px;
  border-radius: 12px;
  cursor: pointer;
  transition: background 0.15s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.1);
  }
}

.search-result-icon {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.6em;
  flex-shrink: 0;
  position: relative;
  overflow: hidden;

  &::after {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(to bottom, transparent, rgba(0, 0, 0, 0.35));
    pointer-events: none;
  }
}

.search-result-info {
  margin-left: 12px;
  display: flex;
  flex-direction: column;
  flex: 1;
  min-width: 0;
}

.search-result-name {
  color: white;
  font-size: 14px;
  font-weight: 500;
}

.search-result-category {
  color: rgba(255, 255, 255, 0.5);
  font-size: 11px;
  margin-top: 1px;
}

.search-result-new {
  background: #ff3b30;
  color: white;
  font-size: 8px;
  font-weight: 700;
  padding: 2px 5px;
  border-radius: 6px;
  letter-spacing: 0.5px;
}
</style>
