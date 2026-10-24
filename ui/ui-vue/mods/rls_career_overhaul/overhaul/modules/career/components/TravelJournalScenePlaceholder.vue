<template>
  <!-- Stands in for a location's cover photo until it has one. Sized by its photo frame; text scales with the
       parent's font-size, so the journal and the phone app each set their own. -->
  <span class="scene-placeholder" :class="normalizedStatus">
    <svg class="scene-sketch" viewBox="0 0 120 80" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
      <circle cx="86" cy="26" r="9" />
      <path class="far-hills" d="M0 58 L18 40 L32 50 L52 28 L72 48 L84 40 L104 54 L120 44 V80 H0 Z" />
      <path class="near-hills" d="M0 70 Q22 54 44 64 T88 60 T120 62 V80 H0 Z" />
    </svg>
    <span class="scene-badge" aria-hidden="true">
      <svg v-if="normalizedStatus === 'notFound'" viewBox="0 0 24 24"><path d="M7 10V7a5 5 0 0 1 10 0v3" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" /><rect x="4.5" y="10" width="15" height="11" rx="2" fill="currentColor" /></svg>
      <svg v-else-if="normalizedStatus === 'discovered'" viewBox="0 0 24 24"><path d="M3 8.5h4l1.6-2.5h6.8L17 8.5h4V19H3Z" fill="currentColor" /><circle cx="12" cy="13.5" r="3.4" fill="none" stroke="#fffaf0" stroke-width="1.8" /></svg>
      <svg v-else viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </span>
    <span class="scene-caption">{{ caption }}</span>
  </span>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  // location status from overhaul_phone_travelJournal: notFound | discovered | completed
  status: { type: String, default: 'notFound' },
})

const CAPTIONS = { notFound: 'Not found yet', discovered: 'Photo needed', completed: 'Memory preserved' }
const normalizedStatus = computed(() => Object.prototype.hasOwnProperty.call(CAPTIONS, props.status) ? props.status : 'notFound')
const caption = computed(() => CAPTIONS[normalizedStatus.value])
</script>

<style scoped lang="scss">
$ink: #342a25; $green: #55735b; $gold: #a47738;

.scene-placeholder {
  position: relative;
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.35em;
  overflow: hidden;
  color: $ink;
  background: repeating-linear-gradient(45deg, #e3dbc9, #e3dbc9 8px, #eee6d8 8px, #eee6d8 16px);
}

.scene-sketch { position: absolute; inset: 0; width: 100%; height: 100%; }
.scene-sketch circle { fill: rgba(255, 250, 240, 0.55); }
.scene-sketch .far-hills { fill: rgba(70, 56, 46, 0.16); }
.scene-sketch .near-hills { fill: rgba(70, 56, 46, 0.24); }

.scene-badge {
  position: relative;
  width: 2.6em;
  height: 2.6em;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  background: rgba(255, 250, 240, 0.92);
  box-shadow: 0 1px 4px rgba(38, 28, 21, 0.25);
}
.scene-badge svg { width: 1.35em; height: 1.35em; }

.scene-caption {
  position: relative;
  padding: 0.2em 0.6em;
  border-radius: 0.25em;
  color: #fffaf0;
  background: rgba(52, 42, 37, 0.78);
  font: 700 1em/1.2 Arial, sans-serif;
  letter-spacing: 0.04em;
  white-space: nowrap;
}

// not found: a darkened, unexposed print with a lock
.notFound { background: linear-gradient(180deg, #b9ae9f, #9c9082); }
.notFound .scene-sketch circle { fill: rgba(255, 250, 240, 0.3); }
.notFound .scene-sketch .far-hills { fill: rgba(52, 42, 37, 0.22); }
.notFound .scene-sketch .near-hills { fill: rgba(52, 42, 37, 0.34); }
.notFound .scene-badge { color: $ink; }

.discovered .scene-badge { color: $gold; }
.completed .scene-badge { color: $green; }
.completed .scene-caption { background: $green; }
</style>
