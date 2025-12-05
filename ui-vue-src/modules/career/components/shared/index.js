// Shared Business Computer UI Components
// Import all components from one place
export { default as BusinessButton } from './BusinessButton.vue'
export { default as BusinessCard } from './BusinessCard.vue'
export { default as BusinessBadge } from './BusinessBadge.vue'
export { default as BusinessSlider } from './BusinessSlider.vue'
export { default as BusinessSection } from './BusinessSection.vue'

// Also export as default object for convenience
import BusinessButton from './BusinessButton.vue'
import BusinessCard from './BusinessCard.vue'
import BusinessBadge from './BusinessBadge.vue'
import BusinessSlider from './BusinessSlider.vue'
import BusinessSection from './BusinessSection.vue'

export default {
  BusinessButton,
  BusinessCard,
  BusinessBadge,
  BusinessSlider,
  BusinessSection
}

