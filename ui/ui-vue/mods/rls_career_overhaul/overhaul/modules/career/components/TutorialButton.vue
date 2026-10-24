<template>
  <BngButton
    ref="buttonRef"
    v-bng-popover:right="!text ? popoverName : null"
    :class="{blink : !seen}"
    :icon="icon"
    class="tut-btn"
    v-bng-on-ui-nav:[binding].focusRequired="bindingHandler"
    @click.stop="clickHandler"
    >
    <span v-if="text">{{ text }}</span>
  </BngButton>
  <BngPopoverContent
    v-if="!text"
    :name="popoverName"
    :placement="popoverPlacement"
  >
    <div class="tut-popover">
      <BngBinding
        v-if="binding"
        :ui-event="binding"
        controller
        class="tut-popover-binding"
      />
      <span>{{ $t("ui.career.tutorialButton.viewSectionTooltip") }}</span>
    </div>
  </BngPopoverContent>
</template>

<script setup>
import { ref, computed } from "vue"
import { BngBinding, BngButton, BngPopoverContent, icons } from "@/common/components/base"
import { vBngPopover } from "@/common/directives"
import { uniqueId } from "@/services/uniqueId"
import { usePopover } from "@/services/popover"
import { lua } from "@/bridge"

const popover = usePopover()
const buttonRef = ref(null)
const popoverName = uniqueId("tutorial-button")
const popoverPlacement = "right"

const props = defineProps({
  text: {
    type: String,
    default: ''
  },
  icon: {
    type: Object,
    default: () => icons.questionmark
  },
  pages: {
    type: Array,
    default: () => [],
  },
  binding: {
    type: String,
    default: undefined,
  },
  bindingDisplayOnly: Boolean,
})

const seen = ref(true)
const bindingHandler = computed(() => {
  if (!props.binding || props.bindingDisplayOnly) return null
  return () => clickHandler()
})

function clickHandler() {
  for(let key of props.pages){
    lua.overhaul_career_guide_tutorialPopups.introPopup(key, true)
  }
  seen.value = true
}

function showPopover() {
  if (props.text) return
  const el = buttonRef.value?.getElement?.()
  if (!el) return
  popover.show(popoverName, el, { placement: popoverPlacement })
}

function hidePopover() {
  if (props.text) return
  popover.hide(popoverName)
}

function isPopoverShown() {
  return !props.text && popover.isShown(popoverName)
}

defineExpose({ showPopover, hidePopover, isPopoverShown, openTutorial: clickHandler })
</script>

<style scoped lang="scss">
.tut-btn {
  min-width: unset !important;
  :deep(.icon) {
    padding-right: 0 !important;
  }
}

@keyframes blink {
  from { color:white; }
  to { color:orange }
}

.blink {
  animation: blink 1s linear infinite;
}

.tut-popover {
  display: flex;
  align-items: center;
  gap: 0.25em;
  padding: 0.25em;
}

.tut-popover-binding {
  display: inline-flex;
  align-items: center;
  flex-shrink: 0;
}

</style>
