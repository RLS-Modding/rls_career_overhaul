<template>
  <div class="vehicle-list-container" v-bng-disabled="!vehicleInventoryStore">
    <VehicleTileRow class="vehicle-list-item" v-if="listStatus" :data="{ _message: listStatus }" :layout="itemLayout" v-bng-disabled />
    <VehicleTileRow class="vehicle-list-item" v-else v-for="vehicle in listView" :key="vehicle.id"
      :data="vehicle" :layout="itemLayout" :selected="vehSelected && vehSelected.id === vehicle.id"
      :is-tutorial="vehicleInventoryStore && vehicleInventoryStore.vehicleInventoryData.tutorialActive"
      :money="vehicleInventoryStore ? vehicleInventoryStore.vehicleInventoryData.playerMoney : 0"
      v-bng-disabled="vehicle.disabled"
      tabindex="0" bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
      v-bng-popover:right-start.click="popId" @click="!vehicle.disabled && select(vehicle, $event)" />

    <BngPopoverMenu :name="popId" focus @hide="selectedVehId = null">
      <template v-for="(buttonData, index) in vehicleInventoryStore.vehicleInventoryData.chooseButtonsData" :key="index">
    <BngButton v-if="vehSelected && isFunctionAvailable(vehSelected, buttonData)"
          :accent="ACCENTS.menu"
          v-bng-on-ui-nav:ok.focusRequired.asMouse
          @click="vehicleInventoryStore.chooseVehicle(vehSelected.id, index)">
      {{ buttonData.buttonText }}<span v-if="buttonData.repairRequired && vehSelected?.needsRepair"> (Damaged)</span>
        </BngButton>
      </template>
      <BngButton
        v-if="vehSelected && vehicleInventoryStore.vehicleInventoryData.buttonsActive.returnLoanerEnabled && vehSelected.returnLoanerPermission.allow"
        :accent="ACCENTS.menu"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmReturnVehicle()">
        Return loaned vehicle
      </BngButton>
      <BngButton
        v-if="vehSelected && vehSelected.delayReason === 'repair'"
        :accent="ACCENTS.menu"
        :disabled="vehSelected.expediteRepairCost > vehicleInventoryStore.vehicleInventoryData.playerMoney"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="confirmExpediteRepair(vehSelected)">
        Expedite Repair
        <BngUnit :money="vehSelected.expediteRepairCost" />
      </BngButton>
      <BngButton
        v-if="vehSelected && vehSelected.delayReason !== 'repair' && vehicleInventoryStore.vehicleInventoryData.buttonsActive.repairEnabled"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.repairPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="openRepairMenu()">
        Repair
      </BngButton>
      <BngButton
        v-if="vehSelected && vehicleInventoryStore.vehicleInventoryData.buttonsActive.storingEnabled && !vehSelected.inStorage"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.storePermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="storeVehicle()">
        Put in storage
      </BngButton>
      <BngButton
        v-if="vehSelected && vehicleInventoryStore.vehicleInventoryData.buttonsActive.favoriteEnabled"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.favoritePermission.allow || vehSelected.favorite"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="setFavoriteVehicle()">
        Set as Favorite
      </BngButton>
      <BngButton
        v-if="vehSelected"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.licensePlateChangePermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="personalizeLicensePlate(vehSelected)">
        Personalize license plate
      </BngButton>
      <BngButton
        v-if="vehSelected"
        :accent="ACCENTS.menu"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="renameVehicle()">
        Rename vehicle
      </BngButton>
      <BngButton
        v-if="vehSelected && vehicleInventoryStore.vehicleInventoryData.buttonsActive.sellEnabled && !vehSelected.listedForSale"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.sellPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="listVehicleForSaleFromContextMenu()">
        List vehicle for sale
      </BngButton>
      <BngButton
        v-if="vehSelected && vehicleInventoryStore.vehicleInventoryData.buttonsActive.sellEnabled && vehSelected.listedForSale"
        :accent="ACCENTS.menu"
        :disabled="!vehSelected.sellPermission.allow"
        v-bng-on-ui-nav:ok.focusRequired.asMouse
        @click="lookAtVehicleListing()">
        Go to vehicle listing
      </BngButton>
    </BngPopoverMenu>
  </div>
</template>

<script setup>
import { ref, computed, nextTick, onUnmounted } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngButton, BngPopoverMenu, BngUnit, ACCENTS } from "@/common/components/base"
import { vBngDisabled, vBngPopover, vBngOnUiNav } from "@/common/directives"
import VehicleTileRow from "./VehicleTileRow.vue"
import { useVehicleInventoryStore } from "../../stores/vehicleInventoryStore"
import { openConfirmation, openPrompt, openFormDialog } from "@/services/popup"
import { $translate } from "@/services/translation"
import { usePopover } from "@/services/popover"
import { uniqueId } from "@/services/uniqueId"
import ListVehicleDialog from "./ListVehicleDialog.vue"
import { useLibStore } from "@/services"
import router from "@/router"

const { units } = useBridge()

const { $game } = useLibStore()
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
  (buttonData.notForSaleRequired && vehicle.listedForSale)
)

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
  lua.career_modules_insurance_repairScreen.openRepairMenu(vehicle, vehicleInventoryStore.vehicleInventoryData.originComputerId)
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
  lua.career_modules_inventory.removeVehicleObject(vehicle.id)
  lua.career_modules_inventory.sendDataToUi()
}

const buyInsurance = (insuranceId) => {
  popHide()
  lua.career_modules_insurance_insurance.purchaseInsurance(insuranceId)
  lua.career_modules_inventory.sendDataToUi()
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

const listVehicleForSale = async (vehicle) => {
  popHide()
  const formModel = {
    vehicleName: vehicle.niceName,
    odometer: vehicle.odometer,
    marketValue: vehicle.value,
    price: Math.max(50, Math.round((vehicle.value || 0) / 50) * 50),
  }
  const formValidator = model => {
    if (!Number.isFinite(model.price) || model.price <= 0) return { error: true, message: "Enter a valid positive price" }
    return { error: false }
  }
  const res = await openFormDialog(
    ListVehicleDialog,
    formModel,
    formValidator,
    "List a Vehicle for Sale",
    undefined,
    undefined,
    "90rem"
  )
  if (!res || !res.value) return
  await lua.career_modules_marketplace.listVehicles([{ inventoryId: vehicle.id, value: res.formData.price }])
}

const listVehicleForSaleFromContextMenu = async () => {
  const vehicle = vehSelected.value
  await listVehicleForSale(vehicle)
  lua.career_modules_marketplace.openMenu(vehicleInventoryStore.vehicleInventoryData.originComputerId)
}

const listVehicleForSaleFromMarketplaceMenu = async (vehicle) => {
  await listVehicleForSale(vehicle)
  router.back()
}

$game.events.on('addListing', (data) => {
  const vehicle = listView.value.find(v => v.id === data.inventoryId)
  listVehicleForSaleFromMarketplaceMenu(vehicle)
})

onUnmounted(() => {
  $game.events.off('addListing')
})


</script>

<style scoped lang="scss">
.vehicle-list-container {
  padding-top: 2rem;
  width: 100%;
  display: flex;
  flex-direction: column;
  background-color: var(--bng-black-8);
  border-radius: var(--bng-corners-2);
  padding: 0.5rem;
  gap: 0.5rem;
  overflow-y: auto;
}

.vehicle-list-item {
  flex: 0 0 auto;
  max-height: 12rem;
  max-width: 100%;
}



</style>
