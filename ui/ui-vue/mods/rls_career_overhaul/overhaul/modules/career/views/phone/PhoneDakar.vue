<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="dakar-phone" v-if="data.active && data.checkpoint">
    <button class="clue-toggle" type="button" :class="{ open: clueOpen }" @click="clueOpen = !clueOpen">
      <div class="clue-toggle-main">
        <span class="clue-kicker">Current clue</span>
        <strong>{{ data.checkpoint.name }}</strong>
      </div>
      <span class="clue-chevron" aria-hidden="true">&rsaquo;</span>
    </button>

    <div v-if="clueOpen" class="clue-detail">
      <img :src="data.checkpoint.image" alt="" class="checkpoint-image">
      <div class="checkpoint-summary">
        <div class="checkpoint-title">{{ data.checkpoint.name }}</div>
        <div class="checkpoint-meta">
          <span>{{ checkpointStep }}</span>
          <span>{{ distanceText }}</span>
          <span v-if="headingText">{{ headingText }}</span>
        </div>
      </div>
    </div>
    <div v-else class="checkpoint-meta collapsed-meta">
      <span>{{ checkpointStep }}</span>
      <span>{{ distanceText }}</span>
      <span v-if="headingText">{{ headingText }}</span>
    </div>

    <div class="repair-row">
      <span>Repairs left</span>
      <strong>{{ data.repairsLeft }}</strong>
    </div>
    <div class="actions">
      <BngButton :disabled="!data.canRepair" :accent="ACCENTS.main" @click="repair">Repair</BngButton>
      <BngButton :accent="ACCENTS.secondary" @click="abandon">Abandon</BngButton>
    </div>
  </div>
  <div class="dakar-phone pending" v-else-if="data.pending">
    <div class="pending-content">
      <div class="empty-title">Dakar Signed Up</div>
      <p>Drive to the starting line.</p>
      <strong>{{ startDistanceText }}</strong>
    </div>
    <div class="actions single">
      <BngButton :disabled="!data.atStart" :accent="ACCENTS.main" @click="startEvent">Start Event</BngButton>
    </div>
  </div>
  <div class="dakar-phone empty" v-else>
    <div class="empty-title">No Active Dakar</div>
    <BngButton :accent="ACCENTS.secondary" @click="refresh">Refresh</BngButton>
  </div>
</template>

<script setup>

import { usePhoneAppFocus } from './controllerLayers.js'
import { openHouseConfirmation } from '../../components/house/index.js'
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import { BngButton, ACCENTS } from '@/common/components/base'
import { useBridge } from '@/bridge'

usePhoneAppFocus()


const { events } = useBridge()
const clueOpen = ref(false)
const lastCheckpointKey = ref('')
const data = reactive({
  active: false,
  checkpoint: null,
  repairsLeft: 0,
  canRepair: false,
  pending: false,
  startDistanceMeters: null,
  atStart: false,
})

function applyData(payload) {
  const checkpoint = payload?.checkpoint || null
  const checkpointKey = checkpoint ? `${checkpoint.index || ''}:${checkpoint.name || ''}:${checkpoint.image || ''}` : ''
  if (checkpointKey !== lastCheckpointKey.value) {
    clueOpen.value = false
    lastCheckpointKey.value = checkpointKey
  }
  data.active = !!payload?.active
  data.pending = !!payload?.pending
  data.checkpoint = checkpoint
  data.repairsLeft = payload?.repairsLeft ?? 0
  data.canRepair = !!payload?.canRepair
  data.startDistanceMeters = payload?.start?.distanceMeters ?? null
  data.atStart = !!payload?.start?.atStart
}

const distanceText = computed(() => {
  const meters = data.checkpoint?.distanceMeters
  if (meters == null) return ''
  if (meters >= 1000) return `${(meters / 1000).toFixed(1)} km`
  return `${Math.max(0, Math.round(meters))} m`
})

const checkpointStep = computed(() => {
  if (!data.checkpoint) return ''
  return `${data.checkpoint.index}/${data.checkpoint.count}`
})

const headingText = computed(() => data.checkpoint?.headingText || '')

const startDistanceText = computed(() => {
  const meters = data.startDistanceMeters
  if (meters == null) return ''
  if (meters >= 1000) return `${(meters / 1000).toFixed(1)} km remaining`
  return `${Math.max(0, Math.round(meters))} m remaining`
})

function callDakar(method) {
  window.bngApi.engineLua(`local name = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureExtension and overhaul_world_maps.getOptionalFeatureExtension('dakar'); local config = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureConfig and overhaul_world_maps.getOptionalFeatureConfig('dakar'); local feature = name and extensions[name]; if feature and feature.${method} then if config ~= nil then feature.${method}(config) else feature.${method}() end else log('W', 'overhaul_optional_events', 'Dakar ${method} disabled: provider or method unavailable (' .. tostring(name) .. ')') end`)
}

function refresh() {
  callDakar('requestDakarPhoneData')
}

function repair() {
  callDakar('useRepairKit')
}

function startEvent() {
  callDakar('startEvent')
}

async function abandon() {
  if (!(await openHouseConfirmation('Abandon Dakar?', 'End the current Dakar event?', [{ label: 'Cancel', value: false, extras: { cancel: true } }, { label: 'Abandon', value: true, extras: { destructive: true } }]))) return
  callDakar('abandonEvent')
}

onMounted(() => {
  events.on('dakarPhoneData', applyData)
  refresh()
})

onUnmounted(() => {
  events.off('dakarPhoneData', applyData)
})
</script>

<style scoped lang="scss">
.dakar-phone {
  height: 100%;
  min-height: 0;
  color: white;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 46px 10px 12px;
  overflow: hidden;
  box-sizing: border-box;
  background:
    linear-gradient(180deg, rgba(60, 41, 28, 0.55), rgba(12, 12, 12, 0.96) 42%),
    #111;
}

.clue-toggle {
  width: 100%;
  flex: 0 0 auto;
  min-height: 58px;
  border: 1px solid rgba(244, 196, 156, 0.34);
  border-radius: 8px;
  color: #fff;
  background: rgba(255, 255, 255, 0.09);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 9px 10px;
  text-align: left;
  font: inherit;
}

.clue-toggle.open {
  border-color: rgba(244, 196, 156, 0.62);
  background: rgba(244, 196, 156, 0.14);
}

.clue-toggle-main {
  min-width: 0;
  display: grid;
  gap: 3px;
}

.clue-kicker {
  color: #f4c49c;
  font-size: 0.72rem;
  font-weight: 800;
  text-transform: uppercase;
}

.clue-toggle strong {
  min-width: 0;
  font-size: 1rem;
  line-height: 1.15;
  word-break: break-word;
}

.clue-chevron {
  flex: 0 0 auto;
  color: #f4c49c;
  font-size: 1.8rem;
  line-height: 1;
  transform: rotate(90deg);
  transition: transform 0.16s ease;
}

.clue-toggle.open .clue-chevron {
  transform: rotate(-90deg);
}

.clue-detail {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 7px;
  overflow: hidden;
}

.checkpoint-image {
  width: 100%;
  flex: 1 1 auto;
  min-height: 0;
  object-fit: contain;
  background: #080808;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 8px;
}

.checkpoint-summary {
  flex: 0 0 auto;
  min-width: 0;
}

.checkpoint-title {
  font-size: 1.05rem;
  font-weight: 700;
  line-height: 1.15;
  word-break: break-word;
}

.checkpoint-meta,
.repair-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  color: #d5d5d5;
  font-size: 0.9rem;
}

.checkpoint-meta {
  flex-wrap: wrap;
}

.collapsed-meta {
  flex: 0 0 auto;
  padding: 7px 9px;
  border-radius: 7px;
  background: rgba(0, 0, 0, 0.24);
}

.checkpoint-meta span:last-child {
  color: #f4c49c;
  font-weight: 700;
}

.repair-row {
  flex: 0 0 auto;
  padding: 6px 9px;
  background: rgba(255, 255, 255, 0.08);
  border-radius: 6px;
}

.repair-row strong {
  color: #fff;
  font-size: 1.1rem;
}

.actions {
  flex: 0 0 auto;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}

.actions.single {
  grid-template-columns: 1fr;
}

.empty {
  place-items: center;
  justify-content: center;
}

.pending {
  justify-content: center;
}

.pending-content {
  text-align: center;
  margin: auto 0;
}

.pending-content p {
  margin: 8px 0;
  color: #d5d5d5;
}

.pending-content strong {
  font-size: 1.1rem;
}

.empty-title {
  font-size: 1.2rem;
  font-weight: 700;
}
</style>
