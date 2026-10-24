// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Each overlay owns its layout and clamp policy; this service owns only the active pointer drag.
export function createDraggableCard($scope, layout, clampLayout, safeApply, options = {}) {
  let drag = null

  $scope.startDrag = function(e) {
    if (!e || (options.ignoreButtons !== false && e.target.closest('button'))) return
    drag = { startX: e.clientX, startY: e.clientY, origX: layout.x, origY: layout.y }
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'grabbing'
    e.preventDefault()
  }

  function onMouseMove(e) {
    if (!drag) return
    safeApply(function() {
      layout.x = drag.origX + e.clientX - drag.startX
      layout.y = drag.origY + e.clientY - drag.startY
      clampLayout()
    })
  }

  function onMouseUp() {
    if (!drag) return
    dispose()
    if (options.onRelease) options.onRelease()
  }

  // Teardown cancels an unfinished gesture; only a real release saves the new position.
  function dispose() {
    if (!drag) return
    drag = null
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  return { onMouseMove, onMouseUp, dispose }
}
