<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Line icons for the Fuel & Ignition panel. Inline SVG rather than BngIcon: BngIcon draws a
     font glyph, which becomes part of the button's text and breaks exact-label clicks in tests. -->
<template>
  <svg class="fuel-ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <path v-for="(d, i) in paths" :key="i" :d="d" />
  </svg>
</template>

<script setup>
import { computed } from "vue"

const props = defineProps({ name: { type: String, required: true } })

// 24×24 strokes, round caps; circles are written as two arcs.
const ICONS = {
  sliders: ["M4 7h9", "M17 7h3", "M4 17h3", "M11 17h9", "M15 5v4", "M9 15v4"],
  grid: ["M4 5h16v14H4z", "M4 10h16", "M4 14.5h16", "M9.5 5v14", "M14.5 5v14"],
  wrench: ["M14.5 4.5a4.5 4.5 0 0 0-4.2 6.1L4.5 16.4a1.6 1.6 0 0 0 2.3 2.3l5.8-5.8a4.5 4.5 0 0 0 6.1-4.2l-2.6 2.6-2.4-.6-.6-2.4z"],
  tank: ["M6 8h12v11a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1z", "M9 8V5h6v3", "M9 13.5c1 .9 2 .9 3 0s2-.9 3 0"],
  droplet: ["M12 3.5c3 3.8 5.5 7 5.5 10.2a5.5 5.5 0 0 1-11 0C6.5 10.5 9 7.3 12 3.5z"],
  spark: ["M13 3 6 13.5h5L10 21l7-10.5h-5z"],
  turbo: ["M12 12m-8 0a8 8 0 1 0 16 0a8 8 0 1 0-16 0", "M12 12m-2 0a2 2 0 1 0 4 0a2 2 0 1 0-4 0", "M12 4c-1 2.5-.5 4.5 0 6", "M19.5 14c-2.5-.5-4.5 0-6 .8", "M5.6 17c1.8-1.8 3.6-2.6 5-2.9"],
  gauge: ["M4.5 16a7.5 7.5 0 1 1 15 0", "M12 16l3.5-4.5", "M4.5 16h2", "M17.5 16h2"],
  engine: ["M7 9h3l1.5-2h3L16 9h2v3h2v3h-2v3h-3l-1.5 1.5h-5L7 18H5v-3H3v-3h2V9z"],
  pump: ["M5 20V5.5A1.5 1.5 0 0 1 6.5 4h6A1.5 1.5 0 0 1 14 5.5V20", "M3.5 20h12", "M5 10h9", "M14 8.5l3 2.5v6a1.5 1.5 0 0 0 3 0V9l-2.5-2.5"],
  flame: ["M12 3.5c.6 3 4.5 5 4.5 9.7a4.5 4.5 0 0 1-9 0c0-2.4 1.2-3.7 2-5.2.6 1.2 1.2 2 2 2.6.3-2.2.1-4.6.5-7.1z"],
  bottle: ["M10 3h4", "M10.5 3v3h3V3", "M8 10a4 4 0 0 1 8 0v9.5a1.5 1.5 0 0 1-1.5 1.5h-5A1.5 1.5 0 0 1 8 19.5z", "M8 13h8"],
  chart: ["M4 4v16h16", "M7.5 15l3.5-4.5 3 2.5 5-6.5"],
  palette: ["M12 3.5a8.5 8.5 0 1 0 0 17c1.2 0 1.6-.8 1.6-1.6 0-1.1-.9-1.4-.9-2.4s.8-1.5 1.7-1.5h2.2a3.9 3.9 0 0 0 3.9-3.9C20.5 7 16.7 3.5 12 3.5z", "M8 10.5h.01", "M11 7.5h.01", "M15.5 8.5h.01"],
  pulse: ["M3 12h4l2.5-6 5 12 2.5-6h4"],
  warn: ["M10.3 4.9a2 2 0 0 1 3.4 0l7 12.1a2 2 0 0 1-1.7 3H5a2 2 0 0 1-1.7-3z", "M12 9.5v4", "M12 16.8h.01"],
}

const paths = computed(() => ICONS[props.name] || [])
</script>

<style scoped>
.fuel-ico {
  width: 1.15em;
  height: 1.15em;
  flex: 0 0 auto;
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
  vertical-align: -0.2em;
}
</style>
