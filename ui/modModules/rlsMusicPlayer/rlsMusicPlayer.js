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
      let flyoutEl = null
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
        if (!btn) {
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
        const h = hostEl()
        flyoutEl = (h || $element[0]).querySelector('.rls-mp-dropdown-flyout')
        return flyoutEl
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

      function onDocumentClick() {
        $scope.$evalAsync(function() {
          vm.playlistMenuOpen = false
          teardownDocClick()
          restoreFlyoutToHost()
        })
      }

      vm.togglePlaylistMenu = function(ev) {
        if (ev) ev.stopPropagation()
        if (vm.playlistMenuOpen) {
          vm.playlistMenuOpen = false
          teardownDocClick()
          restoreFlyoutToHost()
          return
        }
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
        } else {
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
      })

      $scope.$on('$destroy', function() {
        vm.playlistMenuOpen = false
        teardownDocClick()
        restoreFlyoutToHost()
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
