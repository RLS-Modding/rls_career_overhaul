<template>
  <div>
    <div class="career-status-progress" :class="{ 'slim': slim }">

      <BngUnit class="career-status-value" :insuranceScore="displayData.insuranceScore" />
      <BngDivider />
      <BngUnit class="career-status-value" :vouchers="displayData.vouchers" />
      <BngDivider />
      <BngUnit class="career-status-value" :money="displayData.money" />
    </div>
  </div>
</template>

<script setup>
import { onMounted, onUnmounted, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngUnit, BngDivider } from "@/common/components/base"

const { events } = useBridge()

const props = defineProps({
  slim: {
    type: Boolean,
    default: false
  }
})

const LERP_DURATION_MS = 2000
const num = v => (typeof v === "number" && !Number.isNaN(v) ? v : 0)

const displayData = ref({
  insuranceScore: 0,
  vouchers: 0,
  money: 0
})
const hasReceivedFirstData = ref(false)
let lerpStartTime = 0
let lerpStart = null
let lerpTarget = null
let lerpRafId = null
let disposed = false
let displayRequest = 0

function writeDisplay(target) {
  const rounded = {
    insuranceScore: Math.round(num(target.insuranceScore)),
    vouchers: Math.round(num(target.vouchers)),
    money: Math.round(num(target.money) * 100) / 100,
  }
  for (const [key, value] of Object.entries(rounded)) {
    if (displayData.value[key] !== value) displayData.value[key] = value
  }
}

function lerpDisplayToTarget(target) {
  if (lerpRafId != null) cancelAnimationFrame(lerpRafId)
  lerpStart = {
    insuranceScore: num(displayData.value.insuranceScore),
    vouchers: num(displayData.value.vouchers),
    money: num(displayData.value.money)
  }
  lerpTarget = {
    insuranceScore: num(target.insuranceScore),
    vouchers: num(target.vouchers),
    money: num(target.money)
  }
  lerpStartTime = performance.now()

  function tick() {
    const t = Math.min((performance.now() - lerpStartTime) / LERP_DURATION_MS, 1)
    writeDisplay({
      insuranceScore: lerpStart.insuranceScore + (lerpTarget.insuranceScore - lerpStart.insuranceScore) * t,
      vouchers: lerpStart.vouchers + (lerpTarget.vouchers - lerpStart.vouchers) * t,
      money: lerpStart.money + (lerpTarget.money - lerpStart.money) * t,
    })
    if (t < 1) lerpRafId = requestAnimationFrame(tick)
    else lerpRafId = null
  }
  lerpRafId = requestAnimationFrame(tick)
}

function handleCareerStatusData(data, fromUpdate) {
  if (disposed) return
  if (!fromUpdate || !hasReceivedFirstData.value || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
    if (lerpRafId != null) cancelAnimationFrame(lerpRafId)
    lerpRafId = null
    writeDisplay(data)
    hasReceivedFirstData.value = true
    return
  }
  lerpDisplayToTarget(data)
}

async function updateDisplay(fromUpdate = false) {
  const request = ++displayRequest
  const data = await lua.overhaul_career_ui_uiUtils.getCareerStatusData()
  if (disposed || request !== displayRequest) return
  handleCareerStatusData(data, fromUpdate)
}

function handleCareerStatusUpdated() {
  updateDisplay(true)
}

onMounted(() => {
  updateDisplay(false)
  events.on("careerStatusDataUpdated", handleCareerStatusUpdated)
})

onUnmounted(() => {
  disposed = true
  events.off("careerStatusDataUpdated", handleCareerStatusUpdated)
  if (lerpRafId != null) cancelAnimationFrame(lerpRafId)
})

defineExpose({ updateDisplay: () => updateDisplay(false) })
</script>

<style lang="scss" scoped>
.career-status-progress {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  padding: 0.25rem 0.5rem;

  .icon {
    width: 1em;
    height: 1em;
  }
  .career-status-value {
    display: flex;
    flex-direction: row;
    flex-wrap: nowrap;
    align-items: baseline;
    & > :first-child {
      margin-right: 0.125em;
    }
  }

  &.slim {
    height: 2.625rem;
    padding: 0.125rem 0.375rem;

    .career-status-value {
      font-size: 0.875rem;
      padding-right: 0.125rem;
      padding-left: 0.125rem;
    }

    .icon {
      width: 0.875em;
      height: 0.875em;
    }
  }
}

.vertical-divider {
  margin: 0.4em 0.4em 0.4em 0.5em;
  padding-left: 2px;
  background: #fff;
  transform: skewX(-20deg);
  align-self: stretch;
}

// FIXME - this is relying on a conflict with AngularJS CSS in main.css - this class is worryingly used a lot around the place
.career-status-value {
  flex-direction: row;
  display: flex;
  justify-content: center;
  padding: 0;
  align-items: flex-start;
  font-style: italic;
  font-weight: 700;
  padding-right: 0.25rem;
  padding-left: 0.25rem;
  color: white;
}
</style>
