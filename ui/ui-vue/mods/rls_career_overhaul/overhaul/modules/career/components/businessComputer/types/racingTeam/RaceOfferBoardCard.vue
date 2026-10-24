<template>
  <article class="rls-house race-offer-card" :class="{ 'race-offer-card--compact': compact }" @click.stop @mousedown.stop>
    <div class="race-offer-card__head">
      <strong class="race-offer-card__title">{{ title }}</strong>
      <span v-if="statusPill" class="pill race-offer-card__status" :class="statusPill.tone">{{ statusPill.text }}</span>
    </div>

    <div class="race-offer-card__meta">
      <span v-if="classBadge" class="pill race-offer-card__class">{{ classBadge }}</span>
      <span class="race-offer-card__meta-item">{{ lapsLabel }}</span>
      <span v-if="pwLabel" class="race-offer-card__meta-item">P/W {{ pwLabel }}</span>
      <span v-if="driverName" class="race-offer-card__driver">{{ driverName }}</span>
    </div>

    <div class="facts race-offer-card__prizes">
      <div v-for="(place, index) in places" :key="index" class="fact money">
        <span class="fact-key">{{ place.label }}</span>
        <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(place.value) }}</span>
        <span v-if="Number(place.xp) > 0" class="race-offer-card__xp">{{ formatXp(place.xp) }} XP</span>
      </div>
    </div>

    <div class="race-offer-card__actions">
      <HouseButton
        :variant="resolvedPrimaryVariant"
        :compact="compact"
        class="race-offer-card__primary"
        :disabled="primaryDisabled" :aria-disabled="declining" :data-fk="`offer-${offer.id}-accept`"
        @click.stop="!declining && $emit('accept')"
        @mousedown.stop
      >
        {{ primaryLabel }}
      </HouseButton>
      <HouseButton
        :variant="resolvedSecondaryVariant"
        :compact="compact"
        class="race-offer-card__secondary"
        :aria-disabled="declining" :data-fk="`offer-${offer.id}-decline`"
        @click.stop="!declining && $emit('decline')"
        @mousedown.stop
      >
        {{ secondaryLabel }}
      </HouseButton>
    </div>
  </article>
</template>

<script setup>
import { computed } from "vue"
import { formatSanctionedClassCompact, pwBucketX1000 } from "../../../../utils/sanctionedClassFormat"
import { HouseButton } from "../../../house/index.js"
import { BngIcon, icons } from "@/common/components/base"
import { formatWholeMoney } from "./racingTeamMoney.js"

const props = defineProps({
  offer: {
    type: Object,
    required: true
  },
  declining: {
    type: Boolean,
    default: false
  },
  driverName: {
    type: String,
    default: ""
  },
  primaryLabel: {
    type: String,
    default: "Accept"
  },
  secondaryLabel: {
    type: String,
    default: "Decline"
  },
  primaryDisabled: {
    type: Boolean,
    default: false
  },
  statusText: {
    type: String,
    default: ""
  },
  // Optional HouseButton variants. Empty = automatic: a board offer gets neutral Accept + quiet
  // Decline (many cards, no orange wall); a scheduled race (driverName set) gets an orange
  // Spectate once it is ready + quiet-danger Drop out.
  primaryVariant: {
    type: String,
    default: ""
  },
  secondaryVariant: {
    type: String,
    default: ""
  },
  compact: {
    type: Boolean,
    default: false
  }
})

defineEmits(["accept", "decline"])

const title = computed(() => props.offer?.raceLabel || props.offer?.raceName || "Race")

const isScheduled = computed(() => !!props.driverName)

const resolvedPrimaryVariant = computed(() => {
  if (props.primaryVariant) return props.primaryVariant
  return isScheduled.value && !props.primaryDisabled ? "primary" : "neutral"
})

const resolvedSecondaryVariant = computed(() => {
  if (props.secondaryVariant) return props.secondaryVariant
  return isScheduled.value ? "quiet-danger" : "quiet"
})

// Countdown as a short pill: accent while waiting, ok once a scheduled race can be spectated.
const statusPill = computed(() => {
  const status = String(props.statusText || "").trim()
  if (status) return { text: status, tone: "accent" }
  if (isScheduled.value && !props.primaryDisabled) return { text: "Ready", tone: "ok" }
  return null
})

const lapsLabel = computed(() => {
  const n = Math.max(1, Math.floor(Number(props.offer?.lapCount) || 3))
  return n === 1 ? "1 lap" : `${n} laps`
})

const classBadge = computed(() =>
  formatSanctionedClassCompact(props.offer?.hpBracketLabel, props.offer?.hpBracketBranch)
)

const pwLabel = computed(() => {
  const offer = props.offer
  if (!offer) return ""
  const branch = String(offer.hpBracketBranch || offer.hpBracketLabel || "").toLowerCase()
  if (branch.includes("open")) return "500+"
  const src = offer.classPwMin ?? offer.classPwMax
  const bucket = pwBucketX1000(src)
  return bucket != null ? String(bucket) : ""
})

const places = computed(() => {
  const offer = props.offer
  if (!offer) return []
  return [
    { label: "1st", value: offer.payoutFirst, xp: offer.xpFirst },
    { label: "2nd", value: offer.payoutSecond, xp: offer.xpSecond },
    { label: "3rd", value: offer.payoutThird, xp: offer.xpThird }
  ]
})

// number only: the template puts the game currency glyph in front
function formatMoney(n) {
  return formatWholeMoney(n)
}

function formatXp(n) {
  const v = Number(n)
  if (!Number.isFinite(v)) return "0"
  return Math.round(v).toLocaleString()
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.race-offer-card {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  min-width: 0;
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.race-offer-card__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.65em;
}

.race-offer-card__title {
  min-width: 0;
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
  letter-spacing: -0.01em;
  overflow-wrap: anywhere;
}

.race-offer-card__status {
  flex: 0 0 auto;
  max-width: 55%;
  white-space: normal;
  text-align: right;
  line-height: 1.15;
  font-variant-numeric: tabular-nums;
}

.race-offer-card__meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.3em 0.8em;
  margin-top: -0.2em;
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.race-offer-card__class {
  font-size: 0.9em;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.race-offer-card__driver {
  color: var(--muted);
  font-weight: 700;
}

.race-offer-card__prizes {
  column-gap: 0.9em;

  .fact-value {
    overflow: visible;
    text-overflow: clip;
    white-space: normal;
    font-variant-numeric: tabular-nums;
  }
}

.race-offer-card__xp {
  color: var(--faint);
  font-size: 0.74em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.race-offer-card__actions {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  margin-top: auto;
  padding-top: 0.15em;
}

.race-offer-card__secondary {
  flex: 0 0 auto;
}

.race-offer-card__primary {
  flex: 1 1 auto;
}

/* phone density */
.race-offer-card--compact {
  gap: var(--space-2);
  padding: 0.7em 0.75em;

  .race-offer-card__title {
    font-size: 1.05em;
  }

  .race-offer-card__meta {
    font-size: 0.78em;
    margin-top: -0.1em;
  }

  .race-offer-card__prizes .fact-value {
    font-size: 0.95em;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
