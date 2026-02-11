<template>
  <div class="page-dots">
    <span
      v-for="i in totalPages"
      :key="'page-' + i"
      class="page-dot"
      :class="{ active: currentPage === i - 1 }"
      @click="$emit('go', i - 1)"
    ></span>
    <span
      class="page-dot search-dot"
      :class="{ active: isSearchActive }"
      @click="$emit('go', totalPages)"
    >
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="11" cy="11" r="8"/>
        <line x1="21" y1="21" x2="16.65" y2="16.65"/>
      </svg>
    </span>
  </div>
</template>

<script setup>
defineProps({
  totalPages: { type: Number, required: true },
  currentPage: { type: Number, required: true },
  isSearchActive: { type: Boolean, default: false },
})

defineEmits(['go'])
</script>

<style scoped lang="scss">
.page-dots {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  padding: 6px 0;
  z-index: 15;
}

.page-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.35);
  cursor: pointer;
  transition: background 0.2s ease, transform 0.2s ease;

  &.active {
    background: rgba(255, 255, 255, 0.95);
    transform: scale(1.2);
  }
}

.search-dot {
  width: auto;
  height: auto;
  background: none;
  line-height: 1;
  opacity: 0.5;
  transition: opacity 0.2s ease;
  color: rgba(255, 255, 255, 0.9);
  display: flex;
  align-items: center;
  justify-content: center;

  &.active {
    opacity: 1;
    transform: scale(1.15);
    background: none;
  }
}
</style>
