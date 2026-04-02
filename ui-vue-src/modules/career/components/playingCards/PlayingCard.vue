<template>
  <div
    class="playing-card-wrapper"
    :style="{ '--flip-duration': `${FLIP_DURATION}ms`, '--flip-half-duration': `${FLIP_DURATION / 2}ms` }">
    <div class="playing-card-mover" :class="flipPhase">
      <div
        ref="cardRef"
        class="playing-card"
        :class="flipPhase"
      />
    </div>
  </div>
</template>

<script setup>
import { ref, watch, onMounted } from "vue"
import { fetchSvg, namespaceSvgIds, initCard, setRank, swapSuit, setCorners, showSide, toggleSide, setCardTheme } from "./cardController"

const FLIP_SOUND_URL = "/ui/entrypoints/main/cardSounds/Flip.mp3"
const FLIP_DURATION = 744

const props = defineProps({
  rank: { type: String, required: true },
  suit: { type: String, required: true },
  faceUp: { type: Boolean, default: false },
  theme: { type: String, default: "light", validator: v => v === "light" || v === "dark" },
})

const emit = defineEmits(["flip"])

const cardRef = ref(null)
const flipPhase = ref("")
let svgRoot = null
let internalFaceUp = props.faceUp
let flipping = false

function getSvgRoot() {
  if (!svgRoot && cardRef.value) {
    svgRoot = cardRef.value.querySelector("svg")
  }
  return svgRoot
}

function playFlipSound() {
  try {
    const audio = new Audio(FLIP_SOUND_URL)
    audio.volume = 0.5
    audio.play()
  } catch (_) {}
}

function flip() {
  if (flipping) return
  const root = getSvgRoot()
  if (!root) return

  flipping = true
  playFlipSound()
  flipPhase.value = "phase-one"

  setTimeout(() => {
    internalFaceUp = !internalFaceUp
    toggleSide(root)
    flipPhase.value = "phase-two"
    emit("flip", internalFaceUp)
  }, FLIP_DURATION * 0.5)

  setTimeout(() => {
    flipPhase.value = ""
    flipping = false
  }, FLIP_DURATION)
}

onMounted(async () => {
  const svgText = await fetchSvg()
  if (!cardRef.value) return
  const parser = new DOMParser()
  const svgDoc = parser.parseFromString(svgText, "image/svg+xml")
  const parsedRoot = svgDoc.documentElement
  if (!parsedRoot || parsedRoot.tagName.toLowerCase() !== "svg") return

  namespaceSvgIds(parsedRoot)
  cardRef.value.replaceChildren(document.importNode(parsedRoot, true))
  svgRoot = cardRef.value.querySelector("svg")
  if (!svgRoot) return

  initCard(svgRoot, props.rank, props.suit, props.faceUp)
  setCardTheme(svgRoot, props.theme)
  internalFaceUp = props.faceUp
})

watch(
  () => [props.rank, props.suit],
  ([rank, suit]) => {
    const root = getSvgRoot()
    if (!root) return
    setRank(root, rank)
    swapSuit(root, rank, suit)
    setCorners(root, rank, suit)
  }
)

watch(
  () => props.faceUp,
  val => {
    if (val === internalFaceUp) return
    flip()
  }
)

watch(
  () => props.theme,
  theme => {
    const root = getSvgRoot()
    if (root) setCardTheme(root, theme)
  }
)

defineExpose({ flip })
</script>

<style scoped lang="scss">
.playing-card-wrapper {
  perspective: 800px;
  aspect-ratio: 750 / 1050;
}

.playing-card-mover {
  width: 100%;
  height: 100%;
}

.playing-card {
  width: 100%;
  height: 100%;
  overflow: hidden;
  border-radius: 3.5%;
  transform-origin: left center;

  :deep(svg) {
    width: 100%;
    height: 100%;
    display: block;
  }
  will-change: transform;
}

.playing-card-mover.phase-one {
  animation: card-flip-move-out var(--flip-half-duration) ease-in-out forwards;
}

.playing-card-mover.phase-two {
  animation: card-flip-move-in var(--flip-half-duration) ease-in-out forwards;
}

.playing-card.phase-one {
  animation: card-flip-rotate-out var(--flip-half-duration) ease-in-out forwards;
}

.playing-card.phase-two {
  animation: card-flip-rotate-in var(--flip-half-duration) ease-in-out forwards;
}

@keyframes card-flip-move-out {
  0% {
    transform: translateX(0);
  }
  100% {
    transform: translateX(100%);
  }
}

@keyframes card-flip-move-in {
  0% {
    transform: translateX(0);
  }
  100% {
    transform: translateX(0);
  }
}

@keyframes card-flip-rotate-out {
  0% {
    transform-origin: left center;
    transform: rotateY(0deg) translateY(0) scale(1);
  }
  50% {
    transform-origin: left center;
    transform: rotateY(-40deg) translateY(-8%) scale(1.02);
  }
  100% {
    transform-origin: left center;
    transform: rotateY(-89.8deg) translateY(-12%) scale(1.03);
  }
}

@keyframes card-flip-rotate-in {
  0% {
    transform-origin: right center;
    transform: rotateY(89.8deg) translateY(-12%) scale(1.03);
  }
  50% {
    transform-origin: right center;
    transform: rotateY(40deg) translateY(-8%) scale(1.02);
  }
  100% {
    transform-origin: right center;
    transform: rotateY(0deg) translateY(0) scale(1);
  }
}

</style>
