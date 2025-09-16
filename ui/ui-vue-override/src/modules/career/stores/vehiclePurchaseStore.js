import { ref, watch, computed } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"
import { useInsurancePoliciesStore } from "./insurancePoliciesStore"

export const useVehiclePurchaseStore = defineStore("vehiclePurchase", () => {
  const { events } = useBridge()

  const purchaseType = ref("")
  const vehicleInfo = ref({})
  const playerMoney = ref(0)
  const inventoryHasFreeSlot = ref(false)
  const tradeInVehicleInfo = ref({})
  const tradeInEnabled = ref(false)
  const forceTradeIn = ref(false)
  const locationSelectionEnabled = ref(false)
  const forceNoDelivery = ref(false)
  const ownsRequiredInsurance = ref(false)
  const makeDelivery = ref(false)
  const buyRequiredInsurance = ref(false)
  const buyCustomLicensePlate = ref(false)
  const customLicensePlateText = ref("")
  const dealershipId = ref("")
  const prices = ref({})
  const selectedPolicyId = ref(0)
  const insurancePoliciesStore = useInsurancePoliciesStore()

  const finalPackagePrice = computed(() => {
    let price = prices.value.finalPrice

    // Always add first renewal price if a policy is selected (>0)
    let insurancePrice = 0
    const polId = selectedPolicyId.value
    if (polId && polId > 0) {
      const p = (insurancePoliciesStore.policiesData || []).find(p => p.id === polId)
      insurancePrice = p ? (p.premium || p.initialBuyPrice || 0) : 0
    }
    price += insurancePrice

    if (buyCustomLicensePlate.value) {
      price += prices.value.customLicensePlate
    }
    return price
  })

  const handlePurchaseData = data => {
    vehicleInfo.value = data.vehicleInfo
    playerMoney.value = data.playerMoney
    inventoryHasFreeSlot.value = data.inventoryHasFreeSlot
    purchaseType.value = data.purchaseType
    tradeInEnabled.value = data.tradeInEnabled
    locationSelectionEnabled.value = data.locationSelectionEnabled
    forceNoDelivery.value = data.forceNoDelivery
    ownsRequiredInsurance.value = data.ownsRequiredInsurance
    prices.value = data.prices
    makeDelivery.value = false
    buyRequiredInsurance.value = false
    buyCustomLicensePlate.value = false
    customLicensePlateText.value = ""
    dealershipId.value = data.dealershipId

    forceTradeIn.value = data.forceTradeIn

    if (data.tradeInVehicleInfo !== undefined) {
      tradeInVehicleInfo.value = data.tradeInVehicleInfo
    } else {
      tradeInVehicleInfo.value = {}
    }

    if (!ownsRequiredInsurance.value) {
      buyRequiredInsurance.value = true
    }

    // default selected policy to required insurance if present
    if (vehicleInfo.value && vehicleInfo.value.requiredInsurance && typeof vehicleInfo.value.requiredInsurance.id === 'number') {
      selectedPolicyId.value = vehicleInfo.value.requiredInsurance.id
    } else {
      selectedPolicyId.value = 0
    }
  }

  watch(() => buyRequiredInsurance.value, updateInsurancePurchase)

  function updateInsurancePurchase(newValue, oldValue) {
    if (!ownsRequiredInsurance.value && !buyRequiredInsurance.value) makeDelivery.value = true
  }

  function requestPurchaseData() {
    lua.career_modules_vehicleShopping.sendPurchaseDataToUi()
  }

  function buyVehicle(makeDelivery, policyId) {
    // Don't purchase insurance separately - it will be handled in the backend
    // This ensures proper synchronization with vehicle purchase
    let options = {
      makeDelivery: makeDelivery, 
      policyId: policyId,
      purchaseInsurance: buyRequiredInsurance.value && policyId > 0
    }
    if (buyCustomLicensePlate.value) {
      options.licensePlateText = customLicensePlateText.value
    }
    options.dealershipId = dealershipId.value
    lua.career_modules_vehicleShopping.buyFromPurchaseMenu(purchaseType.value, options)
  }

  function setSelectedPolicyId(id) {
    selectedPolicyId.value = id || 0
  }

  function inventoryIsEmpty() {
    return lua.career_modules_inventory.isEmpty()
  }

  function chooseTradeInVehicle() {
    lua.career_modules_vehicleShopping.openInventoryMenuForTradeIn()
  }

  function removeTradeInVehicle() {
    lua.career_modules_vehicleShopping.removeTradeInVehicle()
  }

  function cancel() {
    lua.career_modules_vehicleShopping.cancelPurchase(purchaseType.value)
  }

  function dispose() {
    listen(false)
  }

  // Lua events
  const listen = state => {
    const method = state ? "on" : "off"
    events[method]("vehiclePurchaseData", handlePurchaseData)
  }
  listen(true)

  return {
    buyRequiredInsurance,
    buyVehicle,
    cancel,
    chooseTradeInVehicle,
    dispose,
    forceNoDelivery,
    forceTradeIn,
    inventoryIsEmpty,
    inventoryHasFreeSlot,
    locationSelectionEnabled,
    makeDelivery,
    ownsRequiredInsurance,
    playerMoney,
    prices,
    finalPackagePrice,
    selectedPolicyId,
    setSelectedPolicyId,
    removeTradeInVehicle,
    requestPurchaseData,
    tradeInEnabled,
    tradeInVehicleInfo,
    vehicleInfo,
    buyCustomLicensePlate,
    customLicensePlateText
  }
})
