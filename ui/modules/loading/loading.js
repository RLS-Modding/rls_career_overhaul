angular.module('beamng.stuff')

.directive('animatedIcon', [function () {
  return {
    template: '<div class="icon" layout-align="center center"><div class="icon-img"></div></div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      scope.$watch('data', function() {
        // element[0].querySelector('.icon-img').style = "background-image: url(/ui/modules/loading/icon_" + attrs.icon + ".svg);"
        element[0].getElementsByClassName("icon-img")[0].style.backgroundImage = `url("/ui/modules/loading/icon_${attrs.icon}.svg")`;
        if(scope.data !== undefined) {
          let percent = (scope.data.iconState && scope.data.iconState[attrs.icon.toUpperCase()]) || 0
          element[0].style.backgroundPosition = '0 ' + (percent)  + '%'
        }
      })
    }
  }
}])


.directive('animatedProgressBar', [function () {
  return {
    template: '<div class="progressBarBackground" layout="column" layout-align="center center"><div class="progressBarForeground" layout="column" layout-align="center end"></div><div class="progressBarPercentText"></div></div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      scope.$watch('data', function() {
        let pr = element[0].querySelector('.progressBarForeground')
        let prText = element[0].querySelector('.progressBarPercentText')
        if(scope.data !== undefined) {
          if(scope.data.currentEntries && scope.data.currentEntries.length > 0) {
            let p = scope.data.currentEntries[0].progress
            pr.style.left = '-' + (100 - p)  + '%'
            prText.innerHTML = Math.round(p)  + '%'
          } else {
            // 0 = full bar, -100% = empty
            pr.style.left = '0'
            prText.innerHTML = ''
          }
        }
      })
    }
  }
}])


.directive('animatedProgressStatus', [function () {
  return {
    template: '<div class="progressStatus" layout-align="center center"></div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      scope.$watch('data', function() {
        if(scope.data !== undefined) {
          if(scope.data.currentEntries && scope.data.currentEntries.length > 0) {
            element[0].innerHTML = scope.data.currentEntries[0].message
          } else {
            element[0].innerHTML = ''
          }
        }
      })
    }
  }
}])

.directive('animatedProgressStatusHistory', [function () {
  return {
    template: '<div class="progressStatusHistory" layout-align="center center"><div ng-repeat="item in data.historyEntriesDisplay">{{item.message}}</div></div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
    }
  }
}])

.directive('tipsBar', [function () {
  return {
    template: '<div class="tipsBar" layout-align="begin begin" layout="row" ><div class="tipsBarTitle">{{:: "ui.loadingScreen.tips" | translate}}:</div><div class="tipsBarTip" bng-translate="{{ ::hintTranslationKey }}"></div></div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      /*
      let pr = element[0].querySelector('.tipsBarTip')
      pr.innerHTML = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation'
      */
    }
  }
}])


.controller('LoadingController', ['$scope', 'ControlsUtils', 'Hints', 'Utils',
  function ($scope, ControlsUtils, Hints, Utils) {

  let vm = this
  $scope.hintTranslationKey = Hints[Math.floor(Math.random() * Hints.length)]

  function updateData(data) {
    //console.log(data)
    $scope.data = {}
    $scope.data.historyEntries = data.historyEntries
    $scope.data.historyEntriesDisplay = data.historyEntries.slice(Math.max( data.historyEntries.length -3, 1))
    $scope.data.currentEntries = data.currentEntries; //.slice(0, 2)
    // optimize data layout for our usecase
    $scope.data.iconState = {}
    for(let i = 0; i < data.currentEntries.length; i++) {
      $scope.data.iconState[data.currentEntries[i].name.toUpperCase()] = data.currentEntries[i].progress
    }
    for(let i = 0; i < data.historyEntries.length; i++) {
      $scope.data.iconState[data.historyEntries[i].name.toUpperCase()] = 100
    }
  }
  //updateData(sampleData)

  $scope.$on('UpdateLoadingProgressV2', function (event, data) {
    window.requestAnimationFrame(function () {
      //console.log(">>> UpdateLoadingProgressV2: " + JSON.stringify(data))
      $scope.$apply(function () {
        updateData(data)
      })
    })
    $scope.$digest()
  })

  bngApi.engineLua('sailingTheHighSeas', (val) => {
    $scope.sailingTheHighSeas = val
  })

  let AMOUNT_OF_LOADING_IMAGES = 14
  let rnd = Utils.random(1, AMOUNT_OF_LOADING_IMAGES, true)
  let file = `/ui/modules/loading/drive/rls_drive_loading_${rnd}.jpg`
  if ($scope.sailingTheHighSeas === true) {
    file = "/ui/modules/mainmenu/unofficial_version.jpg"
  }

  // no infinite loading screen
  let timeout = setTimeout(() => {
    bngApi.engineLua('core_gamestate.loadingScreenActive()')
  }, 10000)

  // clear any sticky play states (e.g. scenario screens)
  $scope.$parent.app.stickyPlayState = null

  $scope.$evalAsync(() => {
    vm.img = file
    // give angualar a head start to finish running it's digest
    setTimeout(function () {
      // since background images don't fire a load event, we'll simulate one
      let a = new Image()
      a.onload = function () {
        // give the render a head start (ie. wait 2-3 frames)
        Utils.waitForCefAndAngular(() => {
          bngApi.engineLua('core_gamestate.loadingScreenActive()')
          clearTimeout(timeout)
        })
      }
      a.src = file
    })
  })

  $scope.$on('$destroy', function () {
    clearTimeout(timeout)
  })
}])
