<template>
  <BngList layout-selector v-bng-disabled="!vehicleInventoryStore" @layout-change="onLayoutChange" :layout="LIST_LAYOUTS.TILES">
    <VehicleTile v-if="listStatus" :data="{ _message: listStatus }" :layout="itemLayout" v-bng-disabled />
    <VehicleTile v-else v-for="vehicle in listView" :key="vehicle.id"
      :data="vehicle" :layout="itemLayout" :selected="vehSelected && vehSelected.id === vehicle.id"
      :is-tutorial="vehicleInventoryStore && vehicleInventoryStore.vehicleInventoryData.tutorialActive"
      :money="vehicleInventoryStore ? vehicleInventoryStore.vehicleInventoryData.playerMoney : 0"
      v-bng-disabled="vehicle.disabled"
      tabindex="0" bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
      v-bng-popover:right-start.click="popId" @click="select(vehicle, $event)" />

    <BngPopoverMenu :name="popId" focus @hide="selectedVehId = null">
      <template v-for="(buttonData, index) in vehicleInventoryStore.vehicleInventoryData.chooseButtonsData" :key="index">
        <BngButton v-if="buttonData.repairRequired && vehSelected && vehSelected.needsRepair && !vehicleInventoryStore.vehicleInventoryData.tutorialActive"
          :accent="ACCENTS.menu" disabled>
          {{ buttonData.buttonText }} (Needs repair)
        </BngButton>
        <BngButton v-else-if="isFunctionAvailable(vehSelected, buttonData)"
          :accent="ACCENTS.menu"
          v-bng-on-ui-nav:ok.focusRequired.asMouse
          @click="vehicleInventoryStore.chooseVehicle(vehSelected.id, index)">
          {{ buttonData.buttonText }}
        </BngButton>
      </template>
      <BngButton
        v-if="vehicleInventoryStore.vehicleInventoryData.buttonsActive.returnLoanerEnabled && vehSelected.returnLoanerPermission && vehSelected.returnLoanerPermission.allow"
        :accent="ACCENTS.menu"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmReturnVehicle()">
        Return loaned vehicle
      </BngButton>
      <BngButton
        v-if="vehSelected.junkVehicle && vehSelected.junkVehicle.allow"
        :accent="ACCENTS.menu"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmJunkVehicle()">
        Junk vehicle
      </BngButton>
      <BngButton
        v-if="vehSelected.delayReason === 'repair'"
        :accent="ACCENTS.menu"
        :disabled="vehSelected.expediteRepairCost > vehicleInventoryStore.vehicleInventoryData.playerMoney"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmExpediteRepair(vehSelected)">
        Expedite Repair
        <BngUnit :money="vehSelected.expediteRepairCost" />
      </BngButton>
      <BngButton
        v-if="vehSelected.delayReason !== 'repair' && vehicleInventoryStore.vehicleInventoryData.buttonsActive.repairEnabled"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.repairPermission || !vehSelected.repairPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="openRepairMenu()">
        Repair
      </BngButton>
      <BngButton
        v-if="vehicleInventoryStore.vehicleInventoryData.buttonsActive.storingEnabled && !vehSelected.inStorage"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.storePermission || !vehSelected.storePermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="storeVehicle()">
        Put in storage
      </BngButton>
      <BngButton
        v-if="vehSelected.deliverPermission && vehSelected.deliverPermission.allow"
        :accent="ACCENTS.menu"
        @click="deliverVehicle()">
        Deliver to garage
      </BngButton>
      <BngButton
        :accent="ACCENTS.menu"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="openInsurance()">
        Change insurance
      </BngButton>
      <BngButton
        v-if="vehicleInventoryStore.vehicleInventoryData.buttonsActive.favoriteEnabled"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.favoritePermission || !vehSelected.favoritePermission.allow || vehSelected.favorite"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="setFavoriteVehicle()">
        Set as Favorite
      </BngButton>
      <BngButton
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.licensePlateChangePermission || !vehSelected.licensePlateChangePermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="personalizeLicensePlate(vehSelected)">
        Personalize license plate
      </BngButton>
      <BngButton
        :accent="ACCENTS.menu"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="renameVehicle()">
        Rename vehicle
      </BngButton>
      <BngButton
        v-if="vehicleInventoryStore.vehicleInventoryData.buttonsActive.sellEnabled && !vehSelected.listedForSale"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.sellPermission || !vehSelected.sellPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="listVehicleForSale()">
        List vehicle for sale
      </BngButton>
      <BngButton
        v-if="vehicleInventoryStore.vehicleInventoryData.buttonsActive.sellEnabled && vehSelected.listedForSale"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.sellPermission || !vehSelected.sellPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="lookAtVehicleListing()">
        Go to vehicle listing
      </BngButton>
    </BngPopoverMenu>
  </BngList>
</template>

<script setup>
import { ref, computed, nextTick } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngList, BngButton, BngPopoverMenu, BngUnit, ACCENTS, LIST_LAYOUTS } from "@/common/components/base"
import { vBngDisabled, vBngPopover, vBngOnUiNav } from "@/common/directives"
import VehicleTile from "./VehicleTile.vue"
import { useVehicleInventoryStore } from "../../stores/vehicleInventoryStore"
import { openConfirmation, openPrompt } from "@/services/popup"
import { $translate } from "@/services/translation"
import { usePopover } from "@/services/popover"
import { uniqueId } from "@/services/uniqueId"

const { units } = useBridge()

const popover = usePopover()
const popId = uniqueId("veh_options")
const popHide = () => popover.hide(popId)
const licensePlateTextValid = ref(true)
const vehicleNameValid = ref(true)

const vehicleInventoryStore = useVehicleInventoryStore()
const selectedVehId = ref()

const vehSelected = computed(() => {
  if (typeof selectedVehId.value !== "number") return undefined
  return listView.value.find(v => v.id === selectedVehId.value)
})

const careerStatusData = ref({})

const updateCareerStatusData = () => lua.career_modules_uiUtils.getCareerStatusData().then(data => (careerStatusData.value = data))

const cantPayLicensePlate = computed(() =>
  !careerStatusData.value.money || 300 > careerStatusData.value.money
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
      veh.disabled = !isFunctionAvailable(veh, singleFunction.value)
    }
  }
  res.sort((a, b) => a.favorite ? -1 : b.favorite ? 1 : a.niceName.localeCompare(b.niceName))
  return res
})

const itemLayout = ref("tile")
const onLayoutChange = val => itemLayout.value = val === LIST_LAYOUTS.LIST ? "row" : "tile"

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
    // console.log(show ? "SHOW" : "HIDE", popover.isShown() === show ? "success" : "fail", evt.target)
  })
}

const isFunctionAvailable = (vehicle, buttonData) => !(
  vehicle.timeToAccess ||
  vehicle.missingFile ||
  (buttonData.requiredVehicleNotInGarage && vehicle.inGarage) ||
  (buttonData.requiredOtherVehicleInGarage && !vehicle.otherVehicleInGarage) ||
  (buttonData.ownedRequired && !vehicle.owned) ||
  (buttonData.requireAtCurrentGarage && (!vehicle.retrievePermission || !vehicle.retrievePermission.allow)) ||
  (buttonData.requireAtDifferentGarage && (!vehicle.deliverPermission || !vehicle.deliverPermission.allow))
)

const listVehicleForSale = () => {
  const vehicle = vehSelected.value
  popHide()
  lua.career_modules_marketplace.listVehicles([vehicle.id]).then(() => {
    lua.career_modules_marketplace.openMenu(vehicleInventoryStore.vehicleInventoryData.originComputerId)
  })
}

const lookAtVehicleListing = () => {
  lua.career_modules_marketplace.openMenu(vehicleInventoryStore.vehicleInventoryData.originComputerId)
}

const confirmReturnVehicle = async () => {
  const vehicle = vehSelected.value
  popHide()
  const res = await openConfirmation("", `Do you want to return this loaned vehicle to the owner?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])
  if (res) lua.career_modules_inventory.returnLoanedVehicleFromInventory(vehicle.id)
}

const confirmJunkVehicle = async () => {
  const vehicle = vehSelected.value
  popHide()
  const res = await openConfirmation("", `Do you want to junk this vehicle?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])
  if (res) {
    lua.career_modules_inventory.removeVehicle(vehicle.id)
    lua.career_modules_inventory.sendDataToUi()
  }
}

const personalizeLicensePlate = async () => {
  const vehicle = vehSelected.value
  popHide()
  updateCareerStatusData()
  const res = await openPrompt("Enter your new license plate text:", "Personalize License Plate",
  {
    maxLength: 10, defaultValue: vehicle.config.licenseName,
    buttons: [
      { label: $translate.instant("ui.common.cancel"), value: false, extras: { cancel: true, accent: ACCENTS.secondary } },
      { label: $translate.instant("ui.common.okay") + ` (Cost: ${units.beamBucks(300)})`, value: text => text, extras: {
        disabled: cantPayLicensePlate,
        accent: ACCENTS.primary
      } },
    ],
    validate: text => {
      lua.career_modules_inventory.isLicensePlateValid(text).then(valid => {
        licensePlateTextValid.value = valid
      })
      return licensePlateTextValid.value
    } ,
    errorMessage: "Invalid character in license plate text",
    disableWhenInvalid: true,
  })

  if (res != false)  {
    lua.career_modules_inventory.purchaseLicensePlateText(vehicle.id, res, 300)
    vehicle.config.licenseName = res
  }
}

const confirmExpediteRepair = async () => {
  const vehicle = vehSelected.value
  popHide()
  let price = vehicle.expediteRepairCost
  const res = await openConfirmation("", `Do you want to expedite the repair for ${units.beamBucks(price)}?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])
  if (res) lua.career_modules_inventory.expediteRepairFromInventory(vehicle.id, price)
}

const openRepairMenu = () => {
  const vehicle = vehSelected.value
  popHide()
  lua.career_modules_insurance.openRepairMenu(vehicle, vehicleInventoryStore.vehicleInventoryData.originComputerId)
}

const setFavoriteVehicle = () => {
  const vehicle = vehSelected.value
  popHide()
  lua.career_modules_inventory.setFavoriteVehicle(vehicle.id)
  lua.career_modules_inventory.sendDataToUi()
}

const storeVehicle = () => {
  const vehicle = vehSelected.value
  popHide()
  lua.career_modules_inventory.storeVehicle(vehicle.id)
  lua.career_modules_inventory.removeVehicleObject(vehicle.id)
  lua.career_modules_inventory.sendDataToUi()
}

const deliverVehicle = async () => {
  const vehicle = vehSelected.value
  popHide()
  let price = 5000
  const res = await openConfirmation("", `Do you want to deliver this vehicle to your garage for ${units.beamBucks(price)}?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])
  if (res) {
    lua.career_modules_inventory.deliverVehicle(vehicle.id, price).then(() => {
      // Wait for delivery to complete before refreshing UI
      lua.career_modules_inventory.sendDataToUi()
    })
  }
}

const openInsurance = () => {
  const vehicle = vehSelected.value
  popHide()
  // open insurance policies screen via router
  popover && popHide()
  router.push({ name: 'insurancePolicies' })
}

const renameVehicle = async () => {
  const vehicle = vehSelected.value
  popHide()
  const res = await openPrompt("Enter new vehicle name:", "Rename Vehicle",
  {
    maxLength: 30, defaultValue: vehicle.niceName,
    buttons: [
      { label: $translate.instant("ui.common.cancel"), value: false, extras: { cancel: true, accent: ACCENTS.secondary } },
      { label: $translate.instant("ui.common.okay"), value: text => text, extras: {
        accent: ACCENTS.primary
      } },
    ],
    validate: text => {
      lua.career_modules_inventory.isVehicleNameValid(text).then(valid => {
        vehicleNameValid.value = valid
      })
      return vehicleNameValid.value
    } ,
    errorMessage: "Invalid characters in vehicle name",
    disableWhenInvalid: true,
  })

  if (res != false) {
    lua.career_modules_inventory.renameVehicle(vehicle.id, res)
    vehicle.niceName = res
  }
}
</script>
