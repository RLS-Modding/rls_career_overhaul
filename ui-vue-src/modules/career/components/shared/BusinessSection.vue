<template>
  <div class="business-section">
    <div class="business-section-header">
      <h3>{{ title }}</h3>
    </div>
    <div v-if="$slots.default" class="business-section-content">
      <slot />
    </div>
  </div>
</template>

<script setup>
defineProps({
  title: {
    type: String,
    required: true
  }
})
</script>

<style scoped lang="scss">
.business-section {
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5em;
  overflow: hidden;
}

.business-section-header {
  padding: 1em 1.5em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.3);
  
  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125em;
    font-weight: 600;
  }
}

.business-section-content {
  padding: 1.5em;
}
</style>
