<template>
  <!-- no scope on this screen: A on the focused Continue, or B / Start, continue -->
  <div class="cc-overlay" v-bng-on-ui-nav:back,menu="onNavContinue">
    <div class="rls-house cc-modal" @click.stop>
      <div class="cc-header">
        <div class="cc-title">{{ name }}</div>
        <div class="cc-sub">{{ winConditionName }}</div>
      </div>

      <div class="cc-body">
        <div class="cc-section">
          <div class="cc-section-title">Objective</div>
          <div class="cc-kv">
            <div class="cc-key">What you accomplished</div>
            <div class="cc-val">
              <template v-if="winCondition === 'payOffLoan'">
                Paid off loan
                <span v-if="loans && loans.amount"
                  >(<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCurrency(loans.amount) }})</span
                >
              </template>
              <template v-else-if="winCondition === 'reachTargetMoney'">
                Reached target: <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCurrency(targetMoney) }}
              </template>
              <template v-else>
                {{ winConditionDescription || winConditionName || "Completed challenge" }}
              </template>
            </div>
          </div>
        </div>

        <div class="cc-section">
          <div class="cc-section-title">Starting Conditions</div>
          <div class="cc-grid2">
            <div class="cc-kv">
              <div class="cc-key">Starting Capital</div>
              <div class="cc-val"
                ><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCurrency(startingCapital || 0) }}</div
              >
            </div>
            <div class="cc-kv">
              <div class="cc-key">Starting Loan</div>
              <div class="cc-val">
                <span v-if="loans && loans.amount"
                  ><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCurrency(loans.amount) }}</span
                >
                <span v-else>None</span>
              </div>
            </div>
            <template v-if="loans && loans.amount">
              <div class="cc-kv">
                <div class="cc-key">Loan Interest</div>
                <div class="cc-val">{{ toPercent(loans.interest) }}</div>
              </div>
              <div class="cc-kv">
                <div class="cc-key">Loan Payments</div>
                <div class="cc-val">{{ loans.payments }}</div>
              </div>
            </template>
          </div>
        </div>

        <div class="cc-section">
          <div class="cc-section-title">Highlights</div>
          <div class="cc-grid2">
            <div class="cc-kv">
              <div class="cc-key">Top Earner</div>
              <div class="cc-val"
                >{{ topEarner.label }} (+<BngIcon class="cur" :type="icons.beamCurrency" />{{
                  formatCurrency(topEarner.amount)
                }})</div
              >
            </div>
            <div class="cc-kv">
              <div class="cc-key">Top Expense</div>
              <div class="cc-val"
                >{{ topExpense.label }} (-<BngIcon class="cur" :type="icons.beamCurrency" />{{
                  formatCurrency(topExpense.amount)
                }})</div
              >
            </div>
            <div class="cc-kv">
              <div class="cc-key">Time Spent</div>
              <div class="cc-val">{{ formatDuration(simulationTimeSpent) }}</div>
            </div>
          </div>
        </div>
      </div>

      <div class="cc-footer">
        <HouseButton ref="continueButton" variant="primary" binding="ok" @click="onContinue">Continue</HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { onMounted, onBeforeUnmount, ref } from "vue";
import { useEvents } from "@/services/events";
import { lua } from "@/bridge";
import { BngIcon, icons } from "@/common/components/base";
import { vBngOnUiNav } from "@/common/directives";
import { refocusIfLost } from "../composables/useScreenEntryFocus";
import HouseButton from "../components/house/HouseButton.vue";

const events = useEvents();

const id = ref("");
const name = ref("");
const description = ref("");
const winCondition = ref("");
const winConditionName = ref("");
const winConditionDescription = ref("");
const targetMoney = ref(0);
const simulationTimeSpent = ref(0);
const startingCapital = ref(0);
const loans = ref(null);

const topEarner = ref({ label: "—", amount: 0 });
const topExpense = ref({ label: "—", amount: 0 });

const formatCurrency = (v) => {
  v = Number(v || 0);
  if (v >= 1e6) return (v / 1e6).toFixed(2).replace(/\.00$/, "") + "M";
  if (v >= 1e3) return (v / 1e3).toFixed(2).replace(/\.00$/, "") + "k";
  return v.toFixed(0);
};
const toPercent = (v) => `${Math.round(Number(v || 0) * 100)}%`;
const formatDuration = (seconds) => {
  seconds = Math.max(0, Number(seconds || 0));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  const ms = Math.floor((seconds % 1) * 1000);
  const parts = [];
  if (h) parts.push(`${h}h`);
  if (m) parts.push(`${m}m`);
  parts.push(`${s}s`);
  if (ms || (!h && !m && s === 0)) parts.push(`${ms}ms`);
  return parts.join(" ");
};

async function loadTopEntries() {
  try {
    const log = await lua.overhaul_career_economy_playerAttributes.getAttributeLog();
    if (Array.isArray(log)) {
      const gains = {};
      const losses = {};
      for (const entry of log) {
        if (!entry || !entry.attributeChange || !entry.reason) continue;
        const money = Number(entry.attributeChange.money || 0);
        const label = String(entry.reason.label || "Unknown");
        if (money > 0) {
          gains[label] = (gains[label] || 0) + money;
        } else if (money < 0) {
          losses[label] = (losses[label] || 0) + Math.abs(money);
        }
      }
      let topGain = { label: "—", amount: 0 };
      for (const [label, amt] of Object.entries(gains)) {
        if (amt > topGain.amount) topGain = { label, amount: amt };
      }
      let topLoss = { label: "—", amount: 0 };
      for (const [label, amt] of Object.entries(losses)) {
        if (amt > topLoss.amount) topLoss = { label, amount: amt };
      }
      topEarner.value = topGain;
      topExpense.value = topLoss;
    }
  } catch (e) { reportUiFailure(e, "load top entries (ChallengeComplete)") }
}

const continueButton = ref(null);

// B / Start: stop the event, or it also reaches the game's global fallback and the router goes back twice
function onNavContinue(event) {
  event?.stopPropagation?.();
  onContinue();
}

function onContinue() {
  lua.extensions.ui_router.back();
}

onMounted(() => {
  events.on("challengeCompleteData", (data) => {
    if (data) {
      id.value = data.id || "";
      name.value = data.name || "Challenge Complete";
      description.value = data.description || "";
      winCondition.value = data.winCondition || "";
      winConditionName.value = data.winConditionName || "";
      winConditionDescription.value = data.winConditionDescription || "";
      targetMoney.value = Number(data.targetMoney || 0);
      simulationTimeSpent.value = Number(data.simulationTimeSpent || 0);
      startingCapital.value = Number(data.startingCapital || 0);
      loans.value = data.loans || null;

      loadTopEntries();
    }
  });

  setTimeout(() => {
    lua.overhaul_career_challengeModes.requestChallengeCompleteData();
  }, 1000);

  // controller entry: the only action (no scope here, so nothing would be focused)
  refocusIfLost(() => continueButton.value?.$el);
});

onBeforeUnmount(() => {
  events.off("challengeCompleteData");
});
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.cc-overlay {
  // scaled unit: the screen keeps the same share of the display at 720p..4K (rem/px-sized it shrank at 1440p),
  // still following the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, 1rem);
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.45);
  backdrop-filter: blur(6px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 3000;
}

.cc-modal {
  width: min(56em, calc(100% - 2em));
  padding: 1.1em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
}

.cc-header {
  text-align: center;
}

.cc-title {
  font-size: 1.8em;
  font-weight: 700;
  line-height: 1.2;
}

.cc-sub {
  margin-top: 0.25em;
  color: var(--muted);
  font-weight: 600;
}

.cc-body {
  margin-top: 0.75em;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}

.cc-section {
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.cc-section-title {
  margin-bottom: 0.5em;
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.cc-grid2 {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 0.5em 1em;
}

.cc-kv {
  display: grid;
  // label keeps one line; a long value ("Trailer delivery: A to B (+3.85k)") wraps in its own column
  // instead of squeezing the label into two lines
  grid-template-columns: auto minmax(0, 1fr);
  min-width: 0;
  gap: 0.5em;
  align-items: center;
}

.cc-key {
  color: var(--muted);
  white-space: nowrap;
}

.cc-val {
  font-weight: 700;
  min-width: 0;
  text-align: right;
  overflow-wrap: anywhere;
}

.cc-footer {
  display: flex;
  justify-content: flex-end;
  margin-top: 0.75em;
  > :deep(.house-button) {
    min-width: 6.5em;
  }
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
