<template>
  <span :class="['business-badge', `business-badge-${variant}`]">
    <slot />
  </span>
</template>

<script setup>
defineProps({
  variant: {
    type: String,
    default: 'default',
    validator: (value) => ['default', 'green', 'orange', 'active', 'available'].includes(value)
  }
})
</script>

<style scoped lang="scss">
.business-badge {
  padding: 0.25em 0.5em;
  border-radius: 0.25em;
  font-size: 0.75em;
  font-weight: 500;
  display: inline-block;
  
  &.business-badge-green {
    background: rgba(34, 197, 94, 0.2);
    color: rgba(34, 197, 94, 1);
    border: 1px solid rgba(34, 197, 94, 0.5);
  }
  
  &.business-badge-orange {
    background: rgba(245, 73, 0, 0.2);
    color: rgba(245, 73, 0, 1);
    border: 1px solid rgba(245, 73, 0, 0.5);
  }
  
  &.business-badge-active {
    background: rgba(59, 130, 246, 0.2);
    color: rgba(59, 130, 246, 1);
    border: 1px solid rgba(59, 130, 246, 0.5);
  }
  
  &.business-badge-available {
    background: rgba(34, 197, 94, 0.2);
    color: rgba(34, 197, 94, 1);
    border: 1px solid rgba(34, 197, 94, 0.5);
  }
  
  &.business-badge-default {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.7);
    border: 1px solid rgba(255, 255, 255, 0.2);
  }
}
</style>
