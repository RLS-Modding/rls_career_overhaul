<template>
  <div class="business-slider-control">
    <label v-if="label" class="business-slider-label">{{ label }}</label>
    <div class="business-slider-wrapper">
      <input 
        type="range" 
        :value="modelValue"
        :min="min"
        :max="max"
        :step="step"
        class="business-slider"
        @input="$emit('update:modelValue', parseFloat($event.target.value))"
      />
      <span v-if="showValue" class="business-slider-value">
        {{ formatValue(modelValue, unit) }}
      </span>
    </div>
  </div>
</template>

<script setup>
const props = defineProps({
  modelValue: {
    type: Number,
    required: true
  },
  label: String,
  min: {
    type: Number,
    default: 0
  },
  max: {
    type: Number,
    default: 100
  },
  step: {
    type: Number,
    default: 1
  },
  unit: String,
  showValue: {
    type: Boolean,
    default: true
  }
})

defineEmits(['update:modelValue'])

const formatValue = (value, unit) => {
  if (unit) {
    return `${value}${unit}`
  }
  return value.toString()
}
</script>

<style scoped lang="scss">
.business-slider-control {
  margin-bottom: 1rem;
  
  &:last-child {
    margin-bottom: 0;
  }
}

.business-slider-label {
  display: block;
  color: rgba(255, 255, 255, 0.7);
  margin-bottom: 0.5rem;
  font-size: 0.875rem;
}

.business-slider-wrapper {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.business-slider {
  flex: 1;
  height: 0.5rem;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 0.25rem;
  outline: none;
  
  &::-webkit-slider-thumb {
    appearance: none;
    width: 1rem;
    height: 1rem;
    background: rgba(245, 73, 0, 1);
    border-radius: 50%;
    cursor: pointer;
  }
  
  &::-moz-range-thumb {
    width: 1rem;
    height: 1rem;
    background: rgba(245, 73, 0, 1);
    border-radius: 50%;
    cursor: pointer;
    border: none;
  }
}

.business-slider-value {
  min-width: 4rem;
  padding: 0.25rem 0.5rem;
  background: rgba(26, 26, 26, 1);
  border-radius: 0.25rem;
  text-align: center;
  color: white;
  font-size: 0.875rem;
}
</style>

