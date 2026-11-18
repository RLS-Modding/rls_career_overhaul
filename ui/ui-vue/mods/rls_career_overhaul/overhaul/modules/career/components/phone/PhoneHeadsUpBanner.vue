<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <Transition :name="skipLeaveAnimation ? 'phone-heads-up-instant' : 'phone-heads-up'" @after-leave="onAfterLeave">
    <article
      v-if="visible && current"
      ref="bannerRef"
      :key="current.id"
      class="rls-house phone-heads-up"
      :class="`phone-heads-up--${current.kind}`"
      :style="bannerStyle"
      role="button"
      tabindex="0"
      aria-live="polite"
      @click="onBannerClick"
      @keydown.enter.prevent="onBannerClick"
      @keydown.space.prevent="onBannerClick"
      @pointerdown="onPointerDown"
      @pointermove="onPointerMove"
      @pointerup="onPointerEnd"
      @pointercancel="onPointerCancel"
    >
      <PhoneNotificationContent :item="current" :more-count="extraCount" />
      <!-- Queued banners show as card edges peeking out under this one, as on an iOS stack. -->
      <span v-for="edge in Math.min(extraCount, 2)" :key="edge" class="phone-heads-up__edge" :class="`phone-heads-up__edge--${edge}`" aria-hidden="true"></span>
    </article>
  </Transition>
</template>



<script setup>

import { ref } from 'vue'

import { useRouter } from 'vue-router'

import {

  dismissCurrentHeadsUp,

  onPhoneHeadsUpAfterLeave,

  usePhoneHeadsUpNotification,

} from '../../composables/usePhoneHeadsUpNotification'

import { useHorizontalSwipeDismiss } from '../../composables/useHorizontalSwipeDismiss'

import PhoneNotificationContent from './PhoneNotificationContent.vue'
import { lua } from '@/bridge'
import { openNotification } from '../../utils/phoneNotificationRoutes'
import { removeNotificationCenterEntries } from '../../composables/usePhoneNotificationCenter'
import { navigatePhoneRoute } from '../../utils/phoneNavigation'



const router = useRouter()

const { visible, current, extraCount } = usePhoneHeadsUpNotification()



const bannerRef = ref(null)

const skipLeaveAnimation = ref(false)



const {

  swipeStyle: bannerStyle,

  suppressClick,

  resetSwipe,

  onPointerDown,

  onPointerMove,

  onPointerEnd,

  onPointerCancel,

} = useHorizontalSwipeDismiss({

  getElementEl: () => bannerRef.value,

  onDismiss: () => {

    skipLeaveAnimation.value = true

    dismissCurrentHeadsUp()

  },

})



function onAfterLeave() {

  skipLeaveAnimation.value = false

  resetSwipe()

  onPhoneHeadsUpAfterLeave()

}



async function onBannerClick(event) {

  if (suppressClick.value) {

    suppressClick.value = false

    return

  }

  event?.stopPropagation?.()

  const item = current.value

  if (!item) return

  dismissCurrentHeadsUp()

  // Once it opened, it has been seen: it leaves the Notification Center too.
  if (await openNotification(item, { lua, router, navigate: navigatePhoneRoute })) {

    removeNotificationCenterEntries([item.centerId])

  }
}

</script>



<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss' as *;
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-notification-text.scss' as phone-notif;

// Like an iOS banner, a floating card that drops in over the status bar. The card carries the house
// tokens (.rls-house) for its plate.
.phone-heads-up {
  @include phone-notif.phone-notif-card;
  position: absolute;
  top: 6px;
  left: 0;
  right: 0;
  z-index: 12;
  width: auto;
  margin: 0 8px;
  border-radius: 18px;
  box-shadow: 0 12px 28px rgba(0, 0, 0, 0.45);
  will-change: transform, opacity;
  // Controller focus is the phone-wide ring from overhaulFocus.scss (every [role="button"] in the phone).
}

.phone-heads-up-enter-active,
.phone-heads-up-leave-active {
  transition: transform 0.32s cubic-bezier(0.22, 1, 0.36, 1), opacity 0.24s ease;
}

.phone-heads-up-enter-from,
.phone-heads-up-leave-to {
  opacity: 0;
  transform: translateY(-120%);
}

.phone-heads-up-instant-leave-active {
  transition: none;
}

.phone-heads-up-instant-leave-to {
  opacity: 0;
}

@include phone-notif.phone-notif-stack-edges('.phone-heads-up__edge');

// Reduced motion: the banner fades in place instead of dropping down.
@media (prefers-reduced-motion: reduce) {
  .phone-heads-up-enter-active,
  .phone-heads-up-leave-active {
    transition: opacity 0.16s ease;
  }

  .phone-heads-up-enter-from,
  .phone-heads-up-leave-to {
    transform: none;
  }
}
</style>
