<template>
  <div v-bng-scoped-nav="{ activated: isActivated }" class="profiles-container" @deactivate="onDeactivate">
    <BngScreenHeading class="profiles-title" :preheadings="[$ctx_t('ui.playmodes.career')]">{{ $ctx_t("ui.career.savedProgress") }} </BngScreenHeading>
    <BackAside class="profiles-back" @click="onDeactivate()" />
    <BngList :layout="LIST_LAYOUTS.RIBBON" :targetWidth="22" :targetHeight="28" :targetMargin="1" noBackground>
      <ProfileCreateCard v-model:profileName="newProfileName" class="profile-card" @card:activate="value => onCardActivated(value, -1)" @load="onCreateSave" />
      <ProfileCard
        v-for="(profile, index) of profiles"
        v-bng-popover="profile.incompatibleVersion ? 'tooltip-outdated-message' : null"
        v-bind="profile"
        v-bng-disabled="(isManage || selectedCard === -1) && selectedCard !== index"
        :key="profile.id"
        :active="activeProfileId === profile.id"
        class="profile-card"
        @card:activate="value => onCardActivated(value, index)"
        @manage:change="value => onManageChange(value, index)"
        @load="onLoad" />
    </BngList>
  </div>
  <BngPopoverContent name="tooltip-outdated-message">
    <template #default>
      <div class="tooltip-outdated-message">This profile was saved with an old version of the game. It can no longer be loaded.</div>
    </template>
  </BngPopoverContent>
</template>

<script setup>
import { onBeforeUnmount, onMounted, provide, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { $translate } from "@/services"
import { vBngDisabled, vBngPopover, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { BngList, BngPopoverContent, BngScreenHeading, LIST_LAYOUTS } from "@/common/components/base"
import BackAside from "../../mainmenu/components/BackAside.vue"
import ProfileCard from "../components/profiles/ProfileCard.vue"
import ProfileCreateCard from "../components/profiles/ProfileCreateCard.vue"
import { useProfilesStore, PROFILE_NAME_MAX_LENGTH } from "../stores/profilesStore"

const store = useProfilesStore()
const { events } = useBridge()

const profiles = ref(null)
const activeProfileId = ref(null)

// screen scoped nav. should be automatically activated when the screen is loaded
const isActivated = ref(true)

const selectedCard = ref(null)
const isManage = ref(false)
const newProfileName = ref(null)

let isLoading = false

const onLoad = async id => {
  isLoading = true
  await store.loadProfile(id)
}

const onCreateSave = async (profileName, tutorialChecked, hardcoreMode) => {
  isLoading = true
  await store.loadProfile(profileName, tutorialChecked, true, hardcoreMode)
}

function onCardActivated(active, index) {
  if (active) {
    selectedCard.value = index
    if (index === -1) newProfileName.value = getNewName()
  } else {
    selectedCard.value = null
  }
}

function onManageChange(active, index) {
  isManage.value = active
}

onMounted(() => {
  events.on("allCareerSaveSlots", onProfilesReceived)
  lua.career_career.sendAllCareerSaveSlotsData()
})

onBeforeUnmount(() => {
  events.off("allCareerSaveSlots", onProfilesReceived)
})

provide("validateName", validateName)

function onDeactivate() {
  // if (store.isLoading) return

  if (isLoading) {
    isLoading = false
  } else if (activeProfileId.value) {
    window.bngVue.gotoAngularState("menu.careerPause")
  } else {
    window.bngVue.gotoGameState("menu.mainmenu")
  }
}

async function onProfilesReceived(data) {
  selectedCard.value = null
  activeProfileId.value = null

  profiles.value = data && data.length > 0 ? await updateActiveProfile(data) : null
}

async function updateActiveProfile(data) {
  const currentSave = await lua.career_career.sendCurrentSaveSlotData()
  data.sort((a, b) => new Date(b.date) - new Date(a.date))

  if (currentSave) {
    activeProfileId.value = currentSave.id
    let current = data.find(x => x.id === currentSave.id)

    // if currentSave is not in the returned profiles data yet,
    // because it may not have been saved yet or needs manual saving
    if (!current) current = currentSave

    data = data.filter(x => x.id !== currentSave.id)
    data.splice(0, 0, current)
  }

  return data
}

function validateName(newName) {
  // empty
  if (!newName) return "Save name cannot be empty"

  // too long
  if (newName.length > PROFILE_NAME_MAX_LENGTH) return "Save name cannot be longer than 100 characters"

  // invalid characters
  const invalidChars = /[<>:"/\\|?*]/
  if (invalidChars.test(newName)) return "Save name cannot contain invalid characters"

  // duplicate
  if (profiles.value && profiles.value.find(profile => profile.id.toLowerCase() === newName.toLowerCase())) return "Save name already exists"

  return null
}

function getNewName() {
  const prefix = $translate.contextTranslate("ui.career.profile")
  let id
  for (let i = 1; i < 1e3; i++) {
    id = `${prefix} ${i}`
    if (!profiles.value || !profiles.value.find(profile => profile.id === id)) break
  }
  return id
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.profiles-container {
  font-size: calc-ui-rem();
  margin: auto calc-ui-rem(6);

  // temp
  .profiles-title {
    font-size: calc-ui-rem() !important;
    :deep(.header) {
      padding: calc-ui-rem(0.5) calc-ui-rem(0.75) calc-ui-rem(0.5) calc-ui-rem(0.5) !important;
    }
  }
}

.profiles-title {
  position: absolute;
  top: calc-ui-rem(-6);
  left: calc-ui-rem(-4);
}

.profiles-back {
  top: calc-ui-rem() !important;
  bottom: calc-ui-rem() !important;
}

.profile-card {
  height: calc-ui-rem(28);
  width: calc-ui-rem(22);
}

.tooltip-outdated-message {
  padding: calc-ui-rem(0.5);
  max-width: calc-ui-rem(16);
}
</style>
