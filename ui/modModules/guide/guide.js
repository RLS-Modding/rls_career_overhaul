'use strict'

let guideScope = null
let stopListeningFn = null
let bridgeListenerOff = null
let eventsRegister = {}

function getBridge() {
  return window.bridge || (window.$game && window.$game.events && { events: window.$game.events }) || null
}

angular.module('beamng.stuff')
.controller('GuideController', ['$scope', '$rootScope', function($scope, $rootScope) {
  guideScope = $scope
  $scope.showSplash = false
  $scope.phoneBinding = 'Not bound'
  $scope.isBinding = false
  $scope.isPhoneBound = false
  $scope.bindingAction = 'openPhone'

  function updatePhoneBound(binding) {
    $scope.isPhoneBound = binding && binding !== 'Not bound'
  }

  function loadPhoneBinding(retryCount) {
    retryCount = retryCount || 0
    bngApi.engineLua("extensions.career_modules_guide.getPhoneBinding()", function(result) {
      $scope.$evalAsync(function() {
        var binding = (result && result.binding) ? result.binding : 'Not bound'
        $scope.phoneBinding = binding
        updatePhoneBound(binding)
        if (binding === 'Not bound' && retryCount < 3) {
          setTimeout(function() { loadPhoneBinding(retryCount + 1) }, 150)
        }
      })
    })
  }

  function stopBinding() {
    $scope.isBinding = false
    if (stopListeningFn) {
      stopListeningFn()
      stopListeningFn = null
    }
    if (bridgeListenerOff) {
      bridgeListenerOff()
      bridgeListenerOff = null
    }
    eventsRegister = {}
    bngApi.engineLua("pcall(function() WinInput.setForwardRawEvents(false) end)")
    bngApi.engineLua("pcall(function() setCEFTyping(false) end)")
    bngApi.engineLua("pcall(function() ActionMap.enableBindingCapturing(false) end)")
  }

  function createRawInputListener(controlCapturedRef) {
    return function(eventOrData, dataArg) {
      var data = dataArg !== undefined ? dataArg : eventOrData
      if (!data || !data.control) return
      if (!$scope.isBinding) return
      if (controlCapturedRef.current) return

      var devName = data.devName
      if (!eventsRegister[devName]) {
        eventsRegister[devName] = { axis: {}, key: [null, null] }
      }
      var eventData = eventsRegister[devName]
      var valid = false

      switch (data.controlType) {
        case 'axis':
          if (!eventData.axis[data.control]) {
            eventData.axis[data.control] = { first: data.value, last: data.value, accumulated: 0 }
          } else {
            var detectionThreshold = devName.startsWith('mouse') ? 1 : 0.5
            eventData.axis[data.control].accumulated +=
              Math.abs(eventData.axis[data.control].last - data.value) / detectionThreshold
            eventData.axis[data.control].last = data.value
          }
          valid = eventData.axis[data.control].accumulated >= 1
          break

        case 'button':
        case 'pov':
        case 'key':
          eventData.key = [eventData.key[eventData.key.length - 1], data.control]
          var key0 = eventData.key[0]
          var key1 = eventData.key[1]
          if (key0 && key1) {
            valid = (key0 === key1)
            if (data.value === 0) {
              eventData.key = [null, null]
            }
          }
          break
      }

      if (valid && devName.startsWith('mouse') && data.control === 'button1') {
        valid = false
      }

      if (valid) {
        controlCapturedRef.current = true
        stopBinding()
        var controlString = data.control || ''
        var devNameVal = data.devName || 'keyboard0'
        var escapedControl = (controlString + '').replace(/\\/g, '\\\\').replace(/'/g, "\\'")
        var escapedDev = (devNameVal + '').replace(/\\/g, '\\\\').replace(/'/g, "\\'")
        bngApi.engineLua("extensions.career_modules_guide.setPhoneBinding('" + escapedControl + "', '" + escapedDev + "')", function(result) {
          $scope.$evalAsync(function() {
            if (result && result.binding) {
              $scope.phoneBinding = result.binding
              updatePhoneBound(result.binding)
            }
          })
        })
      }
    }
  }

  $scope.startBinding = function(event) {
    if ($scope.isBinding) return
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    $scope.isBinding = true
    eventsRegister = {}
    var controlCapturedRef = { current: false }

    bngApi.engineLua("ActionMap.enableBindingCapturing(true)")
    bngApi.engineLua("setCEFTyping(true)")

    var listener = createRawInputListener(controlCapturedRef)
    var angularRootScope = window.globalAngularRootScope || $rootScope
    stopListeningFn = angularRootScope.$on('RawInputChanged', listener)

    var bridge = getBridge()
    if (bridge && bridge.events && bridge.events.on) {
      bridge.events.on('RawInputChanged', listener)
      bridgeListenerOff = function() {
        bridge.events.off('RawInputChanged', listener)
      }
    }

    bngApi.engineLua("WinInput.setForwardRawEvents(true)")
  }
  
  $scope.onContinue = function() {
    if ($scope.isBinding) {
      stopBinding()
    }
    $scope.showSplash = false
    bngApi.engineLua("extensions.career_modules_guide.onContinue()")
  }
  
  // Listen for guide events using $rootScope.$on
  var angularRootScope = window.globalAngularRootScope || $rootScope
  
  var showSplashListener = angularRootScope.$on('GuideShowSplash', function() {
    console.log('[Guide] GuideShowSplash received')
    $scope.$evalAsync(function() {
      $scope.showSplash = true
      loadPhoneBinding()
    })
  })
  
  var hideSplashListener = angularRootScope.$on('GuideHideSplash', function() {
    console.log('[Guide] GuideHideSplash received')
    $scope.$evalAsync(function() {
      $scope.showSplash = false
      if ($scope.isBinding) {
        stopBinding()
      }
    })
  })
  
  // Clean up listeners when scope is destroyed
  $scope.$on('$destroy', function() {
    console.log('[Guide] Controller destroyed')
    if (stopListeningFn) stopListeningFn()
    showSplashListener()
    hideSplashListener()
  })
}])

const guideModule = angular.module('guide', ['ui.router'])

.run(['$rootScope', '$compile', function($rootScope, $compile) {
  function initializeGuideOverlay() {
    const existingContainer = document.getElementById('guide-overlay-container')
    if (existingContainer) {
      return
    }
    
    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()
    
    if (!injector) {
      setTimeout(initializeGuideOverlay, 100)
      return
    }
    
    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    
    const guideContainer = angular.element('<div id="guide-overlay-container" ng-controller="GuideController" ng-include="\'/ui/modModules/guide/guide.html\'"></div>')
    bodyElement.append(guideContainer)
    
    $compile(guideContainer)($rootScope)
  }
  
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeGuideOverlay)
  } else {
    setTimeout(initializeGuideOverlay, 500)
  }
}])

export default guideModule
