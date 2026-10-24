// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

import { onScopeDispose, computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"

const isFuelEnergyType = type => ["gasoline", "diesel", "kerosine", "n2o"].includes(type)

// States: written by the Lua events and the UI actions, read by the views.
function createFuelState() {
  const energyTypes = ref([]),
    fuelTanks = ref([]),
    overallPrice = ref(0),
    flowRate = ref(0),
    selectedTankIndex = ref(0),
    showFuelTypeSettings = ref(false),
    showAmountSettings = ref(false),
    energyTypesToLocalUnits = ref({}),
    gasStationName = ref(""),
    fuelDiscountData = ref({}),
    canPay = ref(false),
    isAutoFuelling = ref(false)

  return {
    energyTypes, fuelTanks, overallPrice, flowRate, selectedTankIndex, showFuelTypeSettings, showAmountSettings,
    energyTypesToLocalUnits, gasStationName, fuelDiscountData, canPay, isAutoFuelling,
  }
}

// Local unit labels and conversions. Each energy type maps to a local unit, "L" when none is given.
function createFuelUnits(energyTypesToLocalUnits) {
  const unitToLabel = {"gallonUS": "gal"}
  // The Lua payload's factorSIToLocalUnit is assigned to .value on this object, so these built-in factors are what conversions use.
  const factorSIToLocalUnit = {"gallonUS": 0.26417}

  // TODO instead of using "L" as default everywhere, it should be a dict mapping energy types to default units
  function getUnitLabel(energyType) {
    return (isFuelEnergyType(energyType) ? getLocalUnitLabel(energyType) : "%")
  }

  function getLocalUnit(energyType) {
    return energyTypesToLocalUnits.value[energyType] ? energyTypesToLocalUnits.value[energyType] : "L"
  }

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

  return { getUnitLabel, convertToLocalUnit, convertToPricePerLocalUnit, factorSIToLocalUnit }
}

// Getters: the selected tank, the nozzle, the capacity labels and the tank menu, all derived from the state.
function createFuelViews(state, units) {
  const { fuelTanks, selectedTankIndex } = state
  const { getUnitLabel, convertToLocalUnit } = units
  const minEnergy = 0

  const isFuelling = computed(() => fuelTanks.value.some(f => f.fuelingActive === true))
  const currentFuelData = computed(() => fuelTanks.value[selectedTankIndex.value])
  const currentEnergyType = computed(() => currentFuelData.value?.energyType || null)
  const currentFuelType = computed(() => (currentEnergyType.value ? (isFuelEnergyType(currentEnergyType.value) ? "fuel" : "charge") : ""))
  const currentFuelLevel = computed(() => (currentFuelData.value ? currentFuelData.value.currentEnergy / currentFuelData.value.maxEnergy : 0))
  const canRefuel = computed(() => (currentFuelData.value ? currentFuelData.value.currentEnergy < currentFuelData.value.maxEnergy : false))
  const isCurrentTankFuelling = computed(() => currentFuelData.value?.fuelingActive === true)
  const nozzleMode = computed(() => (canRefuel.value === true ? (isCurrentTankFuelling.value === true ? "on" : "off") : "disabled"))
  const canStartFuelling = computed(() => isFuelling.value === false && canRefuel.value === true)
  const canStopFuelling = computed(() => isCurrentTankFuelling.value === true)
  const hasMultipleTanks = computed(() => fuelTanks.value.length > 1)
  const tankOptions = computed(() => fuelTanks.value.map((tank, index) => ({
    value: index,
    label: {
      txt: "ui.career.refueling.tankIndex",
      context: {
        index: index + 1,
        total: fuelTanks.value.length,
      },
    },
    tank,
  })))
  const minEnergyLabel = computed(() => minEnergy + " " + getUnitLabel(currentEnergyType.value))
  const maxEnergyLabel = computed(() =>
    currentFuelData.value
      ? (isFuelEnergyType(currentEnergyType.value) ? convertToLocalUnit(currentFuelData.value.maxEnergy, currentEnergyType.value).toFixed(2) : "100") + " " + getUnitLabel(currentEnergyType.value)
      : ""
  )

  return {
    isFuelling, currentFuelData, currentEnergyType, currentFuelType, currentFuelLevel, canRefuel, isCurrentTankFuelling,
    nozzleMode, canStartFuelling, canStopFuelling, hasMultipleTanks, tankOptions, minEnergyLabel, maxEnergyLabel,
  }
}

// Actions: each Lua call uses the one-based tank index, and tank selection is blocked while fuelling.
function createFuelActions(state, views) {
  const { fuelTanks, selectedTankIndex, flowRate, isAutoFuelling } = state
  const { isFuelling } = views

  function startFuelling() {
    isAutoFuelling.value = true
    return lua.overhaul_career_maintenance_fuel.uiButtonStartFuelingTank(selectedTankIndex.value + 1)
  }

  function stopFuelling() {
    isAutoFuelling.value = false
    return lua.overhaul_career_maintenance_fuel.uiButtonStopFuelingTank(selectedTankIndex.value + 1)
  }

  function changeFlowRate(newFlowRate) {
    if (newFlowRate <= 0) isAutoFuelling.value = false
    flowRate.value = newFlowRate
    lua.overhaul_career_maintenance_fuel.onChangeFlowRate(flowRate.value, selectedTankIndex.value + 1)
  }

  function setSelectedTankIndex(index) {
    if (isFuelling.value) return
    const nextIndex = Math.max(0, Math.min(Number(index) || 0, fuelTanks.value.length - 1))
    selectedTankIndex.value = nextIndex
    lua.overhaul_career_maintenance_fuel.uiSetSelectedTankIndex(nextIndex + 1)
  }

  function selectPreviousTank() {
    if (isFuelling.value || fuelTanks.value.length <= 1) return
    setSelectedTankIndex((fuelTanks.value.length + selectedTankIndex.value - 1) % fuelTanks.value.length)
  }

  function selectNextTank() {
    if (isFuelling.value || fuelTanks.value.length <= 1) return
    setSelectedTankIndex((selectedTankIndex.value + 1) % fuelTanks.value.length)
  }

  function payPrice() {
    return lua.overhaul_career_maintenance_fuel.payPrice()
  }

  function requestFuelingData() {
    lua.overhaul_career_maintenance_fuel.requestRefuelingTransactionData()
  }

  function cancelTransaction() {
    console.log("cancelTransaction")
    return lua.overhaul_career_maintenance_fuel.uiCancelTransaction()
  }

  return {
    startFuelling, stopFuelling, changeFlowRate, setSelectedTankIndex, selectPreviousTank, selectNextTank,
    payPrice, requestFuelingData, cancelTransaction,
  }
}

// Lua events that fill and refresh the state, and the dispose that removes them.
function listenToFuelEvents(events, state, units, views) {
  const {
    energyTypes, fuelTanks, overallPrice, flowRate, selectedTankIndex, energyTypesToLocalUnits,
    gasStationName, fuelDiscountData, canPay, isAutoFuelling,
  } = state
  const { factorSIToLocalUnit } = units
  const { isFuelling, currentFuelData } = views

  function dispose() {
    events.off("initialFuelingData", handleInitialFuelingData)
    events.off("updateFuelData", handleUpdateFuelData)
  }

  function handleInitialFuelingData(data) {
    ({ fuelData: fuelTanks.value, energyTypes: energyTypes.value } = data)
    selectedTankIndex.value = Math.max(0, Math.min((data.selectedTankIndex || 1) - 1, fuelTanks.value.length - 1))
    energyTypesToLocalUnits.value = data.energyTypesToLocalUnits
    factorSIToLocalUnit.value = data.factorSIToLocalUnit
    gasStationName.value = data.gasStationName
    fuelDiscountData.value = data.fuelDiscountData || {}
    lua.overhaul_career_maintenance_fuel.sendUpdateDataToUI()
  }

  function handleUpdateFuelData(data) {
    // Received hook before initialFuelingData has been received
    if (fuelTanks.value.length === 0) return

    data.fuelData.forEach((tankData, index) => {
      if (!fuelTanks.value[index]) return
      fuelTanks.value[index] = {
        ...fuelTanks.value[index],
        ...tankData,
      }
    })
    overallPrice.value = data.overallPrice
    canPay.value = data.canPay === true

    const currentTankActive = currentFuelData.value?.fuelingActive === true
    flowRate.value = currentTankActive ? data.flowRate : 0
    if (!isFuelling.value) isAutoFuelling.value = false
  }

  events.on("initialFuelingData", handleInitialFuelingData)
  events.on("updateFuelData", handleUpdateFuelData)

  return { dispose }
}

export const useRefuelStore = defineStore("overhaulRefuel", () => {
  const { events } = useBridge()

  // Demo or Constant Values?
  const minSlider = 23,
    maxSlider = 80
  const fuelOptions = [
    { id: 1, value: 0, name: "FuelType-1" },
    { id: 2, value: 1, name: "FuelType-2" },
    { id: 3, value: 2, name: "FuelType-3" },
  ]

  const state = createFuelState()
  const units = createFuelUnits(state.energyTypesToLocalUnits)
  const views = createFuelViews(state, units)
  const actions = createFuelActions(state, views)
  const { dispose } = listenToFuelEvents(events, state, units, views)
  onScopeDispose(dispose)

  return {
    currentFuelData: views.currentFuelData,
    currentFuelLevel: views.currentFuelLevel,
    currentFuelType: views.currentFuelType,
    currentEnergyType: views.currentEnergyType,
    selectedTankIndex: state.selectedTankIndex,
    nozzleMode: views.nozzleMode,
    canRefuel: views.canRefuel,
    overallPrice: state.overallPrice,
    flowRate: state.flowRate,
    isFuelling: views.isFuelling,
    isCurrentTankFuelling: views.isCurrentTankFuelling,
    isAutoFuelling: state.isAutoFuelling,
    energyTypes: state.energyTypes,
    hasMultipleTanks: views.hasMultipleTanks,
    tankOptions: views.tankOptions,
    canPay: state.canPay,
    canStartFuelling: views.canStartFuelling,
    canStopFuelling: views.canStopFuelling,
    fuelDiscountData: state.fuelDiscountData,
    showFuelTypeSettings: state.showFuelTypeSettings,
    showAmountSettings: state.showAmountSettings,
    gasStationName: state.gasStationName,
    startFuelling: actions.startFuelling,
    stopFuelling: actions.stopFuelling,
    changeFlowRate: actions.changeFlowRate,
    payPrice: actions.payPrice,
    requestFuelingData: actions.requestFuelingData,
    cancelTransaction: actions.cancelTransaction,
    setSelectedTankIndex: actions.setSelectedTankIndex,
    selectPreviousTank: actions.selectPreviousTank,
    selectNextTank: actions.selectNextTank,
    getUnitLabel: units.getUnitLabel,
    convertToPricePerLocalUnit: units.convertToPricePerLocalUnit,
    dispose,

    // Demo or Constant values (TODO: Update)
    minEnergyLabel: views.minEnergyLabel,
    maxEnergyLabel: views.maxEnergyLabel,
    minSlider,
    maxSlider,
    fuelOptions,
  }
})
