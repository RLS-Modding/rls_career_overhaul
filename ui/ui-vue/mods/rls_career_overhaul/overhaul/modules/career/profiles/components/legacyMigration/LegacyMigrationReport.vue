<template>
  <div v-if="blocked" class="lmm-banner lmm-banner--blocked">
    <strong>This save cannot be migrated yet</strong>
    <p>Re-enable the missing content below, or pick an earlier healthy autosave, then re-open this report.</p>
  </div>

  <!-- One panel, not four: aligned stat columns over a footer strip for the
       caveat, sharing the Findings panel's frame so the step reads as two blocks. -->
  <div class="lmm-summary">
    <div class="lmm-stats">
      <div class="lmm-stat">
        <strong>{{ vehicleTotal }}</strong>
        <span>Vehicles<em v-if="vehiclesAtRisk">, {{ vehiclesAtRisk }} at risk</em></span>
      </div>
      <div class="lmm-stat">
        <strong>{{ garageTotal }}</strong>
        <span>Garages<em v-if="garagesAtRisk">, {{ garagesAtRisk }} at risk</em></span>
      </div>
      <div class="lmm-stat">
        <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(totalAssetValue) }}</strong>
        <span>Estimated asset value</span>
      </div>
    </div>

    <p class="lmm-note">
      <strong>Your original save is never changed.</strong>
      Migration writes a separate copy and leaves the source untouched.
      <button type="button" class="lmm-note-toggle" @click="emit('toggle-details')">
        {{ detailsOpen ? "Hide details" : "What could go wrong?" }}
      </button>
    </p>
    <p v-if="detailsOpen" class="lmm-note-more">
      Missing, disabled, outdated, or changed mods may make vehicles, maps, parts, missions, or progression
      unavailable. Migration is best-effort and may reset unsupported data. The first load can take several
      minutes while vehicle and map caches rebuild, and ambient level audio may start before the loading
      screen closes.
    </p>
  </div>

  <!-- One panel with hairline rows, not a stack of floating cards, and the
       severity is stated once per bucket instead of on every single row.
       Repeated codes collapse into a single row with a count. -->
  <section v-if="issueTotal" class="lmm-section">
    <div class="lmm-section-heading">
      <h3>Findings</h3>
      <span class="lmm-count">{{ issueTotal }} total</span>
    </div>

    <div class="lmm-findings">
      <template v-for="bucket in issueBuckets" :key="bucket.severity">
        <div :class="['lmm-bucket', `lmm-bucket--${bucket.severity}`]">
          <span class="lmm-bucket-label">{{ bucket.label }}</span>
          <span class="lmm-bucket-count">{{ bucket.total }}</span>
        </div>

        <article v-for="group in bucket.groups" :key="group.key" class="lmm-finding-row">
          <button
            type="button"
            class="lmm-finding"
            :disabled="group.items.length < 2"
            :aria-expanded="group.items.length > 1 ? expandedKeys.has(group.key) : undefined"
            @click="emit('toggle-group', group.key)">
            <span :class="['lmm-finding-icon', `lmm-finding-icon--${bucket.severity}`]" aria-hidden="true">
              {{ bucket.glyph }}
            </span>
            <span class="lmm-finding-text">
              <strong>{{ group.title }}</strong>
              <span v-if="group.detail" class="lmm-finding-detail">{{ group.detail }}</span>
            </span>
            <span v-if="group.items.length > 1" class="lmm-finding-more">
              {{ expandedKeys.has(group.key) ? "Hide" : "List" }}
              <span :class="['lmm-finding-chevron', { 'is-open': expandedKeys.has(group.key) }]">▾</span>
            </span>
          </button>

          <ul v-if="group.items.length > 1 && expandedKeys.has(group.key)" class="lmm-finding-list">
            <li v-for="(item, i) in group.items" :key="i">
              <span class="lmm-finding-name">{{ item.label }}</span>
              <span v-if="item.extra" class="lmm-finding-extra">{{ item.extra }}</span>
            </li>
          </ul>
        </article>
      </template>
    </div>
  </section>

  <p v-else class="lmm-empty">No compatibility problems were found in this save.</p>
</template>

<script setup>
// Review step of LegacyMigrationModal. Presentation only: the shell owns the counts, the findings buckets, the group
// expansion and the details toggle, and this component renders them. Its two events ask the shell to flip that state.
import { BngIcon, icons } from "@/common/components/base"
import { formatMoney } from "./format.js"

// Counts come straight from the report, so they accept whatever the report holds, as the inline template did.
defineProps({
  vehicleTotal: { type: [Number, String], default: 0 },
  vehiclesAtRisk: { type: [Number, String], default: 0 },
  garageTotal: { type: [Number, String], default: 0 },
  garagesAtRisk: { type: [Number, String], default: 0 },
  totalAssetValue: { type: Number, default: 0 },
  blocked: Boolean,
  issueTotal: { type: Number, default: 0 },
  issueBuckets: { type: Array, default: () => [] },
  expandedKeys: { type: Set, default: () => new Set() },
  detailsOpen: Boolean,
})

const emit = defineEmits(["toggle-details", "toggle-group"])
</script>

<style lang="scss" scoped>
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/legacyMigration/tokens" as *;
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/legacyMigration/skin" as *;

@include lmm-section;
@include lmm-section-heading;
@include lmm-count;
@include lmm-summary-panel;
@include lmm-currency;

.lmm-banner {
  padding: 0.75em 0.9em;
  border-radius: 10px;
  border-left: 3px solid $danger;
  background: rgba(240, 71, 71, 0.12);

  strong { display: block; }
  p { margin: 0.2em 0 0; color: rgba(255, 255, 255, 0.7); font-size: 0.85em; line-height: 1.4; }
}

.lmm-note {
  margin: 0;
  padding: 0.6em 0.9em;
  border-top: 1px solid rgba(71, 85, 105, 0.28);
  background: rgba(2, 5, 12, 0.4);
  color: rgba(255, 255, 255, 0.58);
  font-size: 0.79em;
  line-height: 1.45;

  strong { color: #fff; }
}

.lmm-note-toggle {
  padding: 0;
  border: 0;
  background: none;
  color: $accent;
  font-family: inherit;
  font-size: 1em;
  font-weight: 700;
  white-space: nowrap;
  cursor: pointer;

  &:hover { text-decoration: underline; }
}

.lmm-note-more {
  margin: 0;
  padding: 0 0.9em 0.7em;
  background: rgba(2, 5, 12, 0.4);
  color: rgba(255, 255, 255, 0.48);
  font-size: 0.77em;
  line-height: 1.5;
}

/* ── Findings ───────────────────────────────────────────────────────── */

.lmm-findings {
  border: 1px solid rgba(71, 85, 105, 0.35);
  border-radius: 10px;
  background: rgba(15, 23, 42, 0.4);
  overflow: hidden;
}

.lmm-bucket {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.45em 0.8em;
  background: rgba(2, 5, 12, 0.5);
  border-top: 1px solid rgba(71, 85, 105, 0.3);
  font-size: 0.66em;
  font-weight: 900;
  letter-spacing: 0.1em;
  text-transform: uppercase;

  &:first-child { border-top: 0; }
}
.lmm-bucket--blocker { color: $danger; }
.lmm-bucket--action { color: $risk; }
.lmm-bucket--warning { color: #facc15; }

.lmm-bucket-label { flex: 1 1 auto; }

.lmm-bucket-count {
  padding: 0.1em 0.5em;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.75);
  letter-spacing: 0;
}

.lmm-finding-row {
  border-top: 1px solid rgba(71, 85, 105, 0.22);
}

.lmm-finding {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: start;
  gap: 0.7em;
  width: 100%;
  padding: 0.6em 0.8em;
  border: 0;
  background: none;
  color: inherit;
  font-family: inherit;
  font-size: 1em;
  text-align: left;
  cursor: pointer;

  &:disabled { cursor: default; }
  &:not(:disabled):hover { background: rgba(255, 255, 255, 0.045); }
}

.lmm-finding-icon {
  display: grid;
  place-items: center;
  width: 1.5em;
  height: 1.5em;
  margin-top: 0.05em;
  border-radius: 6px;
  font-size: 0.8em;
  font-weight: 900;
  line-height: 1;
}
.lmm-finding-icon--blocker { color: $danger; background: rgba(240, 71, 71, 0.18); }
.lmm-finding-icon--action { color: $risk; background: rgba(251, 146, 60, 0.18); }
.lmm-finding-icon--warning { color: #facc15; background: rgba(250, 204, 21, 0.16); }

.lmm-finding-text {
  display: flex;
  flex-direction: column;
  gap: 0.1em;
  min-width: 0;

  strong { font-size: 0.88em; font-weight: 700; }
}

.lmm-finding-detail {
  color: rgba(255, 255, 255, 0.52);
  font-size: 0.76em;
  line-height: 1.4;
}

.lmm-finding-more {
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  margin-top: 0.1em;
  color: $accent;
  font-size: 0.72em;
  font-weight: 700;
  white-space: nowrap;
}

.lmm-finding-chevron {
  transition: transform 0.15s ease;

  &.is-open { transform: rotate(180deg); }
}

/* Names only, in columns — the headline above already carries the reason. */
.lmm-finding-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(11em, 1fr));
  gap: 0.1em 1.2em;
  margin: 0;
  padding: 0 0.8em 0.6em 3em;
  list-style: none;

  li {
    display: flex;
    flex-direction: column;
    font-size: 0.78em;
    line-height: 1.4;
  }
}

.lmm-finding-name {
  color: rgba(255, 255, 255, 0.78);
}

.lmm-finding-extra {
  padding-left: 0.9em;
  color: rgba(255, 255, 255, 0.42);
  font-size: 0.92em;
}

.lmm-empty {
  margin: 1.2em 0;
  padding: 1em;
  border: 1px dashed rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  color: $muted;
  text-align: center;
  font-size: 0.88em;
}
</style>
