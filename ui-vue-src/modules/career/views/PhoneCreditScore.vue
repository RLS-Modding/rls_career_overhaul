<template>
  <PhoneWrapper app-name="Credit Score" status-font-color="#FFFFFF" status-blend-mode="">
    <div class="credit-placeholder">
      Credit Score — placeholder (full UI to be implemented separately)
    </div>
  </PhoneWrapper>
</template>

<script setup>
import PhoneWrapper from './PhoneWrapper.vue'
</script>

<style scoped lang="scss">
.credit-placeholder {
  padding: 1rem;
  color: rgba(255, 255, 255, 0.7);
  text-align: center;
}
</style>
