<template>
  <BngCard v-bng-scoped-nav="popupScopeBinding" v-bng-on-ui-nav:back,menu="cancel" class="selling-card rls-house">
    <BngCardHeading>{{ $translate.instant("ui.career.partInventory.sellParts") }}</BngCardHeading>
    <div class="selling-card-content">
      <div class="select-buttons">
        <span class="select-label">{{ $translate.instant("ui.career.partInventory.select") }}</span>
        <div class="select-row">
          <HouseButton compact @click="selectAll(true)">{{ $translate.instant("ui.common.all") }}</HouseButton>
          <HouseButton compact @click="selectAll(false)">{{ $translate.instant("ui.common.none") }}</HouseButton>
        </div>
      </div>
      <!-- no nested scope: the rows are plain items of the popup's own scope, so the d-pad walks straight
           into them (a nested scope inside a popup never activated: the pad could not reach the rows) -->
      <div class="partList">
        <div v-bng-ui-nav-scroll.force class="partList-scroll scroll">
          <div
            v-for="(part, index) in parts"
            :key="part.data.id"
            class="part-item"
            :class="partsChecked[index] ? 'part-selected' : ''"
            bng-nav-item
            tabindex="0"
            @click="partsChecked[index] = !partsChecked[index]">
            <BngIcon class="selectionCheckbox" :type="partsChecked[index] ? icons.checkboxOn : icons.checkboxOff" />
            <div class="part-info-col">
              <div>
                <span class="part-name">{{ part.name }}</span>
              </div>
              <div class="part-info-row">
                <span class="right meta-value"><BngPropVal :iconType="icons.beamCurrency" :valueLabel="part.valueFormatted" /></span>
                <span class="right">{{ part.mileage }}</span>
                <span class="center">{{ part.model }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="popup-buttons">
        <HouseButton
          variant="quiet"
          @click="cancel">{{ $translate.instant("ui.common.cancel") }}</HouseButton>
        <HouseButton
          class="sell-button"
          variant="primary"
          :disabled="saleData.numberOfSelected <= 0"
          v-bng-on-ui-nav:ok.asMouse.focusRequired
          v-bng-click="{
            holdCallback: sellSelectedParts,
            holdDelay: 1000,
            repeatInterval: 0,
          }">
          {{ $translate.instant("ui.career.partInventory.sellSelectedParts", { count: saleData.numberOfSelected }) }} <BngUnit :money="saleData.price" />
        </HouseButton>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { lua } from "@/bridge"
import { ref, computed, onMounted, useAttrs } from "vue"
import { vBngClick } from "@/common/directives"
import { BngCard, BngUnit, BngPropVal, BngIcon, icons, BngCardHeading} from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"

const partsChecked = ref([])
const emit = defineEmits(["return"])

const props = defineProps({
  parts: {
    type: Array,
    default: () => [],
  },
  popupActive: Boolean,
})

const attrs = useAttrs()
const scopeName = `_partSellingPopup__${attrs.__id}`
const popupScopeBinding = computed(() => ({
  scopeId: scopeName,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const calculateSaleData = () => {
  let total = 0
  let numberOfSelected = 0
  for (const [index, isChecked] of Object.entries(partsChecked.value)) {
    if (isChecked) {
      let part = props.parts[index]
      total = total + part.data.finalValue
      numberOfSelected = numberOfSelected + 1
    }
  }
  return {price: total, numberOfSelected: numberOfSelected}
}

const saleData = computed(calculateSaleData)

const buildRefList = () => {
  for (let i = 0; i < props.parts.length; i++) {
    partsChecked.value.push(false)
  }
}

const selectAll = (enabled) => {
  for (let i = 0; i < partsChecked.value.length; i++) {
    partsChecked.value[i] = enabled
  }
}

const sellSelectedParts = () => {
  let partIds = []
  for (const [index, isChecked] of Object.entries(partsChecked.value)) {
    if (isChecked) {
      let part = props.parts[index]
      partIds.push(part.data.id)
    }
  }
  lua.overhaul_career_parts_partInventory.sellParts(partIds)
  close(true)
}

// resolves true only after a sale, so Cancel / B no longer report "partSold"
const close = (sold = false) => emit("return", sold === true)
const cancel = () => close(false)

onMounted(buildRefList)
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house style: near-black popup, hairline rows, gold money, one orange action (Sell). */

.selling-card.bng-card {
  --bg-opacity: 0.94;
  --bng-icon-color: currentColor;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  max-height: 92vh;
  color: #fff;
  background-color: transparent;
  border-radius: 0.6em;
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);

  :deep(.card-cnt) {
    border-radius: 0.6em;
    background-color: rgba(var(--bng-off-black-rgb), var(--bg-opacity));
  }
  :deep(.card-heading) { font-size: 1.45em; }
}

.selling-card-content {
  display: flex;
  flex-direction: column;
  gap: 0.65em;
  padding: 0.35em 1em 1em;
}

.part-selected {
  background-color: var(--panel-2);
}

.select-buttons {
  display: flex;
  align-items: center;
  gap: 0.6em;
}
.select-label {
  padding-top: 0.15em; /* Overpass sits high */
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint);
}
.select-row {
  display: flex;
  gap: 0.4em;
}

.popup-buttons {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: 0.5em;
  margin: 0.2em 0 0;
  padding: 0;
}

.part-groups {
  max-height: 100%;
  overflow: hidden auto;
}

.partList {
  position: relative;
  height: min(60vh, 36em);
  width: min(46em, 80vw);
  border-radius: var(--radius-panel);
  background-color: var(--panel);
}

.partList-scroll {
  height: 100%;
  overflow: auto;
  overscroll-behavior: contain;
  padding: 0.25em 0.2em 0.25em 0.35em;
}

.part-item {
  position: relative;
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  align-items: center;
  gap: 0.7em;
  overflow: hidden;
  width: 100%;
  min-height: 3.4em;
  padding: 0.5em 0.6em 0.4em 0.5em;
  color: #fff;
  cursor: pointer;
  border-radius: var(--radius-thumb);
  transition: background-color 0.12s ease-out;
  // overflow:hidden clipped the game's ::before frame (no visible focus); the inset ring is not clipped
  @include house-focus(var(--focus-inset));
  > * {
    flex: 1 1 auto;
  }
  &:hover:not(.part-selected) { background-color: rgba(255, 255, 255, 0.04); }
  &:not(:last-child) {
    border-bottom: 1px solid var(--line);
  }
}

.part-info-col {
  text-align: left;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  min-width: 0;
}
.part-info-row {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.2em 1.1em;
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  > * {
    flex: 0 0 auto;
  }
  > :empty { display: none; }
}

.meta-value {
  color: var(--money);
  font-weight: 700;
  --units-icon-color: var(--money);
  :deep(.info-item) {
    --paddings: 0;
    --icon-size: 1.15em;
    --font-weight-value: 700;
    gap: 0.25em;
    line-height: 1.2;
    font-family: inherit;
  }
}

.selectionCheckbox {
  flex: 0 0 auto;
  padding: 0 0.15em;
  font-size: 1.35em;
  --bng-icon-color: var(--faint);
  color: var(--faint);
}
.part-selected .selectionCheckbox {
  --bng-icon-color: var(--accent);
  color: var(--accent);
}

.part-name {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 1em;
  font-weight: 700;
  line-height: 1.2;
}

.center,
.right {
  text-align: left;
}

/* ---- buttons: house kit (Sell is the one orange action) */
.selling-card .sell-button {
  font-variant-numeric: tabular-nums;
}
</style>
