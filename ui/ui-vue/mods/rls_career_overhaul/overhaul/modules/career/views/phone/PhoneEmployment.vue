<template>
  <div class="employment" ref="screenRef" v-bng-ui-nav-scroll v-bng-on-ui-nav:tab_l="() => switchTab('hiring')" v-bng-on-ui-nav:tab_r="() => switchTab('current')">
    <div v-if="!loaded" class="empty"><p>Loading employment…</p></div>
    <div v-else-if="error" class="empty"
      ><p>Unable to load employment right now.</p
      ><button type="button" class="btn btn-primary" @click="refresh">Try again</button></div
    >
    <div v-else-if="state.unlocked === false" class="empty"
      ><BngIcon :type="icons.lockClosed" /><h3>Employment is off</h3
      ><p>Company employment is disabled for this career. Independent work stays open in the Job Broker.</p></div
    >

    <template v-else>
      <!-- Service job: pick the vehicle for the day -->
      <section v-if="state.roleplaySetup" class="scroll page" v-bng-ui-nav-scroll>
        <div class="hero">
          <img v-if="state.employerPreview" :src="state.employerPreview" alt="" />
          <div class="hero-copy"
            ><span class="kicker">Start of shift</span><strong>{{ translateLabel(state.employerName) }}</strong
            ><span>Choose your vehicle for the day</span></div
          >
        </div>
        <div class="stats">
          <div v-if="repLevel !== null" class="stat"
            ><span class="stat-key">Reputation</span
            ><span class="stat-value"
              >{{ translateLabel(state.employerRepLabel) || "Level " + repLevel }}
              <small v-if="state.employerRepLabel">Lv {{ repLevel }}</small></span
            ></div
          >
          <div v-if="skillStat" class="stat"
            ><span class="stat-key">{{ skillStat.label }}</span
            ><span class="stat-value">Lv {{ skillStat.level }}</span></div
          >
        </div>
        <ul class="fleet">
          <li class="vehicle personal" :class="{ picked: vehicleChoice?.personal }">
            <button type="button" class="vehicle-btn" :disabled="busy" @click="vehicleChoice = { personal: true }">
              <div class="vehicle-img icon-only"><BngIcon :type="icons.keys1" /></div>
              <div class="vehicle-copy"
                ><strong>Personal vehicle</strong><span class="pill soft">Your own risk</span></div
              >
            </button>
          </li>
          <li
            v-for="vehicle in state.roleplaySetup.vehicles"
            :key="`${vehicle.model}/${vehicle.config}`"
            class="vehicle"
            :class="{
              picked:
                !vehicleChoice?.personal &&
                vehicleChoice?.model === vehicle.model &&
                vehicleChoice?.config === vehicle.config,
              locked: vehicle.available === false,
            }"
          >
            <button
              type="button"
              class="vehicle-btn"
              :disabled="busy || vehicle.available === false"
              @click="vehicleChoice = vehicle"
            >
              <div class="vehicle-img"
                ><img :src="vehicle.thumbnail" alt="" /><span v-if="vehicle.available === false" class="img-lock"
                  ><svg class="lock" viewBox="0 0 24 24">
                    <rect x="5" y="11" width="14" height="10" rx="2" />
                    <path d="M8 11V7a4 4 0 0 1 8 0v4" /></svg></span
              ></div>
              <div class="vehicle-copy">
                <strong>{{ translateLabel(vehicle.name) }}</strong>
                <span v-if="vehicle.available !== false" class="pill soft">Company vehicle</span>
                <span v-else class="pill lock-pill" :title="vehicle.disableReason || vehicle.serviceUnlockLabel">{{
                  vehicleUnlockText(vehicle)
                }}</span>
              </div>
            </button>
          </li>
        </ul>
        <p v-if="!availableRoleplayVehicles.length" class="muted">{{
          state.roleplaySetup.unavailableReason ||
          "No company vehicles available at your current reputation or skill level."
        }}</p>
        <p v-if="vehicleChoice && !vehicleChoice.personal" class="note warn"
          >Damage to a company vehicle comes out of held pay and counts against you.</p
        >
        <p v-if="shiftError" class="status-error">{{ shiftError }}</p>
        <div class="actions">
          <button type="button" class="btn" :disabled="busy" @click="closeServiceSetup">Back</button>
          <button
            type="button"
            class="btn btn-primary"
            :disabled="busy || !vehicleChoice"
            @click="startServiceShift"
            >{{ busy ? "Starting…" : "Start shift" }}</button
          >
        </div>
      </section>

      <template v-else>
        <div class="tabs">

          <button
            type="button"
            :class="{ active: tab === 'hiring' }"
            @click="
              tab = 'hiring';
              selectedListing = null;
            "
            >Hiring now<span v-if="listingCount" class="pill">{{ listingCount }}</span></button
          >
          <button
            type="button"
            :class="{ active: tab === 'current' }"
            @click="
              tab = 'current';
              selectedListing = null;
            "
            >Current<span
              v-if="hasCurrentJob || state.headhunterOffer"
              class="tab-dot"
              :class="{ alert: !!state.headhunterOffer }"
            ></span
          ></button>
        </div>

        <!-- Hiring now -->
        <section v-if="tab === 'hiring'" class="scroll page" v-bng-ui-nav-scroll data-tutorial-id="employment-listings">
          <button v-if="state.devTools" type="button" class="btn dev-btn" :disabled="busy" @click="rollListings">{{
            busy ? "Rolling…" : "Roll new offers (dev)"
          }}</button>
          <p v-if="!canApply" class="note">{{ applyBlockedMessage }}</p>

          <template v-if="selectedListing">
            <div class="hero">
              <img v-if="selectedListing.preview" :src="selectedListing.preview" alt="" />
              <button
                type="button"
                class="icon-btn hero-close"
                aria-label="Back to openings"
                @click="selectedListing = null"
                ><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18" /></svg
              ></button>
              <div class="hero-copy"
                ><span
                  v-if="
                    selectedListing.orgName &&
                    translateLabel(selectedListing.orgName) !== translateLabel(selectedListing.facName)
                  "
                  class="kicker"
                  >{{ translateLabel(selectedListing.orgName) }}</span
                ><strong>{{ translateLabel(selectedListing.facName || selectedListing.orgName) }}</strong
                ><span>Your Logistics level {{ playerLevelLabel }}</span></div
              >
            </div>
            <div class="block">
              <div class="block-head"><div class="kicker">Assignments</div></div>
              <ul v-if="listingOfferings(selectedListing).length" class="tiles">
                <li
                  v-for="row in listingOfferings(selectedListing)"
                  :key="row.label"
                  class="tile"
                  :class="{ locked: !row.available }"
                >
                  <strong>{{ row.label }}</strong>
                  <span v-if="row.available" class="pill ok">Ready</span>
                  <span v-else class="pill lock-pill" :title="'Logistics level ' + row.minLevel"
                    ><svg class="lock" viewBox="0 0 24 24">
                      <rect x="5" y="11" width="14" height="10" rx="2" />
                      <path d="M8 11V7a4 4 0 0 1 8 0v4" /></svg
                    >Lv {{ row.minLevel }}</span
                  >
                </li>
              </ul>
              <p v-else class="muted">{{ selectedListing.workSummary || "No assignments listed." }}</p>
            </div>
            <p v-if="selectedListing.rehireBlocked" class="note warn"
              >Rehire cooldown: {{ selectedListing.rehireDaysRemaining || 0 }} day{{
                Number(selectedListing.rehireDaysRemaining) === 1 ? "" : "s"
              }}
              left.</p
            >
            <p
              v-else-if="!availableOfferings(selectedListing).length && selectedListing.skillMessage"
              class="note warn"
              >{{ selectedListing.skillMessage }}</p
            >
            <p v-if="applicationError" class="note warn">{{ applicationError }}</p>
            <PhoneLayer v-if="confirmingJobChange" class="abandon-panel" label="Confirm employment action" @close="confirmingJobChange = false">
              <div class="abandon-panel-row"><span class="abandon-panel-title">End current employment?</span></div>
              <p class="abandon-panel-detail"
                >You'll leave {{ translateLabel(state.logisticsEmployerName) }} and apply to
                {{ translateLabel(selectedListing.facName || selectedListing.orgName) }}. Company equipment will be
                returned and unfinished work will end.</p
              >
              <div class="abandon-panel-actions">
                <button type="button" class="btn" bng-scoped-nav-autofocus :disabled="busy" @click="confirmingJobChange = false"
                  >Keep current job</button
                >
                <button
                  type="button"
                  class="btn btn-quiet-danger"
                  :disabled="busy"
                  @click="apply(selectedListing, true)"
                  >{{ busy ? "Applying…" : "End employment and apply" }}</button
                >
              </div>
            </PhoneLayer>
            <div v-else class="actions">
              <button type="button" class="btn" :disabled="busy" @click="selectedListing = null">Back</button>
              <button
                type="button"
                class="btn btn-primary"
                :disabled="busy || !canApplyToListing(selectedListing)"
                @click="apply(selectedListing)"
                >{{ applyButtonLabel(selectedListing) }}</button
              >
            </div>
          </template>

          <div v-else-if="!state.listings?.length" class="empty"
            ><BngIcon :type="icons.cardboardBox" /><h3>Nothing hiring</h3><p>{{ emptyListingsMessage }}</p></div
          >
          <ul v-else class="listings">
            <li v-for="listing in state.listings" :key="listing.facId || listing.orgId">
              <button
                type="button"
                class="listing"
                :data-fk="listing.facId || listing.orgId"
                :class="{ locked: listing.skillLocked || listing.rehireBlocked }"
                @click="openListing(listing)"
              >
                <span class="listing-img"
                  ><img v-if="listing.preview" :src="listing.preview" alt="" loading="lazy" /><BngIcon
                    v-else
                    :type="icons.cardboardBox"
                /></span>
                <span class="listing-copy">
                  <strong>{{ translateLabel(listing.facName || listing.orgName) }}</strong>
                  <span class="pills">
                    <span
                      v-for="row in listingOfferings(listing).slice(0, 3)"
                      :key="row.label"
                      class="pill"
                      :class="{ 'lock-pill': !row.available }"
                      ><svg v-if="!row.available" class="lock" viewBox="0 0 24 24">
                        <rect x="5" y="11" width="14" height="10" rx="2" />
                        <path d="M8 11V7a4 4 0 0 1 8 0v4" /></svg
                      >{{ row.label }}<b v-if="!row.available" class="pill-lv">Lv {{ row.minLevel }}</b></span
                    >
                    <span v-if="listingOfferings(listing).length > 3" class="pill soft"
                      >+{{ listingOfferings(listing).length - 3 }}</span
                    >
                    <span v-if="!listingOfferings(listing).length && listing.workSummary" class="pill soft">{{
                      listing.workSummary
                    }}</span>
                  </span>
                </span>
                <span class="pill listing-state" :class="listingStateClass(listing)">{{
                  offerActionLabel(listing)
                }}</span>
              </button>
            </li>
          </ul>
        </section>

        <!-- Current -->
        <section v-else class="scroll page" v-bng-ui-nav-scroll>
          <div v-if="state.headhunterOffer" class="card">
            <div class="hero small">
              <img v-if="headhunterPreview" :src="headhunterPreview" alt="" />
              <div class="hero-copy"
                ><span class="kicker">Headhunter offer</span
                ><strong>{{ translateLabel(state.headhunterOffer.facName || state.headhunterOffer.orgName) }}</strong
                ><span
                  >Logistics {{ state.headhunterOffer.level }} unlocked {{ state.headhunterOffer.label }}</span
                ></div
              >
            </div>
            <div v-if="state.headhunterOffer.workSummary" class="pills"
              ><span v-for="w in splitSummary(state.headhunterOffer.workSummary)" :key="w" class="pill">{{
                w
              }}</span></div
            >
            <p class="note warn">Accepting ends your current job. You start there right away.</p>
            <div class="actions">
              <button type="button" class="btn" :disabled="busy" @click="dismissHeadhunter">Dismiss</button>
              <button type="button" class="btn btn-primary" :disabled="busy" @click="acceptHeadhunter">{{
                busy ? "Switching…" : "Accept switch"
              }}</button>
            </div>
          </div>

          <template v-if="state.employed || state.onShift">
            <div class="hero">
              <img v-if="state.employerPreview" :src="state.employerPreview" alt="" />
              <span class="hero-status pill" :class="state.onShift ? 'ok' : ''">{{
                state.onShift ? "On shift" : "Employed"
              }}</span>
              <div class="hero-copy"
                ><span class="kicker">Your employer</span><strong>{{ translateLabel(state.employerName) }}</strong
                ><span>{{ currentStatusLine }}</span></div
              >
            </div>
            <div class="stats">
              <div v-if="repLevel !== null" class="stat"
                ><span class="stat-key">Reputation</span
                ><span class="stat-value"
                  >{{ translateLabel(state.employerRepLabel) || "Level " + repLevel }}
                  <small v-if="state.employerRepLabel">Lv {{ repLevel }}</small></span
                ></div
              >
              <div v-if="skillStat" class="stat"
                ><span class="stat-key">{{ skillStat.label }}</span
                ><span class="stat-value">Lv {{ skillStat.level }}</span></div
              >
              <div v-if="wagesHeld > 0" class="stat money"
                ><span class="stat-key">{{ state.assignment?.openEnded ? "Today's wages" : "Wages held" }}</span
                ><span class="stat-value">{{ money(wagesHeld) }}</span></div
              >
              <div v-if="bonusHeld > 0" class="stat money"
                ><span class="stat-key">Demand bonus</span><span class="stat-value">{{ money(bonusHeld) }}</span></div
              >
            </div>
            <div v-if="state.assignment" class="block">
              <div class="kicker">Current assignment</div>
              <p class="assignment">{{ state.assignment.label }}</p>
              <p v-if="state.assignment.busShift && state.assignment.subtext" class="muted">{{
                state.assignment.subtext
              }}</p>
              <p v-if="state.assignment.yardDropOffPending" class="muted"
                >Drop the truck off at the yard to collect pay and end the day.</p
              >
            </div>
            <p v-if="state.showDamageNotice" class="note warn"
              >Equipment damage this shift. Further incidents affect held pay.</p
            >
            <p v-if="shiftError" class="status-error">{{ shiftError }}</p>
            <PhoneLayer v-if="state.assignment?.canAbandonAssignment && confirmingAbandon" class="abandon-panel" label="Confirm employment action" @close="cancelAbandonConfirm">
              <div class="abandon-panel-row">
                <span class="abandon-panel-title">Abandon this assignment?</span>
                <span class="abandon-panel-fine">{{ money(state.assignment.abandonFine || 0) }}</span>
              </div>
              <p class="abandon-panel-detail"
                >This ends your day and returns company equipment. You stay employed. Standard delivery fines and
                reputation penalties apply.</p
              >
              <div class="abandon-panel-actions">
                <button type="button" class="btn" bng-scoped-nav-autofocus :disabled="busy" @click="cancelAbandonConfirm">Keep working</button>
                <button type="button" class="btn btn-quiet-danger" :disabled="busy" @click="confirmAbandonAssignment">
                  {{ busy ? "Abandoning…" : "Confirm abandon" }}
                </button>
              </div>
            </PhoneLayer>
            <PhoneLayer v-if="confirmingQuit" class="abandon-panel" label="Confirm employment action" @close="confirmingQuit = false">
              <div class="abandon-panel-row">
                <span class="abandon-panel-title">Quit this job?</span>
                <span v-if="wagesHeld > 0" class="abandon-panel-fine">{{ money(wagesHeld) }}</span>
              </div>
              <p class="abandon-panel-detail">
                {{ wagesHeld > 0 ? "Held wages are forfeited. " : "" }}Company equipment is returned{{
                  state.onShift || state.assignment?.held
                    ? ", company cargo is discarded and delivery fines apply"
                    : ""
                }}. Your own deliveries are kept.
              </p>
              <div class="abandon-panel-actions">
                <button type="button" class="btn" bng-scoped-nav-autofocus :disabled="quitting" @click="confirmingQuit = false"
                  >Keep job</button
                >
                <button type="button" class="btn btn-quiet-danger" :disabled="quitting" @click="quit">{{
                  quitting ? "Quitting…" : "Confirm quit"
                }}</button>
              </div>
            </PhoneLayer>
            <div class="actions stack">
              <button
                v-if="state.employed && !state.onShift && !state.assignment?.held"
                type="button"
                class="btn btn-primary"
                :disabled="busy || navigating"
                @click="navigateToYard"
                >{{ navigating ? "Setting route…" : "Navigate to yard" }}</button
              >
              <button
                v-if="!state.roleplayFacility && (state.onShift || state.assignment?.held)"
                type="button"
                class="btn btn-primary"
                :disabled="busy"
                @click="openYard"
                >{{ busy ? "Opening…" : "Open shift screen" }}</button
              >
              <button
                v-if="state.assignment?.canAbandonAssignment && !confirmingAbandon"
                type="button"
                class="btn btn-quiet-danger"
                :disabled="busy"
                @click="startAbandonConfirm"
                >Abandon assignment</button
              >
              <button
                v-if="state.assignment?.canEndDay"
                type="button"
                class="btn"
                :disabled="busy || state.assignment?.endAfterAssignment"
                @click="endDay"
                >{{ busy ? "Ending…" : state.assignment?.endAfterAssignment ? "Finishing day…" : "End day" }}</button
              >
              <button
                v-if="state.assignment?.canEndBusShiftNow"
                type="button"
                class="btn"
                :disabled="busy"
                @click="endBusShiftNow"
                >End day now</button
              >
              <button
                v-if="state.canReportAccident"
                type="button"
                class="btn"
                :class="{ 'btn-danger': accidentArmed }"
                :disabled="busy"
                @click="reportAccident"
                >{{
                  busy ? "Reporting…" : accidentArmed ? "Confirm equipment accident" : "Report equipment accident"
                }}</button
              >
              <button
                v-if="state.employed && !state.roleplayFacility && !state.assignment?.openEnded && !confirmingQuit"
                type="button"
                class="btn btn-quiet-danger"
                :disabled="quitting"
                @click="confirmingQuit = true"
                >Quit job</button
              >
            </div>
          </template>
          <div v-else-if="state.pending" class="card">
            <span class="kicker">Application pending</span>
            <strong class="card-title">{{ translateLabel(state.pending.orgName) }}</strong>
            <p class="muted">You'll get a notification if you're hired.</p>
          </div>
          <div v-else-if="!state.headhunterOffer" class="empty"
            ><BngIcon :type="icons.badgeRoundStar" /><h3>No current job</h3><p>Check Hiring now for openings.</p></div
          >
        </section>
      </template>
    </template>
  </div>
</template>

<script setup>
import PhoneLayer from '../../components/phone/PhoneLayer.vue'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { usePhoneViewFocus } from '../../components/phone/usePhoneViewFocus.js'
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { reportUiFailure } from "../../utils/safeLua"

import { ref, computed, onMounted, onBeforeUnmount, getCurrentInstance } from "vue";
import { lua, useBridge } from "@/bridge";
import { BngIcon, icons } from "@/common/components/base";
import { confirmEndBusShiftNow } from "../../utils/endBusShift";
import { acquireScope } from "../../utils/luaScopes";

const { events } = useBridge();
const translate = getCurrentInstance()?.appContext.config.globalProperties.$translate;
const screenRef = ref(null)
usePhoneScreen({ onBack: () => {
  if (confirmingAbandon.value) { confirmingAbandon.value = false; return true }
  if (confirmingQuit.value) { confirmingQuit.value = false; return true }
  if (confirmingJobChange.value) { confirmingJobChange.value = false; return true }
  if (state.value.roleplaySetup) { closeServiceSetup(); return true }
  if (selectedListing.value) { selectedListing.value = null; return true }
  return false
} })
function switchTab(value) {
  if (state.value.roleplaySetup || confirmingAbandon.value || confirmingQuit.value || confirmingJobChange.value) return
  tab.value = value; selectedListing.value = null
}
const loaded = ref(false);
const error = ref(false);
const quitting = ref(false);
const confirmingQuit = ref(false);
const confirmingJobChange = ref(false);
const applicationError = ref("");
const navigating = ref(false);
// Ground markers to the employer's yard, where the shift starts.
const navigateToYard = async () => {
  navigating.value = true;
  shiftError.value = "";
  try {
    const ok = await lua.overhaul_career_work_employment.navigateToYard(state.value.homeFacId);
    if (ok === false) shiftError.value = "Could not set a route to the company yard.";
  } catch (error) {
    reportUiFailure(error, "navigateToYard failed (PhoneEmployment)");
    shiftError.value = "Could not set a route to the company yard.";
  } finally {
    navigating.value = false;
  }
};
const busy = ref(false);
const shiftError = ref("");
const vehicleChoice = ref(null);
const accidentArmed = ref(false);
const confirmingAbandon = ref(false);
const tab = ref("hiring");
const selectedListing = ref(null);
const state = ref({
  employed: false,
  listings: [],
  unlocked: true,
});

usePhoneViewFocus(screenRef, () => [tab.value, selectedListing.value?.facId, !!state.value.roleplaySetup].join(':'), root => root?.querySelector('.scroll.page') || root)

function translateLabel(value) {
  if (value == null || value === "") return "";
  if (translate && typeof translate.instant === "function") {
    const translated = translate.instant(value);
    if (typeof translated === "string" && translated) return translated;
  }
  return String(value);
}

const money = (v) => `$${Math.round(Number(v) || 0).toLocaleString("en-US")}`;
const bonusHeld = computed(() => Math.round(Number(state.value.surgeBonusHeld) || 0));
const wagesHeld = computed(() => Math.round(Number(state.value.escrowMoney) || 0));
const repLevel = computed(() => {
  const n = Number(state.value.employerRepLevel);
  if (!Number.isFinite(n)) return null;
  if (state.value.employed || state.value.roleplayFacility || state.value.roleplaySetup) return n;
  return null;
});
const skillStat = computed(() => {
  const label = state.value.skillLabel;
  const level = Number(state.value.skillLevel);
  if (!label || !Number.isFinite(level)) return null;
  if (state.value.roleplaySetup || state.value.roleplayFacility || state.value.employed || state.value.onShift) {
    return { label, level };
  }
  return null;
});
const availableRoleplayVehicles = computed(() =>
  (state.value.roleplaySetup?.vehicles || []).filter((v) => v && v.available !== false),
);
function vehicleUnlockText(vehicle) {
  if (vehicle?.serviceUnlockLabel) return vehicle.serviceUnlockLabel;
  if (vehicle?.disableReason) return vehicle.disableReason;
  const rep = Number(vehicle?.reputationLevel);
  if (Number.isFinite(rep)) return `Rep Lv ${rep}`;
  return "Locked";
}
const splitSummary = (text) =>
  String(text || "")
    .split(/\s*[\u00b7\u2022,]\s*/)
    .map((x) => x.trim())
    .filter(Boolean);
const headhunterPreview = computed(() => {
  const offer = state.value.headhunterOffer;
  if (!offer) return "";
  if (offer.preview) return offer.preview;
  const match = (state.value.listings || []).find(
    (row) => (row.facId && row.facId === offer.facId) || (row.orgId && row.orgId === offer.orgId),
  );
  return match?.preview || "";
});
const currentStatusLine = computed(() => {
  const a = state.value.assignment;
  if (a?.busShift && a.subtext) return a.subtext;
  if (state.value.roleplayFacility && state.value.onShift) return "End day anytime to collect today's wages";
  if (state.value.onShift)
    return a?.openEnded
      ? "Open-ended shift. End day any time to return the truck"
      : "Pay is held until the assignment loop is done";
  return "Report to the company yard to clock in";
});
function listingStateClass(listing) {
  if (listing?.rehireBlocked) return "bad";
  if (listing?.skillLocked || (listingOfferings(listing).length && !availableOfferings(listing).length)) return "";
  return "accent";
}

const emptyListingsMessage = computed(() => {
  return "No company yards on this map have work you can do yet.";
});

const listingCount = computed(() => (state.value.listings || []).length);
const hasCurrentJob = computed(() => Boolean(state.value.employed || state.value.pending || state.value.onShift));
const canApply = computed(() => !state.value.pending && !state.value.onShift);
const applyBlockedMessage = computed(() => {
  if (state.value.onShift) return "Finish your current shift before applying for another job.";
  if (state.value.pending) return "Application pending — openings below stay visible.";
  return "";
});
const playerLevelLabel = computed(() => {
  const level = Number(state.value.deliveryLevel);
  return Number.isFinite(level) && level > 0 ? String(level) : "—";
});

function listingOfferings(listing) {
  if (!listing) return [];
  if (Array.isArray(listing.offerings) && listing.offerings.length) return listing.offerings;
  return [];
}

function availableOfferings(listing) {
  return listingOfferings(listing).filter((row) => row && row.available);
}

function promotionOfferings(listing) {
  return listingOfferings(listing).filter((row) => row && !row.available);
}

function formatOfferingNames(rows) {
  return (rows || [])
    .map((row) => row.label)
    .filter(Boolean)
    .join(", ");
}

function formatOfferingsWithLevels(rows) {
  return (rows || [])
    .map((row) => {
      const level = Number(row.minLevel);
      if (Number.isFinite(level) && level > 0) return `${row.label} (Logistics level ${level})`;
      return row.label;
    })
    .filter(Boolean)
    .join(", ");
}

function listingOfferLine(listing) {
  const offerings = listingOfferings(listing);
  if (offerings.length) return formatOfferingsWithLevels(offerings);
  return listing?.workSummary || "";
}

function canApplyToListing(listing) {
  if (!canApply.value || !listing) return false;
  if (
    state.value.employed &&
    listing.orgId === state.value.logisticsEmployerOrgId &&
    listing.facId === state.value.homeFacId
  )
    return false;
  if (listing.rehireBlocked || listing.skillLocked) return false;
  if (listingOfferings(listing).length && !availableOfferings(listing).length) return false;
  return true;
}

function offerActionLabel(listing) {
  if (listing?.rehireBlocked) {
    const days = Number(listing.rehireDaysRemaining) || 0;
    return days > 0 ? `${days}d` : "Blocked";
  }
  if (listing?.skillLocked || (listingOfferings(listing).length && !availableOfferings(listing).length)) {
    return "Locked";
  }
  return "View";
}

function applyButtonLabel(listing) {
  if (busy.value) return "Applying…";
  if (!canApply.value) return "Unavailable";
  if (
    state.value.employed &&
    listing?.orgId === state.value.logisticsEmployerOrgId &&
    listing?.facId === state.value.homeFacId
  )
    return "Current job";
  if (listing?.rehireBlocked) return "Rehire blocked";
  if (listing?.skillLocked || (listingOfferings(listing).length && !availableOfferings(listing).length)) {
    return "Not eligible yet";
  }
  return "Apply";
}

function openListing(listing) {
  selectedListing.value = listing || null;
  confirmingJobChange.value = false;
  applicationError.value = "";
}

const refresh = async () => {
  error.value = false;
  try {
    try {
      if (await lua.overhaul_career_career.isActive()) await acquireScope(lua, "career.employment");
    } catch (error) { reportUiFailure(error, "refresh (PhoneEmployment)") }
    const next = await lua.overhaul_career_work_employment.getUiState();
    if (!next) throw new Error("empty employment state");
    if (!loaded.value && next.onShift) tab.value = "current";
    state.value = next;
    accidentArmed.value = false;
    confirmingAbandon.value = false;
    if (selectedListing.value) {
      const id = selectedListing.value.facId || selectedListing.value.orgId;
      selectedListing.value = (next.listings || []).find((row) => (row.facId || row.orgId) === id) || null;
    }
    loaded.value = true;
  } catch (e) {
    reportUiFailure(e, "Failed to load employment (PhoneEmployment)");
    error.value = true;
    loaded.value = true;
  }
};

const startServiceShift = async () => {
  if (busy.value || !vehicleChoice.value || !state.value.roleplaySetup) return;
  busy.value = true;
  shiftError.value = "";
  try {
    const result = await lua.overhaul_career_work_employment.startRoleplayShift(
      state.value.roleplaySetup.facId,
      vehicleChoice.value,
    );
    if (!result?.success) shiftError.value = result?.message || result?.reason || "Unable to start this shift.";
    else {
      vehicleChoice.value = null;
      tab.value = "current";
    }
    await refresh();
  } catch (e) {
    shiftError.value = "Unable to start this shift. Please try again.";
  } finally {
    busy.value = false;
  }
};

const closeServiceSetup = async () => {
  if (busy.value) return;
  busy.value = true;
  try {
    await lua.overhaul_career_work_employment.closeRoleplaySetup();
    vehicleChoice.value = null;
    shiftError.value = "";
    await refresh();
  } finally {
    busy.value = false;
  }
};

const apply = async (listing, endCurrentEmployment = false) => {
  if (busy.value || !canApplyToListing(listing)) return;
  if (state.value.employed && !endCurrentEmployment) {
    confirmingJobChange.value = true;
    return;
  }
  busy.value = true;
  applicationError.value = "";
  try {
    try {
      if (await lua.overhaul_career_career.isActive()) await acquireScope(lua, "career.employment");
    } catch (error) { reportUiFailure(error, "apply (PhoneEmployment)") }
    const result = await lua.overhaul_career_work_employment.applyForJob(
      listing.orgId,
      listing.facId,
      endCurrentEmployment,
    );
    await refresh();
    if (result && result.ok === false && result.reason) {
      reportUiFailure(result, "applyForJob failed (PhoneEmployment)");
      applicationError.value = result.reason;
    }
    if (!state.value.pending && result?.ok !== true && !applicationError.value) {
      applicationError.value = "Application was not sent. Your current job is unchanged.";
    }
    if (result?.ok === true) {
      selectedListing.value = null;
      tab.value = "current";
      confirmingJobChange.value = false;
    }
  } catch (e) {
    reportUiFailure(e, "Failed to apply (PhoneEmployment)");
    applicationError.value = "Could not submit the application. Please try again.";
  } finally {
    busy.value = false;
  }
};

const openYard = async () => {
  busy.value = true;
  try {
    await lua.overhaul_career_work_employment.openShiftUi(state.value.homeFacId);
  } catch (e) {
    reportUiFailure(e, "Failed to open shift screen (PhoneEmployment)");
  } finally {
    busy.value = false;
  }
};

const shiftActionSucceeded = (result) =>
  result?.success === true || result?.success === 1 || result?.ok === true || result?.ok === 1;

const readShiftActionResult = async (rawResult) => {
  if (rawResult && typeof rawResult === "object") return rawResult;
  try {
    const stored = await lua.overhaul_career_work_employment.getLastShiftActionResult();
    if (stored && typeof stored === "object") return stored;
  } catch (e) {
    reportUiFailure(e, "getLastShiftActionResult failed (PhoneEmployment)");
  }
  return rawResult;
};

const startAbandonConfirm = () => {
  if (busy.value || !state.value.assignment?.canAbandonAssignment) return;
  confirmingAbandon.value = true;
};

const cancelAbandonConfirm = () => {
  confirmingAbandon.value = false;
};

const confirmAbandonAssignment = async () => {
  if (busy.value || !state.value.assignment?.canAbandonAssignment) return;
  busy.value = true;
  shiftError.value = "";
  confirmingAbandon.value = false;
  try {
    const result = await readShiftActionResult(
      await lua.overhaul_career_work_employment.abandonAssignment(state.value.homeFacId),
    );
    if (!shiftActionSucceeded(result)) {
      shiftError.value = result?.message || result?.reason || "Could not abandon the assignment.";
    }
    await refresh();
  } catch (e) {
    reportUiFailure(e, "Failed to abandon assignment (PhoneEmployment)");
    shiftError.value = "Could not abandon the assignment.";
  } finally {
    busy.value = false;
  }
};

const endDay = async () => {
  if (busy.value) return;
  busy.value = true;
  try {
    await lua.overhaul_career_work_employment.endDay(state.value.homeFacId);
    await refresh();
  } catch (e) {
    reportUiFailure(e, "Failed to end day (PhoneEmployment)");
  } finally {
    busy.value = false;
  }
};

const endBusShiftNow = async () => {
  if (busy.value || !state.value.assignment?.canEndBusShiftNow) return;
  const routeId = state.value.assignment.busShift?.routeId;
  busy.value = true;
  shiftError.value = "";
  try {
    if ((await confirmEndBusShiftNow(routeId)) === false) {
      shiftError.value = "The shift changed. Review the current assignment and try again.";
    }
    await refresh();
  } catch (e) {
    reportUiFailure(e, "End bus shift failed (PhoneEmployment)");
    shiftError.value = "Could not end the shift. Please try again.";
  } finally {
    busy.value = false;
  }
};

const reportAccident = async () => {
  if (!state.value.canReportAccident) {
    accidentArmed.value = false;
    return;
  }
  if (!accidentArmed.value) {
    accidentArmed.value = true;
    return;
  }
  busy.value = true;
  try {
    await lua.overhaul_career_work_employment.reportAccident();
    accidentArmed.value = false;
    await refresh();
  } catch (e) {
    reportUiFailure(e, "Failed to report accident (PhoneEmployment)");
    accidentArmed.value = false;
  } finally {
    busy.value = false;
  }
};

const quit = async () => {
  if (quitting.value) return;
  quitting.value = true;
  confirmingQuit.value = false;
  try {
    await lua.overhaul_career_work_employment.quitJob();
    await refresh();
  } catch (e) {
    reportUiFailure(e, "Failed to quit (PhoneEmployment)");
  } finally {
    quitting.value = false;
  }
};

const acceptHeadhunter = async () => {
  busy.value = true;
  try {
    await lua.overhaul_career_work_employment.acceptHeadhunterOffer();
    tab.value = "current";
    await refresh();
  } catch (e) {
    reportUiFailure(e, "Failed to accept headhunter offer (PhoneEmployment)");
  } finally {
    busy.value = false;
  }
};

const dismissHeadhunter = async () => {
  busy.value = true;
  try {
    await lua.overhaul_career_work_employment.dismissHeadhunterOffer();
    await refresh();
  } catch (e) {
    reportUiFailure(e, "Failed to dismiss headhunter offer (PhoneEmployment)");
  } finally {
    busy.value = false;
  }
};

const rollListings = async () => {
  if (!state.value.devTools || busy.value) return;
  busy.value = true;
  try {
    try {
      if (await lua.overhaul_career_career.isActive()) await acquireScope(lua, "career.employment");
    } catch (error) { reportUiFailure(error, "roll listings (PhoneEmployment)") }
    const next = await lua.overhaul_career_work_employment.rollJobListings();
    if (next && typeof next === "object" && Array.isArray(next.listings)) {
      state.value = next;
      loaded.value = true;
      error.value = false;
    } else {
      await refresh();
    }
  } catch (e) {
    reportUiFailure(e, "Failed to roll employment listings (PhoneEmployment)");
    error.value = true;
  } finally {
    busy.value = false;
  }
};

onMounted(() => {
  refresh();
  events.on("employmentUpdated", refresh);
});

onBeforeUnmount(() => {
  events.off("employmentUpdated", refresh);
});
</script>

<style scoped lang="scss">
/* House style shared with the Job Broker and Employee Shift: dark gray, orange accent, Overpass, images first. */
.employment {
  --accent: var(--bng-orange-b400, #ff6600);
  --panel: rgba(255, 255, 255, 0.06);
  --panel-2: rgba(255, 255, 255, 0.1);
  --line: rgba(255, 255, 255, 0.1);
  --muted: rgba(255, 255, 255, 0.72);
  --faint: rgba(255, 255, 255, 0.55);
  --money: #fde68a;
  --ok: #4ade80;
  --warn: #fbbf24;
  --bad: #fca5a5;
  height: 100%;
  box-sizing: border-box;
  padding-top: 4.1em;
  display: flex;
  flex-direction: column;
  background: #151517;
  color: #fff;
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  font-size: 12px;
  line-height: 1.35;
  --bng-icon-color: currentColor;
}
.employment * {
  box-sizing: border-box;
}
.employment :deep(.bng-icon) {
  font-size: 1.25em;
}
.scroll {
  overflow: auto;
  min-height: 0;
  flex: 1;
  scrollbar-gutter: stable;
}
.scroll::-webkit-scrollbar {
  width: 0.45em;
}
.scroll::-webkit-scrollbar-track {
  background: transparent;
}
.scroll::-webkit-scrollbar-thumb {
  background: rgba(255, 255, 255, 0.22);
  border-radius: 1em;
  border: 0.1em solid transparent;
  background-clip: padding-box;
}
.page {
  padding: 0.25em 1em 1em;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 0.8em;
}
.page > * {
  flex: 0 0 auto;
}

/* ---- buttons, pills, text */
.btn {
  appearance: none;
  border: 0;
  margin: 0;
  padding: 0.72em 1.2em 0.58em;
  border-radius: 0.6em;
  font: inherit;
  font-weight: 700;
  line-height: 1;
  color: #fff;
  background: rgba(255, 255, 255, 0.1);
  cursor: pointer;
  white-space: nowrap;
  transition:
    background-color 0.12s,
    transform 0.08s;
}
.btn:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.18);
}
.btn:active:not(:disabled) {
  transform: translateY(1px);
}
.btn.focus-visible {
  outline: none;
  box-shadow:
    0 0 0 2px #fff,
    0 0 0 4px rgba(255, 102, 0, 0.7);
}
.btn:disabled {
  opacity: 0.45;
  cursor: default;
}
.btn-primary {
  background: var(--accent);
}
.btn-primary:hover:not(:disabled) {
  background: #ff7a1f;
}
.btn-danger {
  background: #b91c1c;
}
.btn-danger:hover:not(:disabled) {
  background: #dc2626;
}
.btn-quiet-danger {
  color: var(--bad);
}
.dev-btn {
  justify-self: start;
  font-size: 0.85em;
  color: #fecaca;
  border: 1px dashed rgba(248, 113, 113, 0.5);
  background: transparent;
}
/* explicit reset: the game's legacy global button styles otherwise draw a grey square around icon buttons */
.icon-btn {
  appearance: none;
  display: grid;
  place-items: center;
  width: 2.4em;
  height: 2.4em;
  padding: 0 !important;
  margin: 0;
  border: 0 !important;
  border-radius: 50% !important;
  font: inherit;
  line-height: 1;
  color: #fff;
  background: rgba(0, 0, 0, 0.55);
  box-shadow: none;
  cursor: pointer;
}
.icon-btn:hover:not(:disabled) {
  background: rgba(0, 0, 0, 0.75);
}
.icon-btn svg {
  display: block;
  width: 1.2em;
  height: 1.2em;
  fill: none;
  stroke: currentColor;
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.actions {
  display: flex;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: 0.5em;
  padding-top: 0.2em;
}
.actions.stack {
  flex-direction: column;
  align-items: stretch;
}
.abandon-panel {
  padding: 0.75em 0.85em;
  border-radius: 0.55em;
  background: rgba(15, 23, 42, 0.75);
  border: 1px solid rgba(248, 113, 113, 0.35);
  margin-top: 0.35em;
}
.abandon-panel-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 0.65em;
  flex-wrap: wrap;
}
.abandon-panel-title {
  font-weight: 700;
  font-size: 0.95em;
}
.abandon-panel-fine {
  font-weight: 800;
  color: #fca5a5;
}
.abandon-panel-detail {
  margin: 0.4em 0 0.65em;
  color: rgba(255, 255, 255, 0.62);
  font-size: 0.82em;
  line-height: 1.35;
}
.abandon-panel-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5em;
  flex-wrap: wrap;
}
.pills {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
}
.pill {
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  width: fit-content;
  padding: 0.4em 0.55em 0.1em;
  line-height: 1;
  border-radius: 0.3em;
  background: rgba(255, 255, 255, 0.09);
  color: rgba(255, 255, 255, 0.8);
  font-size: 0.74em;
  font-weight: 700;
  white-space: nowrap;
}
.pill.accent {
  background: rgba(255, 102, 0, 0.25);
  color: #ffb27a;
}
.pill.ok {
  background: rgba(74, 222, 128, 0.18);
  color: #86efac;
}
.pill.bad {
  background: rgba(252, 165, 165, 0.18);
  color: var(--bad);
}
.pill.soft {
  background: transparent;
  color: var(--faint);
  padding-left: 0;
}
.pill-lv {
  margin-left: 0.45em;
  padding-left: 0.45em;
  border-left: 1px solid rgba(255, 255, 255, 0.22);
  font-weight: 700;
}
.lock {
  width: 0.95em;
  height: 0.95em;
  fill: none;
  stroke: currentColor;
  stroke-width: 2.2;
  stroke-linecap: round;
  stroke-linejoin: round;
  position: relative;
  top: -0.13em;
  flex: 0 0 auto;
}
.kicker {
  font-size: 0.75em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--accent);
}
.hint {
  font-size: 0.8em;
  color: var(--faint);
}
.muted {
  margin: 0;
  color: var(--muted);
  font-size: 0.92em;
}
.note {
  margin: 0;
  color: #cbd5e1;
  font-size: 0.92em;
}
.note.warn {
  color: #fdba74;
}
.status-error {
  margin: 0;
  color: var(--bad);
  font-weight: 600;
}
.block {
  display: grid;
  gap: 0.5em;
}
.block-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.25em 1em;
}
.assignment {
  margin: 0;
  font-size: 1.05em;
  font-weight: 700;
  line-height: 1.25;
}
.card {
  padding: 0.8em 0.9em;
  border-radius: 0.5em;
  background: var(--panel);
  display: grid;
  gap: 0.55em;
}
.card-title {
  font-size: 1.15em;
}
.empty {
  padding: 2em 1em;
  text-align: center;
  color: var(--muted);
  display: grid;
  gap: 0.5em;
  justify-items: center;
}
.empty :deep(.bng-icon) {
  font-size: 2.6em;
  color: rgba(255, 255, 255, 0.3);
}
.empty h3 {
  margin: 0;
  color: #fff;
  font-size: 1.1em;
}
.empty p {
  margin: 0;
  max-width: 22em;
}

/* ---- tabs */
.tabs {
  display: flex;
  gap: 0.4em;
  padding: 0 1em 0.6em;
  flex-shrink: 0;
}
.tabs button {
  flex: 1;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  padding: 0.7em 0.6em 0.55em;
  border: 0;
  border-radius: 0.6em;
  background: var(--panel);
  color: var(--muted);
  font: inherit;
  font-weight: 700;
  line-height: 1;
  cursor: pointer;
}
.tabs button.active {
  background: var(--panel-2);
  color: #fff;
  box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.55);
}
.tabs .pill {
  font-size: 0.7em;
}
.tab-dot {
  width: 0.55em;
  height: 0.55em;
  border-radius: 50%;
  background: var(--ok);
}
.tab-dot.alert {
  background: var(--accent);
}

/* ---- hero (facility photo) */
.hero {
  position: relative;
  width: 100%;
  border-radius: 0.5em;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.35);
  aspect-ratio: 16 / 8;
  min-height: 5.5em;
}
.hero.small {
  aspect-ratio: 16 / 6;
  margin: -0.8em -0.9em 0;
  border-radius: 0.5em 0.5em 0 0;
}
.hero img {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.hero::after {
  content: "";
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(21, 21, 23, 0.95) 0%, rgba(21, 21, 23, 0.45) 45%, rgba(21, 21, 23, 0) 80%);
  pointer-events: none;
}
.hero-copy {
  position: absolute;
  left: 0.8em;
  right: 0.8em;
  bottom: 0.6em;
  z-index: 1;
  display: grid;
  gap: 0.1em;
}
.hero-copy strong {
  font-size: 1.25em;
  line-height: 1.15;
  text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9);
}
.hero-copy span {
  color: rgba(255, 255, 255, 0.78);
  font-size: 0.88em;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.9);
}
.hero-copy .kicker {
  color: #ffb27a;
}
.hero-close {
  position: absolute;
  top: 0.5em;
  right: 0.5em;
  z-index: 2;
}
.hero-status {
  position: absolute;
  top: 0.6em;
  right: 0.6em;
  z-index: 2;
}

/* ---- stats */
.stats {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em 1.6em;
  padding-bottom: 0.7em;
  border-bottom: 1px solid var(--line);
}
.stat {
  display: grid;
  gap: 0.12em;
}
.stat-key {
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--faint);
}
.stat-value {
  font-weight: 700;
  font-size: 1.05em;
  line-height: 1.2;
}
.stat-value small {
  font-weight: 600;
  font-size: 0.75em;
  color: var(--faint);
  margin-left: 0.2em;
}
.stat.money .stat-value {
  color: var(--money);
}

/* ---- listings (employers) */
.listings {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 0.45em;
}
.listing {
  display: flex;
  align-items: center;
  gap: 0.65em;
  width: 100%;
  padding: 0.55em 0.65em 0.55em 0.55em;
  border: 0;
  border-radius: 0.5em;
  background: var(--panel);
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}
.listing:hover {
  background: var(--panel-2);
}
.listing.locked .listing-copy strong {
  color: rgba(255, 255, 255, 0.6);
}
.listing.locked .listing-img img {
  filter: grayscale(0.8) brightness(0.6);
}
.listing-img {
  flex: 0 0 auto;
  width: 5em;
  aspect-ratio: 16 / 9;
  border-radius: 0.35em;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.35);
  display: grid;
  place-items: center;
  color: rgba(255, 255, 255, 0.4);
}
.listing-img img {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.listing-img :deep(.bng-icon) {
  font-size: 1.6em;
}
.listing-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.3em;
}
.listing-copy strong {
  font-size: 1.05em;
  line-height: 1.2;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.listing-state {
  flex: 0 0 auto;
}

/* ---- assignment tiles */
.tiles {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 0.45em;
}
.tile {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;
  padding: 0.6em 0.7em;
  border-radius: 0.4em;
  background: var(--panel);
}
.tile.locked strong {
  color: rgba(255, 255, 255, 0.55);
}
.tile strong {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* ---- vehicle choice tiles */
.fleet {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.5em;
}
.vehicle {
  border-radius: 0.4em;
  overflow: hidden;
  background: var(--panel);
  min-width: 0;
}
.vehicle.picked {
  box-shadow: inset 0 0 0 2px var(--accent);
}
.vehicle.locked .vehicle-img img {
  filter: grayscale(0.9) brightness(0.55);
}
.vehicle.locked strong {
  color: rgba(255, 255, 255, 0.55);
}
.vehicle-btn {
  display: block;
  width: 100%;
  padding: 0;
  border: 0;
  background: none;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}
.vehicle-btn:disabled {
  opacity: 0.55;
  cursor: default;
}
.vehicle-img {
  position: relative;
  aspect-ratio: 16 / 9;
  background: rgba(0, 0, 0, 0.35);
}
.vehicle-img img {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.vehicle-img::after {
  content: "";
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(20, 20, 22, 0.7), rgba(20, 20, 22, 0) 55%);
  pointer-events: none;
}
.vehicle-img.icon-only {
  display: grid;
  place-items: center;
  color: rgba(255, 255, 255, 0.55);
}
.vehicle-img.icon-only :deep(.bng-icon) {
  font-size: 2.6em;
}
.img-lock {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-items: center;
  background: rgba(8, 8, 10, 0.35);
  color: rgba(255, 255, 255, 0.9);
}
.img-lock .lock {
  width: 1.4em;
  height: 1.4em;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.8;
}
.vehicle-copy {
  display: grid;
  gap: 0.25em;
  padding: 0.5em 0.6em 0.6em;
  min-width: 0;
}
.vehicle-copy strong {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  line-height: 1.2;
}
</style>
