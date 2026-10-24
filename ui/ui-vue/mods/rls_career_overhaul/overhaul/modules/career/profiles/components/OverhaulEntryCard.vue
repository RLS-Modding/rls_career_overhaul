<!-- Entry map: one first-career button or two stock-scope nav buttons, progressive profile events, existing load path, panel skin. -->
<template>
  <!-- No Overhaul save yet: the whole bar is one invitation that starts a new career. -->
  <button v-if="view.state === 'empty'" type="button" class="overhaul-entry overhaul-entry-first" bng-nav-item tabindex="0"
    v-bng-on-ui-nav:ok.asMouse aria-label="Start a new RLS Career Overhaul career" @click="continueCareer">
    <span class="overhaul-entry-first-copy">
      <span class="overhaul-entry-eyebrow">RLS Career Overhaul</span>
      <strong class="overhaul-entry-first-title">{{ view.title }}</strong>
      <span class="overhaul-entry-features">
        <span v-for="feature in FIRST_CAREER_FEATURES" :key="feature.id" class="overhaul-entry-feature">
          <BngIcon v-if="icons[feature.icon]" :type="icons[feature.icon]" />
          <span>{{ feature.label }}</span>
        </span>
      </span>
    </span>
    <span class="overhaul-entry-resume overhaul-entry-first-cta" aria-hidden="true">
      <svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14" /></svg>
      <span>{{ view.action }}</span>
    </span>
  </button>
  <section v-else class="overhaul-entry" aria-label="RLS Career Overhaul">
    <button type="button" class="overhaul-entry-open" bng-nav-item tabindex="0" v-bng-on-ui-nav:ok.asMouse @click="openProfiles">
      <span class="overhaul-entry-copy">
        <strong>RLS Career Overhaul</strong>
        <small>View your saves</small>
      </span>
      <svg class="overhaul-entry-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5.5 15.5 12 9 18.5" /></svg>
    </button>
    <div class="overhaul-entry-continue" :aria-busy="view.state === 'loading' || busy">
      <div class="overhaul-entry-save" aria-live="polite">
        <template v-if="view.state === 'loading'">
          <span class="overhaul-entry-placeholder overhaul-entry-name" />
          <span class="overhaul-entry-stats">
            <span v-for="n in 2" :key="n" class="overhaul-entry-placeholder overhaul-entry-stat" />
          </span>
          <span class="overhaul-entry-sr">{{ view.title }}</span>
        </template>
        <template v-else>
          <span class="overhaul-entry-heading">
            <strong class="overhaul-entry-name" :title="view.title">{{ view.title }}</strong>
            <span v-if="mapLabel" class="overhaul-entry-map">{{ mapLabel }}</span>
          </span>
          <span v-if="view.profile?.pending" class="overhaul-entry-stats">
            <span v-for="n in 2" :key="n" class="overhaul-entry-placeholder overhaul-entry-stat" />
          </span>
          <template v-else-if="view.profile && !error">
            <dl class="overhaul-entry-stats">
              <div v-for="stat in detailStats" :key="stat.key" class="overhaul-entry-stat">
                <dt>{{ stat.label }}</dt>
                <dd>{{ stat.value }}</dd>
              </div>
            </dl>
          </template>
          <small v-else class="overhaul-entry-hint">{{ error || view.hint }}</small>
        </template>
      </div>
      <ul v-if="showSkills" class="overhaul-entry-skills" aria-label="Top skills">
        <li v-for="skill in skills" :key="skill.id" class="overhaul-entry-skill" :title="`${skill.label} level ${skill.level}`">
          <BngIcon v-if="icons[skill.icon]" class="overhaul-entry-skill-icon" :type="icons[skill.icon]" />
          <span v-else class="overhaul-entry-skill-icon" />
          <span class="overhaul-entry-skill-name">{{ skill.label }}</span>
          <span class="overhaul-entry-skill-bar"><span :style="{ transform: `scaleX(${skill.progress})` }" /></span>
          <span class="overhaul-entry-skill-level">{{ skill.level }}</span>
        </li>
      </ul>
      <div class="overhaul-entry-side">
        <span v-if="money" class="overhaul-entry-money" :title="`Money: ${money.value}`">{{ money.value }}</span>
        <span v-else-if="view.state === 'loading' || view.profile?.pending" class="overhaul-entry-placeholder overhaul-entry-money-placeholder" />
      <button type="button" class="overhaul-entry-resume" bng-nav-item tabindex="0" v-bng-on-ui-nav:ok.asMouse
        :disabled="view.state === 'loading' || busy" @click="continueCareer">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.8v12.4c0 .8.9 1.3 1.6.9l9.6-6.2c.6-.4.6-1.4 0-1.8L9.6 4.9C8.9 4.5 8 5 8 5.8Z" /></svg>
        <span>{{ busy ? "Loading…" : view.action }}</span>
      </button>
      </div>
    </div>
  </section>
</template>

<script setup>
import { computed, onMounted, onBeforeUnmount, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { vBngOnUiNav } from "@/common/directives"
import { useProfilesStore } from "../../stores/profilesStore"
import "../../utils/installLuaBridgeFallbacks"
import { reportUiFailure } from "../../utils/safeLua"
import { entryCardState, FIRST_CAREER_FEATURES, profileStats, topSkills } from "./entryCardState.js"
import { useRoutePrewarm } from "../../composables/useRoutePrewarm"
import { SysInfo } from "@/services"

// These overlays share the mounted main-menu grid and its idle prewarm.
useRoutePrewarm("overhaul.profiles", () =>
  ["menu", "menu.others", "menu.discover"].includes(window.vueRouter?.currentRoute.value.name) && !SysInfo.gameState.value)

const { events } = useBridge()
const store = useProfilesStore()
const profiles = ref([])
const ready = ref(false)
const error = ref("")
const busy = ref(false)
const view = computed(() => entryCardState(profiles.value, ready.value, error.value))
const stats = computed(() => profileStats(view.value.profile))
const money = computed(() => view.value.state === "ready" && !view.value.profile?.pending && !error.value ? stats.value.find(stat => stat.key === "money") : null)
const detailStats = computed(() => stats.value.filter(stat => stat.key !== "money"))
const skills = computed(() => topSkills(view.value.profile))
const showSkills = computed(() => view.value.state === "ready" && !view.value.profile?.pending && !error.value && skills.value.length > 0)
const mapLabel = computed(() => view.value.profile?.levelLabel || view.value.profile?.level?.replaceAll("_", " ") || "")
let generation = null
let disposed = false

function onList(reply) {
  generation = reply.generation
  profiles.value = Object.values(reply.profiles || {})
  ready.value = true
  error.value = ""
}

function onBatch(reply) {
  if (reply.generation !== generation) return
  const updates = new Map(Object.values(reply.profiles || {}).map(profile => [profile.id, profile]))
  profiles.value = profiles.value.map(profile => updates.get(profile.id) || profile)
}

function onFailure(reason) {
  error.value = "Open Overhaul profiles to try again"
  ready.value = true
  reportUiFailure(reason, "Entry card profiles unavailable")
}

const listeners = { OverhaulEntryProfilesList: onList, OverhaulEntryProfilesBatch: onBatch, OverhaulEntryProfilesFailed: onFailure }
const navigate = route => lua.extensions.ui_router.navigate(route, null, null)
const openProfiles = () => navigate("overhaul.profiles")

async function continueCareer() {
  if (busy.value || view.value.state === "loading") return
  // No Overhaul save yet: the save list still shows any old RLS saves to import, and opens its create card when there are none.
  if (view.value.state === "empty") return openProfiles()
  if (view.value.state === "error") return openProfiles()
  busy.value = true
  try {
    const id = view.value.profile.id
    const report = await lua.overhaul_career_career.getLegacySavePreflight(id, null)
    if (disposed) return
    // Migration choices belong to the existing profile screen, before any career is loaded.
    if (report?.requiresMigration) return await openProfiles()
    if (await store.loadExistingProfile(id) === false && !disposed) onFailure("Career did not start")
  } catch (reason) {
    if (!disposed) onFailure(reason)
  } finally {
    busy.value = false
  }
}

onMounted(async () => {
  for (const [event, listener] of Object.entries(listeners)) events.on(event, listener)
  try {
    await lua.overhaul_career_career.sendEntryCardProfilesDataAsync()
  } catch (reason) {
    if (!disposed) onFailure(reason)
  }
})

onBeforeUnmount(() => {
  disposed = true
  for (const [event, listener] of Object.entries(listeners)) events.off(event, listener)
})
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
.overhaul-entry {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr);
  min-height: calc-ui-rem(8.25);
  border: 1px solid rgba(var(--bng-off-white-rgb), 0.14);
  border-radius: var(--bng-corners-2);
  background: rgba(22, 23, 27, 0.94);
  color: var(--bng-off-white);
  overflow: hidden;
}
button { font: inherit; color: inherit; cursor: pointer; border: 0; }
// Only keyboard and controller focus draws a ring (stock nav adds .focus-visible); a mouse click leaves none.
button:focus { outline: none; }
button.focus-visible, button.focus-visible { outline: 2px solid rgba(var(--bng-off-white-rgb), 0.8); outline-offset: -2px; }
button:disabled { cursor: default; opacity: 0.55; }
.overhaul-entry-open, .overhaul-entry-continue { display: flex; align-items: center; gap: calc-ui-rem(1.25); padding: calc-ui-rem(1) calc-ui-rem(1.5); min-width: 0; }
.overhaul-entry-open {
  position: relative; isolation: isolate; text-align: left;
  // Dark on the left so the title reads over the photo; the truck and trailer stay clear on the right.
  background:
    linear-gradient(90deg, rgba(22, 23, 27, 0.96) 0%, rgba(22, 23, 27, 0.8) 38%, rgba(22, 23, 27, 0.2) 100%),
    url("/ui/ui-vue/mods/rls_career_overhaul/overhaul/assets/entryCardHauler.jpg") 58% 50% / cover no-repeat;
  &::after { content: ""; position: absolute; inset: 0; z-index: -1; background: rgba(var(--bng-off-white-rgb), 0.06); opacity: 0; transition: opacity 140ms ease-out; }
  &:hover::after, &.focus-visible::after { opacity: 1; }
  > * { position: relative; z-index: 1; }
}
.overhaul-entry-copy, .overhaul-entry-save { display: flex; flex-direction: column; min-width: 0; }
.overhaul-entry-copy { gap: calc-ui-rem(0.3); }
.overhaul-entry-copy strong { font-size: calc-ui-rem(1.55); letter-spacing: -0.01em; }
.overhaul-entry-copy small { font-size: calc-ui-rem(0.95); color: rgba(var(--bng-off-white-rgb), 0.78); }
.overhaul-entry-hint { font-size: calc-ui-rem(0.95); color: rgba(var(--bng-off-white-rgb), 0.62); }
.overhaul-entry-chevron {
  flex: 0 0 auto; margin-left: auto; width: calc-ui-rem(1.6); height: calc-ui-rem(1.6);
  fill: none; stroke: rgba(var(--bng-off-white-rgb), 0.85); stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round;
  transition: transform 160ms ease-out, stroke 160ms ease-out;
}
.overhaul-entry-open:hover .overhaul-entry-chevron, .overhaul-entry-open.focus-visible .overhaul-entry-chevron { transform: translateX(calc-ui-rem(0.2)); stroke: var(--bng-off-white); }
.overhaul-entry-continue { align-items: stretch; border-left: 1px solid rgba(var(--bng-off-white-rgb), 0.08); }
.overhaul-entry-save { flex: 1; justify-content: center; gap: calc-ui-rem(0.6); }
.overhaul-entry-heading { display: flex; flex-direction: column; align-items: flex-start; gap: calc-ui-rem(0.35); min-width: 0; }
.overhaul-entry-name { max-width: 100%; height: calc-ui-rem(1.45); line-height: calc-ui-rem(1.45); font-size: calc-ui-rem(1.2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.overhaul-entry-map {
  flex: 0 0 auto; padding: calc-ui-rem(0.1) calc-ui-rem(0.55); border-radius: calc-ui-rem(1);
  background: rgba(var(--bng-off-white-rgb), 0.08); color: rgba(var(--bng-off-white-rgb), 0.72); font-size: calc-ui-rem(0.8);
}
.overhaul-entry-stats { display: flex; align-items: baseline; gap: calc-ui-rem(1.1); margin: 0; }
.overhaul-entry-stat {
  display: flex; align-items: baseline; gap: calc-ui-rem(0.35); white-space: nowrap;
  dt { font-size: calc-ui-rem(0.75); color: rgba(var(--bng-off-white-rgb), 0.48); }
  dd { margin: 0; font-size: calc-ui-rem(0.85); font-weight: 600; color: rgba(var(--bng-off-white-rgb), 0.85); font-variant-numeric: tabular-nums; }
}
.overhaul-entry-skills {
  display: flex; flex-direction: column; justify-content: center; gap: calc-ui-rem(0.4); flex: 0 0 auto;
  margin: 0; padding: 0 calc-ui-rem(1.1); list-style: none;
  border-left: 1px solid rgba(var(--bng-off-white-rgb), 0.08); border-right: 1px solid rgba(var(--bng-off-white-rgb), 0.08);
}
.overhaul-entry-skill {
  display: grid; grid-template-columns: calc-ui-rem(1) calc-ui-rem(5) calc-ui-rem(3.25) calc-ui-rem(1.5); align-items: center;
  column-gap: calc-ui-rem(0.5); font-size: calc-ui-rem(0.75); white-space: nowrap;
}
.overhaul-entry-skill-icon { font-size: calc-ui-rem(0.95); color: #ffa45c; }
.overhaul-entry-skill-name { color: rgba(var(--bng-off-white-rgb), 0.7); overflow: hidden; text-overflow: ellipsis; }
.overhaul-entry-skill-level { text-align: right; font-weight: 700; color: #ffc08a; font-variant-numeric: tabular-nums; }
.overhaul-entry-skill-bar {
  height: calc-ui-rem(0.2); border-radius: calc-ui-rem(0.1); overflow: hidden; background: rgba(var(--bng-off-white-rgb), 0.08);
  span { display: block; height: 100%; background: linear-gradient(90deg, #ff7a1a, #ffb06b); transform-origin: left center; }
}
// Stock New and Saves panels need the skills below the profile, with Resume
// in its own column. The name can then truncate without overlapping either.
@container (max-width: 75rem) {
  .overhaul-entry-continue {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: calc-ui-rem(0.6) calc-ui-rem(1);
  }
  .overhaul-entry-save { grid-column: 1; grid-row: 1; }
  .overhaul-entry-stats { flex-wrap: wrap; }
  .overhaul-entry-side { grid-column: 2; grid-row: 1 / span 2; }
  .overhaul-entry-skills {
    grid-column: 1; grid-row: 2;
    padding: calc-ui-rem(0.4) 0 0;
    border: 0;
    border-top: 1px solid rgba(var(--bng-off-white-rgb), 0.08);
  }
  .overhaul-entry-skill {
    grid-template-columns: calc-ui-rem(1) minmax(0, 1fr) calc-ui-rem(3.25) calc-ui-rem(1.5);
  }
}
// At smaller widths, the fixed skill tracks need the full details column.
@container (max-width: 40rem) {
  .overhaul-entry-continue { grid-template-columns: minmax(0, 1fr); }
  .overhaul-entry-side { grid-column: 1; grid-row: 3; }
}
.overhaul-entry-side { display: flex; flex-direction: column; align-items: flex-end; justify-content: flex-end; gap: calc-ui-rem(0.6); flex: 0 0 auto; }
.overhaul-entry-money, .overhaul-entry-money-placeholder { margin-bottom: auto; }
.overhaul-entry-money { font-size: calc-ui-rem(1.3); line-height: 1; font-weight: 700; letter-spacing: -0.01em; color: #fde68a; font-variant-numeric: tabular-nums; }
.overhaul-entry-money-placeholder { width: calc-ui-rem(5); height: calc-ui-rem(1.3); }
.overhaul-entry-resume {
  display: inline-flex; align-items: center; justify-content: center; gap: calc-ui-rem(0.45); flex: 0 0 auto;
  min-width: calc-ui-rem(7); min-height: calc-ui-rem(2.8); padding: 0 calc-ui-rem(1.1); border-radius: calc-ui-rem(1.4);
  border: 1px solid rgba(255, 138, 51, 0.55); background: rgba(255, 122, 26, 0.14); color: #ffb27a; font-weight: 700;
  transition: background-color 140ms ease-out, color 140ms ease-out, transform 100ms ease-out;
  svg { width: calc-ui-rem(1); height: calc-ui-rem(1); fill: currentColor; }
}
.overhaul-entry-resume:hover:not(:disabled), .overhaul-entry-resume.focus-visible { background: #ff7a1a; color: #16171b; }
.overhaul-entry-resume:active:not(:disabled) { transform: scale(0.97); }
.overhaul-entry-placeholder { border-radius: calc-ui-rem(0.45); background: rgba(var(--bng-off-white-rgb), 0.08); }
.overhaul-entry-placeholder.overhaul-entry-name { width: 55%; }
.overhaul-entry-placeholder.overhaul-entry-stat { width: calc-ui-rem(5.5); height: calc-ui-rem(0.9); }
.overhaul-entry-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
// First career: one button across the whole bar, photo behind, a filled call to action on the right.
.overhaul-entry-first {
  display: flex; align-items: center; justify-content: space-between; gap: calc-ui-rem(1.5); width: 100%;
  padding: calc-ui-rem(1.1) calc-ui-rem(1.75); text-align: left; position: relative; isolation: isolate;
  background:
    radial-gradient(60% 140% at 100% 100%, rgba(255, 122, 26, 0.22), transparent 70%),
    linear-gradient(90deg, rgba(22, 23, 27, 0.97) 0%, rgba(22, 23, 27, 0.82) 38%, rgba(22, 23, 27, 0.3) 62%, rgba(22, 23, 27, 0.88) 100%),
    url("/ui/ui-vue/mods/rls_career_overhaul/overhaul/assets/entryCardHauler.jpg") center / cover no-repeat;
  &::after { content: ""; position: absolute; inset: 0; z-index: -1; background: rgba(var(--bng-off-white-rgb), 0.05); opacity: 0; transition: opacity 140ms ease-out; }
  &:hover::after, &.focus-visible::after { opacity: 1; }
  &:hover .overhaul-entry-first-cta, &.focus-visible .overhaul-entry-first-cta { background: linear-gradient(180deg, #ffa05c, #ff7a1a); }
  &:active .overhaul-entry-first-cta { transform: scale(0.97); }
}
.overhaul-entry-first-copy { display: flex; flex-direction: column; gap: calc-ui-rem(0.45); min-width: 0; }
.overhaul-entry-eyebrow { font-size: calc-ui-rem(0.7); font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; color: #ffa45c; }
.overhaul-entry-first-title { font-size: calc-ui-rem(1.55); line-height: 1.15; letter-spacing: -0.01em; }
.overhaul-entry-first-cta {
  min-height: calc-ui-rem(3); padding: 0 calc-ui-rem(1.4); border-color: transparent; background: linear-gradient(180deg, #ff8a33, #f2650f); color: #16171b;
  svg { fill: none; stroke: currentColor; stroke-width: 2.6; stroke-linecap: round; }
}
.overhaul-entry-features {
  display: flex; flex-wrap: wrap; column-gap: calc-ui-rem(1.4); row-gap: calc-ui-rem(0.2); margin-top: calc-ui-rem(0.35);
}
.overhaul-entry-feature {
  display: inline-flex; align-items: center; gap: calc-ui-rem(0.35); font-size: calc-ui-rem(0.8); color: rgba(var(--bng-off-white-rgb), 0.8);
  :deep(.icon-base) { font-size: calc-ui-rem(0.95); color: #ffa45c; }
}
@media (prefers-reduced-motion: reduce) { .overhaul-entry-chevron, .overhaul-entry-resume { transition: none; } }
</style>
