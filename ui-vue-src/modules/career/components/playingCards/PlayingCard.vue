<template>
  <div ref="cardRef" class="playing-card" />
</template>

<script setup>
import { ref, watch, onMounted } from "vue"
import { fetchSvg, initCard, setRank, swapSuit, setCorners, showSide, toggleSide } from "./cardController"

const props = defineProps({
  rank: { type: String, required: true },
  suit: { type: String, required: true },
  faceUp: { type: Boolean, default: false },
})

const emit = defineEmits(["flip"])

const cardRef = ref(null)
let svgRoot = null
let internalFaceUp = props.faceUp

function getSvgRoot() {
  if (!svgRoot && cardRef.value) {
    svgRoot = cardRef.value.querySelector("svg")
  }
  return svgRoot
}

function flip() {
  const root = getSvgRoot()
  if (!root) return
  internalFaceUp = !internalFaceUp
  toggleSide(root)
  emit("flip", internalFaceUp)
}

onMounted(async () => {
  const svgText = await fetchSvg()
  if (!cardRef.value) return
  cardRef.value.innerHTML = svgText
  svgRoot = cardRef.value.querySelector("svg")
  if (svgRoot) {
    initCard(svgRoot, props.rank, props.suit, props.faceUp)
    internalFaceUp = props.faceUp
  }
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
    const root = getSvgRoot()
    if (!root) return
    internalFaceUp = val
    showSide(root, val)
  }
)

defineExpose({ flip })
</script>

<style scoped lang="scss">
.playing-card {
  aspect-ratio: 750 / 1050;
  overflow: hidden;
  border-radius: 3.5%;

  :deep(svg) {
    width: 100%;
    height: 100%;
    display: block;
  }
}
</style>
