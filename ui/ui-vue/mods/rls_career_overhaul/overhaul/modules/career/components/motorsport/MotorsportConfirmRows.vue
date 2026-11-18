<!-- Owns labelled facts and money in Motorsport confirmation dialogs.
     Parts: motorsportConfirmations supplies content; HouseConfirm hosts it; motorsportLabels formats money.
     Contract: render supplied rows and optional copy without changing event state or choosing an action. -->
<template>
  <div class="motorsport-confirm-rows">
    <p v-if="intro" class="ms-caption">{{ intro }}</p>
    <dl><div v-for="row in rows" :key="row.label"><dt>{{ row.label }}</dt><dd :class="row.money ? moneyTone(row.value) : ''">{{ row.money ? money(row.value) : row.value }}</dd></div></dl>
    <p v-if="note" class="ms-caption">{{ note }}</p>
  </div>
</template>
<script setup>
import { money, moneyTone } from '../../utils/motorsportLabels.js'
defineProps({ intro: String, rows: { type: Array, default: () => [] }, note: String })
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss";
.motorsport-confirm-rows { display: grid; gap: .8em; }
dl { margin: 0; }
dl > div { display: flex; justify-content: space-between; align-items: baseline; gap: 1em; padding: .45em 0; border-bottom: 1px solid var(--line); }
dl > div:last-child { border-bottom: 0; }
dt { color: var(--muted); } dd { margin: 0; text-align: right; font-weight: 700; font-variant-numeric: tabular-nums; }
dd.ms-money { font-size: 1.1em; }
</style>
