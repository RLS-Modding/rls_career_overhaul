'use strict'

let guideScope = null
let stopListeningFn = null
let eventsRegister = {}

angular.module('beamng.stuff')
.controller('GuideController', ['$scope', '$rootScope', function($scope, $rootScope) {
  guideScope = $scope
  $scope.showSplash = false
  $scope.phoneBinding = 'Not bound'
  $scope.isBinding = false
  $scope.isPhoneBound = false
  $scope.bindingAction = 'openPhone'

  console.log('[Guide] Controller initialized')

  function updatePhoneBound(binding) {
    $scope.isPhoneBound = binding && binding !== 'Not bound'
  }
  
  function loadPhoneBinding() {
    bngApi.engineLua("extensions.career_modules_guide.getPhoneBinding()", function(result) {
      if (result && result.binding) {
        $scope.$evalAsync(function() {
          $scope.phoneBinding = result.binding
          updatePhoneBound(result.binding)
        })
      }
    })
  }
  
  function convertRawInputToControl(data) {
    const devName = data.devName
    const control = data.control
    
    // Handle keyboard devices (may be "keyboard", "keyboard0", etc.)
    if (devName && devName.startsWith('keyboard')) {
      if (control.length === 1) {
        return 'keyboard_' + control.toLowerCase()
      } else if (control === 'space') {
        return 'keyboard_space'
      } else if (control === 'enter') {
        return 'keyboard_enter'
      } else if (control === 'tab') {
        return 'keyboard_tab'
      } else if (control === 'escape') {
        return 'keyboard_escape'
      } else if (control.startsWith('arrow')) {
        return 'keyboard_' + control
      } else {
        return 'keyboard_' + control.toLowerCase()
      }
    } else if (devName && devName.startsWith('mouse')) {
      if (control.startsWith('button')) {
        const btnNum = control.replace('button', '')
        return 'mouse' + btnNum
      }
      return 'mouse' + control
    }
    
    return devName + '_' + control
  }
  
  function stopBinding() {
    console.log('[Guide] stopBinding called')
    $scope.isBinding = false
    
    // Remove event listener first to prevent any more events
    if (stopListeningFn) {
      stopListeningFn()
      stopListeningFn = null
    }
    
    eventsRegister = {}
    
    // Disable input capturing in the correct order (reverse of start)
    // Use try-catch style by wrapping in pcall on Lua side
    bngApi.engineLua("pcall(function() WinInput.setForwardRawEvents(false) end)")
    bngApi.engineLua("pcall(function() setCEFTyping(false) end)")
    bngApi.engineLua("pcall(function() ActionMap.enableBindingCapturing(false) end)")
    
    console.log('[Guide] stopBinding complete')
  }
  
  $scope.startBinding = function(event) {
    if ($scope.isBinding) return
    
    console.log('[Guide] startBinding called')
    
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    
    $scope.isBinding = true
    eventsRegister = {}
    
    var controlCaptured = false
    
    // Enable input capturing (order matches vanilla)
    bngApi.engineLua("ActionMap.enableBindingCapturing(true)")
    bngApi.engineLua("setCEFTyping(true)")
    
    console.log('[Guide] Registering RawInputChanged listener')
    
    // Use the global Angular rootScope directly (matches how hooks are broadcast)
    var angularRootScope = window.globalAngularRootScope || $rootScope
    console.log('[Guide] Using rootScope:', angularRootScope ? 'found' : 'not found')
    
    // Register event listener using Angular's $on
    stopListeningFn = angularRootScope.$on('RawInputChanged', function(event, data) {
      console.log('[Guide] RawInputChanged received:', data)
      
      if (!$scope.isBinding) return
      if (controlCaptured) return
      
      var devName = data.devName
      if (!eventsRegister[devName]) {
        eventsRegister[devName] = { axis: {}, key: [null, null] }
      }
      
      var valid = false
      
      // Register the received input (matches vanilla logic)
      switch (data.controlType) {
        case 'axis':
          var detectionThreshold = devName.startsWith('mouse') ? 1 : 0.5
          if (!eventsRegister[devName].axis[data.control]) {
            eventsRegister[devName].axis[data.control] = { first: data.value, last: data.value, accumulated: 0 }
          } else {
            eventsRegister[devName].axis[data.control].accumulated += 
              Math.abs(eventsRegister[devName].axis[data.control].last - data.value) / detectionThreshold
            eventsRegister[devName].axis[data.control].last = data.value
          }
          valid = eventsRegister[devName].axis[data.control].accumulated >= 1
          break
          
        case 'button':
        case 'pov':
        case 'key':
          // Accumulate events like vanilla does
          eventsRegister[devName].key.push(data.control)
          eventsRegister[devName].key = eventsRegister[devName].key.slice(-2)
          
          var key0 = eventsRegister[devName].key[0]
          var key1 = eventsRegister[devName].key[1]
          
          console.log('[Guide] Key state:', key0, key1)
          
          if (key0 && key1) {
            valid = (key0 === key1)
            
            // Reset on button release
            if (data.value === 0) {
              eventsRegister[devName].key = [null, null]
            }
          }
          break
      }
      
      // Blacklist right mouse click
      if (valid && devName.startsWith('mouse') && data.control === 'button1') {
        valid = false
      }
      
      console.log('[Guide] Valid input:', valid)
      
      if (valid) {
        controlCaptured = true
        var controlString = convertRawInputToControl(data)
        console.log('[Guide] Captured control:', controlString)
        
        // Stop binding FIRST before calling Lua to ensure input is released
        stopBinding()
        
        // Then set the binding
        bngApi.engineLua("extensions.career_modules_guide.setPhoneBinding('" + controlString + "')", function(result) {
          $scope.$evalAsync(function() {
            if (result && result.binding) {
              $scope.phoneBinding = result.binding
              updatePhoneBound(result.binding)
            }
          })
        })
      }
    })
    
    // Forward raw events after listener is registered
    console.log('[Guide] Enabling WinInput.setForwardRawEvents')
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
