<template>
  <div class="mainCategories">
    <!-- autofocus only while this panel shows: the panels stay mounted (v-show) and the scope takes the
         first autofocus mark in the DOM, so a hidden one would block the slot / part lists' own marks.
         In the tutorial "All parts" is disabled, so the pad starts on Cargo. -->
    <Button class="computer-function-tile"
      :bng-scoped-nav-autofocus="partShoppingStore.activePanel === 'categories' && !tutorialActive ? true : undefined"
      :disabled="tutorialActive"
      @click="openCategory('everything')"
    >
      <BngIcon class="icon" :type="icons.doorFrontCoins" />
      <span class="label">{{ $translate.instant("ui.career.partShopping.allParts") }}</span>
    </Button>
    <Button class="computer-function-tile"
      :bng-scoped-nav-autofocus="partShoppingStore.activePanel === 'categories' && tutorialActive ? true : undefined"
      @click="openCategory('cargo')"
    >
      <BngIcon class="icon" :type="icons.boxPickUp03" />
      <span class="label">{{ $translate.instant("ui.career.partShopping.cargoParts") }}</span>
    </Button>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { lua } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { Button } from "@/common/components/utility"
import { usePartShoppingStore } from "../../stores/partShoppingStore"
import { $translate } from "@/services/translation"

const partShoppingStore = usePartShoppingStore()
const tutorialActive = computed(() => partShoppingStore.partShoppingData?.tutorialPartNames !== undefined)
defineProps({
  cancel: Function,
})

const openCategory = category =>
  lua.extensions.ui_router.navigate("overhaul.computer.partShopping.category", { category })
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
// House tokens (--panel, --radius-*) come from the .rls-house panel in PartShoppingMain.
.mainCategories {
  display: flex;
  flex-direction: column;
  gap: var(--space-2, 0.5em);
  padding: 0.35em var(--inset, 0.85em) var(--inset, 0.85em);
}

.mainCategories .computer-function-tile {
  --bng-content-flow: row;
  --bng-content-align: center;
  --bng-content-justify: flex-start;
  --bng-button-min-width: 100%;
  --bng-button-max-width: 100%;
  --bng-button-margin: 0;
  --bng-button-padding: 0.6em 0.75em;
  --bng-button-padding-top: 0.6em;
  --bng-button-padding-bottom: 0.6em;
  --bng-bg-border-radius: var(--radius-panel, 0.5em);
  --bng-bg-border-width: 0;
  --bng-bg-enabled: var(--panel, rgba(255, 255, 255, 0.06));
  --bng-bg-hover: var(--panel-2, rgba(255, 255, 255, 0.1));
  --bng-bg-active: var(--panel-hover, rgba(255, 255, 255, 0.18));
  --bng-bg-focus: var(--panel-2, rgba(255, 255, 255, 0.1));
  --bng-bg-disabled: var(--panel, rgba(255, 255, 255, 0.06));
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-focus-opacity: 1;
  --bng-bg-disabled-opacity: 1;
  --bng-bg-border-enabled: transparent;
  --bng-bg-border-hover: transparent;
  --bng-bg-border-active: transparent;
  --bng-bg-border-focus: transparent;
  --bng-bg-border-disabled: transparent;
  --bng-icon-color: currentColor;

  gap: 0.75em;
  font-family: "Overpass", var(--fnt-defs);
  position: relative;
  // controller / keyboard focus: the house ring (from the .rls-house panel) instead of the game frame
  &.focus-visible {
    outline: none;
    box-shadow: var(--focus, 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px #ff6600);
  }
  &.focus-visible::before {
    display: none !important;
  }

  // Plain glyph, no badge behind it (same as the computer home tiles).
  .icon {
    flex: 0 0 auto;
    width: 1.3em;
    font-size: 1.4em;
    text-align: center;
    color: var(--faint, rgba(255, 255, 255, 0.55));
    transition: color 120ms ease;
  }
  &:hover .icon,
  &:focus .icon {
    color: #fff;
  }
  .label {
    flex: 1 1 auto;
    font-size: 1.15em;
    font-weight: 700;
    line-height: 1.2;
    text-align: left;
  }
}
</style>
