<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>

  <Transition :name="skipLeaveAnimation ? 'phone-heads-up-instant' : 'phone-heads-up'" @after-leave="onAfterLeave">

    <article

      v-if="visible && current"

      ref="bannerRef"

      :key="current.id"

      class="phone-heads-up"

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

      <div class="phone-heads-up__rail" aria-hidden="true"></div>

      <div class="phone-heads-up__body">

        <template v-if="current.presentationSimple">

          <span class="phone-heads-up__title phone-heads-up__title--simple">{{ current.source }}</span>

        </template>

        <template v-else-if="current.kind === 'racing'">

          <span class="phone-heads-up__source">{{ current.source }}</span>

          <span class="phone-heads-up__title">{{ current.title || 'Race Ready' }}</span>

          <span v-if="current.subline" class="phone-heads-up__message">{{ current.subline }}</span>

        </template>

        <template v-else>

          <span class="phone-heads-up__source">{{ current.source }}</span>

          <span class="phone-heads-up__title">{{ displayTitle }}</span>

          <span v-if="displayMessage" class="phone-heads-up__message">{{ displayMessage }}</span>

        </template>

      </div>

      <span v-if="extraCount > 0" class="phone-heads-up__stack">+{{ extraCount }}</span>

    </article>

  </Transition>

</template>



<script setup>

import { computed, ref } from 'vue'

import { useRouter } from 'vue-router'

import {

  dismissCurrentHeadsUp,

  onPhoneHeadsUpAfterLeave,

  usePhoneHeadsUpNotification,

} from '../../composables/usePhoneHeadsUpNotification'

import { useHorizontalSwipeDismiss } from '../../composables/useHorizontalSwipeDismiss'

import { lua } from '@/bridge'
import { resolveNotificationRoute, installAppFromNotification } from '../../utils/phoneNotificationRoutes'
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



const displayTitle = computed(() => {

  const item = current.value

  if (!item) return ''

  const title = String(item.title || '').trim()

  const message = String(item.message || '').trim()

  if (title && title !== message) return title

  return message || title || 'Notification'

})



const displayMessage = computed(() => {

  const item = current.value

  if (!item) return ''

  const title = String(item.title || '').trim()

  const message = String(item.message || '').trim()

  if (title && message && title !== message) return message

  if (item.meta) return item.meta

  return ''

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

  await installAppFromNotification(lua, item)

  const route = resolveNotificationRoute(item)

  if (route) {


    navigatePhoneRoute(router, route)

  }

}

</script>



<style scoped lang="scss">

@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-notification-text.scss' as phone-notif;



.phone-heads-up {

  position: absolute;

  top: 36px;

  left: 0;

  right: 0;

  z-index: 12;

  display: flex;

  align-items: stretch;

  gap: 0;

  margin: 0 8px;

  padding: 10px 12px 10px 0;

  border-radius: 0 0 14px 14px;

  background: rgba(12, 14, 18, 0.94);


  border: 1px solid rgba(255, 255, 255, 0.12);

  border-top: none;

  box-shadow: 0 10px 24px rgba(0, 0, 0, 0.38);

  color: #f7f1e8;

  pointer-events: auto;

  cursor: pointer;

  overflow: hidden;

  will-change: transform, opacity;



  &.focus-visible {

    outline: 2px solid rgba(125, 211, 252, 0.55);

    outline-offset: 1px;

  }

}



.phone-heads-up__rail {

  width: 4px;

  flex-shrink: 0;

  margin: 2px 10px 2px 0;

  border-radius: 0 4px 4px 0;

  background: #7dd3fc;

}



.phone-heads-up--success .phone-heads-up__rail,

.phone-heads-up--rep .phone-heads-up__rail {

  background: #69d48f;

}



.phone-heads-up--warning .phone-heads-up__rail,

.phone-heads-up--invite .phone-heads-up__rail,

.phone-heads-up--racing .phone-heads-up__rail {

  background: #ffc978;

}



.phone-heads-up--error .phone-heads-up__rail {

  background: #ff8a8a;

}



.phone-heads-up__body {

  @include phone-notif.phone-notif-body;

}



.phone-heads-up__source {

  @include phone-notif.phone-notif-source-line;

  font-size: 9px;

  font-weight: 800;

  letter-spacing: 0.06em;

  text-transform: uppercase;

  color: rgba(247, 241, 232, 0.55);

}



.phone-heads-up__title {

  @include phone-notif.phone-notif-clamped-text(3);

  font-size: 13px;

  font-weight: 700;

  color: #f8fafc;

}



.phone-heads-up__title--simple {

  -webkit-line-clamp: 2;

}



.phone-heads-up__message {

  @include phone-notif.phone-notif-clamped-text(2);

  font-size: 11px;

  font-weight: 500;

  color: rgba(226, 232, 240, 0.82);

}



.phone-heads-up__stack {

  flex-shrink: 0;

  align-self: center;

  margin-left: 8px;

  padding: 2px 7px;

  border-radius: 999px;

  background: rgba(255, 255, 255, 0.12);

  border: 1px solid rgba(255, 255, 255, 0.14);

  font-size: 10px;

  font-weight: 800;

  letter-spacing: 0.02em;

  color: #fff;

}



.phone-heads-up-enter-active,

.phone-heads-up-leave-active {

  transition: transform 0.32s cubic-bezier(0.22, 1, 0.36, 1), opacity 0.24s ease;

}



.phone-heads-up-enter-from,

.phone-heads-up-leave-to {

  opacity: 0;

  transform: translateY(-100%);

}



.phone-heads-up-instant-leave-active {

  transition: none;

}



.phone-heads-up-instant-leave-to {

  opacity: 0;

}

</style>
