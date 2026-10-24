<template>
  <div class="start-toggle-row">
    <label class="start-toggle-label">{{ label }}</label>
    <button
      type="button"
      class="start-toggle"
      :class="{ 'start-toggle--active': modelValue }"
      :aria-pressed="modelValue"
      :disabled="disabled"
      @click="$emit('update:modelValue', !modelValue)">
      <span class="start-toggle-track">
        <span class="start-toggle-thumb" />
      </span>
      <span class="start-toggle-value">{{ modelValue ? "On" : "Off" }}</span>
    </button>
  </div>
</template>

<script setup>
defineProps({
  label: { type: String, required: true },
  modelValue: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
})

defineEmits(["update:modelValue"])
</script>

<style lang="scss" scoped>
.start-toggle-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: 0.75em;
}

.start-toggle-label {
  font-weight: 600;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.75);
}

.start-toggle {
  display: inline-flex;
  align-items: center;
  gap: 0.5em;
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 999px;
  padding: 0.32em 0.46em;
  background: rgba(5, 8, 15, 0.7);
  color: rgba(255, 255, 255, 0.8);
  font-size: 0.82em;
  font-weight: 600;
  cursor: pointer;
  transition: border-color 120ms ease, background 120ms ease, color 120ms ease;

  &:hover:not(:disabled) {
    border-color: rgba(71, 85, 105, 0.8);
  }

  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
}

.start-toggle-track {
  position: relative;
  width: 2.35em;
  height: 1.28em;
  border-radius: 999px;
  background: rgba(71, 85, 105, 0.7);
  transition: background 120ms ease;
  flex: 0 0 auto;
}

.start-toggle-thumb {
  position: absolute;
  top: 0.14em;
  left: 0.14em;
  width: 1em;
  height: 1em;
  border-radius: 50%;
  background: #f8fafc;
  transition: transform 120ms ease;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
}

.start-toggle-value {
  min-width: 1.9em;
  text-align: left;
}

.start-toggle--active {
  border-color: rgba(255, 122, 26, 0.85);
  color: #fff;
  background: linear-gradient(90deg, rgba(255, 122, 26, 0.18), rgba(232, 95, 0, 0.18));
}

.start-toggle--active .start-toggle-track {
  background: linear-gradient(90deg, rgba(255, 122, 26, 0.85), rgba(232, 95, 0, 0.85));
}

.start-toggle--active .start-toggle-thumb {
  transform: translateX(1.02em);
}
</style>
