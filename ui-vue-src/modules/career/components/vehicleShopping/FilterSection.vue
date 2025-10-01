<template>
  <div class="filter-section-card" :class="{ active }">
    <div class="filter-card-header">
      <div class="title"><slot name="title">{{ title }}</slot></div>
      <div class="header-right"><slot name="header-right" /></div>
    </div>
    <div class="filter-card-body">
      <slot />
    </div>
    <div v-if="$slots.action" class="filter-card-action">
      <slot name="action" />
    </div>
  </div>
  
</template>

<script setup>
import { defineProps } from 'vue'

const props = defineProps({
  title: { type: String, default: '' },
  active: { type: Boolean, default: false },
})
</script>

<style scoped>
.filter-section-card {
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: var(--bng-corners-2);
  background: var(--bng-cool-gray-900);
  overflow: hidden;
}
.filter-section-card.active {
  border-color: var(--bng-orange);
  box-shadow: 0 0 0 1px var(--bng-orange) inset;
}
.filter-card-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.5rem 0.75rem;
  border-bottom: 1px solid var(--bng-cool-gray-700);
}
.filter-card-header .title {
  font-weight: 600;
  font-size: 0.8125rem;
  color: var(--bng-off-white);
}
.filter-card-body {
  padding: 0.5rem 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  min-height: 2.5rem;
  position: relative;
}
.filter-card-action {
  padding: 0.375rem 0.75rem 0.625rem 0.75rem;
}
.action-container {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0.5rem 0.625rem;
  font-size: 0.75rem;
  border: 1px dashed var(--bng-cool-gray-600);
  border-radius: var(--bng-corners-1);
  color: var(--bng-orange);
  cursor: pointer;
  transition: all 0.2s ease;
  position: relative;
  overflow: hidden;
}

.action-container::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: var(--bng-orange-alpha-10);
  transform: scaleX(0);
  transform-origin: left center;
  transition: transform 0.3s ease;
  z-index: 0;
}

.action-container:hover {
  border-color: var(--bng-cool-gray-500);
  transform: translateY(-1px);
  box-shadow: 0 2px 4px rgba(0,0,0,0.15);
}

.action-container:hover::before {
  transform: scaleX(1);
}

.action-container:active {
  transform: translateY(0);
  box-shadow: 0 1px 2px rgba(0,0,0,0.1);
}

.action-container > * {
  position: relative;
  z-index: 1;
}

.action-container.active {
  border-color: var(--bng-orange);
  border-style: solid;
  background: var(--bng-orange-alpha-5);
}

.action-container.active:hover {
  background: var(--bng-orange-alpha-15);
  transform: translateY(-2px);
  box-shadow: 0 3px 6px rgba(255,102,0,0.2);
}

.action-container.active:active {
  transform: translateY(0);
  box-shadow: 0 1px 3px rgba(255,102,0,0.15);
}
</style>


