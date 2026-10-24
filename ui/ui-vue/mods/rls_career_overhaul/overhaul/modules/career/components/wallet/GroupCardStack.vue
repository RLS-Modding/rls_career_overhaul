<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- A deck of wallet groups (vehicles, work types, categories, months). Each card peeks out by its
     header over the one before it; choosing a card pulls it out of the deck on a spring, the rest
     recede, and it opens to show everything. Back, or choosing the pulled-out header again, slides
     it into its slot along the same path.
     A screen fills the slots and sets the look through --stack-* variables:
       #card="{ group }"            compact header (name, colour, count, net)
       #detail="{ group, close, limit, page, showMore }"   everything else under the same header when
                                    pulled out; long lists page by `limit` (showMore adds a page)
     Motion is one critically damped spring (0 = in the deck, 1 = pulled out), transform and opacity
     only; reduced motion turns it into a short cross-fade. -->
<template>
  <div ref="viewportRef" class="stack-viewport" :class="{ 'is-open': !!openGroup, moving }">
    <!-- While a card is out the deck is out of reach for every input, not only the controller. Once
         it starts sliding back the deck answers again, so a card can be picked mid-close. -->
    <div ref="deckRef" class="stack-deck" v-bng-ui-nav-scroll.force :bng-no-child-nav="opening ? 'true' : null"
      :aria-hidden="opening ? 'true' : null" :inert="opening">
      <ol class="stack-list" :aria-label="label">
        <li v-for="(group, index) in groups" :key="group.id" class="stack-slot"
          :style="{ zIndex: index + 1, '--stack-tint': tint(group), '--stack-back': Math.min(groups.length - 1 - index, MAX_BACK) }">
          <button type="button" class="stack-card" :class="{ lifted: openGroup && openGroup.id === group.id }"
            :data-fk="`stack-${group.id}`" bng-nav-item :aria-expanded="openGroup && openGroup.id === group.id ? 'true' : 'false'"
            @click="open(group, $event.currentTarget)">
            <slot name="card" :group="group" />
          </button>
        </li>
      </ol>
    </div>

    <!-- Keyed per pull-out: a card reopened mid-close gets a fresh layer, so Back (B) registers again
         and focus returns to the card that was actually opened. -->
    <!-- A card sliding back is on its way out: no longer modal and out of reach of Tab. -->
    <PhoneLayer v-if="openGroup" :key="layerKey" :label="`${detailLabel} details`" :active="opening" class="stack-detail"
      :class="{ closing: !opening }" :inert="!opening" :aria-hidden="opening ? null : 'true'" @close="close" @keydown.esc.stop="close">
      <div ref="sheetRef" class="stack-sheet" :style="{ '--stack-head': `${headHeight}px` }">
        <div class="stack-sheet-body" v-bng-ui-nav-scroll.force>
          <slot name="detail" :group="openGroup" :close="close" :limit="detailLimit" :page="page" :show-more="showMore" />
        </div>
      </div>
      <!-- The pulled-out header is its own way back: tap, click or A on it puts the card away. -->
      <button ref="liftRef" type="button" class="stack-card stack-lift" bng-nav-item aria-expanded="true"
        :style="{ '--stack-tint': tint(openGroup) }" @click="close">
        <slot name="card" :group="openGroup" />
        <span class="stack-lift-chevron" aria-hidden="true"></span>
        <span class="stack-hidden-label">, back to all</span>
      </button>
    </PhoneLayer>
  </div>
</template>

<script setup>
import { nextTick, onBeforeUnmount, ref, shallowRef, watch } from "vue"
import { vBngUiNavScroll } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import PhoneLayer from "../phone/PhoneLayer.vue"
import { createSpring } from "../../utils/springMotion.js"
import { prefersReducedMotion } from "../../utils/walletFinance.js"

const props = defineProps({
  groups: { type: Array, default: () => [] },
  label: { type: String, default: "Groups" },
  detailLabel: { type: String, default: "Group" },
  // Each card's colour (the group's accent); it tints the card so overlapping edges read apart.
  tint: { type: Function, default: () => "#8e8e93" },
  // Transactions shown at first in a pulled-out card; more come a page at a time.
  page: { type: Number, default: 50 },
})
const emit = defineEmits(["open", "more", "close"])

const PULL_RESPONSE = 0.38
const FADE_RESPONSE = 0.14
// How much the card swells at the middle of the pull, like a card lifted off the deck.
const LIFT_SCALE = 0.03
// Cards further back in the deck sit a little narrower, up to this many steps, so the deck shows
// its depth at the sides as well as at each top edge.
const MAX_BACK = 4
const RECEDE_SCALE = 0.04

const viewportRef = ref(null)
const deckRef = ref(null)
const sheetRef = ref(null)
const liftRef = ref(null)
const openGroup = shallowRef(null)
const opening = ref(false)
const headHeight = ref(0)
const layerKey = ref(0)
const detailLimit = ref(0)
// The deck and pulled-out layers get their own compositing layer only while they move.
const moving = ref(false)
let slotTop = 0
let slotScale = 1
let reduced = false

const spring = createSpring({
  value: 0, response: PULL_RESPONSE, damping: 1,
  onUpdate: paint,
  onRest: value => {
    moving.value = false
    if (value === 0 && !opening.value) {
      openGroup.value = null
      paint(0)
    }
  },
})

const clamp = value => Math.min(1, Math.max(0, value))

function paint(progress) {
  const p = clamp(progress)
  const lift = liftRef.value
  const sheet = sheetRef.value
  const deck = deckRef.value
  if (reduced) {
    if (lift) { lift.style.transform = ""; lift.style.opacity = String(p) }
    if (sheet) { sheet.style.transform = ""; sheet.style.opacity = String(p) }
    if (deck) { deck.style.transform = ""; deck.style.opacity = String(1 - 0.7 * p) }
    return
  }
  // The card travels from its slot to the top, swelling slightly mid-way and settling flat.
  if (lift) {
    lift.style.opacity = "1"
    const scale = slotScale + (1 - slotScale) * p + LIFT_SCALE * 4 * p * (1 - p)
    lift.style.transform = `translateY(${(1 - p) * slotTop}px) scale(${scale})`
  }
  // The rest of the pulled-out card opens under it, following it out of the slot.
  if (sheet) {
    const body = clamp((p - 0.25) / 0.75)
    sheet.style.opacity = String(body)
    sheet.style.transform = `translateY(${(1 - p) * slotTop}px) scale(${0.97 + 0.03 * body})`
  }
  // The deck steps back and dims behind it.
  if (deck) {
    deck.style.opacity = String(1 - 0.65 * p)
    deck.style.transform = p > 0 ? `scale(${1 - RECEDE_SCALE * p})` : ""
  }
}

// Layout pixels of the card's top inside the viewport (the UI can be drawn scaled).
function measure(card) {
  const viewport = viewportRef.value
  if (!card?.getBoundingClientRect || !viewport?.getBoundingClientRect) return { top: 0, height: card?.offsetHeight || 0, widthRatio: 1 }
  const box = card.getBoundingClientRect()
  const frame = viewport.getBoundingClientRect()
  const scale = frame.height / (viewport.offsetHeight || frame.height || 1)
  const widthRatio = box.width && frame.width ? Math.min(1, box.width / frame.width) : 1
  return { top: (box.top - frame.top) / scale, height: card.offsetHeight || box.height / scale, widthRatio }
}

// Group ids come from add-ons too, so match the attribute value instead of building a selector.
function cardFor(id) {
  const wanted = `stack-${id}`
  return [...(deckRef.value?.querySelectorAll?.("[data-fk]") || [])].find(card => card.dataset?.fk === wanted) || null
}
function place(card) {
  const { top, height, widthRatio } = measure(card)
  slotTop = top
  slotScale = widthRatio
  return height
}

async function open(group, card) {
  reduced = prefersReducedMotion()
  const response = reduced ? FADE_RESPONSE : PULL_RESPONSE
  const same = openGroup.value && openGroup.value.id === group.id
  // Another card while one slides back: let that one land first.
  if (openGroup.value && !same) spring.set(0)
  if (!same) {
    headHeight.value = place(card)
    detailLimit.value = props.page
  }
  // The same card mid-close turns round from where it is (the spring keeps its value).
  layerKey.value++
  openGroup.value = group
  opening.value = true
  emit("open", group)
  moving.value = true
  await nextTick()
  // A refresh may have swapped in a fresh copy of the same group; anything else superseded us.
  if (openGroup.value?.id !== group.id || !opening.value) {
    if (!openGroup.value) { opening.value = false; moving.value = false }
    return
  }
  paint(spring.value)
  spring.to(1, { response })
}

function close() {
  if (!openGroup.value || !opening.value) return
  opening.value = false
  emit("close")
  moving.value = true
  // The deck may have been re-sorted while the card was out: go back to where its slot is now.
  const card = cardFor(openGroup.value.id)
  if (card) place(card)
  spring.to(0, { response: reduced ? FADE_RESPONSE : PULL_RESPONSE })
  // The sliding-back layer is inert at once, so hand focus to the card it is returning to.
  if (card) nextTick(() => { if (!opening.value) setFocus(card) })
}

function showMore() {
  detailLimit.value += props.page
  emit("more", openGroup.value, detailLimit.value)
}

// A refresh that drops the open group puts the card away at once and keeps focus in the deck.
watch(() => props.groups, groups => {
  if (!openGroup.value) return
  const still = groups.find(group => group.id === openGroup.value.id)
  if (still) { openGroup.value = still; return }
  opening.value = false
  emit("close")
  spring.set(0)
  openGroup.value = null
  nextTick(() => {
    const first = deckRef.value?.querySelector?.("[bng-nav-item]")
    if (first) setFocus(first)
  })
})

onBeforeUnmount(() => spring.stop())
</script>

<style scoped>
.stack-viewport { position: relative; display: flex; flex-direction: column; min-height: 0; flex: 1 1 auto; }
.stack-viewport.moving .stack-deck { will-change: transform, opacity; }
.stack-deck {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0 0 calc(var(--stack-depth, 0.8em) + 0.6em);
  transform-origin: 50% 0;
  scrollbar-width: none;
}
.stack-deck::-webkit-scrollbar { display: none; }
.stack-list { display: grid; margin: 0; padding: 0; list-style: none; }
/* Each card hangs a little "back" below itself that the next card covers, so the deck reads as
   overlapping cards while every header stays a separate, non-overlapping target for the d-pad. */
.stack-slot { position: relative; margin: 0 calc(var(--stack-inset, 0.4em) * var(--stack-back, 0)); }
.stack-card {
  position: relative;
  display: block;
  width: 100%;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: var(--stack-radius, 0.7em) var(--stack-radius, 0.7em) 0 0;
  /* A tinted face, lighter at the top edge, so each card's edge stands off the one behind it. */
  background:
    linear-gradient(180deg, color-mix(in srgb, var(--stack-tint, #8e8e93) 24%, var(--stack-card-bg, #26262b)),
      color-mix(in srgb, var(--stack-tint, #8e8e93) 10%, var(--stack-card-bg, #26262b)));
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
  box-shadow: var(--stack-edge, inset 0 1px 0 rgba(255, 255, 255, 0.12)), 0 -0.35em 0.9em -0.2em rgba(0, 0, 0, 0.7);
  transition: transform 100ms ease-out;
}
.stack-card::after {
  content: "";
  position: absolute;
  left: 0;
  right: 0;
  top: 100%;
  height: var(--stack-depth, 0.8em);
  border-radius: 0 0 var(--stack-radius, 0.7em) var(--stack-radius, 0.7em);
  background: color-mix(in srgb, var(--stack-tint, #8e8e93) 10%, var(--stack-card-bg, #26262b));
  pointer-events: none;
}
.stack-card:active { transform: scale(0.985); }
.stack-card.lifted { opacity: 0; }

.stack-detail { position: absolute; inset: 0; z-index: 30; }
.stack-detail.closing { pointer-events: none; }
.stack-sheet {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  padding-top: var(--stack-head, 3em);
  border-radius: var(--stack-radius, 0.7em);
  background: var(--stack-sheet-bg, #1f1f23);
  box-shadow: 0 0.8em 2em rgba(0, 0, 0, 0.55);
  transform-origin: 50% 0;
  opacity: 0;
  will-change: transform, opacity;
}
.stack-sheet-body { flex: 1 1 auto; min-height: 0; overflow-y: auto; }
/* The phone apps' scrollbar (Broker, Search): a slim rounded thumb on a clear track. Set through the
   -webkit- parts only; scrollbar-width or scrollbar-color would switch them off. */
.stack-sheet-body::-webkit-scrollbar { width: 0.45em; height: 0.45em; }
.stack-sheet-body::-webkit-scrollbar-track { background: transparent; }
.stack-sheet-body::-webkit-scrollbar-thumb { border: 0.1em solid transparent; border-radius: 1em; background: rgba(255, 255, 255, 0.22); background-clip: padding-box; }
.stack-sheet-body::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
.stack-lift {
  position: absolute;
  left: 0;
  right: 0;
  top: 0;
  border-radius: var(--stack-radius, 0.7em);
  box-shadow: 0 0.6em 1.4em rgba(0, 0, 0, 0.5);
  transform-origin: 50% 50%;
  will-change: transform;
}
.stack-lift::after { display: none; }
/* A small up-chevron in the corner: the header folds the card away. Drawn with borders, no icon font. */
.stack-lift-chevron {
  position: absolute;
  top: 0.95em;
  right: 1em;
  width: 0.42em;
  height: 0.42em;
  border-top: 2px solid currentColor;
  border-left: 2px solid currentColor;
  opacity: 0.55;
  transform: translateY(25%) rotate(45deg);
  pointer-events: none;
}
.stack-hidden-label { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
@media (prefers-reduced-motion: reduce) {
  .stack-card:active { transform: none; }
}
</style>
