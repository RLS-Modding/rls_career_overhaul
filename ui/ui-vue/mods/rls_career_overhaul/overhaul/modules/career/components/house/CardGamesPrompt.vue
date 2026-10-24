<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="modal card-games-prompt">
    <h3>Let's go gambling!</h3>
    <div class="actions">
      <HouseButton variant="quiet" bng-scoped-nav-autofocus @click="emit('return', false)">Cancel</HouseButton>
      <HouseButton variant="primary" @click="emit('return', true)">Gamble</HouseButton>
    </div>
  </div>
</template>
<script setup>
import HouseButton from "./HouseButton.vue"
const emit = defineEmits(["return"])
</script>
<style scoped>
.card-games-prompt { min-width: 24em; padding: 1.5em; background: #1a1a1c; color: white; }
.actions { display: flex; justify-content: flex-end; gap: .75em; margin-top: 1.5em; }
</style>
