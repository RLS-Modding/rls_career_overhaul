<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="activity-details">
    <dl>
      <div v-for="(fact, index) in facts" :key="index" class="fact-line">
        <dt>{{ fact.label }}</dt>
        <dd :class="{ gain: fact.kind === 'money' && Number(fact.value) > 0, loss: fact.kind === 'money' && Number(fact.value) < 0 }">
          {{ fact.kind === "money" ? formatMoney(Number(fact.value)) : fact.value }}
        </dd>
      </div>
    </dl>
    <p v-if="!facts.length && entry.text" class="legacy-detail">{{ legacyText }}</p>
    <div v-if="amount !== undefined" class="entry-total">
      <span>{{ amount < 0 ? 'Total paid' : 'Total earned' }}</span>
      <strong :class="{ gain: amount > 0, loss: amount < 0 }">{{ formatMoney(amount) }}</strong>
    </div>
    <div v-if="date" class="recorded"><span>Recorded</span><time :datetime="date.toISOString()">{{ date.toLocaleString(undefined, { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }) }}</time></div>
    <HouseButton v-if="related" class="journal-link" variant="quiet" @click="openRelated">{{ related.label }} <span aria-hidden="true">&rarr;</span></HouseButton>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { HouseButton } from "./house/index.js"
import { lua } from "@/bridge"
import { moneyValue, formatMoney, publicFacts, relatedScreen } from "../utils/logbookPresentation.js"

const props = defineProps({ entry: { type: Object, required: true } })
const amount = computed(() => moneyValue(props.entry))
const facts = computed(() => publicFacts(props.entry))
const legacyText = computed(() => props.entry.overhaulEntryType ? String(props.entry.text || "") : String(props.entry.text || "").replace(/\s+[\/·•]\s+/g, "\n"))
const date = computed(() => {
  const value = new Date(Number(props.entry.time) * 1000)
  return props.entry.time != null && Number.isFinite(value.getTime()) ? value : undefined
})
// Only known, self-contained screens; never navigate to a persisted arbitrary route.
const related = computed(() => relatedScreen(props.entry))
const openRelated = () => { if (related.value) lua.extensions.ui_router.navigate(related.value.route, {}) }
</script>

<style scoped>
.activity-details { color: #fff; }
dl { margin: 0; }
.fact-line { display: flex; align-items: baseline; justify-content: space-between; gap: 2em; padding: 0.5em 0; border-bottom: 1px solid var(--line); }
dt { color: var(--muted); font-size: 0.9em; }
dd { margin: 0; min-width: 0; text-align: right; font-weight: 600; font-variant-numeric: tabular-nums; }
.gain { color: var(--ok); }
.loss { color: var(--bad); }
.entry-total { display: flex; justify-content: space-between; align-items: baseline; gap: 1em; padding: 0.7em 0 0; font-weight: 700; }
.entry-total strong { font-size: 1.3em; font-variant-numeric: tabular-nums; font-weight: 800; }
.recorded { display: flex; align-items: baseline; justify-content: space-between; gap: 1em; padding-top: 1.1em; color: var(--faint); font-size: 0.82em; }
.legacy-detail { white-space: pre-wrap; margin: 1em 0; color: var(--muted); line-height: 1.4; }
.journal-link { margin-top: 1em; padding-left: 0; }
</style>
