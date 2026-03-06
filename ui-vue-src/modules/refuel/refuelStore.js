import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"

// DEBUG_ONLY >>
import { getMockedData, runInBrowser} from '@/utils'
// << END_DEBUG_ONLY

const isFuelEnergyType = type => ["gasoline", "diesel"].includes(type)

export const useRefuelStore = defineStore("refuel", () => {
  const { events } = useBridge()

  const minSlider = 23,
    maxSlider = 80
  const minEnergy = 0
  const fuelOptions = [
    { id: 1, value: 0, name: "FuelType-1" },
    { id: 2, value: 1, name: "FuelType-2" },
    { id: 3, value: 2, name: "FuelType-3" },
  ]

  let energyTypes = ref([]),
    fuelTanks = ref([]),
    overallPrice = ref(0),
    flowRate = ref(0),
    currentEnergyType = ref(null),
    showFuelTypeSettings = ref(false),
    showAmountSettings = ref(false),
    energyTypesToLocalUnits = ref({}),
    gasStationName = ref(""),
    fuelDiscountData = ref({})

  const isFuelling = computed(() => flowRate.value > 0)
  const currentFuelData = computed(() => fuelTanks.value.filter(f => f.energyType === currentEnergyType.value)[0])
  const currentFuelType = computed(() => (currentEnergyType.value !== "" ? (isFuelEnergyType(currentEnergyType.value) ? "fuel" : "charge") : ""))
  const currentFuelLevel = computed(() => (currentFuelData.value ? currentFuelData.value.currentEnergy / currentFuelData.value.maxEnergy : 0))
  const canRefuel = computed(() => (currentFuelData.value ? currentFuelData.value.currentEnergy < currentFuelData.value.maxEnergy : false))
  const nozzleMode = computed(() => (canRefuel.value === true ? (isFuelling.value === true ? "on" : "off") : "disabled"))
  const canPay = computed(() => currentFuelData.value.price > 0)
  const canStartFuelling = computed(() => isFuelling.value === false && canRefuel.value === true)
  const canStopFuelling = computed(() => isFuelling.value === true)
  const minEnergyLabel = computed(() => minEnergy + " " + getUnitLabel(currentEnergyType.value))
  const maxEnergyLabel = computed(() =>
    currentFuelData.value
      ? (isFuelEnergyType(currentEnergyType.value) ? convertToLocalUnit(currentFuelData.value.maxEnergy, currentEnergyType.value).toFixed(2) : "100") + " " + getUnitLabel(currentEnergyType.value)
      : ""
  )

  function getUnitLabel(energyType) {
    return (isFuelEnergyType(energyType) ? getLocalUnitLabel(energyType) : "%")
  }

  function getLocalUnit(energyType) {
    return energyTypesToLocalUnits.value[energyType] ? energyTypesToLocalUnits.value[energyType] : "L"
  }

  const unitToLabel = {"gallonUS": "gal"}
  const factorSIToLocalUnit = {"gallonUS": 0.26417}

  function getLocalUnitLabel(energyType) {
    let localUnit = getLocalUnit(energyType)
    if (!localUnit) { return "L"}
    return unitToLabel[localUnit] ? unitToLabel[localUnit] : "L"
  }

  function convertToLocalUnit(valueSI, energyType) {
    let localUnit = getLocalUnit(energyType)
    if (!localUnit) { return valueSI}
    let factor = factorSIToLocalUnit[localUnit]
    return valueSI * (factor ? factor : 1)
  }

  function convertToPricePerLocalUnit(pricePerSI, energyType) {
    let localUnit = getLocalUnit(energyType)
    if (!localUnit) { return pricePerSI}
    let factor = factorSIToLocalUnit[localUnit]
    return pricePerSI / (factor ? factor : 1)
  }

  function startFuelling() {
    lua.career_modules_fuel.uiButtonStartFueling(currentEnergyType.value)
  }

  function stopFuelling() {
    lua.career_modules_fuel.uiButtonStopFueling(currentEnergyType.value)
  }

  function changeFlowRate(newFlowRate) {
    flowRate.value = newFlowRate
    lua.career_modules_fuel.onChangeFlowRate(flowRate.value)
  }

  function payPrice() {
    lua.career_modules_fuel.payPrice()
  }

  function requestFuelingData() {
    lua.career_modules_fuel.requestRefuelingTransactionData()

    // DEBUG_ONLY >> Get some mock fuel data if we're outside the game
    runInBrowser(
      () => getMockedData('career.initialFuelingData').then(data => events.emit("initialFuelingData", data))
    )
    // << END_DEBUG_ONLY
  }

  function cancelTransaction() {
    lua.career_modules_fuel.uiCancelTransaction()
  }

  function dispose() {
    events.off('initialFuelingData')
    events.off('updateFuelData')
  }

  events.on("initialFuelingData", data => {
    ({ fuelData: fuelTanks.value, energyTypes: energyTypes.value } = data)
    currentEnergyType.value = energyTypes.value[0]
    energyTypesToLocalUnits.value = data.energyTypesToLocalUnits
    gasStationName.value = data.gasStationName
    fuelDiscountData.value = data.fuelDiscountData || {}
    lua.career_modules_fuel.sendUpdateDataToUI()
  })

  events.on("updateFuelData", data => {
    if (fuelTanks.value.length === 0 || !Array.isArray(data?.fuelData)) return

    for (let i = 0; i < data.fuelData.length; i++) {
      const update = data.fuelData[i]
      if (!update) continue

      let tank = null
      if (update.energyType) {
        tank = fuelTanks.value.find(t => t.energyType === update.energyType)
      }
      if (!tank && i < fuelTanks.value.length) {
        tank = fuelTanks.value[i]
      }
      if (!tank) continue

      tank.currentEnergy = update.currentEnergy
      tank.fueledEnergy = update.fueledEnergy
      tank.price = update.price
      tank.fuelingActive = update.fuelingActive
    }

    overallPrice.value = data.overallPrice
    flowRate.value = data.fuelData.some(t => t && t.fuelingActive === true) ? 1 : 0
  })

  return {
    currentFuelData,
    currentFuelLevel,
    currentFuelType,
    currentEnergyType,
    nozzleMode,
    overallPrice,
    isFuelling,
    energyTypes,
    canPay,
    canStartFuelling,
    canStopFuelling,
    fuelDiscountData,
    showFuelTypeSettings,
    showAmountSettings,
    gasStationName,
    startFuelling,
    stopFuelling,
    changeFlowRate,
    payPrice,
    requestFuelingData,
    cancelTransaction,
    getUnitLabel,
    convertToPricePerLocalUnit,
    dispose,
    minEnergyLabel,
    maxEnergyLabel,
    minSlider,
    maxSlider,
    fuelOptions,
  }
})
