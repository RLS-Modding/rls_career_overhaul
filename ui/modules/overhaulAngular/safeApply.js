// Engine callbacks own only this HUD's subtree; an active Angular pass already covers its changes.
export function createSafeApply($scope) {
  return function safeApply(fn) {
    if ($scope.$$destroyed) return
    fn()
    if (!$scope.$$phase) $scope.$digest()
  }
}
