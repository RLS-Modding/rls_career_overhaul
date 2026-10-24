<!-- Shared waiting indicator exported by house/index.js; callers supply a localized label.
     Mount only while data is pending. This component owns visibility pause and reduced motion. -->
<template>
  <div class="house-loader" role="status" aria-live="polite">
    <span class="house-loader__mark" :class="{ 'is-paused': hidden }" aria-hidden="true">
      <span class="house-loader__beams">
        <template v-for="i in 5" :key="i">
          <span class="house-loader__spoke" :style="{ '--angle': `${-90 + (i - 1) * 72}deg`, '--start': `${((i - 1) * 0.21 + 0) / 2.4 * 100}%`, '--end': `${((i - 1) * 0.21 + 0) / 2.4 * 100 + 8}%` }" />
          <span class="house-loader__rim" :style="{ '--angle': `${-90 + (i - 1) * 72}deg`, '--start': `${((i - 1) * 0.21 + 0.096) / 2.4 * 100}%`, '--end': `${((i - 1) * 0.21 + 0.096) / 2.4 * 100 + 8}%` }" />
        </template>
      </span>
      <span class="house-loader__hub" />
      <span v-for="i in 5" :key="i" class="house-loader__node" :style="{ '--angle': `${-90 + (i - 1) * 72}deg` }" />
    </span>
    <span class="house-loader__label">{{ label }}</span>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from "vue"

defineProps({ label: { type: String, default: "Loading…" } })
const hidden = ref(document.hidden)
const syncVisibility = () => { hidden.value = document.hidden }
onMounted(() => document.addEventListener("visibilitychange", syncVisibility))
onBeforeUnmount(() => document.removeEventListener("visibilitychange", syncVisibility))
</script>

<style scoped>
.house-loader {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.85em;
  padding: 2em 1em;
  color: var(--bng-off-white, #ebebeb);
  text-align: center;
}
.house-loader__mark {
  --radius: 1.625em;
  position: relative;
  display: block;
  width: 4em;
  height: 4em;
  color: var(--accent, var(--bng-orange-b400, #ff6600));
  contain: layout paint;
}
.house-loader__beams {
  position: absolute;
  inset: 0;
  animation: house-loader-fade 2.4s linear infinite;
}
.house-loader__hub,
.house-loader__node,
.house-loader__spoke,
.house-loader__rim {
  position: absolute;
  left: 50%;
  top: 50%;
  background: currentColor;
}
.house-loader__hub,
.house-loader__node { border-radius: 50%; }
.house-loader__hub {
  width: 0.625em;
  height: 0.625em;
  margin: -0.3125em;
}
.house-loader__node {
  width: 0.4375em;
  height: 0.4375em;
  margin: -0.21875em;
  transform: rotate(var(--angle)) translateX(var(--radius));
}
.house-loader__spoke,
.house-loader__rim {
  width: var(--radius);
  height: 0.125em;
  margin-top: -0.0625em;
  transform-origin: 0 50%;
  animation: house-loader-build 2.4s infinite;
  animation-timing-function: linear(0 0%, 0 var(--start), 1 var(--end), 1 100%);
}
.house-loader__spoke { --beam-start: rotate(var(--angle)); }
.house-loader__rim {
  /* Five-node chord: 2R sin(pi/5); local angle: 90deg + 36deg. */
  width: calc(var(--radius) * 1.175570505);
  --beam-start: rotate(var(--angle)) translateX(var(--radius)) rotate(126deg);
}
.house-loader__label { font-size: 0.9em; line-height: 1.4; }
.is-paused .house-loader__beams,
.is-paused .house-loader__spoke,
.is-paused .house-loader__rim { animation-play-state: paused; }
@keyframes house-loader-build {
  from { transform: var(--beam-start) scaleX(0); }
  to { transform: var(--beam-start) scaleX(1); }
}
@keyframes house-loader-fade {
  0%, 70% { opacity: 0.85; }
  85%, 100% { opacity: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .house-loader__beams,
  .house-loader__spoke,
  .house-loader__rim { animation: none; }
  .house-loader__beams { opacity: 0.85; }
  .house-loader__spoke,
  .house-loader__rim { transform: var(--beam-start) scaleX(1); }
}
</style>
