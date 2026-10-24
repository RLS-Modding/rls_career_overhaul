<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div ref="rootRef" :aria-busy="busy" class="rls-house jobs-tab">
    <header class="tab-head">
      <div class="tab-copy">
        <h2 class="block-title">{{ sessionStore.hasCapability('goals') ? 'Goals' : 'Jobs' }}</h2>
        <p class="hint">{{ sessionStore.hasCapability('goals') ? 'Track goals and milestones for your racing program.' : 'Manage active work and available opportunities in one place.' }}</p>
      </div>
      <HouseButton
        v-if="sessionStore.hasCapability('customerJobs')"
        class="filters-button" data-fk="filters"
        :icon="icons.filter"
        @click.stop="openFiltersModal"
        @mousedown.stop
        title="Manage filters, notifications, and blacklists"
      >
        Filters<span v-if="filtersActiveCount" class="pill accent count-pill">{{ filtersActiveCount }}</span>
      </HouseButton>
    </header>

    <RacingTeamPromoPanel
      v-if="sessionStore.hasCapability('goals') && league2Invite.visible"
      variant="card"
      :title="league2Invite.popupTitle"
      :body="league2Invite.popupBody"
      :image-url="league2Invite.popupImageUrl"
      :fee="league2Invite.fee"
    >
      <HouseButton variant="quiet" @click.stop="onLeague2InviteLaterJobs" @mousedown.stop>
        {{ league2Invite.laterLabel }}
      </HouseButton>
      <HouseButton variant="primary" @click.stop="onLeague2InviteAcceptJobs" @mousedown.stop>
        {{ league2Invite.acceptLabel }}
      </HouseButton>
    </RacingTeamPromoPanel>

    <section
      v-if="sessionStore.hasCapability('goals') && racingTeamCurrentGoal"
      class="panel current-goal"
    >
      <div class="goal-head">
        <span class="caption">Current goal</span>
        <span v-if="racingTeamCurrentGoal.tier != null" class="pill">Tier {{ racingTeamCurrentGoal.tier }}</span>
        <span v-else-if="racingTeamLeagueLabel" class="pill">{{ racingTeamLeagueLabel }}</span>
      </div>
      <strong class="goal-title">{{ racingTeamCurrentGoal.title || 'Current goal' }}</strong>
      <p v-if="racingTeamCurrentGoal.description" class="goal-description">{{ racingTeamCurrentGoal.description }}</p>
      <div class="facts goal-facts">
        <div class="fact">
          <span class="fact-key">Target</span>
          <span class="fact-value">{{ racingTeamCurrentGoal.targetLabel || '—' }}</span>
        </div>
        <div class="fact">
          <span class="fact-key">Progress</span>
          <span class="fact-value">{{ racingTeamCurrentGoal.progressLabel || '—' }}</span>
        </div>
      </div>
    </section>

    <section
      v-if="sessionStore.hasCapability('goals') && racingTeamCompletedGoals.length"
      class="job-section"
    >
      <div class="section-head">
        <span class="caption">Completed goals</span>
        <span class="pill count">{{ racingTeamCompletedGoals.length }}</span>
      </div>
      <div class="panel completed-goals">
        <div class="lines">
          <div v-for="cg in displayedCompletedGoals" :key="cg.id" class="line completed-goal">
            <span class="completed-copy">
              <strong>{{ cg.title || cg.id }}</strong>
              <span v-if="cg.description" class="hint">{{ cg.description }}</span>
              <span v-if="cg.completedBestTimesSummary" class="hint">{{ cg.completedBestTimesSummary }}</span>
            </span>
            <span v-if="formatLeagueLabel(cg.league)" class="pill">{{ formatLeagueLabel(cg.league) }}</span>
          </div>
        </div>
        <HouseButton
          v-if="hasHiddenCompletedGoals"
          variant="quiet"
          compact
          class="completed-toggle"
          @click.stop="completedGoalsExpanded = !completedGoalsExpanded"
          @mousedown.stop
        >
          {{ completedGoalsExpanded ? "Show less" : "Show more" }}
        </HouseButton>
      </div>
    </section>

    <!-- recognition picks: open a chooser -->
    <div v-if="showRecognitionBanner" class="panel recognition">
      <div class="facts recognition-facts">
        <button
          v-if="skillsStore.brandRecognitionUnlocked"
          type="button"
          class="fact recognition-fact"
          @click.stop="openBrandModal"
          @mousedown.stop
        >
          <span class="fact-key">Brand recognition</span>
          <span class="fact-value" :class="{ unset: brandSelectionDisplay === 'Not Selected' }">{{ brandSelectionDisplay }}</span>
        </button>
        <button
          v-if="skillsStore.raceRecognitionUnlocked"
          type="button"
          class="fact recognition-fact"
          @click.stop="openRaceModal"
          @mousedown.stop
        >
          <span class="fact-key">Race recognition</span>
          <span class="fact-value" :class="{ unset: raceSelectionDisplay === 'Not Selected' }">{{ raceSelectionDisplay }}</span>
        </button>
      </div>
    </div>

    <div v-if="!sessionStore.hasCapability('goals') && (sessionStore.activeJobs.length || sessionStore.newJobs.length)" class="jobs-content">
      <!-- Active Jobs Section -->
      <section v-if="sessionStore.activeJobs.length > 0" class="job-section">
        <div class="section-head">
          <span class="caption">Active jobs</span>
          <span class="pill count">{{ sessionStore.activeJobs.length }}</span>
        </div>
        <div class="jobs-grid">
          <template v-for="job in sessionStore.activeJobs" :key="`active-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard :job="job" :is-active="true" :business-id="sessionStore.businessId" layout="full"
                @pull-out="handlePullOut(job)" @put-away="handlePutAway(job)" @abandon="handleAbandon(job)"
                @complete="handleComplete(job)" />
            </div>
          </template>
        </div>
      </section>

      <!-- New Jobs Section -->
      <section v-if="sessionStore.newJobs.length > 0" class="job-section">
        <div class="section-head">
          <span class="caption">New jobs</span>
          <span class="pill count">{{ sessionStore.newJobs.length }}</span>
        </div>
        <div class="jobs-grid">
          <template v-for="job in sessionStore.newJobs" :key="`new-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard :job="job" :is-active="false" layout="full" @accept="handleAccept"
                @decline="handleDecline" />
            </div>
          </template>
        </div>
      </section>
    </div>

    <div v-else-if="!sessionStore.hasCapability('goals')" class="empty">
      <h3>No jobs right now</h3>
      <p>New work shows up here as customers bring their cars in.</p>
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal && !sessionStore.hasCapability('goals')" class="rls-house rls-house-card house-overlay" @click.self.stop="cancelAbandon"
          @mousedown.self.stop>
          <div class="modal house-modal" v-bng-scoped-nav="abandonModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="cancelAbandon">
            <h3>Abandon job?</h3>
            <p>
              You will be charged a penalty of
              <strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ penaltyCost.toLocaleString() }}</strong>.
            </p>
            <div class="modal-actions">
              <HouseButton variant="quiet" bng-scoped-nav-autofocus @click.stop="cancelAbandon"
                @mousedown.stop>Cancel</HouseButton>
              <HouseButton variant="danger" @click.stop="confirmAbandon" @mousedown.stop>
                Abandon
              </HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showBrandModal" class="rls-house rls-house-card house-overlay" @click.self.stop="closeBrandModal"
          @mousedown.self.stop>
          <div class="modal house-modal selection-modal" v-bng-scoped-nav="brandModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="closeBrandModal" @click.stop @mousedown.stop>
            <h3>Brand recognition</h3>
            <div v-if="isLoadingBrands" class="selection-empty">
              <p>Loading brands</p>
            </div>
            <div v-else-if="skillsStore.availableBrands.length === 0" class="selection-empty">
              <p>No brands available</p>
              <span class="hint">Try refreshing or check if vehicles are loaded.</span>
            </div>
            <div v-else class="selection-list scroll" v-bng-ui-nav-scroll>
              <button type="button" class="menu-item selection-item" :class="{ 'selected': !skillsStore.brandSelection }"
                :bng-scoped-nav-autofocus="!skillsStore.brandSelection ? true : null"
                @click.stop="selectBrand(null)" @mousedown.stop>
                <span>No brand</span>
                <svg v-if="!skillsStore.brandSelection" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
              <button v-for="brand in skillsStore.availableBrands" :key="brand" type="button" class="menu-item selection-item"
                :class="{ 'selected': skillsStore.brandSelection === brand }"
                :bng-scoped-nav-autofocus="skillsStore.brandSelection === brand ? true : null" @click.stop="selectBrand(brand)"
                @mousedown.stop>
                <span>{{ brand }}</span>
                <svg v-if="skillsStore.brandSelection === brand" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
            </div>
            <div class="modal-actions">
              <HouseButton variant="quiet" @click.stop="closeBrandModal" @mousedown.stop>Close</HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showRaceModal" class="rls-house rls-house-card house-overlay" @click.self.stop="closeRaceModal"
          @mousedown.self.stop>
          <div class="modal house-modal selection-modal" v-bng-scoped-nav="raceModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="closeRaceModal" @click.stop @mousedown.stop>
            <h3>Race recognition</h3>
            <div v-if="isLoadingRaceTypes" class="selection-empty">
              <p>Loading race types</p>
            </div>
            <div v-else-if="skillsStore.availableRaceTypes.length === 0" class="selection-empty">
              <p>No race types available</p>
              <span class="hint">Check if race data is loaded.</span>
            </div>
            <div v-else class="selection-list scroll" v-bng-ui-nav-scroll>
              <button type="button" class="menu-item selection-item" :class="{ 'selected': !skillsStore.raceSelection }"
                :bng-scoped-nav-autofocus="!skillsStore.raceSelection ? true : null"
                @click.stop="selectRace(null)" @mousedown.stop>
                <span>No race type</span>
                <svg v-if="!skillsStore.raceSelection" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
              <button v-for="raceType in skillsStore.availableRaceTypes" :key="raceType.id" type="button" class="menu-item selection-item"
                :class="{ 'selected': skillsStore.raceSelection === raceType.id }"
                :bng-scoped-nav-autofocus="skillsStore.raceSelection === raceType.id ? true : null" @click.stop="selectRace(raceType.id)"
                @mousedown.stop>
                <span>{{ raceType.label }}</span>
                <svg v-if="skillsStore.raceSelection === raceType.id" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
            </div>
            <div class="modal-actions">
              <HouseButton variant="quiet" @click.stop="closeRaceModal" @mousedown.stop>Close</HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <FiltersModal :show="showFiltersModal" @close="closeFiltersModal" />
  </div>
</template>

<script setup>
import { useScopedNav } from "@/services/scopedNav/api"
import { useActionFocus } from "../../composables/useActionFocus.js"
import { safeLua } from "../../utils/safeLua.js"

import { computed, ref, Teleport, onMounted, onUnmounted, watch, nextTick } from "vue"
import { useBusinessJobsStore } from "../../stores/businessComputer/businessJobsStore.js"
import { useBusinessRacingTeamStore } from "../../stores/businessComputer/businessRacingTeamStore.js"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { useBusinessSkillsStore } from "../../stores/businessComputer/businessSkillsStore.js"
import { useBusinessTechsStore } from "../../stores/businessComputer/businessTechsStore.js"
import { useBusinessVehiclesStore } from "../../stores/businessComputer/businessVehiclesStore.js"
import { useBridge } from "@/bridge"
import BusinessJobCard from "./BusinessJobCard.vue"
import FiltersModal from "./FiltersModal.vue"
import RacingTeamPromoPanel from "../RacingTeamPromoPanel.vue"
import { normalizeId } from "../../utils/businessUtils"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"

const rootRef = ref(null)
const { busy, run } = useActionFocus(rootRef)
const jobsStore = useBusinessJobsStore()
const racingTeamStore = useBusinessRacingTeamStore()
const sessionStore = useBusinessSessionStore()
const skillsStore = useBusinessSkillsStore()
const techsStore = useBusinessTechsStore()
const vehiclesStore = useBusinessVehiclesStore()
// pickers open on the current choice; the abandon confirm opens on Cancel
const abandonModalScope = bcModalScope("job-abandon")
const brandModalScope = bcModalScope("brand-recognition")
const raceModalScope = bcModalScope("race-recognition")
const { events } = useBridge()

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const interceptEvent = () => { }

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

const showBrandModal = ref(false)
const showRaceModal = ref(false)
const showFiltersModal = ref(false)
const isLoadingBrands = ref(false)
const isLoadingRaceTypes = ref(false)

// Count pill on the Filters button: vehicles currently on the blacklist, notification list and
// manager blacklist (display only; the lists themselves are managed in FiltersModal).
const filtersActiveCount = computed(() => {
  const len = (data, key) => (Array.isArray(data?.[key]) ? data[key].length : 0)
  return len(techsStore.blacklistData, "blacklist")
    + len(techsStore.notificationListData, "notificationList")
    + len(techsStore.managerBlacklistData, "managerBlacklist")
})

const showRecognitionBanner = computed(() => {
  return skillsStore.brandRecognitionUnlocked || skillsStore.raceRecognitionUnlocked
})

const racingTeamCurrentGoal = computed(() => {
  const g = sessionStore.businessData?.currentGoal
  if (!g || typeof g !== "object") return null
  return g
})

const racingTeamLeagueLabel = computed(() => {
  const g = sessionStore.businessData?.currentGoal
  if (g?.league) return formatLeagueLabel(g.league)
  const cl = sessionStore.businessData?.currentLeague
  if (cl) return formatLeagueLabel(cl)
  return ""
})

const COMPLETED_GOALS_COLLAPSED_COUNT = 1

const completedGoalsExpanded = ref(false)

const racingTeamCompletedGoals = computed(() => {
  const c = sessionStore.businessData?.completedGoals
  return Array.isArray(c) ? c : []
})

const racingTeamCompletedGoalsNewestFirst = computed(() => {
  const all = racingTeamCompletedGoals.value
  return all.length ? [...all].reverse() : []
})

const hasHiddenCompletedGoals = computed(
  () => racingTeamCompletedGoalsNewestFirst.value.length > COMPLETED_GOALS_COLLAPSED_COUNT
)

const displayedCompletedGoals = computed(() => {
  const all = racingTeamCompletedGoalsNewestFirst.value
  if (completedGoalsExpanded.value || all.length <= COMPLETED_GOALS_COLLAPSED_COUNT) {
    return all
  }
  return all.slice(0, COMPLETED_GOALS_COLLAPSED_COUNT)
})

const league2Invite = computed(() => racingTeamStore.league2Invite ?? {})

const onLeague2InviteLaterJobs = async () => {
  await racingTeamStore.racingTeamLeague2InviteLater()
}

const onLeague2InviteAcceptJobs = async () => {
  await racingTeamStore.acceptLeague2Invite()
}

const brandSelectionDisplay = computed(() => {
  const selection = skillsStore.brandSelection
  if (selection === null || selection === undefined || selection === "null" || selection === "") {
    return "Not Selected"
  }
  return selection
})

const raceSelectionDisplay = computed(() => {
  if (!skillsStore.raceSelection) return "Not Selected"
  const raceType = skillsStore.availableRaceTypes.find(rt => rt.id === skillsStore.raceSelection)
  return raceType ? raceType.label : "Not Selected"
})

const handleBrandsReceived = (data) => {
  if (data && Array.isArray(data.brands)) {
    skillsStore.availableBrands = data.brands
  } else {
    skillsStore.availableBrands = []
  }
  isLoadingBrands.value = false
  if (showBrandModal.value) nextTick(() => useScopedNav().requestScopeFocus(brandModalScope.scopeId))
}

const openBrandModal = async () => {
  showBrandModal.value = true
  if (skillsStore.availableBrands.length === 0) {
    isLoadingBrands.value = true
    skillsStore.getAvailableBrands()
  }
}

const closeBrandModal = () => {
  showBrandModal.value = false
}

const selectBrand = async (brand) => {
  await skillsStore.setBrandSelection(brand)
  closeBrandModal()
}

const handleRaceTypesReceived = (data) => {
  if (data && Array.isArray(data.raceTypes)) {
    skillsStore.availableRaceTypes = data.raceTypes
  } else {
    skillsStore.availableRaceTypes = []
  }
  isLoadingRaceTypes.value = false
}

const openRaceModal = async () => {
  showRaceModal.value = true
  if (skillsStore.availableRaceTypes.length === 0) {
    isLoadingRaceTypes.value = true
    skillsStore.getAvailableRaceTypes()
  }
}

const closeRaceModal = () => {
  showRaceModal.value = false
}

const openFiltersModal = () => {
  showFiltersModal.value = true
}

const closeFiltersModal = () => {
  showFiltersModal.value = false
}

const selectRace = async (raceType) => {
  await skillsStore.setRaceSelection(raceType)
  closeRaceModal()
}

onMounted(async () => {
  events.on('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.on('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)

  // read-only: load the filter lists once so the Filters button can show its count
  if (sessionStore.hasCapability('customerJobs') && sessionStore.businessId) {
    if (!techsStore.blacklistData) techsStore.fetchBlacklistData?.()
    if (!techsStore.notificationListData) techsStore.fetchNotificationListData?.()
    if (!techsStore.managerBlacklistData) techsStore.fetchManagerBlacklistData?.()
  }

  const needsBrandStatus = skillsStore.brandRecognitionUnlocked === undefined || skillsStore.brandRecognitionUnlocked === null
  const needsRaceStatus = skillsStore.raceRecognitionUnlocked === undefined || skillsStore.raceRecognitionUnlocked === null
  
  if (needsBrandStatus || needsRaceStatus) {
    await Promise.all([
      needsBrandStatus ? skillsStore.updateBrandRecognitionStatus() : Promise.resolve(),
      needsRaceStatus ? skillsStore.updateRaceRecognitionStatus() : Promise.resolve()
    ])
  }
  
  const needsBrandSelection = skillsStore.brandRecognitionUnlocked && skillsStore.brandSelection === null
  const needsRaceSelection = skillsStore.raceRecognitionUnlocked && skillsStore.raceSelection === null
  
  if (needsBrandSelection || needsRaceSelection) {
    await Promise.all([
      needsBrandSelection ? skillsStore.getBrandSelection() : Promise.resolve(),
      needsRaceSelection ? skillsStore.getRaceSelection() : Promise.resolve()
    ])
  }
})

onUnmounted(() => {
  events.off('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.off('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)
})

watch(() => skillsStore.brandRecognitionUnlocked, async (unlocked) => {
  if (unlocked && skillsStore.brandSelection === null) {
    await skillsStore.getBrandSelection()
  }
})

watch(() => skillsStore.raceRecognitionUnlocked, async (unlocked) => {
  if (unlocked && skillsStore.raceSelection === null) {
    await skillsStore.getRaceSelection()
  }
})

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})


const findVehicleForJob = (job) => {
  if (!Array.isArray(sessionStore.vehicles)) {
    return null
  }
  const sv = normalizeId(job?.storedVehicleId)
  if (sv !== null) {
    const byStored = sessionStore.vehicles.find(vehicle => normalizeId(vehicle?.vehicleId) === sv)
    if (byStored) return byStored
  }
  const jobId = normalizeId(job?.jobId ?? job?.id)
  if (jobId === null) {
    return null
  }
  return sessionStore.vehicles.find(vehicle => {
    if (!vehicle.jobId) return false
    return normalizeId(vehicle.jobId) === jobId
  }) || null
}

const handlePullOut = async (job) => {
  return run(async () => {
  const vehicle = findVehicleForJob(job)
  if (!vehicle) {
    return
  }
  await vehiclesStore.pullOutVehicle(vehicle.vehicleId)

  })
}

const handlePutAway = async (job) => {
  return run(async () => {
  const vehicle = findVehicleForJob(job)
  await vehiclesStore.putAwayVehicle(vehicle?.vehicleId)

  })
}

const handleAbandon = (job) => {
  if (!job) return
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const jobIdForAction = (job) => {
  const raw = job?.jobId ?? job?.id ?? job?.job_id
  if (raw === undefined || raw === null || raw === '') return undefined
  // Prefer numbers for Lua bridge: string job ids are received as 0 in GE Lua
  if (typeof raw === 'number' && Number.isFinite(raw)) return raw
  if (typeof raw === 'string' && /^\d+$/.test(raw.trim())) return Number(raw.trim())
  return String(raw)
}

const abandonBusy = ref(false)
const confirmAbandon = async () => {
  if (!jobToAbandon.value || abandonBusy.value) return
  abandonBusy.value = true
  try {
    await jobsStore.abandonJob(jobIdForAction(jobToAbandon.value))
    showAbandonModal.value = false
    jobToAbandon.value = null
  } finally {
    abandonBusy.value = false
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

const handleComplete = job => run(() => jobsStore.completeJob(job.jobId ?? parseInt(job.id)))

const handleAccept = job => run(() => jobsStore.acceptJob(jobIdForAction(job)))

const handleDecline = job => run(() => jobsStore.declineJob(jobIdForAction(job)))

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.jobs-tab {
  display: flex;
  flex-direction: column;
  gap: 1.4em;
}

/* ---- header ---- */
.tab-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.75em 1em;
}

.tab-copy {
  flex: 1 1 18em;
  min-width: 0;
  display: grid;
  gap: 0.3em;

  .block-title {
    font-size: 1.45em;
    font-weight: 800;
    letter-spacing: -0.01em;
  }

  .hint {
    font-size: 0.9em;
  }
}

.count-pill {
  margin-left: 0.45em;
  font-variant-numeric: tabular-nums;
}

/* ---- section captions ---- */
.job-section {
  display: grid;
  gap: 0.7em;
}

.section-head {
  display: flex;
  align-items: center;
  gap: 0.5em;

  .caption {
    padding-top: 0.12em; // Overpass caps sit high
  }

  .pill.count {
    font-variant-numeric: tabular-nums;
  }
}

/* ---- racing team goals ---- */
.current-goal {
  gap: var(--space-3);

  .goal-head {
    display: flex;
    align-items: center;
    gap: 0.5em;

    .caption {
      padding-top: 0.12em;
    }
  }

  .goal-title {
    font-size: 1.2em;
    font-weight: 800;
    line-height: 1.2;
  }

  .goal-description {
    margin: 0;
    color: var(--muted);
    font-size: 0.92em;
    font-weight: 600;
    line-height: 1.4;
  }
}

.facts .fact-value {
  white-space: normal;
  overflow: visible;
  text-overflow: clip;
  font-variant-numeric: tabular-nums;
}

.completed-goals {
  padding-top: 0.2em;
  padding-bottom: 0.6em;

  .completed-goal {
    align-items: flex-start;
  }

  .completed-copy {
    flex: 1 1 auto;
    min-width: 0;
    display: grid;
    gap: 0.2em;

    strong {
      font-weight: 700;
      line-height: 1.25;
    }
  }

  .completed-toggle {
    justify-self: start;
  }
}

/* ---- recognition strip ---- */
.recognition {
  padding: 0.35em;
}

.recognition-facts {
  grid-template-columns: repeat(auto-fill, minmax(13em, 1fr));
  column-gap: 0.35em;
}

.recognition-fact {
  appearance: none;
  margin: 0;
  padding: 0.6em 0.75em 0.5em;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s;

  &:hover {
    background: var(--panel-2);
  }

  @include house-focus;

  .fact-value.unset {
    color: var(--faint);
    font-weight: 600;
  }
}

/* ---- jobs ---- */
.jobs-content {
  display: flex;
  flex-direction: column;
  gap: 1.8em;
}

.jobs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(19em, 1fr));
  gap: 1em;
}

.job-card-wrapper {
  height: 100%;
  min-width: 0;
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

  .money {
    font-variant-numeric: tabular-nums;
  }
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

.selection-modal {
  width: min(24em, 100%);
}

.selection-list {
  display: grid;
  gap: 0.1em;
  max-height: 22em;
  margin: 0 -0.35em;
  padding: 0 0.35em;
}

.selection-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;

  &.focus-visible {
    outline: none;
    background: rgba(255, 255, 255, 0.08);
  }

  svg {
    width: 0.9em;
    height: 0.9em;
    flex: 0 0 auto;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.6;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
}

.selection-empty {
  display: grid;
  gap: 0.3em;
  padding: 1em 0;
  text-align: center;
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

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
