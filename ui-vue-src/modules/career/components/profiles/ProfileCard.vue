<template>
  <div
    v-bng-scoped-nav="{ canDeactivate, canBubbleEvent }"
    v-bng-sound-class="'bng_hover_generic'"
    :class="['pc', { 'pc--active': active, 'pc--outdated': incompatibleVersion, 'pc--manage': isManage, 'pc--hover': hovered }]"
    @activate="onScopeChanged(true)"
    @deactivate="onScopeChanged(false)"
    @mouseover="hovered = true"
    @mouseleave="hovered = false">

    <div class="pc-image" :style="bgStyle">
      <div class="pc-image-overlay" />

      <div class="pc-header">
        <div class="pc-name">{{ id }}</div>
        <div v-if="active" class="pc-playing">{{ $ctx_t("ui.career.nowplaying") }}</div>
        <div v-else class="pc-last-played">{{ lastPlayedDescription }}</div>
      </div>

      <div v-if="!isManage && (modeChipLabel || cheatsMode)" class="pc-badges">
        <span v-if="modeChipLabel" class="pc-chip pc-chip--challenge">{{ modeChipLabel }}</span>
        <span v-if="cheatsMode" class="pc-chip pc-chip--cheats">Freeroam+</span>
      </div>
    </div>

    <div :class="['pc-drawer', { 'pc-drawer--open': showBody }]">
      <div ref="bodyRef" class="pc-body" v-bng-on-ui-nav:menu,back="goBack">
          <div v-if="backupStep === 'name'" class="pc-backup-section">
            <label class="pc-backup-label">Backup name</label>
            <div :class="['pc-backup-input-wrap', { 'pc-backup-input-wrap--error': backupNameError }]">
              <input
                v-bng-text-input
                :value="backupName"
                :maxlength="PROFILE_NAME_MAX_LENGTH"
                class="pc-backup-input"
                @input="onBackupInput"
                @focus="onBackupInputFocus"
                @blur="onBackupInputBlur"
                @keydown.enter.prevent="onBackupEnter" />
            </div>
            <span v-if="backupNameError" class="pc-backup-error">{{ backupNameError }}</span>
            <div class="pc-btns pc-btns--backup">
              <button ref="backupCancelBtn" class="pc-btn pc-btn--secondary" type="button" @click="cancelBackup">Cancel</button>
              <button
                ref="backupCreateBtn"
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--primary"
                type="button"
                :disabled="!!backupNameError || !backupName.trim()"
                @click="confirmBackup">Create</button>
            </div>
          </div>
          <div v-else-if="backupStep === 'loading'" class="pc-backup-feedback">
            <div class="pc-backup-spinner" />
          </div>
          <div v-else-if="backupStep === 'success'" class="pc-backup-feedback pc-backup-feedback--success">
            Backup created
          </div>
          <div v-else-if="isManage && currentMenu === MENU_ITEMS.RENAME" class="pc-manage-section">
            <BngInput
              v-model="saveName"
              :maxlength="PROFILE_NAME_MAX_LENGTH"
              :validate="validateFn"
              :errorMessage="nameError"
              externalLabel="Save Name"
              @blur="onInputBlur"
              @keydown.enter.prevent />
            <div class="pc-btns">
              <button ref="startButton" class="pc-btn pc-btn--primary" :disabled="nameError !== null || saveName === id" @click="updateProfileName">Save</button>
              <button ref="cancelButton" class="pc-btn pc-btn--secondary" @click="goBack">Back</button>
            </div>
          </div>
          <div v-else-if="isManage && currentMenu === MENU_ITEMS.DELETE" class="pc-manage-section">
            <span class="pc-delete-prompt">{{ $ctx_t("ui.career.deletePrompt") }}</span>
            <div class="pc-btns">
              <button class="pc-btn pc-btn--danger" @click="deleteProfile">{{ $ctx_t("ui.common.yes") }}</button>
              <button class="pc-btn pc-btn--secondary" @click="goBack">{{ $ctx_t("ui.common.no") }}</button>
            </div>
          </div>
          <div v-else-if="isManage" class="pc-manage-section">
            <button class="pc-btn pc-btn--secondary" :disabled="active" @click="() => (currentMenu = MENU_ITEMS.RENAME)">{{ $ctx_t("ui.career.rename") }}</button>
            <button class="pc-btn pc-btn--secondary" :disabled="active" @click="() => (currentMenu = MENU_ITEMS.DELETE)">{{ $ctx_t("ui.career.delete") }}</button>
            <button
              v-bng-sound-class="'bng_click_generic'"
              class="pc-btn pc-btn--secondary"
              :disabled="incompatibleVersion"
              @click="startBackup">Backup</button>
            <div class="pc-btns pc-btns--back">
              <button class="pc-btn pc-btn--secondary" @click="goBack">Back</button>
            </div>
          </div>
          <div v-else class="pc-status-section">
            <div class="pc-money">
              <BngUnit :money="money?.value || 0" :formatter="moneyFormatter" />
            </div>

            <div v-if="topSkills.length" class="pc-skills">
              <div v-for="sk in topSkills" :key="sk.id" class="pc-skill">
                <BngIcon :type="sk.icon" class="pc-skill-icon" />
                <span class="pc-skill-name">{{ sk.label }}</span>
                <span class="pc-skill-lvl">{{ $ctx_t(sk.levelLabel) }}</span>
              </div>
            </div>

            <div class="pc-btns">
              <button
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--secondary"
                @click="enableManage">Manage</button>
              <button
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--primary"
                :disabled="active || incompatibleVersion"
                @click="$emit('load', id)">Load</button>
            </div>
          </div>
      </div>
    </div>

    <div v-if="active" class="pc-active-bar" />
  </div>
</template>

<script>
const MENU_ITEMS = {
  RENAME: "rename",
  DELETE: "delete",
}
</script>

<script setup>
import { computed, inject, nextTick, ref, watch } from "vue"
import { BngButton, BngInput, BngIcon, BngUnit } from "@/common/components/base"
import { vBngScopedNav, vBngSoundClass, vBngOnUiNav, vBngTextInput } from "@/common/directives"
import { timeSpan } from "@/utils/datetime"
import { shrinkNum } from "@/utils/format"
import { lua } from "@/bridge"
import { PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { setFocus } from "@/services/uiNavFocus"

const props = defineProps({
  id: { type: String, required: true },
  date: { type: String, required: true },
  creationDate: { type: String, required: true },
  incompatibleVersion: Boolean,
  outdatedVersion: { type: Boolean, required: true },
  preview: { type: String, default: "/ui/modules/career/profilePreview_WCUSA.jpg" },
  beamXP: Object,
  vouchers: Object,
  money: Object,
  active: Boolean,
  branches: Array,
  freSkills: { type: Array, default: () => [] },
  activeChallenge: [Object, String],
  difficultyMode: String,
  cheatsMode: Boolean,
  forceCloseManage: Boolean,
})

const emit = defineEmits(["card:activate", "manage:change", "backup:change", "load"])

const hovered = ref(false)
const isManage = ref(false)
const currentMenu = ref(null)
const backupStep = ref(null)
const backupName = ref("")
const backupNameError = ref(null)
const backupCancelBtn = ref(null)
const backupCreateBtn = ref(null)

watch(() => props.forceCloseManage, (shouldClose) => {
  if (shouldClose && isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("card:activate", false)
    emit("manage:change", false)
  }
  if (shouldClose && backupStep.value) {
    if (backupStep.value === "loading") return
    backupStep.value = null
    backupName.value = ""
    backupNameError.value = null
    emit("backup:change", false)
    if (!isManage.value) emit("card:activate", false)
  }
})

const validateName = inject("validateName")
const nameError = ref(null)
const bodyRef = ref(null)
const startButton = ref(null)
const cancelButton = ref(null)

const bgStyle = computed(() => ({
  backgroundImage: `url(${props.preview})`,
}))

const lastPlayedDescription = computed(() => timeSpan(props.date))

const formatterFn = num => shrinkNum(num, 1)
const moneyFormatter = computed(() => (props.money?.value > 100000 ? formatterFn : undefined))

const showBody = computed(() => hovered.value || isManage.value || !!backupStep.value)

const activeView = computed(() => {
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
  if (!el || !showBody.value) return
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

const topSkills = computed(() => {
  const list = props.freSkills
  if (!list || !list.length) return []
  return [...list]
    .sort((a, b) => {
      const ld = (Number(b.level) || 0) - (Number(a.level) || 0)
      if (ld !== 0) return ld
      return (Number(b.value) || 0) - (Number(a.value) || 0)
    })
    .slice(0, 3)
})

const challengeInfo = computed(() => {
  const v = props.activeChallenge
  if (!v) return null
  return typeof v === "string" ? { name: v } : v
})

const DIFFICULTY_MODE_LABELS = { easy: "Casual", hard: "Hard", hardcore: "Hardcore" }
const difficultyChipLabel = computed(() => {
  const mode = typeof props.difficultyMode === "string" ? props.difficultyMode.toLowerCase() : "normal"
  return mode === "normal" ? null : (DIFFICULTY_MODE_LABELS[mode] || mode)
})
const modeChipLabel = computed(() => challengeInfo.value?.name || difficultyChipLabel.value)

const validateFn = name => {
  let res = validateName(name)
  if (name === props.id) res = null
  nameError.value = res || null
  return !res
}

const canDeactivate = () => !isManage.value && backupStep.value !== "loading"
const canBubbleEvent = e => e.detail.name === "menu" && !isManage.value && !backupStep.value

const onScopeChanged = value => {
  if (!value && isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("manage:change", false)
  }
  if (!value && backupStep.value && backupStep.value !== "loading") {
    cancelBackup()
  }
}

function enableManage() {
  isManage.value = true
  emit("card:activate", true)
  emit("manage:change", true)
}

function goBack() {
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
  }
}

function validateBackupName(name) {
  const res = validateName(name)
  backupNameError.value = res || null
  return !res
}

function onBackupInputFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}

function onBackupInputBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
}

function onBackupInput(e) {
  backupName.value = e.target.value
  validateBackupName(backupName.value)
}

function onBackupEnter() {
  const focusEl = backupNameError.value || !backupName.value.trim() ? backupCancelBtn : backupCreateBtn
  if (focusEl.value) nextTick(() => setFocus(focusEl.value))
}

function startBackup() {
  if (isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("manage:change", false)
  }
  backupName.value = ""
  backupNameError.value = null
  backupStep.value = "name"
  emit("card:activate", true)
  emit("backup:change", true)
}

function cancelBackup() {
  if (backupStep.value === "loading") return
  backupStep.value = null
  backupName.value = ""
  backupNameError.value = null
  emit("backup:change", false)
  if (!isManage.value) emit("card:activate", false)
}

async function confirmBackup() {
  if (!validateBackupName(backupName.value) || backupNameError.value) return
  const trimmed = backupName.value.trim()
  backupStep.value = "loading"
  try {
    const ok = await lua.career_saveSystem.duplicateSaveSlot(props.id, trimmed)
    if (ok) {
      await lua.career_career.sendAllCareerSaveSlotsData()
      backupStep.value = "success"
      emit("backup:change", false)
      window.setTimeout(() => {
        backupStep.value = null
        backupName.value = ""
      }, 1500)
    } else {
      backupStep.value = "name"
      backupNameError.value = "Backup failed"
    }
  } catch (_) {
    backupStep.value = "name"
    backupNameError.value = "Backup failed"
  }
}

const saveName = ref(props.id)
const deleteProfile = () => {
  lua.career_saveSystem.removeSaveSlot(props.id)
  lua.career_career.sendAllCareerSaveSlotsData()
}
const updateProfileName = async () => {
  await lua.career_saveSystem.renameSaveSlot(props.id, saveName.value)
  await lua.career_career.sendAllCareerSaveSlotsData()
}

function onInputBlur() {
  let focusButton = nameError.value || saveName.value === props.id ? cancelButton : startButton
  if (focusButton.value) nextTick(() => setFocus(focusButton.value))
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

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

  transition: transform 0.22s ease-out;

  &.pc--outdated {
    filter: grayscale(0.7);
    opacity: 0.7;
  }
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

.pc-badges {
  position: relative;
  z-index: 1;
  display: flex;
  gap: 0.35em;
  padding: 0 1em 0.6em;
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

.pc-body {
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: hidden;
  padding: 0.55em 0.7em 0.65em;
  background: #0b0f19;
}

.pc-money {
  display: flex;
  justify-content: flex-end;
  font-weight: 700;
  font-size: 1.05em;
  padding-bottom: 0.4em;
  border-bottom: 1px solid #1e2533;
  margin-bottom: 0.35em;
}

.pc-skills {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  margin-bottom: 0.5em;
}

.pc-skill {
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding: 0.2em 0;

  .pc-skill-icon {
    flex: 0 0 auto;
    font-size: 1.15em;
    opacity: 0.85;
  }

  .pc-skill-name {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 600;
    font-size: 0.82em;
  }

  .pc-skill-lvl {
    flex: 0 0 auto;
    font-size: 0.72em;
    font-weight: 700;
    opacity: 0.6;
  }
}

.pc-btns {
  display: flex;
  gap: 0.5em;
  margin-top: 0.15em;
}

.pc-btns--back {
  margin-top: auto;
  padding-top: 0.5em;
}

.pc-btn {
  flex: 1 1 0;
  border: 0;
  border-radius: 8px;
  padding: 0.4em 0;
  font-size: 0.88em;
  font-weight: 500;
  cursor: pointer;

  &:hover { filter: brightness(1.1); }
  &:active { filter: brightness(0.95); }
  &:disabled { opacity: 0.4; cursor: not-allowed; filter: none; }
}

.pc-btn--primary {
  background: linear-gradient(90deg, #ff7a1a, #e85f00);
  color: #fff;
}

.pc-btn--secondary {
  background: #374151;
  color: #f3f4f6;
}

.pc-btn--danger {
  background: #dc2626;
  color: #fff;
}

.pc-manage-section {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  min-height: 8em;
}

.pc-delete-prompt {
  font-size: 0.88em;
  padding: 0.5em 0;
}

.pc-btns--backup {
  margin-top: 0.5em;
}

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

.pc-active-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 0.25em;
  background: var(--bng-orange-400, #fb923c);
  z-index: 5;
}

</style>
