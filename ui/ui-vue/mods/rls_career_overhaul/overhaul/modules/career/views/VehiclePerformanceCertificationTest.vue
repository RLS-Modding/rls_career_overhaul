<!-- RLS override of the vanilla in-progress assessment card (shown over the world during the drag test).
     Same script and nav; restyled to a compact near-black house card: plain timer glyph, the status
     line, a running bar (transform-only) and the cancel button. Turns red only while cancelling. -->
<template>
  <div class="rls-house certification-test-in-progress">
    <div v-bng-scoped-nav="{ scopeId: 'root' }" class="certification-card" :class="{ 'is-cancelling': cancellingTest }">
      <div class="certification-content">
        <div class="certification-icon">
          <BngIcon :type="icons.timeUnlockOutline" />
        </div>
        <div class="certification-copy">
          <span class="caption">{{ $t("ui.career.vehiclePerformance.title") }}</span>
          <div class="certificationTestText" :class="{ 'cancelling': cancellingTest }">{{ $t(assessmentProgressMessage) }}</div>
        </div>
      </div>
      <div class="run-bar" aria-hidden="true"><span></span></div>
      <div class="cancelButton">
        <!-- B / Start cancel (as vanilla); the glyph says so while a pad is in use -->
        <HouseButton
          block
          binding="back"
          :disabled="cancellingTest"
          v-bng-on-ui-nav:back,menu.asMouse
          @click="cancelTest"
        >
          {{ $t("ui.career.vehiclePerformance.cancelTest") }}
        </HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { HouseButton } from "../components/house/index.js"
import { lua } from "@/bridge"

const assessmentProgressMessage = ref("ui.career.vehiclePerformance.assessmentInProgress")
const cancellingTest = ref(false)

const cancelTest = () => {
  cancellingTest.value = true
  lua.overhaul_career_parts_vehiclePerformance.cancelTest()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.certification-test-in-progress {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  padding: 1em;
  width: fit-content;
}

.certification-card {
  display: grid;
  gap: 0.85em;
  width: 22em;
  padding: 1em 1.1em 1.1em;
  border-radius: 0.6em;
  background:
    radial-gradient(120% 60% at 0% 0%, rgba(255, 102, 0, 0.16), rgba(255, 102, 0, 0) 60%),
    rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  &.is-cancelling {
    background: rgba(var(--bng-off-black-rgb), 0.9);
  }
}

.certification-content {
  display: flex;
  align-items: center;
  gap: 0.8em;
  min-width: 0;
}

.certification-icon {
  flex: 0 0 auto;
  font-size: 2.6em;
  line-height: 1;
  color: var(--accent-soft);
  .is-cancelling & {
    color: var(--bad);
  }
}

.certification-copy {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}

.certificationTestText {
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
  color: #fff;

  &.cancelling {
    color: var(--bad);
    animation: pulse 1.5s ease-in-out infinite;
  }
}

@keyframes pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.55;
  }
}

/* indeterminate run bar: a soft segment sliding across (transform only) */
.run-bar {
  position: relative;
  height: 0.3em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  span {
    position: absolute;
    top: 0;
    bottom: 0;
    left: 0;
    width: 35%;
    border-radius: inherit;
    background: linear-gradient(90deg, rgba(255, 178, 122, 0), rgba(255, 178, 122, 0.85), rgba(255, 178, 122, 0));
    animation: run 1.6s cubic-bezier(0.45, 0, 0.55, 1) infinite;
  }
  .is-cancelling & span {
    animation-play-state: paused;
    opacity: 0;
  }
}

@keyframes run {
  0% {
    transform: translateX(-100%);
  }
  100% {
    transform: translateX(290%);
  }
}

.cancelButton {
  display: flex;
}
</style>
