import { onBeforeUnmount } from 'vue'
import { openOverhaulPopup } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/openOverhaulPopup.js'

// Installed by the persistent Vue host, like openHouseConfirmation.
export function useGameplayPopups() {
  const previous = window.bngVue.openOverhaulAngularPopup
  const active = new Set()
  let disposed = false
  const open = async (content, anchor) => {
    const { default: component } = await import('./AngularGameplayPopup.vue')
    if (disposed) throw new Error('Overhaul popup owner unloaded')
    const popup = openOverhaulPopup(component, { content, anchor }, {
      fade: false, blur: false, style: ['gameplay-original'], preserveLayout: true,
    })
    active.add(popup)
    popup.promise.finally(() => active.delete(popup))
    return popup
  }
  window.bngVue.openOverhaulAngularPopup = open
  onBeforeUnmount(() => {
    disposed = true
    for (const popup of active) popup.return(false)
    active.clear()
    if (window.bngVue.openOverhaulAngularPopup === open) {
      if (previous === undefined) delete window.bngVue.openOverhaulAngularPopup
      else window.bngVue.openOverhaulAngularPopup = previous
    }
  })
}
