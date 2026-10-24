// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { DEFAULT_LAYOUT, api } from './presentation.js'

export function createLayout($scope, angularRootScope) {
  const layout = { x: 18, y: 18 }
  $scope.hudLayout = layout
  $scope.panelWidth = panelWidth
  let drag = null
  let blurNotifyFrame = null
  let appliedLayout = null

  function clampLayout(l) {
    const vw = window.innerWidth || 1280
    const vh = window.innerHeight || 720
    const width = panelWidth()
    l.x = Math.max(0, Math.min(l.x, Math.max(0, vw - Math.min(width, vw - 20))))
    l.y = Math.max(0, Math.min(l.y, Math.max(0, vh - 48)))
    return l
  }

  function panelWidth() {
    const vw = window.innerWidth || 1280
    if ($scope.isPulling()) return Math.min(360, vw - 20)
    if ($scope.isComplete()) return Math.min(760, vw - 20)
    return Math.min(420, vw - 20)
  }

  function notifyGameBlur() {
    if (blurNotifyFrame != null) return
    blurNotifyFrame = window.requestAnimationFrame(function() {
      blurNotifyFrame = null
      angularRootScope.$broadcast('windowResize')
    })
  }

  function applyLayout() {
    const root = document.querySelector('.dsh-root')
    if (!root) return
    clampLayout(layout)
    const width = panelWidth()
    const phase = $scope.state && $scope.state.phase
    if (appliedLayout && appliedLayout.x === layout.x && appliedLayout.y === layout.y &&
        appliedLayout.width === width && appliedLayout.phase === phase) return
    appliedLayout = { x: layout.x, y: layout.y, width, phase }
    root.style.left = layout.x + 'px'
    root.style.top = layout.y + 'px'
    const panel = root.querySelector('.dsh-panel')
    if (panel) panel.style.width = width + 'px'
    notifyGameBlur()
  }

  function persistLayout() {
    const luaApi = api()
    if (!luaApi) return
    luaApi.engineLua(
      "extensions.overhaul_shell_settings.setSetting('dynoSessionHudLayout', " +
      "{x = " + Math.round(layout.x) + ", y = " + Math.round(layout.y) + "})"
    )
  }

  function adoptLayout(candidate) {
    candidate = candidate && typeof candidate === 'object' ? candidate : {}
    layout.x = Number.isFinite(candidate.x) ? candidate.x : DEFAULT_LAYOUT.x
    layout.y = Number.isFinite(candidate.y) ? candidate.y : DEFAULT_LAYOUT.y
    clampLayout(layout)
    appliedLayout = null
  }

  function onMouseDown(e) {
    if (!$scope.visible || $scope.isPulling()) return
    const header = e.target.closest('.dsh-header')
    if (header && header.closest('.dsh-root')) {
      drag = {
        startX: e.clientX,
        startY: e.clientY,
        origX: layout.x,
        origY: layout.y
      }
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'grabbing'
      e.preventDefault()
      return
    }
  }

  function onMouseMove(e) {
    if (drag) {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      applyLayout()
    }
  }

  function onMouseUp() {
    if (!drag) return
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
    drag = null
    persistLayout()
  }

  function dispose() {
    if (blurNotifyFrame != null) window.cancelAnimationFrame(blurNotifyFrame)
    blurNotifyFrame = null
    if (drag) {
      drag = null
      document.body.style.userSelect = ''
      document.body.style.cursor = ''
    }
  }

  return { applyLayout, adoptLayout, notifyGameBlur, onMouseDown, onMouseMove, onMouseUp, dispose }
}
