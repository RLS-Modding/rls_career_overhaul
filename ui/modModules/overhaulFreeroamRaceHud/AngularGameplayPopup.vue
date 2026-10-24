<template>
  <div ref="host" class="gameplay-popup-content" v-bng-ui-nav-scroll />
</template>
<script>
const layoutOwners = new WeakMap()
</script>
<script setup>
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { vBngUiNavScroll } from '@/common/directives'
import { setFocus } from '@/services/uiNavFocus'
const props = defineProps({ content: Object, anchor: Object, popupActive: Boolean })
const host = ref(null)
let observer
let contextObserver
const contexts = []
const backdrops = []
async function focusContent() {
  await nextTick()
  if (!props.popupActive || !host.value) return
  const target = host.value.querySelector('[bng-scoped-nav-autofocus]:not([disabled])')
    || host.value.querySelector('button:not([disabled]), input:not([disabled])')
  const active = document.activeElement
  if (target && (!host.value.contains(active) || active.disabled)) {
    setFocus(target)
  }
  // Angular can append rows after the Vue mount. Keep the chosen control in
  // view as that content settles, including a safe button below a long graph.
  if (host.value.contains(document.activeElement)) document.activeElement.scrollIntoView({ block: 'nearest' })
}
onMounted(() => {
  // Stock popup CSS clears focused controls' shadows. Preserve each control's
  // own paint before transferring it into that host.
  props.anchor.append(props.content)
  for (const control of props.content.querySelectorAll('button, input, select, textarea, [tabindex]')) {
    control.style.setProperty('--gameplay-original-shadow', getComputedStyle(control).boxShadow)
  }
  // Reproduce only the original layout ancestors inside the stock popup scope.
  // Transfer their paint too, so a nested backdrop covers the parent popup.
  const popupRoot = host.value.closest('.overhaul-popup')
  Object.assign(popupRoot.style, { position: 'fixed', inset: '0', width: '100vw', height: '100vh', pointerEvents: 'none' })
  let node = props.content
  for (let parent = props.anchor.parentElement; parent && !parent.id; parent = parent.parentElement) {
    const shell = parent.cloneNode(false)
    contexts.push([parent, shell])
    shell.append(node)
    // A sibling backdrop has Angular's existing mouse-dismiss listener. Move
    // that same node into the modal too; stock makes outside content inert.
    for (const sibling of [...parent.children]) {
      if (sibling !== props.anchor && sibling.hasAttribute('ng-click')
        && [...sibling.classList].some(name => name.endsWith('-backdrop'))) {
        backdrops.push([sibling, parent, sibling.nextSibling])
        shell.prepend(sibling)
      }
    }
    node = shell
  }
  const syncContext = () => {
    for (const [source, shell] of contexts) {
      shell.className = source.className.replace(/\bgameplay-popup-layout-source\b/g, '').trim()
      shell.style.cssText = source.style.cssText
    }
  }
  syncContext()
  for (const [source] of contexts) {
    layoutOwners.set(source, (layoutOwners.get(source) || 0) + 1)
    source.classList.add('gameplay-popup-layout-source')
  }
  contextObserver = new MutationObserver(syncContext)
  for (const [source] of contexts) contextObserver.observe(source, { attributes: true, attributeFilter: ['class', 'style'] })
  host.value.append(node)
  observer = new MutationObserver(focusContent)
  observer.observe(host.value, { childList: true, subtree: true, attributes: true, attributeFilter: ['disabled'] })
  focusContent()
})
onBeforeUnmount(() => {
  observer?.disconnect()
  contextObserver?.disconnect()
  for (const [backdrop, parent, next] of backdrops) {
    parent.insertBefore(backdrop, next?.parentNode === parent ? next : null)
  }
  for (const [source] of contexts) {
    const owners = layoutOwners.get(source) - 1
    if (owners) layoutOwners.set(source, owners)
    else { layoutOwners.delete(source); source.classList.remove('gameplay-popup-layout-source') }
  }
})
watch(() => props.popupActive, focusContent)
</script>
<style lang="scss">
.gameplay-popup-layout-source { background: transparent !important; box-shadow: none !important; }
.gameplay-popup-content {
  display: contents;
  .focus-visible {
    outline: 2px solid #fff;
    outline-offset: 2px;
    box-shadow: var(--gameplay-original-shadow, none);
  }
  .focus-visible::before { display: none !important; }
}
.popup-background.background-style-gameplay-original {
  background: transparent !important;
  backdrop-filter: none !important;
}
</style>
