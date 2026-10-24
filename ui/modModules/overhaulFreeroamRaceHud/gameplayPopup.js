// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Angular content keeps its owning controller; the stock popup owns navigation.
angular.module('beamng.stuff').directive('overhaulPopup', ['$compile', function($compile) {
  return {
    restrict: 'A', terminal: true,
    link(scope, element, attrs) {
      const template = element.clone()
      template.removeAttr('overhaul-popup')
      template.removeAttr('ng-if')
      template.removeAttr('overhaul-popup-when')
      element.empty()
      element.css('display', 'none')
      const child = scope.$new()
      const content = $compile(template)(child)
      let handle
      let disposed = false
      let generation = 0
      const cancel = () => {
        if (!disposed) scope.$evalAsync(attrs.overhaulPopup)
      }
      function present(modal) {
        const token = ++generation
        handle?.return(true)
        handle = null
        if (!modal) {
          element.css('display', 'contents')
          element.append(content)
          return
        }
        element.css('display', 'contents')
        Promise.resolve().then(async () => {
          if (disposed || token !== generation) return
          const open = window.bngVue?.openOverhaulAngularPopup
          if (!open) throw new Error('Overhaul popup host is unavailable')
          const popup = await open(content[0], element[0])
          if (disposed || token !== generation) { popup.return(true); return }
          handle = popup
          popup.promise.then(result => { if (token === generation && result === false) cancel() })
        }).catch(error => {
          console.error('[Overhaul popup]', error)
          if (token === generation) cancel()
        })
      }
      if (attrs.overhaulPopupWhen) scope.$watch(attrs.overhaulPopupWhen, present)
      else present(true)
      scope.$on('$destroy', () => {
        disposed = true
        generation++
        handle?.return(true)
        child.$destroy()
        content.remove()
      })
    },
  }
}])
