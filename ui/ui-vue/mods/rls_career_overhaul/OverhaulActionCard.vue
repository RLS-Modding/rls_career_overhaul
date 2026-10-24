<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <section class="overhaul-action-card">
    <h2>{{ title }}</h2>
    <p>{{ description }}</p>
    <BngButton :disabled="!action" @click="runAction">{{ actionLabel || title }}</BngButton>
  </section>
</template>

<script setup>
import { BngButton } from "@/common/components/base"
import { useBridge } from "@/bridge"

const props = defineProps({
  title: String,
  description: String,
  actionLabel: String,
  action: String,
})
const { api } = useBridge()
const runAction = () => { if (props.action) api.engineLua(props.action) }
</script>

<style scoped>
.overhaul-action-card { padding: 1.5rem; }
p { margin-bottom: 1.5rem; }
</style>
