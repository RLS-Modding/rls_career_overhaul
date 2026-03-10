<template>
  <div class="unlock-wrapper" :class="{ closing: isClosing }">
    <BngCard class="celebration-card">
      <BngCardHeading type="ribbon">Level Up!</BngCardHeading>

      <div class="hero">
        <div class="level-text-wrap">
          <div class="skill-name">{{ $ctx_t((reward.animationData && reward.animationData.name) || "Skill") }}</div>
          <div class="level-text">Level {{ levelValue }}</div>
        </div>
      </div>

      <div class="card-content">
        <h3>{{ reward.unlockPopupHeader || defaultHeader }}</h3>

        <template v-if="currentUnlocks.length">
          <div class="unlocks-label">Unlocks</div>
          <UnlockCard v-for="(item, index) in currentUnlocks" :key="`${index}-${item.heading || item.label || 'unlock'}`" class="tier-unlocks-item" :data="item" />
        </template>
        <div v-else class="no-unlocks">No new unlock items at this level.</div>

      </div>
    </BngCard>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from "vue"
import { BngCard, BngCardHeading } from "@/common/components/base"
import UnlockCard from "../progress/UnlockCard.vue"

const emit = defineEmits(["return"])
const AUTO_CLOSE_MS = 2800
const FADE_OUT_MS = 300
const isClosing = ref(false)
let closeTimer = null
let fadeTimer = null

const props = defineProps({
  reward: {
    type: Object,
    default: () => ({})
  },
})

const levelValue = computed(() => {
  const level = Number(props.reward && props.reward.animationData && props.reward.animationData.level)
  return Number.isFinite(level) && level > 0 ? level : 1
})

const defaultHeader = computed(() => {
  const skillName = (props.reward && props.reward.animationData && props.reward.animationData.name) || "Skill"
  return `${skillName} Skill: Level ${levelValue.value}`
})

const currentUnlocks = computed(() => {
  const levels = Array.isArray(props.reward && props.reward.branchLevels) ? props.reward.branchLevels : []
  const currentLevelData = levels[levelValue.value - 1]
  return Array.isArray(currentLevelData && currentLevelData.unlocks) ? currentLevelData.unlocks : []
})

const closePopup = () => {
  if (isClosing.value) return
  isClosing.value = true
  fadeTimer = setTimeout(() => emit("return", true), FADE_OUT_MS)
}

onMounted(() => {
  closeTimer = setTimeout(closePopup, AUTO_CLOSE_MS)
})

onUnmounted(() => {
  if (closeTimer) clearTimeout(closeTimer)
  if (fadeTimer) clearTimeout(fadeTimer)
})
</script>

<script>
import { popupPosition, popupContainer } from "@/services/popup"
export default {
  reportState: false,
  wrapper: {
    fade: false,
    blur: false,
    style: popupContainer.clickthrough,
  },
  position: [popupPosition.top, popupPosition.center],
}
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/modules/density" as *;

.unlock-wrapper {
  color: white;
  max-width: 42rem;
  margin-top: 1rem;
  transition: opacity 300ms ease, transform 300ms ease;
}

.unlock-wrapper.closing {
  opacity: 0;
  transform: translateY(-0.75rem);
}

:deep(.bng-card-wrapper) {
  --bg-opacity: 1 !important;
}

.celebration-card {
  overflow: hidden;
}

.hero {
  position: relative;
  padding: 1rem 1rem 0.75rem;
  overflow: hidden;
}

.level-text-wrap {
  position: relative;
  z-index: 1;
  text-align: center;
  margin-top: 0.6rem;
  margin-bottom: 0.45rem;
}

.skill-name {
  font-size: 1rem;
  font-weight: 600;
  opacity: 0.9;
}

.level-text {
  font-size: 2rem;
  font-weight: 800;
  line-height: 1;
  text-transform: uppercase;
  color: #ffd080;
  letter-spacing: 0.04em;
  animation: level-pop 350ms ease-out;
}

@keyframes level-pop {
  0% {
    transform: scale(0.7);
    opacity: 0.15;
  }
  100% {
    transform: scale(1);
    opacity: 1;
  }
}

.card-content {
  padding: 0.5rem 1rem 1rem;
}

.card-content h3 {
  margin: 0;
  margin-bottom: 0.75rem;
  text-align: center;
}

.unlocks-label {
  font-weight: 700;
  margin-bottom: 0.35rem;
}

.tier-unlocks-item {
  margin-bottom: 0.4rem;
}

.no-unlocks {
  color: rgba(255, 255, 255, 0.75);
  font-style: italic;
  margin-bottom: 0.5rem;
}

</style>
