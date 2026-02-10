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
    >🔍</span>
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
  font-size: 10px;
  line-height: 1;
  opacity: 0.5;
  transition: opacity 0.2s ease;

  &.active {
    opacity: 1;
    transform: scale(1.15);
    background: none;
  }
}
</style>
