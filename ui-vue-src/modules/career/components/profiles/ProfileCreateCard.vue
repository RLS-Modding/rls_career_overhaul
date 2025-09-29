<template>
  <BngCard
    v-bng-scoped-nav="{ activated: isActive }"
    v-bng-blur
    v-bng-sound-class="'bng_hover_generic'"
    :hideFooter="!isActive"
    :footerStyles="cardFooterStyles"
    class="profile-create-card"
    @activate="onActivated"
    @deactivate="onDeactivated">
    <div :class="{ 'create-active': isActive }" class="create-content-container">
      <template v-if="isActive">
        <BngInput
          v-model="profileName"
          :maxlength="PROFILE_NAME_MAX_LENGTH"
          :validate="validateFn"
          :errorMessage="nameError"
          externalLabel="Save Name"
          @keydown.enter="onEnter" />
        <BngSwitch v-model="hardcoreMode" label-before :inline="false"> Hardcore Mode </BngSwitch>
        <BngSwitch v-model="tutorialChecked" label-before :inline="false" :label-alignment="LABEL_ALIGNMENTS.START">{{
          $ctx_t("ui.career.tutorialCheckDesc")
        }}</BngSwitch>
        <span class="tutorial-desc" :class="{ checked: tutorialChecked }">{{ $ctx_t("ui.career.tutorialOnDesc") }}</span>
      </template>
      <div v-else class="create-content-cover" @click="setActive(true)">
        <div class="cover-plus-container">
          <div class="cover-plus-button">+</div>
        </div>
      </div>
    </div>
    <template #buttons>
      <BngButton ref="startButton" v-bng-on-ui-nav:ok.asMouse.focusRequired :disabled="nameError !== null" @click="load">Start</BngButton>
      <BngButton ref="cancelButton" v-bng-on-ui-nav:ok.asMouse.focusRequired accent="outlined" @click="setActive(false)">Cancel</BngButton>
    </template>
  </BngCard>
</template>

<script>
const cardFooterStyles = {
  "background-color": "hsla(217, 22%, 12%, 1)",
}
</script>

<script setup>
import { inject, nextTick, ref } from "vue"
import { vBngOnUiNav, vBngScopedNav, vBngBlur, vBngSoundClass } from "@/common/directives"
import { BngButton, BngCard, BngInput, BngSwitch, LABEL_ALIGNMENTS } from "@/common/components/base"
import { PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { setFocus } from "@/services/uiNavFocus"

const emit = defineEmits(["card:activate", "load"])

const profileName = defineModel("profileName", { required: true })
const hardcoreMode = ref(false)
const tutorialChecked = ref(true)
const isActive = ref(false)

const validateName = inject("validateName")
const nameError = ref(null)

const startButton = ref(null)
const cancelButton = ref(null)

// TODO: seems hacky but will be updated when input validation has been improved
const validateFn = name => {
  const res = validateName(name)
  if (!res) {
    nameError.value = null
  } else {
    nameError.value = res
  }

  return !res
}

const load = () => emit("load", profileName.value, tutorialChecked.value, hardcoreMode.value)

function onActivated(event) {
  const data = event.detail
  if (data.activationType === "full") {
    setActive(true)
  }
}

function onDeactivated(event) {
  setActive(false)
}

function setActive(value) {
  isActive.value = value
  emit("card:activate", value)
}

function onEnter(event) {
  event.preventDefault()
  const focusButton = nameError.value ? cancelButton : startButton
  if (focusButton.value) nextTick(() => setFocus(focusButton.value.$el))
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.profile-create-card {
  font-size: calc-ui-rem();
  color: white;

  // temp
  :deep(.card-cnt) {
    border-radius: calc-ui-rem(0.5) !important;
  }
  :deep(.bng-button) {
    font-size: calc-ui-rem() !important;
    line-height: calc-ui-rem(1.5) !important;
    margin: calc-ui-rem(0.25) !important;
    &, .background {
      border-radius: calc-ui-rem(0.25) !important;
    }
  }
}

.create-content-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  padding: 0.75em 1em;

  > * {
    margin-bottom: 1.5em;
  }

  &.create-active {
    background: hsla(217, 22%, 12%, 1);
  }
}

.create-content-cover {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  justify-content: center;
  padding: 1em 0;
  flex: 1 0.0001 auto;
  border-radius: var(--bng-corners-1) var(--bng-corners-1) 0 0;
  overflow: hidden;

  > .cover-plus-container {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 100%;
    height: 100%;

    > .cover-plus-button {
      font-weight: 400;
      font-size: 13em;
      line-height: 1em;
      background-color: transparent;
      flex: 0 0 auto;
      text-align: center;
      color: rgba(255, 255, 255, 0.2);
    }
  }
}

.tutorial-desc {
  padding-top: 1.5em;
  text-align: left;
  color: var(--bng-cool-gray-400);
  margin-top: auto;
  padding-top: 0;

  &.checked {
    color: #fff !important;
  }
}
</style>
