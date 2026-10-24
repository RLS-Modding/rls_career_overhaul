// Remember an actual control for each in-screen view, including v-show swaps.
import { nextTick, onBeforeUnmount, onMounted, watch } from 'vue'
import useControls from '@/services/controls'
import { setFocus } from '@/services/uiNavFocus'

export function usePhoneViewFocus(root, view, pick = element => element) {
  const remembered = new Map()
  let ticket = 0
  let disposed = false
  const remember = event => {
    const target = event.target
    if (target?.dataset?.fk) remembered.set(view(), target.dataset.fk)
  }
  onMounted(() => root.value?.addEventListener('focusin', remember))
  async function focusView() {
    const current = ++ticket
    await nextTick()
    if (disposed || current !== ticket || !useControls().isControllerUsed) return
    const area = pick(root.value)
    if (!area) return
    const key = remembered.get(view())
    const controls = [...area.querySelectorAll('button, input, [bng-nav-item]')].filter(el =>
      !el.disabled && !el.closest('[inert], [hidden]') && el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden')
    const target = controls.find(el => el.dataset.fk === key) || controls.find(el => el.hasAttribute('bng-scoped-nav-autofocus')) || controls[0]
    if (target) setFocus(target)
  }
  watch(view, focusView, { flush: 'pre' })
  onBeforeUnmount(() => { disposed = true; ticket++; root.value?.removeEventListener('focusin', remember) })
  return focusView
}
