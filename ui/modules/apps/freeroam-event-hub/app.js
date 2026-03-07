'use strict';
angular.module('beamng.apps')
.directive('freeroamEventHub', ['$timeout', '$rootScope', function ($timeout, $rootScope) {
  return {
    restrict: 'EA',
    scope: true,
    template:
      '<div class="freeroam-event-hub" style="width:100%;background:#000;color:#fff;font-size:22px;line-height:1.4;box-sizing:border-box;overflow:visible;" ng-class="{ \'hub-available\': available }">' +
        '<div ng-if="available" class="hub-panel" style="width:100%;max-width:100%;background:#000;border:1px solid rgba(255,255,255,0.25);border-radius:8px;box-sizing:border-box;">' +
          '<div class="hub-header" style="display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 14px;border-bottom:1px solid rgba(255,255,255,0.2);background:rgba(255,255,255,0.06);border-radius:8px 8px 0 0;min-height:44px;flex-shrink:0;">' +
            '<span class="hub-title" style="flex:1;min-width:0;font-weight:700;font-size:20px;color:#fff;">{{ getHeaderTitle() }}</span>' +
            '<button class="hub-header-btn" ng-click="closeApp()" title="Close" style="flex-shrink:0;background:rgba(255,255,255,0.2);border:1px solid rgba(255,255,255,0.4);border-radius:6px;color:#fff;font-weight:600;padding:6px 12px;cursor:pointer;white-space:nowrap;">Close</button>' +
          '</div>' +
          '<div class="hub-content" style="padding:14px 16px;color:#fff;font-size:22px;">' +
            '<div ng-if="showSessionEnded" style="display:flex;flex-direction:column;gap:12px;">' +
              '<div style="font-size:24px;font-weight:700;color:#9cf;">Session ended</div>' +
              '<div style="font-size:20px;color:#aaa;">You left the race area.</div>' +
              '<button type="button" class="hub-menu-btn" ng-click="closeApp()" style="margin-top:8px;padding:12px 14px;background:rgba(255,255,255,0.2);border:1px solid rgba(255,255,255,0.4);border-radius:6px;color:#fff;font-size:22px;font-weight:600;cursor:pointer;">Close</button>' +
            '</div>' +
            '<div ng-if="showResult && raceResult && !showSessionEnded && !showRaceHistory" style="display:flex;flex-direction:column;gap:10px;">' +
              '<div style="font-size:24px;font-weight:700;color:#9cf;margin-bottom:4px;">Race complete</div>' +
              '<div style="display:flex;justify-content:space-between;font-size:24px;"><span>Laps</span><span>{{ raceResult.lapsCompleted }} / {{ raceResult.lapsTotal }}</span></div>' +
              '<div style="display:flex;justify-content:space-between;font-size:24px;"><span>Total time</span><span>{{ formatTime(raceResult.totalTime) }}</span></div>' +
              '<div ng-if="raceResult.bestLap != null" style="display:flex;justify-content:space-between;font-size:24px;"><span>Best lap</span><span>{{ formatTime(raceResult.bestLap) }}</span></div>' +
              '<div ng-if="raceResult.newBest" style="color:#3c3;font-weight:700;font-size:24px;">New best time!</div>' +
              '<div ng-if="raceResult.invalidLap" style="color:#f96;font-style:italic;font-size:24px;">Lap invalidated</div>' +
              '<div ng-if="raceResult.reward != null && raceResult.reward > 0" style="display:flex;justify-content:space-between;font-size:24px;"><span>Reward</span><span>${{ raceResult.reward.toFixed(2) }}</span></div>' +
              '<button type="button" class="hub-menu-btn" ng-click="goToRaceHistory()" style="margin-top:12px;padding:12px 14px;background:rgba(0,150,255,0.35);border:1px solid rgba(255,255,255,0.4);border-radius:6px;color:#fff;font-size:22px;font-weight:600;cursor:pointer;">Next</button>' +
            '</div>' +
            '<div ng-if="showRaceHistory" style="display:flex;flex-direction:column;gap:8px;">' +
              '<div style="font-size:24px;font-weight:700;color:#9cf;margin-bottom:4px;">Race history</div>' +
              '<div style="font-size:18px;color:#aaa;margin-bottom:8px;">Your best times and payouts for this map.</div>' +
              '<div class="hub-history-list" style="max-height:320px;overflow-y:auto;border:1px solid rgba(255,255,255,0.15);border-radius:6px;padding:8px;">' +
                '<div ng-repeat="entry in raceHistoryEntries track by entry.raceLabel" style="display:flex;justify-content:space-between;align-items:center;padding:8px 10px;border-bottom:1px solid rgba(255,255,255,0.1);font-size:20px;gap:12px;">' +
                  '<span style="flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;" title="{{ entry.raceLabel }}">{{ entry.raceLabel }}</span>' +
                  '<span ng-if="entry.time != null" style="flex-shrink:0;">{{ formatTime(entry.time) }}</span>' +
                  '<span ng-if="entry.driftScore != null && entry.driftScore > 0" style="flex-shrink:0;">{{ entry.driftScore }} pts</span>' +
                  '<span ng-if="entry.topSpeed != null && entry.topSpeed > 0" style="flex-shrink:0;">{{ entry.topSpeed | number:1 }} mph</span>' +
                  '<span ng-if="entry.reward != null && entry.reward > 0" style="flex-shrink:0;color:#6c6;">${{ entry.reward.toFixed(2) }}</span>' +
                '</div>' +
                '<div ng-if="!raceHistoryEntries || raceHistoryEntries.length === 0" style="padding:12px;color:#888;font-size:20px;">No events completed yet.</div>' +
              '</div>' +
              '<button type="button" class="hub-menu-btn" ng-click="closeApp()" style="margin-top:8px;padding:12px 14px;background:rgba(255,255,255,0.2);border:1px solid rgba(255,255,255,0.4);border-radius:6px;color:#fff;font-size:22px;font-weight:600;cursor:pointer;">Close</button>' +
            '</div>' +
            '<div ng-if="!showResult && !showSessionEnded && !showRaceHistory && selectedRace && !isLiveRace()" style="color:#fff;display:flex;flex-direction:column;gap:2px;">' +
              '<div style="margin-top:8px;color:#aaa;font-size:22px;font-style:italic;">Drive to start line to begin.</div>' +
            '</div>' +
            '<div ng-if="!showResult && !showSessionEnded && !showRaceHistory && isLiveRace()" style="display:flex;flex-direction:column;gap:3px;margin-top:8px;padding-top:8px;border-top:1px solid rgba(255,255,255,0.2);">' +
              '<div ng-if="raceState.routeName" class="hub-detail-route" style="font-size:20px;color:#9cf;margin-bottom:2px;">{{ raceState.routeName }}</div>' +
              '<div class="hub-detail-row" style="font-size:26px;">Lap {{ (raceState.currentLap || 0) + 1 }}</div>' +
              '<div ng-if="raceState.invalidLap" class="hub-detail-invalid" style="color:#f96;font-size:24px;font-style:italic;">Lap invalidated</div>' +
              '<div class="hub-detail-timer" style="font-size:30px;font-weight:700;display:flex;justify-content:space-between;align-items:center;gap:8px;">' +
                '<span>Lap: {{ formatTime(raceState.currentLapTime) }}</span>' +
                '<span ng-if="getDelta() !== null" ng-style="getDelta() < 0 ? { color: \'#3c3\', fontWeight: 600 } : { color: \'#f44\', fontWeight: 600 }">{{ formatDelta(getDelta()) }}</span>' +
              '</div>' +
              '<div style="font-size:24px;">Best lap: {{ raceState.bestLapThisRun != null ? formatTime(raceState.bestLapThisRun) : "—" }}</div>' +
              '<div ng-if="raceState.lastLapTime != null" style="font-size:24px;">Last lap: {{ formatTime(raceState.lastLapTime) }}</div>' +
              '<div ng-if="raceState.topSpeedThisLap != null" style="font-size:24px;">Top speed: {{ formatSpeed(raceState.topSpeedThisLap) }}</div>' +
              '<div ng-if="splitsList().length" style="margin-top:6px;padding-top:6px;border-top:1px solid rgba(255,255,255,0.15);">' +
                '<div style="font-size:20px;color:#9cf;margin-bottom:4px;">Checkpoints</div>' +
                '<div ng-repeat="split in splitsList() track by $index" style="font-size:20px;display:flex;justify-content:space-between;gap:8px;padding:2px 0;">' +
                  '<span>CP {{ $index + 1 }}: {{ formatTime(split) }}</span>' +
                  '<span ng-if="getSectorDelta($index) !== null" ng-style="getSectorDelta($index) < 0 ? { color: \'#3c3\', fontWeight: 600 } : { color: \'#f44\', fontWeight: 600 }">{{ formatDelta(getSectorDelta($index)) }}</span>' +
                '</div>' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>',
    link: function (scope) {
      var api = (typeof bngApi !== 'undefined' && bngApi && bngApi.engineLua) ? bngApi : (window.bngApi && window.bngApi.engineLua ? window.bngApi : null);
      scope.available = false;
      scope.raceState = { inRace: false };
      scope.selectedRace = null;
      scope.showResult = false;
      scope.raceResult = null;
      scope.showSessionEnded = false;
      scope.showRaceHistory = false;
      scope.raceHistoryEntries = [];

      function safeApply(fn) {
        var phase = scope.$$phase;
        if (phase === '$apply' || phase === '$digest') fn(); else scope.$apply(fn);
      }

      scope.$on('FreeroamHubSetAvailable', function (event, data) {
        safeApply(function () {
          scope.available = data && data.available === true;
          if (!scope.available) {
            scope.showResult = false;
            scope.raceResult = null;
            scope.showSessionEnded = false;
            scope.showRaceHistory = false;
            scope.raceHistoryEntries = [];
            scope.selectedRace = null;
            scope.raceState = { inRace: false };
          }
        });
      });

      scope.$on('FreeroamHubRaceState', function (event, data) {
        safeApply(function () {
          scope.raceState = data || { inRace: false };
          if (scope.raceState.inRace && scope.raceState.raceId) {
            scope.selectedRace = { raceId: scope.raceState.raceId, label: scope.raceState.raceLabel || scope.raceState.raceId };
            scope.showSessionEnded = false;
          } else if (scope.raceState.staged && scope.raceState.raceId) {
            scope.selectedRace = { raceId: scope.raceState.raceId, label: scope.raceState.raceLabel || scope.raceState.raceId };
            scope.showSessionEnded = false;
          } else {
            scope.selectedRace = null;
            if (scope.available) scope.showSessionEnded = true;
          }
        });
      });

      scope.$on('FreeroamHubRaceResult', function (event, data) {
        safeApply(function () {
          scope.raceResult = data || null;
          scope.showResult = !!scope.raceResult;
          scope.showSessionEnded = false;
          scope.showRaceHistory = false;
        });
      });

      scope.$on('FreeroamHubRaceHistory', function (event, data) {
        safeApply(function () {
          scope.raceHistoryEntries = (data && data.entries) ? data.entries : [];
          scope.showRaceHistory = true;
        });
      });

      scope.goToRaceHistory = function () {
        scope.showRaceHistory = true;
        if (api && api.engineLua) {
          api.engineLua('extensions.hook("onFreeroamHubRequestRaceHistory")');
        }
      };

      $timeout(function () {
        if (api && api.engineLua) api.engineLua('extensions.hook("onFreeroamHubReady")');
      }, 0);

      scope.formatTime = function (seconds) {
        if (seconds == null || typeof seconds !== 'number') return '--:--.--';
        var sign = seconds < 0 ? '-' : '';
        seconds = Math.abs(seconds);
        var m = Math.floor(seconds / 60);
        var s = seconds % 60;
        var whole = Math.floor(s);
        var cent = Math.floor((s - whole) * 100);
        return sign + (m < 10 ? '0' : '') + m + ':' + (whole < 10 ? '0' : '') + whole + '.' + (cent < 10 ? '0' : '') + cent;
      };
      scope.formatDelta = function (delta) {
        if (delta == null || typeof delta !== 'number') return '';
        var sign = delta >= 0 ? '+' : '';
        return sign + delta.toFixed(2) + 's';
      };
      scope.formatSpeed = function (mph) {
        if (mph == null || typeof mph !== 'number') return '—';
        return Math.round(mph) + ' mph';
      };
      scope.getDelta = function () {
        if (!scope.raceState || scope.raceState.currentLapTime == null || scope.raceState.bestLapThisRun == null) return null;
        return scope.raceState.currentLapTime - scope.raceState.bestLapThisRun;
      };
      scope.getSectorDelta = function (sectorIndex) {
        if (!scope.raceState || !scope.raceState.sectorDeltas) return null;
        var key = sectorIndex + 1;
        var d = scope.raceState.sectorDeltas[sectorIndex] != null ? scope.raceState.sectorDeltas[sectorIndex] : scope.raceState.sectorDeltas[key];
        return d != null && typeof d === 'number' ? d : null;
      };
      scope.splitsList = function () {
        var t = scope.raceState && scope.raceState.splits;
        if (!t) return [];
        if (Array.isArray(t)) return t;
        var arr = [];
        for (var i = 1; i <= 20; i++) {
          if (t[i] !== undefined && t[i] !== null) arr.push(t[i]);
          else break;
        }
        return arr;
      };
      scope.lastSplitTime = function () {
        var list = scope.splitsList();
        return list && list.length ? list[list.length - 1] : null;
      };
      scope.lastSplitDelta = function () {
        var list = scope.splitsList();
        if (!list || list.length === 0) return null;
        return scope.getSectorDelta(list.length - 1);
      };
      scope.isLiveRace = function () {
        if (!scope.raceState || scope.raceState.inRace !== true || !scope.selectedRace) return false;
        var a = scope.raceState.raceId;
        var b = scope.selectedRace.raceId;
        return a == b || String(a) === String(b);
      };
      scope.getHeaderTitle = function () {
        if (scope.showRaceHistory) return 'Race history';
        if (scope.showSessionEnded) return 'Session ended';
        if (scope.showResult && scope.raceResult) return scope.raceResult.raceLabel || 'Race Result';
        if (scope.selectedRace) return scope.selectedRace.label || 'Freeroam Event';
        return 'Freeroam Event Hub';
      };
      scope.closeApp = function () {
        scope.available = false;
        scope.showSessionEnded = false;
        scope.showResult = false;
        scope.raceResult = null;
        scope.showRaceHistory = false;
        scope.raceHistoryEntries = [];
        scope.selectedRace = null;
        scope.raceState = { inRace: false };
        $rootScope.$broadcast('appContainer:removeApp', 'freeroamEventHub');
      };
    }
  };
}]);
