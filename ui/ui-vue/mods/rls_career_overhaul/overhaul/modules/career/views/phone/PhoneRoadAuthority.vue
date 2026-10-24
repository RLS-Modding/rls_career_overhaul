<template>
  <div v-if="selectedReport" class="road-authority-phone detail-view">
    <button class="back-button" type="button" aria-label="Back" @click="selectedReportId = null">
      <span aria-hidden="true">&lsaquo;</span>
    </button>
    <div class="detail-footer">
      <h2>{{ selectedReport.name }}</h2>
      <span>{{ selectedReport.status || 'Active' }}</span>
    </div>
    <img :src="selectedReport.image" alt="" class="detail-image">
  </div>

  <div v-else class="road-authority-phone">
    <div class="summary-row">
      <span>{{ activeCountText }}</span>
      <strong>{{ data.debrisClearedCount }} cleared</strong>
    </div>

    <div v-if="data.activeReports.length" class="report-list" v-bng-ui-nav-scroll>
      <button
        v-for="report in data.activeReports"
        :key="report.id"
        class="report-card"
        type="button"
        @click="selectedReportId = report.id">
        <div class="report-body">
          <div class="report-copy">
            <span class="report-kicker">Cleanup report</span>
            <h2>{{ report.name }}</h2>
          </div>
          <span class="report-status">{{ report.status || 'Active' }}</span>
        </div>
        <span class="report-chevron" aria-hidden="true">&rsaquo;</span>
      </button>
    </div>

    <div v-else class="empty-state">
      <div class="empty-title">No Active Reports</div>
      <p>New cleanup reports will appear here.</p>
    </div>
  </div>
</template>

<script setup>

import { usePhoneAppFocus } from './controllerLayers.js'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { vBngUiNavScroll } from '@/common/directives'
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import { useBridge } from '@/bridge'

usePhoneAppFocus()


const { events } = useBridge()
const data = reactive({
  activeReports: [],
  debrisClearedCount: 0,
  maxActiveReports: 10,
})
const selectedReportId = ref(null)
usePhoneScreen({ onBack: () => { if (!selectedReportId.value) return false; selectedReportId.value = null; return true } })

function applyData(payload) {
  data.activeReports = Array.isArray(payload?.activeReports) ? payload.activeReports : []
  data.debrisClearedCount = payload?.debrisClearedCount ?? 0
  data.maxActiveReports = payload?.maxActiveReports ?? 10
  if (selectedReportId.value && !data.activeReports.some(report => report.id === selectedReportId.value)) {
    selectedReportId.value = null
  }
}

const activeCountText = computed(() => {
  const count = data.activeReports.length
  return `${count}/${data.maxActiveReports} active`
})

const selectedReport = computed(() => {
  return data.activeReports.find(report => report.id === selectedReportId.value) || null
})

function refresh() {
  window.bngApi.engineLua("local name = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureExtension and overhaul_world_maps.getOptionalFeatureExtension('roadAuthority'); local config = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureConfig and overhaul_world_maps.getOptionalFeatureConfig('roadAuthority'); local feature = name and extensions[name]; if feature and feature.requestRoadAuthorityPhoneData then if config ~= nil then feature.requestRoadAuthorityPhoneData(config) else feature.requestRoadAuthorityPhoneData() end else log('W', 'overhaul_optional_events', 'Road Authority phone disabled: provider or requestRoadAuthorityPhoneData unavailable (' .. tostring(name) .. ')') end")
}

onMounted(() => {
  events.on('roadAuthorityPhoneData', applyData)
  refresh()
})

onUnmounted(() => {
  events.off('roadAuthorityPhoneData', applyData)
})
</script>

<style scoped lang="scss">
.road-authority-phone {
  height: 100%;
  min-height: 0;
  color: #fff;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 46px 10px 12px;
  overflow: hidden;
  box-sizing: border-box;
  background:
    linear-gradient(180deg, rgba(28, 58, 42, 0.54), rgba(10, 12, 11, 0.96) 44%),
    #101311;
}

.detail-view {
  position: relative;
  overflow: hidden;
}

.back-button {
  position: absolute;
  top: 50px;
  left: 12px;
  z-index: 1;
  width: 32px;
  height: 32px;
  border: 0;
  border-radius: 50%;
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  display: grid;
  place-items: center;
  font-size: 1.8rem;
  line-height: 1;
  padding: 0 0 3px;
}

.detail-image {
  display: block;
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  object-fit: contain;
  background: #070707;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 8px;
}

.detail-footer {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-height: 42px;
  padding: 0 2px 3px 42px;
}

.detail-footer h2 {
  margin: 0;
  min-width: 0;
  font-size: 1.05rem;
  line-height: 1.15;
  word-break: break-word;
}

.detail-footer span {
  flex: 0 0 auto;
  color: #bfe5b9;
  font-size: 0.84rem;
  font-weight: 700;
}

.summary-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex: 0 0 auto;
  padding: 7px 9px;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.08);
  color: #d8d8d8;
  font-size: 0.88rem;
}

.summary-row strong {
  color: #fff;
  font-size: 0.95rem;
}

.report-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-height: 0;
  overflow-y: auto;
  padding-right: 2px;
}

.report-card {
  flex: 0 0 auto;
  min-height: 62px;
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(191, 229, 185, 0.24);
  color: inherit;
  font: inherit;
  padding: 9px 10px;
  text-align: left;
  display: flex;
  align-items: center;
  gap: 9px;
}

.report-body {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.report-copy {
  min-width: 0;
  display: grid;
  gap: 3px;
}

.report-kicker {
  color: #bfe5b9;
  font-size: 0.7rem;
  font-weight: 800;
  text-transform: uppercase;
}

.report-body h2 {
  margin: 0;
  min-width: 0;
  font-size: 1rem;
  line-height: 1.15;
  font-weight: 700;
  word-break: break-word;
}

.report-status {
  flex: 0 0 auto;
  color: #bfe5b9;
  font-size: 0.84rem;
  font-weight: 700;
}

.report-chevron {
  flex: 0 0 auto;
  color: #bfe5b9;
  font-size: 1.6rem;
  line-height: 1;
}

.empty-state {
  flex: 1 1 auto;
  display: grid;
  place-content: center;
  gap: 7px;
  text-align: center;
}

.empty-title {
  font-size: 1.12rem;
  font-weight: 700;
}

.empty-state p {
  margin: 0;
  color: #d5d5d5;
  font-size: 0.9rem;
}
</style>
