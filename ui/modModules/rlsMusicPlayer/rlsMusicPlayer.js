'use strict'

function luaStr(s) {
  if (s == null || s === '') return 'nil'
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'
}

function luaBool(b) {
  return b ? 'true' : 'false'
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
      const vm = this
      vm.playlistModel = ''
      vm.playlistMenuOpen = false
      vm.volumePanelOpen = false
      vm.volumePercent = 100
      let flyoutEl = null
      let volumeFlyoutEl = null
      let docClickBound = false
      let artResizeObserver = null
      let transportRow = null
      let startupPlaybackSynced = false
      const transportPress = { el: null, t: 0, pending: null }
      const TRANSPORT_PRESS_MIN_MS = 160

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
        }, delay)
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

      function syncArtSize() {
        const root = $element[0].querySelector('.rls-mp')
        const art = $element[0].querySelector('.rls-mp-art')
        const col = $element[0].querySelector('.rls-mp-main-col')
        if (!root || !art || !col) return
        const h = Math.max(0, Math.round(col.getBoundingClientRect().height || col.offsetHeight || 0))
        if (h > 0) {
          root.style.setProperty('--rls-mp-art-size', h + 'px')
        } else {
          root.style.removeProperty('--rls-mp-art-size')
        }
      }

      function scheduleArtSizeSync() {
        $timeout(syncArtSize, 0, false)
      }

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

      function hideVolumePanel() {
        vm.volumePanelOpen = false
        restoreVolumeFlyoutToHost()
      }

      function teardownDocClick() {
        if (docClickBound) {
          $document.off('click', onDocumentClick)
          docClickBound = false
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

      function onDocumentClick() {
        $scope.$evalAsync(function() {
          vm.playlistMenuOpen = false
          vm.volumePanelOpen = false
          teardownDocClick()
          restoreFlyoutToHost()
          restoreVolumeFlyoutToHost()
        })
      }

      function showVolumePanel() {
        if (vm.volumePanelOpen) {
          $timeout(placeVolumeFlyout, 0, false)
          return
        }
        if (vm.playlistMenuOpen) {
          vm.playlistMenuOpen = false
          teardownDocClick()
          restoreFlyoutToHost()
        }
        vm.volumePanelOpen = true
        $timeout(function() {
          const fly = volumeFlyout()
          const trig = $element[0].querySelector('.rls-mp-ico-volume')
          if (!fly || !trig) {
            vm.volumePanelOpen = false
            return
          }
          document.body.appendChild(fly)
          placeVolumeFlyout()
          $timeout(placeVolumeFlyout, 0, false)
        }, 0, false)
      }

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
        const fly = volumeFlyout()
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
          $scope.$evalAsync(showVolumePanel)
        }
        function onFlyEnter() {
          $scope.$evalAsync(showVolumePanel)
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
          $scope.$evalAsync(hideVolumePanel)
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

      vm.togglePlaylistMenu = function(ev) {
        if (ev) ev.stopPropagation()
        if (vm.playlistMenuOpen) {
          vm.playlistMenuOpen = false
          teardownDocClick()
          restoreFlyoutToHost()
          return
        }
        vm.volumePanelOpen = false
        restoreVolumeFlyoutToHost()
        $timeout(function() {
          const fly = flyout()
          const trig = $element[0].querySelector('.rls-mp-pl-trigger')
          if (!fly || !trig) return
          document.body.appendChild(fly)
          placeFlyout()
          vm.playlistMenuOpen = true
          $timeout(placeFlyout, 0, false)
          $timeout(function() {
            teardownDocClick()
            $document.on('click', onDocumentClick)
            docClickBound = true
          }, 0, false)
        }, 0)
      }

      vm.pickPlaylist = function(name, ev) {
        if (ev) ev.stopPropagation()
        if (!name) return
        vm.playlistModel = name
        vm.onPlaylistModelChange()
        vm.playlistMenuOpen = false
        teardownDocClick()
        restoreFlyoutToHost()
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
      let pollHandle = null

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
        if (vm.startPlaying === 'false') {
          vm.stop()
        } else if (!result.isPlaying) {
          vm.play()
        }
      }

      function refresh() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.getUiState()', function(result) {
          if (!result || typeof result !== 'object') return
          $scope.$evalAsync(function() {
            const nextNames = result.playlistNames || []
            if (playlistNamesSig(vm.state.playlistNames) !== playlistNamesSig(nextNames)) {
              vm.state.playlistNames = nextNames.slice()
            }
            vm.state.tracks = result.tracks || []
            vm.state.index = result.index
            vm.state.count = result.count
            vm.state.isPlaying = result.isPlaying
            vm.state.positionSec = result.positionSec
            vm.state.durationSec = result.durationSec
            vm.state.currentTitle = result.currentTitle
            vm.state.currentCover = result.currentCover
            vm.state.activePlaylist = result.activePlaylist
            vm.state.shuffle = !!result.shuffle
            vm.state.repeatMode = result.repeatMode || 'all'
            if (result.activePlaylist && vm.playlistModel !== result.activePlaylist) {
              vm.playlistModel = result.activePlaylist
            }
            if (!vm.volumePanelOpen && result.musicVolume != null) {
              vm.volumePercent = Math.max(0, Math.min(100, Math.round(Number(result.musicVolume) * 100)))
            }
            scheduleArtSizeSync()
            maybeApplyStartupPlayback(result)
          })
        })
      }

      vm.onPlaylistModelChange = function() {
        const name = vm.playlistModel
        if (!name) return
        if (name === vm.state.activePlaylist) return
        vm.selectPlaylist(name)
      }

      function syncOutput() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        const en = (vm.emitterName || '').trim()
        if (en) {
          window.bngApi.engineLua(
            'extensions.overhaul_musicPlayer.uiSetOutput(' + luaStr(en) + ', false, nil)'
          )
        } else {
          window.bngApi.engineLua(
            'extensions.overhaul_musicPlayer.uiSetOutput(nil, ' + luaBool(vm.useGui !== 'false') + ', nil)'
          )
        }
      }

      function loadPlaylistPath() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        const p = (vm.playlistPath || '').trim()
        if (!p) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.loadPlaylist(' + luaStr(p) + ')')
      }

      function loadMusicLibrary() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        const root = ((vm.musicRoot || '/music').trim() || '/music')
        const pref = (vm.activePlaylist || '').trim()
        let lua = 'extensions.overhaul_musicPlayer.loadMusicLibrary(' + luaStr(root) + ')'
        if (pref) {
          lua = 'extensions.overhaul_musicPlayer.loadMusicLibrary(' + luaStr(root) + ', ' + luaStr(pref) + ')'
        }
        window.bngApi.engineLua(lua)
      }

      vm.fmt = function(sec) {
        const n = Math.max(0, Math.floor(Number(sec) || 0))
        const m = Math.floor(n / 60)
        const s = n % 60
        return m + ':' + (s < 10 ? '0' : '') + s
      }

      vm.pct = function() {
        const d = Number(vm.state.durationSec) || 0
        if (d <= 0) return 0
        return Math.min(100, 100 * (Number(vm.state.positionSec) || 0) / d)
      }

      vm.play = function() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.uiPlay()')
        window.setTimeout(refresh, 40)
      }

      vm.stop = function() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.uiStop()')
        refresh()
      }

      vm.togglePlayStop = function() {
        if (vm.state.isPlaying) {
          vm.stop()
        } else {
          vm.play()
        }
      }

      vm.next = function() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.uiNext()')
        window.setTimeout(refresh, 40)
      }

      vm.prev = function() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.uiPrevious()')
        window.setTimeout(refresh, 40)
      }

      vm.toggleShuffle = function() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.uiToggleShuffle()')
        window.setTimeout(refresh, 40)
      }

      vm.toggleRepeat = function() {
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.uiToggleRepeat()')
        window.setTimeout(refresh, 40)
      }

      function volumeSliderClientY(ev) {
        if (ev.touches && ev.touches.length) {
          return ev.touches[0].clientY
        }
        if (ev.changedTouches && ev.changedTouches.length) {
          return ev.changedTouches[0].clientY
        }
        return ev.clientY
      }

      vm.volumeSliderPointerDown = function(ev) {
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
          $scope.$evalAsync(function() {
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

      vm.volumeSliderKeyDown = function(ev) {
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

      vm.applyVolumePercent = function() {
        let p = Number(vm.volumePercent)
        if (Number.isNaN(p)) p = 100
        p = Math.max(0, Math.min(100, Math.round(p)))
        vm.volumePercent = p
        if (!window.bngApi || !window.bngApi.engineLua) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.uiSetVolume(' + (p / 100) + ')')
      }

      vm.selectPlaylist = function(name) {
        if (!window.bngApi || !window.bngApi.engineLua) return
        if (!name) return
        window.bngApi.engineLua('extensions.overhaul_musicPlayer.setActivePlaylist(' + luaStr(name) + ')')
        window.setTimeout(refresh, 40)
      }

      $scope.$evalAsync(function() {
        if ((vm.playlistPath || '').trim()) {
          loadPlaylistPath()
        } else {
          loadMusicLibrary()
        }
        syncOutput()
        refresh()
        const ms = Math.max(80, parseInt(vm.pollMs, 10) || 320)
        pollHandle = $interval(refresh, ms)
        scheduleArtSizeSync()
        if (window.ResizeObserver) {
          const col = $element[0].querySelector('.rls-mp-main-col')
          if (col) {
            artResizeObserver = new window.ResizeObserver(scheduleArtSizeSync)
            artResizeObserver.observe(col)
          }
        }
        window.addEventListener('resize', syncArtSize)
        transportRow = $element[0].querySelector('.rls-mp-row-ctrl')
        if (transportRow) {
          transportRow.addEventListener('mousedown', transportPointerDown)
          transportRow.addEventListener('touchstart', transportPointerDown, { passive: true })
        }
        bindVolumeHover()
        bindVolumeSliderInteractions()
      })

      $scope.$on('$destroy', function() {
        vm.playlistMenuOpen = false
        vm.volumePanelOpen = false
        unbindVolumeHover()
        unbindVolumeSliderInteractions()
        teardownDocClick()
        restoreFlyoutToHost()
        restoreVolumeFlyoutToHost()
        transportAbort()
        if (transportRow) {
          transportRow.removeEventListener('mousedown', transportPointerDown)
          transportRow.removeEventListener('touchstart', transportPointerDown)
          transportRow = null
        }
        window.removeEventListener('resize', syncArtSize)
        if (artResizeObserver) {
          artResizeObserver.disconnect()
          artResizeObserver = null
        }
        if (pollHandle) {
          $interval.cancel(pollHandle)
          pollHandle = null
        }
      })
    }]
  }
}])

export default rlsMusicPlayerModule
