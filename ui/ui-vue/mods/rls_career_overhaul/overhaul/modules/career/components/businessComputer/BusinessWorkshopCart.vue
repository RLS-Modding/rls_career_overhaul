<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <ShoppingCart
    class="workshop-cart"
    v-bng-scoped-nav="{ scopeId: scopeId, canDeactivate: () => { emit('return-to-workshop'); return false } }"
    :active="active"
    :cart-data="cartData"
    :player-money="businessBalance"
    :confirm-button-text="$translate.instant('ui.career.shared.confirm')"
    v-bng-on-ui-nav:context="() => emit('return-to-workshop')"
    @apply="purchase"
    @cancel="emit('cancel')"
    @remove-item="item => emit('remove-item', item)"
  >
    <template #before-summary>
      <BusinessDynoPanel />
    </template>
  </ShoppingCart>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { lua } from "@/bridge"
import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
import { useEvents } from "@/services/events"
import { $translate } from "@/services/translation"
import ShoppingCart from "../ShoppingCart.vue"
import { useBusinessCartStore } from "../../stores/businessComputer/businessCartStore.js"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import BusinessDynoPanel from "./BusinessDynoPanel.vue"

const props = defineProps({
  mode: { type: String, required: true },
  active: Boolean,
  scopeId: { type: String, required: true },
})
const emit = defineEmits(["cancel", "purchased", "remove-item", "return-to-workshop"])
const cartStore = useBusinessCartStore()
const sessionStore = useBusinessSessionStore()
const events = useEvents()
const businessBalance = ref(0)
const purchasing = ref(false)

const sourceItems = computed(() => props.mode === "parts" ? cartStore.partsCart || [] : cartStore.tuningCart || [])
const subtotal = computed(() => sourceItems.value.reduce((sum, item) => sum + (Number(item.price) || 0), 0))
const taxes = computed(() => subtotal.value * 0.07)
const cartData = computed(() => ({
  items: sourceItems.value.map(item => ({
    key: item.id || item.varName || `${item.type}-${item.partName || item.title}`,
    name: item.partNiceName || item.title || item.partName || item.varName || "Item",
    price: Number(item.price) || 0,
    priceHide: item.type === "category" || (item.type === "variable" && !(Number(item.price) > 0)),
    type: item.type,
    level: item.level,
    removeShow: item.type === "part" || item.type === "variable",
    itemId: item.id,
    slotPath: item.slotPath,
    varName: item.varName,
    extraInfo: item.fromInventory ? "Business inventory" : undefined,
  })),
  taxes: taxes.value,
  total: subtotal.value + taxes.value,
}))

const loadBalance = async () => {
  if (!sessionStore.businessType || !sessionStore.businessId) return
  businessBalance.value = Number(await lua.overhaul_career_business_computer.getBusinessAccountBalance(
    sessionStore.businessType,
    sessionStore.businessId
  )) || 0
}

const onAccountUpdate = data => {
  const expectedId = `business_${sessionStore.businessType}_${sessionStore.businessId}`
  if (data?.accountId === expectedId) businessBalance.value = Number(data.balance) || 0
}

const purchase = async () => {
  if (purchasing.value || sourceItems.value.length === 0) return
  purchasing.value = true
  try {
    const accountId = `business_${sessionStore.businessType}_${sessionStore.businessId}`
    const success = await lua.overhaul_career_business_computer.purchaseCartItems(
      sessionStore.businessId,
      accountId,
      {
        parts: props.mode === "parts" ? cartStore.partsCart : [],
        tuning: props.mode === "tuning" ? cartStore.tuningCart : [],
      }
    )
    if (success) emit("purchased")
  } finally {
    purchasing.value = false
  }
}

watch(() => [sessionStore.businessType, sessionStore.businessId], loadBalance, { immediate: true })
onMounted(() => events.on("bank:onOverhaulAccountUpdate", onAccountUpdate))
onBeforeUnmount(() => events.off("bank:onOverhaulAccountUpdate", onAccountUpdate))
</script>

<style scoped lang="scss">
// the workshop column is sized for the cart plus the dyno panel: keep it full width
.cart.workshop-cart.computer-panel {
  width: 100%;
}

// room for the Performance panel under the cart lines (the shared cart is 27em tall)
.cart.workshop-cart.computer-panel:not(.expanded) {
  height: 40em;
  max-height: 100%;
}
</style>
