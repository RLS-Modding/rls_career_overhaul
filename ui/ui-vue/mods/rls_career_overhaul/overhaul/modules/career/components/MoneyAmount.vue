<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <span class="money-amount"><BngIcon class="money-glyph" :type="icons.beamCurrency" color="inherit" aria-hidden="true" /><slot /></span>
</template>

<script setup>
import { BngIcon, icons } from "@/common/components/base"
</script>

<style scoped>
.money-amount {
  display: inline-flex;
  align-items: baseline;
  gap: 0.18em;
  white-space: nowrap;
}
.money-glyph {
  --bng-icon-size: 1em;
  align-self: center;
}
</style>
