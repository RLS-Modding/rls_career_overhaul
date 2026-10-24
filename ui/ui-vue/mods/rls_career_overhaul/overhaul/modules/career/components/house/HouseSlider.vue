<!-- Style Guide slider (.slider) on top of the game's BngSlider, so scoped controller nav, ok/back confirm,
     held-direction repeat, the embedded number box (with-input) and reset (with-reset) all still work.
     Drop-in for BngSlider: every prop, v-model, event and the exposed dirty API pass straight through. -->
<template>
  <BngSlider ref="inner" v-bind="$attrs" class="rls-house house-slider" />
</template>

<script setup>
import { nextTick, onBeforeUnmount, onMounted, ref, useAttrs, watch } from "vue"
import { BngSlider } from "@/common/components/base"

defineOptions({ inheritAttrs: false })
const attrs = useAttrs()

// Forward BngSlider's exposed API (dirty, markClean, activateSlider, ...) so a ref on this
// wrapper behaves like a ref on BngSlider.
const inner = ref(null)
defineExpose(
  new Proxy(
    {},
    {
      get: (target, key) => (key in target ? target[key] : inner.value?.[key]),
      has: (target, key) => key in target || (!!inner.value && key in inner.value),
    }
  )
)

// Fill follows the thumb live. BngSlider only moves its own fill when it emits a committed value,
// so the bar trailed the thumb while dragging; we draw the fill from the range input's live value.
let rangeEl = null
let numEl = null
const clamp01 = x => Math.min(1, Math.max(0, x))
const updateFill = () => {
  if (!rangeEl) return
  const min = Number(rangeEl.min), max = Number(rangeEl.max), v = Number(rangeEl.value)
  const span = max - min
  rangeEl.style.setProperty("--p", String(span > 0 ? clamp01((v - min) / span) : 0))
  // default-position notch (orig-value = the vehicle's stock setting)
  const orig = Number(attrs.origValue ?? attrs["orig-value"])
  if (span > 0 && Number.isFinite(orig)) rangeEl.style.setProperty("--d", String(clamp01((orig - min) / span)))
  else rangeEl.style.removeProperty("--d")
}

// Arrow up/down in the number box moves the slider right away (BngSlider applies typed values on
// blur/enter only). Typing stays as it was, so partial input like "3." is never rewritten mid-edit.
const pushNumber = e => {
  if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return
  const v = Number(numEl?.value)
  if (!Number.isFinite(v)) return
  attrs["onUpdate:modelValue"]?.(v)
  attrs.onValueChanged?.(v)
}

// Controller steps change the range's value directly (no "input" event) and BngSlider only emits
// after its debounce, so the fill trailed the thumb on a pad. While the slider has focus, follow the
// range's value each frame and redraw only when it changes; the loop stops as soon as focus leaves.
let followRaf = 0
let lastValue = null
const follow = () => {
  if (!rangeEl) return (followRaf = 0)
  if (rangeEl.value !== lastValue) {
    lastValue = rangeEl.value
    updateFill()
  }
  followRaf = requestAnimationFrame(follow)
}
const startFollow = () => {
  if (!followRaf) followRaf = requestAnimationFrame(follow)
}
const stopFollow = event => {
  const root = inner.value?.$el
  if (event?.relatedTarget && root?.contains(event.relatedTarget)) return
  if (followRaf) cancelAnimationFrame(followRaf)
  followRaf = 0
  updateFill()
}

// Controller hints (BngSlider's "edit value" / "reset" popovers) are teleported to the page-wide
// popover layer, out of reach of scoped styles. While any house slider is mounted, a body class
// turns on the house hint look below (career only: freeroam sliders never set it).
const HINT_CLASS = "rls-house-slider-hints"
const hintUsers = (window.__rlsHouseSliderHints = window.__rlsHouseSliderHints || { n: 0 })

onMounted(() => {
  if (hintUsers.n++ === 0) document.body.classList.add(HINT_CLASS)
  const root = inner.value?.$el
  rangeEl = root?.querySelector?.("input.bng-slider") || null
  numEl = root?.querySelector?.(".bng-slider-input input") || null
  rangeEl?.addEventListener("input", updateFill)
  numEl?.addEventListener("keyup", pushNumber)
  root?.addEventListener?.("focusin", startFollow)
  root?.addEventListener?.("focusout", stopFollow)
  updateFill()
})
onBeforeUnmount(() => {
  if (--hintUsers.n <= 0) {
    hintUsers.n = 0
    document.body.classList.remove(HINT_CLASS)
  }
  rangeEl?.removeEventListener("input", updateFill)
  numEl?.removeEventListener("keyup", pushNumber)
  const root = inner.value?.$el
  root?.removeEventListener?.("focusin", startFollow)
  root?.removeEventListener?.("focusout", stopFollow)
  if (followRaf) cancelAnimationFrame(followRaf)
  followRaf = 0
})
watch(() => [attrs.modelValue, attrs.min, attrs.max, attrs.origValue, attrs["orig-value"]], () => nextTick(updateFill))
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/components/house/houseFieldSkin.scss" as *;

// controller focus: only the thumb lights up (Tristan: a ring around the whole slider was too much).
// The game's ::before frame is hidden on the container and the range, and the thumb glow shows both
// when the slider's scope is focused and while editing.
.house-slider.focus-visible {
  outline: none;
}
.house-slider.focus-visible::before,
.house-slider :deep(.focus-visible)::before {
  display: none !important;
}
.house-slider.focus-visible :deep(input.bng-slider)::-webkit-slider-thumb,
.house-slider :deep(input.bng-slider.focus-visible)::-webkit-slider-thumb {
  background-color: #fff;
  box-shadow: 0 0 0 0.22em rgba(255, 102, 0, 0.55), 0 0.05em 0.3em rgba(0, 0, 0, 0.35);
}

.house-slider {
  align-items: center;
  gap: 0.45em;
  color: #fff;

  // Track: a 0.45em band with the orange fill up to the thumb centre, plus a thin white notch at
  // the default (stock) value. --p / --d (0..1) are set from script; the calc maps them under the
  // thumb centre (thumb 1.15em wide). The input itself is thumb-tall so the notch can stand proud of
  // the band; BngSlider's own inline background-position fill is overridden (it lagged the thumb).
  position: relative;
  :deep(.bng-slider) {
    --fill-x: calc(0.575em + var(--p, 0) * (100% - 1.15em));
    --mark-x: calc(0.575em + var(--d, -10) * (100% - 1.15em));
    height: 1.15em;
    margin: calc(var(--bng-slider-margin, 0.45em) - 0.35em) 0;
    border-radius: 0;
    background-color: transparent;
    background-image:
      linear-gradient(
        90deg,
        transparent calc(var(--mark-x) - 1px),
        rgba(255, 255, 255, 0.75) calc(var(--mark-x) - 1px) calc(var(--mark-x) + 1px),
        transparent calc(var(--mark-x) + 1px)
      ),
      linear-gradient(90deg, var(--accent) 0 var(--fill-x), rgba(255, 255, 255, 0.12) 0) !important;
    background-size: 100% 0.85em, 100% 0.45em !important;
    background-position: 0 50%, 0 50% !important;
    background-repeat: no-repeat !important;
    cursor: pointer;

    &::-webkit-slider-thumb {
      width: 1.15em;
      height: 1.15em;
      border: 0;
      border-radius: 50%;
      transform: none;
      background: #fff;
      box-shadow: 0 0.05em 0.3em rgba(0, 0, 0, 0.35);
      transition: box-shadow 0.12s;
    }

    &:focus {
      &::-webkit-slider-thumb {
        background-color: #fff;
        box-shadow: 0 0 0 0.22em rgba(255, 102, 0, 0.55), 0 0.05em 0.3em rgba(0, 0, 0, 0.35);
      }
    }

    // Firefox (Atlas only; the game is Chromium): same band and thumb
    &::-moz-range-track {
      height: 0.45em;
      border-radius: 1em;
      background: linear-gradient(90deg, var(--accent) 0 calc(var(--p, 0) * 100%), rgba(255, 255, 255, 0.12) 0);
    }
    &::-moz-range-thumb {
      width: 1.15em;
      height: 1.15em;
      border: 0;
      border-radius: 50%;
      background: #fff;
    }

    &[disabled] {
      opacity: 0.45;
      &::-webkit-slider-thumb {
        background-color: #fff !important;
        box-shadow: none;
      }
    }
  }

  // embedded number box: quiet field (hairline, row shows through) sized for 5-digit values plus a unit
  :deep(.bng-slider-input) {
    @include house-bng-input-root;
    flex: 0 0 6.6em;
    width: 6.6em;
    height: 2.1em;
    margin-left: 0.15em;
    background: rgba(0, 0, 0, 0.14);
    border-color: rgba(255, 255, 255, 0.12);
  }
  :deep(.bng-slider-input .input-container) {
    padding-left: 0.45em;
  }
  :deep(.bng-slider-input .suffix) {
    padding-right: 0.45em;
  }
  @include house-bng-input-parts(".bng-slider-input");

  // embedded reset: compact quiet icon button, lifted onto the label line (top right of the row)
  // so the number box gets that width back
  :deep(.bng-slider-reset) {
    position: absolute;
    right: 0;
    bottom: calc(100% + 0.2em);
    --bng-button-margin: 0;
    --bng-bg-enabled: transparent;
    --bng-bg-enabled-opacity: 0;
    --bng-bg-hover: #fff;
    --bng-bg-hover-opacity: 0.08;
    --bng-bg-active: #fff;
    --bng-bg-active-opacity: 0.12;
    --bng-bg-disabled: transparent;
    --bng-bg-disabled-opacity: 0;
    --bng-bg-border-radius: var(--radius-control);
    --bng-icon-color: var(--muted);
    font-size: 0.85em;
  }
}
</style>

<!-- Global on purpose: the hint popovers live in the page-wide .popover-container. -->
<style lang="scss">
body.rls-house-slider-hints .bng-popover[data-bng-popover-name^="slider-input-hint"],
body.rls-house-slider-hints .bng-popover[data-bng-popover-name^="slider-reset-hint"] {
  --popover-bg-override: #1a1a1c;
  padding: 0.3em 0.45em;
  border-radius: 0.45em;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 6px 16px rgba(0, 0, 0, 0.45);
  line-height: 1;

  > .bng-popover-arrow {
    width: 0.6em;
    height: 0.6em;
    box-shadow: 1px 1px 0 rgba(255, 255, 255, 0.08);
  }

  // nothing to show (no glyph for this device): hide it rather than leave a bare pointer
  &:not(:has(.binding-wrapper)) {
    display: none;
  }
}
</style>
