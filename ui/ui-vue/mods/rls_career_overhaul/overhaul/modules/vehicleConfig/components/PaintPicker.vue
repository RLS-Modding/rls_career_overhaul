<!-- RLS override of the vanilla PaintPicker.vue. Script logic is the game's; the `house` prop (career painting
     only) swaps the chrome for the RLS house look: the finish sliders become house sliders with a caption and a
     readable percentage, the advanced switch a house switch, and PaintPresets gets `house` too. The colour picker
     is HousePaintColour (BngColorPicker's contract, usable on a pad); its field and bars keep their colours.
     Without `house` (freeroam vehicle config) the template and styles are the vanilla ones. -->
<template>
  <div class="paint-picker" :class="{ house }">
    <div v-if="showPreview || showPresets" class="paint-flex">
      <svg v-if="showPreview" class="paint-preview" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1" preserveAspectRatio="xMidYMid meet">
        <defs>
          <radialGradient id="light" cy="0.28" cx="0.35" r="0.3" spreadMethod="pad">
            <stop :offset="0.1 + 0.2 * (1 - paint.roughness)" v-bind="{ 'stop-opacity': 0.4 + 0.2 * paint.roughness }" stop-color="#fff" />
            <stop :offset="1 - paint.roughness * 0.5" stop-opacity="0.0" stop-color="#fff" />
          </radialGradient>
          <radialGradient id="shadow" cy="0.43" cx="0.45" r="0.55" spreadMethod="pad">
            <stop offset="0.7" stop-opacity="0.0" stop-color="#000" />
            <stop offset="0.85" stop-opacity="0.2" stop-color="#000" />
            <stop offset="1.0" stop-opacity="0.5" stop-color="#000" />
          </radialGradient>
          <pattern id="colPreview" x="0" y="0" width="1" height="1" patternUnits="userSpaceOnUse">
            <!-- reflection -->
            <!-- FIXME: this image should NOT contain light reflection -->
            <image x="0" y="0" height="1" width="1" :xlink:href="'/ui/lib/int/colorpicker/color-chrome.png'" />
            <!-- colour -->
            <rect y="0" x="0" width="1" height="1" :fill="`hsl(${hslColour})`" v-bind="{ 'fill-opacity': paint.alpha / 2 }" stroke="transparent" />
            <!-- light -->
            <rect y="0" x="0" width="1" height="1" fill="url(#light)" stroke="transparent" />
            <!-- shadow -->
            <rect y="0" x="0" width="1" height="1" fill="url(#shadow)" stroke="transparent" />
          </pattern>
        </defs>
        <circle cy="0.5" cx="0.5" r="0.5" fill="url(#colPreview)" stroke="transparent" />
      </svg>
      <PaintPresets
        v-if="showPresets"
        :presets="factoryPresets"
        :show-text="showText"
        :editable="presetsEditable"
        :current="paint.paintObject"
        :pick-before-add="!showMain"
        :picker-mode="pickerMode"
        :house="house"
        @apply="applyPreset"
      />
    </div>

    <div v-if="showMain" class="paint-main">
      <span v-if="showText && $slots.default"><slot></slot></span>
      <!-- career: the house colour picker (same model + change contract) whose field and bars work on a pad -->
      <HousePaintColour v-if="house" v-model="paintPicker" @change="returnPaint()" />
      <BngColorPicker
        v-else
        v-model="paintPicker"
        :view="pickerMode"
        :show-text="showText"
        @change="returnPaint()"
      />
    </div>

    <div v-if="showMain && !house">
      <BngSwitch
        v-if="showAdvancedSwitch"
        v-model="advanced"
        :label="$t('ui.color.configurations')"
        class="paint-advanced-switch"
      />

      <div v-if="advanced" class="paint-slider-group" :class="{ 'paint-slider-group-fullrow': $simplemenu.value }">
        <BngColorSlider v-if="legacy" v-model="paint.alpha" :max="2" @change="returnPaint()" :fill="[`hsla(${hslColour}, 0)`, `hsla(${hslColour}, 2)`]">
          {{ showText ? `${$t("ui.color.chrominess")} (${paint.alphaPercent}%)` : null }}
        </BngColorSlider>
        <BngColorSlider v-model="paint.metallic" @change="returnPaint()">
          {{ showText ? `${$t("ui.color.metallic")} (${paint.metallicPercent}%)` : null }}
        </BngColorSlider>
        <BngColorSlider v-model="paint.roughness" @change="returnPaint()">
          {{ showText ? `${$t("ui.color.roughness")} (${paint.roughnessPercent}%)` : null }}
        </BngColorSlider>
        <BngColorSlider v-model="paint.clearcoat" @change="returnPaint()">
          {{ showText ? `${$t("ui.color.clearCoat")} (${paint.clearcoatPercent}%)` : null }}
        </BngColorSlider>
        <BngColorSlider v-model="paint.clearcoatRoughness" @change="returnPaint()">
          {{ showText ? `${$t("ui.color.clearCoatRoughness")} (${paint.clearcoatRoughnessPercent}%)` : null }}
        </BngColorSlider>
      </div>
    </div>

    <!-- career (house): same models and change handler, house switch / sliders with a caption + value line -->
    <div v-if="showMain && house" class="paint-house-advanced">
      <HouseSwitch v-if="showAdvancedSwitch" v-model="advanced" row>
        {{ $t("ui.color.configurations") }}
      </HouseSwitch>
      <div v-if="advanced" class="paint-house-sliders">
        <div v-if="legacy" class="paint-house-slider">
          <div class="paint-house-slider-head">
            <span class="paint-house-slider-name">{{ $t("ui.color.chrominess") }}</span>
            <span class="paint-house-slider-value">{{ paint.alphaPercent }}%</span>
          </div>
          <HouseSlider v-model="paint.alpha" :min="0" :max="2" :step="0.01" @change="returnPaint()" />
        </div>
        <div class="paint-house-slider">
          <div class="paint-house-slider-head">
            <span class="paint-house-slider-name">{{ $t("ui.color.metallic") }}</span>
            <span class="paint-house-slider-value">{{ paint.metallicPercent }}%</span>
          </div>
          <HouseSlider v-model="paint.metallic" :min="0" :max="1" :step="0.01" @change="returnPaint()" />
        </div>
        <div class="paint-house-slider">
          <div class="paint-house-slider-head">
            <span class="paint-house-slider-name">{{ $t("ui.color.roughness") }}</span>
            <span class="paint-house-slider-value">{{ paint.roughnessPercent }}%</span>
          </div>
          <HouseSlider v-model="paint.roughness" :min="0" :max="1" :step="0.01" @change="returnPaint()" />
        </div>
        <div class="paint-house-slider">
          <div class="paint-house-slider-head">
            <span class="paint-house-slider-name">{{ $t("ui.color.clearCoat") }}</span>
            <span class="paint-house-slider-value">{{ paint.clearcoatPercent }}%</span>
          </div>
          <HouseSlider v-model="paint.clearcoat" :min="0" :max="1" :step="0.01" @change="returnPaint()" />
        </div>
        <div class="paint-house-slider">
          <div class="paint-house-slider-head">
            <span class="paint-house-slider-name">{{ $t("ui.color.clearCoatRoughness") }}</span>
            <span class="paint-house-slider-value">{{ paint.clearcoatRoughnessPercent }}%</span>
          </div>
          <HouseSlider v-model="paint.clearcoatRoughness" :min="0" :max="1" :step="0.01" @change="returnPaint()" />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, reactive, computed, watch } from "vue"
import { BngSwitch, BngColorSlider, BngColorPicker } from "@/common/components/base"
import { HouseSwitch, HouseSlider } from "../../career/components/house/index.js"
import PaintPresets from "./PaintPresets.vue"
import HousePaintColour from "./HousePaintColour.vue"
import Paint from "@/utils/paint"

const props = defineProps({
  modelValue: {
    type: [String, Object],
    // legacy    r g b  a  m r c  cr
    // default: "1 1 1 1.2 0 1 1 0.06",
    // current   r g b m r c  cr
    // default: "1 1 1 0 1 1 0.06",
  },
  legacy: {
    type: Boolean,
    default: false,
  },
  presets: {
    // preCol
    type: Object,
    default: {},
  },
  presetsEditable: {
    type: Boolean,
    default: false,
  },
  showPresets: {
    type: Boolean,
    default: true,
  },
  showMain: {
    type: Boolean,
    default: true,
  },
  pickerMode: {
    type: String,
    default: "full_luminosity",
  },
  showText: {
    type: Boolean,
    default: true,
  },
  showPreview: {
    type: Boolean,
    default: false,
  },
  advancedOpen: {
    type: Boolean,
    default: false,
  },
  showAdvancedSwitch: {
    type: Boolean,
    default: true,
  },
  // career only (RLS house look); freeroam leaves this off
  house: Boolean,
})

defineExpose({
  paintUpdated,
  setAdvancedVisible,
})

watch(() => props.modelValue, init)

const emitter = defineEmits(["update:modelValue", "change"])

const advanced = ref(props.advancedOpen)

const paint = reactive(new Paint({ legacy: props.legacy }))
watch(() => props.legacy, val => paint.legacy = val)

const paintPicker = ref(paint) // this is to avoid "assigning to const" error after compiling the vue

let isPaintObject = false

const factoryPresets = computed(() => props.presets || {})

const hslColour = computed(() => Paint.hslCssStr(paint.hsl))

function init() {
  const defPaint = [1, 1, 1, 1, 0, 1, 1, 0]
  if (!props.modelValue) {
    // no paint in model
    paint.paint = defPaint
    return
  }
  // check if it's a paint itself
  isPaintObject = props.modelValue instanceof Paint
  if (isPaintObject) {
    paint.paint = props.modelValue.paintObject
    // if used with legacy, then legacy prop must be set
    return
  }
  // attempt to parse paint
  const newpaint = new Paint({ legacy: props.legacy })
  try {
    newpaint.paint = props.modelValue
  } catch (err) {
    // console.warn(err)
    newpaint.paint = defPaint
  }
  // if not the same paint
  if (newpaint.paintString !== paint.paintString) paint.paint = newpaint.paintObject
}

function returnPaint() {
  let res
  if (isPaintObject) {
    // to preserve original reactivity
    res = props.modelValue
    res.paint = paint.paintObject
  } else {
    res = paint.paintString
  }
  emitter("change", res)
  emitter("update:modelValue", res)
}

function paintUpdated() {
  init()
  returnPaint()
}

function setAdvancedVisible(visible) {
  advanced.value = visible
}

function applyPreset(preset) {
  paint.paint = preset
  returnPaint()
}

init()
</script>

<style lang="scss" scoped>
.paint-picker {
  display: flex;
  // flex-wrap: wrap;
  // align-items: center;
  flex-direction: column;

  .paint-advanced-switch {
    margin: 0.5rem 0;
  }

  .paint-slider-group {
    border-left: 1px rgba(255, 255, 255, 0.25) dashed;
    padding-left: 5px;
    margin-left: 5px;

    display: flex;
    flex-direction: row;
    flex-wrap: wrap;
    justify-content: space-between;
    > * {
      $width: calc(50% - 0.5em);
      flex: 0 0 $width;
      width: $width;
    }
    &.paint-slider-group-fullrow > * {
      flex: 0 0 100%;
      width: 100%;
    }
  }

  .colour-slider {
    margin-top: 1.25em;
  }

  .paint-flex {
    display: flex;
    flex-direction: row;
    flex-wrap: nowrap;

    .paint-preview {
      position: relative;
      /* width: 75px;
      height: 75px; */
      min-width: 50px;
      max-width: 100px;
      min-height: 50px;
      max-height: 75px;
      margin-right: 5px;
    }
  }
}

// ---- career only (house prop). Tokens come from the career screen's .rls-house root; fallbacks are the same values.
.paint-picker.house {
  gap: 1em;

  // gloss / metallic pass no presets: drop the empty presets block so it adds no gap
  .paint-flex:has(> .paint-presets:empty) {
    display: none;
  }

  // colour picker (HousePaintColour styles itself)
  .paint-main {
    display: block;
  }

  .paint-house-advanced {
    display: grid;
    gap: 0.75em;
  }

  .paint-house-sliders {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.9em 1.4em;
  }

  .paint-house-slider {
    display: grid;
    gap: 0.25em;
    min-width: 0;
  }

  .paint-house-slider-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 0.6em;
  }

  // Style Guide caption
  .paint-house-slider-name {
    min-width: 0;
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint, rgba(255, 255, 255, 0.55));
  }

  .paint-house-slider-value {
    flex: 0 0 auto;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}
</style>
