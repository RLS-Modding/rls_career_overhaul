// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

'use strict'

// Manager settings, save state and route registration. The local navigation
// directive keeps offscreen settings reachable in the bounded HTML/CSS panel.
import '../../modules/overhaulAngular/musicPlayer.js'
import { icons } from '/ui/ui-vue/src/assets/fonts/bngIcons/bngIcons.js'

// English defaults bypass stale game locale caches. The translation guard test
// keeps this map identical to the shipped English resource.
const managerEnglish = {
  "ui.overhaulManager.world.label": "World & traffic",
  "ui.overhaulManager.world.note": "Shape the world around you",
  "ui.overhaulManager.gameplay.label": "Driving & immersion",
  "ui.overhaulManager.gameplay.note": "Make your career feel your own",
  "ui.overhaulManager.autosave.label": "Career saving",
  "ui.overhaulManager.autosave.note": "Keep your progress protected",
  "ui.overhaulManager.developer.label": "Developer tools",
  "ui.overhaulManager.developer.note": "Testing and troubleshooting",
  "ui.overhaulManager.addons.note": "Additional career options",
  "ui.overhaulManager.loadError": "Could not load settings",
  "ui.overhaulManager.savingChanges": "Saving changes…",
  "ui.overhaulManager.saved": "Changes saved",
  "ui.overhaulManager.saveError": "Could not save changes",
  "ui.overhaulManager.settings.autosaveEnabled.label": "Autosave",
  "ui.overhaulManager.settings.autosaveEnabled.description": "Save automatically when stopped or on foot.",
  "ui.overhaulManager.settings.autosaveIntervalMinutes.label": "Autosave Interval",
  "ui.overhaulManager.settings.autosaveIntervalMinutes.description": "Save at this interval once safely stopped.",
  "ui.overhaulManager.settings.autosaveIntervalMinutes.unit": "min",
  "ui.overhaulManager.settings.forcePhoneTutorial.label": "Phone Tutorial",
  "ui.overhaulManager.settings.forcePhoneTutorial.description": "Allow completed tutorials to run again.",
  "ui.overhaulManager.settings.mapDevMode.label": "Map Dev Mode",
  "ui.overhaulManager.settings.mapDevMode.description": "Map editing and testing tools.",
  "ui.overhaulManager.settings.noParkedMode.label": "No Parked Mode",
  "ui.overhaulManager.settings.noParkedMode.description": "Remove parked vehicles from the world.",
  "ui.overhaulManager.settings.racingTeamDevConsole.label": "Racing Team Console",
  "ui.overhaulManager.settings.racingTeamDevConsole.description": "Show the console on the team computer.",
  "ui.overhaulManager.settings.realisticVehicleEntry.label": "Realistic Vehicle Entry",
  "ui.overhaulManager.settings.realisticVehicleEntry.description": "Walk up and open the door to enter.",
  "ui.overhaulManager.settings.realisticWalkingCamera.label": "Realistic Walking Camera",
  "ui.overhaulManager.settings.realisticWalkingCamera.description": "Head bob and sway while on foot.",
  "ui.overhaulManager.settings.showBusPassengers.label": "Bus Stop Passengers",
  "ui.overhaulManager.settings.showBusPassengers.description": "Visible passengers; fares stay the same.",
  "ui.overhaulManager.adjust": "Adjust {{label}}.",
  "ui.overhaulManager.title": "Overhaul Manager",
  "ui.overhaulManager.devKey": "Dev key active",
  "ui.overhaulManager.replay": "Replay now",
  "ui.overhaulManager.on": "On",
  "ui.overhaulManager.off": "Off",
  "ui.overhaulManager.back": "Back",
  "ui.overhaulManager.save": "Save changes",
  "ui.overhaulManager.saving": "Saving…",
  "ui.overhaulManager.invalid": "Choose a valid setting value",
  "ui.overhaulManager.dirty": "Unsaved changes",
  "ui.overhaulManager.upToDate": "Settings up to date",
  "ui.overhaulManager.summary": "{{enabled}} of {{total}} features on",
  "ui.overhaulManager.toggle": "Toggle {{label}}",
  "ui.overhaulManager.mainMenu": "Main menu",
  "ui.overhaulManager.location": "Location"
};

angular.module('beamng.stuff')
.directive('overhaulSettingsNav', function() {
  return {
    restrict: 'A',
    link: function(scope, element) {
      const panel = element[0];
      // Crossfire considers visible rectangles. Include offscreen rows here so
      // a short list cannot send Down straight to the fixed footer.
      function navigate(event) {
        const direction = {focus_u: -1, focus_d: 1, focus_l: -1, focus_r: 1}[event.detail?.name];
        if (!direction || !event.detail.value) return;
        const active = panel.ownerDocument.activeElement;
        if (!panel.contains(active) || !['BUTTON', 'INPUT'].includes(active.tagName)) return;
        const current = active.getBoundingClientRect();
        const content = panel.querySelector('.overhaul-content');
        const inList = content.contains(active);
        const horizontal = ['focus_l', 'focus_r'].includes(event.detail.name);
        if (horizontal && active.getAttribute?.('role') === 'slider') {
          event.preventDefault();
          event.stopImmediatePropagation();
          scope.$evalAsync(() => scope.adjustNumber(active.getAttribute('data-setting-key'), direction));
          return;
        }
        if (horizontal && !inList) return;
        if (!inList && direction > 0) return;
        const controls = Array.from(content.querySelectorAll('button:not(:disabled), input:not(:disabled)'))
          .filter(button => button.getClientRects().length);
        const candidates = controls.filter(button => button !== active)
          .map(button => ({button, rect: button.getBoundingClientRect()}))
          .filter(({rect}) => Math.abs(rect.top + rect.height / 2 - current.top - current.height / 2) < 1
            && direction * (rect.left - current.left) > 1)
          .sort((a, b) => direction * (a.rect.left - b.rect.left));
        const index = controls.indexOf(active);
        const next = horizontal ? candidates[0]?.button
          : !inList ? controls[controls.length - 1]
          : controls[index + direction] || (direction > 0
            ? panel.querySelector('.overhaul-footer button:not(:disabled)') : null);
        if (!next) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        next.focus({preventScroll: true});
        next.classList.add('focus-visible');
        // Reveal the setting's label as well as its control.
        next.closest('.setting-card')?.scrollIntoView({block: 'nearest', inline: 'nearest'});
        next.scrollIntoView({block: 'nearest', inline: 'nearest'});
      }
      function clearFocus(event) {
        event.target.classList.remove('focus-visible');
      }
      panel.addEventListener('ui_nav', navigate, true);
      panel.addEventListener('focusout', clearFocus);
      scope.$on('$destroy', function() {
        panel.removeEventListener('ui_nav', navigate, true);
        panel.removeEventListener('focusout', clearFocus);
      });
    }
  };
})
.controller('OverhaulManagerController', ['$scope', '$translate', function($scope, $translate) {
  $scope.t = function(key, context = {}) {
    if (!key) return '';
    const translated = $translate.instant(key, context);
    if (translated && translated !== key) return translated;
    // Add-ons may supply plain copy or their own namespaced locale keys.
    const fallback = Object.prototype.hasOwnProperty.call(managerEnglish, key)
      ? managerEnglish[key] : /^[\w-]+(?:\.[\w-]+)+$/.test(key)
        ? humanize(key.split('.').filter(part => !['label', 'description', 'note', 'unit'].includes(part)).pop() || key)
        : key;
    return fallback.replace(/{{\s*(\w+)\s*}}/g, (_, name) => context[name] ?? '');
  };
  // angularHost refreshes its locale table on this hook. The completion event
  // also covers asynchronous refreshes before scheduling a fresh digest.
  $scope.$on('onTranslationsReloaded', () => $scope.$evalAsync(() => {}));
  $scope.$on('$translateChangeSuccess', () => $scope.$evalAsync(() => {}));
  $scope.devKeyValid = false;
  $scope.isLoaded = false;
  $scope.isDirty = false;
  $scope.isSaving = false;
  $scope.saveStatus = '';
  $scope.saveError = false;
  $scope.values = {};
  $scope.sections = [];
  $scope.enabledCount = 0;
  $scope.featureCount = 0;
  var savedSettings = {};
  var entries = [];
  var sections = {
    world: {label: 'ui.overhaulManager.world.label', icon: 'globe', note: 'ui.overhaulManager.world.note'},
    gameplay: {label: 'ui.overhaulManager.gameplay.label', icon: 'vehicleDoors', note: 'ui.overhaulManager.gameplay.note'},
    autosave: {label: 'ui.overhaulManager.autosave.label', icon: 'saveAs1', note: 'ui.overhaulManager.autosave.note'},
    developer: {label: 'ui.overhaulManager.developer.label', icon: 'code', note: 'ui.overhaulManager.developer.note'}
  };

  function resolveIcon(name) {
    return Object.prototype.hasOwnProperty.call(icons, name) ? name : 'wrench';
  }

  function humanize(key) {
    return key.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[._-]/g, ' ').replace(/^./, c => c.toUpperCase());
  }

  function updateSummary() {
    var visible = $scope.sections.flatMap(section => section.options).filter(option => option.type === 'boolean');
    $scope.featureCount = visible.length;
    $scope.enabledCount = visible.filter(option => $scope.values[option.key] === true).length;
  }

  function buildSections() {
    var groups = new Map();
    entries.forEach(function(entry) {
      var ui = entry.ui || {};
      // Layout objects belong to their draggable HUD, not a scalar settings control.
      if (entry.type === 'table' || ui.hidden || (ui.devOnly && !$scope.devKeyValid)) return;
      var key = ui.section || entry.section || 'addons';
      if (!groups.has(key)) {
        var heading = sections[key] || {label: humanize(key), icon: 'wrench', note: 'ui.overhaulManager.addons.note'};
        groups.set(key, {key: key, ...heading, icon: resolveIcon(heading.icon), options: []});
      }
      groups.get(key).options.push({...entry, label: ui.label || humanize(entry.key),
        icon: resolveIcon(ui.icon),
        description: ui.description || '', unit: ui.unit || '',
        control: entry.options ? 'choice' : entry.type === 'boolean' ? 'toggle' : entry.type === 'number' ? (Number.isFinite(entry.range?.min) && Number.isFinite(entry.range?.max) ? 'slider' : 'number') : 'text'});
    });
    var order = ['world', 'gameplay', 'autosave', 'developer'];
    $scope.sections = Array.from(groups.values()).sort((a, b) => (order.includes(a.key) ? order.indexOf(a.key) : 4) - (order.includes(b.key) ? order.indexOf(b.key) : 4));
    updateSummary();
  }

  function accepts(option, value) {
    return typeof value === option.type
      && (option.type !== 'number' || Number.isFinite(value))
      && (!option.options || option.options.includes(value))
      && (option.range?.min === undefined || value >= option.range.min)
      && (option.range?.max === undefined || value <= option.range.max);
  }
  $scope.disabled = function(option) {
    return !$scope.isLoaded || $scope.isSaving || option.ui?.disabled === true
      || (option.ui?.devOnly && !$scope.devKeyValid)
      || Object.entries(option.ui?.dependsOn || {}).some(([key, value]) => $scope.values[key] !== value);
  };
  $scope.choiceLabel = function(option, value) {
    return option.type === 'boolean' ? $scope.t(value ? 'ui.overhaulManager.on' : 'ui.overhaulManager.off') : value;
  };
  $scope.changed = function() {
    $scope.saveStatus = '';
    $scope.saveError = false;
    $scope.isDirty = !angular.equals($scope.values, savedSettings);
    $scope.invalid = $scope.sections.some(section => section.options.some(option => !$scope.disabled(option) && !accepts(option, $scope.values[option.key])));
    updateSummary();
  };
  $scope.setValue = function(option, value) {
    if ($scope.disabled(option)) return;
    $scope.values[option.key] = value;
    $scope.changed();
  };

  $scope.adjustNumber = function(key, direction) {
    var option = entries.find(entry => entry.key === key);
    if (!option || !$scope.isLoaded || $scope.isSaving) return;
    var span = option.range.max - option.range.min;
    var configuredStep = option.range.step ?? option.step;
    var step = Number.isFinite(configuredStep) && configuredStep > 0 ? configuredStep : Math.min(1, span / 20);
    var current = Number.isFinite($scope.values[key]) ? $scope.values[key] : option.range.min;
    // Preserve the range origin as well as the step when trimming artifacts.
    var decimals = Math.max(...[step, option.range.min].map(value => {
      var parts = String(value).toLowerCase().split('e');
      return Math.max(0, (parts[0].split('.')[1] || '').length - Number(parts[1] || 0));
    }));
    var next = Number((current + direction * step).toFixed(Math.min(100, decimals)));
    $scope.setValue(option, Math.max(option.range.min, Math.min(option.range.max, next)));
  };
  $scope.rangeRatio = function(option) {
    var span = option.range.max - option.range.min;
    return span ? ($scope.values[option.key] - option.range.min) / span : 0;
  };
  $scope.setSlider = function(option, event) {
    var track = event.currentTarget.querySelector('.slider-track').getBoundingClientRect();
    var ratio = Math.max(0, Math.min(1, (event.clientX - track.left) / track.width));
    // Keyboard/controller activation has no pointer position; advance one step.
    if (!event.detail) return $scope.adjustNumber(option.key, 1);
    $scope.setValue(option, Math.round((option.range.min + ratio * (option.range.max - option.range.min)) * 100) / 100);
  };

  $scope.loadSettings = function() {
    bngApi.engineLua("extensions.overhaul_shell_extensionManager.isDevKeyValid()", function(result) {
      $scope.$evalAsync(function() { $scope.devKeyValid = result === true; buildSections(); });
    });
    // One snapshot keeps definitions and values together, including add-on settings.
    bngApi.engineLua("{schema=extensions.overhaul_shell_settings.getSchema(), values=extensions.overhaul_shell_settings.getSettings()}", function(result) {
      $scope.$evalAsync(function() {
        if (!result || !Array.isArray(result.schema) || !result.values) {
          $scope.saveError = true;
          $scope.saveStatus = 'ui.overhaulManager.loadError';
          return;
        }
        entries = result.schema;
        $scope.values = result.values;
        savedSettings = angular.copy($scope.values);
        buildSections();
        $scope.isLoaded = true;
        $scope.isDirty = false;
      });
    });
  };

  $scope.replayPhoneTutorial = function() {
    if (!$scope.devKeyValid || !$scope.isLoaded || $scope.isSaving) return;
    bngApi.engineLua("extensions.overhaul_shell_extensionManager.replayPhoneTutorial()");
  };

  $scope.saveSettings = function() {
    if (!$scope.isLoaded || $scope.isSaving) return;
    $scope.changed();
    if (!$scope.isDirty || $scope.invalid) return;
    // Send only changed, visible scalar options. JSON decoding safely handles
    // namespaced keys and string values without constructing Lua identifiers.
    var changes = {};
    $scope.sections.forEach(section => section.options.forEach(function(option) {
      if (!$scope.disabled(option) && !angular.equals($scope.values[option.key], savedSettings[option.key])) changes[option.key] = $scope.values[option.key];
    }));
    if (!Object.keys(changes).length) return;
    var payload = JSON.stringify(JSON.stringify(changes));
    $scope.isSaving = true;
    $scope.saveStatus = 'ui.overhaulManager.savingChanges';
    $scope.saveError = false;
    bngApi.engineLua("extensions.overhaul_shell_settings.setSettings(jsonDecode(" + payload + "))", function(result) {
      $scope.$evalAsync(function() {
        $scope.isSaving = false;
        if (result === true) {
          Object.assign(savedSettings, angular.copy(changes));
          $scope.isDirty = !angular.equals($scope.values, savedSettings);
          $scope.saveStatus = $scope.isDirty ? 'ui.overhaulManager.dirty' : 'ui.overhaulManager.saved';
        } else {
          $scope.saveError = true;
          $scope.saveStatus = 'ui.overhaulManager.saveError';
        }
      });
    });
  };
  $scope.goBack = function() { bngApi.engineLua("extensions.ui_router.back()"); };
  $scope.loadSettings();
}])

export default angular.module('overhaulManager', ['ui.router', 'rlsMusicPlayer'])

.config(['$stateProvider', function($stateProvider) {
  $stateProvider.state('menu.overhaulManager', {
    url: '/overhaulManager',
    templateUrl: '/ui/modModules/overhaulManager/overhaulManager.html?v=17',
    controller: 'OverhaulManagerController',
  })
}])

.run(['$rootScope', function ($rootScope) {
  const buttonConfig = {
    icon: '/ui/modModules/overhaulManager/icons/overhaulIcon.png',
    targetState: 'menu.overhaulManager',
    translateid: 'Overhaul Manager'
  };

  function addOverhaulManagerButton(addButton) {
    if (typeof addButton === 'function') {
      addButton(buttonConfig)
    }
  }

  $rootScope.$on("MainMenuButtons", function(_event, addButton) {
    addOverhaulManagerButton(addButton)
  })

  if (window.bridge && window.bridge.events) {
    window.bridge.events.on("MainMenuButtons", addOverhaulManagerButton)
  }

  bngApi.engineLua("guihooks.trigger('BroadcastMainMenuButtons')")
}])
