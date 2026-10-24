<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <span data-broker-scope v-if="compact && !isLocked(row)" class="access-line">
    <span data-broker-scope class="pill" :class="fit.state" :title="fit.reason">{{ fit.label }}</span>
  </span>
  <span data-broker-scope v-else class="access-summary">
    <span data-broker-scope v-if="!isLocked(row) || (showHere && row.atPickup)" class="pills">
      <span data-broker-scope v-if="showHere && row.atPickup" class="pill here">You're here</span>
      <span data-broker-scope v-if="!isLocked(row)" class="pill" :class="fit.state" :title="fit.reason">{{ fit.label }}</span>
    </span>
    <span data-broker-scope v-if="badges.length" class="badge-line"><span data-broker-scope v-for="(badge, index) in badges" :key="index" class="badge-tag">{{ badge }}</span></span>
    <span data-broker-scope v-if="!isLocked(row) && fit.state !== 'ok'" class="fit-reason">{{ fit.reason }}</span>
    <span data-broker-scope v-for="(reason, index) in accessReasons(row)" :key="index" class="requirement">
      <strong data-broker-scope>{{ requirementText(reason) }}</strong>
      <progress data-broker-scope v-if="requirementProgress(reason) != null" :value="requirementProgress(reason)" max="1" :aria-label="reason.label" :title="xpText(reason)" />
      <small data-broker-scope v-if="!compact && reason.progress?.needed">{{ xpText(reason) }}</small>
    </span>
  </span>
</template>

<script setup>
// Rows pass compact: only the fit, so every row keeps one calm status line;
// details show the reason, then modifiers and expiry as quiet tags.
import { computed, inject } from 'vue'
const props = defineProps({ row: { type: Object, required: true }, compact: Boolean, showHere: Boolean })
const { s, isLocked, fitBadge, offerBadges, accessReasons, requirementProgress, requirementText } = inject(Symbol.for('overhaul.phoneBroker'))
const fit = computed(() => fitBadge(props.row))
const badges = computed(() => offerBadges(props.row, s.data.logisticsTime))
function xpText(reason) {
  return reason.progress?.needed ? `Level ${reason.progress.level ?? reason.have}: ${reason.progress.current} / ${reason.progress.needed} XP` : reason.label
}
</script>
