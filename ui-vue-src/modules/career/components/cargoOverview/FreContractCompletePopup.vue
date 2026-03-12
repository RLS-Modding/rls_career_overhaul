<template>
  <div class="contract-wrapper" :class="{ closing: isClosing }">
    <BngCard class="celebration-card">
      <BngCardHeading type="ribbon">Contract Complete!</BngCardHeading>

      <div class="hero">
        <div class="discipline">{{ disciplineLabel }}</div>
        <div class="race">{{ raceLabel }}</div>
      </div>

      <div class="card-content">
        <div class="line">Tier: {{ tierLabel }}</div>
        <div class="line">Vehicle: {{ modelLabel }}</div>
        <div class="line">{{ objectiveText }}</div>
        <div class="rewards">
          <div class="money">+${{ rewardMoney }}</div>
          <div class="xp">+{{ rewardXp }} XP</div>
        </div>
      </div>
    </BngCard>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from "vue"
import { BngCard, BngCardHeading } from "@/common/components/base"

const emit = defineEmits(["return"])
const AUTO_CLOSE_MS = 4500
const FADE_OUT_MS = 300
const isClosing = ref(false)
let closeTimer = null
let fadeTimer = null

const props = defineProps({
  entry: {
    type: Object,
    default: () => ({})
  }
})

const disciplineLabel = computed(() => props.entry?.disciplineLabel || "FRE")
const raceLabel = computed(() => props.entry?.raceLabel || "Race")
const tierLabel = computed(() => {
  const tier = props.entry?.tier || "easy"
  return `${String(tier).charAt(0).toUpperCase()}${String(tier).slice(1)}`
})
const modelLabel = computed(() => props.entry?.requiredModelLabel || props.entry?.requiredModel || "Any model")
const rewardMoney = computed(() => Math.floor(Number(props.entry?.rewardMoney || 0)).toLocaleString())
const rewardXp = computed(() => Math.floor(Number(props.entry?.rewardXp || 0)).toLocaleString())
const objectiveText = computed(() => {
  const objectiveType = props.entry?.objectiveType === "laps" ? "laps" : "events"
  const requiredCount = Math.max(1, Math.floor(Number(props.entry?.requiredCount || 1)))
  if (objectiveType === "laps") {
    return `Objective cleared: ${requiredCount} lap${requiredCount === 1 ? "" : "s"} under target`
  }
  return `Objective cleared: ${requiredCount} event${requiredCount === 1 ? "" : "s"} under target`
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
.contract-wrapper {
  color: #fff;
  max-width: 42rem;
  margin-top: 1rem;
  transition: opacity 300ms ease, transform 300ms ease;
}

.contract-wrapper.closing {
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
  text-align: center;
  padding: 1rem 1rem 0.5rem;
}

.discipline {
  font-size: 1rem;
  font-weight: 700;
  opacity: 0.92;
}

.race {
  margin-top: 0.25rem;
  font-size: 1.85rem;
  line-height: 1.05;
  font-weight: 800;
  color: #ffd080;
}

.card-content {
  padding: 0.5rem 1rem 1rem;
}

.line {
  font-size: 1rem;
  margin-bottom: 0.25rem;
  opacity: 0.9;
}

.rewards {
  margin-top: 0.65rem;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
}

.money,
.xp {
  font-size: 1.1rem;
  font-weight: 800;
}

.money {
  color: #86efac;
}

.xp {
  color: #93c5fd;
}
</style>
