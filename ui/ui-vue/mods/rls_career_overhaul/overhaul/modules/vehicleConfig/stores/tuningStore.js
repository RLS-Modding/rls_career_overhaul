// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

import { ref } from "vue"
import { defineStore } from "pinia"
import { roundDec, round } from "@/utils/maths"
import { useBridge } from "@/bridge"

// After setConfigVars the vehicle respawns and can fire several VehicleFocusChanged /
// VehicleConfigChange echoes. Suppress those until VehicleChange (spawn finished).
const APPLY_SAFETY_TIMEOUT_MS = 5000
const INBOUND_COALESCE_MS = 50

function countDecimals(num) {
  if (typeof num !== "number" || ~~num === num) return 0
  return num.toString().split(".")[1].length || 0
}

function rawToValDis(varData, raw) {
  const vData = (raw - varData.min) / (varData.max - varData.min)
  return roundDec(round(vData * (varData.maxDis - varData.minDis), varData.stepDis) + varData.minDis, countDecimals(varData.stepDis))
}

function valToValDis(varData, useDef = false) {
  return rawToValDis(varData, useDef ? varData.default : varData.val)
}

function valDisToVal(varData) {
  const vData = (varData.valDis - varData.minDis) / (varData.maxDis - varData.minDis)
  return vData * (varData.max - varData.min) + varData.min
}

// Groups a payload into category > subCategory > vars and sets each var's display state. Reads
// tuningVariablesRef.value only after the payload's variables/defaults are read, as before.
function buildTuningModel(data, tuningVariablesRef) {
  // defaults.vars holds the vars of the loaded .pc, which is the baseline the sliders reset to.
  // Career payloads are a flat variables map without it.
  let loadedVars = null
  if (data.variables) {
    loadedVars = data.defaults?.vars || null
    data = data.variables
  }

  const newBuckets = []
  const newTuningVariables = {}
  const prevVars = tuningVariablesRef.value

  for (const varData of Object.values(data)) {
    if (varData.hideInUI) continue

    if (!varData.category) varData.category = "Other"
    if (!varData.subCategory) varData.subCategory = "Other"

    const cat = (newBuckets.find(cat => cat.name === varData.category) || newBuckets[newBuckets.push({ name: varData.category, items: [] }) - 1]).items
    const list = (cat.find(sub => sub.name === varData.subCategory) || cat[cat.push({ name: varData.subCategory, items: [] }) - 1]).items
    list.push(varData)

    const nextValDis = Number(valToValDis(varData))
    const prev = prevVars?.[varData.name]
    // Keep the local display value when the engine echo rounds back to the same step.
    // Avoids slider thumb/input jumping on apply re-sync.
    const step = Number(varData.stepDis)
    const sameStep = prev
      && Number.isFinite(prev.valDis)
      && Number.isFinite(nextValDis)
      && Number.isFinite(step)
      && step > 0
      && Math.abs(prev.valDis - nextValDis) < step * 0.5

    // A var missing from the loaded config was spawned at its jbeam default, so that is its baseline
    const loadedVal = loadedVars ? Number(loadedVars[varData.name]) : NaN
    const origDis = Number.isFinite(loadedVal) ? Number(rawToValDis(varData, loadedVal)) : Number(valToValDis(varData, true))

    newTuningVariables[varData.name] = {
      valDis: sameStep ? prev.valDis : nextValDis,
      minDis: varData.minDis,
      maxDis: varData.maxDis,
      min: varData.min,
      max: varData.max,
      origDis,
    }
  }

  const sorter = (a, b) => a.name.localeCompare(b.name)
  newBuckets.sort(sorter)
  for (const cat of newBuckets) {
    cat.items.sort(sorter)
    for (const sub of cat.items) sub.items.sort(sorter)
  }

  return { buckets: newBuckets, tuningVariables: newTuningVariables }
}

// Owns the apply-busy state and the echo gate: while an apply respawns the vehicle, focus and config
// echoes are dropped, and VehicleChange (or the safety timer) ends the busy state with one refresh.
function createApplyEchoGate({ api, isBusy, events, processTuningData }) {
  let echoQuiet = false
  let applySafetyTimer = null
  let inboundCoalesceTimer = null
  let pendingInboundData = undefined
  let vehicleChangeBound = false
  let finishingApply = false

  function clearApplySafetyTimer() {
    if (applySafetyTimer) {
      clearTimeout(applySafetyTimer)
      applySafetyTimer = null
    }
  }

  function clearInboundCoalesce() {
    if (inboundCoalesceTimer) {
      clearTimeout(inboundCoalesceTimer)
      inboundCoalesceTimer = null
    }
    pendingInboundData = undefined
  }

  function endApplyBusy() {
    clearApplySafetyTimer()
    echoQuiet = false
    finishingApply = false
    isBusy.value = false
  }

  function finishApplyAndRefresh() {
    if (finishingApply || (!echoQuiet && !isBusy.value)) return
    finishingApply = true
    clearApplySafetyTimer()
    echoQuiet = false
    // One settled refresh after spawn (picks up engine clamps, etc.)
    Promise.resolve(api.request()).finally(() => {
      finishingApply = false
      isBusy.value = false
    })
  }

  function beginApplyBusy() {
    clearApplySafetyTimer()
    finishingApply = false
    echoQuiet = true
    isBusy.value = true
    // Fallback if VehicleChange never arrives (career / failed spawn).
    applySafetyTimer = setTimeout(() => {
      applySafetyTimer = null
      finishApplyAndRefresh()
    }, APPLY_SAFETY_TIMEOUT_MS)
  }

  function onVehicleChange() {
    if (!echoQuiet && !isBusy.value) return
    finishApplyAndRefresh()
  }

  function requestFromFocusChange() {
    if (echoQuiet) return
    api.request()
  }

  function onVehicleConfigChange(data) {
    if (echoQuiet) return
    pendingInboundData = data
    if (inboundCoalesceTimer) return
    inboundCoalesceTimer = setTimeout(() => {
      inboundCoalesceTimer = null
      const payload = pendingInboundData
      pendingInboundData = undefined
      if (payload !== undefined && !echoQuiet) processTuningData(payload)
    }, INBOUND_COALESCE_MS)
  }

  function bindVehicleChange() {
    if (vehicleChangeBound) return
    events.on("VehicleChange", onVehicleChange)
    vehicleChangeBound = true
  }

  function unbindVehicleChange() {
    if (!vehicleChangeBound) return
    events.off("VehicleChange", onVehicleChange)
    vehicleChangeBound = false
  }

  return {
    beginApplyBusy,
    endApplyBusy,
    clearInboundCoalesce,
    bindVehicleChange,
    unbindVehicleChange,
    requestFromFocusChange,
    onVehicleConfigChange,
  }
}

export const useTuningStore = defineStore("overhaulTuning", () => {
  const { lua, events } = useBridge()

  const buckets = ref({})
  const tuningVariables = ref({})
  const isBusy = ref(false)
  let editedTuningVars = {}

  let isCareer = false
  const shoppingData = ref({})

  const noapi = () => {
    throw new Error("Tuning store must be initialised first")
  }
  let api = {
    request: noapi,
    apply: noapi,
    reset: noapi,
    close: () => {},
    menuClose: () => {},
  }

  const processTuningData = data => {
    if (!data) {
      tuningVariables.value = {}
      buckets.value = []
      return
    }
    const model = buildTuningModel(data, tuningVariables)
    tuningVariables.value = model.tuningVariables
    buckets.value = model.buckets
  }

  const {
    beginApplyBusy,
    endApplyBusy,
    clearInboundCoalesce,
    bindVehicleChange,
    unbindVehicleChange,
    requestFromFocusChange,
    onVehicleConfigChange,
  } = createApplyEchoGate({ api, isBusy, events, processTuningData })

  async function init() {
    editedTuningVars = {}
    isCareer = await lua.overhaul_career_career.isActive()
    bindVehicleChange()
    if (isCareer) {
      api.request = async () => processTuningData(await lua.overhaul_career_parts_tuning.getTuningData())
      api.apply = (values, edited) => {
        const res = {}
        for (const [varName] of Object.entries(edited)) {
          if (values[varName]) res[varName] = valDisToVal(values[varName])
        }
        lua.overhaul_career_parts_tuning.apply(res)
      }
      api.reset = () => {}
      api.close = () => {
        endApplyBusy()
        clearInboundCoalesce()
        unbindVehicleChange()
        events.off("sendTuningShoppingData", setShoppingData)
        events.off("updateTuningVariable", updateTuningVariable)
        shoppingData.value = {}
      }

      events.on("sendTuningShoppingData", setShoppingData)
      events.on("updateTuningVariable", updateTuningVariable)
    } else {
      api.request = async () => await lua.extensions.core_vehicle_partmgmt.sendDataToUI()
      api.apply = (values, edited) => {
        const res = {}
        for (const varName in values) res[varName] = valDisToVal(values[varName])
        lua.extensions.core_vehicle_partmgmt.setConfigVars(res)
      }
      api.reset = async () => await lua.extensions.core_vehicle_partmgmt.resetVarsToLoadedConfig()
      api.close = () => {
        endApplyBusy()
        clearInboundCoalesce()
        unbindVehicleChange()
        events.off("VehicleFocusChanged", requestFromFocusChange)
        events.off("VehicleConfigChange", onVehicleConfigChange)
      }
      api.menuClose = api.close
      events.on("VehicleFocusChanged", requestFromFocusChange)
      events.on("VehicleConfigChange", onVehicleConfigChange)
    }
    for (const name in api) {
      if (api[name] === noapi) api[name] = () => {}
    }
  }

  function apply() {
    beginApplyBusy()
    api.apply(tuningVariables.value, editedTuningVars)
    editedTuningVars = {}
  }

  function setShoppingData(data) {
    shoppingData.value = data
  }

  function updateTuningVariable(tuningVar) {
    if (tuningVariables.value[tuningVar.name]) {
      tuningVariables.value[tuningVar.name].valDis = Number(valToValDis(tuningVar))
    }
  }

  function tuningVarChanged(varName) {
    editedTuningVars[varName] = true
  }

  async function refreshFromBackend() {
    editedTuningVars = {}
    await api.request()
  }

  return {
    init,
    buckets,
    tuningVariables,
    shoppingData,
    isBusy,
    apply,
    requestInitialData: () => api.request(),
    refreshFromBackend,
    close: () => api.close(),
    notifyOnMenuClosed: () => api.menuClose(),
    tuningVarChanged,
    resetTuningData: () => api.reset(),
  }
})
