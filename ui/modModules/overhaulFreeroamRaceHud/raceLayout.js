// HUD panel placement: the layout this controller holds, pointer drag and resize, and the game-blur notify that follows
// each visible move. The document listeners are added here and removed by dispose.
function createHudLayout($scope, angularRootScope) {
  var DEFAULT_LAYOUT = { x: 12, y: 12, width: 340 }
  var hudLayout = { x: 12, y: 12, width: 340 }
  $scope.hudLayout = hudLayout
  var drag = null
  var resize = null
  var blurNotifyFrame = null

  function clampLayout(l) {
    var vw = window.innerWidth, vh = window.innerHeight
    l.x = Math.max(0, Math.min(l.x, vw - 100))
    l.y = Math.max(0, Math.min(l.y, vh - 40))
    l.width = Math.max(240, Math.min(560, l.width))
    return l
  }

  function notifyGameBlur() {
    if (blurNotifyFrame != null) return
    blurNotifyFrame = window.requestAnimationFrame(function() {
      blurNotifyFrame = null
      angularRootScope.$broadcast('windowResize')
    })
  }

  function applyLayout() {
    var root = document.querySelector('.frh-overlay-root')
    if (!root) return
    root.style.left = hudLayout.x + 'px'
    root.style.top = hudLayout.y + 'px'
    var panel = root.querySelector('.frh-panel')
    if (panel) panel.style.width = hudLayout.width + 'px'
    notifyGameBlur()
  }

  function persistLayout() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua(
        "extensions.overhaul_shell_settings.setSetting('freeroamRaceHudLayout', " +
        "{x = " + hudLayout.x + ", y = " + hudLayout.y + ", width = " + hudLayout.width + "})"
      )
    }
  }

  function adoptLayout(candidate) {
    candidate = candidate && typeof candidate === 'object' ? candidate : {}
    hudLayout = clampLayout({
      x: Number.isFinite(candidate.x) ? candidate.x : DEFAULT_LAYOUT.x,
      y: Number.isFinite(candidate.y) ? candidate.y : DEFAULT_LAYOUT.y,
      width: Number.isFinite(candidate.width) ? candidate.width : DEFAULT_LAYOUT.width,
    })
    $scope.hudLayout = hudLayout
  }

  function onMouseDown(e) {
    if (!$scope.visible) return
    if (e.target.closest('button')) return
    var header = e.target.closest('.frh-header')
    if (header && header.closest('.frh-overlay-root')) {
      drag = {
        startX: e.clientX, startY: e.clientY,
        origX: hudLayout.x, origY: hudLayout.y
      }
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'grabbing'
      e.preventDefault()
      return
    }
    var handle = e.target.closest('.frh-resize-handle')
    if (handle && handle.closest('.frh-overlay-root')) {
      resize = { startX: e.clientX, origWidth: hudLayout.width }
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'ew-resize'
      e.preventDefault()
    }
  }

  function onMouseMove(e) {
    if (drag) {
      hudLayout.x = Math.max(0, drag.origX + e.clientX - drag.startX)
      hudLayout.y = Math.max(0, drag.origY + e.clientY - drag.startY)
      applyLayout()
    } else if (resize) {
      hudLayout.width = Math.max(240, Math.min(560, resize.origWidth + e.clientX - resize.startX))
      applyLayout()
    }
  }

  function onMouseUp() {
    if (drag || resize) {
      document.body.style.userSelect = ''
      document.body.style.cursor = ''
      drag = null
      resize = null
      persistLayout()
    }
  }

  document.addEventListener('mousedown', onMouseDown, true)
  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  return {
    applyLayout: applyLayout,
    notifyGameBlur: notifyGameBlur,
    adoptLayout: adoptLayout,
    dispose: function() {
      if (blurNotifyFrame != null) window.cancelAnimationFrame(blurNotifyFrame)
      blurNotifyFrame = null
      if (drag || resize) {
        document.body.style.userSelect = ''
        document.body.style.cursor = ''
        drag = null
        resize = null
      }
      document.removeEventListener('mousedown', onMouseDown, true)
      document.removeEventListener('mousemove', onMouseMove, true)
      document.removeEventListener('mouseup', onMouseUp, true)
    },
  }
}

// Race HUD display formatting. Templates call these directly. Each reads only its arguments, plus the time formatters
// already on the scope for the sector helpers.

export { createHudLayout }
