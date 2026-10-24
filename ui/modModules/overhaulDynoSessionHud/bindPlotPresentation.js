// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { graphPointData, unitLabel, toNumber, GRAPH_VIEW } from './presentation.js'

export function bindPlotPresentation($scope, graphModel) {

  function polyline(name) {
    const model = graphModel()
    return model ? model.polylines[name] : ''
  }

  $scope.powerCurvePoints = () => polyline('power')
  $scope.torqueCurvePoints = () => polyline('torque')
  $scope.comparisonPowerCurvePoints = () => polyline('comparisonPower')
  $scope.comparisonTorqueCurvePoints = () => polyline('comparisonTorque')

  $scope.graphPlot = function() {
    const model = graphModel()
    return model ? model.plot : { x: 84, y: 34, w: 600, h: 226 }
  }

  $scope.graphYLabels = function() {
    const model = graphModel()
    if (!model) return []
    if (model.yLabels) return model.yLabels
    const plot = model.plot
    const targetLines = Math.min(8, Math.max(2, Math.ceil(model.maxY / model.yStep)))
    const step = Math.max(model.yStep, Math.ceil((model.maxY / targetLines) / model.yStep) * model.yStep)
    const labels = []
    for (let value = 0; value <= model.maxY; value += step) {
      const y = plot.y + plot.h - (value / model.maxY) * plot.h
      labels.push({ value: value, y: y.toFixed(1), x1: plot.x, x2: plot.x + plot.w })
    }
    if (labels[labels.length - 1].value !== model.maxY) {
      labels.push({ value: model.maxY, y: plot.y.toFixed(1), x1: plot.x, x2: plot.x + plot.w })
    }
    model.yLabels = labels
    return model.yLabels
  }

  $scope.graphXLabels = function() {
    const model = graphModel()
    if (!model) return []
    if (model.xLabels) return model.xLabels
    const plot = model.plot
    const rpmRange = model.maxRpm - model.minRpm
    const step = rpmRange > 7000 ? 2000 : 1000
    const labels = []
    function rpmLabel(value) {
      if (value < 1000) return String(Math.round(value))
      return String(Math.round(value / 100) / 10) + 'k'
    }
    labels.push({ value: model.minRpm, label: rpmLabel(model.minRpm), x: plot.x.toFixed(1), y1: plot.y, y2: plot.y + plot.h })
    const firstTick = Math.ceil(model.minRpm / step) * step
    for (let value = firstTick; value < model.maxRpm; value += step) {
      if (value === model.minRpm) continue
      const x = plot.x + ((value - model.minRpm) / rpmRange) * plot.w
      labels.push({ value: value, label: rpmLabel(value), x: x.toFixed(1), y1: plot.y, y2: plot.y + plot.h })
    }
    if (labels[labels.length - 1].value !== model.maxRpm) {
      labels.push({ value: model.maxRpm, label: rpmLabel(model.maxRpm), x: (plot.x + plot.w).toFixed(1), y1: plot.y, y2: plot.y + plot.h })
    }
    model.xLabels = labels
    return model.xLabels
  }

  $scope.powerUnitLabel = function() {
    return unitLabel('power', 'PS')
  }

  $scope.torqueUnitLabel = function() {
    return unitLabel('torque', 'Nm')
  }

  $scope.onGraphMouseMove = function($event) {
    const model = graphModel()
    if (!model || !model.curve.length) return
    const svg = $event.currentTarget
    const rect = svg.getBoundingClientRect && svg.getBoundingClientRect()
    if (!rect || !rect.width || !rect.height) return
    const point = {
      x: (($event.clientX - rect.left) / rect.width) * GRAPH_VIEW.w,
      y: (($event.clientY - rect.top) / rect.height) * GRAPH_VIEW.h
    }

    const plot = model.plot
    const clampedX = Math.max(plot.x, Math.min(plot.x + plot.w, point.x))
    const targetRpm = model.minRpm + ((clampedX - plot.x) / plot.w) * (model.maxRpm - model.minRpm)
    let closest = model.curve[0]
    let closestDistance = Math.abs(toNumber(closest.rpm) - targetRpm)
    model.curve.forEach(function(candidate) {
      const distance = Math.abs(toNumber(candidate.rpm) - targetRpm)
      if (distance < closestDistance) {
        closest = candidate
        closestDistance = distance
      }
    })

    const data = graphPointData(model, closest)
    const tooltipWidth = 184
    const tooltipX = data.x > plot.x + plot.w - tooltipWidth - 6 ? data.x - tooltipWidth - 8 : data.x + 8
    const clampedTooltipX = Math.max(plot.x + 4, tooltipX)
    const tooltipY = plot.y + 10
    $scope.graphHover = {
      x: data.x.toFixed(1),
      y1: plot.y,
      y2: plot.y + plot.h,
      powerY: data.powerY.toFixed(1),
      torqueY: data.torqueY.toFixed(1),
      tooltipX: clampedTooltipX.toFixed(1),
      tooltipY: tooltipY.toFixed(1),
      tooltipTextX: (clampedTooltipX + 12).toFixed(1),
      tooltipRpmY: (tooltipY + 20).toFixed(1),
      tooltipPowerY: (tooltipY + 45).toFixed(1),
      tooltipTorqueY: (tooltipY + 67).toFixed(1),
      rpm: $scope.formatRpm(data.rpm) + ' RPM',
      power: $scope.formatPower(data.power),
      torque: $scope.formatTorque(data.torque)
    }
  }

  $scope.onGraphMouseLeave = function() {
    $scope.graphHover = null
  }
}
