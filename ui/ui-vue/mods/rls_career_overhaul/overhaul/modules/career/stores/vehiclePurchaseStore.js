// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

import { ref, computed, onScopeDispose } from "vue"
import { defineStore } from "pinia"
import { useBridge, lua } from "@/bridge"

// Spend and price views over the purchase refs. Called once per store, so each store keeps its own closures.
function createPurchaseViews({ racingTeamFleetPurchase, racingTeamBusinessMoney, playerMoney, prices, buyCustomLicensePlate, insuranceOptions, makeDelivery, deliveryQuote }) {
  function isRacingTeamVehicleShop () {
    return racingTeamFleetPurchase.value === true
  }

  const racingTeamVehicleShop = computed(() => racingTeamFleetPurchase.value === true)

  const spendableMoney = computed(() => {
    if (isRacingTeamVehicleShop()) {
      return Number(racingTeamBusinessMoney.value) || 0
    }
    return Number(playerMoney.value) || 0
  })

  const finalPackagePrice = computed(() => {
    let price = prices.value.finalPrice
    if (isRacingTeamVehicleShop()) {
      return price
    }

    if (buyCustomLicensePlate.value) {
      price += prices.value.customLicensePlate
    }

    if (insuranceOptions.value.insuranceId > 0) {
      price += insuranceOptions.value.priceMoney
    }
    if (makeDelivery.value && deliveryQuote.value && !deliveryQuote.value.disabled) {
      price += Number(deliveryQuote.value.finalPrice) || 0
    }

    return price
  })

  return { isRacingTeamVehicleShop, racingTeamVehicleShop, spendableMoney, finalPackagePrice }
}

// Applies each vehiclePurchaseData payload to the refs and owns the delivery quote requests it starts.
// The purchase key and quote counter are closure state: a reset invalidates quotes still in flight.
function createPurchaseIntake({ vehicleInfo, playerMoney, racingTeamFleetPurchase, racingTeamBusinessMoney, inventoryHasFreeSlot, garageAvailability, purchaseType, tradeInEnabled, locationSelectionEnabled, forceNoDelivery, prices, garageDeliveryAllowed, deliveryGarages, selectedGarageId, deliveryQuote, makeDelivery, freightAvailable, freightUnavailableReason, buyCustomLicensePlate, customLicensePlateText, dealershipId, forceTradeIn, insuranceOptions, testDriveDamageFee, tradeInVehicleInfo }) {
  let activePurchaseKey = null
  let deliveryQuoteRequest = 0

  const handlePurchaseData = data => {
    const purchaseKey = JSON.stringify([data.vehicleInfo?.shopId, data.dealershipId, data.purchaseType])
    const samePurchase = activePurchaseKey === purchaseKey
    activePurchaseKey = purchaseKey
    deliveryQuoteRequest++
    vehicleInfo.value = data.vehicleInfo
    playerMoney.value = data.playerMoney
    racingTeamFleetPurchase.value = data.racingTeamFleetPurchase === true
    racingTeamBusinessMoney.value = data.racingTeamBusinessMoney != null ? Number(data.racingTeamBusinessMoney) || 0 : 0
    inventoryHasFreeSlot.value = data.inventoryHasFreeSlot
    garageAvailability.value = data.garageAvailability || "ok"
    purchaseType.value = data.purchaseType
    tradeInEnabled.value = data.tradeInEnabled
    locationSelectionEnabled.value = data.locationSelectionEnabled
    forceNoDelivery.value = data.forceNoDelivery
    prices.value = data.prices
    garageDeliveryAllowed.value = data.garageDeliveryAllowed === true
    deliveryGarages.value = Array.isArray(data.deliveryGarages) ? data.deliveryGarages : []
    const deliveryAvailable =
      garageDeliveryAllowed.value &&
      deliveryGarages.value.length > 0 &&
      !forceNoDelivery.value
    makeDelivery.value = deliveryAvailable && (samePurchase ? makeDelivery.value : true)
    const previousGarageAvailable = samePurchase && deliveryGarages.value.some(garage => String(garage.id) === selectedGarageId.value)
    selectedGarageId.value = makeDelivery.value
      ? (previousGarageAvailable ? selectedGarageId.value : String(deliveryGarages.value[0].id))
      : ""
    deliveryQuote.value = null
    freightAvailable.value = data.freightAvailable !== false
    freightUnavailableReason.value = data.freightUnavailableReason || ""
    buyCustomLicensePlate.value = false
    customLicensePlateText.value = ""
    dealershipId.value = data.dealershipId

    forceTradeIn.value = data.forceTradeIn
    insuranceOptions.value = data.insuranceOptions
    testDriveDamageFee.value = data.testDriveDamageFee || 0

    if (data.tradeInVehicleInfo !== undefined) {
      tradeInVehicleInfo.value = data.tradeInVehicleInfo
    } else {
      tradeInVehicleInfo.value = {}
    }

    if (makeDelivery.value) {
      requestDeliveryQuote(selectedGarageId.value)
    }
  }

  async function requestDeliveryQuote(garageId) {
    const request = ++deliveryQuoteRequest
    const requestedGarageId = garageId != null ? String(garageId) : ""
    selectedGarageId.value = requestedGarageId
    deliveryQuote.value = null
    if (!requestedGarageId) return null
    const quote = await lua.overhaul_career_market_vehicleShopping.getDeliveryQuote(requestedGarageId)
    if (request === deliveryQuoteRequest && selectedGarageId.value === requestedGarageId) {
      deliveryQuote.value = quote
    }
    return quote
  }

  function resetPurchaseIntake() {
    activePurchaseKey = null
    deliveryQuoteRequest++
  }

  return { handlePurchaseData, requestDeliveryQuote, resetPurchaseIntake }
}

export const useVehiclePurchaseStore = defineStore("overhaulVehiclePurchase", () => {
  const { events } = useBridge()

  const purchaseType = ref("")
  const vehicleInfo = ref({})
  const playerMoney = ref(0)
  const racingTeamBusinessMoney = ref(0)
  const alreadyDidTestDrive = ref(false)
  const inventoryHasFreeSlot = ref(false)
  const garageAvailability = ref("ok")
  const tradeInVehicleInfo = ref({})
  const tradeInEnabled = ref(false)
  const forceTradeIn = ref(false)
  const locationSelectionEnabled = ref(false)
  const forceNoDelivery = ref(false)
  const makeDelivery = ref(false)
  const garageDeliveryAllowed = ref(false)
  const deliveryGarages = ref([])
  const selectedGarageId = ref("")
  const deliveryQuote = ref(null)
  const freightAvailable = ref(true)
  const freightUnavailableReason = ref("")
  const buyCustomLicensePlate = ref(false)
  const customLicensePlateText = ref("")
  const dealershipId = ref("")
  const prices = ref({})
  const insuranceOptions = ref({})
  const testDriveDamageFee = ref(0)
  /** Authoritative for this purchase session (set from Lua); avoids sessionStorage/global rtBiz races. */
  const racingTeamFleetPurchase = ref(false)

  const { isRacingTeamVehicleShop, racingTeamVehicleShop, spendableMoney, finalPackagePrice } = createPurchaseViews({
    racingTeamFleetPurchase,
    racingTeamBusinessMoney,
    playerMoney,
    prices,
    buyCustomLicensePlate,
    insuranceOptions,
    makeDelivery,
    deliveryQuote,
  })

  const { handlePurchaseData, requestDeliveryQuote, resetPurchaseIntake } = createPurchaseIntake({
    vehicleInfo,
    playerMoney,
    racingTeamFleetPurchase,
    racingTeamBusinessMoney,
    inventoryHasFreeSlot,
    garageAvailability,
    purchaseType,
    tradeInEnabled,
    locationSelectionEnabled,
    forceNoDelivery,
    prices,
    garageDeliveryAllowed,
    deliveryGarages,
    selectedGarageId,
    deliveryQuote,
    makeDelivery,
    freightAvailable,
    freightUnavailableReason,
    buyCustomLicensePlate,
    customLicensePlateText,
    dealershipId,
    forceTradeIn,
    insuranceOptions,
    testDriveDamageFee,
    tradeInVehicleInfo,
  })

  function requestPurchaseData() {
    lua.overhaul_career_market_vehicleShopping.sendPurchaseDataToUi()
  }

  function buyVehicle(makeDelivery) {
    let options = {
      makeDelivery: makeDelivery,
      insuranceId: insuranceOptions.value.insuranceId
    }
    if (makeDelivery) options.targetGarageId = selectedGarageId.value
    if (buyCustomLicensePlate.value) {
      options.licensePlateText = customLicensePlateText.value
    }
    options.dealershipId = dealershipId.value
    if (isRacingTeamVehicleShop()) {
      options.insuranceId = -1
      delete options.licensePlateText
    }
    if (vehicleInfo.value.source === "carMeet") {
      options.insuranceId = -1
    }
    lua.overhaul_career_market_vehicleShopping.buyFromPurchaseMenu(purchaseType.value, options)
  }

  function inventoryIsEmpty() {
    return lua.overhaul_career_garage_inventory.isEmpty()
  }

  function chooseTradeInVehicle() {
    lua.overhaul_career_market_vehicleShopping.openInventoryMenuForTradeIn()
  }

  function removeTradeInVehicle() {
    lua.overhaul_career_market_vehicleShopping.removeTradeInVehicle()
  }

  function cancel() {
    lua.overhaul_career_market_vehicleShopping.cancelPurchase(purchaseType.value)
  }

  function startTestDrive() {
    lua.overhaul_career_market_inspectVehicle.startTestDrive()
  }

  function dispose() {
    resetPurchaseIntake()
    racingTeamFleetPurchase.value = false
    listen(false)
  }

  // Lua events
  const listen = state => {
    const method = state ? "on" : "off"
    events[method]("vehiclePurchaseData", handlePurchaseData)
  }
  listen(true)
  onScopeDispose(dispose)

  return {
    buyVehicle,
    cancel,
    chooseTradeInVehicle,
    purchaseType,
    startTestDrive,
    dispose,
    forceNoDelivery,
    forceTradeIn,
    inventoryIsEmpty,
    inventoryHasFreeSlot,
    garageAvailability,
    locationSelectionEnabled,
    makeDelivery,
    garageDeliveryAllowed,
    deliveryGarages,
    selectedGarageId,
    deliveryQuote,
    freightAvailable,
    freightUnavailableReason,
    requestDeliveryQuote,
    playerMoney,
    racingTeamBusinessMoney,
    spendableMoney,
    prices,
    finalPackagePrice,
    removeTradeInVehicle,
    requestPurchaseData,
    tradeInEnabled,
    tradeInVehicleInfo,
    vehicleInfo,
    buyCustomLicensePlate,
    customLicensePlateText,
    alreadyDidTestDrive,
    insuranceOptions,
    racingTeamVehicleShop,
    racingTeamFleetPurchase,
    testDriveDamageFee,
  }
})
