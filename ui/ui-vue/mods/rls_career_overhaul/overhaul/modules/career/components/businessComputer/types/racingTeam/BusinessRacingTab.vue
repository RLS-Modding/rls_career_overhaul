<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!--
  Map of businessComputer/types/racingTeam/BusinessRacingTab.vue
  Racing tab owns league and scheduled-race selections, confirmations and busy guards.
  Read schedule clock and selectors, fleet eligibility, league actions, scheduled actions, then lifecycle.
  Race offers remain in RaceOfferBoardCard; the store owns persisted business and race state.
-->
<template>
  <div ref="tabRef" class="rls-house racing-tab" :class="{ 'racing-tab--phone': layout === 'phone' }">
    <header class="tab-head">
      <h2 class="block-title">{{ raceOffersScreenTitle || "Races" }}</h2>
      <p class="hint">{{ tabHint }}</p>
    </header>

    <section v-if="showManagerAutomationPanel" class="panel manager-panel">
      <div class="manager-head">
        <span class="caption">Manager automation</span>
        <span v-if="managerBookingTimerText" class="pill manager-countdown">{{ managerBookingTimerText }}</span>
      </div>
      <HouseSwitch
        row
        class="manager-switch"
        :model-value="managerAutoAssign"
        :aria-disabled="managerAutoToggleBusy"
        @update:model-value="onManagerAutoSwitch"
      >
        {{ layout === 'phone' ? 'Auto-assign' : 'Auto-assign sanctioned offers' }}
      </HouseSwitch>
      <div v-if="managerSkillLevel >= 2" class="manager-interval">
        <span class="hint">Automation interval</span>
        <div class="seg bar manager-interval-seg" role="radiogroup" aria-label="Automation interval">
          <button
            v-for="opt in managerIntervalOptions"
            :key="opt.value"
            type="button"
            :class="{ active: managerIntervalModel === opt.value }"
            :aria-disabled="managerIntervalBusy"
            :aria-checked="managerIntervalModel === opt.value"
            role="radio"
            @mousedown.stop
            @click.stop="selectManagerInterval(opt.value)"
          >
            {{ opt.shortLabel }}
          </button>
        </div>
      </div>
      <p v-if="layout !== 'phone'" class="hint manager-hint">
        When on, books idle drivers from the offer board. Spectate alerts need Shop App.
      </p>
    </section>

    <div v-if="racingTeamProxyArmed" class="panel proxy-banner">
      <template v-if="isLeague1">
        <p class="proxy-banner__text">Team race armed. Go to the grid.</p>
        <HouseButton
          variant="primary"
          :compact="layout === 'phone'"
          :aria-disabled="raceFromGarageBusy"
          @click.stop="onRaceFromGarage"
          @mousedown.stop
        >
          Go to grid
        </HouseButton>
      </template>
      <template v-else>
        <p class="proxy-banner__text">Spectate from Scheduled races when ready.</p>
      </template>
    </div>

    <template v-if="!selectedOffer">
      <section v-if="driversWithScheduledRaces.length" class="races-section">
        <div class="section-head">
          <span class="caption">Scheduled races</span>
          <span class="pill count">{{ driversWithScheduledRaces.length }}</span>
        </div>
        <ul v-if="layout === 'phone'" class="offers-list">
          <li v-for="row in driversWithScheduledRaces" :key="row.key" class="offer-row">
            <RaceOfferBoardCard
              compact
              :offer="row.offer"
              :driver-name="row.driverName"
              :declining="armScheduledBusyId === row.driverId || dropScheduledBusyId === row.driverId"
              :primary-disabled="!row.scheduledRaceReady"
              :status-text="row.scheduledRaceReady ? '' : formatWaitText(row.secondsUntilScheduledRace, row.useWallClock)"
              primary-label="Spectate"
              secondary-label="Drop out"
              @accept="startScheduledRaceSpectate(row.driverId)"
              @decline="dropScheduledRace(row.driverId)"
            />
          </li>
        </ul>
        <div v-else class="offers-grid">
          <div v-for="row in driversWithScheduledRaces" :key="row.key" class="offer-grid-item">
            <RaceOfferBoardCard
              :offer="row.offer"
              :driver-name="row.driverName"
              :declining="armScheduledBusyId === row.driverId || dropScheduledBusyId === row.driverId"
              :primary-disabled="!row.scheduledRaceReady"
              :status-text="row.scheduledRaceReady ? '' : formatWaitText(row.secondsUntilScheduledRace, row.useWallClock)"
              primary-label="Spectate"
              secondary-label="Drop out"
              @accept="startScheduledRaceSpectate(row.driverId)"
              @decline="dropScheduledRace(row.driverId)"
            />
          </div>
        </div>
      </section>

      <p v-if="raceOffersMessage" class="notice">{{ raceOffersMessage }}</p>

      <section class="races-section">
        <div class="section-head">
          <span class="caption">Available races</span>
          <span v-if="raceOffers.length" class="pill count">{{ raceOffers.length }}</span>
        </div>
        <ul v-if="raceOffers.length && layout === 'phone'" class="offers-list">
          <li v-for="offer in raceOffers" :key="String(offer.id)" class="offer-row" :data-offer-id="String(offer.id)">
            <RaceOfferBoardCard
              compact
              :offer="offer"
              :declining="decliningOfferId === String(offer.id)"
              @accept="onAccept(offer)"
              @decline="onDeclineRaceOffer(offer)"
            />
          </li>
        </ul>
        <div v-else-if="raceOffers.length" class="offers-grid">
          <div v-for="offer in raceOffers" :key="String(offer.id)" class="offer-grid-item" :data-offer-id="String(offer.id)">
            <RaceOfferBoardCard
              :offer="offer"
              :declining="decliningOfferId === String(offer.id)"
              @accept="onAccept(offer)"
              @decline="onDeclineRaceOffer(offer)"
            />
          </div>
        </div>
        <div v-else class="empty races-empty">
          <p>{{ driversWithScheduledRaces.length ? "No new offers on the board. Use Scheduled races above when ready." : "No offers available right now." }}</p>
        </div>
      </section>
    </template>

    <div v-else class="panel offer-detail" v-bng-on-ui-nav:back.focusRequired="onDetailNavBack">
      <HouseButton
        variant="quiet"
        compact
        class="offer-detail__back"
        :icon="icons.arrowLargeLeft"
        @click.stop="onOfferDetailBack"
        @mousedown.stop
      >
        Back
      </HouseButton>
      <h3 class="offer-title">{{ selectedOffer.raceLabel || selectedOffer.raceName || "Race" }}</h3>
      <div class="facts detail-facts">
        <div class="fact">
          <span class="fact-key">Scheduled</span>
          <span class="fact-value">{{ selectedOffer.scheduledTime ?? "—" }}</span>
        </div>
        <div class="fact">
          <span class="fact-key">Laps</span>
          <span class="fact-value">{{ selectedOffer.lapCount ?? "—" }}</span>
        </div>
        <div class="fact">
          <span class="fact-key">Class</span>
          <span class="fact-value">{{ formatClassLabel(selectedOffer.hpBracketLabel, selectedOffer.classPwMin, selectedOffer.classPwMax, selectedOffer.hpBracketBranch) || "—" }}</span>
        </div>
        <div v-for="place in selectedOfferPrizes" :key="place.label" class="fact money">
          <span class="fact-key">{{ place.label }}</span>
          <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(place.value) }}</span>
          <span v-if="Number(place.xp) > 0" class="prize-xp">{{ Math.round(Number(place.xp)).toLocaleString() }} XP</span>
        </div>
      </div>
      <div class="offer-detail__actions">
        <HouseButton
          v-if="isLeague1"
          variant="primary"
          :aria-disabled="league1FleetLoading"
          @click.stop="openLeague1FleetPicker"
          @mousedown.stop
        >
          Choose fleet car
        </HouseButton>
        <HouseButton
          v-else
          variant="primary"
          @click.stop="onAssignDriver"
          @mousedown.stop
        >
          Assign driver
        </HouseButton>
        <HouseButton
          v-if="!isLeague1"
          :aria-disabled="league2FleetLoading"
          @click.stop="openLeague2FleetPicker"
          @mousedown.stop
          title="Drive this race yourself. Team payout is reduced (see racing team docs) and you'll have a cooldown after."
        >
          Race myself
        </HouseButton>
      </div>

      <div v-if="isLeague1 && league1FleetPickerOpen" class="picker">
        <div class="picker-head">
          <span class="caption">Choose a team car</span>
          <p class="hint">Match the car’s class to this offer.</p>
        </div>
        <p v-if="league1FleetLoading" class="picker-empty">Loading fleet…</p>
        <p v-else-if="!league1FleetOptions.length" class="picker-empty">No fleet vehicle matches this sanctioned class.</p>
        <ul v-else class="lines picker-list">
          <li v-for="fv in league1FleetOptions" :key="String(fv.vehicleId)" class="line picker-item">
            <div class="picker-copy">
              <strong class="picker-name">{{ fv.vehicleName || ("Vehicle #" + fv.vehicleId) }}</strong>
              <span
                v-if="formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage"
                class="picker-sub"
              >
                {{ formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage }}
              </span>
              <span v-if="fv.overpowered || fv.onCooldown" class="picker-pills">
                <span v-if="fv.overpowered" class="pill bad">Over class</span>
                <span v-if="fv.onCooldown" class="pill accent">Cooling down {{ formatCooldown(fv.cooldownSec) }}</span>
              </span>
            </div>
            <HouseButton
              compact
              :aria-disabled="raceLeague1BusyVehicleId !== null"
              :data-fk="'race-confirmLeague1RaceWithFleet-' + (fv.vehicleId)" @click.stop="confirmLeague1RaceWithFleet(fv)"
              @mousedown.stop
            >
              Race
            </HouseButton>
          </li>
        </ul>
      </div>

      <div v-if="!isLeague1 && league2FleetPickerOpen" class="picker">
        <div class="picker-head">
          <span class="caption">Race this offer yourself</span>
          <p class="hint">Lower team payout; cooldown after you race.</p>
        </div>
        <p v-if="league2FleetLoading" class="picker-empty">Loading fleet…</p>
        <p v-else-if="!league2FleetOptions.length" class="picker-empty">No fleet vehicle matches this sanctioned class.</p>
        <ul v-else class="lines picker-list">
          <li v-for="fv in league2FleetOptions" :key="String(fv.vehicleId)" class="line picker-item">
            <div class="picker-copy">
              <strong class="picker-name">{{ fv.vehicleName || ("Vehicle #" + fv.vehicleId) }}</strong>
              <span
                v-if="formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage"
                class="picker-sub"
              >
                {{ formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage }}
              </span>
              <span v-if="fv.overpowered || fv.onCooldown || fv.playerOnCooldown" class="picker-pills">
                <span v-if="fv.overpowered" class="pill bad">Over class</span>
                <span v-if="fv.onCooldown" class="pill accent">Vehicle cooling {{ formatCooldown(fv.cooldownSec) }}</span>
                <span v-if="fv.playerOnCooldown" class="pill accent">Player cooling {{ formatCooldown(fv.playerCooldownSec) }}</span>
              </span>
            </div>
            <HouseButton
              compact
              :aria-disabled="raceLeague2BusyVehicleId !== null" :disabled="fv.onCooldown || fv.playerOnCooldown || fv.overpowered"
              :data-fk="'race-confirmLeague2RaceWithFleet-' + (fv.vehicleId)" @click.stop="confirmLeague2RaceWithFleet(fv)"
              @mousedown.stop
            >
              Race
            </HouseButton>
          </li>
        </ul>
      </div>

      <div v-if="driverPickerOpen && !isLeague1" class="picker">
        <div class="picker-head">
          <span class="caption">Choose a driver</span>
          <p class="hint">Books the race; spectate from Scheduled races when ready.</p>
        </div>
        <p v-if="!availableDrivers.length" class="picker-empty">No drivers available.</p>
        <ul v-else class="lines picker-list">
          <li v-for="tech in availableDrivers" :key="String(tech.id)" class="line picker-item">
            <div class="picker-copy">
              <strong class="picker-name">{{ tech.name || ("Driver #" + tech.id) }}</strong>
              <span v-if="tech.fleetVehicleName" class="picker-sub">{{ tech.fleetVehicleName }}</span>
              <span
                v-if="!tech.fleetVehicleName || (hasFleetVehicleAssigned(tech) && isDriverOnPostRaceCooldown(tech))"
                class="picker-pills"
              >
                <span v-if="!tech.fleetVehicleName" class="pill warn">Assign a fleet car first</span>
                <span v-if="hasFleetVehicleAssigned(tech) && isDriverOnPostRaceCooldown(tech)" class="pill accent">
                  Recovering {{ formatCooldownCounter(remainingSecondsForPostRaceCooldown(tech)) }}
                </span>
              </span>
            </div>
            <HouseButton
              compact
              :disabled="!hasFleetVehicleAssigned(tech) || isDriverOnPostRaceCooldown(tech)"
              :data-fk="'race-confirmRaceWithDriver-' + (tech.id)" @click.stop="confirmRaceWithDriver(tech)"
              @mousedown.stop
            >
              Schedule
            </HouseButton>
          </li>
        </ul>
        <HouseButton variant="quiet" compact class="picker-cancel" @click.stop="cancelDriverPicker" @mousedown.stop>
          Cancel
        </HouseButton>
      </div>
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="vehicleOutOfClassModalOpen"
          class="rls-house rls-house-card house-overlay"
          @click.self.stop="vehicleOutOfClassModalOpen = false"
          @mousedown.self.stop="vehicleOutOfClassModalOpen = false"
        >
          <div
            class="modal house-modal"
            v-bng-scoped-nav="outOfClassModalScope" v-bc-modal-focus
            v-bng-on-ui-nav:back,menu="() => { vehicleOutOfClassModalOpen = false }"
            @click.stop
            @mousedown.stop>
            <h3>Vehicle over class limit</h3>
            <p>
              This car's power-to-weight is above the race bracket (see class on the offer vs your vehicle card). Pick a lower-tier offer or use a less powerful tune.
            </p>
            <div class="modal-actions">
              <HouseButton
                variant="primary"
                @click.stop="vehicleOutOfClassModalOpen = false"
                @mousedown.stop
              >OK</HouseButton>
            </div>
          </div>
        </div>
      </transition>
      <transition name="modal-fade">
        <div
          v-if="vehicleOnCooldownModalOpen"
          class="rls-house rls-house-card house-overlay"
          @click.self.stop="vehicleOnCooldownModalOpen = false"
          @mousedown.self.stop="vehicleOnCooldownModalOpen = false"
        >
          <div
            class="modal house-modal"
            v-bng-scoped-nav="cooldownModalScope" v-bc-modal-focus
            v-bng-on-ui-nav:back,menu="() => { vehicleOnCooldownModalOpen = false }"
            @click.stop
            @mousedown.stop>
            <h3>Vehicle on cooldown</h3>
            <p>
              This car just finished a race and needs time to reset. <span v-if="vehicleOnCooldownSec > 0">Try again in {{ formatCooldown(vehicleOnCooldownSec) }}.</span>
            </p>
            <div class="modal-actions">
              <HouseButton
                variant="primary"
                @click.stop="vehicleOnCooldownModalOpen = false"
                @mousedown.stop
              >OK</HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>
<script setup>
import { useActionFocus } from "../../../../composables/useActionFocus.js"
import { setFocus } from "@/services/uiNavFocus"
import { useNowSeconds } from "../../../../composables/useNowSeconds.js"
import { useRaceCountdowns } from "./useRaceCountdowns.js"
import { useRacingManagerSettings } from "./useRacingManagerSettings.js"
import { isOutOfSpecErr, armScheduledErrMessage, proxyRaceErrMessage, dropScheduledErrMessage } from "./raceActionMessages.js"
import { computed, ref, watch, nextTick, onMounted, onUnmounted } from "vue"
import { lua, useBridge } from "@/bridge"
import { useBusinessComputerStore } from "../../../../stores/businessComputerStore"
import { useBusinessRacingTeamStore } from "../../../../stores/businessComputer/businessRacingTeamStore.js"
import { useBusinessSessionStore } from "../../../../stores/businessComputer/businessSessionStore.js"
import { useBusinessTechsStore } from "../../../../stores/businessComputer/businessTechsStore.js"
import { formatSanctionedClassWithBucket } from "../../../../utils/sanctionedClassFormat"
import RaceOfferBoardCard from "./RaceOfferBoardCard.vue"
import { HouseButton, HouseSwitch } from "../../../house/index.js"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { refocusIfLost } from "../../../../composables/useScreenEntryFocus"
import { bcModalScope, vBcModalFocus } from "../../bcModalNav"
import { BngIcon, icons } from "@/common/components/base"
import { safeLua } from "../../../../utils/safeLua.js"
import { formatWholeMoney } from "./racingTeamMoney.js"

defineProps({
  layout: {
    type: String,
    default: "computer",
    validator: (value) => ["computer", "phone"].includes(value),
  },
})

const computerStore = useBusinessComputerStore()
const racingTeamStore = useBusinessRacingTeamStore()
const sessionStore = useBusinessSessionStore()
const techsStore = useBusinessTechsStore()
const { events } = useBridge()

const scheduleUiSecondTick = useNowSeconds()

const { formatCooldownCounter, remainingSecondsForPostRaceCooldown, remainingSecondsForScheduledDriver } = useRaceCountdowns({ racingTeamStore, scheduleUiSecondTick })

const handleVehicleOutOfClass = () => {
  vehicleOutOfClassModalOpen.value = true
}

const handleVehicleOnCooldown = (payload) => {
  const sec = Number(payload?.remainingSec)
  vehicleOnCooldownSec.value = Number.isFinite(sec) ? Math.max(0, Math.floor(sec)) : 0
  vehicleOnCooldownModalOpen.value = true
}

const formatCooldown = (totalSec) => formatCooldownCounter(totalSec)

onMounted(() => {
  events.on("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
  events.on("racingTeam:vehicleOnCooldown", handleVehicleOnCooldown)
  events.on("racingTeamManagerSettingsUpdated", onManagerSettingsUpdated)
})
onUnmounted(() => {
  events.off("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
  events.off("racingTeam:vehicleOnCooldown", handleVehicleOnCooldown)
  events.off("racingTeamManagerSettingsUpdated", onManagerSettingsUpdated)
})

function formatLeagueLabel (league) {
  if (!league || typeof league !== "string") return ""
  const map = racingTeamStore.racingTeamLeagueDisplayNames
  if (map && typeof map === "object" && map[league]) {
    return String(map[league])
  }
  const m = /^league(\d+)$/i.exec(league.trim())
  if (m) return `League ${m[1]}`
  return league
}

const raceOffersScreenTitle = computed(() => {
  const cl = sessionStore.businessData?.currentLeague
  if (!cl || typeof cl !== "string") return ""
  return formatLeagueLabel(cl) || ""
})

const selectedOffer = ref(null)

const selectedOfferPrizes = computed(() => {
  const o = selectedOffer.value
  if (!o) return []
  return [
    { label: "1st", value: o.payoutFirst, xp: o.xpFirst },
    { label: "2nd", value: o.payoutSecond, xp: o.xpSecond },
    { label: "3rd", value: o.payoutThird, xp: o.xpThird },
  ].filter((p) => Number.isFinite(Number(p.value)))
})

const driverPickerOpen = ref(false)

const league1FleetPickerOpen = ref(false)
const league1FleetOptions = ref([])
const league1FleetLoading = ref(false)
const raceLeague1BusyVehicleId = ref(null)

const league2FleetPickerOpen = ref(false)
const league2FleetOptions = ref([])
const league2FleetLoading = ref(false)
const raceLeague2BusyVehicleId = ref(null)

const raceFromGarageBusy = ref(false)

const armScheduledBusyId = ref(null)

const dropScheduledBusyId = ref(null)

const decliningOfferId = ref(null)

const vehicleOutOfClassModalOpen = ref(false)
const vehicleOnCooldownModalOpen = ref(false)
const outOfClassModalScope = bcModalScope("race-out-of-class")
const cooldownModalScope = bcModalScope("race-cooldown")

// Controller: the offer list and the offer detail swap with v-if, so carry focus across the swap
// (detail -> its first live action; back -> the offer's Accept, else the first offer) and let B close an
// open picker, then the detail, before it reaches the computer.
const tabRef = ref(null)
const { run } = useActionFocus(tabRef)
watch([league1FleetPickerOpen, league2FleetPickerOpen, driverPickerOpen, league1FleetLoading, league2FleetLoading], async () => {
  await nextTick()
  if (league1FleetPickerOpen.value || league2FleetPickerOpen.value || driverPickerOpen.value) {
    const target = tabRef.value?.querySelector('.picker-list button:not(:disabled)')
    if (target) setFocus(target)
  } else { focusDetailActions() }
})
const lastOfferId = ref(null)
const focusDetailActions = () => refocusIfLost(() => tabRef.value?.querySelector(".offer-detail__actions button:not(:disabled)"))
const focusOfferList = () => refocusIfLost(() =>
  tabRef.value?.querySelector(`[data-offer-id="${lastOfferId.value}"] button:not(:disabled)`)
  || tabRef.value?.querySelector(".races-section button:not(:disabled)"))
const onDetailNavBack = () => {
  if (driverPickerOpen.value) cancelDriverPicker()
  else if (league1FleetPickerOpen.value) cancelLeague1FleetPicker()
  else if (league2FleetPickerOpen.value) cancelLeague2FleetPicker()
  else {
    clearSelectedOffer()
    focusOfferList()
    return false
  }
  focusDetailActions()
  return false
}
const vehicleOnCooldownSec = ref(0)

const racingTeamProxyArmed = computed(() => sessionStore.businessData?.racingTeamProxyArmed === true)

const isLeague1 = computed(() => (sessionStore.businessData?.currentLeague || "") === "league1")

const tabHint = computed(() =>
  isLeague1.value
    ? "Pick a sanctioned race from the board and drive it in a team car."
    : "Book your drivers into races from the board, then spectate when they're ready."
)

const {
  showManagerAutomationPanel, managerSkillLevel, managerAutoAssign,
  managerIntervalOptions, managerIntervalModel, managerIntervalCountdownSec,
  managerBookingTimerText, managerAutoToggleBusy, managerIntervalBusy,
  selectManagerInterval, onManagerAutoToggle, onManagerSettingsUpdated
} = useRacingManagerSettings({ sessionStore, racingTeamStore, scheduleUiSecondTick })
const onManagerAutoSwitch = (enabled) => onManagerAutoToggle({ target: { checked: !!enabled } })

const driversWithScheduledRaces = computed(() => {
  void racingTeamStore.racingTeamCareerSimTime
  void scheduleUiSecondTick.value
  const list = techsStore.techs
  if (!Array.isArray(list)) return []
  const rows = []
  for (const t of list) {
    if (!t || t.fired || !t.pendingRaceOffer) continue
    const pr = t.pendingRaceOffer
    const useWallClock = Number.isFinite(Number(pr.scheduledRaceReadyWallEpoch ?? t.scheduledRaceReadyWallEpoch))
    const remaining = remainingSecondsForScheduledDriver(t)
    rows.push({
      key: `sched-${t.id}-${pr.id ?? ""}`,
      driverId: t.id,
      driverName: t.name || `Driver #${t.id}`,
      offer: pr,
      scheduledRaceReady: remaining !== null ? remaining <= 0 : t.scheduledRaceReady === true,
      secondsUntilScheduledRace: remaining ?? 0,
      useWallClock,
    })
  }
  return rows
})

const formatWaitText = (seconds, useWallClock) => {
  if (!useWallClock && (racingTeamStore.racingTeamCareerSimTime === null || racingTeamStore.racingTeamCareerSimTime === undefined)) {
    if (Number.isFinite(seconds) && seconds > 0) {
      const s = Math.max(0, Math.floor(seconds))
      const minutes = Math.floor(s / 60)
      const secs = s % 60
      return minutes > 0 ? `Ready in ~${minutes}m ${secs}s (syncing…)` : `Ready in ~${secs}s (syncing…)`
    }
    return "Syncing countdown…"
  }
  if (!Number.isFinite(seconds) || seconds <= 0) return "Not ready yet"
  const s = Math.max(0, Math.floor(seconds))
  const minutes = Math.floor(s / 60)
  const secs = s % 60
  if (minutes > 0) {
    return `Ready in ${minutes}m ${secs}s`
  }
  return `Ready in ${secs}s`
}

const raceOffers = computed(() => {
  const list = sessionStore.businessData?.raceOffers
  return Array.isArray(list) ? list : []
})

const availableDrivers = computed(() => {
  const list = techsStore.techs
  if (!Array.isArray(list)) return []
  return list.filter((t) => t && !t.fired && !t.pendingRaceOffer)
})

const raceOffersMessage = computed(() => sessionStore.businessData?.raceOffersMessage || "")

// number only: the template puts the game currency glyph in front
const formatMoney = (n) => formatWholeMoney(n)

const formatClassLabel = (label, classPwMin, classPwMax, branch) => {
  const source = Number.isFinite(Number(classPwMin)) ? classPwMin : classPwMax
  return formatSanctionedClassWithBucket(label, source, branch)
}

/** League 1 accept: Lua reason strings → in-game toast (Lua already ui_messages some cases). */
const LEAGUE1_ACCEPT_TOAST = {
  not_eligible_pw: "This car is outside the race power-to-weight bracket (too high or bracket read failed).",
  fleet_power_weight_unknown:
    "Cannot read this car's power-to-weight (dyno or weight missing). Run a dyno on it or pick another vehicle.",
  insufficient_funds: "Not enough team funds for the entry fee.",
  offer_not_on_board: "That offer is no longer on the board — refresh and pick again.",
  bad_fleet_vehicle: "Fleet vehicle not found. Pull the car from inventory or reload.",
  wrong_league: "League 1 sanctioned board is required for player races from this screen.",
  missing_args: "Missing race or vehicle selection.",
  sanctioned_module_missing: "Sanctioned racing module unavailable. Check the mod install.",
  player_cooldown: "You're still recovering from your last race. Wait for your cooldown to clear.",
}

/** Inventory ids may be 0; JS treats 0 as falsy — do not use !tech.fleetVehicleId for UI gating. */
const hasFleetVehicleAssigned = (tech) => {
  if (!tech) return false
  const id = tech.fleetVehicleId
  if (id === undefined || id === null) return false
  if (id === "") return false
  if (typeof id === "number" && !Number.isFinite(id)) return false
  return true
}

const isDriverOnPostRaceCooldown = (tech) => remainingSecondsForPostRaceCooldown(tech) > 0

const formatPostRaceCooldownText = (tech) => formatCooldownCounter(remainingSecondsForPostRaceCooldown(tech))

const onAccept = (offer) => {
  if (!offer || offer.id === undefined || offer.id === null) return
  lastOfferId.value = String(offer.id)
  selectedOffer.value = offer
  focusDetailActions()
}

const onDeclineRaceOffer = async (offer) => {
  return run(async () => {
  if (!offer || offer.id === undefined || offer.id === null) return
  const oid = String(offer.id)
  decliningOfferId.value = oid
  try {
    const ok = await racingTeamStore.declineRacingTeamRaceOffer(offer.id)
    if (ok) {
      await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
      if (selectedOffer.value && String(selectedOffer.value.id) === oid) {
        clearSelectedOffer()
      }
    }
  } finally {
    decliningOfferId.value = null
    focusOfferList()
  }

  })
}

const onOfferDetailBack = () => {
  if (league1FleetPickerOpen.value) {
    cancelLeague1FleetPicker()
    return
  }
  if (league2FleetPickerOpen.value) {
    cancelLeague2FleetPicker()
    return
  }
  clearSelectedOffer()
  focusOfferList()
}

const clearSelectedOffer = () => {
  driverPickerOpen.value = false
  league1FleetPickerOpen.value = false
  league1FleetOptions.value = []
  league1FleetLoading.value = false
  raceLeague1BusyVehicleId.value = null
  league2FleetPickerOpen.value = false
  league2FleetOptions.value = []
  league2FleetLoading.value = false
  raceLeague2BusyVehicleId.value = null
  selectedOffer.value = null
}

const onAssignDriver = () => {
  if (isLeague1.value) return
  driverPickerOpen.value = true
}

const cancelLeague1FleetPicker = () => {
  league1FleetPickerOpen.value = false
  league1FleetOptions.value = []
  league1FleetLoading.value = false
  raceLeague1BusyVehicleId.value = null
}

const openLeague1FleetPicker = async () => {
  return run(async () => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null) return
  league1FleetPickerOpen.value = true
  league1FleetLoading.value = true
  league1FleetOptions.value = []
  try {
    const opts = await racingTeamStore.listLeague1FleetVehiclesForSanctionedOffer(offer.id)
    league1FleetOptions.value = Array.isArray(opts) ? opts : []
    if (!league1FleetOptions.value.length) {
      safeLua(() => lua.ui_message(
          "No fleet vehicle matches this race HP class. Buy or tune a car in the bracket shown on the offer.",
          9,
          "Racing Team",
          "warning"
        ), "Show league 1 no-fleet toast")
      league1FleetPickerOpen.value = false
    }
  } catch (e) {
    safeLua(() => { throw e }, "Open league 1 fleet picker")
    league1FleetPickerOpen.value = false
  } finally {
    league1FleetLoading.value = false
  }

  })
}

const cancelLeague2FleetPicker = () => {
  league2FleetPickerOpen.value = false
  league2FleetOptions.value = []
  league2FleetLoading.value = false
  raceLeague2BusyVehicleId.value = null
}

const openLeague2FleetPicker = async () => {
  return run(async () => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null) return
  league2FleetPickerOpen.value = true
  league2FleetLoading.value = true
  league2FleetOptions.value = []
  try {
    const opts = await racingTeamStore.listLeague2FleetVehiclesForSanctionedOffer(offer.id)
    league2FleetOptions.value = Array.isArray(opts) ? opts : []
    if (!league2FleetOptions.value.length) {
      safeLua(() => lua.ui_message(
          "No fleet vehicle matches this race power-to-weight class. Tune or assign a car in the bracket shown.",
          9,
          "Racing Team",
          "warning"
        ), "Show league 2 no-fleet toast")
      league2FleetPickerOpen.value = false
    }
  } catch (e) {
    safeLua(() => { throw e }, "Open league 2 fleet picker")
    league2FleetPickerOpen.value = false
  } finally {
    league2FleetLoading.value = false
  }

  })
}

const confirmLeague2RaceWithFleet = async (fv) => {
  return run(async () => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null || !fv) return
  const vid = fv.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  raceLeague2BusyVehicleId.value = vid
  try {
    const res = await racingTeamStore.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(offer.id, vid)
    if (res === "out_of_class" || String(res || "").toLowerCase() === "out_of_class") {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    if (res === "vehicle_cooldown" || String(res || "").toLowerCase() === "vehicle_cooldown") {
      vehicleOnCooldownModalOpen.value = true
      return
    }
    if (res !== true) {
      const key = typeof res === "string" ? String(res).toLowerCase() : ""
      const specific = key ? LEAGUE1_ACCEPT_TOAST[key] : null
      safeLua(() => {
        if (specific) {
          lua.ui_message(specific, 10, "Racing Team", "warning")
        } else if (res === false || res == null || res === "") {
          lua.ui_message(
            "Could not start this race. The offer may no longer be on the board, the team account may not cover the entry fee, or a sanctioned race may already be active.",
            8,
            "Racing Team",
            "error"
          )
        } else if (typeof res === "string" && res.length > 0) {
          lua.ui_message(`Could not start this race (${res}).`, 9, "Racing Team", "warning")
        }
      }, "Show league 2 race start message")
      return
    }
    await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
    clearSelectedOffer()
    safeLua(() => lua.ui_message("Go to race set. Drive to staging to begin.", 6, "Racing Team", "info"), "Show league 2 race set toast")
    if (computerStore.exitBusinessComputerToPlay) {
      computerStore.exitBusinessComputerToPlay()
    }
  } finally {
    raceLeague2BusyVehicleId.value = null
  }

  })
}

const confirmLeague1RaceWithFleet = async (fv) => {
  return run(async () => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null || !fv) return
  const vid = fv.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  raceLeague1BusyVehicleId.value = vid
  try {
    const res = await racingTeamStore.acceptRacingTeamRaceOfferAsPlayer(offer.id, vid)
    if (res === "out_of_class" || String(res || "").toLowerCase() === "out_of_class" || vehicleOutOfClassModalOpen.value) {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    if (res === "vehicle_cooldown" || String(res || "").toLowerCase() === "vehicle_cooldown" || vehicleOnCooldownModalOpen.value) {
      vehicleOnCooldownModalOpen.value = true
      return
    }
    if (res !== true) {
      const key = typeof res === "string" ? String(res).toLowerCase() : ""
      const specific = key ? LEAGUE1_ACCEPT_TOAST[key] : null
      safeLua(() => {
        if (specific) {
          lua.ui_message(specific, 10, "Racing Team", "warning")
        } else if (res === false || res == null || res === "") {
          lua.ui_message(
            "Could not start this race. The offer may no longer be on the board, the team account may not cover the entry fee, or a sanctioned race may already be active.",
            8,
            "Racing Team",
            "error"
          )
        } else if (typeof res === "string" && res.length > 0) {
          lua.ui_message(`Could not start this race (${res}).`, 9, "Racing Team", "warning")
        }
      }, "Show league 1 race start message")
      return
    }
    await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
    clearSelectedOffer()
    safeLua(() => lua.ui_message("Go to race set. Drive to staging to begin.", 6, "Racing Team", "info"), "Show league 1 race set toast")
    if (computerStore.exitBusinessComputerToPlay) {
      computerStore.exitBusinessComputerToPlay()
    }
  } finally {
    raceLeague1BusyVehicleId.value = null
  }

  })
}

const cancelDriverPicker = () => {
  driverPickerOpen.value = false
  focusDetailActions()
}

const confirmRaceWithDriver = async (tech) => {
  return run(async () => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null || !tech) return
  if (!hasFleetVehicleAssigned(tech)) return
  await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
  const fresh = techsStore.techs.find((x) => x && Number(x.id) === Number(tech.id))
  if (fresh && isDriverOnPostRaceCooldown(fresh)) {
    safeLua(() => lua.ui_message(
        `${fresh.name || "Driver"} is still recovering from their last race (${formatPostRaceCooldownText(fresh)} left).`,
        7,
        "Racing Team",
        "warning"
      ), "Show driver recovery toast")
    return
  }
  const accepted = await racingTeamStore.acceptRacingTeamRaceOffer(offer.id, tech.id)
  if (accepted === "out_of_class" || String(accepted || "").toLowerCase() === "out_of_class" || vehicleOutOfClassModalOpen.value) {
    vehicleOutOfClassModalOpen.value = true
    return
  }
  if (accepted === "vehicle_cooldown" || String(accepted || "").toLowerCase() === "vehicle_cooldown" || vehicleOnCooldownModalOpen.value) {
    vehicleOnCooldownModalOpen.value = true
    return
  }
  if (accepted !== true) {
    const key = typeof accepted === "string" ? String(accepted).toLowerCase() : ""
    const specific = key ? LEAGUE1_ACCEPT_TOAST[key] : null
    safeLua(() => {
      if (specific) {
        lua.ui_message(specific, 10, "Racing Team", "warning")
      } else if (!accepted) {
        lua.ui_message(
          "Could not accept this race. The offer may have expired, the fleet car may be invalid, or the car may not match the sanctioned class.",
          7,
          "Racing Team",
          "error"
        )
      } else if (typeof accepted === "string" && accepted.length > 0) {
        lua.ui_message(`Could not accept this race (${accepted}).`, 8, "Racing Team", "warning")
      }
    }, "Show driver accept message")
    return
  }
  driverPickerOpen.value = false
  clearSelectedOffer()
  await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
  focusOfferList()

  })
}

const dropScheduledRace = async (driverId) => {
  return run(async () => {
  if (driverId === undefined || driverId === null) return
  dropScheduledBusyId.value = driverId
  try {
    const res = await racingTeamStore.cancelRacingTeamProxyScheduledRace(driverId)
    if (res && res.ok) {
      await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
      safeLua(() => lua.ui_message("Scheduled team race withdrawn. Entry fee refunded when applicable.", 7, "Racing Team", "info"), "Show drop-out toast")
    } else if (res && res.err) {
      safeLua(() => lua.ui_message(dropScheduledErrMessage(res.err), 6, "Racing Team", "error"), "Show drop-out error toast")
    }
  } finally {
    dropScheduledBusyId.value = null
  }

  })
}

const startScheduledRaceSpectate = async (driverId) => {
  return run(async () => {
  if (driverId === undefined || driverId === null) return
  armScheduledBusyId.value = driverId
  try {
    const res = await racingTeamStore.simulateRacingTeamProxyRace({ driverId })
    if (res && res.ok === true) {
      await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
      safeLua(() => lua.ui_message(
          "Team race spectate started from your scheduled row.",
          8,
          "Racing Team",
          "info"
        ), "Show spectate toast")
      computerStore.exitBusinessComputerToPlay()
      return
    }
    const err = res && res.err ? res.err : "unknown_error"
    let showOos = isOutOfSpecErr(err)
    if (!showOos) {
      await safeLua(async () => {
        const chk = await racingTeamStore.isProxyScheduledDriverFleetOverpowered(driverId)
        showOos = !!(chk && chk.overpowered)
      }, "Check scheduled driver fleet class")
    }
    if (showOos) {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    safeLua(() => lua.ui_message(armScheduledErrMessage(err), 6, "Racing Team", "error"), "Show spectate error toast")
  } finally {
    armScheduledBusyId.value = null
  }

  })
}

const onRaceFromGarage = async () => {
  return run(async () => {
  if (raceFromGarageBusy.value) return
  raceFromGarageBusy.value = true
  try {
    const res = await racingTeamStore.beginRacingTeamProxyRaceFromBusinessComputer()
    if (res && res.ok === true) {
      safeLua(() => lua.ui_message("Team car placed at staging.", 4, "Racing Team", "info"), "Show garage race toast")
      await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
      computerStore.exitBusinessComputerToPlay()
      return
    }
    const err = res && res.err ? res.err : "unknown_error"
    let showOos = isOutOfSpecErr(err)
    if (!showOos) {
      await safeLua(async () => {
        const chk = await racingTeamStore.isArmedProxyFleetOverpoweredForRequest()
        showOos = !!(chk && chk.overpowered)
      }, "Check armed proxy fleet class")
    }
    if (showOos) {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    safeLua(() => lua.ui_message(proxyRaceErrMessage(err), 6, "Racing Team", "error"), "Show garage race error toast")
  } finally {
    raceFromGarageBusy.value = false
  }

  })
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.racing-tab {
  display: flex;
  flex-direction: column;
  gap: 1.4em;
  font-variant-numeric: tabular-nums;
}

/* ---- header: league name as the page title ---- */
.tab-head {
  display: grid;
  gap: 0.3em;

  .block-title {
    font-size: 1.45em;
    font-weight: 800;
    letter-spacing: -0.01em;
    color: #fff;
  }

  .hint {
    font-size: 0.9em;
  }
}

/* ---- section captions ---- */
.races-section {
  display: grid;
  gap: 0.7em;
  min-width: 0;
}

.section-head,
.manager-head {
  display: flex;
  align-items: center;
  gap: 0.5em;

  .caption {
    padding-top: 0.12em; // Overpass caps sit high
  }
}

/* ---- manager automation ---- */
.manager-panel {
  gap: var(--space-3);
}

.manager-head {
  justify-content: space-between;
  flex-wrap: wrap;
}

.manager-switch {
  font-size: 0.95em;
}

.manager-interval {
  display: grid;
  gap: 0.35em;
}

.manager-interval-seg {
  width: fit-content;
  max-width: 100%;
  flex-wrap: wrap;

  button {
    flex: 0 0 auto;
    min-width: 3.2em;
    font-variant-numeric: tabular-nums;
  }

  button:disabled {
    opacity: 0.45;
    cursor: default;
  }
}

.manager-hint {
  line-height: 1.35;
}

/* ---- armed proxy race ---- */
.proxy-banner {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
}

.proxy-banner__text {
  margin: 0;
  flex: 1 1 12em;
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.4;
}

/* ---- offer board ---- */
.offers-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(19em, 1fr));
  gap: 1em;
}

.offer-grid-item {
  min-width: 0;
  height: 100%;
}

.offer-grid-item :deep(.race-offer-card) {
  height: 100%;
}

.offers-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.6em;
  width: 100%;
}

.offer-row {
  min-width: 0;
}

.races-empty {
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* ---- offer detail ---- */
.offer-detail {
  gap: var(--space-3);
}

.offer-detail__back {
  justify-self: start;
  margin-left: -0.4em;
}

.offer-title {
  margin: 0;
  font-size: 1.3em;
  font-weight: 800;
  letter-spacing: -0.01em;
  line-height: 1.2;
}

.detail-facts {
  .fact-value {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    font-variant-numeric: tabular-nums;
  }
}

.prize-xp {
  color: var(--faint);
  font-size: 0.74em;
  font-weight: 700;
}

.offer-detail__actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--space-2);
  margin-top: 0.15em;
}

/* ---- pickers (fleet car / driver) ---- */
.picker {
  display: grid;
  gap: var(--space-2);
  margin-top: 0.3em;
  padding-top: 0.85em;
  border-top: 1px solid var(--line);
}

.picker-head {
  display: grid;
  gap: 0.25em;
}

.picker-empty {
  margin: 0;
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 600;
}

.picker-list {
  list-style: none;
  margin: 0;
  padding: 0;
}

.picker-item {
  align-items: center;
}

.picker-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.2em;
}

.picker-name {
  font-weight: 700;
  line-height: 1.25;
}

.picker-sub {
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
}

.picker-pills {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
  margin-top: 0.1em;
}

.picker-cancel {
  justify-self: start;
}

/* ---- modals (teleported to body, so they carry .rls-house themselves) ---- */
.house-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
}

.house-modal {
  width: min(26em, 100%);
}

.modal-actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-2);
  margin-top: 0.2em;

  > :only-child {
    margin-left: auto;
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .house-modal {
    transition: transform 0.18s ease-out;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .house-modal {
    transform: translateY(0.6em) scale(0.98);
  }
}

/* ---- phone layout ---- */
.racing-tab--phone {
  flex: 1;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  gap: 0.9em;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  padding-bottom: 0.85em;

  &::-webkit-scrollbar { width: 0.5em; height: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }

  .tab-head {
    display: none;
  }

  .manager-panel {
    padding: 0.7em 0.75em;
    gap: var(--space-2);
  }

  .manager-switch {
    font-size: 0.88em;
  }

  .manager-interval-seg button {
    min-width: 2.6em;
    font-size: 0.85em;
  }

  .proxy-banner {
    padding: 0.7em 0.75em;
  }

  .proxy-banner__text {
    font-size: 0.85em;
    flex: 1 1 100%;
  }

  .notice {
    font-size: 0.85em;
  }

  .races-section {
    gap: 0.5em;
  }

  .offer-detail {
    padding: 0.7em 0.75em;
    gap: var(--space-2);
  }

  .offer-title {
    font-size: 1.1em;
  }

  .detail-facts {
    font-size: 0.9em;
    row-gap: 0.5em;
  }

  .races-empty {
    padding: 1em;
    font-size: 0.9em;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
