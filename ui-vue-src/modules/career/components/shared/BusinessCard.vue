<template>
  <div :class="['business-card', { 'business-card-gradient': gradient }]">
    <div v-if="$slots.header || title" class="business-card-header">
      <div v-if="icon || title" class="business-card-header-content">
        <slot name="icon">
          <svg v-if="icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <component :is="icon" />
          </svg>
        </slot>
        <h3 v-if="title">{{ title }}</h3>
      </div>
      <p v-if="description" class="business-card-description">{{ description }}</p>
    </div>
    <div v-if="$slots.default" class="business-card-content">
      <slot />
    </div>
  </div>
</template>

<script setup>
defineProps({
  title: String,
  description: String,
  icon: String,
  gradient: {
    type: Boolean,
    default: false
  }
})
</script>

<style scoped lang="scss">
.business-card {
  background: rgba(26, 26, 26, 0.5);
  border: 1px solid rgba(245, 73, 0, 0.3);
  border-radius: 0.5em;
  overflow: hidden;
  
  &.business-card-gradient {
    background: linear-gradient(to bottom right, rgba(245, 73, 0, 0.2), rgba(26, 26, 26, 0.5));
    border: 1px solid rgba(245, 73, 0, 0.5);
  }
}

.business-card-header {
  padding: 1em 1.5em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.3);
}

.business-card-header-content {
  display: flex;
  align-items: center;
  gap: 0.75em;
  margin-bottom: 0.5em;
  
  svg {
    color: rgba(245, 73, 0, 1);
    flex-shrink: 0;
  }
  
  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125em;
    font-weight: 600;
  }
}

.business-card-description {
  margin: 0;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.875em;
}

.business-card-content {
  padding: 1.5em;
}
</style>
