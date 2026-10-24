<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Role certification prompt (shown when you drive into an assignment trigger). House card: what it
     takes, Certify (asks to confirm) and Cancel. Controller: the card is its own nav scope, active once
     the data is in, focus on Certify (Cancel when you can't afford it); B cancels. -->
<template>
  <LayoutSingle class="assignment-layout">
    <div class="assignment-center">
      <section
        class="rls-house modal assignment-card"
        v-bng-scoped-nav="scopeBinding"
        v-bng-blur="1">
        <span class="caption">Role certification</span>
        <h3>Certify your vehicle for {{ type }} work</h3>
        <p>
          Certification takes {{ convertTime(time) }} and costs
          <span class="amt"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(cost) }}</span>.
          Your vehicle is unavailable while it's being certified.
        </p>
        <p v-if="ready && !canAfford" class="notice bad">You can't afford the certification right now.</p>

        <div class="actions">
          <HouseButton
            variant="quiet"
            binding="back"
            :bng-scoped-nav-autofocus="!canAfford ? '' : null"
            @click="cancel">
            Cancel
          </HouseButton>
          <HouseButton
            variant="primary"
            :disabled="!canAfford"
            :bng-scoped-nav-autofocus="canAfford ? '' : null"
            @click="showConfirmation">
            Certify
          </HouseButton>
        </div>
      </section>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { lua, useBridge } from "@/bridge"
import { computed, ref, onMounted } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngBlur, vBngScopedNav } from "@/common/directives"
import { LayoutSingle } from "@/common/layouts"
import { HouseButton, openHouseConfirmation } from "../components/house/index.js"
import { moneyText } from "../utils/units"
import { formatAccessEta as convertTime } from "../utils/accessEta.js"
import { moneyMessage } from "../components/moneyMessage"

const { units } = useBridge()

const time = ref(0)
const cost = ref(0)
const type = ref("")
const canAfford = ref(false)
const ready = ref(false)
const confirming = ref(false)

const formatMoney = v => units.beamBucks(Number(v) || 0)

// Active once the data is in, so focus lands on Certify when you can pay for it. B cancels the
// prompt (there is nothing to step back to).
const scopeBinding = computed(() => ({
  scopeId: "rls-role-assignment",
  activated: ready.value,
  canDeactivate: () => {
    if (!confirming.value) cancel()
    return false
  },
}))

onMounted(async () => {
  try {
    const assignmentData = await lua.overhaul_career_police_certification.requestAssignmentData()
    if (assignmentData) {
      time.value = assignmentData.time
      cost.value = assignmentData.cost
      type.value = assignmentData.type
    }
    await refreshCanPay()
  } finally {
    ready.value = true
  }
})

async function refreshCanPay() {
  // Lua calls resolve asynchronously; a Promise in the template would always be truthy.
  canAfford.value = !!(await lua.overhaul_career_police_certification.canPay())
}



function goToPlayState() {
  window.bngApi.engineLua('guihooks.trigger("ChangeState", {state = "play", params = {}})')
}

function cancel() {
  goToPlayState()
}

async function showConfirmation() {
  if (!canAfford.value || confirming.value) return
  confirming.value = true
  let ok = false
  try {
    ok = await openHouseConfirmation(
      "Confirm certification",
      moneyMessage(`Certify your vehicle for ${type.value} work? It will be unavailable for ${convertTime(time.value)} and the certification costs `, moneyText(units, cost.value), "."),
      [
        { label: "Certify", value: true, extras: { default: true } },
        { label: "Cancel", value: false, extras: { cancel: true } },
      ]
    )
  } finally {
    confirming.value = false
  }
  // Lua closes the screen itself (ChangeState play) when certification starts
  if (ok) lua.overhaul_career_police_certification.startCertification()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// centred over the play view (the layout's content box does not centre its slot)
.assignment-center {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
}

.assignment-card {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(28em, 92vw);
  height: auto;
  align-content: start;
  pointer-events: auto;
  gap: 0.7em;
  padding: 1.1em 1.1em 1em;
  color: #fff;
  background: rgba(21, 21, 23, 0.95);
  h3 {
    font-size: 1.25em;
    line-height: 1.2;
  }
  .notice {
    font-size: 0.88em;
  }
}

.amt {
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}

.actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5em;
  margin-top: 0.2em;
}
</style>
