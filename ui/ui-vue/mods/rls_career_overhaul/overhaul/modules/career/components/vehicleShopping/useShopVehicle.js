// One shop listing's state and actions, shared by VehicleCard (list row) and VehicleDetail (detail page).
import { reportUiFailure } from "../../utils/safeLua.js"
import { computed, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { icons } from "@/common/components/base"
import { openHouseConfirmation } from "../house/index.js"
import { $translate } from "@/services/translation"

const DRIVE_TRAIN_ICONS = {
  AWD: icons.AWD,
  "4WD": icons["4WD"],
  FWD: icons.FWD,
  RWD: icons.RWD,
  drivetrain_special: icons.drivetrainSpecial,
  drivetrain_generic: icons.drivetrainGeneric,
  defaultMissing: icons.drivetrainGeneric,
  defaultUnknown: icons.drivetrainGeneric,
}
const FUEL_TYPE_ICONS = {
  Battery: icons.charge,
  Gasoline: icons.fuelPump,
  Diesel: icons.fuelPump,
  defaultMissing: icons.fuelPump,
  defaultUnknown: icons.fuelPump,
}
const TRANSMISSION_ICONS = {
  Automatic: icons.transmissionA,
  Manual: icons.transmissionM,
  defaultMissing: icons.transmissionM,
  defaultUnknown: icons.transmissionM,
}
const ATTRIBUTE_ICONS = { Drivetrain: DRIVE_TRAIN_ICONS, "Fuel Type": FUEL_TYPE_ICONS, Transmission: TRANSMISSION_ICONS }

// the taxi glyph: the game's fast-travel icon (the cab outline read as a toy)
export const TAXI_ICON = icons.fastTravel

// The listing open on the detail page (its shop id), shared so the shop screens' Back closes it first.
export const shopDetail = ref(null)
/** Close the detail page if one is open; true when it was. */
const closeShopDetail = () => {
  if (shopDetail.value == null) return false
  shopDetail.value = null
  return true
}

const isFiniteNumber = v => v !== null && v !== "" && Number.isFinite(Number(v))

function useShopVehicle(props) {
  const { units } = useBridge()
  const data = () => props.vehicleShoppingData || {}
  const vehicle = () => props.vehicle || {}

  const isSold = computed(() => Boolean(vehicle().__sold || vehicle().soldViewCounter > 0))

  const sellerAccess = computed(() => {
    const dealerships = data().dealerships
    if (!Array.isArray(dealerships)) return null
    return dealerships.find(dealership => dealership.id === vehicle().sellerId) || null
  })

  const isOnlineSeller = computed(() => {
    const salesChannel = sellerAccess.value?.salesChannel ?? vehicle().salesChannel
    return salesChannel === "factory" || salesChannel === "remanufactured"
  })

  const isAtSeller = computed(() => vehicle().sellerId === data().currentSeller)

  const canPurchaseFromHere = computed(
    () => props.phoneMode || isAtSeller.value || (sellerAccess.value?.remotePurchaseAllowed ?? vehicle().remotePurchaseAllowed) === true
  )

  const purchaseButtonLabel = computed(() => {
    if (props.phoneMode && vehicle().sellerId === "private") return "Buy"
    if (props.racingTeamShop) return "Purchase for Team"
    const garageDeliveryAllowed = sellerAccess.value?.garageDeliveryAllowed ?? vehicle().garageDeliveryAllowed
    if (isOnlineSeller.value && !garageDeliveryAllowed) return "Order for Pickup"
    return "Purchase"
  })

  const vehiclePrice = computed(() => vehicle().valueAdjusted || vehicle().Value || 0)

  const insufficientFundsLabel = computed(() => (props.racingTeamShop ? "Over team budget" : "Insufficient funds"))

  const hasInsufficientFunds = computed(() => {
    if (props.racingTeamShop) {
      const team = Number(data().racingTeamBusinessMoney)
      return vehiclePrice.value > (Number.isFinite(team) ? team : 0)
    }
    if (data().cheatsMode) return false
    const wallet = Number(data().playerAttributes?.money?.value ?? data().playerAttributes?.money ?? 0)
    return vehiclePrice.value > wallet
  })

  /** Taxi is always paid from the player's wallet; team shop payload omits personal cash from playerAttributes. */
  const personalCashForTaxi = computed(() => {
    const d = data()
    if (d.playerPersonalMoneyForTaxi != null) {
      const n = Number(d.playerPersonalMoneyForTaxi)
      return Number.isFinite(n) ? n : 0
    }
    const n = Number(d.playerAttributes?.money?.value ?? d.playerAttributes?.money)
    return Number.isFinite(n) ? n : 0
  })

  const hasInsufficientTaxiFunds = computed(() => {
    if (data().cheatsMode) return false
    const price = Number(vehicle().quickTravelPrice)
    // Unknown/NaN fare: don't block taxi on a broken comparison.
    if (!Number.isFinite(price)) return false
    return personalCashForTaxi.value < price
  })

  const taxiCostKnown = computed(() => isFiniteNumber(vehicle().quickTravelPrice))
  const actionsBlocked = computed(() => Boolean(data().disableShopping || isSold.value))

  // which actions this listing offers (same conditions the card always used)
  const showRoute = computed(() => !props.phoneMode && !isOnlineSeller.value)
  const showTaxi = computed(() => !props.phoneMode && !data().currentSeller && !isOnlineSeller.value)
  const showPurchase = computed(() => (vehicle().sellerId !== "private" || props.phoneMode) && canPurchaseFromHere.value)
  const showNegotiate = computed(() => props.phoneMode && vehicle().sellerId === "private")

  const formatDistance = distance => (isFiniteNumber(distance) ? units.buildString("length", distance, 1) : "Unknown")
  const formatTaxiCost = price => (isFiniteNumber(price) ? units.beamBucks(price) : "cost unknown")
  const formatMileage = mileage => (mileage === 0 ? "New" : units.buildString("length", mileage, 0))

  const getVehicleId = () => {
    // shopId is the primary identifier (v38 system)
    const shopId = vehicle().shopId || vehicle().id || vehicle().uid
    if (!shopId) reportUiFailure(vehicle(), "Shop listing has no vehicle id")
    return shopId || null
  }

  const confirmTaxi = async () => {
    const vehicleId = getVehicleId()
    if (!vehicleId) return
    const fare = vehicle().quickTravelPrice
    const confirmMsg = isFiniteNumber(fare)
      ? $translate.instant("ui.career.vehicleShopping.taxiConfirm", { price: units.beamBucks(fare) })
      : "Do you want to take a taxi to this vehicle? (cost unknown)"
    const res = await openHouseConfirmation("", confirmMsg, [
      { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false } },
      { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
    ])
    if (res) lua.overhaul_career_market_vehicleShopping.quickTravelToVehicle(vehicleId)
  }

  // at the vehicle's own seller the route button inspects the car instead
  const routeOrInspect = () => {
    const vehicleId = getVehicleId()
    if (!vehicleId) return
    if (isAtSeller.value) lua.overhaul_career_market_vehicleShopping.showVehicle(vehicleId)
    else lua.overhaul_career_market_vehicleShopping.navigateToPos(vehicle().pos, vehicleId)
  }
  // phone layout: always a route, never the inspect camera
  const navigate = () => {
    const vehicleId = getVehicleId()
    if (vehicleId) lua.overhaul_career_market_vehicleShopping.navigateToPos(vehicle().pos, vehicleId)
  }
  const routeLabel = computed(() => (isAtSeller.value ? "Inspect Vehicle" : "Set Route"))
  const routeIcon = computed(() => (isAtSeller.value ? icons.search : icons.routeSimple))

  const openPurchase = () => {
    const vehicleId = getVehicleId()
    if (vehicleId) lua.overhaul_career_market_vehicleShopping.openPurchaseMenu("instant", vehicleId)
  }

  const negotiate = () => {
    const vehicleId = getVehicleId()
    if (vehicleId) lua.overhaul_career_market_marketplace.startNegotiateSellingOffer(vehicleId)
  }

  const attributeIcon = attribute => {
    const dict = ATTRIBUTE_ICONS[attribute]
    if (!dict) return icons.info
    const value = vehicle()[attribute]
    if (!value) return dict.defaultMissing
    return dict[value] || dict.defaultUnknown
  }

  const insuranceName = computed(() => {
    const name = vehicle().insuranceClass?.name || vehicle().requiredInsurance?.name
    return name ? $translate.instant(name) : null
  })

  // Spec cells, label over value. `short` is the list row's six; the detail page shows every one the vehicle has.
  const specs = computed(() => {
    const v = vehicle()
    const num = key => (isFiniteNumber(v[key]) ? Number(v[key]) : null)
    // one launch time: the one in the player's speed unit, the other only if that one is missing
    const accelRow = num => {
      const order = units.uiUnits?.uiUnitLength === "imperial" ? ["0-60 mph", "0-100 km/h"] : ["0-100 km/h", "0-60 mph"]
      const key = order.find(k => num(k) != null)
      return { key: "accel", label: key || order[0], value: key ? `${num(key).toFixed(1)} s` : null }
    }
    const rows = [
      { key: "power", label: "Power", value: num("Power") != null ? units.buildString("power", num("Power"), 0) : null, short: true },
      { key: "mileage", label: "Odometer", value: v.Mileage !== undefined && v.Mileage !== null ? formatMileage(v.Mileage) : null, short: true },
      { key: "drivetrain", label: "Drivetrain", value: v.Drivetrain || null, short: true },
      { key: "transmission", label: "Gearbox", value: v.Transmission || null, short: true },
      { key: "fuel", label: "Fuel", value: v["Fuel Type"] || null, short: true },
      { key: "weight", label: "Weight", value: num("Weight") != null ? units.buildString("weight", num("Weight"), 0) : null, short: true },
      { key: "torque", label: "Torque", value: num("Torque") != null ? units.buildString("torque", num("Torque"), 0) : null },
      { key: "ptw", label: "Power to weight", value: num("Power") && num("Weight") ? `${units.buildString("power", num("Power") / (num("Weight") / 1000), 0)} / t` : null },
      { key: "topspeed", label: "Top speed", value: num("Top Speed") != null ? units.buildString("speed", num("Top Speed"), 0) : null },
      accelRow(num),
      { key: "body", label: "Body", value: v["Body Style"] || null },
      { key: "config", label: "Configuration", value: v["Config Type"] || null },
      { key: "country", label: "Country", value: v.Country || null },
      { key: "year", label: "Year", value: v.year || null },
    ]
    return rows.filter(r => r.value !== null && r.value !== undefined && r.value !== "")
  })

  return {
    units,
    isSold,
    isOnlineSeller,
    isAtSeller,
    purchaseButtonLabel,
    vehiclePrice,
    insufficientFundsLabel,
    hasInsufficientFunds,
    hasInsufficientTaxiFunds,
    taxiCostKnown,
    actionsBlocked,
    showRoute,
    showTaxi,
    showPurchase,
    showNegotiate,
    routeLabel,
    routeIcon,
    insuranceName,
    specs,
    formatDistance,
    formatTaxiCost,
    formatMileage,
    getVehicleId,
    confirmTaxi,
    routeOrInspect,
    navigate,
    openPurchase,
    negotiate,
    attributeIcon,
  }
}

export { closeShopDetail, useShopVehicle }
