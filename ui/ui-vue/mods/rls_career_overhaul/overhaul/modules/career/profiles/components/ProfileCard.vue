<!--
  ProfileCard: one save in the profile strip, drawn as a small card or as the featured hero.

  Ownership
    This file owns the frame (picture, header, drawer, hover and snap), the one view state
    (which body is open, by priority), the scope and ui-nav handling, the switch rows and the
    status buttons. Everything the user can do to a save is started here.

  Parts (profileCard/)
    ProfileStatusPanel.vue  the status view: money line, hero tiles, skills, recent money.
                            Receives figures as props; the card's switch rows and buttons are
                            its default slot, so they stay in this file's template.
    ProfileManagePanel.vue  the manage menu, rename form and delete confirmation. Its focus
                            policy lives there; the card owns rename state and the Lua writes.
    useProfileBackup.js     backup state and the save, poll, copy sequence.
    menuItems.js            the sub-view ids the card and the manage panel share.
    The backup name step, the loading spinner and the success line, and the save list, are drawn by
    this file's template (the card fetches the folders).
    (style block)           the card's own visual skin, then the buttons and section chrome shared by the card and every panel.

  Reading order
    1. props and emits          4. drawer, hover and snap       7. switches (Lua writes)
    2. view state               5. view priority (activeView)   8. template
    3. saves and rename         6. scope, back and backup wiring

  Contract
    - View priority, first match wins: backup > saves > manage > status. activeView sets the
      drawer's height key from the same order, so the two cannot disagree.
    - The status and manage panels receive state as props and report back with semantic events. They
      never emit to the outside world; the card maps their events to the emits below.
    - Emits to the strip: card:activate and manage:change (the scope the card holds), backup:change,
      load (a profile id) and saves:load (id, save name).
    - Rename text is seeded once, when the card mounts, not when rename opens.
-->
<template>
  <div
    v-bng-scoped-nav="{ canDeactivate, canBubbleEvent }"
    v-bng-sound-class="'bng_hover_generic'"
    :class="['pc', { 'pc--active': active, 'pc--outdated': incompatibleVersion, 'pc--manage': isManage, 'pc--hover': hovered, 'pc--hero': hero, 'pc--snap-shut': snapDrawerShut, 'profile-card--hero': hero, 'profile-card--selected': selected }]"
    @activate="onScopeChanged(true)"
    @deactivate="onScopeChanged(false)"
    @mouseover="onPointerOver"
    @mouseleave="hovered = false">

    <div class="pc-image" :style="bgStyle">
      <div class="pc-image-overlay" />

      <!-- Labelling the picture, so it sits on the picture. -->
      <div v-if="hero && mapLabel" class="pc-map-tag">{{ mapLabel }}</div>

      <!-- What you were sitting in when the game last saved. The thumbnail is
           only written on saves that ran a thumbnail pass, so it can be absent
           even when the vehicle is known. -->
      <div v-if="hero && lastVehicle" class="pc-vehicle">
        <img
          v-if="lastVehicle.image && vehicleImageOk"
          class="pc-vehicle-img"
          :src="lastVehicle.image"
          alt=""
          @error="vehicleImageOk = false" />
        <div class="pc-vehicle-cap">
          <div class="pc-vehicle-eyebrow">Last driven</div>
          <!-- niceName is a {txt, context} translation for some vehicles and a
               plain string for others; $ctx_t handles both. Printed raw it came
               out as the JSON of the translation object. -->
          <div v-if="lastVehicle.name" class="pc-vehicle-name">{{ $ctx_t(lastVehicle.name) }}</div>
          <div v-if="lastVehicle.location" class="pc-vehicle-loc">{{ $ctx_t(lastVehicle.location) }}</div>
        </div>
      </div>

      <!-- Identity belongs on the art: it is the one part of the card with room
           to spare, and the picture is this save's map. -->
      <div class="pc-header">
        <div v-if="hero && active" class="pc-eyebrow">{{ $ctx_t("ui.career.nowplaying") }}</div>
        <div class="pc-name">{{ displayName || id }}</div>
        <div v-if="hero" class="pc-strapline">{{ heroStrapline }}</div>
        <template v-else>
          <div v-if="active" class="pc-playing">{{ $ctx_t("ui.career.nowplaying") }}</div>
          <div v-else-if="lastPlayedDescription" class="pc-last-played">{{ lastPlayedDescription }}</div>
        </template>

        <!-- Inside the header so the chips sit on the same rhythm as the line
             above them, whether or not that line is there. -->
        <div v-if="(hero || !isManage) && hasBadges" class="pc-badges">
          <span v-if="saveDataMissing" class="pc-chip pc-chip--incomplete">No save data</span>
          <span v-if="modeChipLabel" :class="modeChipClass">{{ modeChipLabel }}</span>
          <span v-if="experimentalMaintenanceEnabled" class="pc-chip pc-chip--maintenance">Maintenance</span>
          <span v-if="(requiresMigration || outdatedVersion) && !incompatibleVersion" class="pc-chip pc-chip--migration">Migrate to 0.40</span>
          <span v-if="importSource" class="pc-chip pc-chip--migration">RLS save</span>
        </div>
        <div v-if="importBlockReason" class="pc-last-played">{{ importBlockReason }}</div>
      </div>
    </div>

    <div :class="['pc-drawer', { 'pc-drawer--open': showBody }]">
      <div ref="bodyRef" class="pc-body" v-bng-on-ui-nav:menu,back="goBack">
        <template v-if="backupStep">
          <div v-if="backupStep === 'name'" class="pc-backup-section">
            <div class="pc-section-head">
              <div class="pc-section-title">Backup</div>
              <div class="pc-section-sub">Copy of {{ originalName }}</div>
            </div>
            <label class="pc-backup-label">Backup name</label>
            <div data-focus-field :class="['pc-backup-input-wrap', { 'pc-backup-input-wrap--error': backupNameError }]">
              <!-- v-bng-text-input owns this field's CEF typing (focus, blur, unmount); add no focus or blur handlers here. -->
              <input
                v-bng-text-input
                :value="backupName"
                :maxlength="PROFILE_NAME_MAX_LENGTH"
                class="pc-backup-input"
                @input="setBackupName($event.target.value)"
                @keydown.enter.prevent="onBackupNameEnter" />
            </div>
            <span v-if="backupNameError" class="pc-backup-error">{{ backupNameError }}</span>
            <div class="pc-btns pc-btns--backup">
              <button ref="backupCancelButton" class="pc-btn pc-btn--secondary" type="button" @click="cancelBackup()">Cancel</button>
              <button
                ref="backupCreateButton"
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--primary"
                type="button"
                :disabled="!!backupNameError || !backupName.trim()"
                @click="confirmBackup()">Create</button>
            </div>
          </div>
          <div v-else-if="backupStep === 'loading'" class="pc-backup-feedback">
            <div class="pc-backup-spinner" />
          </div>
          <div v-else-if="backupStep === 'success'" class="pc-backup-feedback pc-backup-feedback--success">
            Backup created
          </div>
        </template>
        <div v-else-if="savesOpen" class="pc-manage-section pc-saves-section">
          <div class="pc-section-head">
            <div class="pc-section-title">Saves</div>
            <div class="pc-section-sub">{{ savesSubtitle }}</div>
          </div>
          <div v-if="savesLoading" class="pc-saves-state">Loading saves…</div>
          <div v-else-if="!saveFolders.length" class="pc-saves-state">No saves in this profile.</div>
          <div v-else class="pc-saves-list">
            <button
              v-for="save in saveFolders"
              :key="save.name"
              type="button"
              class="pc-save-row"
              :class="{ 'pc-save-row--current': save.isCurrent }"
              :disabled="save.incompatibleVersion || save.corrupted"
              @click="onLoadSave(save)">
              <span class="pc-save-name">
                {{ save.name }}
                <span v-if="save.isCurrent" class="pc-save-chip">Current</span>
              </span>
              <span class="pc-save-sub">{{ saveRowSubtitle(save) }}</span>
            </button>
          </div>
          <div class="pc-btns pc-btns--back">
            <button class="pc-btn pc-btn--secondary" @click="closeSaves()">Back</button>
          </div>
        </div>
        <ProfileManagePanel
          v-else-if="isManage"
          :menu="currentMenu"
          :hero="hero"
          :active="active"
          :incompatible-version="incompatibleVersion"
          :original-name="originalName"
          :name="saveName"
          :name-error="nameError"
          :max-length="PROFILE_NAME_MAX_LENGTH"
          :validate="validateFn"
          @open-rename="currentMenu = MENU_ITEMS.RENAME"
          @open-delete="currentMenu = MENU_ITEMS.DELETE"
          @backup="startBackup"
          @back="goBack"
          @update:name="saveName = $event"
          @save-name="updateProfileName"
          @confirm-delete="deleteProfile" />
        <ProfileStatusPanel
          v-else
          :money="money"
          :hero="hero"
          :fre-skills="freSkills"
          :recent-money="recentMoney"
          :highlights-pending="highlightsPending"
          :asset-value="assetValue"
          :vehicle-count="vehicleCount"
          :garage-count="garageCount"
          :insurance-score="insuranceScore">
          <div v-if="!isManage && !isHardcore && !importSource" class="pc-maintenance-row">
            <span class="pc-maintenance-label">Police</span>
            <button
              type="button"
              class="pc-switch"
              :class="{ 'pc-switch--active': policeEnabled }"
              :aria-pressed="policeEnabled"
              :disabled="incompatibleVersion || policeToggleSaving"
              @click.stop="onPoliceSwitchClick">
              <span class="pc-switch-track">
                <span class="pc-switch-thumb" />
              </span>
              <span class="pc-switch-value">{{ policeEnabled ? "On" : "Off" }}</span>
            </button>
          </div>

          <div v-if="APPRENTICESHIP_CHOICE_ENABLED && !isManage && needsEmploymentChoice && !importSource" class="pc-maintenance-row">
            <div class="pc-maintenance-copy">
              <span class="pc-maintenance-label">Employment</span>
              <span class="pc-maintenance-hint">Off for now — freelance cargo, no company jobs. One-time: turn On to add apprenticeship, or lock Off. Ignore and it stays Off until you decide.</span>
            </div>
            <button
              type="button"
              class="pc-switch"
              :aria-pressed="false"
              :disabled="incompatibleVersion || employmentToggleSaving"
              @click.stop="onEmploymentSwitchClick">
              <span class="pc-switch-track">
                <span class="pc-switch-thumb" />
              </span>
              <span class="pc-switch-value">{{ employmentToggleSaving ? "Saving…" : "Off" }}</span>
            </button>
          </div>

          <div v-if="!importSource" class="pc-maintenance-row">
            <span class="pc-maintenance-label">Experimental maintenance</span>
            <button
              type="button"
              class="pc-switch"
              :class="{ 'pc-switch--active': experimentalMaintenanceEnabled }"
              :aria-pressed="experimentalMaintenanceEnabled"
              :disabled="incompatibleVersion || maintenanceToggleSaving"
              @click.stop="onExperimentalMaintenanceSwitchClick">
              <span class="pc-switch-track">
                <span class="pc-switch-thumb" />
              </span>
              <span class="pc-switch-value">{{ experimentalMaintenanceEnabled ? "On" : "Off" }}</span>
            </button>
          </div>

          <div class="pc-btns">
            <button
              v-if="!importSource"
              v-bng-sound-class="'bng_click_generic'"
              class="pc-btn pc-btn--secondary"
              ref="manageButton"
              @click="enableManage">Manage</button>
            <button
              v-if="!importSource"
              v-bng-sound-class="'bng_click_generic'"
              class="pc-btn pc-btn--secondary"
              :disabled="incompatibleVersion"
              @click="openSaves">Saves</button>
            <button
              v-bng-sound-class="'bng_click_generic'"
              class="pc-btn pc-btn--primary"
              :disabled="active || incompatibleVersion"
              @click="$emit('load', id)">{{ hero && !active ? "Continue" : "Load" }}</button>
          </div>
        </ProfileStatusPanel>
      </div>
    </div>

    <div v-if="active" class="pc-active-bar" />
  </div>
</template>

<script setup>
import { computed, inject, nextTick, onBeforeUnmount, ref, watch } from "vue"
import { vBngScopedNav, vBngSoundClass, vBngOnUiNav, vBngTextInput } from "@/common/directives"
import { timeSpan } from "@/utils/datetime"
import { lua } from "@/bridge"
import { openConfirmation } from "@/services/popup"
import { setFocus } from "@/services/uiNavFocus"
import { PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { APPRENTICESHIP_CHOICE_ENABLED } from "./start/careerStartConfig.js"
import { getProfileModeChipLabel, resolveProfileDifficulty, resolveProfileStartMode } from "./start/careerStartModes.js"
import ProfileStatusPanel from "./profileCard/ProfileStatusPanel.vue"
import ProfileManagePanel from "./profileCard/ProfileManagePanel.vue"
import { useProfileBackup } from "./profileCard/useProfileBackup.js"
import { MENU_ITEMS } from "./profileCard/menuItems.js"
import { safeLua } from "../../utils/safeLua.js"

const props = defineProps({
  id: { type: String, required: true },
  displayName: { type: String, default: "" },
  /**
   * Not required: a slot whose save cannot be read has no date, no creation
   * date and no version to compare — the Lua sends an id and saveDataMissing
   * and nothing else. The card already renders that state; demanding the
   * fields only produced a warning per field per such profile.
   */
  date: { type: String, default: "" },
  creationDate: { type: String, default: "" },
  incompatibleVersion: Boolean,
  outdatedVersion: { type: Boolean, default: false },
  requiresMigration: Boolean,
  preview: { type: String, default: "" },
  beamXP: Object,
  vouchers: Object,
  money: Object,
  active: Boolean,
  branches: Array,
  freSkills: { type: [Array, Object], default: () => [] },
  activeChallenge: [Object, String],
  careerStartMode: String,
  difficultyMode: String,
  cheatsMode: Boolean,
  experimentalMaintenanceEnabled: Boolean,
  policeEnabled: { type: Boolean, default: true },
  /** Existing saves missing logisticsEmploymentMode.json — one-time toggle. */
  needsEmploymentChoice: { type: Boolean, default: false },
  employmentApprenticeship: { type: Boolean, default: true },
  /** Set by the Lua when the slot has no playerAttributes.json to read. */
  saveDataMissing: Boolean,
  /**
   * An RLS save from settings/cloud/saves/ (overhaul_shell_saveImport). Load opens the
   * migration step; nothing on the card may write to it, so only Load is offered.
   */
  importSource: Boolean,
  importBlockReason: String,
  forceCloseManage: Boolean,
  /** The featured save: wider, split in two, and open without being hovered. */
  hero: Boolean,
  /** Ringed while browsing: chosen, but not yet opened. */
  selected: Boolean,
  insuranceScore: Object,
  vehicleCount: Number,
  garageCount: Number,
  /** [{amount, label, time}] newest first — fetched by the parent, hero only. */
  recentMoney: { type: Array, default: () => [] },
  /** Owned vehicles valued at age + mileage, summed. Hero only. */
  assetValue: Number,
  /** {name, location, image} for whatever was being driven at the last save. */
  lastVehicle: Object,
  /** True while the above are still being read, so empty is not mistaken for none. */
  highlightsPending: Boolean,
  /** The strip is in motion; hover means nothing until it stops. */
  sliding: Boolean,
  /** Resolved by the parent against overhaul_world_maps — the id alone is not a label. */
  mapLabel: { type: String, default: "" },
})

const emit = defineEmits(["card:activate", "manage:change", "backup:change", "load", "saves:load"])

const hovered = ref(false)
const isManage = ref(false)
const currentMenu = ref(null)
const maintenanceToggleSaving = ref(false)
const policeToggleSaving = ref(false)
const employmentToggleSaving = ref(false)
const employmentToggleValue = ref(props.employmentApprenticeship === true)
watch(
  () => [props.needsEmploymentChoice, props.employmentApprenticeship],
  () => {
    employmentToggleValue.value = props.employmentApprenticeship === true
  }
)
const savesOpen = ref(false)
const savesLoading = ref(false)
const saveFolders = ref([])

/** Picking a save is a state of this card, not a screen you get sent to. */
async function openSaves() {
  savesOpen.value = true
  savesLoading.value = true
  saveFolders.value = []
  emit("card:activate", true)
  emit("manage:change", true)
  try {
    const folders = await lua.overhaul_career_career.getSaveFoldersForProfile(props.id)
    saveFolders.value = Array.isArray(folders) ? folders : Object.values(folders || {})
  } catch (error) {
    saveFolders.value = []
    safeLua(() => { throw error }, "ProfileCard failed to load saves")
  } finally {
    savesLoading.value = false
  }
}

function closeSaves() {
  savesOpen.value = false
  saveFolders.value = []
  emit("card:activate", false)
  emit("manage:change", false)
}

const savesSubtitle = computed(() => {
  if (savesLoading.value) return "Reading save folders…"
  const count = saveFolders.value.length
  if (!count) return "Nothing stored yet"
  return `${count} to choose from — the newest is loaded by default`
})

function saveRowSubtitle(save) {
  if (save.incompatibleVersion) return "Saved with an older version"
  if (save.corrupted) return "Corrupted"
  if (save.requiresMigration || save.outdatedVersion) return "Migrate a copy to 0.40"
  return timeSpan(save.date)
}

function onLoadSave(save) {
  if (!save || save.incompatibleVersion || save.corrupted) return
  emit("saves:load", props.id, save.name)
}

watch(() => props.forceCloseManage, (shouldClose) => {
  if (shouldClose && isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("card:activate", false)
    emit("manage:change", false)
  }
  if (shouldClose && savesOpen.value) closeSaves()
  if (shouldClose && backupStep.value) cancelBackup()
})

const validateName = inject("validateName")
const bodyRef = ref(null)

const {
  step: backupStep,
  name: backupName,
  nameError: backupNameError,
  open: openBackup,
  close: closeBackup,
  setName: setBackupName,
  confirm: confirmBackup,
} = useProfileBackup({
  getId: () => props.id,
  getActive: () => props.active,
  validateName,
  onSuccess: () => emit("backup:change", false),
})

const backupCancelButton = ref(null)
const backupCreateButton = ref(null)

// Enter on an unusable name lands on Cancel, so a stray Enter cannot submit it.
function onBackupNameEnter() {
  const focusTarget = backupNameError.value || !backupName.value.trim() ? backupCancelButton : backupCreateButton
  if (focusTarget.value) nextTick(() => setFocus(focusTarget.value))
}

// Seed from what the card shows, not the on-disk folder id — otherwise renaming
// "Profile 1" starts you editing "profile1" and saving unchanged silently renames it.
const saveName = ref(props.displayName || props.id)
const nameError = ref(null)

const bgStyle = computed(() => ({
  backgroundImage: props.preview ? `url(${props.preview})` : "linear-gradient(135deg, #182435, #0b0f19)",
}))

/** timeSpan returns "-" when there is no date. An empty line says less than no line. */
const lastPlayedDescription = computed(() => {
  const span = timeSpan(props.date)
  return span && span !== "-" ? span : null
})

/** One line under the name. The map is its own tag in the artwork's top corner. */
const heroStrapline = computed(() => {
  if (!lastPlayedDescription.value) return ""
  return `${props.active ? "Last saved" : "Last played"} ${lastPlayedDescription.value} ago`
})

/** The hero's panel is the card, not a drawer — it never has to be revealed. */
const showBody = computed(() => props.hero || hovered.value || isManage.value || savesOpen.value || !!backupStep.value)

const activeView = computed(() => {
  // Loading and loaded are different heights, and the drawer animates to whatever
  // this key last resolved to — so they have to be different keys.
  if (savesOpen.value) return savesLoading.value ? "saves-loading" : `saves-${saveFolders.value.length}`
  if (backupStep.value === "name") return "backup-name"
  if (backupStep.value === "loading") return "backup-loading"
  if (backupStep.value === "success") return "backup-success"
  if (!isManage.value) return "status"
  if (currentMenu.value === MENU_ITEMS.RENAME) return "rename"
  if (currentMenu.value === MENU_ITEMS.DELETE) return "delete"
  return "manage"
})

watch(activeView, () => {
  const el = bodyRef.value
  // The hero's panel is a fixed-height column, so animating it to its content
  // height would collapse it out of the card's grid.
  if (!el || !showBody.value || props.hero) return
  const from = el.offsetHeight
  el.style.height = from + "px"
  nextTick(() => {
    el.style.height = "auto"
    const to = el.offsetHeight
    el.style.height = from + "px"
    el.offsetHeight
    el.style.transition = "height 0.25s cubic-bezier(0.22, 1, 0.36, 1)"
    el.style.height = to + "px"
    const done = e => {
      if (e.target !== el) return
      el.style.height = ""
      el.style.transition = ""
      el.removeEventListener("transitionend", done)
    }
    el.addEventListener("transitionend", done)
  })
})

const modeChipLabel = computed(() => getProfileModeChipLabel(props))
const modeChipClass = computed(() => {
  // Custom is the only path that can carry cheats, so it gets its own colour.
  if (resolveProfileStartMode(props) === "custom" || props.cheatsMode) {
    return "pc-chip pc-chip--cheats"
  }
  return "pc-chip pc-chip--challenge"
})
const isHardcore = computed(() => resolveProfileDifficulty(props)?.id === "hardcore")

/**
 * Hover is only real if the pointer went to the card. While the strip slides,
 * the cards go to the pointer — every one that passes under it fires mouseover
 * and would light up on the way past. Held off until the strip is at rest.
 */
function onPointerOver() {
  if (props.sliding) return
  hovered.value = true
}

watch(
  () => props.sliding,
  isSliding => {
    if (isSliding) hovered.value = false
  }
)

const snapDrawerShut = ref(false)
let snapTimer = null

watch(
  () => props.hero,
  isHero => {
    if (isHero) return
    hovered.value = false
    snapDrawerShut.value = true
    cancelAnimationFrame(snapTimer)
    snapTimer = requestAnimationFrame(() =>
      (snapTimer = requestAnimationFrame(() => {
        snapDrawerShut.value = false
      }))
    )
  }
)

onBeforeUnmount(() => cancelAnimationFrame(snapTimer))

/** Dropped the moment a recorded thumbnail fails to load, so a broken-image
    box never sits in the artwork; resets when the vehicle changes. */
const vehicleImageOk = ref(true)

watch(
  () => props.lastVehicle?.image,
  () => {
    vehicleImageOk.value = true
  }
)

const hasBadges = computed(
  () => !!(modeChipLabel.value || props.experimentalMaintenanceEnabled || props.saveDataMissing || props.outdatedVersion || props.importSource)
)

const originalName = computed(() => props.displayName || props.id)

const validateFn = name => {
  let res = validateName(name)
  // The save's own current name is never a conflict with itself.
  if (name === props.id || name === originalName.value) res = null
  nameError.value = res || null
  return !res
}

const canDeactivate = () => !isManage.value && !savesOpen.value && backupStep.value !== "loading"
const canBubbleEvent = e => ["menu", "tab_l", "tab_r"].includes(e.detail.name) && !isManage.value && !savesOpen.value && !backupStep.value

const onScopeChanged = value => {
  if (!value && savesOpen.value) closeSaves()
  if (!value && isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("manage:change", false)
  }
  if (!value && backupStep.value && backupStep.value !== "loading") {
    cancelBackup()
  }
}

const manageButton = ref(null)
function enableManage() {
  isManage.value = true
  emit("card:activate", true)
  emit("manage:change", true)
}

function goBack() {
  if (savesOpen.value) {
    closeSaves()
    return
  }
  if (backupStep.value === "name") {
    cancelBackup()
    return
  }
  if (backupStep.value === "loading" || backupStep.value === "success") {
    return
  }
  if (currentMenu.value) {
    currentMenu.value = null
  } else {
    isManage.value = false
    emit("card:activate", false)
    emit("manage:change", false)
    nextTick(() => { if (manageButton.value) setFocus(manageButton.value) })
  }
}

function startBackup() {
  if (isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("manage:change", false)
  }
  openBackup()
  emit("card:activate", true)
  emit("backup:change", true)
}

function cancelBackup() {
  if (backupStep.value === "loading") return
  closeBackup()
  emit("backup:change", false)
  if (!isManage.value) emit("card:activate", false)
}

const deleteProfile = () => {
  lua.overhaul_career_saveSystem.removeProfile(props.id)
  lua.overhaul_career_career.sendAllCareerProfilesData()
}
const updateProfileName = async () => {
  await lua.overhaul_career_saveSystem.renameProfile(props.id, saveName.value)
  await lua.overhaul_career_career.sendAllCareerProfilesData()
}

async function onPoliceSwitchClick() {
  if (props.incompatibleVersion || policeToggleSaving.value || isHardcore.value) return
  policeToggleSaving.value = true
  try {
    const next = props.policeEnabled === false
    const ok = await lua.overhaul_career_career.setPoliceEnabledForSaveSlot(props.id, next)
    if (ok) {
      await lua.overhaul_career_career.sendAllCareerProfilesData()
      // Only warn when already in a session — toggle during load is applied on activate.
      const inSession = await lua.overhaul_career_career.isActive()
      if (inSession) {
        await openConfirmation(
          "Police",
          "Restart for changes to take effect.",
          [{ label: "OK", value: true, extras: { default: true } }]
        )
      }
    }
  } finally {
    policeToggleSaving.value = false
  }
}

async function onEmploymentSwitchClick() {
  if (!APPRENTICESHIP_CHOICE_ENABLED || props.incompatibleVersion || employmentToggleSaving.value || !props.needsEmploymentChoice) return
  const choice = await openConfirmation(
    "Employment",
    "Employment is Off right now (freelance). Apprenticeship turns it On and locks company jobs. Keep freelance locks Off. Cancel leaves it unlocked so you can decide later.",
    [
      { label: "Cancel", value: "cancel" },
      { label: "Keep freelance", value: "off" },
      { label: "Apprenticeship", value: "on", extras: { default: true } },
    ]
  )
  if (choice !== "on" && choice !== "off") return

  const enabled = choice === "on"
  employmentToggleSaving.value = true
  try {
    employmentToggleValue.value = enabled
    const ok = await lua.overhaul_career_career.setEmploymentApprenticeshipForSaveSlot(props.id, enabled)
    if (ok) {
      await lua.overhaul_career_career.sendAllCareerProfilesData()
    } else {
      employmentToggleValue.value = props.employmentApprenticeship === true
    }
  } finally {
    employmentToggleSaving.value = false
  }
}

async function onExperimentalMaintenanceSwitchClick() {
  if (props.incompatibleVersion || maintenanceToggleSaving.value) return
  maintenanceToggleSaving.value = true
  try {
    const next = !props.experimentalMaintenanceEnabled
    const ok = await lua.overhaul_career_career.setMaintenanceModeForSaveSlot(props.id, next)
    if (ok) {
      await lua.overhaul_career_career.sendAllCareerProfilesData()
    }
  } finally {
    maintenanceToggleSaving.value = false
  }
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

// Visual skin of ProfileCard.vue's own elements: the card shell, picture and header, drawer,
// the switch rows, and the featured (hero) layout.
//
// Map
//   .pc                       the card: grid, hover lift, outdated grey-out
//   .pc--hero                 featured card: two columns, and :deep() overrides into the panels
//   .pc-eyebrow … .pc-chip*   picture overlay, name block, map tag, last-driven box, chips
//   .pc-body, .pc-drawer      the revealed panel and its height and snap rules
//   .pc-maintenance-row, .pc-switch*   switch rows the card draws itself
//   .pc-saves-*, .pc-save-*   the save list the card draws (first in the block)
//   .pc-backup-*              the backup name step, spinner and success line (first in the block)
//   .pc-active-bar, pc-fade-in and pc-backup-spin keyframes
//
// Scope rule
//   Rules for elements the card renders are plain selectors. Rules for elements a panel renders
//   (status, manage, and the shared buttons and section chrome) are wrapped in :deep(). A plain selector
//   would not reach those elements because they carry the panel's scope, not this card's.
//   Shared button and section rules follow the card rules below.

/* Saves list, drawn by this card. */
.pc-saves-state {
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.55);
  padding: 0.6em 0;
}

.pc-saves-list {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  /* Three autosaves is the normal case — only scroll past that. */
  max-height: 12.5em;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
}

/* Name left, age right — stacked, these read as three blocks rather than a list. */
.pc-save-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
  width: 100%;
  text-align: left;
  border: 0;
  border-radius: 8px;
  padding: 0.4em 0.55em;
  background: #1e2533;
  color: #f3f4f6;
  font-family: inherit;
  cursor: pointer;
  transition: background 0.12s ease, box-shadow 0.12s ease, transform 0.06s ease;

  &:hover:not(:disabled) {
    background: #2c3548;
    box-shadow: 0 0 0 1px rgba(148, 163, 184, 0.55);
  }

  &:active:not(:disabled) {
    background: #161c27;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.pc-save-row--current {
  box-shadow: inset 0 0 0 1px rgba(255, 122, 26, 0.5);
}

.pc-save-name {
  display: flex;
  align-items: center;
  gap: 0.4em;
  min-width: 0;
  font-size: 0.85em;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.pc-save-chip {
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: #ff9647;
}

.pc-save-sub {
  flex: 0 1 auto;
  min-width: 0;
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.5);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* Backup name step, spinner and success line, drawn by this card. */
.pc-backup-section {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  min-height: 7em;
}

.pc-backup-label {
  font-weight: 600;
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.65);
  padding-left: 0.1em;
}

.pc-backup-input-wrap {
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.1em 0.5em;

  &:focus-within { border-color: rgba(148, 163, 184, 0.5); }
  &.pc-backup-input-wrap--error { border-color: rgba(239, 68, 68, 0.6); }
}

.pc-backup-input {
  width: 100%;
  background: none;
  border: 0;
  outline: none;
  color: #fff;
  font-size: 0.88em;
  font-family: inherit;
}

.pc-backup-error {
  font-size: 0.72em;
  color: #f87171;
  padding-left: 0.15em;
}

.pc-backup-feedback {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 6em;
}

.pc-backup-feedback--success {
  font-weight: 700;
  font-size: 0.95em;
  color: #86efac;
}

.pc-backup-spinner {
  width: 2.25em;
  height: 2.25em;
  border: 3px solid rgba(148, 163, 184, 0.25);
  border-top-color: #ff7a1a;
  border-radius: 50%;
  animation: pc-backup-spin 0.7s linear infinite;
}

@keyframes pc-backup-spin {
  to { transform: rotate(360deg); }
}

.pc {
  position: relative;
  display: grid;
  grid-template-rows: 1fr auto;
  height: 100%;
  font-size: calc-ui-rem();
  color: #fff;
  border-radius: calc-ui-rem(1);
  overflow: hidden;
  cursor: default;

  &:hover, &.pc--hover {
    transform: translateY(-3px);
    transition: transform 0.22s ease-out;
  }

  /**
   * Two phases, in this order: the card rises to full height, then the panel
   * wipes open to the right. Selecting it does not slam a finished card into
   * place — it grows, then opens.
   */
  transition:
    transform 0.22s ease-out,
    height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    min-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    max-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s,
    min-width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s;

  &.pc--outdated {
    filter: grayscale(0.7);
    opacity: 0.7;
  }
}

/**
 * The featured card is the same component turned on its side: art in one column,
 * the panel that is normally a hover drawer permanently open in the other.
 */
.pc--hero {
  grid-template-rows: minmax(0, 1fr);
  /**
   * The artwork column is fixed and the panel takes whatever is left, so the
   * card's growing width opens the panel rather than crushing the artwork.
   * 22rem is exactly an unselected card, which is why the first phase of the
   * reveal can change height alone without anything moving sideways.
   */
  grid-template-columns: calc-ui-rem(22) minmax(0, 1fr);
  box-shadow:
    0 0 0 1px rgba(255, 122, 26, 0.35),
    0 18px 48px rgba(0, 0, 0, 0.55);

  /* It is the anchor of the strip — it should not drift under the cursor. */
  &:hover,
  &.pc--hover {
    transform: none;
  }

  .pc-drawer {
    transition: none;
  }

  .pc-body {
    height: 100%;
    width: calc-ui-rem(28);
    padding: 0.9em 0.9em 0;
    overflow-y: auto;
    /* Dim: this one runs the full height of the panel, and in orange it read as
       a design element rather than a scrollbar. */
    scrollbar-width: thin;
    scrollbar-color: rgba(148, 163, 184, 0.35) transparent;
  }

  /* Fill whatever the persistent header leaves, so Back and Continue land at the
     bottom edge instead of floating halfway up a mostly empty panel. */
  :deep(.pc-status-section),
  :deep(.pc-manage-section),
  .pc-backup-section {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    min-height: 0;
  }

  /* Nothing in here may be compressed below its content height. Flex's default
     shrink let the skills list be squeezed and then paint over the rows under
     it; if it does not fit, the panel scrolls instead. */
  :deep(.pc-status-section) > * {
    flex-shrink: 0;
  }

  .pc-saves-list {
    max-height: none;
  }

  .pc-header {
    padding: 0 1.15em 1em;
  }

  /* Taller than the small cards' scrim: this column is mostly sky, and the name
     sits over it at twice the size. */
  .pc-image-overlay {
    background: linear-gradient(
      180deg,
      rgba(0, 0, 0, 0.05) 0%,
      rgba(0, 0, 0, 0.2) 45%,
      rgba(0, 0, 0, 0.82) 100%
    );
  }

  .pc-name {
    font-size: 2.15em;
  }

  /* Skills and money history sit beside each other rather than stacking, which
     is what made the single column read as one undifferentiated list. */
  :deep(.pc-detail) {
    display: grid;
    align-items: start;
  }

  /* Ruled, like the figures above. A full-width progress bar running to a bare
     18px gutter read as bleeding into the column beside it. */
  /* Not even: skill names are short and right-align a level, while the money
     labels are free text and were losing half of themselves to the ellipsis. */
  :deep(.pc-detail--split) {
    grid-template-columns: 0.88fr 1.12fr;

    .pc-skills {
      padding-right: 1em;
    }

    .pc-txns {
      padding-left: 1em;
      border-left: 1px solid #1e2533;
    }
  }

  :deep(.pc-skills) {
    margin-bottom: 0;
  }

  /**
   * A grid, not a wrapping flex row. Flex decides line breaks from each item's
   * unshrunk width, so a long skill name pushed its level onto a second line
   * instead of ellipsising — rows grew by a line each and the panel gained a
   * scrollbar. Here the name column is the only flexible one and it truncates,
   * so every row is exactly the same height whatever the name is.
   */
  :deep(.pc-skill) {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    align-items: center;
    column-gap: 0.4em;
    row-gap: 0.15em;
    padding: 0.1em 0;
  }

  /* The ruled rows above already draw lines; their own border kept stacking
     more onto the same few pixels. */
  .pc-maintenance-row {
    padding: 0.3em 0;
    margin-bottom: 0;
    border-bottom: 0;
  }

  /**
   * Load leads on its own row; Manage and Saves share the one below it. The
   * block is pinned because the panel scrolls — margin-top:auto alone would push
   * it past the bottom edge the moment the stats are taller than the card.
   */
  :deep(.pc-btns) {
    position: sticky;
    bottom: 0;
    flex-wrap: wrap;
    margin-top: auto;
    padding: 0.6em 0 0.9em;
    background: linear-gradient(180deg, rgba(11, 15, 25, 0) 0%, #0b0f19 0.6em);

    .pc-btn--primary {
      order: -1;
      flex: 1 0 100%;
      padding: 0.55em 0;
      font-size: 1em;
      font-weight: 700;
    }
  }
}

.pc-eyebrow {
  font-size: 0.72em;
  font-weight: 800;
  letter-spacing: 0.13em;
  text-transform: uppercase;
  color: #ff9647;
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.6);
  margin-bottom: 0.15em;
}

/* Arrives after the card does, so it eases in rather than appearing mid-frame. */
.pc-vehicle {
  animation: pc-fade-in 0.18s ease-out;
}

@keyframes pc-fade-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

/**
 * Only the drawer snaps. The card itself keeps its size transition on the way
 * out, because a deselected card collapsing instantly shunts everything to its
 * right across by the width difference in a single frame — a hard jump the
 * slide then has to absorb. Shrinking it is safe: once deselected it is back to
 * the stacked layout, which at a wide size is simply a wide picture, not the
 * broken half-state that made growing it a problem.
 */
.pc--snap-shut .pc-drawer {
  transition: none;
}

.pc-image {
  position: relative;
  min-height: 0;
  background-size: cover;
  background-position: center;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
}

.pc-drawer {
  display: grid;
  min-height: 0;
  overflow: hidden;
  background: #0b0f19;
  grid-template-rows: minmax(0, 0fr);
  transition: grid-template-rows 0.32s cubic-bezier(0.22, 1, 0.36, 1);

  &.pc-drawer--open {
    grid-template-rows: minmax(0, 1fr);
  }
}

.pc-image-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(180deg, rgba(0,0,0,0.05) 0%, rgba(0,0,0,0.15) 40%, rgba(0,0,0,0.65) 100%);
  pointer-events: none;
}

.pc-header {
  position: relative;
  z-index: 1;
  padding: 0 1em 0.7em;
}

.pc-name {
  font-weight: 900;
  font-size: 2em;
  line-height: 1.15;
  letter-spacing: 0.01em;
  text-shadow: 0 2px 8px rgba(0,0,0,0.5);
  font-family: "Overpass", var(--fnt-defs);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.pc-playing {
  margin-top: 0.2em;
  font-weight: 700;
  font-size: 0.8em;
  color: var(--bng-orange-400, #fb923c);
  text-shadow: 0 1px 4px rgba(0,0,0,0.5);
}

.pc-last-played {
  margin-top: 0.2em;
  font-size: 0.78em;
  opacity: 0.75;
  text-shadow: 0 1px 4px rgba(0,0,0,0.4);
}

/* Quiet: it names the picture, it is not a headline. */
.pc-map-tag {
  position: absolute;
  top: 0.8em;
  left: 0.9em;
  z-index: 1;
  font-size: 0.78em;
  font-weight: 600;
  letter-spacing: 0.02em;
  color: rgba(255, 255, 255, 0.72);
  text-shadow: 0 1px 5px rgba(0, 0, 0, 0.8);
}

/* Top corner of the art, opposite the name block at the bottom. */
.pc-vehicle {
  position: absolute;
  top: 0.7em;
  right: 0.7em;
  z-index: 1;
  width: 10em;
  padding: 0.45em 0.55em 0.5em;
  border-radius: 10px;
  background: rgba(6, 9, 16, 0.72);
  border: 1px solid rgba(148, 163, 184, 0.25);
  backdrop-filter: blur(3px);
}

.pc-vehicle-img {
  display: block;
  width: 100%;
  height: auto;
  margin-bottom: 0.15em;
}

.pc-vehicle-eyebrow {
  font-size: 0.6em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.45);
}

.pc-vehicle-name {
  font-size: 0.78em;
  font-weight: 700;
  line-height: 1.2;
}

.pc-vehicle-loc {
  font-size: 0.68em;
  color: rgba(255, 255, 255, 0.55);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* Place and recency on one line — two facts do not need two rows. */
.pc-strapline {
  margin-top: 0.25em;
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.8);
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.55);
}

.pc-badges {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
  margin-top: 0.3em;
}

.pc-chip {
  display: inline-flex;
  align-items: center;
  padding: 0.15em 0.55em;
  border-radius: 8px;
  font-size: 0.72em;
  font-weight: 800;
  box-shadow: 0 3px 8px rgba(0,0,0,0.3);
}
.pc-chip--challenge { background: linear-gradient(90deg, #ff7a1a, #e85f00); }
.pc-chip--cheats { background: linear-gradient(90deg, #9333ea, #7c3aed); }
.pc-chip--maintenance {
  background: linear-gradient(90deg, #0f9f8f, #22c55e);
  color: #f0fdfa;
}
.pc-chip--migration {
  background: linear-gradient(90deg, #c2410c, #9a3412);
  color: #fff7ed;
}
.pc-chip--incomplete {
  background: rgba(15, 23, 42, 0.85);
  border: 1px solid rgba(148, 163, 184, 0.55);
  color: rgba(255, 255, 255, 0.75);
}

.pc-body {
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: hidden;
  padding: 0.55em 0.7em 0.65em;
  background: #0b0f19;
}

.pc-maintenance-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  padding: 0.35em 0;
  margin-bottom: 0.35em;
  border-bottom: 1px solid #1e2533;
}

.pc-maintenance-copy {
  display: flex;
  flex-direction: column;
  gap: 0.15em;
  min-width: 0;
  flex: 1 1 auto;
}

.pc-maintenance-label {
  font-size: 0.78em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.75);
}

.pc-maintenance-hint {
  font-size: 0.68em;
  line-height: 1.3;
  color: rgba(255, 255, 255, 0.45);
}

.pc-switch {
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
  border: 0;
  background: transparent;
  color: #fff;
  cursor: pointer;
  font-size: 0.78em;
  font-weight: 700;
  padding: 0.15em 0;

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.pc-switch-track {
  position: relative;
  width: 2.4em;
  height: 1.25em;
  border-radius: 999px;
  background: #374151;
  transition: background 0.2s ease;
}

.pc-switch--active .pc-switch-track {
  background: linear-gradient(90deg, #0f9f8f, #22c55e);
}

.pc-switch-thumb {
  position: absolute;
  top: 0.12em;
  left: 0.12em;
  width: 1em;
  height: 1em;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
  transition: transform 0.2s ease;
}

.pc-switch--active .pc-switch-thumb {
  transform: translateX(1.1em);
}

.pc-switch-value {
  min-width: 1.6em;
  text-align: right;
  opacity: 0.85;
}

.pc-active-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 0.25em;
  background: var(--bng-orange-400, #fb923c);
  z-index: 5;
}
// Buttons and section chrome shared by the card's status buttons and every panel it mounts.
// Rules for the buttons and section chrome of ProfileStatusPanel and ProfileManagePanel are wrapped
// in :deep(); they also reach the same classes in this template's saves and backup sections.
// Keep the order: the saves-section and backup-button overrides must follow the base rules.

/* Load leads on its own row ... (see the card rules above); the base row is here. */
:deep(.pc-btns) {
  display: flex;
  gap: 0.5em;
  margin-top: 0.15em;
}

:deep(.pc-btns--back) {
  margin-top: auto;
  padding-top: 0.5em;
}

/**
 * `filter: brightness()` measured ~6/255 on these colours — invisible, and hover
 * and pressed were within ~1 level of each other. Each state now changes the
 * colour outright and pressed also moves, so it reads without a comparison shot.
 */
:deep(.pc-btn) {
  flex: 1 1 0;
  border: 0;
  border-radius: 8px;
  padding: 0.4em 0;
  font-size: 0.88em;
  font-weight: 500;
  cursor: pointer;
  transition: background 90ms ease, box-shadow 90ms ease, transform 60ms ease;

  &.focus-visible {
    outline: 2px solid #ff7a1a;
    outline-offset: 2px;
  }

  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
    transform: none;
    box-shadow: none;
  }
}

:deep(.pc-btn--primary) {
  background: linear-gradient(90deg, #ff7a1a, #e85f00);
  color: #fff;

  &:hover:not(:disabled) {
    background: linear-gradient(90deg, #ff9647, #fb7215);
    box-shadow: 0 0 0 1px rgba(255, 168, 102, 0.75);
  }

  &:active:not(:disabled) {
    background: linear-gradient(90deg, #d95f00, #b34c00);
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }
}

:deep(.pc-btn--secondary) {
  background: #374151;
  color: #f3f4f6;

  &:hover:not(:disabled) {
    background: #4d5b6f;
    box-shadow: 0 0 0 1px rgba(148, 163, 184, 0.55);
  }

  &:active:not(:disabled) {
    background: #262f3c;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }
}

:deep(.pc-btn--danger) {
  background: #dc2626;
  color: #fff;

  &:hover:not(:disabled) {
    background: #f04444;
    box-shadow: 0 0 0 1px rgba(248, 113, 113, 0.8);
  }

  &:active:not(:disabled) {
    background: #a41919;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.5);
    transform: translateY(1px);
  }
}

/* Every sub-view opens with the same two lines, so switching between them does
   not feel like landing in an unlabelled box. */
:deep(.pc-section-head) {
  padding-bottom: 0.45em;
  margin-bottom: 0.15em;
  border-bottom: 1px solid #1e2533;
}

:deep(.pc-section-title) {
  font-size: 1.05em;
  font-weight: 800;
  line-height: 1.2;
}

:deep(.pc-section-title--danger) {
  color: #fca5a5;
}

:deep(.pc-section-sub) {
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.45);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

:deep(.pc-manage-section) {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  min-height: 8em;
}

/* BngInput hangs its error 18px below itself with position:absolute. Reserve
   that lane so the message lands in space instead of across the Save button. */
:deep(.pc-manage-section .bng-input) {
  margin-bottom: 1.2em;
}

.pc-saves-section {
  gap: 0.35em;
}

.pc-btns--backup {
  margin-top: 0.5em;
}
</style>
