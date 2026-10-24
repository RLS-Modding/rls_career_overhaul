<template>
  <div class="rls-house vehicle-list-container" v-bng-disabled="!vehicleInventoryStore">
    <VehicleTileRow class="vehicle-list-item" v-if="listStatus" :data="{ _message: listStatus }" :layout="itemLayout" v-bng-disabled />

    <template v-else>
      <div v-for="group in groupedVehicles" :key="group.id || group.name" class="garage-group">
        <!-- the toggle runs on mousedown: bng-nav-item makes it a d-pad stop and ok.asMouse turns A into
             that mousedown -->
        <div class="garage-header" :class="{ open: !isCollapsed(group.id) }" role="button" tabindex="0"
          bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
          @mousedown.stop.prevent="e => toggleGroup(group.id, e)"
          @click.stop.prevent>
          <svg class="garage-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>
          <div class="garage-title">{{ group.name }}</div>
          <span class="pill garage-capacity">{{ group.count }} / {{ group.capacity || "N/A" }}</span>
        </div>

        <div v-if="!isCollapsed(group.id)" class="garage-vehicles">
          <VehicleTileRow class="vehicle-list-item" v-for="vehicle in group.vehicles" :key="vehicle.id"
            :data="vehicle" :layout="itemLayout" :selected="vehSelected && vehSelected.id === vehicle.id"
            :is-tutorial="vehicleInventoryStore && vehicleInventoryStore.vehicleInventoryData.tutorialActive"
            :money="vehicleInventoryStore ? vehicleInventoryStore.vehicleInventoryData.playerMoney : 0"
            :disabled-reason="getTradeInTileReason(vehicle)"
            v-bng-disabled="vehicle.disabled"
            tabindex="0" bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-popover:right-start.click="popId" @click="!vehicle.disabled && select(vehicle, $event)" />
        </div>
      </div>
    </template>

    <BngPopoverMenu class="veh-menu" :name="popId" focus @hide="selectedVehId = null">
      <template v-for="(buttonData, index) in vehicleInventoryStore.vehicleInventoryData.chooseButtonsData" :key="index">
        <HouseButton variant="menu" v-if="vehSelected && isChooserActionAvailable(vehSelected, buttonData)"
          :disabled="(buttonData.buttonText === 'Deliver' || buttonData.buttonText === 'Deliver and replace') && vehicleInventoryStore.vehicleInventoryData.playerMoney < 5000"
          v-bng-on-ui-nav:ok.focusRequired.asMouse
          @click="handleButtonClick(buttonData, index)">
          {{ buttonData.buttonText }}<span v-if="buttonData.repairRequired && vehSelected?.needsRepair"> (Damaged)</span>
          <span v-if="buttonData.retrievalAction && vehSelected?.retrievalCoveredByInsurance"> — Insurance tow</span>
          <BngUnit v-else-if="buttonData.retrievalAction && !vehSelected?.retrievalFree" :money="vehSelected?.retrievalCost || 0" />
        </HouseButton>
        <HouseButton variant="menu" v-else-if="vehSelected && isTradeInAction(buttonData)" disabled>
          {{ getUnavailableReason(vehSelected, buttonData) }}
        </HouseButton>
        <HouseButton variant="menu" v-else-if="vehSelected && buttonData.repairRequired && vehSelected.needsRepair" disabled>
          {{ buttonData.buttonText }} (Needs repair)
        </HouseButton>
      </template>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage && vehicleInventoryStore.vehicleInventoryData.buttonsActive.returnLoanerEnabled && vehSelected.returnLoanerPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmReturnVehicle()">
        Return loaned vehicle
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage && vehSelected.delayReason === 'repair'"
        :disabled="vehSelected.expediteRepairCost > vehicleInventoryStore.vehicleInventoryData.playerMoney"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmExpediteRepair(vehSelected)">
        Expedite Repair
        <BngUnit class="menu-money" :money="vehSelected.expediteRepairCost" />
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage && vehSelected.delayReason !== 'repair' && vehicleInventoryStore.vehicleInventoryData.buttonsActive.repairEnabled"
        :disabled="!vehSelected.repairPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="openRepairMenu()">
        Repair
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage && vehicleInventoryStore.vehicleInventoryData.buttonsActive.storingEnabled && !vehSelected.inStorage"
        :disabled="isStoring || !vehSelected.storePermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="storeVehicle()">
        Put in storage
        <span v-if="!vehSelected.storePermission.allow && vehSelected.storePermission.label">
          {{ vehSelected.storePermission.label }}
        </span>
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage && vehicleInventoryStore.vehicleInventoryData.buttonsActive.favoriteEnabled"
        :disabled="!vehSelected.favoritePermission.allow || vehSelected.favorite"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="setFavoriteVehicle()">
        Set as Favorite
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage"
        :disabled="!vehSelected.licensePlateChangePermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="personalizeLicensePlate(vehSelected)">
        Personalize license plate
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="renameVehicle()">
        Rename vehicle
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehSelected.atCurrentGarage && vehicleInventoryStore.vehicleInventoryData.buttonsActive.sellEnabled && !vehSelected.listedForSale"
        :disabled="!vehSelected.sellPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="listVehicleForSaleFromContextMenu()">
        List vehicle for sale
      </HouseButton>
      <!-- a listed car can be managed from any garage -->
      <HouseButton variant="menu"
        v-if="vehSelected && vehicleInventoryStore.vehicleInventoryData.buttonsActive.sellEnabled && vehSelected.listedForSale"
        :disabled="!vehSelected.sellPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="lookAtVehicleListing()">
        Go to vehicle listing
      </HouseButton>
      <HouseButton variant="menu"
        v-if="vehSelected && vehicleInventoryStore.vehicleInventoryData.buttonsActive.sellEnabled && vehSelected.listedForSale"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmRemoveListing()">
        Remove listing
      </HouseButton>
    </BngPopoverMenu>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../../utils/safeLua.js"

import { ref, computed, nextTick, onMounted, onUnmounted } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngPopoverMenu, BngUnit, ACCENTS } from "@/common/components/base"
import { vBngDisabled, vBngPopover, vBngOnUiNav } from "@/common/directives"
import VehicleTileRow from "./VehicleTileRow.vue"
import { useVehicleInventoryStore } from "../../stores/vehicleInventoryStore"
import { HouseButton, openHousePrompt, openHouseConfirmation, openHouseFormDialog } from "../house/index.js"
import { $translate } from "@/services/translation"
import { usePopover } from "@/services/popover"
import { uniqueId } from "@/services/uniqueId"
import ListVehicleDialog from "./ListVehicleDialog.vue"
import { moneyText } from "../../utils/units"
import { moneyMessage } from "../moneyMessage"
import { ensureFocus } from "@/services/uiNavFocus"

const { units, events } = useBridge()
const popover = usePopover()
const popId = uniqueId("veh_options")
const popHide = () => popover.hide(popId)
const licensePlateTextValid = ref(true)
const vehicleNameValid = ref(true)
const garageCapacities = ref({})
const collapsedGroups = ref({})
const isStoring = ref(false)

const vehicleInventoryStore = useVehicleInventoryStore()
const selectedVehId = ref()
const currentGarageHasSpace = computed(() => {
  const data = vehicleInventoryStore?.vehicleInventoryData
  if (!data || data.currentGarageHasSpace === undefined) return true
  return !!data.currentGarageHasSpace
})

const hasGlobalGarageSpace = computed(() => {
  const data = vehicleInventoryStore?.vehicleInventoryData
  if (!data || data.hasGlobalGarageSpace === undefined) return true
  return !!data.hasGlobalGarageSpace
})

const vehSelected = computed(() => {
  if (typeof selectedVehId.value !== "number") return undefined
  return listView.value.find(v => v.id === selectedVehId.value)
})

const careerStatusData = ref({})
const licensePlateCost = ref(null)

const updateCareerStatusData = () => lua.overhaul_career_ui_uiUtils.getCareerStatusData().then(data => (careerStatusData.value = data))

const cantPayLicensePlate = computed(() =>
  licensePlateCost.value === null || !careerStatusData.value.money || licensePlateCost.value > careerStatusData.value.money
)

const listStatus = computed(() =>
  !vehicleInventoryStore
  ? "Please wait..."
  : !Array.isArray(vehicleInventoryStore.filteredVehicles) || vehicleInventoryStore.filteredVehicles.length === 0
  ? "You don't currently own any vehicles"
  : null
)

const listView = computed(() => {
  if (!vehicleInventoryStore || !Array.isArray(vehicleInventoryStore.filteredVehicles) || vehicleInventoryStore.filteredVehicles.length === 0) return []
  const res = vehicleInventoryStore.filteredVehicles
  if (singleFunction.value) {
    for (const veh of res) {
      veh.disabled = isTradeInAction(singleFunction.value)
        ? !isTradeInAvailable(veh, singleFunction.value)
        : !isFunctionAvailable(veh, singleFunction.value)
    }
  }
  return res.slice().sort((a, b) => a.favorite ? -1 : b.favorite ? 1 : a.niceName.localeCompare(b.niceName))
})

const groupedVehicles = computed(() => {
  const groups = []
  const lookup = {}
  const currentGarageId = vehicleInventoryStore?.vehicleInventoryData?.currentGarageId
  const currentKey = currentGarageId !== undefined && currentGarageId !== null ? String(currentGarageId) : null

  const ensureGroup = (garageId, niceName) => {
    const garageKey = String(garageId)
    if (!lookup[garageKey]) {
      const garageInfo = garageCapacities.value ? garageCapacities.value[garageKey] : null
      lookup[garageKey] = {
        id: garageId,
        name: niceName || (garageInfo?.name ? $translate.instant(garageInfo.name) : "Garage"),
        hasNiceName: !!niceName,
        capacity: garageInfo?.capacity,
        vehicles: [],
        count: 0,
      }
      groups.push(lookup[garageKey])
    } else if (niceName && !lookup[garageKey].hasNiceName) {
      lookup[garageKey].name = niceName
      lookup[garageKey].hasNiceName = true
    }
    return lookup[garageKey]
  }

  for (const veh of listView.value) {
    const garageId = veh.location ?? "unknown"
    const assignedHere = currentKey !== null && String(garageId) === currentKey
    const physicallyHere = currentKey !== null && !!veh.inGarage
    const displayGroup = (assignedHere || physicallyHere)
      ? ensureGroup(currentGarageId, assignedHere ? veh.niceLocation : null)
      : ensureGroup(garageId, veh.niceLocation)
    displayGroup.vehicles.push(veh)
    ensureGroup(garageId, veh.niceLocation).count++
  }

  if (currentKey !== null) {
    const idx = groups.findIndex(g => String(g.id) === currentKey)
    if (idx > 0) {
      const [current] = groups.splice(idx, 1)
      groups.unshift(current)
    }
  }

  return groups
})

// Layout constants (replacing LIST_LAYOUTS)
const LAYOUT_TYPES = {
  TILE: "tile",
  LIST: "row"
}

const itemLayout = ref(LAYOUT_TYPES.TILE)
const onLayoutChange = val => itemLayout.value = val === LAYOUT_TYPES.LIST ? "row" : "tile"

// returns a function if we only have a single option available
const singleFunction = computed(() => {
  // no data yet
  if (!vehicleInventoryStore || !vehicleInventoryStore.vehicleInventoryData) return null
  const data = vehicleInventoryStore.vehicleInventoryData
  // normal menu functions are available
  if (Object.values(data.buttonsActive).includes(true)) return null
  // zero or more than one custom functions
  if (!Array.isArray(data.chooseButtonsData) || data.chooseButtonsData.length !== 1) return null
  // return the only function available
  return data.chooseButtonsData[0]
})

const handleButtonClick = async (buttonData, index) => {
  const vehicle = vehSelected.value
  if (!vehicle) return
  // Capture before popHide/confirm: popover @hide clears selectedVehId.
  const vehicleId = vehicle.id
  popHide()

  if (buttonData.retrievalAction) {
    const covered = vehicle.retrievalCoveredByInsurance
    const cost = Number(vehicle.retrievalCost) || 0
    const free = vehicle.retrievalFree || (!covered && cost <= 0)
    const confirmationText = free
      ? "Do you want to retrieve this vehicle from this garage?"
      : covered ? "Do you want to retrieve this vehicle and use one insurance roadside-assistance tow?"
      : moneyMessage("Do you want to retrieve this vehicle and pay ", moneyText(units, cost), "?")
    const res = await openHouseConfirmation(
      "",
      confirmationText,
      [
        { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
        { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
      ]
    )
    if (res) {
      vehicleInventoryStore.chooseVehicle(vehicleId, index)
    }
  } else if (buttonData.buttonText === "Deliver" || buttonData.buttonText === "Deliver and replace") {
    const cost = 5000
    const message = moneyMessage(buttonData.buttonText === "Deliver and replace"
      ? "Do you want to deliver this vehicle and replace your current one for "
      : "Do you want to deliver this vehicle to your garage for ", moneyText(units, cost), "?")

    const res = await openHouseConfirmation("", message, [
      { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
      { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
    ])

    if (res) {
      vehicleInventoryStore.chooseVehicle(vehicleId, index)
    }
  } else {
    vehicleInventoryStore.chooseVehicle(vehicleId, index)
  }
}

function select(vehicle, evt) {
  const show =
    vehicleInventoryStore && vehicleInventoryStore.vehicleInventoryData
    && (Object.values(vehicleInventoryStore.vehicleInventoryData.buttonsActive).includes(true) || vehicleInventoryStore.vehicleInventoryData.chooseButtonsData.length > 0)
    && vehicle && (!vehSelected.value || vehSelected.value.id !== vehicle.id)
  let popover
  if (evt && evt.target) {
    let cur = evt.target
    while (true) {
      popover = cur.__popover
      if (popover) break
      cur = cur.parentNode
      if (cur === document.body) break
    }
  }
  // evaluate the single function available, if any
  if (vehicle && singleFunction.value) {
    // next two lines are popover error avoidance for this mode (note: errors are console-only and not affecting anything)
    selectedVehId.value = null
    popover && popover.hide()
    // call the function
    vehicleInventoryStore.chooseVehicle(vehicle.id, 0)
    return
  }
  // hide and nextTick is to make it properly work with uiNav
  show && popover && popover.hide()
  nextTick(() => {
    if (show) {
      selectedVehId.value = vehicle.id
      popover && popover.show()
    } else {
      popover && popover.hide()
      selectedVehId.value = null
    }
  })
}

const isFunctionAvailable = (vehicle, buttonData) => {
  const isDeliverAction = buttonData && (buttonData.buttonText === "Deliver" || buttonData.buttonText === "Deliver and replace")
  const deliverAllowed = !isDeliverAction
    ? true
    : (vehicle && vehicle.deliverPermission && typeof vehicle.deliverPermission.allow === "boolean")
      ? vehicle.deliverPermission.allow
      : (!vehicle.atCurrentGarage && (currentGarageHasSpace.value || hasGlobalGarageSpace.value))

  return !(
    vehicle.timeToAccess ||
    vehicle.missingFile ||
    (!deliverAllowed) ||
    (!isDeliverAction && buttonData.requiredVehicleNotInGarage && vehicle.inGarage) ||
    (buttonData.requiredOtherVehicleInGarage && !vehicle.otherVehicleInGarage) ||
    (buttonData.ownedRequired && !vehicle.owned) ||
    (buttonData.repairRequired && vehicle.needsRepair) ||
    (buttonData.notForSaleRequired && vehicle.listedForSale) ||
    (buttonData.requireAtCurrentGarage && !vehicle.atCurrentGarage) ||
    (buttonData.requireAtDifferentGarage && vehicle.atCurrentGarage) ||
    (!vehicle.atCurrentGarage && !currentGarageHasSpace.value && !hasGlobalGarageSpace.value)
  )
}

const isTradeInAction = buttonData => buttonData?.buttonText === "Trade-In"

const getTradeInBlockerReason = (vehicle, buttonData) => {
  if (vehicle.timeToAccess) return vehicle.delayReason === "engineRetailPickup"
    ? "Ready for pickup at the engine shop"
    : "Vehicle unavailable right now"
  if (vehicle.missingFile) return "Vehicle data missing"
  if (buttonData.requiredVehicleNotInGarage && vehicle.inGarage) return "Vehicle must not be in garage"
  if (buttonData.requiredOtherVehicleInGarage && !vehicle.otherVehicleInGarage) return "Required support vehicle is missing"
  if (buttonData.ownedRequired && !vehicle.owned) return "You do not own this vehicle"
  if (buttonData.repairRequired && vehicle.needsRepair) return "Needs repair"
  if (buttonData.notForSaleRequired && vehicle.listedForSale) return "Vehicle is listed for sale"
  return null
}

const isTradeInAvailable = (vehicle, buttonData) => !getTradeInBlockerReason(vehicle, buttonData)

const isChooserActionAvailable = (vehicle, buttonData) => (
  isTradeInAction(buttonData)
    ? isTradeInAvailable(vehicle, buttonData)
    : isFunctionAvailable(vehicle, buttonData)
)

const getUnavailableReason = (vehicle, buttonData) => {
  if (!isTradeInAction(buttonData)) return buttonData?.buttonText || "Unavailable"
  return `Trade-In (${getTradeInBlockerReason(vehicle, buttonData) || "Unavailable"})`
}

const getTradeInTileReason = vehicle => {
  // chooseButtonsData arrives as {} (not []) when Lua sends an empty table, so guard the lookup
  const buttons = vehicleInventoryStore.vehicleInventoryData?.chooseButtonsData
  const tradeInButtonData = Array.isArray(buttons) ? buttons.find(isTradeInAction) : undefined
  if (!tradeInButtonData || isTradeInAvailable(vehicle, tradeInButtonData)) return null
  return getTradeInBlockerReason(vehicle, tradeInButtonData)
}

const lookAtVehicleListing = () => {
  lua.overhaul_career_market_marketplace.openMenu(vehicleInventoryStore.vehicleInventoryData.originComputerId)
}

const confirmRemoveListing = async () => {
  const vehicle = vehSelected.value
  if (!vehicle) return
  const vehicleId = vehicle.id
  popHide()
  const res = await openHouseConfirmation("", `Take ${vehicle.niceName} off the market? Pending offers will be lost.`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
  ])
  if (!res) return
  await lua.overhaul_career_market_marketplace.removeVehicleListing(vehicleId)
  lua.overhaul_career_garage_inventory.sendVehicleUpdatesToUi()
}

const confirmReturnVehicle = async () => {
  const vehicle = vehSelected.value
  popHide()
  const res = await openHouseConfirmation("", $translate.instant("ui.career.inventory.confirm.returnLoanedVehicle"), [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
  ])
  if (res) lua.overhaul_career_garage_inventory.returnLoanedVehicleFromInventory(vehicle.id)
}

const personalizeLicensePlate = async () => {
  const vehicle = vehSelected.value
  popHide()
  // money must be fresh before the prompt is built: errorMessage below is a fixed string, and careerStatusData
  // starts as {} (which reads as "can't pay"). validate re-reads cantPayLicensePlate each time it runs.
  try {
    await updateCareerStatusData()
    licensePlateCost.value = await lua.overhaul_career_garage_inventory.getLicensePlateCost()
  } catch (e) {
    reportUiFailure(e, "personalizeLicensePlate: could not refresh career status")
    return
  }
  const res = await openHousePrompt(`Costs ${moneyText(units, licensePlateCost.value)}. Up to 10 characters.`, "Personalize license plate", {
    defaultValue: vehicle.licenseName,
    maxLength: 10,
    confirmLabel: "Buy plate",
    validate: text => {
      lua.overhaul_career_garage_inventory.isLicensePlateValid(text).then(valid => {
        licensePlateTextValid.value = valid
      })
      return !cantPayLicensePlate.value && licensePlateTextValid.value && String(text).trim().length > 0
    },
    errorMessage: cantPayLicensePlate.value ? "Not enough money for a custom plate" : "Invalid character in license plate text",
  }).catch(() => false)

  if (res != false)  {
    const purchased = await lua.overhaul_career_garage_inventory.purchaseLicensePlateText(vehicle.id, res)
    if (purchased) vehicle.licenseName = res
  }
}

const confirmExpediteRepair = async () => {
  const vehicle = vehSelected.value
  popHide()
  let price = vehicle.expediteRepairCost
  const res = await openHouseConfirmation("", $translate.instant("ui.career.inventory.confirm.expediteRepair", { price: units.beamBucks(price) }), [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
  ])
  if (res) lua.overhaul_career_garage_inventory.expediteRepairFromInventory(vehicle.id, price)
}

const openRepairMenu = () => {
  const vehicle = vehSelected.value
  popHide()
  lua.overhaul_career_repair_repairScreen.openRepairMenu(vehicle, vehicleInventoryStore.vehicleInventoryData.originComputerId)
}

const setFavoriteVehicle = () => {
  const vehicle = vehSelected.value
  popHide()
  lua.overhaul_career_garage_inventory.setFavoriteVehicle(vehicle.id)
  lua.overhaul_career_garage_inventory.sendVehicleUpdatesToUi()
}

const storeVehicle = async () => {
  const vehicle = vehSelected.value
  if (!vehicle || isStoring.value) return
  const vehicleId = vehicle.id
  popHide()

  if (vehicle.storageTowRequired) {
    const covered = vehicle.storageTowCoveredByInsurance
    const cost = Number(vehicle.storageTowCost) || 0
    const confirmationText = covered
      ? "Tow this vehicle to this garage and put it in storage, and use one insurance roadside-assistance tow?"
      : moneyMessage("Tow this vehicle to this garage and put it in storage, and pay ", moneyText(units, cost), "?")
    const res = await openHouseConfirmation("", confirmationText, [
      { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
      { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
    ])
    if (!res) return
  }

  isStoring.value = true
  try {
    await lua.overhaul_career_garage_inventory.storeVehicleAtClosestGarage(vehicleId)
  } finally {
    isStoring.value = false
  }
}

const renameVehicle = async () => {
  const vehicle = vehSelected.value
  popHide()
  const res = await openHousePrompt("", "Rename vehicle", {
    defaultValue: vehicle.niceName,
    maxLength: 30,
    confirmLabel: "Rename",
    validate: text => {
      lua.overhaul_career_garage_inventory.isVehicleNameValid(text).then(valid => {
        vehicleNameValid.value = valid
      })
      return vehicleNameValid.value && String(text).trim().length > 0
    },
    errorMessage: "Invalid characters in vehicle name",
  }).catch(() => false)

  if (res != false) {
    lua.overhaul_career_garage_inventory.renameVehicle(vehicle.id, res)
    vehicle.niceName = res
  }
}

const listVehicleForSale = async (vehicle) => {
  popHide()
  if (!vehicle) {
    return false
  }
  const formModel = {
    vehicleName: vehicle.niceName,
    odometer: vehicle.odometer,
    mileage: vehicle.mileage,
    thumbnail: vehicle.thumbnail ? `${vehicle.thumbnail}?${vehicle.dirtyDate}` : null,
    marketValue: vehicle.marketSellValue || vehicle.value,
    price: Math.max(50, Math.round(((vehicle.marketSellValue || vehicle.value) || 0) / 50) * 50),
  }
  const formValidator = model => {
    if (!Number.isFinite(model.price) || model.price <= 0) return { error: true, message: "Enter a valid positive price" }
    return { error: false }
  }
  const res = await openHouseFormDialog(
    ListVehicleDialog,
    formModel,
    formValidator,
    "List a Vehicle for Sale",
    undefined,
    [
      { label: "List for sale", value: true, emitData: true, disableIfInvalid: true },
      { label: $translate.instant("ui.common.cancel"), value: false, extras: { cancel: true } },
    ],
    "36em"
  )
  if (!res || !res.value) return false

  const { events } = useBridge()
  const listedOk = await new Promise(resolve => {
    let settled = false
    const requestId = `list_${Date.now()}_${Math.random().toString(16).slice(2)}`
    const finish = ok => {
      if (settled) return
      settled = true
      events.off('marketplaceListVehiclesFinished', onFinished)
      resolve(!!ok)
    }
    const onFinished = payload => {
      if (!payload || payload.requestId !== requestId) return
      finish(payload.ok)
    }
    events.on('marketplaceListVehiclesFinished', onFinished)
    lua.overhaul_career_market_marketplace.listVehicles([{ inventoryId: vehicle.id, value: res.formData.price }], requestId)
      .catch(() => finish(false))
    setTimeout(() => finish(false), 8000)
  })
  return listedOk
}

const listVehicleForSaleFromContextMenu = async () => {
  const vehicle = vehSelected.value
  const listed = await listVehicleForSale(vehicle)
  if (!listed) return
  lua.overhaul_career_market_marketplace.openMenu(vehicleInventoryStore.vehicleInventoryData.originComputerId)
}

const listVehicleForSaleFromMarketplaceMenu = async (vehicle) => {
  await listVehicleForSale(vehicle)
  // Return to marketplace listings (same as context-menu list path).
  lua.overhaul_career_market_marketplace.openMenu(vehicleInventoryStore.vehicleInventoryData.originComputerId)
}

const loadGarageCapacities = async () => {
  const data = await lua.overhaul_career_garage_garageManager.getGarageCapacityData()
  if (data) {
    garageCapacities.value = data
  }
}

const toggleGroup = (garageId, event) => {
  const key = String(garageId)
  collapsedGroups.value = {
    ...collapsedGroups.value,
    [key]: !collapsedGroups.value[key]
  }
  // A arrives as a synthetic mousedown, which drops the controller focus class; put the ring back
  const header = event?.currentTarget
  if (header) nextTick(() => ensureFocus(header))
}

const isCollapsed = (garageId) => !!collapsedGroups.value[String(garageId)]

const onAddListing = (data) => {
  const vehicle = listView.value.find(v => v.id === data.inventoryId)
  listVehicleForSaleFromMarketplaceMenu(vehicle)
}
events.on('addListing', onAddListing)

onMounted(() => {
  loadGarageCapacities()
})

onUnmounted(() => {
  // off(name) on the shared emitter removes every listener.
  events.off('addListing', onAddListing)
})

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* House list: near-black card, garage groups as collapsible sections, slim scrollbar.
   Sized in em off a resolution-scaled font so it keeps its share of the screen at 720p..4K. */
.rls-house.vehicle-list-container {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: 100%;
  height: auto; // hug the list; scroll once it outgrows the screen
  flex: 0 1 auto;
  align-self: flex-start;
  min-height: 0;
  max-height: 100%;
  display: flex;
  flex-direction: column;
  gap: 0.9em;
  padding: 0.8em 0.6em 0.9em 0.8em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-gutter: stable;

  &::-webkit-scrollbar { width: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
}

.vehicle-list-item {
  flex: 0 0 auto;
  max-width: 100%;
}

.garage-group {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
  width: 100%;
  flex-shrink: 0;
}

/* header: chevron (turns down when open) · garage name · count pill */
.garage-header {
  position: relative;
  display: flex;
  align-items: center;
  gap: 0.55em;
  padding: 0.35em 0.2em 0.25em;
  border-radius: var(--radius-thumb);
  cursor: pointer;
  &:hover .garage-chevron {
    color: #fff;
  }
  @include house-focus;
}
.garage-chevron {
  flex: 0 0 auto;
  width: 0.8em;
  height: 0.8em;
  fill: none;
  stroke: currentColor;
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
  color: var(--faint);
  transition: transform 0.15s ease-out, color 0.12s;
}
.garage-header.open .garage-chevron {
  transform: rotate(90deg);
}
.garage-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  padding-top: 0.1em; // Overpass sits high
  font-size: 1.05em;
  font-weight: 800;
  color: #fff;
}
.garage-capacity {
  font-variant-numeric: tabular-nums;
}

.garage-vehicles {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
  min-height: 0;
}

/* actions menu rows (slot content keeps this scope even though the popover is teleported) */
.menu-money {
  margin-left: auto;
  color: var(--money);
  font-variant-numeric: tabular-nums;
}
</style>

<!-- Global on purpose: the actions popover lives in the page-wide .popover-container. -->
<style lang="scss">
.bng-popover[data-bng-popover-name^="veh_options"] {
  --popover-bg-override: #1a1a1c;
  min-width: 15em;
  padding: 0.35em;
  border-radius: 0.5em;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 12px 28px rgba(0, 0, 0, 0.5);
  > .bng-popover-arrow {
    width: 0.7em;
    height: 0.7em;
  }
  // no action applies to this vehicle (e.g. listed for sale at another garage): don't show an empty menu
  &:not(:has(.house-button)) {
    display: none;
  }
}
</style>
