// Keep the original input and its mouse/keyboard handlers. Consume stock menu
// events locally while editing, so B exits the field before its containing form.
const editors = new WeakMap()
export const vPhoneNumber = {
  mounted(element, binding) {
    const editor = { step: binding.value, editing: false, axis: 0 }
    const finish = () => { editor.editing = false; editor.axis = 0; element.removeAttribute('data-phone-number-editing') }
    editor.onBlur = finish
    editor.onNav = event => {
      const { name, value } = event.detail || {}
      if (name === 'ok') {
        event.stopImmediatePropagation()
        if (value) {
          editor.editing = !editor.editing
          if (editor.editing) element.setAttribute('data-phone-number-editing', '')
          else finish()
        }
        return
      }
      if (!editor.editing) return
      if (name === 'back') {
        event.stopImmediatePropagation()
        if (value) finish()
        return
      }
      if (!['focus_l', 'focus_r', 'focus_u', 'focus_d', 'focus_lr', 'focus_ud'].includes(name)) return
      event.stopImmediatePropagation()
      let direction = name === 'focus_l' ? -1 : name === 'focus_r' ? 1 : 0
      if (name === 'focus_lr') {
        const axis = Math.abs(value) > 0.5 ? Math.sign(value) : 0
        direction = axis && axis !== editor.axis ? axis : 0
        editor.axis = axis
      }
      if (!value || !direction || element.disabled || element.readOnly) return
      const step = Number(editor.step) || Number(element.step) || 1
      const min = element.min === '' ? 0 : Number(element.min)
      const max = element.max === '' ? Number.MAX_SAFE_INTEGER : Number(element.max)
      const delta = direction * step
      element.value = String(Number(Math.max(min, Math.min(max, (Number(element.value) || 0) + delta)).toFixed(8)))
      element.dispatchEvent(new Event('input', { bubbles: true }))
      element.dispatchEvent(new Event('change', { bubbles: true }))
    }
    editors.set(element, editor)
    element.addEventListener('ui_nav', editor.onNav)
    element.addEventListener('blur', editor.onBlur)
  },
  updated(element, binding) { editors.get(element).step = binding.value },
  beforeUnmount(element) {
    const editor = editors.get(element)
    element.removeEventListener('ui_nav', editor.onNav)
    element.removeEventListener('blur', editor.onBlur)
    editor.onBlur()
    editors.delete(element)
  },
}
