<template>
  <ComputerPanel
    class="cart rls-house"
    :class="{ expanded, 'cart-active': active }"
    :active="active"
  >
    <!-- house heading: cart glyph, title, item count; the controller hint to switch here shows
         only while the cart is the inactive panel (same rule as ComputerPanel's own hints) -->
    <template #heading>
      <div class="cart-heading">
        <span v-if="showSwitchHint" class="cart-hint">
          <BngBinding :ui-event="activateBindingUiEvent" controller />
        </span>
        <BngIcon class="cart-glyph" :type="icons.shoppingCart" />
        <span class="cart-heading-text">{{ $translate.instant("ui.career.shoppingCart.title") }}</span>
        <span v-if="itemCount" class="pill">{{ itemCount }}</span>
        <HouseButton
          class="cart-expand"
          variant="quiet"
          compact
          bng-no-nav="true"
          v-bng-on-ui-nav:action_2="() => (expanded = !expanded)"
          v-bng-ui-nav-label:action_2="$translate.instant('ui.career.shoppingCart.toggleExpanded')"
          :icon="expanded ? icons.arrowLargeDown : icons.arrowLargeUp"
          @click="expanded = !expanded" />
      </div>
    </template>
    <div class="cart-main">
      <div class="cart-row cart-header">
        <div></div>
        <div>{{ $translate.instant("ui.career.shoppingCart.part") }}</div>
        <div>{{ $translate.instant("ui.career.shoppingCart.price") }}</div>
      </div>
      <!-- the directive (not the bare attribute) registers the right stick with the game's tracker -->
      <div ref="cartList" class="cart-list scroll" v-bng-ui-nav-scroll="active ? { force: true } : false">
        <template v-if="cartData">
          <div v-for="(item, index) in cartData.items" :key="item.key ?? index" class="cart-row cart-item" :class="item.type ? [`type-${item.type}`] : null">
            <div>
              <HouseButton
                v-if="item.removeShow"
                class="cart-remove"
                variant="quiet-danger"
                compact
                :icon="icons.trashBin1"
                :disabled="item.removeDisabled"
                @click="removeItem(index, item)" />
            </div>
            <div class="item-name" :style="{ paddingLeft: item.level ? `${item.level - 1}em` : undefined }">
              {{ item.name }}
              <div v-if="item.extraInfo" class="extra-info-text">
                {{ item.extraInfo }}
              </div>
            </div>
            <div v-if="!item.priceHide" class="price">
              {{ units.beamBucks(item.price) }}
            </div>
            <div v-else></div>
          </div>
        </template>
        <div v-if="isEmpty" class="empty cart-empty">
          <BngIcon class="cart-empty-glyph" :type="icons.shoppingCart" />
          <p>Cart is empty</p>
        </div>
        <slot name="before-summary" />
        <div class="cart-row cart-subtotal">
          <div></div>
          <div>{{ $translate.instant("ui.career.shoppingCart.subtotal") }}</div>
          <div class="price">{{ units.beamBucks(subtotal) }}</div>
        </div>
        <div class="cart-row cart-tax">
          <div></div>
          <div>{{ $translate.instant("ui.career.shoppingCart.salesTax", { rate: 7 }) }}</div>
          <div class="price">{{ units.beamBucks(salesTax) }}</div>
        </div>
      </div>
      <div class="cart-row cart-total">
        <div></div>
        <div>{{ $translate.instant("ui.career.shoppingCart.total") }}</div>
        <div class="price"><BngUnit :money="cartData ? cartData.total : 0" /></div>
      </div>
    </div>
    <template #footer>
      <div v-if="showSaveForLater && restoreInProgress" class="notice restore-banner">
        Restoring saved build… {{ restoreProgress.current }}/{{ restoreProgress.total }}
      </div>
      <HouseButton
        v-if="holdToConfirm"
        ref="confirmBtn"
        class="cart-btn cart-btn-primary"
        variant="primary"
        :disabled="confirmDisabled"
        v-bng-on-ui-nav:ok.asMouse.focusRequired
        v-bng-click="{
          holdCallback: completeHoldSound,
          holdDelay: 1000,
          repeatInterval: 0,
          holdSoundInstanceId: 'shopping-cart-purchase',
        }"
      >
        {{ confirmButtonText || $translate.instant("ui.career.vehiclePurchase.purchase") }}
      </HouseButton>
      <HouseButton
        v-else
        ref="confirmBtn"
        class="cart-btn cart-btn-primary"
        variant="primary"
        :disabled="confirmDisabled"
        @click.stop="onConfirmClick"
      >
        {{ confirmButtonText || "Confirm" }}
      </HouseButton>
      <HouseButton
        v-if="showSaveForLater"
        class="cart-btn"
        :disabled="saveForLaterDisabled"
        @click="emit('save-for-later')"
      >
        Save for later
      </HouseButton>
      <HouseButton
        class="cart-btn"
        variant="quiet"
        :disabled="showSaveForLater && restoreInProgress"
        @click="emit('cancel')">
        {{ $translate.instant("ui.common.cancel") }}
      </HouseButton>
    </template>
  </ComputerPanel>
</template>

<script setup>
import { ref, computed, watch, nextTick } from "vue"
import { useBridge } from "@/bridge"
import { BngBinding, BngIcon, BngUnit, icons } from "@/common/components/base"
import { storeToRefs } from "pinia"
import useControls from "@/services/controls"
import { HouseButton } from "./house/index.js"
import ComputerPanel from "./ComputerPanel.vue"
import { $translate } from "@/services/translation"
import { vBngClick, vBngOnUiNav, vBngUiNavLabel, vBngUiNavScroll } from "@/common/directives"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { setFocus } from "@/services/uiNavFocus"
import { refocusIfLost } from "../composables/useScreenEntryFocus"

const props = defineProps({
  cartData: Object,
  playerMoney: Number,
  confirmButtonText: String,
  activateBindingUiEvent: {
    type: String,
    default: "context",
  },
  active: Boolean,
  showSaveForLater: Boolean,
  restoreInProgress: Boolean,
  restoreProgress: {
    type: Object,
    default: () => ({ current: 0, total: 0 }),
  },
  holdToConfirm: {
    type: Boolean,
    default: true,
  },
})

const emit = defineEmits(["apply", "cancel", "save-for-later", "remove-item"])

const { units } = useBridge()

const { isControllerUsed } = storeToRefs(useControls())
const showSwitchHint = computed(() => isControllerUsed.value && !props.active)

// priced lines only (tuning category / sub-category headers aren't purchases themselves)
const itemCount = computed(() => {
  const items = props.cartData?.items
  if (!Array.isArray(items)) return 0
  return items.filter(item => !item.priceHide && item.type !== "category" && item.type !== "subCategory").length
})

const expanded = ref(false)
const confirmBtn = ref(null)

const confirmDisabled = computed(() =>
  (props.showSaveForLater && props.restoreInProgress) ||
  !props.cartData ||
  props.cartData.items.length === 0 ||
  (Number(props.cartData.total) > 0 &&
    props.playerMoney != null &&
    Number.isFinite(Number(props.playerMoney)) &&
    Number(props.cartData.total) > Number(props.playerMoney))
)

const isEmpty = computed(() =>
  !props.cartData ||
  !Array.isArray(props.cartData.items) ||
  props.cartData.items.length === 0
)

const saveForLaterDisabled = computed(() =>
  props.restoreInProgress ||
  !props.cartData ||
  !props.cartData.items ||
  props.cartData.items.length === 0
)

function focusConfirm() {
  if (confirmDisabled.value) return
  nextTick(() => {
    const el = confirmBtn.value?.$el
    if (el) setFocus(el)
  })
}

const navBlocker = useUINavBlocker()
watch(
  () => props.active,
  show => {
    show ? navBlocker.blockOnly() : navBlocker.blockOnly(["action_2"])
    // Dual-scope cart often lands focus on Cancel; put it on Confirm when the cart activates.
    if (show) focusConfirm()
  },
  { immediate: true }
)

// If the cart was already active while empty, focus Confirm once items become purchasable.
watch(confirmDisabled, (disabled, wasDisabled) => {
  if (props.active && wasDisabled && !disabled) focusConfirm()
})

const subtotal = computed(() => {
  if (!props.cartData) return 0
  return (Number(props.cartData.total) || 0) - (Number(props.cartData.taxes) || 0)
})

const salesTax = computed(() => props.cartData && props.cartData.taxes ? props.cartData.taxes : 0)

// Controller: removing a line unmounts the focused remove button; once the cart re-renders, put a
// pad on the remove button that took its place (or the one above), else on the footer.
const cartList = ref(null)
let removedIndex = -1
function removeItem(index, item) {
  removedIndex = index
  emit("remove-item", item)
}
watch(
  () => props.cartData?.items,
  () => {
    if (removedIndex < 0) return
    const at = removedIndex
    removedIndex = -1
    refocusIfLost(() => {
      const buttons = [...(cartList.value?.querySelectorAll(".cart-remove:not([disabled])") || [])]
      return buttons[Math.min(at, buttons.length - 1)] || confirmBtn.value?.$el?.closest(".cart")?.querySelector(".cart-btn:not([disabled])")
    })
  },
  { flush: "post" }
)

function isPrimaryInteraction(event) {
  return !event || event.fromController || event.button === 0
}

function completeHoldSound(event) {
  if (!isPrimaryInteraction(event)) return
  emit("apply")
}

function onConfirmClick(event) {
  if (confirmDisabled.value) return
  if (event && event.button != null && event.button !== 0) return
  emit("apply")
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Root is ComputerPanel; `.cart.computer-panel` outranks its own scoped surface rules
// without relying on any parent class (also embedded by BusinessWorkshopCart).
.cart.computer-panel {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  // the side column is a fixed 33rem; size the cart in the screen-scaled em instead so it narrows at 720p
  align-self: flex-end;
  width: 28em;
  max-width: 100%;
  flex: 1 0 auto;
  height: 27em;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  transition: opacity 0.15s ease;
  & :deep(.card-cnt) {
    background-color: transparent;
  }
  // body fills the panel so subtotal / tax / total sit at the bottom even when the cart is empty
  > :deep(.panel-content) {
    flex: 1 1 auto;
    min-height: 0;
  }
  &.expanded {
    height: auto;
    min-height: 27em;
    max-height: 100%;
  }
  // same ground whether or not the controller is on the cart; the heading glyph shows which is active
  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.92);
    font-weight: inherit;
  }
  > :deep(.footer-container) {
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
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

// ---- house buttons
.cart .cart-expand {
  margin-left: auto;
}

.cart .cart-item .cart-remove {
  font-size: 0.85em;
  padding: 0.3em 0.4em 0.25em;
  border-radius: var(--radius-thumb);
}

.cart .cart-btn {
  white-space: nowrap;
}

// Primary: the single orange action.
.cart .cart-btn-primary {
  flex: 1 1 auto;
}

// ---- cart body
.cart-main {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  max-height: 100%;
  min-height: 0;
  overflow: hidden;
  font-variant-numeric: tabular-nums;
}

// Three columns: remove action, name, price. The list reserves a 0.5em scrollbar gutter,
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
  font-weight: 600;
  line-height: 1.25;
}

// Dividers only between top-level entries; tuning sub-rows stay grouped under their category.
.cart-item + .cart-item:not(.type-subCategory):not(.type-item):not(.type-variable) {
  border-top: 1px solid var(--line);
}

.item-name {
  min-width: 0;
  overflow-wrap: anywhere;
}

.extra-info-text {
  margin-top: 0.15em;
  font-size: 0.82em;
  font-weight: 600;
  color: var(--faint);
}

.cart-row {
  &.type-category {
    min-height: 2.5em;
    padding-top: 0.6em;
    font-weight: 800;
  }
  &.type-subCategory {
    min-height: 2.2em;
    font-weight: 700;
    color: var(--muted);
  }
  &.type-item,
  &.type-variable {
    min-height: 2.4em;
    font-weight: 600;
  }
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

.cart-subtotal,
.cart-tax {
  min-height: 2.2em;
  padding-top: 0.3em;
  padding-bottom: 0.2em;
  font-weight: 600;
  color: var(--muted);
  .price { font-weight: 600; }
}

.cart-subtotal {
  margin-top: auto;
  padding-top: 0.55em;
  border-top: 1px solid var(--line);
}

.cart-tax {
  padding-bottom: 0.45em;
}

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
    :deep(.info-item) {
      padding: 0;
    }
  }
}

.restore-banner {
  flex: 1 1 100%;
  text-align: center;
  background: var(--accent-ink);
  color: var(--accent-soft);
}
</style>
