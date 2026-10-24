<template>
  <Teleport to="body">
    <!-- After Spectate click (staging), teleport to team car, or while in an active proxy race (Lua sets flags). -->
    <div v-if="visible && (spectateStaging || playerTeleportedToTeamCar || inRace)" class="rtp-overlay" @click.self>
      <button
        type="button"
        class="btn btn-secondary rtp-overlay__btn"
        data-focusable
        :disabled="isCancelling"
        :aria-busy="isCancelling ? 'true' : 'false'"
        @click="onCancel"
      >
        {{ isCancelling ? "Dropping out…" : "Drop out" }}
      </button>
    </div>
  </Teleport>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua.js"
import { ref, onMounted, onBeforeUnmount } from "vue"
import { useBridge, lua } from "@/bridge"

const bridge = useBridge()

const visible = ref(false)
const businessId = ref(null)
/** When true, overlay may show (still requires visible). Reserved for future race-phase UI. */
const inRace = ref(false)
/** From Lua `racingTeamProxyOverlay` payload — only then show the exit control. */
const playerTeleportedToTeamCar = ref(false)
/** True from Spectate / simulate flow before world teleport (Lua `spectateStaging`). */
const spectateStaging = ref(false)
/** In-flight guard so a double-tap on Drop out doesn't fire cancelRacingTeamProxySession twice. */
const isCancelling = ref(false)

const onOverlay = (...args) => {
  const raw = args.length > 0 ? args[0] : null
  const d = raw && typeof raw === "object" ? raw : {}
  visible.value = d.visible === true
  businessId.value = d.businessId != null && d.businessId !== "" ? String(d.businessId) : null
  inRace.value = d.inRace === true
  playerTeleportedToTeamCar.value = d.playerTeleportedToTeamCar === true
  spectateStaging.value = d.spectateStaging === true
}

const onCancel = async () => {
  if (isCancelling.value) return
  const bid = businessId.value
  if (!bid) {
    visible.value = false
    return
  }
  isCancelling.value = true
  try {
    await lua.overhaul_career_business_computer.cancelRacingTeamProxySession(bid)
  } catch (e) {
    reportUiFailure(e, "Cancel the racing team proxy session")
  } finally {
    isCancelling.value = false
  }
  visible.value = false
}

onMounted(() => {
  bridge.events.on("racingTeamProxyOverlay", onOverlay)
})

onBeforeUnmount(() => {
  bridge.events.off("racingTeamProxyOverlay", onOverlay)
})
</script>

<style scoped lang="scss">
.rtp-overlay {
  // same resolution scale as the house screens (rem-sized, the button shrank at 1440p)
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  position: fixed;
  left: 1.25rem;
  top: 50%;
  transform: translateY(-50%);
  z-index: 13050;
  pointer-events: auto;
}

.rtp-overlay__btn {
  margin: 0;
  box-shadow: 0 4px 18px rgba(0, 0, 0, 0.45);
}

.btn {
  // keyboard / controller focus: the house ring (rlsHouse --focus values) on a positioned button, with
  // the game's ::before frame hidden (teleported to <body>, outside the game's frame rule anyway)
  position: relative;
  &.focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600),
      0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
  }
  &.focus-visible::before {
    display: none !important;
  }
  padding: 0.55em 1.25em;
  border-radius: 8px;
  font-weight: 600;
  font-size: 0.9em;
  cursor: pointer;
  border: none;
  transition: background 0.15s, opacity 0.15s;
}

.btn-secondary {
  background: rgba(40, 52, 64, 0.95);
  color: rgba(255, 255, 255, 0.92);
  border: 1px solid rgba(245, 73, 0, 0.35);
  &:hover:not(:disabled) {
    border-color: rgba(245, 73, 0, 0.55);
    background: rgba(50, 64, 78, 0.98);
  }
  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}
</style>
