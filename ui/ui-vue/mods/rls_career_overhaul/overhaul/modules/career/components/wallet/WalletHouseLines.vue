<!-- House lines for wallet transactions in the pause Financial History: what it was and the
     amount, then what it was for and when. Choosing a line opens its details (the full label and
     context); a small chevron shows which way it goes. Inside a group (groupBy) lines leave out
     what the group already says. Used by the ungrouped list and by a pulled-out group card. -->
<template>
  <div class="lines fin-lines">
    <div :data-expanded="expanded.has(row.id)" v-for="{ row, text } in shown" :key="row.id" class="line fin-entry" :data-tone="toneOf(row.amount)">
      <button type="button" :aria-expanded="expanded.has(row.id)" @click="toggleDetails(row.id)" class="fin-line" bng-nav-item>
        <span class="fin-reason">{{ text.title }}</span>
        <span class="fin-amount">{{ formatSigned(row.amount) }}</span>
        <span class="fin-subtitle">{{ text.subtitle }}</span>
        <span class="fin-when">{{ relativeTime(row.timestamp, now) }}<span class="fin-chevron" aria-hidden="true"></span></span>
      </button>
      <div v-show="expanded.has(row.id)" class="fin-full">
        <p v-if="text.raw">{{ text.raw }}</p>
        <p v-if="text.context">{{ text.context }}</p>
        <p v-if="text.seller">Seller: {{ text.seller }}</p>
        <p v-if="!text.raw && !text.context && !text.seller">No other details recorded.</p>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, getCurrentInstance, ref } from "vue"
import { formatSigned, relativeTime, transactionText, toneOf } from "../../utils/walletFinance.js"

const props = defineProps({
  rows: { type: Array, default: () => [] },
  now: { type: Number, default: () => Date.now() / 1000 },
  // The group these lines sit in ("vehicle", "source", "category", "period"), or "none".
  groupBy: { type: String, default: "none" },
})

const expanded = ref(new Set())
function toggleDetails(id) {
  if (expanded.value.has(id)) expanded.value.delete(id)
  else expanded.value.add(id)
}

const { proxy } = getCurrentInstance()
const shown = computed(() => props.rows.map(row => ({ row, text: transactionText(row, proxy.$ctx_t, props.groupBy) })))
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Two lines per transaction: what and how much, then what for and when. */
.fin-entry.line { display: block; padding: 0; }
.fin-line {
  width: 100%;
  box-sizing: border-box;
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  grid-template-areas: "reason amount" "meta when";
  align-items: start;
  gap: 0.2em 1em;
  padding: 0.5em var(--inset) 0.45em;
  font-size: 0.92em;
  cursor: pointer;
  list-style: none;
}
.fin-reason { grid-area: reason; overflow: hidden; font-weight: 600; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow-wrap: anywhere; }
.fin-subtitle { grid-area: meta; color: var(--muted); line-height: 1.4; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; overflow-wrap: anywhere; }
.fin-line { border: 0; background: transparent; color: inherit; font-family: inherit; text-align: left; }
.fin-full { padding: 0 var(--inset) 0.6em; overflow-wrap: anywhere; line-height: 1.45; }
.fin-full p { margin: 0 0 0.3em; }
.fin-when { grid-area: when; color: var(--faint); font-size: 0.85em; font-weight: 600; text-align: right; white-space: nowrap; }
.fin-amount { white-space: nowrap; grid-area: amount; font-weight: 800; font-variant-numeric: tabular-nums; text-align: right; }
.fin-entry[data-tone="income"] .fin-amount { color: var(--ok); }
.fin-entry[data-tone="expense"] .fin-amount { color: var(--bad); }
/* Quiet disclosure: a small chevron after the time, pointing down when closed and up when open. */
.fin-chevron { display: inline-block; width: 0.4em; height: 0.4em; margin: 0 0.15em 0.2em 0.6em; border-right: 1.5px solid currentColor; border-bottom: 1.5px solid currentColor; transform: rotate(45deg); }
[data-expanded="true"] .fin-chevron { margin-bottom: -0.05em; transform: rotate(-135deg); }
</style>
