<template>
  <EntryOverlayPopup :active="visible" :can-cancel="false" @leave="hide">
    <Transition name="wn-fade">
      <div
        v-if="visible"
        ref="dialogRoot"
        class="wn-overlay"
        :class="{ 'wn-overlay--ready': interactive }"
        role="dialog"
        aria-modal="true"
        aria-label="RLS Career Overhaul introduction"
        tabindex="-1"

        v-bng-on-ui-nav:tab_l="prevSlide"
        v-bng-on-ui-nav:back="back"
        v-bng-on-ui-nav:ok="confirm"
        v-bng-on-ui-nav:focus_l="pageLeft"
        v-bng-on-ui-nav:focus_r="pageRight"
        v-bng-on-ui-nav:tab_r="nextSlide"
      >
        <div ref="card" class="wn-card" :style="{ fontSize: `${unit}px` }" @click.stop>
          <section
            v-for="{ slide, i } in renderedSlides"
            :key="i"
            class="wn-slide"
            :class="[`wn-slide--${slide.kind || 'photo'}`, { 'is-active': i === index }]"
            :aria-hidden="i !== index"
            :inert="i !== index || undefined"
          >
            <div class="wn-slide__photo" :style="photoStyle(slide)"></div>

            <template v-if="slide.kind === 'welcome' || slide.kind === 'phone'">
              <div class="wn-vignette"></div>
              <div class="wn-scrim-left"></div>
              <div class="wn-txt wn-txt--tl wn-txt--setup">
                <div class="wn-kicker">{{ slide.kind === 'welcome' ? 'Welcome' : 'Phone shortcut' }}</div>
                <h2>{{ slide.title }}</h2>
                <p v-if="slide.summary">{{ slide.summary }}</p>
                <template v-if="slide.kind === 'phone'">
                  <p>Jobs, cars, money and navigation. All on your phone.</p>
                  <div class="wn-phone">
                    <div class="wn-phone__binding" :class="{ 'wn-phone__binding--editing': editing }">
                      <div class="wn-phone__detail">
                        <span class="wn-phone__label">{{ editing ? 'New shortcut' : 'Current shortcut' }}</span>
                        <OverhaulBindingEditor v-if="editing" :model="bindings" />
                        <BngBinding v-else action="openPhone" show-unassigned track-ignore unassigned-text="Not bound" />
                      </div>
                    </div>
                    <button v-if="!editing" type="button" class="wn-ghost wn-phone__change" data-focusable @click="changePhoneBinding">
                      {{ isPhoneBound ? 'Change shortcut' : 'Set shortcut' }}
                    </button>
                    <p v-if="!editing && bindings.error.value" class="wn-phone__error" role="alert">{{ bindings.error.value }}</p>
                    <p v-else-if="!editing" class="wn-phone__hint">One shortcut is enough. You can change it later in Phone settings.</p>
                  </div>
                </template>
              </div>
            </template>

            <template v-else-if="slide.kind === 'intro'">
              <div class="wn-vignette"></div>
              <div class="wn-scrim-left"></div>
              <div class="wn-txt wn-txt--tl wn-txt--intro">
                <div class="wn-kicker wn-kicker--log">
                  <span class="wn-log-glyph" aria-hidden="true"><i></i><i></i><i></i></span>
                  {{ slide.eyebrow || "Update log" }}
                </div>
                <h2>{{ slide.title }}</h2>
                <p v-if="slide.subtitle" class="wn-intro-subtitle">{{ slide.subtitle }}</p>
                <p v-if="slide.summary">{{ slide.summary }}</p>
                <div v-if="slide.contents !== false && contents.length" class="wn-toc">
                  <div class="wn-toc__label">{{ slide.contentsLabel || "In this update" }}</div>
                  <ol>
                    <li v-for="(entry, k) in contents" :key="k">
                      <button
                        type="button"
                        class="wn-toc__link"
                        data-focusable
                        :disabled="!interactive || editing"
                        @click.stop="go(entry.index)"
                      >
                        <span class="wn-toc__num">{{ String(k + 1).padStart(2, "0") }}</span>
                        <span class="wn-toc__title">{{ entry.title }}</span>
                      </button>
                    </li>
                  </ol>
                </div>
              </div>
            </template>

            <template v-else-if="slide.kind === 'list'">
              <div class="wn-vignette"></div>
              <div class="wn-scrim-full"></div>
              <div class="wn-grid" :style="{ gridTemplateColumns: `repeat(${(slide.columns || []).length || 1}, 1fr)` }">
                <h2>{{ slide.title }}</h2>
                <p v-if="slide.lead" class="wn-grid__lead">{{ slide.lead }}</p>
                <div v-for="(col, c) in slide.columns || []" :key="c" class="wn-col">
                  <h3>{{ col.heading }}</h3>
                  <ul>
                    <li v-for="(item, k) in col.items || []" :key="k">{{ item }}</li>
                  </ul>
                </div>
              </div>
            </template>

            <template v-else>
              <div class="wn-vignette"></div>
              <div v-if="side(slide) === 'bottom-left'" class="wn-scrim-bottom"></div>
              <div v-else class="wn-scrim-left"></div>
              <div class="wn-txt" :class="side(slide) === 'bottom-left' ? 'wn-txt--bl' : 'wn-txt--tl'">
                <div class="wn-kicker wn-kicker--photo">
                  <span v-if="photoSlides.length > 1">{{ photoIndex(i) }} of {{ photoSlides.length }}</span>
                  <span v-if="slide.kicker">{{ slide.kicker }}</span>
                </div>
                <h2>{{ slide.title }}</h2>
                <p v-if="slide.summary">{{ slide.summary }}</p>
                <ul v-if="slide.facts && slide.facts.length" class="wn-facts">
                  <li v-for="(fact, k) in slide.facts" :key="k">{{ fact }}</li>
                </ul>
              </div>
            </template>
          </section>

          <div class="wn-bar"></div>
          <div class="wn-version">{{ summary.label }}</div>

              <div class="wn-nav" v-if="slides.length > 1">
            <button type="button" class="wn-ghost" data-focusable :disabled="!interactive || editing || index === 0" @click.stop="go(index - 1)">
              <BngBinding class="wn-glyph" ui-event="tab_l" controller track-ignore />Prev
            </button>
            <div class="wn-dots">
              <button
                v-for="(slide, i) in slides"
                :key="i"
                type="button"
                :class="{ 'is-active': i === index }"
                :aria-label="`Slide ${i + 1}`"
                bng-no-nav="true"
                :disabled="!interactive || editing"
                @click.stop="go(i)"
              ></button>
            </div>
            <button type="button" class="wn-ghost" data-focusable :disabled="!interactive || editing || index === slides.length - 1" @click.stop="go(index + 1)">
              Next<BngBinding class="wn-glyph wn-glyph--after" ui-event="tab_r" controller track-ignore />
            </button>
          </div>

          <div class="wn-ctrl">
            <label v-if="plan.whatsNew" class="wn-check">
              <input v-model="dontShowAgain" type="checkbox" data-focusable :disabled="!interactive || editing" />
              <span>{{ summary.dontShowLabel || "Don't show again" }}</span>
            </label>
            <button
              ref="continueButton"
              type="button"
              class="wn-continue"
              data-focusable
              :disabled="!interactive || editing"
              bng-scoped-nav-autofocus
              @click.stop="onContinue"
            >
              <BngBinding v-if="interactive" class="wn-glyph" ui-event="ok" controller track-ignore />{{ phonePage && !isPhoneBound ? "Continue, set shortcut later" : "Continue" }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </EntryOverlayPopup>
</template>

<script setup>
import { introPages, continueIntro } from "../utils/careerIntro.js"
import { useOverhaulBindings } from "../composables/useOverhaulBindings"
import OverhaulBindingEditor from "./OverhaulBindingEditor.vue"
import EntryOverlayPopup from "./EntryOverlayPopup.vue"
import { usePhoneOpeningBlocker } from "../composables/usePhoneOpeningBlocker"
import { safeLua } from "../utils/safeLua.js"

import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngBinding } from "@/common/components/base"
import { vBngOnUiNav } from "@/common/directives"
import { loadingScreen } from "@/services/screenCover"

const STORAGE_PREFIX = "rls-career-overhaul:beta-cycle-seen:"
const EVENT_NAME = "RlsCareerIntroShow"

const bridge = useBridge()
const open = ref(false)
const plan = ref({})
const summary = computed(() => plan.value.whatsNew || {})
const bindings = useOverhaulBindings()
const editing = computed(() => bindings.capturing.value || !!bindings.pending.value || bindings.saving.value)
const isPhoneBound = computed(() => bindings.controls.getAllBindingsForAction('openPhone').length > 0)
const phonePage = computed(() => slides.value[index.value]?.kind === 'phone')
const index = ref(0)
const dialogRoot = ref(null)
const card = ref(null)
const continueButton = ref(null)
const dontShowAgain = ref(false)
const interactive = ref(false)
// `shown` stays true through the loading screen's fade-out.
const visible = computed(() => open.value && interactive.value && !loadingScreen.active && !loadingScreen.shown)
usePhoneOpeningBlocker('beta', visible)
const unit = ref(12)
let resizeObserver = null

const slides = computed(() => introPages(plan.value))
// Each mounted slide keeps its photo decoded, so only the active slide and its two
// neighbours are mounted. Hidden neighbours cannot receive navigation.
const renderedSlides = computed(() => {
  return slides.value
    .map((slide, i) => ({ slide, i }))
    .filter(({ i }) => {
      return Math.abs(i - index.value) <= 1
    })
})
const photoSlides = computed(() => slides.value.filter(s => !s.kind || s.kind === "photo"))
// Table of contents for the intro: every non-intro slide title, in order.
// "toc": false keeps a continuation page (a second "everything else" page) out of it.
const contents = computed(() =>
  slides.value
    .map((s, i) => ({ title: s.title, index: i }))
    .filter(e => !["intro", "welcome", "phone"].includes(slides.value[e.index].kind) && slides.value[e.index].toc !== false && e.title)
)

function side(slide) {
  return slide.textSide === "bottom-left" ? "bottom-left" : "top-left"
}

function photoIndex(i) {
  return photoSlides.value.indexOf(slides.value[i]) + 1
}

function imageUrl(slide) {
  if (!slide || !slide.image) return ""
  if (/^(https?:)?\/\//.test(slide.image) || slide.image.startsWith("/")) return slide.image
  return `${summary.value.imageBase || ""}${slide.image}`
}

function photoStyle(slide) {
  const url = imageUrl(slide)
  const style = url ? { backgroundImage: `url("${url}")` } : {}
  if (slide.imagePosition) style.backgroundPosition = slide.imagePosition
  // imageScale > 1 zooms the photo (anchored at imagePosition) to crop out an edge
  let scale = slide.imageScale && slide.imageScale !== 1 ? slide.imageScale : 1
  // imageBlur (px at 1080p, scaled with the card) softens a busy photo behind dense text
  if (slide.imageBlur) {
    style.filter = `blur(${(slide.imageBlur * unit.value) / 10}px)`
    scale = Math.max(scale, 1.06) // hide the blurred edge
  }
  if (scale !== 1) {
    style.transform = `scale(${scale})`
    style.transformOrigin = slide.imagePosition || "center"
  }
  return style
}

// The card mounts only once it is visible, so the slide on screen and the one after it are
// warmed here; slides further on load when the window reaches them.
function preloadNearSlides() {
  const count = slides.value.length
  if (!count) return
  for (const offset of [0, 1]) {
    const url = imageUrl(slides.value[(index.value + offset) % count])
    if (!url) continue
    const img = new Image()
    img.src = url
  }
}

function go(n) {
  if (editing.value) return
  index.value = Math.max(0, Math.min(slides.value.length - 1, n))
}

function storageKey(cycleId) {
  return `${STORAGE_PREFIX}${cycleId}`
}

function wasSeen(cycleId) {
  try {
    return window.localStorage.getItem(storageKey(cycleId)) === "true"
  } catch (_) {
    return false
  }
}

function rememberSeen(cycleId) {
  safeLua(() => window.localStorage.setItem(storageKey(cycleId), "true"), "BetaCycleSplash: rememberSeen")
}

function forgetSeen(cycleId) {
  safeLua(() => window.localStorage.removeItem(storageKey(cycleId)), "BetaCycleSplash: forgetSeen")
}

// 1em inside the card = card width / 116 (never below 9px), so every size in the SCSS is
// proportional to the card and 720p / 1440p look identical. Raise the divisor
// to make everything smaller.
function fitUnit() {
  const el = card.value
  if (!el) return
  const w = el.clientWidth || window.innerWidth
  unit.value = Math.max(9, Math.round(w / 116))
  snapToPixels(el)
}

// Centering can leave the card on a half pixel, which blurs text in CEF.
function snapToPixels(el) {
  el.style.transform = ""
  const r = el.getBoundingClientRect()
  const dx = Math.round(r.left) - r.left
  const dy = Math.round(r.top) - r.top
  if (dx || dy) el.style.transform = `translate(${dx}px, ${dy}px)`
}

function bindResizeObserver() {
  if (resizeObserver || typeof ResizeObserver === "undefined") return
  resizeObserver = new ResizeObserver(() => fitUnit())
  if (card.value) resizeObserver.observe(card.value)
}

function unbindResizeObserver() {
  if (!resizeObserver) return
  resizeObserver.disconnect()
  resizeObserver = null
}

function show(raw) {
  const data = Array.isArray(raw) ? raw[0] : raw
  if (!data || (!data.welcome && !data.whatsNew)) return
  // Resync replays one retained plan; it must not reset an open reader or editor.
  if (open.value && !data.preview) return
  plan.value = data
  index.value = 0
  dontShowAgain.value = false
  interactive.value = true
  open.value = slides.value.length > 0
  preloadNearSlides()
}

function hide() {
  bindings.cancel()
  open.value = false
  unbindResizeObserver()
}

function changePhoneBinding() {
  bindings.capture('openPhone', bindings.controls.getAllBindingsForAction('openPhone')[0] || null)
}

function onContinue() {
  if (!interactive.value || editing.value) return
  const step = continueIntro(slides.value, index.value, editing.value)
  if (!step.finish) { go(step.index); return }
  if (summary.value.id && !plan.value.preview) {
    if (dontShowAgain.value) rememberSeen(summary.value.id)
    else forgetSeen(summary.value.id)
  }
  safeLua(() => lua.overhaul_career_guide_betaWelcome.finish(dontShowAgain.value), 'Finish career introduction')
  hide()
}

function back(event) {
  event?.stopPropagation?.()
  if (bindings.pending.value && !bindings.saving.value) return bindings.cancel()
  if (editing.value) return
  if (index.value > 0) go(index.value - 1)
  else onContinue()
}

function confirm(event) {
  if (!event?.target?.closest?.('button, input')) {
    event?.stopPropagation?.()
    onContinue()
  } else return true
}

function prevSlide() {
  if (editing.value) return true
  go(index.value - 1)
}
function nextSlide() {
  if (editing.value) return true
  go(index.value + 1)
}
function pageLeft() {
  if (phonePage.value) return true
  return prevSlide()
}
function pageRight() {
  if (phonePage.value) return true
  return nextSlide()
}

async function resync() {
  const data = await lua.overhaul_career_guide_betaWelcome.getSummary(false)
  const id = data?.id
  await lua.overhaul_career_guide_betaWelcome.resync(id && wasSeen(id) ? id : null, true)
}

function requestResync() {
  return safeLua(resync, "Resync career introduction")
}

onMounted(() => {
  bridge.events.on(EVENT_NAME, show)
  bridge.events.on("RlsCareerIntroResyncRequested", requestResync)
  window.addEventListener("resize", fitUnit)
  bridge.events.on("RlsCareerIntroHide", hide)
  requestResync()
})

onBeforeUnmount(() => {
  unbindResizeObserver()
  window.removeEventListener("resize", fitUnit)
  bindings.cancel()
  bridge.events.off(EVENT_NAME, show)
  bridge.events.off("RlsCareerIntroResyncRequested", requestResync)
  bridge.events.off("RlsCareerIntroHide", hide)
})

// The popup mounts the card after `visible` turns on, so the card ref drives the fit.
watch([visible, card], ([shown, el]) => {
  unbindResizeObserver()
  if (!shown || !el) return
  bindResizeObserver()
  fitUnit()
  focusStep()
}, { flush: 'post' })
function focusStep() {
  nextTick(() => {
    const root = dialogRoot.value
    if (!root) return
    const pending = bindings.pending.value
    const selector = pending && !pending.conflicts?.length ? '.is-active .editor-buttons button:last-child:not(:disabled)'
      : editing.value ? '.is-active .binding-editor button:not(:disabled)'
      : phonePage.value && !isPhoneBound.value ? '.is-active .wn-phone__change' : '.wn-continue'
    ;(root.querySelector(selector) || continueButton.value)?.focus({ preventScroll: true })
  })
}
watch([index, editing, isPhoneBound, bindings.pending], () => { if (visible.value) focusStep() })

</script>

<style scoped lang="scss">
$orange: #ff792f;

.wn-overlay {
  position: fixed;
  inset: 0;
  z-index: 13900;
  display: grid;
  place-items: center;
  overflow: hidden;
  padding: 1.5rem;
  color: #fff;
  font-family: "Overpass", "Noto Sans", sans-serif;
  pointer-events: auto;
  background: rgba(6, 8, 10, 0.86);

  &:focus {
    outline: none;
  }
}

.wn-overlay--ready {
  z-index: 14500;
}

// The card keeps a 16:9 frame and fits whichever viewport side is tighter.
.wn-card {
  position: relative;
  width: min(calc(100vw - 6rem), calc((100vh - 6rem) * 16 / 9), 88rem);
  aspect-ratio: 16 / 9;
  overflow: hidden;
  border-radius: 0.75rem;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: #000;
  box-shadow: 0 1.5rem 5rem rgba(0, 0, 0, 0.6);
  line-height: 1.3;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
}

.wn-slide {
  position: absolute;
  inset: 0;
  opacity: 0;
  transition: opacity 350ms ease;
  pointer-events: none;

  &.is-active {
    opacity: 1;
    pointer-events: auto;
  }
}

.wn-slide__photo {
  position: absolute;
  inset: 0;
  background-size: cover;
  background-position: center;
}

// Darkening layers: long multi-stop fades, never a hard edge.
.wn-vignette {
  position: absolute;
  inset: 0;
  background: radial-gradient(ellipse at 55% 45%, rgba(0, 0, 0, 0) 35%, rgba(0, 0, 0, 0.18) 65%, rgba(0, 0, 0, 0.5) 100%);
}

.wn-scrim-left {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 78%;
  background: linear-gradient(to right, rgba(0, 0, 0, 0.66) 0%, rgba(0, 0, 0, 0.52) 22%, rgba(0, 0, 0, 0.32) 48%, rgba(0, 0, 0, 0.12) 76%, rgba(0, 0, 0, 0) 100%);
}

.wn-scrim-bottom {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 80%;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.78) 0%, rgba(0, 0, 0, 0.58) 22%, rgba(0, 0, 0, 0.32) 50%, rgba(0, 0, 0, 0.1) 78%, rgba(0, 0, 0, 0) 100%);
}

.wn-scrim-full {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.72) 0%, rgba(0, 0, 0, 0.6) 30%, rgba(0, 0, 0, 0.42) 60%, rgba(0, 0, 0, 0.28) 100%);
}

.wn-txt {
  position: absolute;
  z-index: 0;
  width: 46em;
  max-width: 60%;

  // soft halo behind the text; closest-side sizing guarantees it reaches
  // transparent before the box edge, so no seam
  &::before {
    content: "";
    position: absolute;
    inset: -9em -22em -9em -14em;
    z-index: -1;
    background: radial-gradient(closest-side at 40% 50%, rgba(0, 0, 0, 0.5) 0%, rgba(0, 0, 0, 0.38) 28%, rgba(0, 0, 0, 0.2) 58%, rgba(0, 0, 0, 0.06) 84%, rgba(0, 0, 0, 0) 100%);
  }

  h2 {
    margin: 0;
    font-size: 3.4em;
    font-weight: 700;
    line-height: 1.02;
    letter-spacing: -0.02em;
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.55);
  }

  p {
    margin: 0.55em 0 0;
    font-size: 1.45em;
    font-weight: 400;
    line-height: 1.35;
    color: rgba(255, 255, 255, 0.9);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
  }
}

.wn-txt--tl {
  left: 5em;
  top: 5em;
}

.wn-txt--bl {
  left: 5em;
  bottom: 9.5em;
}

.wn-txt--intro {
  width: 50em;

  h2 {
    font-size: 2.7em;
  }
}

.wn-kicker--log {
  display: flex;
  align-items: center;
  gap: 0.6em;
}

.wn-kicker--photo {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.15em 0.9em;
}

.wn-log-glyph {
  display: inline-grid;
  gap: 0.18em;
  width: 1.1em;

  i {
    display: block;
    height: 0.16em;
    border-radius: 0.08em;
    background: $orange;

    &:nth-child(2) {
      width: 70%;
    }

    &:nth-child(3) {
      width: 85%;
    }
  }
}

.wn-intro-subtitle {
  margin-top: 0.35em !important;
  font-size: 1.15em !important;
  font-weight: 600 !important;
  color: rgba(255, 255, 255, 0.72) !important;
}

.wn-toc {
  margin-top: 1.4em;

  ol {
    margin: 0;
    padding: 0;
    list-style: none;
    display: grid;
    gap: 0.45em;
  }

  li {
    font-size: 1.05em;
  }
}

// Controller (.focus-visible) and keyboard focus: the house ring (rlsHouse --focus values) on a
// positioned control, with the game's ::before frame hidden (the splash is teleported to <body>)
@mixin pad-focus {
  position: relative;
  &.focus-visible:not(:disabled) {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600),
      0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
  }
  &.focus-visible::before {
    display: none !important;
  }
}
.wn-phone__change { @include pad-focus; }
.wn-txt--setup { max-width: 56em; }
.wn-slide--phone {
  .wn-slide__photo { filter: brightness(0.72); }
  .wn-scrim-left {
    width: 100%;
    background: radial-gradient(ellipse at center, rgba(0, 0, 0, .55), rgba(0, 0, 0, .2));
  }
  // The spacer only shrinks when the editor would reach the nav row, so the heading stays put.
  .wn-txt--setup {
    left: 50%;
    top: 4em;
    bottom: 9.5em;
    transform: translateX(-50%);
    display: flex;
    flex-direction: column;
    width: 50em;
    max-width: 80%;
    text-align: center;

    &::after { content: ""; order: -1; flex: 0 1 15em; }
  }
  h2 { font-size: 3.2em; }
}
.wn-phone {
  width: min(100%, 40em);
  margin: 2em auto 0;
  padding: 1.8em;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 0.75em;
  background: rgba(18, 18, 20, 0.78);
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  box-shadow: 0 1em 3em rgba(0, 0, 0, 0.18);
  text-align: center;
}
.wn-phone__binding { margin-bottom: 1.5em; }
.wn-phone__binding--editing { margin-bottom: 0; }
.wn-phone__detail {
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  gap: 0.8em;
  min-width: 0;
  padding: 1.5em;
  border: 1px solid rgba(255, 255, 255, 0.09);
  border-radius: 0.5em;
  background: rgba(255, 255, 255, 0.045);
  font-size: 1.2em;
  overflow-wrap: anywhere;
}
.wn-phone__label { color: rgba(255, 255, 255, 0.5); font-size: 0.65em; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; }
.wn-ghost.wn-phone__change {
  padding: 0.65em 1.8em;
  font-size: 1.1em;
  transition: background 160ms ease, border-color 160ms ease, transform 160ms ease;
  &:hover { transform: translateY(-1px); }
  &:active { transform: translateY(0); }
}
.wn-phone .wn-phone__hint, .wn-phone .wn-phone__error { margin-top: 1.1em; font-size: 1.05em; color: rgba(255, 255, 255, 0.65); text-shadow: none; }
.wn-phone .wn-phone__error { color: #ffb38a; }
.wn-phone :deep(.binding-editor) {
  width: 100%;
  min-width: 0;
  max-height: min(24em, 36vh);
  overflow-y: auto;
  padding: 0;
  border: 0;
  background: none;
  font-size: 0.84em;
  text-align: center;

  .editor-buttons { justify-content: center; gap: 0.8em; }
  .binding-facts, ul { text-align: left; }
  .binding-facts { padding: 0.8em 1em; border-radius: 0.5em; background: rgba(255, 255, 255, 0.045); }
  h3 { margin: 0 0 0.6em; font-size: 1.65em; color: #fff; }
  p { max-width: 26em; margin: 0 auto 1.4em; line-height: 1.6; }
  p, li, .binding-facts { font-size: 1.1em; }
  .binding-facts dt { font-size: 0.8em; }
  > button, .editor-buttons button { padding: 0.55em 1.3em; border-radius: 0.4em; font: inherit; font-size: 1.1em; font-weight: 700; }
}
.wn-slide--phone.is-active {
  .wn-phone { animation: wn-phone-arrive 280ms ease-out both; }
  .wn-phone__detail { animation: wn-phone-arrive 300ms 60ms ease-out both; }
  .binding-editor { animation: wn-phone-arrive 180ms ease-out both; }
}
@keyframes wn-phone-arrive {
  from { opacity: 0; transform: translateY(0.6em); }
  to { opacity: 1; transform: translateY(0); }
}
@media (prefers-reduced-motion: reduce) {
  .wn-slide--phone.is-active .wn-phone,
  .wn-slide--phone.is-active .wn-phone__detail,
  .wn-slide--phone.is-active .binding-editor { animation: none; }
  .wn-ghost.wn-phone__change { transition: none; &:hover { transform: none; } }
}
.wn-glyph {
  margin-right: 0.4em;
  vertical-align: middle;
  &--after {
    margin-right: 0;
    margin-left: 0.4em;
  }
}

.wn-toc__link {
  @include pad-focus;
  display: flex;
  align-items: baseline;
  gap: 0.8em;
  width: 100%;
  margin: 0 -0.5em;
  padding: 0.15em 0.5em;
  border: 0;
  border-radius: 0.3em;
  background: transparent;
  color: rgba(255, 255, 255, 0.86);
  font: inherit;
  text-align: left;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
  cursor: pointer;

  &:hover:not(:disabled),
  &.focus-visible:not(:disabled) {
    outline: none;
    background: rgba(255, 255, 255, 0.1);
    color: #fff;
  }

  &:hover:not(:disabled) .wn-toc__title,
  &.focus-visible:not(:disabled) .wn-toc__title {
    text-decoration: underline;
    text-underline-offset: 0.15em;
    text-decoration-color: rgba(255, 121, 47, 0.8);
  }

  &:disabled {
    cursor: default;
  }
}

.wn-toc__label {
  margin-bottom: 0.6em;
  padding-bottom: 0.5em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.18);
  font-size: 0.8em;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.6);
}

.wn-toc__num {
  flex: 0 0 1.6em;
  font-weight: 700;
  color: $orange;
}

.wn-kicker {
  margin-bottom: 0.5em;
  font-size: 0.9em;
  font-weight: 700;
  letter-spacing: 0.16em;
  text-transform: uppercase;
  color: $orange;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
}

.wn-facts {
  margin: 1em 0 0;
  padding: 0;
  list-style: none;
  display: grid;
  gap: 0.5em;

  li {
    display: flex;
    align-items: flex-start;
    gap: 0.7em;
    font-size: 1.2em;
    line-height: 1.3;
    color: rgba(255, 255, 255, 0.82);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);

    &::before {
      content: "";
      flex: 0 0 auto;
      width: 0.2em;
      height: 1em;
      margin-top: 0.15em;
      border-radius: 0.1em;
      background: $orange;
    }
  }
}

// "Everything else" page
.wn-grid {
  position: absolute;
  z-index: 0;
  left: 5em;
  right: 5em;
  top: 5em;
  bottom: 9.5em;
  display: grid;
  gap: 3em;
  align-content: start;

  &::before {
    content: "";
    position: absolute;
    inset: -8em -10em;
    z-index: -1;
    background: radial-gradient(closest-side at 50% 45%, rgba(0, 0, 0, 0.45) 0%, rgba(0, 0, 0, 0.28) 55%, rgba(0, 0, 0, 0.08) 85%, rgba(0, 0, 0, 0) 100%);
  }

  h2 {
    grid-column: 1 / -1;
    margin: 0;
    font-size: 3.2em;
    font-weight: 700;
    line-height: 1.02;
    letter-spacing: -0.02em;
  }
}

.wn-grid__lead {
  grid-column: 1 / -1;
  margin: -1.5em 0 0;
  font-size: 1.4em;
  color: rgba(255, 255, 255, 0.8);
}

.wn-col {
  h3 {
    margin: 0 0 0.8em;
    padding-bottom: 0.6em;
    border-bottom: 0.1em solid rgba(255, 255, 255, 0.18);
    font-size: 1.05em;
    font-weight: 700;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: $orange;
  }

  ul {
    margin: 0;
    padding: 0;
    list-style: none;
    display: grid;
    gap: 0.55em;
  }

  li {
    display: flex;
    gap: 0.7em;
    font-size: 1.2em;
    line-height: 1.3;
    color: rgba(255, 255, 255, 0.88);

    &::before {
      content: "";
      flex: 0 0 auto;
      width: 0.2em;
      height: 1em;
      margin-top: 0.15em;
      border-radius: 0.1em;
      background: $orange;
    }
  }
}

// Chrome
.wn-bar {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 12em;
  pointer-events: none;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.85) 0%, rgba(0, 0, 0, 0.6) 30%, rgba(0, 0, 0, 0.28) 62%, rgba(0, 0, 0, 0.06) 88%, rgba(0, 0, 0, 0) 100%);
}

.wn-version {
  position: absolute;
  left: 3em;
  bottom: 3em;
  font-size: 0.8em;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.6);
}

.wn-nav {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 2.4em;
  width: max-content;
  margin: 0 auto;
  display: flex;
  align-items: center;
  gap: 1.2em;
}

.wn-ghost {
  @include pad-focus;
  padding: 0.5em 1.1em;
  border: 1px solid rgba(255, 255, 255, 0.55);
  border-radius: 0.4em;
  background: rgba(0, 0, 0, 0.35);
  color: #fff;
  font: inherit;
  font-size: 0.9em;
  font-weight: 700;
  cursor: pointer;

  &:hover:not(:disabled),
  &.focus-visible:not(:disabled) {
    outline: none;
    border-color: #fff;
    background: rgba(255, 255, 255, 0.12);
  }

  &:disabled {
    opacity: 0.45;
    cursor: default;
  }
}

.wn-dots {
  display: flex;
  gap: 0.7em;

  button {
    width: 0.6em;
    height: 0.6em;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.45);
    cursor: pointer;

    &.is-active {
      background: $orange;
      box-shadow: 0 0 0 0.22em rgba(255, 121, 47, 0.28);
    }
  }
}

.wn-ctrl {
  position: absolute;
  right: 3em;
  bottom: 2.4em;
  display: flex;
  align-items: center;
  gap: 1.5em;
}

.wn-check {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.9em;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.88);
  cursor: pointer;
  user-select: none;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);

  input {
    width: 1.2em;
    height: 1.2em;
    margin: 0;
    accent-color: $orange;
    cursor: pointer;
  }

  input {
    @include pad-focus;
  }
}

.wn-continue {
  @include pad-focus;
  padding: 0.6em 1.5em;
  border: 0;
  border-radius: 0.4em;
  background: $orange;
  color: #17191c;
  font: inherit;
  font-size: 0.95em;
  font-weight: 700;
  cursor: pointer;
  box-shadow: 0 0.5em 1.5em rgba(0, 0, 0, 0.5);
  transition: transform 120ms ease, background 120ms ease, box-shadow 120ms ease;

  &:hover:not(:disabled) {
    outline: none;
    background: #ff965d;
    box-shadow: 0 0 0 0.18em rgba(255, 150, 93, 0.35), 0 0.5em 1.5em rgba(0, 0, 0, 0.5);
    transform: translateY(-1px);
  }
  &.focus-visible:not(:disabled) {
    background: #ff965d;
    transform: translateY(-1px);
  }

  &:disabled {
    cursor: wait;
    color: rgba(23, 25, 28, 0.7);
    background: #c88963;
    box-shadow: none;
    transform: none;
  }
}

.wn-fade-enter-active,
.wn-fade-leave-active {
  transition: opacity 280ms ease;
}

.wn-fade-enter-from,
.wn-fade-leave-to {
  opacity: 0;
}
</style>
