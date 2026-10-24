<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <span class="house-action-hint">
    <!-- viewerObj shows a fixed binding where a suppressed scope would hide ui-event glyphs. -->
    <BngBinding v-if="action || uiEvent || viewerObj" :action="action" :ui-event="uiEvent" :viewer-obj="viewerObj"
      :role="glyphLabel ? 'img' : undefined" :aria-label="glyphLabel" />
    {{ hold ? 'Hold to ' : '' }}{{ label }}<span v-if="reason" role="status"> — {{ reason }}</span>
  </span>
</template>
<script setup>
import { BngBinding } from "@/common/components/base"
defineProps({ action: String, uiEvent: String, viewerObj: Object, glyphLabel: String, label: { type: String, required: true }, hold: Boolean, reason: String })
</script>
