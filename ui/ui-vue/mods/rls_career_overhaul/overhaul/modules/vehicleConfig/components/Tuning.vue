<template>
  <div
    class="innerTuningCard"
    :class="{
      'with-background': withBackground,
      house,
    }"
    v-bng-blur="withBackground"
    v-bng-on-ui-nav:action_4="toggleTuningApps"
    v-bng-ui-nav-label:action_4="showTuningApps ? $t('ui.vehicleconfig.tuning') : ''"
  >
    <TuningDebugAppsPanel v-if="showTuningApps" ref="tuningAppsPanelRef" />

    <div v-if="tuningLoaded" class="tuning-form" v-bng-ui-nav-scroll>
      <slot name="before-sliders" />
      <div v-if="extraFeatures.length > 0" class="extra-features">
        <BngButton
          v-bng-disabled="!extraFeatures.find(f => f.mirrorsEnabled)"
          @click="toMirrors"
          accent="secondary"
        >
          {{ $t("ui.mirrors.name") }}
        </BngButton>
      </div>
      <div v-if="!hasTuningCategories" class="tuning-empty">
        {{ $t("ui.common.noData") }}
      </div>
      <div class="tuning-category" v-for="category in tuningStore.buckets" :key="category.name">
        <h2 class="category-heading"><span class="category-name">{{ category.name }}</span></h2>
        <div class="tuning-subcategory" v-for="subCategory in category.items" :key="subCategory.name">
          <h3 class="subcategory-heading" v-if="subCategory.name !== 'Other'"><span class="subcategory-name">{{ subCategory.name }}</span></h3>
          <BngRow
            v-for="varData in subCategory.items"
            :key="category.name + subCategory.name + varData.name"
            class="input-container variable-box"
            vertical
            :tooltip="varData.description"
          >
            <template #label>{{ varData.title }}</template>
            <component
              :is="house ? HouseSlider : BngSlider"
              ref="inputs"
              :min="varData.minDis"
              :max="varData.maxDis"
              :step="varData.stepDis"
              :unit="varData.unit"
              :class="{ 'property-slider': true }"
              with-input
              with-reset
              :busy="tuningStore.isBusy"
              :orig-value="tuningStore.tuningVariables[varData.name].origDis"
              v-model="tuningStore.tuningVariables[varData.name].valDis"
              @valueChanged="onChange(varData.name)"
              @interactionStart="holdApply"
              @interactionEnd="releaseApply"
            />
          </BngRow>
        </div>
      </div>
    </div>

    <div v-if="showControls" class="tuning-static">
      <div v-if="awdActive" class="awd-app bngApp">
        <table class="awd-table" v-if="wheelRows.length > 0">
          <thead>
            <tr>
              <th>Name</th>
              <th>Camber</th>
              <th>Toe</th>
              <th>Caster</th>
              <th>SAI</th>
            </tr>
          </thead>
          <tr v-for="w in wheelRows" :key="w.name">
            <td class="data-name">{{ w.name }}</td>
            <td>{{ formatWheelAngle(w.camber) }}</td>
            <td>{{ formatWheelAngle(w.toe) }}</td>
            <td>{{ formatWheelAngle(w.caster) }}</td>
            <td>{{ formatWheelAngle(w.sai) }}</td>
          </tr>
        </table>
      </div>
      <!-- career (house): Style Guide switches and buttons; same models, handlers and nav -->
      <div v-if="house" class="tuning-controls-row">
        <HouseSwitch v-model="awdShow">{{ $t("ui.garage.tune.advWheel") }}</HouseSwitch>
        <HouseSwitch v-model="autoApply">{{ $t("ui.garage.liveUpdates") }}</HouseSwitch>

        <div class="buttons">
          <HouseButton
            compact
            variant="quiet"
            :icon="icons.undo"
            class="reset-button"
            :aria-label="$t('ui.common.reset')"
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-click="{ holdCallback: resetVarsToLoadedConfig, holdDelay: 1000, repeatInterval: 0 }"
            v-bng-tooltip="$t('ui.common.reset')"
          />

          <HouseButton :disabled="autoApply || !isChanged" @click="apply">
            {{ $t("ui.common.apply") }}
          </HouseButton>

          <HouseButton v-if="closeButton" @click="close">
            <BngBinding ui-event="back" deviceMask="xinput" />
            {{ $t("ui.common.close") }}
          </HouseButton>
        </div>
      </div>
      <div v-else class="tuning-controls-row">
        <BngSwitch v-model="awdShow">{{ $t("ui.garage.tune.advWheel") }}</BngSwitch>
        <BngSwitch v-model="autoApply" @valueChanged="applySettingChanged">{{ $t("ui.garage.liveUpdates") }}</BngSwitch>

        <div class="buttons">
          <BngButton
            show-hold
            :icon="icons.undo"
            :accent="ACCENTS.custom_old"
            class="reset-button"
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-click="{ holdCallback: resetVarsToLoadedConfig, holdDelay: 1000, repeatInterval: 0 }"
            v-bng-tooltip="$t('ui.common.reset')"
          />

          <BngButton :disabled="autoApply || !isChanged" @click="apply">
            {{ $t("ui.common.apply") }}
          </BngButton>

          <BngButton v-if="closeButton" @click="close" :accent="ACCENTS.attention">
            <BngBinding ui-event="back" deviceMask="xinput" />
            {{ $t("ui.common.close") }}
          </BngButton>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, onBeforeMount, onUnmounted, nextTick } from "vue"
import { BngRow, BngButton, ACCENTS, BngSwitch, BngSlider, BngBinding, icons } from "@/common/components/base"
import { vBngBlur, vBngTooltip, vBngDisabled, vBngClick, vBngOnUiNav, vBngUiNavLabel, vBngUiNavScroll } from "@/common/directives"
import { HouseButton, HouseSwitch, HouseSlider } from "../../career/components/house/index.js"
import TuningDebugAppsPanel from "@/modules/vehicleConfig/components/TuningDebugAppsPanel.vue"
import { useTuningStore } from "../stores/tuningStore"
import { getUINavServiceInstance, UI_EVENTS, UI_EVENT_GROUPS } from "@/services/uiNav"
import { debounce } from "@/utils/rateLimit"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"
import { useSettingsAsync } from "@/services/settings.js"

const { lua, api } = useBridge()
const events = useEvents()

const tuningStore = useTuningStore()

const props = defineProps({
  withBackground: Boolean,
  buttonTarget: {
    type: Object,
  },
  closeButton: Boolean, // used in career mode
  showControls: {
    type: Boolean,
    default: true,
  },
  autoApply: {
    type: Boolean,
    default: null,
  },
  blockContextNav: {
    type: Boolean,
    default: true,
  },
  mirrorsRoute: {
    type: String,
    default: null,
  },
  // False when a parent already owns the stick filter, such as the combined pause screen.
  releaseDrivingSticks: {
    type: Boolean,
    default: true,
  },
  showTuningApps: Boolean,
  // career only: render the RLS house (Style Guide) controls and rows. Freeroam leaves this off and
  // renders exactly as before.
  house: Boolean,
})

const tuningAppsPanelRef = ref(null)
const awdShow = ref(false)
// The advanced wheel table exists only while the switch is on (and the controls are shown); that is
// also the lifetime of its debug user and its stream.
const awdActive = computed(() => props.showControls && awdShow.value)
const wheelData = ref([])
const wheelRows = computed(() => {
  if (!Array.isArray(wheelData.value)) return []
  return wheelData.value.slice().sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
})
const formatWheelAngle = value => (value ? parseFloat(value).toFixed(3) : "")

const setWheelDebugUser = enabled =>
  api.activeObjectLua(`extensions.advancedwheeldebug.registerDebugUser("advancedWheelDebugApp", ${enabled})`)
const wheelStream = useStreams(["advancedWheelDebugData"], streams => (wheelData.value = streams["advancedWheelDebugData"]))
wheelStream.off()

watch(awdActive, active => {
  if (active) {
    wheelStream.on()
    setWheelDebugUser(true)
  } else {
    wheelStream.off()
    setWheelDebugUser(false)
    wheelData.value = []
  }
})
const reRegisterWheelDebugUser = () => awdActive.value && setWheelDebugUser(true)
events.on("VehicleReset", reRegisterWheelDebugUser)
events.on("VehicleChange", reRegisterWheelDebugUser)

function toggleTuningApps() {
  if (!props.showTuningApps) return true
  tuningAppsPanelRef.value?.toggle?.()
  return false
}

function apply() {
  tuningStore.apply()
}
function close() {
  tuningStore.close()
}

const mirrorsShown = ref(true)
const mirrorsEnabled = ref(false)

let mirrorsRoute = props.mirrorsRoute || "menu.vehicleconfig.tuning.mirrors"

async function toMirrors() {
  await lua.extensions.ui_router.navigate(mirrorsRoute, null, null)
}

const inputs = ref([])

const isChanged = computed(() => inputs.value.some(ipt => ipt.dirty))
const changedCount = computed(() => inputs.value.filter(ipt => ipt.dirty).length)

const localAutoApply = ref(false)
const autoApply = computed({
  get: () => typeof props.autoApply === "boolean" ? props.autoApply : localAutoApply.value,
  set: val => {
    if (typeof props.autoApply !== "boolean") localAutoApply.value = val
    if (!val) cancelPendingApply()
    applySettingChanged(val)
  },
})

const APPLY_DEBOUNCE_MS = 1000

let applyPending = false
let interactionCount = 0

const debouncedApply = debounce(() => {
  if (interactionCount > 0 || tuningStore.isBusy) return
  applyPending = false
  apply()
}, APPLY_DEBOUNCE_MS)

function scheduleApply() {
  applyPending = true
  if (interactionCount > 0 || tuningStore.isBusy) return
  debouncedApply()
}

function holdApply() {
  interactionCount++
  debouncedApply.cancel()
}

function releaseApply() {
  interactionCount = Math.max(0, interactionCount - 1)
  if (interactionCount === 0 && applyPending) debouncedApply()
}

function cancelPendingApply() {
  applyPending = false
  debouncedApply.cancel()
}

watch(
  () => tuningStore.isBusy,
  busy => {
    if (!busy && applyPending && interactionCount === 0) debouncedApply()
  }
)

function onChange(varName) {
  //TODO is there a way to check here if the input is dirty or not?
  tuningStore.tuningVarChanged(varName)
  autoApply.value && scheduleApply()
}

const applySettingChanged = val => localStorage.setItem("applyTuningChangesAutomatically", JSON.stringify(val))

watch(
  () => tuningStore.buckets,
  () => nextTick(() => {
    for (let ipt of inputs.value) ipt.markClean()
  })
)

async function resetVarsToLoadedConfig() {
  tuningStore.resetTuningData()
  await tuningStore.requestInitialData()
  await nextTick()
  for (let ipt of inputs.value) ipt.markClean()
}

function getVisibleTuneSnapshot() {
  const variables = {}
  for (const category of tuningStore.buckets || []) {
    for (const subCategory of category.items || []) {
      for (const varData of subCategory.items || []) {
        const current = tuningStore.tuningVariables[varData.name]
        if (!current) continue
        const displayRange = current.maxDis - current.minDis
        const rawRange = current.max - current.min
        const rawValue = displayRange === 0
          ? current.min
          : ((current.valDis - current.minDis) / displayRange) * rawRange + current.min
        if (!Number.isFinite(rawValue)) continue
        variables[varData.name] = {
          value: rawValue,
          label: String(varData.title || varData.name),
        }
      }
    }
  }
  return { variables }
}

function prepareForExternalReload() {
  cancelPendingApply()
}

async function refreshFromBackend() {
  prepareForExternalReload()
  await tuningStore.refreshFromBackend()
  await nextTick()
  for (const input of inputs.value) input.markClean()
}

let releaseDrivingSticksActive = true

onBeforeMount(async () => {
  const optAutoApply = localStorage.getItem("applyTuningChangesAutomatically")
  if (optAutoApply) {
    try {
      localAutoApply.value = !!JSON.parse(optAutoApply)
    } catch (err) { }
  }

  if (!props.mirrorsRoute && await lua.overhaul_integration_services_garageMode.isActive()) {
    mirrorsRoute = "menu.vehicleconfig.tuning.mirrors.in-garage"
  }

  if (await lua.overhaul_career_career.isActive()) {
    mirrorsShown.value = false
  } else {
    mirrorsEnabled.value = (await useSettingsAsync()).values.GraphicDynMirrorsEnabled
  }

  await tuningStore.init()
  await tuningStore.requestInitialData()
  if (!releaseDrivingSticksActive || !props.releaseDrivingSticks) return
  getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar, UI_EVENTS.rotate_h_cam)
})

const extraFeatures = computed(() => {
  const features = []
  if (mirrorsEnabled.value) {
    features.push({ mirrorsEnabled: true })
  }
  return features
})

const tuningLoaded = computed(() => Array.isArray(tuningStore.buckets))
const hasTuningCategories = computed(() => tuningLoaded.value && tuningStore.buckets.length > 0)

onUnmounted(async () => {
  if (awdActive.value) setWheelDebugUser(false)
  releaseDrivingSticksActive = false
  if (props.releaseDrivingSticks) getUINavServiceInstance().clearFilteredEvents()
  // dispose of the pending apply
  cancelPendingApply()
  await tuningStore.notifyOnMenuClosed()
  tuningStore.close()
  tuningStore.$dispose()
})

defineExpose({
  apply,
  close,
  changedCount,
  isChanged,
  getVisibleTuneSnapshot,
  prepareForExternalReload,
  refreshFromBackend,
})
</script>

<style scoped lang="scss">
.innerTuningCard {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
  max-height: 100%;
  overflow: hidden;

  > .tuning-static {
    flex: 0 0 auto;
    padding: 0.5em 1em;
    border-top: solid 2px var(--bng-orange);
    display: flex;
    flex-direction: column;
    gap: 0.25em;
    min-height: 0;
    min-width: 0;
    // Leave room for the tuning form's vertical padding when wheel data needs
    // the rest of the available height.
    max-height: calc(100% - 1.5rem);
    box-sizing: border-box;
    overflow: hidden;

    .awd-app {
      flex: 1 1 auto;
      min-height: 0;
      width: 100%;
      padding: 0;
      overflow: auto;

      .awd-table {
        width: 100%;

        thead > tr {
          text-align: justify;
        }

        th {
          text-align: left;
        }
        th:first-child {
          text-align: center;
        }

        td {
          width: 20%;
          font-size: 0.875em;
          font-weight: 400;
          letter-spacing: 0.01em;
          line-height: 1.4em;
          text-align: left;

          &.data-name {
            font-weight: 500;
            line-height: 1.7em;
            text-align: center;
          }
        }
      }
    }

    .tuning-controls-row {
      display: flex;
      flex-direction: row;
      flex-wrap: wrap;
      align-items: center;
      gap: 0.25em;
      width: 100%;
      flex: 0 0 auto;
    }

    .buttons {
      text-align: right;
      display: flex;
      justify-content: flex-end;
      gap: 0.125rem;
      height: 2.8em;
      flex: 1 0 auto;
      margin-left: auto;

      .reset-button {
        --bng-button-custom-hold-offset: 0px;
      }
    }
  }

  &.with-background {
    background-color: rgba(0, 0, 0, 0.6);
  }

  color: white;

  > .tuning-form {
    flex: 1 1 auto;
    min-height: 0;
    width: 100%;
    display: flex;
    flex-direction: column;
    padding: 0.5rem 0 1rem;
    text-align: center;
    overflow-x: hidden;
    overflow-y: auto;
    will-change: scroll-position;

    > * {
      flex-shrink: 0;
    }

    .tuning-empty {
      flex: 1 1 auto;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 6rem;
      padding: 1.5rem 1rem;
      color: rgba(var(--bng-off-white-rgb), 0.65);
      font-size: 1.125rem;
      font-weight: 600;
      letter-spacing: 0.08em;
    }

    .extra-features {
      display: flex;
      flex-direction: row;
      flex-wrap: wrap;
      justify-content: center;
      gap: 0.5rem;
    }

    .tuning-category {
      display: flex;
      flex-direction: column;
      flex-wrap: nowrap;
      padding: 0.5em 0 0.75em 0;

      .category-heading {
        margin: 0 0 0 0;
        font-size: 1.25em;
        font-weight: 600;
        font-style: italic;
        text-align: left;
        margin: 0;
        padding: 0.5em 0.5em 0.5em 1rem;
        display: inline-flex;
        align-items: center;
        justify-content: flex-start;
        gap: 0.5em;
        color: var(--bng-orange-100);

        &::after {
          content: "";
          display: inline-block;
          transform: translateY(0.125em);
          height: 1px;
          background: var(--bng-orange-750);
          flex: 1 1 auto;
        }
      }

      .tuning-subcategory {
        display: flex;
        flex-direction: column;
        flex-wrap: nowrap;
        padding: 0 0.5rem 0 1rem;

        .subcategory-heading {
          font-size: 1em;
          font-weight: 600;
          font-style: italic;
          text-align: left;
          margin: 0;
          padding: 0.5em 0 0.5em 0;
          display: inline-flex;
          align-items: center;
          justify-content: flex-start;
          gap: 0.5em;

          &::after {
            content: "";
            display: inline-block;
            transform: translateY(0.125em);
            height: 0.0625em;
            background: repeating-linear-gradient(to right, var(--bng-cool-gray-750), var(--bng-cool-gray-750) 0.25em, transparent 0.251em, transparent 0.45em);
            flex: 1 1 auto;
          }
        }
      }

      .input-container {
        display: flex;
        flex-direction: column;
        flex-wrap: nowrap;
      }
    }
  }

  .variable-title {
    text-align: left;
    font-size: 0.875em;
  }

  .variable-box {
    float: left;
    --input-width: 7em;
    --bng-slider-margin: 0.25em;

    .property-slider {
      --input-height: 2em;
      align-items: center;
    }
  }
}
// ---- career only (house prop): Style Guide captions, translucent .line rows, slim scrollbar and a
// hairline bottom bar. Tokens come from the career panel's .rls-house; the fallbacks are the same values.
.innerTuningCard.house {
  font-family: "Overpass", var(--fnt-defs, sans-serif);

  > .tuning-form {
    padding: 0.35em 0.5em 1em 0.75em;
    text-align: left;
    scrollbar-gutter: stable;
    &::-webkit-scrollbar { width: 0.5em; height: 0.5em; }
    &::-webkit-scrollbar-track { background: transparent; }
    &::-webkit-scrollbar-thumb {
      background: rgba(255, 255, 255, 0.22);
      border-radius: 1em;
      border: 0.12em solid transparent;
      background-clip: padding-box;
    }
    &::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
    &::-webkit-scrollbar-thumb:active { background: var(--accent, #ff6600); background-clip: padding-box; }

    .tuning-category {
      padding: 0.2em 0 0.5em;

      // Style Guide .caption + hairline rule
      .category-heading {
        padding: 0.9em 0.15em 0.5em;
        gap: 0.7em;
        font-size: 0.78em;
        font-style: normal;
        font-weight: 700;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        color: var(--faint, rgba(255, 255, 255, 0.55));
        &::after {
          transform: none;
          height: 1px;
          background: var(--line, rgba(255, 255, 255, 0.1));
        }
      }

      .tuning-subcategory {
        padding: 0;

        .subcategory-heading {
          padding: 0.7em 0.15em 0.35em;
          font-size: 0.85em;
          font-style: normal;
          font-weight: 700;
          color: var(--muted, rgba(255, 255, 255, 0.72));
          &::after {
            display: none;
          }
        }
      }
    }
  }

  // each setting is a translucent line; a subcategory's lines read as one rounded group
  .variable-box {
    --bng-bg-enabled: rgba(255, 255, 255, 0.06);
    --bng-bg-hover: rgba(255, 255, 255, 0.1);
    --bng-bg-active: rgba(255, 255, 255, 0.1);
    --bng-bg-border-enabled: transparent;
    --bng-bg-border-hover: transparent;
    --bng-bg-border-active: transparent;
    --bng-bg-enabled-opacity: 1;
    --bng-bg-hover-opacity: 1;
    --bng-bg-active-opacity: 1;
    --bng-bg-border-radius: 0;
    --bng-row-label-padding: 0 0 0.2em;
    --bng-slider-margin: 0.45em;
    --input-width: 6.5em;
    margin: 0;
    padding: 0.6em 0.75em 0.45em;
    border-radius: 0;

    &.focus-visible:not(.no-focus-frame) {
      --bng-bg-enabled: rgba(255, 255, 255, 0.12);
    }

    :deep(.bng-row-background) {
      border-radius: inherit;
    }
    :deep(.bng-row-label) {
      color: #fff;
      font-size: 0.92em;
      font-weight: 600;
      line-height: 1.25;
    }
  }
  .variable-box + .variable-box {
    border-top: 1px solid var(--line, rgba(255, 255, 255, 0.1));
  }
  div.variable-box:first-of-type {
    border-top-left-radius: var(--radius-panel, 0.5em);
    border-top-right-radius: var(--radius-panel, 0.5em);
  }
  div.variable-box:last-of-type {
    border-bottom-left-radius: var(--radius-panel, 0.5em);
    border-bottom-right-radius: var(--radius-panel, 0.5em);
  }

  > .tuning-static {
    padding: 0.6em 0.75em;
    border-top: 1px solid var(--line, rgba(255, 255, 255, 0.1));

    .tuning-controls-row {
      gap: 0.5em 1.2em;
    }

    .buttons {
      align-items: center;
      gap: 0.4em;
      height: auto;
    }
  }
}
</style>
