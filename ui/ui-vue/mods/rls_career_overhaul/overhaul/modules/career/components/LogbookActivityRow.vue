<template>
  <button type="button" class="career-logbook-item activity-row" :class="{ selected }" :aria-expanded="selected" bng-nav-item
    v-bng-sound-class="'bng_click_generic_small'">
    <BngIcon class="activity-icon" :type="icon" />
    <span class="activity-copy">
      <span class="activity-category">{{ $ctx_t(entry.cardTypeLabel) }}<span v-if="entry.isNew" class="activity-unread">{{ newLabel }}</span></span>
      <span class="activity-title" :title="$ctx_t(entry.title)">{{ $ctx_t(entry.title) }}</span>
      <span class="activity-time" v-bng-relative-time="entry.time"></span>
    </span>
    <span v-if="money !== undefined" class="activity-value" :class="{ gain: money > 0, loss: money < 0 }">{{ formattedMoney }}</span>
  </button>
</template>

<script setup>
import { computed } from "vue"
import { $translate } from "@/services"
import { moneyValue, formatMoney } from "../utils/logbookPresentation.js"
import { BngIcon, icons } from "@/common/components/base"
import { vBngRelativeTime, vBngSoundClass } from "@/common/directives"
const props = defineProps({ entry: { type: Object, required: true }, selected: Boolean })
const newLabel = computed(() => { const text = $translate.instant("ui.common.new"); return text === "ui.common.new" ? "New" : text })
const icon = computed(() => icons[props.entry.icon] || icons.checkmark)
const money = computed(() => moneyValue(props.entry))
const formattedMoney = computed(() => formatMoney(money.value))
</script>

<style scoped lang="scss">
.activity-row {
  display: flex;
  width: 100%;
  gap: 0.75em;
  align-items: center;
  padding: 0.75em 0.85em;
  margin: 0;
  border: 0;
  border-radius: var(--radius-control);
  background: transparent;
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
}
.activity-row:hover:not(.selected) {
  background: var(--panel-hover);
}
.activity-row.focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: -2px;
}
.activity-icon {
  font-size: 1.4em;
  color: var(--muted);
}
.activity-copy {
  flex: 1;
  min-width: 0;
  overflow-wrap: anywhere;
}
.activity-category {
  display: flex;
  gap: 0.5em;
  color: var(--muted);
  font-size: 0.78em;
}
.activity-title {
  display: block;
  font-weight: 700;
  font-size: 1.15em;
  line-height: 1.25;
  margin: 0.2em 0;
}
.activity-time {
  display: block;
  color: var(--faint);
  font-size: 0.8em;
}
.activity-value {
  align-self: flex-start;
  font-weight: 800;
  font-size: 0.85em;
  font-variant-numeric: tabular-nums;
}
.gain {
  color: var(--ok);
}
.loss {
  color: var(--bad);
}
.activity-unread {
  color: var(--accent-soft);
}
</style>
