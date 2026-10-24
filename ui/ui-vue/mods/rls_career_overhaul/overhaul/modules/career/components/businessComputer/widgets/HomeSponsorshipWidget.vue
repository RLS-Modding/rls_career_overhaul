<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="rls-house home-widget sponsorship-widget" :class="{ 'home-widget--compact': compact }">
    <div class="widget-header">
      <h3>Sponsorship</h3>
      <span v-if="!compact && isRacingTeamLeague2 && bonusSummary" class="widget-sub">{{ bonusSummary }}</span>
    </div>
    <div v-if="!isRacingTeam" class="widget-content placeholder">
      <p class="placeholder-text">Sponsor tools are for the racing team business.</p>
    </div>
    <div v-else-if="!isLeague2" class="widget-content placeholder">
      <p class="placeholder-text">
        {{ compact ? "League 2 unlocks sponsor contracts." : lockedMessage }}
      </p>
    </div>
    <div v-else class="widget-content sponsor-body"  v-bng-ui-nav-scroll.force>
      <div class="sponsor-slots-line">
        Slots: <strong>{{ sponsorSlotsUsed }}</strong> / <strong>{{ sponsorSlotsMax }}</strong>
        <span v-if="compact && bonusSummary" class="sponsor-slots-line__bonus">{{ bonusSummary }}</span>
      </div>
      <div v-if="!compact && availableOffers.length" class="sponsor-section">
        <h4 class="sponsor-section__title">Available offers</h4>
        <div
          v-for="o in availableOffers"
          :key="o.id"
          class="sponsor-card sponsor-card--available"
        >
          <div class="sponsor-card__name">{{ o.name }}</div>
          <div v-if="o.focusLabel" class="sponsor-card__focus">{{ o.focusLabel }}</div>
          <div class="sponsor-card__bonuses">
            +{{ pct(o.bonusMoneyPercent) }} race payout, +{{ pct(o.bonusXpPercent) }} XP
          </div>
          <div class="sponsor-card__actions">
            <HouseButton variant="quiet" compact @click="onDecline(o.id)">
              Pass
            </HouseButton>
            <HouseButton
              compact
              :disabled="sponsorSlotsUsed >= sponsorSlotsMax"
              @click="onAccept(o.id)"
            >
              Sign
            </HouseButton>
          </div>
        </div>
      </div>
      <div v-else-if="!compact" class="sponsor-empty">
        No sponsor offer right now.
      </div>
      <div v-if="active.length" class="sponsor-section" :class="{ 'sponsor-section--compact': compact }">
        <h4 v-if="!compact" class="sponsor-section__title">Active contracts</h4>
        <template v-if="compact">
          <ul class="sponsor-compact-list">
            <li v-for="o in active" :key="o.id" class="sponsor-compact-row">
              <span class="sponsor-compact-row__name">{{ o.name }}</span>
              <span class="sponsor-compact-row__bonus">+{{ pct(o.bonusMoneyPercent) }}, +{{ pct(o.bonusXpPercent) }} XP</span>
            </li>
          </ul>
        </template>
        <template v-else>
          <div
            v-for="o in active"
            :key="o.id"
            class="sponsor-card sponsor-card--active"
          >
            <div class="sponsor-card__name">{{ o.name }}</div>
            <div class="sponsor-card__bonuses">
              +{{ pct(o.bonusMoneyPercent) }}, +{{ pct(o.bonusXpPercent) }} XP
            </div>
            <HouseButton variant="quiet" compact @click="onDrop(o.id)">
              End contract
            </HouseButton>
          </div>
        </template>
      </div>
      <p v-else-if="compact" class="sponsor-empty sponsor-empty--compact">No active sponsors.</p>
    </div>
  </div>
</template>

<script setup>
import { vBngUiNavScroll } from "@/common/directives"
import { computed } from "vue"
import { useBusinessRacingTeamStore } from "../../../stores/businessComputer/businessRacingTeamStore.js"
import { useBusinessSessionStore } from "../../../stores/businessComputer/businessSessionStore.js"
import { HouseButton } from "../../house/index.js"

defineProps({
  compact: { type: Boolean, default: false },
})

const racingTeamStore = useBusinessRacingTeamStore()
const sessionStore = useBusinessSessionStore()

const isRacingTeam = computed(() => sessionStore.hasCapability('sponsorships'))
const isLeague2 = computed(() => (sessionStore.businessData?.currentLeague || "") === "league2")
const isRacingTeamLeague2 = computed(() => isRacingTeam.value && isLeague2.value)

// League 2 name for the locked message. The invite acronym is only the League 2 one while the invite targets
// League 2, and Lua leaves it nil on levels without leagueNInviteAcronym, so fall back to the level's league
// display name and finally to plain text (never "undefined").
const league2Name = computed(() => {
  const inv = racingTeamStore.league2Invite || {}
  const target = inv.targetLeague
  const acronym = typeof inv.acronym === "string" ? inv.acronym.trim() : ""
  if (acronym && (!target || target === "league2")) return acronym
  const names = racingTeamStore.racingTeamLeagueDisplayNames || {}
  const display = typeof names.league2 === "string" ? names.league2.trim() : ""
  return display || ""
})

const leagueNumber = computed(() => {
  const m = /^league(\d+)$/i.exec(String(sessionStore.businessData?.currentLeague || "").trim())
  return m ? Number(m[1]) : 1
})

const lockedMessage = computed(() => {
  if (leagueNumber.value > 2) {
    return "Sponsor contracts are only offered while the team races in League 2."
  }
  const who = league2Name.value ? `${league2Name.value} (League 2)` : "League 2"
  return `Join ${who} from the Goals tab to unlock team sponsor contracts. Bonuses apply to proxy race payouts.`
})

const sp = computed(() => racingTeamStore.racingTeamSponsors || {})

const availableOffers = computed(() => {
  const a = sp.value.available
  return Array.isArray(a) ? a : []
})

const active = computed(() => {
  const a = sp.value.active
  return Array.isArray(a) ? a : []
})

const sponsorSlotsUsed = computed(() => Number(sp.value.sponsorSlotsUsed) || 0)
const sponsorSlotsMax = computed(() => Number(sp.value.sponsorSlots) || 2)

const bonusSummary = computed(() => {
  const m = sp.value.bonusMoneyTotal
  const x = sp.value.bonusXpTotal
  if ((m == null || m === 0) && (x == null || x === 0)) {
    return ""
  }
  return `Active: +${pct(m)} payout, +${pct(x)} XP`
})

function pct (v) {
  if (v == null || v === "") return "0%"
  const n = Number(v)
  if (!Number.isFinite(n)) return "0%"
  return `${Math.round(n * 100)}%`
}

async function onAccept (id) {
  await racingTeamStore.acceptRacingTeamSponsorOffer(id)
}

async function onDecline (id) {
  await racingTeamStore.declineRacingTeamSponsorOffer(id)
}

async function onDrop (id) {
  await racingTeamStore.dropRacingTeamSponsorActive(id)
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.home-widget {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.widget-header {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.3em;
  padding: 0.8em var(--inset) 0.55em;
  flex-shrink: 0;

  h3 {
    margin: 0;
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }
}

.widget-sub {
  font-size: 0.85em;
  font-weight: 600;
  color: var(--muted);
  line-height: 1.35;
}

.widget-content.placeholder {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  min-height: 0;
  padding: 1.25em var(--inset);
  text-align: center;
}

.placeholder-text {
  margin: 0;
  max-width: 26em;
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.45;
}

.sponsor-body {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.9em;
  min-height: 0;
  overflow-y: auto;
  padding: 0.15em var(--inset) var(--inset);
}

.sponsor-slots-line {
  font-size: 0.88em;
  font-weight: 600;
  color: var(--faint);

  strong {
    color: #fff;
    font-variant-numeric: tabular-nums;
  }
}

.sponsor-section__title {
  margin: 0 0 0.45em;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint);
}

.sponsor-empty {
  font-size: 0.9em;
  font-weight: 600;
  color: var(--faint);
  line-height: 1.4;
}

.sponsor-card {
  display: grid;
  gap: 0.25em;
  padding: 0.7em 0.8em 0.65em;
  margin-bottom: 0.4em;
  border-radius: var(--radius-panel);
  background: var(--panel);

  &:last-child {
    margin-bottom: 0;
  }
}

.sponsor-card__name {
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
}

.sponsor-card__focus {
  font-size: 0.8em;
  font-weight: 600;
  color: var(--faint);
}

.sponsor-card__bonuses {
  font-size: 0.88em;
  font-weight: 600;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}

.sponsor-card__actions {
  display: flex;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: var(--space-2);
  margin-top: 0.45em;
}

.sponsor-card--active > :deep(.house-button) {
  justify-self: end;
  margin-top: 0.3em;
}

.sponsor-compact-list {
  margin: 0;
  padding: 0;
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.sponsor-compact-row {
  display: grid;
  gap: 0.1em;
  padding: 0.4em 0.5em 0.35em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.sponsor-compact-row__name {
  font-size: 0.82em;
  font-weight: 700;
  color: #fff;
}

.sponsor-compact-row__bonus {
  font-size: 0.72em;
  font-weight: 600;
  color: var(--muted);
}

.sponsor-slots-line__bonus {
  margin-left: 0.6em;
  color: var(--muted);
}

.home-widget--compact {
  min-height: 0;
  height: auto;
  flex-shrink: 0;

  .widget-header {
    padding: 0.42em 0.55em;
    flex-direction: row;
    align-items: center;
    justify-content: space-between;
  }

  .widget-content.placeholder {
    padding: 0.5em 0.55em;
  }

  .placeholder-text {
    font-size: 0.78em;
  }

  .sponsor-body {
    padding: 0.2em 0.55em 0.5em;
    gap: 0.4em;
  }

  .sponsor-slots-line {
    font-size: 0.75em;
  }

  .sponsor-empty--compact {
    margin: 0;
    font-size: 0.75em;
  }
}
</style>
