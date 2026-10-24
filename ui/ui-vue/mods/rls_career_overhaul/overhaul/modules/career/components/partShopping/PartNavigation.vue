<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <nav class="part-navigation" aria-label="Part navigation">
    <HouseButton v-if="canBack" compact variant="quiet" :icon="icons.arrowSmallLeft" binding="back" @click="$emit('back')">
      {{ $translate.instant("ui.common.back") }}
    </HouseButton>
    <span class="location" aria-current="page">{{ label }}</span>
    <BngBinding v-if="!active" ui-event="context" controller />
  </nav>
</template>

<script setup>
import { BngBinding, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { $translate } from "@/services/translation"

defineProps({ label: String, canBack: Boolean, active: Boolean })
defineEmits(["back"])
</script>

<style scoped lang="scss">
.part-navigation {
  display: flex;
  flex: 0 0 auto;
  align-items: center;
  gap: 0.65em;
  min-height: 2.8em;
  padding: 0.35em var(--inset, 0.85em);
  border-bottom: 1px solid var(--line, rgba(255, 255, 255, 0.1));
  margin-bottom: 0.35em;
}
.location {
  flex: 1 1 auto;
  min-width: 0;
  color: var(--accent, #ff6600);
  font-weight: 700;
  overflow-wrap: anywhere;
}
</style>
