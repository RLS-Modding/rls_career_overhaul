<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- The Vault's paid entry prompt: the 2.7 card's layout (icon, title, fee row, warning, paired
     buttons) built from the house kit (HouseConfirm's card, HouseButton). It sits inside the auction's
     own nav scope, so Back still reaches the screen's cancel. When entry is blocked, the reason shows
     under the fee row. Focus starts on Enter Auction when entry is allowed, on Leave when blocked. -->
<template>
  <div class="rls-house entry-prompt">
    <div class="modal entry-modal" role="dialog" aria-modal="true" aria-labelledby="vault-entry-title">
      <div class="entry-head">
        <BngIcon class="entry-icon" :type="icons.carCoins" />
        <h3 id="vault-entry-title">The Vault</h3>
      </div>
      <div v-if="fee > 0" class="entry-fee">
        <span>Entry Fee</span>
        <strong>{{ formatDollars(fee) }}</strong>
      </div>
      <p v-if="!canPay" class="notice bad">{{ message || "You can't enter The Vault right now." }}</p>
      <div class="entry-actions">
        <HouseButton
          block
          variant="neutral"
          ref="leaveButton"
          binding="back"
          :bng-scoped-nav-autofocus="startOnEnter ? null : ''"
          @click="emit('cancel')">
          Leave
        </HouseButton>
        <HouseButton
          block
          variant="primary"
          ref="enterButton"
          :disabled="!canPay"
          :bng-scoped-nav-autofocus="startOnEnter ? '' : null"
          @click="pay">
          Enter Auction
        </HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import HouseButton from "./house/HouseButton.vue"
import { refocusIfLost } from "../composables/useScreenEntryFocus"

const props = defineProps({
  // Lua's status line; shown as the reason when entry is blocked
  message: { type: String, default: "" },
  fee: { type: Number, default: 0 },
  canPay: Boolean,
})
const emit = defineEmits(["pay", "cancel"])

// Disabled styling is not the guard: no click, key or pad path may pay while entry is blocked.
const pay = () => {
  if (props.canPay) emit("pay")
}

// Only the opening focus follows canPay; a later money or garage change must not move the pad.
const startOnEnter = props.canPay
const leaveButton = ref(null)
const enterButton = ref(null)
// ...unless the focused Enter Auction just became disabled: then Leave takes over instead of nothing.
watch(() => props.canPay, canPay => {
  const enter = enterButton.value?.$el
  if (!canPay && enter && document.activeElement === enter) refocusIfLost(() => leaveButton.value?.$el, { force: true })
})

// Same format as Lua's view.formatDollars: 1000 -> "$1,000"
const formatDollars = amount => "$" + Math.round(amount).toLocaleString("en-US")
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.entry-prompt {
  position: fixed;
  inset: 0;
  display: grid;
  place-items: center;
  background: rgba(0, 0, 0, 0.45);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  pointer-events: auto;
}
.entry-modal {
  width: min(24em, 92vw);
  padding: 1.3em 1.2em 1.1em;
}
.entry-head {
  display: grid;
  justify-items: center;
  gap: var(--space-2);
  h3 {
    font-size: 1.2em;
    line-height: 1.2;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
}
.entry-icon {
  font-size: 2.2em;
  color: var(--accent);
}
.entry-fee {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  padding: 0.6em 0.8em 0.5em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: var(--muted);
  font-size: 0.95em;
  font-weight: 600;
  strong {
    color: var(--money);
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }
}
.entry-actions {
  display: grid;
  grid-template-columns: 1fr 1.5fr;
  gap: var(--space-2);
  margin-top: var(--space-1);
}
</style>
