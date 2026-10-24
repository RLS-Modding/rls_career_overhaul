<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Inset grouped list of wallet transactions: category tile, what it was, what it was for, and a
     signed amount beside a labelled relative time. Tapping a row opens its details (the full label
     and context); a small chevron shows which way it goes. Inside a group (groupBy) rows leave out
     what the group already says. Used by the Wallet home and group pages. -->
<template>
  <ol class="wallet-list" :aria-label="label">
    <li v-for="{ row, text } in shown" :key="row.id" class="wallet-tx" :data-tone="toneOf(row.amount)">
      <div :data-expanded="expanded.has(row.id)" class="wallet-tx-details">
      <button type="button" :aria-expanded="expanded.has(row.id)" @click="toggleDetails(row.id)" class="wallet-tx-summary" bng-nav-item>
      <span class="wallet-tile" :style="{ backgroundColor: accentOf(row.category) }" aria-hidden="true">
        <BngIcon :type="icons[categoryIcon(row.category)] || icons[FALLBACK_ICON]" />
      </span>
      <span class="wallet-tx-copy">
        <span class="wallet-tx-name">{{ text.title }}</span>
        <span v-if="text.subtitle" class="wallet-tx-sub">{{ text.subtitle }}</span>
      </span>
      <span class="wallet-tx-amount">
        <span class="wallet-tx-value">{{ formatSigned(row.amount) }}</span>
        <span class="wallet-tx-time">{{ relativeTime(row.timestamp, now) }}<span class="wallet-tx-chevron" aria-hidden="true"></span></span>
      </span>
      </button>
      <div v-show="expanded.has(row.id)" class="wallet-tx-full">
        <p v-if="text.raw">{{ text.raw }}</p>
        <p v-if="text.context">{{ text.context }}</p>
        <p v-if="text.seller">Seller: {{ text.seller }}</p>
        <p v-if="!text.raw && !text.context && !text.seller">No other details recorded.</p>
      </div>
      </div>
    </li>
  </ol>
</template>

<script setup>
import { computed, getCurrentInstance, ref } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { FALLBACK_ICON, accentOf, categoryIcon, formatSigned, relativeTime, transactionText, toneOf } from "../../../utils/walletFinance.js"

const props = defineProps({
  rows: { type: Array, default: () => [] },
  limit: { type: Number, default: Infinity },
  now: { type: Number, default: () => Date.now() / 1000 },
  label: { type: String, default: "Transactions" },
  // The group these rows sit in ("vehicle", "source", "category", "period"), or "none".
  groupBy: { type: String, default: "none" },
})

const expanded = ref(new Set())
function toggleDetails(id) {
  if (expanded.value.has(id)) expanded.value.delete(id)
  else expanded.value.add(id)
}

const { proxy } = getCurrentInstance()
const shown = computed(() => props.rows.slice(0, props.limit).map(row => ({ row, text: transactionText(row, proxy.$ctx_t, props.groupBy) })))
</script>

<style scoped>
.wallet-list { list-style: none; margin: 0; padding: 0; border-radius: 14px; background: #1c1c1f; overflow: hidden; }
.wallet-tx { position: relative; }
.wallet-tx-summary { width: 100%; box-sizing: border-box; display: grid; grid-template-columns: 34px minmax(0, 1fr); align-items: start; gap: 6px 10px; padding: 12px; cursor: pointer; list-style: none; }
.wallet-tx-summary { border: 0; background: transparent; color: inherit; font: inherit; text-align: left; }
.wallet-tx-amount { grid-column: 2; display: flex; justify-content: space-between; align-items: baseline; gap: 8px; white-space: nowrap; }
.wallet-tx-full { padding: 0 12px 12px 56px; overflow-wrap: anywhere; line-height: 1.45; }
.wallet-tx-full p { margin: 0 0 6px; }
.wallet-tx + .wallet-tx::before { content: ""; position: absolute; top: 0; left: 56px; right: 0; height: 1px; background: rgba(255, 255, 255, 0.07); }
.wallet-tile { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 9px; color: #fff; font-size: 18px; --bng-icon-color: #fff; }
.wallet-tx-copy { display: grid; min-width: 0; gap: 1px; }
.wallet-tx-name { overflow: hidden; font-size: 13px; font-weight: 700; letter-spacing: -0.005em; line-height: 1.25; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow-wrap: anywhere; }
.wallet-tx-sub { overflow: hidden; color: rgba(235, 235, 245, 0.62); font-size: 11px; letter-spacing: 0.01em; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow-wrap: anywhere; }
.wallet-tx-value { font-size: 13.5px; font-weight: 800; font-variant-numeric: tabular-nums; }
.wallet-tx-time { color: rgba(235, 235, 245, 0.55); font-size: 10.5px; font-weight: 600; letter-spacing: 0.01em; white-space: nowrap; }
[data-tone="income"] .wallet-tx-value { color: #30d158; }
[data-tone="expense"] .wallet-tx-value { color: #ff6961; }
/* Quiet disclosure: a small chevron after the time, pointing down when closed and up when open. */
.wallet-tx-chevron { display: inline-block; width: 0.38em; height: 0.38em; margin: 0 0.15em 0.18em 0.6em; border-right: 1.5px solid currentColor; border-bottom: 1.5px solid currentColor; opacity: 0.7; transform: rotate(45deg); }
[data-expanded="true"] .wallet-tx-chevron { margin-bottom: -0.05em; transform: rotate(-135deg); }
</style>
