// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Map: Lua output/library commands; transport press feedback; artwork sizing and flyout placement;
// playlist and volume inputs; audio-state polling and transport commands; instance lifecycle; directive registration.
import { createSafeApply } from './safeApply.js'
import { luaLiteral } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/luaLiteral.js'
'use strict'

const TRANSPORT_PRESS_MIN_MS = 160

// An absent playlist or output selector is nil in the player API.
const luaStr = value => value == null || value === '' ? 'nil' : luaLiteral(String(value))

function luaBool(b) {
  return b ? 'true' : 'false'
}

// Pushes the emitter or GUI output choice to the Lua player.
function syncOutput(vm) {
  if (!window.bngApi || !window.bngApi.engineLua) return
  const en = (vm.emitterName || '').trim()
  if (en) {
    window.bngApi.engineLua(
      'extensions.overhaul_phone_musicPlayer.uiSetOutput(' + luaStr(en) + ', false, nil)'
    )
  } else {
    window.bngApi.engineLua(
      'extensions.overhaul_phone_musicPlayer.uiSetOutput(nil, ' + luaBool(vm.useGui !== 'false') + ', nil)'
    )
  }
}

function loadPlaylistPath(vm) {
  if (!window.bngApi || !window.bngApi.engineLua) return
  const p = (vm.playlistPath || '').trim()
  if (!p) return
  window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.loadPlaylist(' + luaStr(p) + ')')
}

function loadMusicLibrary(vm) {
  if (!window.bngApi || !window.bngApi.engineLua) return
  const root = ((vm.musicRoot || '/music').trim() || '/music')
  const pref = (vm.activePlaylist || '').trim()
  const lua = 'extensions.overhaul_phone_musicPlayer.loadMusicLibrary(' + luaStr(root) + ', ' + luaStr(pref) + ', true)'
  window.bngApi.engineLua(lua)
}

// Press feedback for the transport icons. The pressed class stays for at least TRANSPORT_PRESS_MIN_MS, so a quick tap
// is still visible.
function createTransportPress($document, $timeout) {
  const transportPress = { el: null, t: 0, pending: null }

  function transportRelease() {
    $document.off('mouseup', transportRelease)
    $document.off('touchend', transportRelease)
    if (!transportPress.el) {
      return
    }
    const el = transportPress.el
    const t0 = transportPress.t
    transportPress.el = null
    if (transportPress.pending) {
      $timeout.cancel(transportPress.pending)
      transportPress.pending = null
    }
    const elapsed = Date.now() - t0
    const delay = elapsed < TRANSPORT_PRESS_MIN_MS ? TRANSPORT_PRESS_MIN_MS - elapsed : 0
    transportPress.pending = $timeout(function() {
      el.classList.remove('rls-mp-pressed')
      transportPress.pending = null
    }, delay, false)
  }

  function transportAbort() {
    $document.off('mouseup', transportRelease)
    $document.off('touchend', transportRelease)
    if (transportPress.pending) {
      $timeout.cancel(transportPress.pending)
      transportPress.pending = null
    }
    if (transportPress.el) {
      transportPress.el.classList.remove('rls-mp-pressed')
      transportPress.el = null
    }
  }

  function findIconFromEvent(ev) {
    var t = ev.target
    if (!t) return null
    if (t.classList && t.classList.contains('rls-mp-icon')) return t
    if (t.closest) return t.closest('.rls-mp-icon')
    while (t && t !== ev.currentTarget) {
      if (t.classList && t.classList.contains('rls-mp-icon')) return t
      t = t.parentNode
    }
    return null
  }

  function transportPointerDown(ev) {
    if (ev.type === 'mousedown' && ev.button !== 0) {
      return
    }
    var btn = findIconFromEvent(ev)
    if (!btn || (btn.classList && btn.classList.contains('rls-mp-ico-volume'))) {
      return
    }
    transportAbort()
    transportPress.el = btn
    transportPress.t = Date.now()
    btn.classList.add('rls-mp-pressed')
    $document.on('mouseup', transportRelease)
    $document.on('touchend', transportRelease)
  }

  return { transportPointerDown, transportAbort }
}

// Sizes the art square to the height of the main column, on resize and whenever the column is observed to change.
function createArtSizing($element, $timeout) {
  let lastHeight = null
  let pending = null
  function syncArtSize() {
    const root = $element[0].querySelector('.rls-mp')
    const art = $element[0].querySelector('.rls-mp-art')
    const col = $element[0].querySelector('.rls-mp-main-col')
    if (!root || !art || !col) return
    const h = Math.max(0, Math.round(col.getBoundingClientRect().height || col.offsetHeight || 0))
    if (h === lastHeight) return
    lastHeight = h
    if (h > 0) {
      root.style.setProperty('--rls-mp-art-size', h + 'px')
    } else {
      root.style.removeProperty('--rls-mp-art-size')
    }
  }

  function scheduleArtSizeSync() {
    if (pending != null) return
    pending = $timeout(function() {
      pending = null
      syncArtSize()
    }, 0, false)
  }

  function dispose() {
    if (pending != null) $timeout.cancel(pending)
    pending = null
  }

  return { syncArtSize, scheduleArtSizeSync, dispose }
}

// Finds the playlist and volume flyouts in the directive, moves them between their host and the body, and places them
// next to their triggers.
function createFlyoutLookup($element) {
  let flyoutEl = null
  let volumeFlyoutEl = null

  function flyout() {
    if (flyoutEl && flyoutEl.parentNode) {
      return flyoutEl
    }
    flyoutEl = $element[0].querySelector('.rls-mp-dropdown-flyout')
    return flyoutEl
  }

  function volumeFlyout() {
    if (volumeFlyoutEl && volumeFlyoutEl.parentNode) {
      return volumeFlyoutEl
    }
    volumeFlyoutEl = $element[0].querySelector('.rls-mp-volume-flyout')
    return volumeFlyoutEl
  }

  function hostEl() {
    return $element[0].querySelector('.rls-mp-host')
  }

  function restoreFlyoutToHost() {
    const fly = flyout()
    const host = hostEl()
    if (fly && host && fly.parentNode !== host) {
      host.appendChild(fly)
    }
  }

  function restoreVolumeFlyoutToHost() {
    const fly = volumeFlyout()
    const host = hostEl()
    if (fly && host && fly.parentNode !== host) {
      host.appendChild(fly)
    }
  }

  function placeFlyout() {
    const fly = flyout()
    const trig = $element[0].querySelector('.rls-mp-pl-trigger')
    if (!fly || !trig) return
    const r = trig.getBoundingClientRect()
    const gap = 4
    fly.style.position = 'fixed'
    fly.style.zIndex = '999999'
    fly.style.top = (r.bottom + gap) + 'px'
    fly.style.left = r.left + 'px'
    fly.style.minWidth = Math.max(r.width, 10) + 'px'
    const maxW = Math.max(160, window.innerWidth - r.left - 8)
    fly.style.maxWidth = maxW + 'px'
    const below = window.innerHeight - r.bottom - gap
    if (below < 100 && r.top > 120) {
      fly.style.top = (r.top - gap - Math.min(240, fly.offsetHeight || 180)) + 'px'
    }
  }

  function placeVolumeFlyout() {
    const fly = volumeFlyout()
    const trig = $element[0].querySelector('.rls-mp-ico-volume')
    if (!fly || !trig) return
    const r = trig.getBoundingClientRect()
    const well = fly.querySelector('.rls-mp-volume-flyout-icon-well')
    const panel = fly.querySelector('.rls-mp-volume-flyout-panel')
    const iconH = Math.max(28, Math.ceil(r.height))
    const iconW = Math.max(28, Math.ceil(r.width))
    if (well) {
      well.style.minHeight = iconH + 'px'
    }
    if (panel) {
      panel.style.minWidth = Math.max(34, iconW + 2) + 'px'
    }
    fly.style.position = 'fixed'
    fly.style.zIndex = '2147483646'
    fly.style.visibility = 'hidden'
    fly.style.top = '0px'
    fly.style.left = '0px'
    void fly.offsetHeight
    const flyW = fly.offsetWidth || 54
    const flyH = fly.offsetHeight || 96
    let top = r.bottom - flyH
    let left = r.left + (r.width * 0.5) - (flyW * 0.5)
    top = Math.max(8, Math.min(top, window.innerHeight - flyH - 8))
    left = Math.max(8, Math.min(left, window.innerWidth - flyW - 8))
    fly.style.visibility = ''
    fly.style.left = left + 'px'
    fly.style.top = top + 'px'
    void fly.offsetHeight
    const br = fly.getBoundingClientRect()
    const adj = r.bottom - br.bottom
    if (Math.abs(adj) > 0.5) {
      fly.style.top = (top + adj) + 'px'
    }
  }

  return {
    flyout,
    volumeFlyout,
    restoreFlyoutToHost,
    restoreVolumeFlyoutToHost,
    placeFlyout,
    placeVolumeFlyout
  }
}

// Open state of the playlist menu and the volume panel. Only one is open at a time; an open playlist menu listens for
// document clicks so that a click elsewhere closes it.
function createPanelMenus(vm, $scope, $element, $document, $timeout, flyouts) {
  const safeApply = createSafeApply($scope)
  let docClickBound = false

  function teardownDocClick() {
    if (docClickBound) {
      $document.off('click', onDocumentClick)
      docClickBound = false
    }
  }

  function onDocumentClick() {
    safeApply(function() {
      vm.playlistMenuOpen = false
      vm.volumePanelOpen = false
      teardownDocClick()
      flyouts.restoreFlyoutToHost()
      flyouts.restoreVolumeFlyoutToHost()
    })
  }

  function hideVolumePanel() {
    vm.volumePanelOpen = false
    flyouts.restoreVolumeFlyoutToHost()
  }

  function showVolumePanel() {
    if (vm.volumePanelOpen) {
      $timeout(flyouts.placeVolumeFlyout, 0, false)
      return
    }
    if (vm.playlistMenuOpen) {
      vm.playlistMenuOpen = false
      teardownDocClick()
      flyouts.restoreFlyoutToHost()
    }
    vm.volumePanelOpen = true
    $timeout(function() {
      const fly = flyouts.volumeFlyout()
      const trig = $element[0].querySelector('.rls-mp-ico-volume')
      if (!fly || !trig) {
        safeApply(function() { vm.volumePanelOpen = false })
        return
      }
      document.body.appendChild(fly)
      flyouts.placeVolumeFlyout()
      $timeout(flyouts.placeVolumeFlyout, 0, false)
    }, 0, false)
  }

  function togglePlaylistMenu(ev) {
    if (ev) ev.stopPropagation()
    if (vm.playlistMenuOpen) {
      vm.playlistMenuOpen = false
      teardownDocClick()
      flyouts.restoreFlyoutToHost()
      return
    }
    vm.volumePanelOpen = false
    flyouts.restoreVolumeFlyoutToHost()
    $timeout(function() {
      const fly = flyouts.flyout()
      const trig = $element[0].querySelector('.rls-mp-pl-trigger')
      if (!fly || !trig) return
      document.body.appendChild(fly)
      flyouts.placeFlyout()
      safeApply(function() { vm.playlistMenuOpen = true })
      $timeout(flyouts.placeFlyout, 0, false)
      $timeout(function() {
        teardownDocClick()
        $document.on('click', onDocumentClick)
        docClickBound = true
      }, 0, false)
    }, 0, false)
  }

  function pickPlaylist(name, ev) {
    if (ev) ev.stopPropagation()
    if (!name) return
    vm.playlistModel = name
    vm.onPlaylistModelChange()
    vm.playlistMenuOpen = false
    teardownDocClick()
    flyouts.restoreFlyoutToHost()
  }

  return { teardownDocClick, hideVolumePanel, showVolumePanel, togglePlaylistMenu, pickPlaylist }
}

// Hover bindings for the volume icon and its flyout, and the pointer bindings on the volume slider.
function createVolumeInputs(vm, $scope, $element, flyouts, menus) {
  const safeApply = createSafeApply($scope)
  let volumeHoverBound = null
  let volumeSliderRoot = null

  function onVolumeSliderMouseDown(ev) {
    if (ev.button !== 0) {
      return
    }
    ev.preventDefault()
    vm.volumeSliderPointerDown(ev)
  }

  function onVolumeSliderTouchStart(ev) {
    ev.preventDefault()
    vm.volumeSliderPointerDown(ev)
  }

  function bindVolumeSliderInteractions() {
    const el = $element[0].querySelector('.rls-mp-vslider')
    if (!el) {
      return
    }
    if (volumeSliderRoot && volumeSliderRoot !== el) {
      volumeSliderRoot.removeEventListener('mousedown', onVolumeSliderMouseDown)
      volumeSliderRoot.removeEventListener('touchstart', onVolumeSliderTouchStart)
    }
    if (!el._rlsVsPtrBound) {
      el.addEventListener('mousedown', onVolumeSliderMouseDown)
      el.addEventListener('touchstart', onVolumeSliderTouchStart, { passive: false })
      el._rlsVsPtrBound = true
    }
    volumeSliderRoot = el
  }

  function unbindVolumeSliderInteractions() {
    if (!volumeSliderRoot) {
      return
    }
    volumeSliderRoot.removeEventListener('mousedown', onVolumeSliderMouseDown)
    volumeSliderRoot.removeEventListener('touchstart', onVolumeSliderTouchStart)
    delete volumeSliderRoot._rlsVsPtrBound
    volumeSliderRoot = null
  }

  // The icon and an open flyout (with a small margin) both count as inside, so the panel stays open while the pointer
  // crosses the gap between them.
  function volumeHotZoneHit(clientX, clientY) {
    const flyPad = 12
    const iconPad = 2
    function hit(r, pad) {
      if (!r || (r.width <= 0 && r.height <= 0)) {
        return false
      }
      return clientX >= r.left - pad && clientX <= r.right + pad &&
        clientY >= r.top - pad && clientY <= r.bottom + pad
    }
    const ico = $element[0].querySelector('.rls-mp-ico-volume')
    const fly = flyouts.volumeFlyout()
    if (ico && hit(ico.getBoundingClientRect(), iconPad)) {
      return true
    }
    if (vm.volumePanelOpen && fly && hit(fly.getBoundingClientRect(), flyPad)) {
      return true
    }
    return false
  }

  function bindVolumeHover() {
    unbindVolumeHover()
    const ico = $element[0].querySelector('.rls-mp-ico-volume')
    const fly = $element[0].querySelector('.rls-mp-volume-flyout')

    function onIconEnter() {
      safeApply(menus.showVolumePanel)
    }
    function onFlyEnter() {
      safeApply(menus.showVolumePanel)
    }
    function onVolumeIconClick(ev) {
      ev.preventDefault()
      ev.stopPropagation()
    }
    function onVolumeIconMouseDown(ev) {
      if (ev.type === 'mousedown' && ev.button !== 0) {
        return
      }
      ev.preventDefault()
    }
    function onDocVolumeMove(ev) {
      if (!vm.volumePanelOpen) {
        return
      }
      if (volumeHotZoneHit(ev.clientX, ev.clientY)) {
        return
      }
      safeApply(menus.hideVolumePanel)
    }

    if (ico) {
      ico.addEventListener('mouseenter', onIconEnter)
      ico.addEventListener('mousedown', onVolumeIconMouseDown)
      ico.addEventListener('click', onVolumeIconClick)
    }
    if (fly) {
      fly.addEventListener('mouseenter', onFlyEnter)
    }
    document.addEventListener('mousemove', onDocVolumeMove, true)
    volumeHoverBound = {
      ico: ico,
      fly: fly,
      onIconEnter: onIconEnter,
      onFlyEnter: onFlyEnter,
      onVolumeIconClick: onVolumeIconClick,
      onVolumeIconMouseDown: onVolumeIconMouseDown,
      onDocVolumeMove: onDocVolumeMove
    }
  }

  function unbindVolumeHover() {
    if (!volumeHoverBound) {
      return
    }
    const b = volumeHoverBound
    volumeHoverBound = null
    document.removeEventListener('mousemove', b.onDocVolumeMove, true)
    if (b.ico) {
      b.ico.removeEventListener('mouseenter', b.onIconEnter)
      b.ico.removeEventListener('mousedown', b.onVolumeIconMouseDown)
      b.ico.removeEventListener('click', b.onVolumeIconClick)
    }
    if (b.fly) {
      b.fly.removeEventListener('mouseenter', b.onFlyEnter)
    }
  }

  return { bindVolumeHover, unbindVolumeHover, bindVolumeSliderInteractions, unbindVolumeSliderInteractions }
}

// Dragging on the volume slider (mouse or touch) and the arrow, Home and End keys.
function createVolumeDrag(vm, $scope) {
  const safeApply = createSafeApply($scope)
  function volumeSliderClientY(ev) {
    if (ev.touches && ev.touches.length) {
      return ev.touches[0].clientY
    }
    if (ev.changedTouches && ev.changedTouches.length) {
      return ev.changedTouches[0].clientY
    }
    return ev.clientY
  }

  function volumeSliderPointerDown(ev) {
    if (ev.type === 'mousedown' && ev.button !== 0) {
      return
    }
    let root = ev.currentTarget
    if (!root || !root.querySelector) {
      const t = ev.target
      if (t && t.closest) {
        root = t.closest('.rls-mp-vslider')
      }
    }
    if (!root || !root.querySelector) {
      return
    }
    const track = root.querySelector('.rls-mp-vslider-track')
    if (!track) {
      return
    }
    if (ev.preventDefault) {
      ev.preventDefault()
    }

    const win = window
    function updateFromEvent(e) {
      if (e.type === 'touchmove' && e.cancelable) {
        e.preventDefault()
      }
      const tr = track.getBoundingClientRect()
      const h = tr.height
      if (h <= 0) {
        return
      }
      const y = volumeSliderClientY(e)
      const t = (tr.bottom - y) / h
      const p = Math.max(0, Math.min(100, Math.round(t * 100)))
      if (p === vm.volumePercent) return
      safeApply(function() {
        vm.volumePercent = p
        vm.applyVolumePercent()
      })
    }

    updateFromEvent(ev)

    function move(e) {
      updateFromEvent(e)
    }
    function up() {
      win.removeEventListener('mousemove', move, true)
      win.removeEventListener('mouseup', up, true)
      win.removeEventListener('touchmove', move, true)
      win.removeEventListener('touchend', up, true)
      win.removeEventListener('touchcancel', up, true)
    }
    win.addEventListener('mousemove', move, true)
    win.addEventListener('mouseup', up, true)
    win.addEventListener('touchmove', move, { capture: true, passive: false })
    win.addEventListener('touchend', up, true)
    win.addEventListener('touchcancel', up, true)
  }

  function volumeSliderKeyDown(ev) {
    const k = ev.key
    if (k === 'Home') {
      ev.preventDefault()
      vm.volumePercent = 0
      vm.applyVolumePercent()
      return
    }
    if (k === 'End') {
      ev.preventDefault()
      vm.volumePercent = 100
      vm.applyVolumePercent()
      return
    }
    let d = 0
    if (k === 'ArrowUp' || k === 'ArrowRight') {
      d = 5
    } else if (k === 'ArrowDown' || k === 'ArrowLeft') {
      d = -5
    }
    if (!d) {
      return
    }
    ev.preventDefault()
    const cur = Number(vm.volumePercent)
    const next = Math.max(0, Math.min(100, Math.round((Number.isNaN(cur) ? 100 : cur) + d)))
    vm.volumePercent = next
    vm.applyVolumePercent()
  }

  return { volumeSliderPointerDown, volumeSliderKeyDown }
}

// Reads the Lua player state into the controller on each poll, and starts playback once when the player has music and
// startPlaying allows it.
function createAudioSync(vm, $scope) {
  let tracksVersion = null
  let startupPlaybackSynced = false

  function playlistNamesSig(names) {
    if (!names || !names.length) return ''
    return names.join('\u0000')
  }

  function maybeApplyStartupPlayback(result) {
    if (startupPlaybackSynced) return
    if (vm.startPlaying == null || vm.startPlaying === '') return
    const hasMusic = (Number(result.count) || 0) > 0 || ((result.playlistNames || []).length > 0)
    if (!hasMusic) return
    startupPlaybackSynced = true
    if (vm.startPlaying !== 'false' && !result.isPlaying) {
      vm.play()
    }
  }

  function refresh() {
    if ($scope.$$destroyed || !window.bngApi || !window.bngApi.engineLua) return
    const known = tracksVersion == null ? '' : String(Number(tracksVersion) || 0)
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.getUiState(' + known + ')', function(result) {
      if ($scope.$$destroyed || !result || typeof result !== 'object') return
      let changed = false
      function update(target, key, value) {
        if (target[key] === value) return
        target[key] = value
        changed = true
      }
      const nextNames = result.playlistNames || []
      if (playlistNamesSig(vm.state.playlistNames) !== playlistNamesSig(nextNames)) {
        update(vm.state, 'playlistNames', nextNames.slice())
      }
      if (result.tracks && typeof result.tracks === 'object') {
        // Lua serializes an empty table as {}; omitted tracks retain the known library.
        const nextTracks = Array.isArray(result.tracks) ? result.tracks : []
        if (JSON.stringify(vm.state.tracks) !== JSON.stringify(nextTracks)) {
          update(vm.state, 'tracks', nextTracks)
        }
        tracksVersion = result.tracksVersion != null ? result.tracksVersion : null
      }
      for (const key of ['index', 'count', 'isPlaying', 'positionSec', 'durationSec',
        'currentTitle', 'currentCover', 'activePlaylist']) {
        update(vm.state, key, result[key])
      }
      update(vm.state, 'shuffle', !!result.shuffle)
      update(vm.state, 'repeatMode', result.repeatMode || 'all')
      if (result.activePlaylist) update(vm, 'playlistModel', result.activePlaylist)
      if (!vm.volumePanelOpen && result.musicVolume != null) {
        update(vm, 'volumePercent', Math.max(0, Math.min(100, Math.round(Number(result.musicVolume) * 100))))
      }
      maybeApplyStartupPlayback(result)
      if (changed && !$scope.$$phase) $scope.$digest()
    })
  }

  return { refresh }
}

// Transport and playlist commands. Each sends one Lua call and then refreshes the state shortly after.
function createTransportCommands(vm, refresh) {
  function fmt(sec) {
    const n = Math.max(0, Math.floor(Number(sec) || 0))
    const m = Math.floor(n / 60)
    const s = n % 60
    return m + ':' + (s < 10 ? '0' : '') + s
  }

  function pct() {
    const d = Number(vm.state.durationSec) || 0
    if (d <= 0) return 0
    return Math.min(100, 100 * (Number(vm.state.positionSec) || 0) / d)
  }

  function play() {
    if (!window.bngApi || !window.bngApi.engineLua) return
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.uiPlay()')
    window.setTimeout(refresh, 40)
  }

  function stop() {
    if (!window.bngApi || !window.bngApi.engineLua) return
    window.bngApi.engineLua('if overhaul_phone_musicPlayer then overhaul_phone_musicPlayer.uiStop() end')
    refresh()
  }

  function togglePlayStop() {
    if (vm.state.isPlaying) {
      vm.stop()
    } else {
      vm.play()
    }
  }

  function next() {
    if (!window.bngApi || !window.bngApi.engineLua) return
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.uiNext()')
    window.setTimeout(refresh, 40)
  }

  function prev() {
    if (!window.bngApi || !window.bngApi.engineLua) return
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.uiPrevious()')
    window.setTimeout(refresh, 40)
  }

  function toggleShuffle() {
    if (!window.bngApi || !window.bngApi.engineLua) return
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.uiToggleShuffle()')
    window.setTimeout(refresh, 40)
  }

  function toggleRepeat() {
    if (!window.bngApi || !window.bngApi.engineLua) return
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.uiToggleRepeat()')
    window.setTimeout(refresh, 40)
  }

  function selectPlaylist(name) {
    if (!window.bngApi || !window.bngApi.engineLua) return
    if (!name) return
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.setActivePlaylist(' + luaStr(name) + ')')
    window.setTimeout(refresh, 40)
  }

  function onPlaylistModelChange() {
    const name = vm.playlistModel
    if (!name) return
    if (name === vm.state.activePlaylist) return
    vm.selectPlaylist(name)
  }

  function applyVolumePercent() {
    let p = Number(vm.volumePercent)
    if (Number.isNaN(p)) p = 100
    p = Math.max(0, Math.min(100, Math.round(p)))
    vm.volumePercent = p
    if (!window.bngApi || !window.bngApi.engineLua) return
    window.bngApi.engineLua('extensions.overhaul_phone_musicPlayer.uiSetVolume(' + (p / 100) + ')')
  }

  return {
    fmt,
    pct,
    play,
    stop,
    togglePlayStop,
    next,
    prev,
    toggleShuffle,
    toggleRepeat,
    selectPlaylist,
    onPlaylistModelChange,
    applyVolumePercent
  }
}

function rlsMusicPlayerController($scope, $element, $document, $timeout, $interval) {
  const vm = this
  vm.playlistModel = ''
  vm.playlistMenuOpen = false
  vm.volumePanelOpen = false
  vm.volumePercent = 100
  let transportRow = null
  let artResizeObserver = null
  let pollHandle = null

  const transportPress = createTransportPress($document, $timeout)
  const artSize = createArtSizing($element, $timeout)
  const flyouts = createFlyoutLookup($element)
  const menus = createPanelMenus(vm, $scope, $element, $document, $timeout, flyouts)
  const volumeInputs = createVolumeInputs(vm, $scope, $element, flyouts, menus)
  const volumeDrag = createVolumeDrag(vm, $scope)
  const audio = createAudioSync(vm, $scope)
  const transport = createTransportCommands(vm, audio.refresh)

  // Public members are anonymous functions, as in the original module. Each one forwards to its helper, and calls
  // between members still go through vm.
  vm.togglePlaylistMenu = function(ev) {
    menus.togglePlaylistMenu(ev)
  }
  vm.pickPlaylist = function(name, ev) {
    menus.pickPlaylist(name, ev)
  }
  vm.state = {
    tracks: [],
    index: 1,
    count: 0,
    isPlaying: false,
    positionSec: 0,
    durationSec: 0,
    currentTitle: '',
    currentCover: '',
    playlistNames: [],
    activePlaylist: '',
    shuffle: false,
    repeatMode: 'all'
  }
  vm.onPlaylistModelChange = function() {
    transport.onPlaylistModelChange()
  }
  vm.fmt = function(sec) {
    return transport.fmt(sec)
  }
  vm.pct = function() {
    return transport.pct()
  }
  vm.play = function() {
    transport.play()
  }
  vm.stop = function() {
    transport.stop()
  }
  vm.togglePlayStop = function() {
    transport.togglePlayStop()
  }
  vm.next = function() {
    transport.next()
  }
  vm.prev = function() {
    transport.prev()
  }
  vm.toggleShuffle = function() {
    transport.toggleShuffle()
  }
  vm.toggleRepeat = function() {
    transport.toggleRepeat()
  }
  vm.volumeSliderPointerDown = function(ev) {
    volumeDrag.volumeSliderPointerDown(ev)
  }
  vm.volumeSliderKeyDown = function(ev) {
    volumeDrag.volumeSliderKeyDown(ev)
  }
  vm.applyVolumePercent = function() {
    transport.applyVolumePercent()
  }
  vm.selectPlaylist = function(name) {
    transport.selectPlaylist(name)
  }

  // Mount: load the library or playlist, sync the output, start polling, and wire the layout and pointer listeners.
  $scope.$evalAsync(function() {
    if ((vm.playlistPath || '').trim()) {
      loadPlaylistPath(vm)
    } else {
      loadMusicLibrary(vm)
    }
    syncOutput(vm)
    audio.refresh()
    const ms = Math.max(80, parseInt(vm.pollMs, 10) || 320)
    pollHandle = $interval(audio.refresh, ms, 0, false)
    artSize.scheduleArtSizeSync()
    if (window.ResizeObserver) {
      const col = $element[0].querySelector('.rls-mp-main-col')
      if (col) {
        artResizeObserver = new window.ResizeObserver(artSize.scheduleArtSizeSync)
        artResizeObserver.observe(col)
      }
    }
    window.addEventListener('resize', artSize.syncArtSize)
    transportRow = $element[0].querySelector('.rls-mp-row-ctrl')
    if (transportRow) {
      transportRow.addEventListener('mousedown', transportPress.transportPointerDown)
      transportRow.addEventListener('touchstart', transportPress.transportPointerDown, { passive: true })
    }
    volumeInputs.bindVolumeHover()
    volumeInputs.bindVolumeSliderInteractions()
  })

  // Unmount: undo everything the mount wired, in the same order.
  $scope.$on('$destroy', function() {
    vm.playlistMenuOpen = false
    vm.volumePanelOpen = false
    volumeInputs.unbindVolumeHover()
    volumeInputs.unbindVolumeSliderInteractions()
    menus.teardownDocClick()
    flyouts.restoreFlyoutToHost()
    flyouts.restoreVolumeFlyoutToHost()
    transportPress.transportAbort()
    if (transportRow) {
      transportRow.removeEventListener('mousedown', transportPress.transportPointerDown)
      transportRow.removeEventListener('touchstart', transportPress.transportPointerDown)
      transportRow = null
    }
    artSize.dispose()
    window.removeEventListener('resize', artSize.syncArtSize)
    if (artResizeObserver) {
      artResizeObserver.disconnect()
      artResizeObserver = null
    }
    if (pollHandle) {
      $interval.cancel(pollHandle)
      pollHandle = null
    }
  })
}

let rlsMusicPlayerModule
try {
  rlsMusicPlayerModule = angular.module('rlsMusicPlayer')
} catch (e) {
  rlsMusicPlayerModule = angular.module('rlsMusicPlayer', [])
}

rlsMusicPlayerModule.directive('rlsMusicPlayer', ['$interval', function($interval) {
  return {
    restrict: 'E',
    scope: {
      emitterName: '@?',
      musicRoot: '@?',
      playlistPath: '@?',
      activePlaylist: '@?',
      startPlaying: '@?',
      useGui: '@?',
      pollMs: '@?'
    },
    templateUrl: '/ui/modModules/rlsMusicPlayer/rlsMusicPlayer.html',
    controllerAs: 'vm',
    bindToController: true,
    controller: ['$scope', '$element', '$document', '$timeout', function($scope, $element, $document, $timeout) {
      rlsMusicPlayerController.call(this, $scope, $element, $document, $timeout, $interval)
    }]
  }
}])

export default rlsMusicPlayerModule
