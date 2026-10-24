<!-- RLS override of the vanilla painting cart. Props, emits, scoped nav, ui-nav handlers and the hold-to-buy
     button contract are the game's; the chrome matches the house ShoppingCart (components/ShoppingCart.vue):
     cart heading with item count, Option / Price header, quiet-danger remove, total pinned to the bottom,
     one orange hold-to-purchase button. PaintingMain renders it in the ComputerWrapper side column. -->
<template>
  <ComputerPanel
    class="paint-cart rls-house"
    :class="{ 'cart-active': active }"
    :active="active"
    tabindex="-1">
    <template #heading>
      <div class="cart-heading">
        <!-- controller cue to switch here: only while the cart is the inactive panel and has something in it -->
        <span v-if="showSwitchHint" class="cart-hint">
          <BngBinding ui-event="context" controller />
        </span>
        <BngIcon class="cart-glyph" :type="icons.shoppingCart" />
        <span class="cart-heading-text">{{ $t("ui.career.shoppingCart.title") }}</span>
        <span v-if="itemCount" class="pill">{{ itemCount }}</span>
      </div>
    </template>

    <div class="cart-main">
      <div class="cart-row cart-header">
        <div></div>
        <div>{{ $t("ui.career.painting.option") }}</div>
        <div>{{ $t("ui.career.shoppingCart.price") }}</div>
      </div>
      <!-- the directive (not the bare attribute) registers the right stick with the game's tracker -->
      <div ref="cartList" class="cart-list scroll" v-bng-ui-nav-scroll="active ? { force: true } : false">
        <template v-if="changedPaint">
          <div
            v-for="date in rowsWithMeta"
            :key="date.rowKey"
            class="cart-row cart-item"
            :class="date.topLevel ? 'cart-item-top' : 'cart-item-sub'">
            <div>
              <HouseButton
                v-if="date.topLevel"
                class="cart-remove"
                variant="quiet-danger"
                compact
                :icon="icons.trashBin1"
                :data-paint-cart-item-position="date.topLevelPosition"
                @click="handleResetPaint(date)" />
            </div>
            <div class="item-name">{{ date.name }}</div>
            <div class="price">{{ units.beamBucks(date.price) }}</div>
          </div>
        </template>
        <div v-else class="empty cart-empty">
          <BngIcon class="cart-empty-glyph" :type="icons.shoppingCart" />
          <p>Cart is empty</p>
        </div>
      </div>
      <div class="cart-row cart-total" :class="{ short: changedPaint && !canPay }">
        <div></div>
        <div>{{ $t("ui.career.shoppingCart.total") }}</div>
        <div class="price">{{ units.beamBucks(totalPrice) }}</div>
      </div>
    </div>

    <template #footer>
      <HouseButton
        class="purchase-button"
        variant="primary"
        :disabled="!canPay || !changedPaint"
        v-bng-on-ui-nav:ok.asMouse.focusRequired
        v-bng-click="{
          holdCallback: () => emit('apply'),
          holdDelay: 1000,
          repeatInterval: 0,
        }">
        {{ $t("ui.career.painting.purchaseAndApply") }}
      </HouseButton>
    </template>
  </ComputerPanel>
</template>

<script setup>
import { computed, nextTick } from "vue"
import { storeToRefs } from "pinia"
import { useBridge } from "@/bridge"
import { BngBinding, BngIcon, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngClick, vBngUiNavScroll } from "@/common/directives"
import { useScopedNav } from "@/services/scopedNav/api"
import useControls from "@/services/controls"
import ComputerPanel from "../ComputerPanel.vue"
import { HouseButton } from "../house/index.js"

const props = defineProps({
  active: Boolean,
  showHint: Boolean,
  changedPaint: Boolean,
  rows: { type: Array, default: () => [] },
  totalPrice: { type: Number, default: 0 },
  canPay: Boolean,
})

const emit = defineEmits(["reset-paint", "apply"])

const rowsWithMeta = computed(() => {
  let topLevelPosition = 0
  return props.rows.map((row, rowIndex) => ({
    ...row,
    rowKey: row.topLevel ? `paint-${row.index}` : `sub-${rowIndex}`,
    topLevelPosition: row.topLevel ? topLevelPosition++ : null,
  }))
})

function focusAfterDelete(deletedIndex) {
  const topLevelCount = props.rows.filter(row => row.topLevel).length
  if (topLevelCount === 0) return
  const targetIndex = Math.min(Math.max(deletedIndex, 0), topLevelCount - 1)
  requestCurrentScopeFocus(`[data-paint-cart-item-position="${targetIndex}"]`, {
    reason: "paint-cart-item-removed",
  })
}

async function handleResetPaint(row) {
  const deletedPosition = row.topLevelPosition
  emit("reset-paint", row.index)
  await nextTick()
  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
  }
  focusAfterDelete(deletedPosition)
}

const { units } = useBridge()
const { requestCurrentScopeFocus } = useScopedNav()

// display only: same rule ComputerPanel uses for its own heading hints
const { isControllerUsed } = storeToRefs(useControls())
const showSwitchHint = computed(() => isControllerUsed.value && !props.active && props.showHint)

// one per repainted slot (clear coat lines belong to their slot)
const itemCount = computed(() => (props.changedPaint ? props.rows.filter(row => row.topLevel).length : 0))
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Root is ComputerPanel; `.paint-cart.computer-panel` outranks its scoped surface rules.
.paint-cart.computer-panel {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  // the side column is a fixed 33rem; size the cart in the screen-scaled em instead so it narrows at 720p
  align-self: flex-end;
  width: 28em;
  max-width: 100%;
  flex: 0 0 auto;
  height: 24em;
  max-height: 100%;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  // body fills the panel so the total sits at the bottom even when the cart is empty
  > :deep(.panel-content) {
    flex: 1 1 auto;
    min-height: 0;
  }
  // same ground whether or not the controller is on the cart; the heading glyph shows which is active
  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.92);
    font-weight: inherit;
  }
  > :deep(.footer-container) {
    padding: var(--space-3) var(--inset) var(--inset);
    background: transparent;
  }
}

.cart-heading {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.55em;
  padding: 0.8em 0.7em 0.55em var(--inset);
}

.cart-hint {
  display: inline-flex;
  align-items: center;
  font-size: 0.9em;
}

.cart-glyph {
  flex: 0 0 auto;
  font-size: 1.35em;
  color: rgba(255, 255, 255, 0.6);
  .cart-active & {
    color: var(--accent-soft);
  }
}

.cart-heading-text {
  flex: 0 1 auto;
  min-width: 0;
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}

// ---- cart body
.cart-main {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
  overflow: hidden;
  font-variant-numeric: tabular-nums;
}

// Three columns: remove action, option, price. The list reserves a 0.5em scrollbar gutter,
// so rows outside it (header, total) add that to their right padding to keep prices aligned.
.cart-row {
  display: grid;
  grid-template-columns: 2.4em minmax(0, 1fr) minmax(6.5em, auto);
  align-items: center;
  column-gap: var(--space-2);
  flex: 0 0 auto;
  min-height: 2.9em;
  padding: 0.45em var(--inset) 0.35em 0.35em;
  > :first-child {
    display: flex;
    justify-content: center;
  }
  > :last-child {
    text-align: right;
    white-space: nowrap;
  }
}

.price {
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.cart-header {
  min-height: 0;
  padding-top: 0.15em;
  padding-bottom: 0.45em;
  padding-right: calc(var(--inset) + 0.5em);
  border-bottom: 1px solid var(--line);
  > * {
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }
}

.cart-list {
  display: flex;
  flex-direction: column;
  overflow: hidden auto;
  flex: 1 1 auto;
  min-height: 0;
}

.cart-item {
  line-height: 1.25;
}

// a repainted slot reads as one group: divider only above each slot line
.cart-item-top {
  font-weight: 700;
}
.cart-item + .cart-item-top {
  border-top: 1px solid var(--line);
}
.cart-item-sub {
  min-height: 2.3em;
  font-weight: 600;
  color: var(--muted);
  .item-name {
    padding-left: 1em;
  }
  .price {
    font-weight: 600;
  }
}

.cart-item .cart-remove {
  font-size: 0.85em;
  padding: 0.3em 0.4em 0.25em;
  border-radius: var(--radius-thumb);
}

.item-name {
  min-width: 0;
  overflow-wrap: anywhere;
}

.cart-empty {
  flex: 0 0 auto;
  padding: 1.4em 1em 1em;
  p { color: var(--muted); }
}

.cart-empty-glyph {
  font-size: 1.8em;
  color: rgba(255, 255, 255, 0.3);
}

// total pinned right above the purchase button
.cart-total {
  min-height: 2.6em;
  margin: var(--space-2) var(--space-3) 0;
  padding: 0.55em calc(var(--inset) + 0.5em - var(--space-3)) 0.4em 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  > * {
    font-size: 1.15em;
    font-weight: 800;
  }
  .price {
    font-weight: 800;
  }
  // status by exception: the player cannot afford this repaint
  &.short .price {
    color: var(--bad);
  }
}

.purchase-button {
  flex: 1 1 auto;
}
</style>
