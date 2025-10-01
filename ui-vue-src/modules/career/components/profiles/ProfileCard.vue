<template>
  <BngCard
    v-bng-scoped-nav="{ activated: isActivated, canActivate, canDeactivate }"
    v-bng-sound-class="'bng_hover_generic'"
    :backgroundImage="preview"
    :footerStyles="cardFooterStyles"
    :hideFooter="!expanded"
    :class="{ 'profile-card-active': active, 'manage-active': isManage, 'profile-outdated': incompatibleVersion }"
    animateFooterDelay="0.1s"
    animateFooterType="slide"
    class="profile-card"
    @activate="onActivated"
    @deactivate="onDeactivated"
    @mouseover="onHover(true)"
    @mouseleave="onHover(false)">
    <div class="profile-card-cover">
      <div class="profile-card-container">
        <div class="profile-card-top">
          <div class="profile-card-title">{{ $ctx_t(id) }}</div>
          <div v-if="!isManage" class="profile-card-date">
            <span v-if="active">{{ $ctx_t("ui.career.nowplaying") }}</span>
            <span v-else>{{ $ctx_t("ui.career.lastplayed") }} {{ lastPlayedDescription }}</span>
          </div>
        </div>
        <div v-if="!isManage && challengeInfo" class="profile-card-challenge">
          <div class="challenge-chip" title="Challenge Mode">
            <span class="chip-sq"></span>
            <span class="chip-text">{{ challengeInfo.name }}</span>
          </div>
        </div>
      </div>
    </div>
    <div class="profile-card-content" v-bng-on-ui-nav:menu,back="goBack">
      <div v-if="isActivated && isManage" class="profile-manage">
        <div v-if="currentMenu === MENU_ITEMS.RENAME" class="profile-manage-rename">
          <BngInput
            v-model="saveName"
            :maxlength="PROFILE_NAME_MAX_LENGTH"
            :validate="validateFn"
            :errorMessage="nameError"
            externalLabel="Save Name"
            @blur="onInputBlur"
            @keydown.enter.prevent />
        </div>
        <div v-else-if="currentMenu === MENU_ITEMS.DELETE" class="profile-manage-delete">
          <span>
            {{ $ctx_t("ui.career.deletePrompt") }}
          </span>
          <BngButton
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-sound-class="'bng_click_generic'"
            :label="$ctx_t('ui.common.yes')"
            accent="attention"
            @click="deleteProfile" />
          <BngButton
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-sound-class="'bng_cancel_generic'"
            :label="$ctx_t('ui.common.no')"
            accent="secondary"
            @click="goBack" />
        </div>
        <div v-else class="profile-manage-main">
          <BngButton
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-sound-class="'bng_click_generic'"
            accent="secondary"
            :label="$ctx_t('ui.career.rename')"
            :disabled="active"
            @click="() => (currentMenu = MENU_ITEMS.RENAME)" />
          <BngButton
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-sound-class="'bng_click_generic'"
            accent="secondary"
            :label="$ctx_t('ui.career.delete')"
            :disabled="active"
            @click="() => (currentMenu = MENU_ITEMS.DELETE)" />
          <BngButton :label="$ctx_t('ui.career.mods')" accent="secondary" disabled />
          <BngButton :label="$ctx_t('ui.career.backup')" accent="secondary" disabled />
        </div>
      </div>

      <ProfileStatus v-else :branches="branches" :expanded="expanded" :beamXP="beamXP" :vouchers="vouchers" :money="money" />
    </div>
    <template #buttons>
      <template v-if="isManage">
        <BngButton
          ref="startButton"
          v-if="currentMenu === MENU_ITEMS.RENAME"
          v-bng-on-ui-nav:ok.asMouse.focusRequired
          v-bng-sound-class="'bng_click_generic'"
          :disabled="nameError !== null || saveName === props.id"
          @click="updateProfileName">
          Save
        </BngButton>
        <BngButton ref="cancelButton" v-bng-on-ui-nav:ok.asMouse.focusRequired v-bng-sound-class="'bng_cancel_generic'" accent="outlined" @click="goBack">
          Back
        </BngButton>
      </template>
      <template v-else>
        <BngButton v-bng-on-ui-nav:ok.asMouse.focusRequired v-bng-sound-class="'bng_click_generic'" accent="outlined" @click="enableManage">Manage </BngButton>
        <BngButton
          v-bng-on-ui-nav:ok.asMouse.focusRequired
          v-bng-sound-class="'bng_click_generic'"
          @click="$emit('load', id)"
          :disabled="active || incompatibleVersion"
          >Load
        </BngButton>
      </template>
    </template>
  </BngCard>
</template>

<script>
const MENU_ITEMS = {
  RENAME: "rename",
  DELETE: "delete",
}
</script>

<script setup>
import { computed, inject, nextTick, ref, onMounted, watch } from "vue"
import { BngButton, BngCard, BngInput } from "@/common/components/base"
import { vBngScopedNav, vBngSoundClass, vBngOnUiNav } from "@/common/directives"
import { timeSpan } from "@/utils/datetime"
import { lua } from "@/bridge"
import { useProfilesStore, PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import ProfileStatus from "./ProfileStatus.vue"
import { setFocus } from "@/services/uiNavFocus"

const store = useProfilesStore()

const props = defineProps({
  id: {
    type: String,
    required: true,
  },
  date: {
    type: String,
    required: true,
  },
  creationDate: {
    type: String,
    required: true,
  },
  incompatibleVersion: Boolean,
  outdatedVersion: {
    type: Boolean,
    required: true,
  },
  preview: {
    type: String,
    default: "/ui/modules/career/profilePreview_WCUSA.jpg",
  },
  beamXP: Object,
  vouchers: Object,
  money: Object,
  active: Boolean,
  branches: Array,
  activeChallenge: Object,
})

const emit = defineEmits(["card:activate", "manage:change", "load"])

const isActivated = ref(false)
const isManage = ref(false)
const currentMenu = ref(null)
const expanded = ref(false)

const validateName = inject("validateName")
const nameError = ref(null)

const startButton = ref(null)
const cancelButton = ref(null)

const lastPlayedDescription = computed(() => timeSpan(props.date))
const cardFooterStyles = {
  background: "rgba(15, 23, 42, 0.6)",
  "backdrop-filter": "blur(8px)",
  "-webkit-backdrop-filter": "blur(8px)",
  "border-top": "1px solid rgba(255,255,255,0.06)",
}

// Challenge badge from profiles (allCareerSaveSlots)
const challengeInfo = computed(() => {
  const v = props.activeChallenge
  if (!v) return null
  if (typeof v === "string") return { name: v }
  return v
})

// TODO: seems hacky but will be updated when input validation has been improved
const validateFn = name => {
  let res = validateName(name)

  // if unedited, don't show error
  if (name === props.id) res = null

  if (!res) {
    nameError.value = null
  } else {
    nameError.value = res
  }

  return !res
}

const canActivate = () => {
  return true
}

const canDeactivate = () => {
  return !isManage.value
}

function onActivated(event) {
  expanded.value = true

  const detail = event.detail
  if (detail.activationType === "full") {
    isActivated.value = true
    emit("card:activate", true)
  }
}

function onDeactivated() {
  expanded.value = false
  isActivated.value = false
  enableManage(false)
  emit("card:activate", false)
}

function onHover(hover) {
  if (isActivated.value) return
  expanded.value = hover
}

function enableManage(enable = true) {
  isManage.value = enable
  emit("manage:change", enable)
}

function goBack() {
  if (currentMenu.value) {
    currentMenu.value = null
  } else {
    enableManage(false)
  }
}

// START Manage Menu
const saveName = ref(props.id)

const deleteProfile = () => {
  lua.career_saveSystem.removeSaveSlot(props.id)
  lua.career_career.sendAllCareerSaveSlotsData()
}

const updateProfileName = async () => {
  await lua.career_saveSystem.renameSaveSlot(props.id, saveName.value)
  await lua.career_career.sendAllCareerSaveSlotsData()
}
// END Manage Menu

function onInputBlur() {
  let focusButton = nameError.value || saveName.value === props.id ? cancelButton : startButton
  if (focusButton.value) nextTick(() => setFocus(focusButton.value.$el))
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.profile-card {
  font-size: calc-ui-rem();
  color: #fff;

  border-radius: calc-ui-rem(1.25) !important;
  overflow: hidden;
  box-shadow: 0 16px 40px rgba(0, 0, 0, 0.45);
  background-color: rgba(15, 23, 42, 0.22);
  transition: transform .18s ease, box-shadow .18s ease;
  backdrop-filter: blur(2px);
  -webkit-backdrop-filter: blur(2px);

  &:hover {
    transform: translateY(-2px);
    box-shadow: 0 20px 48px rgba(0, 0, 0, 0.5);
  }
  :deep(.bng-button) {
    font-size: calc-ui-rem() !important;
    line-height: calc-ui-rem(1.5) !important;
    margin: calc-ui-rem(0.25) !important;
    &, .background {
      border-radius: calc-ui-rem(0.5) !important;
    }
  }
  :deep(.bng-progress-bar) {
    font-size: calc-ui-rem() !important;
  }

  &.profile-card-active {
    :deep() {
      > :last-child {
        border-bottom: 0.3em solid var(--bng-orange-400);
        border-bottom-left-radius: 0;
        border-bottom-right-radius: 0;
      }
    }
  }

  &.manage-active {
    .profile-card-cover {
      flex: 0.5 0.0001 auto;
    }

    .profile-card-content {
      flex: 1 1 auto;
      justify-content: start;
    }
  }

  &.profile-outdated {
    background-color: #808080 !important;
    background-blend-mode: luminosity;
  }
}

.profile-card[disabled="disabled"] {
  pointer-events: none;
}

.profile-card-cover {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  padding: 1.25em 0 0.75em 0;
  flex: 1 0.0001 auto;
  border-radius: var(--bng-corners-1) var(--bng-corners-1) 0 0;
  overflow: hidden;
  color: #fff;
  min-height: 14em;

  &::before {
    content: "";
    position: absolute;
    inset: 0;
    background: linear-gradient(180deg, rgba(0,0,0,0.15) 0%, rgba(0,0,0,0.25) 35%, rgba(0,0,0,0.5) 100%);
    pointer-events: none;
  }
  &::after {
    content: "";
    position: absolute;
    inset: 0;
    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06);
    border-radius: inherit;
    pointer-events: none;
  }

  > .profile-card-container {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    padding: 0.25em 0 0.75em 0;
    max-width: 100%;
    align-items: flex-start;
    font-family: "Overpass", var(--fnt-defs);
    z-index: 1;

    > .profile-card-top {
      display: flex;
      flex-direction: column;
      gap: 0.35em;
      max-width: 88%;
      margin-left: 0;
      margin-top: 0.75em;
      padding: 0.75em 1em;
      background: rgba(15, 23, 42, 0.6);
      backdrop-filter: blur(6px);
      -webkit-backdrop-filter: blur(6px);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 16px;
      border-top-left-radius: 0;
      border-bottom-left-radius: 0;
      box-shadow: 0 8px 18px rgba(0,0,0,0.35);
    }

    > .profile-card-top > .profile-card-title {
      display: -webkit-box;
      -webkit-line-clamp: 3;
      line-clamp: 3;
      -webkit-box-orient: vertical;
      max-width: 100%;
      font-weight: 1000;
      font-size: 2.25em;
      letter-spacing: 0.02em;
      line-height: 1.2em;
      padding: 0;
      background: transparent;
      border: 0;
      border-radius: 0;
      font-family: "Overpass", var(--fnt-defs);
      overflow: hidden;
    }

    > .profile-card-challenge {
      padding: 0 0.6em 0.2em 0.6em;
    }

    .challenge-chip {
      display: inline-flex;
      align-items: center;
      gap: 0.45em;
      padding: 0.25em 0.7em;
      background-image: linear-gradient(90deg, #ff7a1a, #e85f00);
      border: 0;
      border-radius: 12px;
      box-shadow: 0 6px 12px rgba(0,0,0,0.28);
      font-size: 0.92em;
      font-weight: 800;
      color: #ffffff;
    }
    .chip-sq {
      width: 10px;
      height: 10px;
      border-radius: 3px;
      background: rgba(255,255,255,0.9);
      box-shadow: inset 0 0 0 1px rgba(0,0,0,0.1);
    }
    .chip-text { white-space: nowrap; color: inherit; }

    > .profile-card-date {
      letter-spacing: 0.02em;
      line-height: 1.3em;
      padding: 0;
      background: transparent;
      border: 0;
      border-radius: 0;
      opacity: 0.95;
    }
  }
}

.profile-card-content {
  display: flex;
  flex: 0.0001 1 auto;
  flex-flow: column;
  justify-content: space-between;
  align-items: stretch;
  // padding: 0 1em 1em;
  overflow: hidden;
  background: linear-gradient(180deg, rgba(15, 23, 42, 0.7), rgba(15, 23, 42, 0.85));
}

.profile-manage {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  justify-content: space-between;
  align-items: stretch;
  min-height: 12.5em;
  padding: 1em 0 1em 1em;
  color: #fff;
  background: rgba(15, 23, 42, 0.9);
  border-top: 1px solid rgba(255,255,255,0.06);

  > .profile-manage-main {
    display: flex;
    flex-direction: column;
  }

  > .profile-manage-delete {
    display: flex;
    flex-direction: column;
  }

  > .profile-manage-rename {
    margin-right: calc-ui-rem(0.75);
  }
}
</style>
