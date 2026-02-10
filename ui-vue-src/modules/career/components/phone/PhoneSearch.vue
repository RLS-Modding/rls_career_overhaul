<template>
  <div class="phone-search">
    <div class="search-input-wrap">
      <span class="search-icon">🔍</span>
      <input
        ref="searchInputRef"
        v-model="query"
        class="search-input"
        placeholder="Search apps..."
        @focus="onFocus"
        @blur="onBlur"
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

function onFocus() {
  // CEF typing mode would be handled by vBngTextInput if needed
}

function onBlur() {
  // noop
}
</script>

<style scoped lang="scss">
.phone-search {
  display: flex;
  flex-direction: column;
  height: 100%;
  padding: 8px 0;
}

.search-input-wrap {
  display: flex;
  align-items: center;
  background: rgba(255, 255, 255, 0.12);
  border-radius: 12px;
  padding: 8px 12px;
  margin-bottom: 12px;
}

.search-icon {
  font-size: 14px;
  margin-right: 8px;
  opacity: 0.7;
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
