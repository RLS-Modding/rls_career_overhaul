<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->
<!--
  Notification Center: every notification the phone received, grouped per app like iOS. It opens by
  dragging down from the top of the phone (or tapping the status-bar island). A group with more than one
  notification shows as a stack (newest card, edges peeking out, "N more") until the player opens it.
  Tapping a card opens its app. Every card shows a cross in its corner on hover or focus, as on macOS: it
  clears that notification, or the whole app for a stack. An opened group also has its app's cross by its
  name, next to Show less. Clear all clears everything.
-->
<template>
  <div ref="listEl" class="rls-house phone-notification-center">
    <template v-if="groups.length">
      <div class="nc-toolbar">
        <button type="button" class="nc-clear-all" @click="clearAll($event)">Clear all</button>
      </div>
      <TransitionGroup tag="div" name="nc-group" class="nc-groups">
        <section v-for="group in groups" :key="group.key" class="nc-group" :data-group="group.key" :aria-label="group.name">
          <div class="nc-group__head">
            <span class="nc-group__name">{{ group.name }}</span>
            <span v-if="isStacked(group)" class="nc-group__more">{{ group.items.length - 1 }} more</span>
            <template v-if="isExpanded(group)">
              <button type="button" class="nc-group__less" @click="collapse(group, $event)">Show less</button>
              <button type="button" class="nc-group__clear" :aria-label="`Clear ${group.name}`" @click="clearGroup(group, $event)">
                <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3l6 6M9 3l-6 6" /></svg>
              </button>
            </template>
          </div>
          <!-- Every card has its cross in its corner, over the time, shown while the card is hovered or focused. -->
          <div v-if="isStacked(group)" class="nc-row">
            <button
              type="button"
              class="nc-card"
              :data-card="group.key"
              :class="`nc-card--edges-${Math.min(group.items.length - 1, 2)}`"
              @click="expand(group, $event)"
            >
              <!-- Named by what it shows (the newest notification), then what a tap does. -->
              <PhoneNotificationContent :item="group.items[0]" :aside="receivedAgo(group.items[0].receivedAt, now)" />
              <span class="nc-spoken">, {{ group.items.length }} notifications, show all</span>
              <span v-for="edge in Math.min(group.items.length - 1, 2)" :key="edge" class="nc-card__edge" :class="`nc-card__edge--${edge}`" aria-hidden="true"></span>
            </button>
            <button type="button" class="nc-row__clear" data-phone-reveal :aria-label="`Clear ${group.name}`" @click="clearGroup(group, $event)">
              <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3l6 6M9 3l-6 6" /></svg>
            </button>
          </div>
          <template v-else>
            <div v-for="item in group.items" :key="item.id" class="nc-row">
              <button type="button" class="nc-card" :data-card="item.id" @click="openItem(item, $event)">
                <PhoneNotificationContent :item="item" :aside="receivedAgo(item.receivedAt, now)" />
              </button>
              <button type="button" class="nc-row__clear" data-phone-reveal :aria-label="`Clear ${clearLabel(item, group)}`" @click="clearItem(item, $event)">
                <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3l6 6M9 3l-6 6" /></svg>
              </button>
            </div>
          </template>
        </section>
      </TransitionGroup>
    </template>
    <div v-else class="nc-empty" tabindex="-1">
      <p class="nc-empty__title">No notifications</p>
      <p class="nc-empty__hint">Notifications from this session show here until you open or clear them.</p>
    </div>
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import PhoneNotificationContent from '../../components/phone/PhoneNotificationContent.vue'
import {
  clearNotificationCenter,
  removeNotificationCenterEntries,
  takeNotificationCenterReturn,
  usePhoneNotificationCenter,
} from '../../composables/usePhoneNotificationCenter'
import { closeFinishedGroups, groupByApp, receivedAgo } from '../../utils/phoneNotificationPresentation'
import { loadNotificationApps, notificationApp, notificationAppKey } from '../../utils/phoneNotificationApps'
import { getNotificationInstallAppId, openNotification, resolveNotificationRoute } from '../../utils/phoneNotificationRoutes'
import { navigatePhoneRoute } from '../../utils/phoneNavigation'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { retireHeadsUpNotifications } from '../../composables/usePhoneHeadsUpNotification'

const router = useRouter()
const { entries } = usePhoneNotificationCenter()

const groups = computed(() => groupByApp(entries.value, notificationAppKey).map(group => ({
  ...group,
  name: notificationApp(group.items[0]).name,
})))

const listEl = ref(null)
const expanded = reactive(new Set())
const isExpanded = group => group.items.length > 1 && expanded.has(group.key)
const isStacked = group => group.items.length > 1 && !expanded.has(group.key)
watch(groups, list => closeFinishedGroups(expanded, list))
// Opening a stack puts keyboard or controller focus on its first card, closing it on the stack again, so
// the player keeps their place (a pointer click leaves focus alone, as with a clear).
async function focusGroup(event, key) {
  if (!event || event.detail !== 0 || !listEl.value) return
  await nextTick()
  const section = [...listEl.value.querySelectorAll('.nc-group')].find(element => element.dataset.group === key)
  section?.querySelector('button.nc-card')?.focus()
}
function expand(group, event) {
  expanded.add(group.key)
  return focusGroup(event, group.key)
}
function collapse(group, event) {
  expanded.delete(group.key)
  return focusGroup(event, group.key)
}

// The cards on screen, in order: a stack is one card (keyed by its group), an opened group one per notification.
const cardKeys = computed(() => groups.value.flatMap(group => (isStacked(group) ? [group.key] : group.items.map(item => item.id))))

// A clear takes away the button that had focus. When it came from a keyboard or controller (a click with
// no pointer, detail 0), focus goes to the card now in its place, or the last one, so it is never lost; a
// mouse clear leaves focus alone, so no other card shows its cross. The place comes from the list itself,
// so a group still fading out is never picked.
async function keepFocusAfterClear(event, fromKey) {
  if (!event || event.detail !== 0 || !listEl.value) return
  const index = Math.max(0, cardKeys.value.indexOf(fromKey))
  await nextTick()
  const keys = cardKeys.value
  if (!keys.length) {
    // Nothing left: the empty state holds focus, so it stays on this screen.
    listEl.value.querySelector('.nc-empty')?.focus()
    return
  }
  const key = keys[Math.min(index, keys.length - 1)]
  ;[...listEl.value.querySelectorAll('button.nc-card')].find(card => card.dataset.card === key)?.focus()
}

function clearGroup(group, event) {
  const keep = keepFocusAfterClear(event, isStacked(group) ? group.key : group.items[0]?.id)
  expanded.delete(group.key)
  removeNotificationCenterEntries(group.items.map(item => item.id))
  return keep
}

function clearItem(item, event) {
  const keep = keepFocusAfterClear(event, item.id)
  removeNotificationCenterEntries([item.id])
  return keep
}

function clearAll(event) {
  const keep = keepFocusAfterClear(event, null)
  clearNotificationCenter()
  return keep
}

// Tapping a notification takes it off the list once it has opened its app, like on iOS. One with
// nowhere to go is simply read and cleared; one whose app failed to install or open stays for later.
async function openItem(item, event) {
  const hasDestination = !!(resolveNotificationRoute(item) || getNotificationInstallAppId(item))
  if (!hasDestination) {
    // Read and cleared in place: focus stays in the list, as with a clear.
    const keep = keepFocusAfterClear(event, item.id)
    removeNotificationCenterEntries([item.id])
    return keep
  }
  if (await openNotification(item, { lua, router, navigate: navigatePhoneRoute })) removeNotificationCenterEntries([item.id])
}

// Back returns to the screen the Notification Center was pulled down over (or Settings).
usePhoneScreen({
  onBack: () => {
    const target = takeNotificationCenterReturn()
    if (!target) return false
    returnTo(target)
    return true
  },
})

// The phone navigates by name and params; once the screen is back, its query and hash (a Guide topic and
// section) are put back the way that screen sets them itself.
async function returnTo(target) {
  const result = await navigatePhoneRoute(router, { name: target.name, params: target.params })
  if (result?.success === false || (!Object.keys(target.query).length && !target.hash)) return
  const restore = () => router.replace({ query: target.query, hash: target.hash })
  if (router.currentRoute.value.name === target.name) return restore()
  const stop = watch(() => router.currentRoute.value.name, name => {
    if (name !== target.name) return
    stop()
    restore()
  })
  window.setTimeout(stop, 3000)
}

// "4m ago" stays current while the list is open.
const now = ref(Date.now())

// The card's title; when another card in the group shares it, a few words of the message too ("New Order,
// Burger Barn"), so the clear buttons read apart without reading out a whole message.
const LABEL_MESSAGE_WORDS = 6
function clearLabel(item, group) {
  const title = item.title || group.name
  const sharesTitle = group.items.some(other => other !== item && other.title === item.title)
  if (!sharesTitle || !item.message) return title
  return `${title}, ${item.message.split(/\s+/).slice(0, LABEL_MESSAGE_WORDS).join(' ')}`
}
let clock = null
onMounted(() => {
  loadNotificationApps()
  retireHeadsUpNotifications()
  clock = window.setInterval(() => { now.value = Date.now() }, 30000)
})
onBeforeUnmount(() => {
  if (clock) window.clearInterval(clock)
  // Left by opening a notification: the origin is spent, so a later visit never jumps back to it.
  takeNotificationCenterReturn()
})
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss' as *;
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-notification-text.scss' as phone-notif;

.phone-notification-center {
  --status-bar: var(--phone-status-bar-height, 36px);
  display: flex;
  flex-direction: column;
  gap: 10px;
  height: 100%;
  padding: calc(var(--status-bar) + var(--phone-status-bar-content-gap, 6px)) 12px 16px;
  overflow-y: auto;
  overflow-x: hidden;
  // The phone's own screen colour shows through; cards sit a step lighter on it.
  // Scrolled cards fade out before they reach the status bar instead of sliding under it.
  // Fully clear again where the list starts, so nothing at rest sits in the fade.
  mask-image: linear-gradient(to bottom, transparent calc(var(--status-bar) - 6px), #000 calc(var(--status-bar) + var(--phone-status-bar-content-gap, 6px)));

  // A thin, quiet native-style scrollbar instead of the phone's orange one: the house .scroll thumb
  // colours, narrower, and grey while dragged too.
  &::-webkit-scrollbar { width: 4px; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.22);
  }
  &::-webkit-scrollbar-thumb:hover,
  &::-webkit-scrollbar-thumb:active { background: rgba(255, 255, 255, 0.38); }
}

.nc-toolbar {
  display: flex;
  justify-content: flex-end;
}

.nc-clear-all,
.nc-group__less {
  appearance: none;
  border: 0;
  border-radius: 999px;
  padding: 5px 12px 4px;
  background: var(--panel-2);
  color: inherit;
  font: inherit;
  font-size: 11px;
  font-weight: 700;
  cursor: pointer;
}

.nc-groups {
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.nc-group {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.nc-group__head {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 26px;
  padding: 0 4px;
}

.nc-group__more {
  flex: none;
  font-size: 11px;
  font-weight: 600;
  color: var(--faint);
  font-variant-numeric: tabular-nums;
}

.nc-group__name {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
  font-weight: 600;
  color: var(--faint);
}

.nc-group__clear,
.nc-row__clear {
  appearance: none;
  display: grid;
  place-items: center;
  width: 26px;
  height: 26px;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: var(--panel-2);
  color: var(--muted);
  cursor: pointer;

  svg {
    width: 10px;
    height: 10px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.8;
    stroke-linecap: round;
  }
}

.nc-row {
  position: relative;
}

// The card's cross shows over its time while the card is hovered or focused, in line with an opened
// group's app cross.
.nc-row__clear {
  position: absolute;
  top: 7px;
  right: 4px;
  opacity: 0;
  // Not tappable while unseen, so a tap on the card's time opens the card instead of clearing it.
  pointer-events: none;
  transition: opacity 0.12s ease;

  // A slightly larger hit area than the 26 px circle, without drawing a larger one.
  &::before {
    content: '';
    position: absolute;
    inset: -3px;
  }
}

.nc-row:hover,
.nc-row:focus-within {
  .nc-row__clear { opacity: 1; pointer-events: auto; }
  :deep(.phone-notification__note) { visibility: hidden; }
}

.nc-card {
  @include phone-notif.phone-notif-card;
  appearance: none;
  position: relative;
  display: block;
  border-radius: 18px;
  background: var(--panel-2);
  color: inherit;
  font: inherit;
  text-align: left;
}

.nc-spoken {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
  white-space: nowrap;
}

.nc-card--edges-1 { margin-bottom: 7px; }
.nc-card--edges-2 { margin-bottom: 13px; }

@include phone-notif.phone-notif-stack-edges('.nc-card__edge');

.nc-empty {
  flex: 1;
  display: grid;
  align-content: center;
  justify-items: center;
  gap: 4px;
  text-align: center;
}

.nc-empty__title {
  margin: 0;
  font-size: 15px;
  font-weight: 700;
}

.nc-empty__hint {
  margin: 0;
  font-size: 12px;
  color: var(--faint);
}

.nc-group-enter-active,
.nc-group-leave-active {
  transition: opacity 0.2s ease;
}

.nc-group-enter-from,
.nc-group-leave-to {
  opacity: 0;
}

// Last, so it wins over the transitions above.
@media (prefers-reduced-motion: reduce) {
  .nc-row__clear,
  .nc-group-enter-active,
  .nc-group-leave-active { transition: none; }
}
</style>
