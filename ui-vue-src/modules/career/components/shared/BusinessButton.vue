<template>
  <button 
    :class="['business-btn', `business-btn-${variant}`, { 'business-btn-disabled': disabled }]"
    :disabled="disabled"
    @click="$emit('click', $event)"
  >
    <slot />
  </button>
</template>

<script setup>
defineProps({
  variant: {
    type: String,
    default: 'primary',
    validator: (value) => ['primary', 'secondary', 'success', 'danger'].includes(value)
  },
  disabled: {
    type: Boolean,
    default: false
  }
})

defineEmits(['click'])
</script>

<style scoped lang="scss">
.business-btn {
  padding: 0.5rem 1rem;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  
  &:disabled,
  &.business-btn-disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
  
  &.business-btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;
    
    &:hover:not(:disabled):not(.business-btn-disabled) {
      background: rgba(245, 73, 0, 0.9);
    }
  }
  
  &.business-btn-secondary {
    background: rgba(55, 55, 55, 1);
    color: white;
    
    &:hover:not(:disabled):not(.business-btn-disabled) {
      background: rgba(75, 75, 75, 1);
    }
  }
  
  &.business-btn-success {
    background: rgba(34, 197, 94, 1);
    color: white;
    
    &:hover:not(:disabled):not(.business-btn-disabled) {
      background: rgba(34, 197, 94, 0.9);
    }
  }
  
  &.business-btn-danger {
    background: rgba(239, 68, 68, 1);
    color: white;
    
    &:hover:not(:disabled):not(.business-btn-disabled) {
      background: rgba(239, 68, 68, 0.9);
    }
  }
}
</style>

