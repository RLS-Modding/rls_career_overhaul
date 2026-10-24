<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Owns the phone projection and invite/club selection. Lua remains the state authority.
     Read social panels, active-meet panels, computed projections, then actions and styles.
     The bridge refreshes an invite before another RSVP action may begin. -->
<template>
  <div class="scene-app">
    <nav class="tabs">
      <button :class="{ active: tab === 'social' }" @click="tab = 'social'">Social</button>
      <button :class="{ active: tab === 'active' }" @click="tab = 'active'">Active</button>
    </nav>

    <section v-if="tab === 'social'" class="tab-panel">
      <nav class="social-tabs">
        <button
          v-for="tile in socialTiles"
          :key="tile.id"
          :class="{ active: socialSection === tile.id }"
          @click="socialSection = tile.id">
          <span>{{ tile.label }}</span>
          <strong>{{ tile.count }}</strong>
        </button>
      </nav>

      <template v-if="socialSection === 'mail'">
        <div v-if="!invites.length" class="empty-card">
          <h2>No Mail</h2>
          <p>Car meet invites will appear here when they arrive.</p>
        </div>

        <div v-if="invites.length" class="section-block">
          <div class="section-title">Car Meet Invites</div>
          <div class="invite-list">
            <article
              v-for="invite in invites"
              :key="invite.id"
              class="expand-card"
              :class="{ expanded: isInviteExpanded(invite) }">
              <button
                type="button"
                class="expand-row"
                :aria-expanded="isInviteExpanded(invite)"
                @click="toggleInvite(invite)">
                <span>
                  <strong>{{ invite.typeName || invite.type }}</strong>
                  <small>{{ invite.clubName || invite.location }}</small>
                </span>
                <em>{{ formatRemaining(invite.expiresAt) }}</em>
              </button>

              <div v-if="isInviteExpanded(invite)" class="expand-detail">
                <img :src="invite.preview" alt="" class="meet-image">
                <div class="info-row"><span>Location</span><strong>{{ invite.location }}</strong></div>
                <div class="info-row" v-if="invite.clubName"><span>Club</span><strong>{{ invite.clubName }}</strong></div>
                <div class="info-row" v-if="invite.missPenalty">
                  <span>Miss Penalty</span><strong class="negative">{{ invite.missPenalty }} rep</strong>
                </div>
                <div class="info-row" v-if="invite.minVehicleValue">
                  <span>Requirement</span><strong>${{ formatMoney(invite.minVehicleValue) }}+ vehicle</strong>
                </div>
                <div class="attendance-grid">
                  <BngButton
                    v-for="level in attendanceLevels"
                    :key="level"
                    :accent="selectedAttendance === level ? ACCENTS.main : ACCENTS.secondary"
                    @click="selectedAttendance = level">
                    {{ level }}
                  </BngButton>
                </div>
                <div class="phone-action-buttons">
                  <BngButton @click="decline" accent="secondary">Decline</BngButton>
                  <BngButton @click="rsvp" accent="main">Accept</BngButton>
                </div>
              </div>
            </article>
          </div>
        </div>
      </template>

      <template v-else-if="socialSection === 'clubs'">
        <div class="section-block">
          <article class="expand-card" :class="{ expanded: openClubGroups.active }">
            <button
              type="button"
              class="expand-row"
              :aria-expanded="openClubGroups.active"
              @click="openClubGroups.active = !openClubGroups.active">
              <span>
                <strong>Active Clubs</strong>
                <small>{{ joinedClubs.length ? `${activeClubCount} of ${joinedClubs.length} active` : "Not in any clubs yet" }}</small>
              </span>
              <em>{{ joinedClubs.length }}</em>
            </button>

            <div v-if="openClubGroups.active" class="expand-detail club-group">
              <p v-if="!joinedClubs.length" class="club-group-empty">Join a club from the invitations below.</p>
              <div
                v-for="club in joinedClubs"
                :key="club.id"
                class="club-tile"
                :class="{ expanded: expandedClubId === club.id }">
                <button
                  type="button"
                  class="club-tile-row"
                  :aria-expanded="expandedClubId === club.id"
                  @click="toggleClub(club.id)">
                  <span>
                    <strong>{{ club.name }}</strong>
                    <small>{{ club.active ? `Standing ${club.standing ?? 100}` : "Missing qualifying vehicle" }}</small>
                  </span>
                  <em :class="{ negative: !club.active || Number(club.standing ?? 100) <= 35 }">
                    {{ club.active ? "Active" : "Inactive" }}
                  </em>
                </button>
                <div v-if="expandedClubId === club.id" class="club-tile-detail">
                  <div class="info-row"><span>Eligible cars</span><strong>{{ club.requirementsText }}</strong></div>
                  <div class="info-row" v-if="club.obligationText"><span>Attendance</span><strong>{{ club.obligationText }}</strong></div>
                  <div class="info-row"><span>Standing</span><strong>{{ club.standing ?? 100 }}</strong></div>
                  <BngButton class="club-tile-action" @click="leaveClub(club.id)" accent="secondary">Leave Club</BngButton>
                </div>
              </div>
            </div>
          </article>

          <article class="expand-card" :class="{ expanded: openClubGroups.invites }">
            <button
              type="button"
              class="expand-row"
              :aria-expanded="openClubGroups.invites"
              @click="openClubGroups.invites = !openClubGroups.invites">
              <span>
                <strong>Club Invitations</strong>
                <small>{{ availableClubs.length ? `${availableClubs.length} available` : "None right now" }}</small>
              </span>
              <em>{{ availableClubs.length }}</em>
            </button>

            <div v-if="openClubGroups.invites" class="expand-detail club-group">
              <p v-if="!availableClubs.length" class="club-group-empty">No club invitations available right now.</p>
              <div
                v-for="club in availableClubs"
                :key="club.id"
                class="club-tile"
                :class="{ expanded: expandedClubId === club.id }">
                <button
                  type="button"
                  class="club-tile-row"
                  :aria-expanded="expandedClubId === club.id"
                  @click="toggleClub(club.id)">
                  <span>
                    <strong>{{ club.name }}</strong>
                    <small>{{ club.canJoin ? (club.joinFee ? `Dues $${formatMoney(club.joinFee)}` : "No dues") : club.disableReason }}</small>
                  </span>
                  <em :class="club.canJoin ? 'positive' : 'muted'">{{ club.canJoin ? "Open" : "Locked" }}</em>
                </button>
                <div v-if="expandedClubId === club.id" class="club-tile-detail">
                  <div class="info-row"><span>Eligible cars</span><strong>{{ club.requirementsText }}</strong></div>
                  <div class="info-row"><span>Reputation</span><strong>{{ club.requiredRep || 0 }}+</strong></div>
                  <div class="info-row"><span>Dues</span><strong>{{ club.joinFee ? `$${formatMoney(club.joinFee)}` : "None" }}</strong></div>
                  <div class="info-row" v-if="club.disableReason"><span>Status</span><strong class="negative">{{ club.disableReason }}</strong></div>
                  <BngButton class="club-tile-action" :disabled="!club.canJoin" @click="joinClub(club.id)" accent="main">
                    {{ club.joinFee ? `Join for $${formatMoney(club.joinFee)}` : "Join" }}
                  </BngButton>
                </div>
              </div>
            </div>
          </article>
        </div>
      </template>

      <template v-else-if="socialSection === 'popularity'">
        <article class="detail-card rep-card">
          <span>Reputation</span>
          <strong>{{ displayRep }}/{{ overview.maxReputation || 100 }}</strong>
        </article>

        <div v-if="popularityVehicles.length === 0" class="empty-card">
          <h2>No Popularity Yet</h2>
          <p>Take a car to a meet to build local buzz.</p>
        </div>
        <div v-else class="section-block">
          <div class="section-title">Local Buzz</div>
          <article v-for="vehicle in popularityVehicles" :key="vehicle.inventoryId" class="list-card vehicle-card">
            <strong>{{ vehicle.name }}</strong>
            <div class="stat-grid">
              <div>
                <span>Local Buzz</span>
                <strong>+{{ formatPercent(vehicle.totalPercent) }}</strong>
              </div>
              <div>
                <span>Meets</span>
                <strong>{{ vehicle.meetsAttended || 0 }}</strong>
              </div>
            </div>
            <small v-if="vehicle.estimatedValue">Estimated value: ${{ formatMoney(vehicle.estimatedValue) }}</small>
          </article>
        </div>
      </template>

      <template v-else-if="socialSection === 'history'">
        <template v-if="historySubview === 'detail' && historyDetail">
          <button type="button" class="subview-back" @click="closeHistoryDetail">Back</button>
          <article class="detail-card history-detail-head">
            <img v-if="historyDetail.thumbnail" :src="historyDetail.thumbnail" alt="" class="meet-image">
            <div class="detail-head">
              <h2>{{ historyDetail.name }}</h2>
              <span v-if="historyDetail.sold" class="chip">Sold</span>
            </div>
            <div class="stat-grid">
              <div>
                <span>Local Buzz</span>
                <strong>+{{ formatPercent(historyDetail.totalPercent) }}</strong>
              </div>
              <div>
                <span>Meets</span>
                <strong>{{ historyDetail.meetsAttended || 0 }}</strong>
              </div>
              <div v-if="!historyDetail.sold && historyDetail.valueBonusPercent > 0">
                <span>Rep Value Bonus</span>
                <strong>+{{ historyDetail.valueBonusPercent }}%</strong>
              </div>
            </div>
            <small v-if="historyDetail.estimatedValue">Estimated value: ${{ formatMoney(historyDetail.estimatedValue) }}</small>
            <small v-if="historyDetail.soldPrice">Sold for ${{ formatMoney(historyDetail.soldPrice) }}</small>
          </article>

          <div class="section-block">
            <div class="section-title">Car Meet Activity</div>
            <div v-if="!historySceneEvents.length" class="empty-card compact">No meet activity logged yet.</div>
            <article v-for="(event, index) in historySceneEvents" :key="`scene-${index}-${event.time}`" class="list-card history-event-row">
              <span>
                <strong>{{ event.label || event.kind }}</strong>
                <small>{{ formatHistoryTime(event.time) }}</small>
              </span>
              <em>{{ formatHistoryEventMeta(event) }}</em>
            </article>
          </div>

          <div class="section-block">
            <div class="section-title">Freeroam Times</div>
            <div v-if="!historyFreeroamTimes.length" class="empty-card compact">No freeroam times recorded for this car.</div>
            <article v-for="fre in historyFreeroamTimes" :key="fre.raceName" class="list-card history-event-row">
              <span><strong>{{ fre.raceName }}</strong></span>
              <em>{{ fre.displayValue }}</em>
            </article>
          </div>
        </template>

        <template v-else>
          <div v-if="historyVehicles.length === 0" class="empty-card">
            <h2>No History</h2>
            <p>Cars you take to car meets will appear here.</p>
          </div>
          <div v-else class="section-block">
            <div class="section-title">Your Cars</div>
            <button
              v-for="vehicle in historyVehicles"
              :key="historyListKey(vehicle)"
              type="button"
              class="list-card history-list-row"
              @click="openHistoryDetail(vehicle)">
              <img v-if="vehicle.thumbnail" :src="vehicle.thumbnail" alt="" class="car-rep-thumb">
              <span class="car-rep-name">
                <strong>{{ vehicle.name }}</strong>
                <small>
                  {{ vehicle.sold ? "Sold" : "Owned" }}
                  <template v-if="vehicle.totalPercent > 0">, +{{ formatPercent(vehicle.totalPercent) }} buzz</template>
                </small>
              </span>
              <em>{{ vehicle.meetsAttended || 0 }} meets</em>
            </button>
          </div>
        </template>
      </template>
    </section>

    <section v-else class="tab-panel">
      <article v-if="activeInvite" class="detail-card">
        <div class="detail-head">
          <h2>{{ activeInvite.typeName || activeInvite.type }}</h2>
          <span class="chip">{{ currentMeet?.phase || "waiting" }}</span>
        </div>
        <div class="info-row"><span>Location</span><strong>{{ activeInvite.location }}</strong></div>
        <div class="info-row" v-if="activeInvite.clubName"><span>Club</span><strong>{{ activeInvite.clubName }}</strong></div>
        <div class="info-row"><span>Status</span><strong>{{ activeStatusLabel }}</strong></div>
        <div class="info-row"><span>Time</span><strong>{{ activeTimeLabel }}</strong></div>

        <div class="active-grid">
          <div>
            <span>Meet Cars</span>
            <strong>{{ meetPurchaseVehicles.length }}</strong>
            <small>{{ meetOffersAvailable ? "Walk up to make offers" : "Meet vehicles nearby" }}</small>
          </div>
          <div v-if="saleOffersAvailable">
            <span>Your Offers</span>
            <strong>{{ saleOfferCount }}</strong>
            <small v-if="saleData.needsVehicleAtMeet">Park your car at the meet</small>
            <small v-else-if="saleOfferCount">Tap View Offers below</small>
            <small v-else>Offers may arrive during the meet</small>
          </div>
        </div>

        <div v-if="saleOffersAvailable" class="sale-status">
          <strong>{{ saleData.guaranteed ? "Bazaar Sale" : "Your Car" }}</strong>
          <span v-if="saleData.sold">Sold</span>
          <span v-else-if="saleData.needsVehicleAtMeet">Park your vehicle at the meet to receive offers</span>
          <span v-else-if="saleData.guaranteed">{{ saleData.guaranteedGenerated || 0 }}/{{ saleData.guaranteedTarget || 0 }} guaranteed offers</span>
          <span v-else>Offers may arrive during the meet</span>
        </div>

        <div class="phone-action-buttons">
          <BngButton v-if="saleOffersAvailable" @click="openSaleOffers" accent="secondary">View Offers</BngButton>
          <BngButton @click="cancelRSVP" accent="secondary">Cancel</BngButton>
          <BngButton @click="setRoute" accent="main">Set Route</BngButton>
        </div>
      </article>

      <div v-else class="empty-card">
        <h2>No Active Meet</h2>
        <p>Accept an invite to start a meet.</p>
      </div>
    </section>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from "vue"
import { BngButton, ACCENTS } from "@/common/components/base"
import { lua, useBridge } from "@/bridge"
import { formatMoney as formatAmount } from "../utils/units.js"

const { events } = useBridge()
const MEET_CLOCK_TICK_MS = 1000
const attendanceLevels = ["LOW", "MEDIUM", "HIGH"]

const tab = ref("social")
const socialSection = ref("mail")
const selectedAttendance = ref("MEDIUM")
const selectedInvite = ref(null)
const overview = ref({ reputation: 0, maxReputation: 100, pendingInviteCap: 3, invites: [], activeInvite: null })
const clubData = ref(null)
const openClubGroups = ref({ active: false, invites: false })
const expandedClubId = ref(null)

const toggleClub = clubId => {
  expandedClubId.value = expandedClubId.value === clubId ? null : clubId
}
const popularityVehicles = ref([])
const historyVehicles = ref([])
const historyDetail = ref(null)
const historySubview = ref("list")
const now = ref(Math.floor(Date.now() / 1000))
let timer = null

const asArray = value => {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object") return []
  return Object.values(value)
}

const invites = computed(() => asArray(overview.value.invites))
const activeInvite = computed(() => overview.value.activeInvite || null)
const currentMeet = computed(() => overview.value.currentMeet || null)
const meetPurchaseVehicles = computed(() => asArray(overview.value.meetPurchaseVehicles))
const saleData = computed(() => overview.value.sale || overview.value.bazaar || null)
const saleOfferCount = computed(() => asArray(saleData.value?.offers).length)
const displayRep = computed(() => Math.round(Number(overview.value.reputation || 0)))
const joinedClubs = computed(() => asArray(clubData.value?.joinedClubs))
const availableClubs = computed(() => asArray(clubData.value?.availableClubs))
const joinedClubCount = computed(() => joinedClubs.value.length)
const activeClubCount = computed(() => joinedClubs.value.filter(club => club.active).length)
const offerMeetTypes = ["SHOWCASE", "BAZAAR", "CLUB", "STREET_CRUISE", "ELITE"]
const meetOffersAvailable = computed(() => offerMeetTypes.includes(currentMeet.value?.type))
const saleOffersAvailable = computed(() => meetOffersAvailable.value && !!saleData.value)
const historySceneEvents = computed(() => asArray(historyDetail.value?.sceneEvents))
const historyFreeroamTimes = computed(() => asArray(historyDetail.value?.freeroamTimes))
const socialTiles = computed(() => [
  { id: "mail", label: "Mail", count: invites.value.length },
  { id: "clubs", label: "Clubs", count: joinedClubCount.value },
  { id: "popularity", label: "Popularity", count: popularityVehicles.value.length },
  { id: "history", label: "History", count: historyVehicles.value.length },
])

watch(socialSection, section => {
  if (section !== "history") {
    historySubview.value = "list"
    historyDetail.value = null
  }
})

const activeStatusLabel = computed(() => {
  if (!currentMeet.value) return "Waiting"
  if (currentMeet.value.phase === "waiting") return "Drive to the meet"
  if (currentMeet.value.phase === "showcase") return "Meet active"
  if (currentMeet.value.phase === "cruise") return "Cruise active"
  if (currentMeet.value.phase === "ending") return "Wrapping up"
  if (currentMeet.value.phase === "cleanup") return "Leaving meet"
  return currentMeet.value.phase || "Active"
})

const activeTimeLabel = computed(() => {
  const meet = currentMeet.value
  if (!meet) return "-"
  if (!meet.arrived || !meet.arrivalTime) return "Starts on arrival"
  const remaining = Math.max(0, Number(meet.arrivalTime) + Number(meet.duration || 600) - now.value)
  return formatDuration(remaining)
})

let isUnmounted = false

onMounted(async () => {
  await refreshOverview()
  if (isUnmounted) return
  events.on("onCarMeetOverview", updateOverview)
  events.on("onCarMeetPopularityData", updatePopularityData)
  events.on("onVehicleSceneHistory", updateHistoryDetail)
  timer = setInterval(() => {
    now.value = Math.floor(Date.now() / 1000)
  }, MEET_CLOCK_TICK_MS)
})

onUnmounted(() => {
  isUnmounted = true
  events.off("onCarMeetOverview", updateOverview)
  events.off("onCarMeetPopularityData", updatePopularityData)
  events.off("onVehicleSceneHistory", updateHistoryDetail)
  if (timer) clearInterval(timer)
})

const refreshOverview = async () => {
  updateOverview(await lua.overhaul_career_carmeets_carmeets.checkAvailableMeets())
  lua.overhaul_career_carmeets_carmeets.requestRSVPData()
  refreshSocialData()
}

const refreshSocialData = async () => {
  updatePopularityData(await lua.overhaul_career_carmeets_reputation.requestPhoneSocialData())
}

const updateOverview = data => {
  if (!data) return
  overview.value = data
  clubData.value = data.clubs || clubData.value
  if (selectedInvite.value) {
    selectedInvite.value = invites.value.find(invite => invite.id === selectedInvite.value.id) || null
  }
}

const isInviteExpanded = invite => !!(selectedInvite.value && selectedInvite.value.id === invite.id)

const toggleInvite = invite => {
  selectedInvite.value = isInviteExpanded(invite) ? null : invite
}

const updatePopularityData = data => {
  if (!data) return
  popularityVehicles.value = asArray(data.vehicles)
  historyVehicles.value = asArray(data.historyVehicles)
}

const updateHistoryDetail = data => {
  if (!data || !data.inventoryId) {
    historyDetail.value = null
    return
  }
  historyDetail.value = data
  historySubview.value = "detail"
}

const historyListKey = vehicle => {
  if (vehicle.archiveIndex) return `archive-${vehicle.archiveIndex}`
  return `owned-${vehicle.inventoryId}`
}

const openHistoryDetail = async vehicle => {
  if (!vehicle) return
  const archiveIndex = vehicle.archiveIndex ? Number(vehicle.archiveIndex) : null
  await lua.overhaul_career_carmeets_reputation.requestVehicleHistory(Number(vehicle.inventoryId), archiveIndex)
}

const closeHistoryDetail = () => {
  historySubview.value = "list"
  historyDetail.value = null
}

const formatHistoryTime = timestamp => {
  const seconds = Number(timestamp || 0)
  if (!seconds) return "Unknown time"
  return new Date(seconds * 1000).toLocaleString()
}

const formatHistoryEventMeta = event => {
  const parts = []
  const rep = Number(event.playerRep || 0) + Number(event.carRepDelta || 0)
  if (rep) parts.push(`+${formatRep(rep)} rep`)
  if (event.buzzDelta) parts.push(`+${formatPercent(event.buzzDelta)} buzz`)
  if (event.price) parts.push(`$${formatMoney(event.price)}`)
  return parts.length ? parts.join(", ") : ""
}

const formatDuration = seconds => {
  const minutes = Math.floor(seconds / 60)
  const secs = seconds % 60
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h ${minutes % 60}m`
  return `${minutes}m ${secs.toString().padStart(2, "0")}s`
}

const formatRemaining = expiresAt => {
  const seconds = Math.max(0, Number(expiresAt || 0) - now.value)
  const minutes = Math.ceil(seconds / 60)
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h ${minutes % 60}m`
  return `${minutes}m`
}

const formatMoney = value => {
  // Meet rewards use Math.round ties and retain the old negative-zero label.
  const amount = Math.round(Number(value || 0))
  if (!Number.isFinite(amount) || Object.is(amount, -0)) return amount.toLocaleString()
  return formatAmount(amount, { decimals: 0 })
}

const formatPercent = value => `${Number(value || 0).toFixed(2)}%`

const formatRep = value => {
  const amount = Number(value || 0)
  if (Math.abs(amount - Math.round(amount)) < 0.05) return String(Math.round(amount))
  return amount.toFixed(1)
}

const joinClub = async clubId => {
  clubData.value = await lua.overhaul_career_carmeets_carmeets.joinClub(clubId)
  updateOverview(await lua.overhaul_career_carmeets_carmeets.checkAvailableMeets())
}

const leaveClub = async clubId => {
  clubData.value = await lua.overhaul_career_carmeets_carmeets.leaveClub(clubId)
  updateOverview(await lua.overhaul_career_carmeets_carmeets.checkAvailableMeets())
}

let rsvpBusy = false

const rsvp = async () => {
  if (!selectedInvite.value || rsvpBusy) return
  rsvpBusy = true
  try {
    const accepted = await lua.overhaul_career_carmeets_carmeets.rsvpToMeet(selectedInvite.value.id, selectedAttendance.value)
    updateOverview(await lua.overhaul_career_carmeets_carmeets.checkAvailableMeets())
    if (accepted) {
      tab.value = "active"
      await lua.overhaul_career_carmeets_carmeets.requestRSVPData()
    }
  } finally {
    rsvpBusy = false
  }
}

const decline = async () => {
  if (!selectedInvite.value || rsvpBusy) return
  rsvpBusy = true
  try {
    await lua.overhaul_career_carmeets_carmeets.decline(selectedInvite.value.id)
    updateOverview(await lua.overhaul_career_carmeets_carmeets.checkAvailableMeets())
  } finally {
    rsvpBusy = false
  }
}

const cancelRSVP = async () => {
  if (rsvpBusy) return
  rsvpBusy = true
  try {
    await lua.overhaul_career_carmeets_carmeets.cancelRSVP()
    updateOverview(await lua.overhaul_career_carmeets_carmeets.checkAvailableMeets())
  } finally {
    rsvpBusy = false
  }
  tab.value = "social"
}

const setRoute = () => {
  lua.overhaul_career_carmeets_carmeets.setRoute()
}

const openSaleOffers = () => {
  lua.overhaul_career_carmeets_carmeets.openMeetSaleOffers()
}
</script>

<style scoped lang="scss">
.scene-app {
  box-sizing: border-box;
  height: 100%;
  color: #f4f0ea;
  background: #12161d;
  font-size: 0.9em;
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 52px 10px 24px;
  overflow-y: auto;
  overflow-x: hidden;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 255, 255, 0.18) transparent;
}

.scene-app::-webkit-scrollbar {
  width: 4px;
}

.scene-app::-webkit-scrollbar-track {
  background: transparent;
}

.scene-app::-webkit-scrollbar-thumb {
  background: rgba(255, 255, 255, 0.16);
  border-radius: 999px;
}

.list-card,
.detail-card,
.empty-card {
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 18px;
  background: #171c25;
  box-shadow: 0 14px 34px rgba(0, 0, 0, 0.22);
}

.info-row span,
.active-grid span,
.active-grid small,
.list-card small,
.sale-status span {
  color: rgba(228, 233, 242, 0.72);
}

.tabs {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 6px;
  padding: 3px;
  border-radius: 16px;
  border: 1px solid rgba(255, 255, 255, 0.06);
  background: rgba(13, 16, 22, 0.62);
}

.social-tabs {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 6px;
  padding: 3px;
  border-radius: 16px;
  border: 1px solid rgba(255, 255, 255, 0.06);
  background: rgba(13, 16, 22, 0.62);
}

.tabs button,
.social-tabs button {
  color: rgba(214, 222, 235, 0.72);
  border: none;
  border-radius: 12px;
  background: transparent;
  transition: transform 0.16s ease, background-color 0.16s ease, border-color 0.16s ease, color 0.16s ease;
}

.expand-card {
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 18px;
  background: #171c25;
  box-shadow: 0 14px 34px rgba(0, 0, 0, 0.22);
  overflow: hidden;
  transition: background-color 0.16s ease, border-color 0.16s ease;
}

.expand-card.expanded {
  border-color: rgba(228, 114, 56, 0.32);
  background: #1a2029;
}

button.expand-row {
  width: 100%;
  margin: 0;
  padding: 14px;
  font: inherit;
  text-align: left;
  color: #f4f0ea;
  appearance: none;
  cursor: pointer;
  border: none;
  background: transparent;
  transition: transform 0.16s ease;
}

button.expand-row.focus-visible {
  outline: 2px solid rgba(228, 114, 56, 0.85);
  outline-offset: -2px;
}

.expand-row strong,
.expand-row small {
  display: block;
}

.expand-row small {
  color: rgba(228, 233, 242, 0.72);
}

.expand-detail {
  padding: 0 14px 14px;
}

.club-group {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.club-tile {
  border: 1px solid rgba(255, 255, 255, 0.07);
  border-radius: 14px;
  background: #121720;
  overflow: hidden;
  transition: border-color 0.16s ease;
}

.club-tile.expanded {
  border-color: rgba(228, 114, 56, 0.4);
}

button.club-tile-row {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: center;
  gap: 10px;
  width: 100%;
  margin: 0;
  padding: 11px 12px;
  font: inherit;
  text-align: left;
  color: #f4f0ea;
  appearance: none;
  cursor: pointer;
  border: none;
  background: transparent;
}

button.club-tile-row:active {
  transform: scale(0.985);
}

button.club-tile-row.focus-visible {
  outline: 2px solid rgba(228, 114, 56, 0.85);
  outline-offset: -2px;
}

.club-tile-row strong,
.club-tile-row small {
  display: block;
}

.club-tile-row small {
  margin-top: 2px;
  font-size: 0.82em;
  color: rgba(228, 233, 242, 0.66);
}

.club-tile-row em {
  padding: 4px 9px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.05);
  font-style: normal;
  font-size: 0.75em;
  font-weight: 700;
}

.club-tile-row em.positive {
  color: #9fe0a8;
  background: rgba(96, 190, 110, 0.12);
}

.club-tile-row em.muted {
  color: rgba(228, 233, 242, 0.55);
}

.club-tile-detail {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 10px 12px 12px;
  border-top: 1px solid rgba(255, 255, 255, 0.06);
}

.club-tile-detail .info-row {
  font-size: 0.88em;
}

.club-tile-detail .info-row span {
  color: rgba(228, 233, 242, 0.62);
}

.club-tile-detail .info-row strong {
  text-align: right;
}

.club-tile-action {
  margin-top: 6px;
  width: 100%;
}

.club-group-empty {
  margin: 0;
  padding: 4px 2px;
  font-size: 0.9em;
  color: rgba(228, 233, 242, 0.72);
}

.tabs button,
.social-tabs button {
  padding: 10px 12px;
  font-weight: 700;
}

.tabs button:active,
.social-tabs button:active,
.expand-row:active {
  transform: scale(0.985);
}

.tabs button.active,
.social-tabs button.active {
  color: #fff7f1;
  background: linear-gradient(180deg, rgba(224, 107, 50, 0.92), rgba(180, 76, 28, 0.92));
  box-shadow: 0 8px 18px rgba(180, 76, 28, 0.26);
}

.list-card.selected {
  border-color: rgba(228, 114, 56, 0.32);
  background: #1a2029;
}

.social-tabs span,
.social-tabs strong {
  display: block;
}

.social-tabs span {
  font-size: 0.72em;
}

.tab-panel,
.invite-list,
.section-block {
  display: flex;
  flex-direction: column;
  gap: 9px;
}

.list-card {
  padding: 14px;
}

.expand-row,
.info-row,
.detail-head,
.sale-status {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: center;
  gap: 8px;
}

.list-card strong,
.list-card small {
  display: block;
}

.card-top {
  display: flex;
  justify-content: space-between;
  margin-bottom: 8px;
  color: rgba(219, 226, 237, 0.66);
  font-size: 0.7em;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.expand-row em,
.chip {
  font-style: normal;
  font-size: 0.78em;
}

.detail-card {
  padding: 14px;
}

.rep-card {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: center;
}

.rep-card span {
  color: rgba(228, 233, 242, 0.72);
}

.rep-card strong {
  font-size: 1.35em;
}

.subview-back {
  align-self: flex-start;
  padding: 8px 12px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 12px;
  background: #1a2029;
  color: #f4f0ea;
  font-weight: 700;
  cursor: pointer;
}

.subview-hint {
  margin: 0;
  color: rgba(219, 226, 237, 0.66);
  font-size: 0.82em;
  line-height: 1.35;
}

.nav-row,
.history-list-row {
  color: #f4f0ea;
  font: inherit;
}

.nav-row {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: center;
  gap: 8px;
  width: 100%;
  text-align: left;
  cursor: pointer;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: #171c24;
}

.nav-row strong,
.nav-row small,
.history-list-row strong {
  display: block;
}

.nav-row strong,
.history-list-row .car-rep-name strong {
  color: #f4f0ea;
}

.nav-row small {
  margin-top: 4px;
  color: rgba(219, 226, 237, 0.66);
  font-size: 0.78em;
}

.nav-row em {
  font-style: normal;
  font-size: 0.78em;
  color: rgba(228, 114, 56, 0.95);
  font-weight: 700;
}

.car-rep-row {
  display: grid;
  grid-template-columns: auto 1fr auto;
  align-items: center;
  gap: 10px;
}

.car-rep-thumb {
  width: 44px;
  height: 44px;
  border-radius: 10px;
  object-fit: cover;
  background: #3b3b3b;
}

.car-rep-name {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 700;
  color: #f4f0ea;
}

.car-rep-row .car-rep-name {
  color: #f4f0ea;
}

.car-rep-meta {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
}

.car-rep-meta small {
  color: rgba(219, 226, 237, 0.66);
  font-size: 0.72em;
}

.car-rep-value {
  font-size: 1.1em;
  color: #f0c49a;
}

.history-list-row {
  display: grid;
  grid-template-columns: auto 1fr auto;
  align-items: center;
  gap: 10px;
  width: 100%;
  text-align: left;
  cursor: pointer;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: #171c24;
}

.history-event-row {
  display: grid;
  grid-template-columns: auto 1fr auto;
  align-items: center;
  gap: 10px;
  width: 100%;
  text-align: left;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: #171c24;
  color: #f4f0ea;
}

.history-list-row strong,
.history-list-row small,
.history-event-row strong,
.history-event-row small {
  display: block;
}

.history-event-row strong {
  color: #f4f0ea;
}

.history-list-row small,
.history-event-row small {
  margin-top: 4px;
  color: rgba(219, 226, 237, 0.66);
  font-size: 0.78em;
}

.history-list-row em,
.history-event-row em {
  font-style: normal;
  font-size: 0.78em;
  color: rgba(228, 114, 56, 0.95);
  font-weight: 700;
  text-align: right;
}

.history-detail-head .stat-grid {
  margin-top: 10px;
}

.detail-card h2,
.empty-card h2 {
  margin: 0;
  font-size: 1.2em;
}

.meet-image {
  width: 100%;
  aspect-ratio: 16 / 9;
  border-radius: 14px;
  background-color: #3b3b3b;
  object-fit: cover;
  margin-bottom: 12px;
}

.chip {
  padding: 6px 9px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.05);
  color: rgba(234, 239, 245, 0.72);
}

.info-row {
  margin-top: 7px;
}

.negative {
  color: #ff8e8e;
}

.attendance-grid,
.phone-action-buttons,
.active-grid,
.stat-grid {
  display: grid;
  gap: 8px;
  margin-top: 10px;
}

.attendance-grid {
  grid-template-columns: repeat(3, minmax(0, 1fr));
}

.phone-action-buttons,
.active-grid,
.stat-grid {
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.scene-app :deep(.bng-button) {
  width: 100%;
  min-width: 0;
  border-radius: 999px;
  overflow: hidden;
}

.scene-app :deep(.bng-button .label) {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.active-grid div,
.stat-grid div,
.sale-status {
  padding: 12px;
  border-radius: 14px;
  border: 1px solid rgba(255, 255, 255, 0.06);
  background: rgba(255, 255, 255, 0.03);
}

.active-grid strong,
.stat-grid strong {
  display: block;
  font-size: 1.45em;
}

.stat-grid span {
  color: rgba(228, 233, 242, 0.72);
}

.section-title {
  color: rgba(244, 193, 156, 0.82);
  font-weight: 800;
  letter-spacing: 0.02em;
}

.empty-card {
  padding: 22px 15px;
  text-align: center;
  color: rgba(228, 233, 242, 0.72);
}

.empty-card.compact {
  padding: 16px 15px;
}








</style>
