<template>
  <Transition name="loading-fade" @after-enter="onFadeIn" @after-leave="onFadeOut">
    <dialog
      v-if="state.visible"
      open
      class="loading-screen"
      :class="`loading-screen-${state.mode}`"
    >
      <div class="loading-background" :style="{ backgroundImage: state.image ? `url('${state.image}')` : 'none' }"></div>

      <!-- normal loading progress screen -->
      <div v-if="state.mode === 'progress'" class="progress-box">
        <div class="progress-icon-group">
          <div
            v-for="iconInfo in iconsList"
            :key="iconInfo.id"
            class="progress-icon-box"
            :style="{ backgroundPosition: `0 ${state.iconState[iconInfo.id] || 0}%` }"
          >
            <BngIcon :type="iconInfo.icon" color="#fff" class="progress-icon" />
          </div>
        </div>

        <div class="progress-bar-container">
          <BngProgressBar
            class="progress-bar"
            gradient
            :show-value-label="false"
            :min="0"
            :max="100"
            :value="progressValue"
          />
        </div>

        <div class="progress-status">{{ currentStatus || $tt("ui.common.loading") }}</div>

        <div class="progress-history">
          <div v-for="(item, idx) in state.historyEntriesDisplay" :key="idx">
            {{ item.message }}
          </div>
        </div>
      </div>

      <!-- custom loading screen (fade screen) -->
      <div v-if="state.mode === 'custom'" class="custom-box" :class="{ 'custom-with-tips': state.customContent?.tips }">
        <div class="custom-left-container">
          <div v-if="state.customContent && (state.customContent.title || state.customContent.text)" class="custom-text-panel">
            <BngScreenHeading v-if="state.customContent.title" :preheadings="[$tt(state.customContent.subtitle)]">
              {{ $tt(state.customContent.title) }}
            </BngScreenHeading>
            <p v-if="state.customContent.text" class="text">
              <DynamicComponent :translate-id="state.customContent.text" bbcode translate-context />
            </p>
          </div>
          <div v-else class="custom-indeterminate-panel">
            <BngScreenHeading>
              {{ $tt("ui.common.loading.short") }}
            </BngScreenHeading>
            <BngProgressBar
              class="progress-bar"
              gradient
              :show-value-label="false"
              :min="0"
              :max="100"
              indeterminate
            />
          </div>
        </div>
        <div class="custom-right-container">
          <div
            v-if="state.customContent && state.customContent.image"
            class="custom-image-panel"
            :style="{ backgroundImage: `url('${state.customContent.image}')` }"
          ></div>
        </div>
      </div>

      <div v-if="state.mode === 'progress' || state.customContent?.tips" class="tips-bar">
        <div class="tips-bar-title">{{ $tt("ui.loadingScreen.tips") }}:</div>
        <div class="tips-bar-tip">
          <DynamicComponent :translate-id="tip" bbcode />
        </div>
      </div>
    </dialog>
  </Transition>
  <!-- this is to force the browser to show images right away by storing them in memory -->
  <div v-if="state.image" class="loading-cache">
    <img :src="state.image" alt="" />
  </div>
</template>

<script setup>
import { ref, reactive, computed, watch, onMounted, onUnmounted, nextTick } from "vue"
import { BngProgressBar, BngIcon, BngScreenHeading, icons } from "@/common/components/base"
import { DynamicComponent } from "@/common/components/utility"
import { useEvents } from "@/services/events"
import { useBridge } from "@/bridge"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { linkLoadingScreenState } from "@/services/screenCover"
import { getAssetURL } from "@/utils"
import { debounce } from "@/utils/rateLimit"
import Logger from "@/services/logger"
import hints from "../hints"

const events = useEvents()
const { lua } = useBridge()
const navBlocker = useUINavBlocker()

const imagesAmount = 18 // fallback number of built-in loading images
const customImagesAmount = 12 // number of custom loading images
const customImagePathPattern = "/ui/modules/loading/drive/rls_drive_loading_{n}.jpg"
const preferCustomLoadingImages = true
const activeRepeatTime = 10_000 // safety to ensure lua is notified (as it was in angular)

// css transition durations (in ms)
const fadeInDefault = 1_000
const fadeOutDefault = 2_000

let lastImageNum = -1
let repeatTimer = null
let customTimer = null

const iconsList = [
  { id: "terrain", icon: icons.terrain },
  { id: "environment", icon: icons.water },
  { id: "forest", icon: icons.trafficCone },
  { id: "meshes", icon: icons.garage01 },
  { id: "roads", icon: icons.road },
  { id: "beamng", icon: icons.beamNG },
]

const state = reactive({
  active: false, // if loading screen is supposed to be visible
  visible: false, // if loading screen is actually visible
  fading: false, // if loading screen is currently fading in/out
  shown: false, // if loading screen is shown (including fade in/out)
  autoActivate: true, // if loading screen should be activated/dismissed automatically (used on startup to handle cases of lost loading state such as command line args or ui reload)
  highSeas: false,
  mode: "progress", // "progress" or "custom"
  image: null,
  iconState: {},
  currentEntries: [],
  historyEntriesDisplay: [],
  customContent: null, // when mode is "custom"
  fadeInTime: fadeInDefault,
  fadeOutTime: fadeOutDefault,
  customPause: -1,
})

function resetState() {
  state.mode = "progress"
  state.customContent = null
  state.iconState = {}
  state.currentEntries = []
  state.historyEntriesDisplay = []
  state.fadeInTime = fadeInDefault
  state.fadeOutTime = fadeOutDefault
  state.customPause = -1
}

const tip = ref("")
const setTip = (txt = undefined, _retrying = false) => {
  const idx = ~~(Math.random() * hints.length)
  tip.value = txt || hints[idx]
  if (!tip.value || tip.value === "undefined") {
    Logger.debug(`Loading Screen tip is undefined!\nARG: ${JSON.stringify(txt)} TIP: ${JSON.stringify(tip.value)} IDX: ${idx}/${hints.length}`)
    if (!_retrying) {
      setTip(undefined, true)
    } else {
      tip.value = ""
    }
  }
}

const fadeInTimeVar = computed(() => state.fadeInTime + "ms")
const fadeOutTimeVar = computed(() => state.fadeOutTime + "ms")

const progressValue = computed(() => state.currentEntries[0]?.progress || 0)
const currentStatus = computed(() => state.currentEntries[0]?.message || "")

events.on("LoadingScreen", data => {
  // in external UI: do not ever allow showing the loading screen
  if (!window.beamng?.ingame) return

  // Logger.debug("LoadingScreen event", data)

  if (!data || typeof data !== "object") data = {}

  state.autoActivate = false // dismiss auto activation flag

  state.active = !!data.active

  if (data.custom) {
    state.mode = "custom"
    state.fadeInTime = data.custom.fadeIn > 0 ? data.custom.fadeIn * 1000 : state.fadeInTime || 0
    state.fadeOutTime = data.custom.fadeOut > 0 ? data.custom.fadeOut * 1000 : state.fadeOutTime || 0
  }

  if (state.active) {
    // mode switch should happen on activation only to handle the visuals correctly
    if (data.custom) {
      /* data.custom: {
          fadeIn, // (number) fade-in duration in seconds
          fadeOut, // (number) fade-out duration in seconds
          pause, // (number) duration to wait between fade-in and fade-out, -1 to hold indefinitely
          data: { // (object) content to display
            image, // (string) URL for background image
            title, // (string) main heading text)
            subtitle, // (string) secondary heading text
            text, // (contextual) main body text
            tips, // (contextual) tip text to display
          }
        }
      */
      state.customPause = data.custom.pause ? data.custom.pause * 1000 : -1
      state.customContent = data.custom.data
      if (state.customContent?.image) {
        // state.customContent.image = getAssetURL(state.customContent.image) // FIXME: misbehaves in vue-dev mode, hm...
        state.image = state.customContent.image
      }
    } else {
      resetState()
      window.bngVue.gotoAngularState("blank")
    }

    setTip(state.customContent?.tips)

  } else if (state.mode === "progress" && "gotoMainMenu" in data) {
    const args = []
    if (data.gotoMainMenu) {
      // window.bngVue.gotoAngularState("menu.mainmenu")
      args.push("menu.mainmenu")
    } else {
      // window.bngVue.gotoAngularState("menu")
      args.push("menu", ["loading"])
    }
    // for backward compatibility
    window.globalAngularRootScope?.$broadcast("ChangeState", ...args)
    window.vueEventBus?.emit("onChangeState", ...args)
  }
})

events.on("UpdateLoadingProgressV2", data => {
  // in external UI: do not ever allow showing the loading screen
  if (!window.beamng?.ingame || (!state.autoActivate && !state.active)) return

  // Logger.debug("UpdateLoadingProgressV2", JSON.stringify(data))

  let { currentEntries, historyEntries } = data
  if (!currentEntries || !Array.isArray(currentEntries)) currentEntries = []
  if (!historyEntries || !Array.isArray(historyEntries)) historyEntries = []

  state.currentEntries = currentEntries
  state.historyEntriesDisplay = historyEntries.slice(Math.max(historyEntries.length - 3, 1))

  state.iconState = {}
  for (const { name, progress } of currentEntries) {
    state.iconState[name.toLowerCase()] = progress
  }
  for (const { name } of historyEntries) {
    state.iconState[name.toLowerCase()] = 100
  }

  if (state.autoActivate) {
    state.active = currentEntries.length > 0 || historyEntries.length > 0
  }
})

const onFadeIn = () => {
  state.fading = false
  if (state.mode === "progress") {
    lua.core_gamestate.loadingScreenActive()
    repeatTimer = setTimeout(() => { // this was in angular
      lua.core_gamestate.loadingScreenActive()
    }, activeRepeatTime)
  } else if (state.mode === "custom") {
    lua.extensions.ui_fadeScreen.onScreenFadeStateDelayed(1)
    // -1 pause means we're holding until fadeScreen.lua:stop()
    if (state.customPause !== -1) {
      customTimer = setTimeout(() => {
        lua.extensions.ui_fadeScreen.onScreenFadeStateDelayed(2)
      }, state.customPause * 1000)
    }
  }
}

const onFadeOut = () => {
  state.fading = false
  state.shown = false
  if (state.mode === "custom") {
    lua.extensions.ui_fadeScreen.onScreenFadeStateDelayed(3)
  }
  // clean up
  resetState()
  // switch and preload next image to avoid partial display next time
  loadNextImage()
}

// visual and interaction controller
watch(() => state.active, (newActive, oldActive) => {
  if (!window.beamng?.ingame) return
  // when showing loading screen
  if (newActive && !oldActive) activateLoading()
  // when hiding loading screen
  else if (!newActive && oldActive) deactivateLoading()
})

const activateLoading = () => {
  // Logger.debug(`Loading Screen: activating (${state.active})`)
  if (state.active) {
    deactivateLoading.cancel()
    // Logger.debug("Loading Screen: blocking all events")
    navBlocker.allowOnly([])
    /// uncomment if want to wait until custom image is loaded
    // if (state.mode === "custom" && state.customContent?.image) {
    //   loadImage(state.customContent.image)
    //     .then(() => state.visible = true)
    //     .catch(() => state.visible = true)
    // } else {
      nextTick(() => {
        state.visible = true
        state.fading = true
        state.shown = true
      })
    // }
  }
}

const deactivateLoading = debounce(() => {
  // Logger.debug(`Loading Screen: deactivating (${state.active})`)
  if (!state.active) {
    // Logger.debug("Loading Screen: unblocking all events")
    clearTimers()
    navBlocker.clear()
    nextTick(() => {
      state.visible = false
      state.fading = true
    })
  }
}, 100)

const getRandomImageNum = (amount = imagesAmount) => {
  const rnd = ~~(Math.random() * amount) + 1
  if (rnd === lastImageNum) return getRandomImageNum(amount)
  lastImageNum = rnd
  return rnd
}

const getCustomImageUrl = () => customImagePathPattern.replace("{n}", getRandomImageNum(customImagesAmount))

const getNextImageUrl = () => {
  let url
  if (state.highSeas) {
    url = "images/mainmenu/unofficial_version.jpg"
  } else if (preferCustomLoadingImages) {
    // Kept absolute so the path points directly to this mod's custom images.
    url = getCustomImageUrl()
  } else {
    url = `images/loading/drive/${getRandomImageNum()}.jpg`
    url = getAssetURL(url)
  }
  if (url.startsWith("/")) return url
  return getAssetURL(url)
}

const loadNextImage = async () => {
  const url = getNextImageUrl()
  if (state.image === url) return
  try {
    await loadImage(url)
    state.image = url
  } catch {
    // If custom image loading fails, gracefully fall back to stock images.
    const fallbackUrl = getAssetURL(`images/loading/drive/${getRandomImageNum(imagesAmount)}.jpg`)
    await loadImage(fallbackUrl)
    state.image = fallbackUrl
  }
}

// use this to load images
const loadImage = url => new Promise((resolve, reject) => {
  const img = new Image()
  img.onload = () => resolve(url)
  img.onerror = () => reject(url)
  img.src = url
})

const clearTimers = () => {
  if (repeatTimer) {
    clearTimeout(repeatTimer)
    repeatTimer = null
  }
  if (customTimer) {
    clearTimeout(customTimer)
    customTimer = null
  }
}

const initLoadingScreen = () => bngApi.engineLua("sailingTheHighSeas", async ahoy => {
  state.highSeas = ahoy === true
  await loadNextImage()
  setTip()

  lua.core_gamestate.loadingScreenActive() // for auto-activation in case of lost loading state (command line args or ui reload)

  window.loadingTest = active => { // FIXME: TEMP TESTING
    events.emit("LoadingScreen", {
      active,
      // custom: {
      //   fadeIn: 1,
      //   pause: -1,
      //   fadeOut: 1,
      //   data: {
      //     image: getAssetURL("images/vehicleSelectorBackground.jpg"),
      //     title: "Test Title",
      //     subtitle: "Test Subtitle",
      //     text: "This is a test of the custom loading screen.",
      //     tips: "Here's a helpful tip!",
      //   },
      // },
    })
  }
})

onMounted(() => {
  linkLoadingScreenState(state)
  initLoadingScreen()
})
onUnmounted(() => clearTimers())
</script>

<style lang="scss" scoped>
.loading-cache {
  // this must not be display:none; in order to work
  position: absolute;
  top: 0;
  left: 0;
  width: 1px;
  height: 1px;
  opacity: 0.01;
  overflow: hidden;
  pointer-events: none;
  > img {
    width: 1px;
    height: 1px;
  }
}

.loading-screen,
.loading-background {
  position:absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  width: 100vw;
  height: 100vh;
}

.loading-screen {
  display: flex;
  justify-content: center;
  flex-direction: column;
  align-items: flex-start;
  margin: 0;
  padding: 0;
  border: 0;
  outline: none;
  background-color: #000;
  z-index: var(--zorder_loading_background);
  z-index: 13000;
  isolation: isolate;

  &::backdrop {
    display: none;
  }

  > * {
    z-index: 2;
    // pointer-events: none; // not really needed because we block input more globally
  }
}

.loading-background {
  background-size: cover;
  background-position: center center;
  z-index: 1;
}

.loading-screen-progress {
}
.loading-screen-custom {
  .loading-background {
    // display: none;
    // background-size: auto 120%;
    // background-position: 0% 50%;
    opacity: 0.1; // FIXME: uncomment to get a nicer look
  }
}

.progress-box {
  position:absolute;
  top: 35%;
  width:32em;
  height:20em;
  max-height:20em;
  padding: 2em 5em 3em 5em;
}

.loading-screen-custom {
  justify-content: flex-start;
}
.custom-box {
  position: relative;
  display: flex;
  flex-flow: row nowrap;
  justify-content: space-evenly;
  align-items: stretch;
  width: 100%;
  height: 100%;
  gap: 1em;
  color: #fff;

  &.custom-with-tips {
    height: calc(100% - 8% - 7em);
  }

  > * {
    $size: 40%;
    flex: 0 0 $size;
    position: relative;
    width: 40em;
    max-width: $size;
  }

  .custom-left-container {
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: flex-start;
    gap: 1em;
    width: 100%;
    max-height: 100%;
  }

  .custom-indeterminate-panel {
    position: absolute;
    bottom: 6em;
    width: 100%;
    .progress-bar {
      width: 32em;
    }
  }

  .custom-right-container {
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: flex-end;
  }

  .custom-image-panel {
    width: 100%;
    aspect-ratio: 16/9;
    background-position: center center;
    background-size: cover;
  }
  .custom-text-panel {
    padding: 0 1em;
  }
  .text {
    font-size: 1.5em !important;
  }
}

.progress-icon-group {
  display: flex;
  margin-left: -0.75em;
  justify-content: start;
}

.progress-icon-box {
  display: flex;
  align-items: center;
  justify-content: center;
  border: 2px solid #ff6600;
  border-radius: 10px;
  background: linear-gradient(0deg, #ff6600 0%, #ff6600 50%, rgba(0,0,0,0) 50%);
  background-size: 200% 200%;
  margin: 0.75em;
  padding: 0.25em;
  width: 3.5em;
  height: 3.5em;
}

.progress-icon {
  --bng-icon-size: 3em;
  --bng-icon-color: #fff;
}

.progress-bar-container {
  // margin-right: 1em;
  overflow: hidden;
  .progress-bar {
    transform: translateX(-1em) skewX(-23deg);
  }
}

.progress-status {
  min-height: 2em;
  border-radius:0px;
  font-style: italic;
  font-weight: 700;
  color:white;
  margin-top: 15px;
  max-width: 40em;
  word-wrap: normal;
  font-size: 2em;
}

.progress-history {
  border-radius:0px;
  color:rgb(200, 200, 200);
  text-shadow: #000 0 0 12px, #000 0 0 6px, #000 0 0 3px;
  width:100%;
  margin-top: 1em;
  min-height: 5em;
}

.tips-bar {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 8%;
  display: flex;
  align-items: baseline;
  justify-content: flex-start;
  padding: 2em 5em 3em 5em;
  background-image: linear-gradient(220deg, rgba(0, 0, 0, 0.4) 0%, rgba(0, 0, 0, 0.65) 100%);
  z-index: 2;
}
.tips-bar-title {
  font-family: "Overpass", var(--fnt-defs);
  font-style: italic;
  font-size: 1.75em;
  font-weight:bold;
  color: #fff;
}

.tips-bar-tip {
  font-size: 1.125em;
  color: #fff;
  margin-left: 0.5em;
  max-width: 36em;
}

.loading-fade-enter-active,
.loading-fade-leave-active {
  transition-property: opacity;
  transition-timing-function: cubic-bezier(0.23, 1, 0.32, 1);
}
.loading-fade-enter-active {
  transition-duration: v-bind(fadeInTimeVar);
}
.loading-fade-leave-active {
  transition-duration: v-bind(fadeOutTimeVar);
}
.loading-fade-enter-from,
.loading-fade-leave-to {
  opacity: 0;
}
.loading-fade-enter-to,
.loading-fade-leave-from {
  opacity: 1;
}
</style>
