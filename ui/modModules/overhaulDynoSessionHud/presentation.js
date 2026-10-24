// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { reportFailure } from '../../modules/overhaulAngular/reportFailure.js'
const DEFAULT_LAYOUT = { x: 18, y: 18 }
const GRAPH_VIEW = { w: 720, h: 320 }
const HOW_TO_STORAGE_KEY = 'rlsDynoHowToDismissedV1'
const pollMs = 2000

const flagLabels = {
  gearChanged: 'Gear Change',
  neutralGear: 'Neutral/Reverse',
  throttleLift: 'Throttle Lift',
  brakeInput: 'Brake Input',
  noRpmClimb: 'No RPM Climb',
  noUsablePower: 'No Usable Power',
  insufficientData: 'Insufficient Clean Data',
  timeout: 'Timeout',
  unstableRpm: 'Unstable RPM',
  powerSpike: 'Power Spike',
  torqueSpike: 'Torque Spike',
  sustainedTorqueRoughness: 'Sustained Torque Fluctuation',
  dynoSweepUnregulated: 'Dyno Could Not Hold Sweep Rate',
  pullInterrupted: 'Pull Interrupted',
  throttleBelowTarget: 'Throttle Below 90%',
  waitingForStableGear: 'Waiting For Gear',
  waitingForThrottle: 'Waiting For Throttle'
}

function api() {
  if (typeof bngApi !== 'undefined' && bngApi && bngApi.engineLua) return bngApi
  if (window.bngApi && window.bngApi.engineLua) return window.bngApi
  return null
}

function toNumber(value) {
  const number = Number(value)
  return isFinite(number) ? number : 0
}

function unitString(kind, value, fallbackUnit, converter) {
  const number = toNumber(value)
  const units = window.bridge && window.bridge.units
  if (units && typeof units.buildString === 'function') {
    try {
      return units.buildString(kind, number, 0)
    } catch (err) { reportFailure(err, 'Format dyno units') }
  }
  const converted = converter ? converter(number) : number
  return Math.max(0, Math.round(converted)).toLocaleString() + ' ' + fallbackUnit
}

function displayPowerValue(value) {
  const number = toNumber(value)
  const units = window.bridge && window.bridge.units
  if (units && typeof units.power === 'function') {
    try {
      const helper = units.power(number)
      if (helper && typeof helper.val === 'number') return helper.val
    } catch (err) { reportFailure(err, 'Convert dyno power') }
  }
  return number
}

function displayTorqueValue(value) {
  const number = toNumber(value)
  const units = window.bridge && window.bridge.units
  if (units && typeof units.torque === 'function') {
    try {
      const helper = units.torque(number)
      if (helper && typeof helper.val === 'number') return helper.val
    } catch (err) { reportFailure(err, 'Convert dyno torque') }
  }
  return number
}

function unitLabel(kind, fallback) {
  const units = window.bridge && window.bridge.units
  if (units && typeof units[kind] === 'function') {
    try {
      const helper = units[kind](1)
      if (helper && helper.unit) return helper.unit
    } catch (err) { reportFailure(err, 'Read dyno unit label') }
  }
  return fallback
}

function normalizeFlags(flags) {
  const result = []
  if (!flags || typeof flags !== 'object') return result
  Object.keys(flags).forEach(function(key) {
    if (!flags[key]) return
    result.push(flagLabels[key] || key)
  })
  return result
}

function graphPoint(model, rpm, value) {
  const plot = model.plot
  const rpmRange = Math.max(1, model.maxRpm - model.minRpm)
  const x = plot.x + ((Math.max(model.minRpm, toNumber(rpm)) - model.minRpm) / rpmRange) * plot.w
  const y = plot.y + plot.h - (Math.max(0, toNumber(value)) / model.maxY) * plot.h
  return x.toFixed(1) + ',' + y.toFixed(1)
}

function graphPointData(model, point) {
  const power = Math.max(0, displayPowerValue(point.power))
  const torque = Math.max(0, displayTorqueValue(point.torque))
  const plot = model.plot
  const rpmRange = Math.max(1, model.maxRpm - model.minRpm)
  const x = plot.x + ((Math.max(model.minRpm, toNumber(point.rpm)) - model.minRpm) / rpmRange) * plot.w
  const powerY = plot.y + plot.h - (power / model.maxY) * plot.h
  const torqueY = plot.y + plot.h - (torque / model.maxY) * plot.h
  return {
    x: x,
    powerY: powerY,
    torqueY: torqueY,
    rpm: toNumber(point.rpm),
    power: point.power,
    torque: point.torque
  }
}


export { DEFAULT_LAYOUT, GRAPH_VIEW, HOW_TO_STORAGE_KEY, pollMs, api, toNumber, unitString, displayPowerValue, displayTorqueValue, unitLabel, normalizeFlags, graphPoint, graphPointData }
