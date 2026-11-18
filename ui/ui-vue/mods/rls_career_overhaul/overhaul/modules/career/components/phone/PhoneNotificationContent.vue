<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->
<!--
  The inside of one phone notification (open- and closed-phone banners, Notification Center), laid out like
  iOS: the sending app's own icon, a bold title with a quiet note on the right ("2 more", "4m ago"), the
  message and a one-line footer. Money and signed percentages are coloured; text is shown as sent.
  Render it inside the card element that carries .rls-house, which supplies the house tokens. It holds
  only phrasing elements, so the card can be a <button>.
-->
<template>
  <span class="phone-notification" :class="status.tone && `phone-notification--${status.tone}`">
    <span class="phone-notification__icon" :style="iconStyle" aria-hidden="true">
      <img v-if="iconImage" :src="iconImage" alt="" draggable="false" @error="imageFailed = true" />
      <BngIcon v-else :type="app.app?.icon || status.icon" />
    </span>
    <span class="phone-notification__text">
      <span class="phone-notification__head">
        <span class="phone-notification__title" :class="{ 'phone-notification__title--promoted': lines.promoted }">
          <span v-if="status.label" class="phone-notification__spoken">{{ status.label }}: </span>
          <template v-if="item.presentationSimple">{{ app.name }}</template>
          <MoneyText v-else :text="lines.title" />
        </span>
        <span v-if="note" class="phone-notification__note">{{ note }}</span>
      </span>
      <span v-if="!item.presentationSimple" class="phone-notification__spoken">{{ app.name }}</span>
      <span v-if="lines.message" class="phone-notification__message"><MoneyText :text="lines.message" /></span>
      <span v-if="footer.length" class="phone-notification__footer">
        <template v-for="(value, valueIndex) in footer" :key="valueIndex">
          <span
            v-for="(part, partIndex) in value"
            :key="partIndex"
            class="phone-notification__part"
            :class="[
              part.money ? `phone-notification__money phone-notification__money--${part.money}` : 'phone-notification__part--text',
              { 'phone-notification__part--new-value': valueIndex > 0 && partIndex === 0 },
            ]"
          >{{ part.text }}</span>
        </template>
      </span>
    </span>
  </span>
</template>

<script setup>
import { computed, h, ref, watch } from 'vue'
import { BngIcon } from '@/common/components/base'
import {
  footerValues,
  moneySegments,
  notificationLines,
  notificationStatus,
} from '../../utils/phoneNotificationPresentation'
import { notificationApp } from '../../utils/phoneNotificationApps'

const props = defineProps({
  item: { type: Object, required: true },
  // Notifications stacked behind this one; shown as "2 more".
  moreCount: { type: Number, default: 0 },
  // A note for the right of the title when nothing is stacked, e.g. "4m ago" in the Notification Center.
  aside: { type: String, default: '' },
})

const status = computed(() => notificationStatus(props.item))
const lines = computed(() => notificationLines(props.item))
// Footer values, each split into text and money parts. Every part is its own item on the one footer
// line: text parts give way to an ellipsis, money parts keep their full width.
const footer = computed(() => footerValues(lines.value.footer).map(moneySegments))
const note = computed(() => (props.moreCount > 0 ? `${props.moreCount} more` : props.aside))

const app = computed(() => notificationApp(props.item))
const imageFailed = ref(false)
watch(() => app.value.app?.iconImage, () => { imageFailed.value = false })
const iconImage = computed(() => (!imageFailed.value && app.value.app?.iconImage) || '')
// The app's own tile colours behind its glyph, where its manifest sets them; otherwise the plain house tile.
const iconStyle = computed(() => {
  const manifest = app.value.app
  if (iconImage.value || !manifest) return {}
  return { ...(manifest.color ? { background: manifest.color } : {}), ...(manifest.iconColor ? { color: manifest.iconColor } : {}) }
})

// Plain text with each money run wrapped so it can take the gain, loss or amount colour.
const MoneyText = props => moneySegments(props.text).map(segment => segment.money
  ? h('span', { class: ['phone-notification__money', `phone-notification__money--${segment.money}`] }, segment.text)
  : segment.text)
MoneyText.props = { text: { type: String, default: '' } }
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-notification-text.scss' as phone-notif;

.phone-notification {
  display: flex;
  align-items: center;
  gap: 11px;
  width: 100%;
  min-width: 0;
  font-size: 12px;
  line-height: 1.3;
  text-align: left;
}

// The app icon, as on the home screen: its own image, or its colour tile and glyph.
.phone-notification__icon {
  flex: none;
  display: grid;
  place-items: center;
  width: 34px;
  height: 34px;
  border-radius: 9px;
  overflow: hidden;
  background: var(--panel-2);
  color: var(--muted);
  font-size: 19px;
  --bng-icon-color: currentColor;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.phone-notification__text {
  @include phone-notif.phone-notif-body;
  gap: 1px;
}

.phone-notification__head {
  display: flex;
  align-items: baseline;
  gap: 8px;
  width: 100%;
  min-width: 0;
}

.phone-notification__title {
  @include phone-notif.phone-notif-clamped-text(3);
  flex: 1 1 0;
  min-width: 0;
  font-size: 13px;
  font-weight: 700;
  line-height: 1.25;
}

// A message standing in for the title reads as body text, so it doesn't outweigh real titles.
.phone-notification__title--promoted { font-weight: 600; }

// Only warnings and problems tint their title; every other kind reads as plain news.
.phone-notification--warn .phone-notification__title { color: var(--warn); }
.phone-notification--bad .phone-notification__title { color: var(--bad); }

.phone-notification__note {
  flex: none;
  font-size: 11px;
  font-weight: 600;
  color: var(--faint);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

// Words for screen readers only: the status before the title and the app after it.
.phone-notification__spoken {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
  white-space: nowrap;
}

.phone-notification__message {
  @include phone-notif.phone-notif-clamped-text(2);
  font-weight: 500;
  color: var(--muted);
}

// Footer: always one line. Text parts shrink with an ellipsis when space runs out; money parts never
// do, so an amount after a long reason stays readable. Values that were joined with "·" sit apart.
.phone-notification__footer {
  @include phone-notif.phone-notif-source-line;
  display: flex;
  width: 100%;
  margin-top: 1px;
  font-size: 11px;
  font-weight: 600;
  color: var(--faint);
}

// pre keeps the spaces at the edges of a part ("+18%" then " pay"), which flex items would drop.
.phone-notification__part {
  flex: none;
  white-space: pre;
}

.phone-notification__part--text {
  flex: 0 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}

.phone-notification__part--new-value { margin-left: 10px; }

// MoneyText renders these spans without this file's scope id, hence :deep.
.phone-notification :deep(.phone-notification__money) {
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  color: var(--money);
}

.phone-notification :deep(.phone-notification__money--gain) { color: var(--ok); }
.phone-notification :deep(.phone-notification__money--loss) { color: var(--bad); }
</style>
