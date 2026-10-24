<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="taxi-container" ref="container">
    <!-- Minimap Background -->
    <div class="map-container">
    </div>

    <!-- Reward + Driver Rating Top Bar -->
    <div class="reward-bubble" v-if="currentState !== 'start'">
      <span class="total">${{ formatCurrency(totalReward) }}</span>
      <span class="divider">|</span>
      <span class="driver">★ {{ driverRatingDisplay }}</span>
    </div>

    <!-- Start State -->
    <div class="bottom-panel" v-if="currentState === 'start'">
      <div class="rider-details center">
        <span class="rider-info progress-chip">{{ taxiSkillDisplay }}</span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.person" />
          {{ currentCapacity }}
        </span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.carUp" />
          {{ vehicleMultiplier }}
        </span>
      </div>
      <button class="state-button" @click.stop="setState('ready')"> Drive Now </button>
    </div>

    <!-- Ready State -->
    <div class="bottom-panel" v-if="currentState === 'ready'">
      <div class="rider-details center">
        <span class="rider-info progress-chip">{{ taxiSkillDisplay }}</span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.person" />
          {{ currentCapacity }}
        </span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.carUp" />
          {{ vehicleMultiplier }}
        </span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.sync" />
          {{ fareStreak }}
        </span>
      </div>
      <button class="state-button stop" @click.stop="setState('stop')"> Stop Driving </button>
    </div>

    <!-- Pickup/Dropoff State -->
    <div class="bottom-panel" v-if="currentState === 'pickup' || currentState === 'dropoff'">
      <div class="rider-details">
        <span class="rider-type">{{ riderType }}</span>
        <button class="info-button" @click.stop="toggleInfo">?</button>
        <span class="rider-info">{{ riderValueDisplay }}</span>
      </div>
      <div class="ride-status">
        {{ currentState === "pickup" ? "Picking up" : "Dropping off" }} {{ riderCount }} passengers
      </div>
      <div class="fare-display small">
        ${{ formatCurrency(farePerKm) }} <span class="tip-note">excluding tip</span>
      </div>
      <div class="rider-details center">
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.person" />
          {{ riderCount }}/{{ currentCapacity }}
        </span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.carUp" />
          {{ vehicleMultiplier }}
        </span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.sync" />
          {{ fareStreak }}
        </span>
      </div>
    </div>

    <!-- Accept Rider State -->
    <div class="bottom-panel rider" v-if="currentState === 'accept'">
      <div class="rider-header">
        <div class="rider-title">
          <span class="rider-type">{{ riderType }}</span>
          <button class="info-button" @click.stop="toggleInfo">?</button>
        </div>
        <button class="close-button" @click.stop="setState('reject')">
          <BngIcon class="x-icon" :type="icons.xmark" />
        </button>
      </div>
      <div class="fare-display"> ${{ formatCurrency(farePerKm) }} <span class="tip-note">excluding tip</span> </div>
      <div class="rider-details">
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.person" />
          {{ riderCount }}
        </span>
        <span class="rider-info">{{ riderValueDisplay }}</span>
        <span class="rider-info">
          <BngIcon class="app-icon" :type="icons.sync" />
          {{ fareStreak }}
        </span>
      </div>
      <button class="state-button" @click.stop="setState('working')"> Accept </button>
    </div>

    <!-- Complete State -->
    <div class="complete-overlay" v-bng-scoped-nav="modalScopes.complete" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer" v-if="currentState === 'complete'">
      <div class="complete-modal">
        <div class="fare-header">
          <div class="fare-display center">${{ formatCurrency(totalFare) }}</div>
          <div class="fare-rating"> ★ {{ passengerRatingDisplay }}</div>
        </div>
        <div class="fare-breakdown">
          <div class="breakdown-section">
            <div class="breakdown-label">Base Fare</div>
            <div class="breakdown-amount">${{ formatCurrency(baseFareAmount) }}</div>
          </div>
          <button type="button" class="breakdown-section clickable" @click.stop="toggleTipBreakdown" :aria-expanded="showTipBreakdown">
            <div class="breakdown-label">Tips</div>
            <div
              class="breakdown-amount"
              :class="{ 'positive': totalTipsAmount > 0, 'negative': totalTipsAmount < 0 }"
            >
              {{ totalTipsAmount > 0 ? "+" : "" }}${{ formatCurrency(Math.abs(totalTipsAmount)) }}
              <span class="count-badge" v-if="Object.keys(tipBreakdownData).length > 0">{{
                Object.keys(tipBreakdownData).length
              }}</span>
              <span class="dropdown-icon" :class="{ open: showTipBreakdown }">▼</span>
            </div>
          </button>
          <transition name="collapse">
            <div class="tip-breakdown" v-if="Object.keys(tipBreakdownData).length > 0 && showTipBreakdown">
              <div class="tip-item" v-for="(amount, name) in tipBreakdownData" :key="name">
                <span class="tip-name">{{ name }}</span>
                <span class="tip-amount" :class="{ 'positive': amount >= 0, 'negative': amount < 0 }">
                  {{ amount >= 0 ? "+" : "" }}${{ formatCurrency(Math.abs(amount)) }}
                </span>
              </div>
            </div>
          </transition>
          <div class="breakdown-section" v-if="taxiSkillXpAmount > 0">
            <div class="breakdown-label">Taxi Skill XP</div>
            <div class="breakdown-amount positive">+{{ formatWholeNumber(taxiSkillXpAmount) }} XP</div>
          </div>
        </div>
        <div class="rider-details center">
          <span class="rider-info">{{ riderType }}</span>
          <button class="info-button" @click.stop="toggleInfo">?</button>
          <span class="rider-info">{{ riderValueDisplay }}</span>
        </div>
        <button bng-scoped-nav-autofocus class="state-button complete" @click.stop="setState('ready')">Complete</button>
      </div>
    </div>

    <!-- Disabled State Overlay -->
    <div class="disabled-overlay" v-if="currentState === 'disabled'">
      <button type="button" class="phone-overlay-dismiss" bng-no-nav="true" tabindex="-1" aria-label="Close overlay" @click="closeDisabledOverlay"></button>
      <div class="disabled-modal" v-bng-scoped-nav="modalScopes.disabled" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
        <PhoneAppNotice card :icon="icons.person" :message="disabledReason || 'Taxi is currently disabled'">
          <button type="button" bng-scoped-nav-autofocus @click="closeDisabledOverlay">OK</button>
        </PhoneAppNotice>
      </div>
    </div>

    <!-- Passenger Info Popover -->
    <div class="info-popover" v-bng-scoped-nav="modalScopes.info" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer" v-if="showInfo">
      <div class="info-title">{{ riderType }}</div>
      <div class="info-body">{{ riderDescription }}</div>
      <button bng-scoped-nav-autofocus class="info-close" @click.stop="toggleInfo">Close</button>
    </div>
  </div>
</template>

<script setup>

import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { vBcModalFocus } from '../../components/businessComputer/bcModalNav.js'
import { usePhoneAppLayers, usePhoneAppFocus } from './controllerLayers.js'
import { ref, onMounted, onUnmounted, computed } from "vue";
import { useMinimapStore } from "../../stores/minimapStore";
import { BngIcon, icons } from "@/common/components/base";
import PhoneAppNotice from "../../components/phone/PhoneAppNotice.vue";
import { useEvents } from "@/services/events";
import { lua } from "@/bridge";

usePhoneAppFocus()


const events = useEvents();

const store = useMinimapStore();
const container = ref(null);

// State management
const currentState = ref("ready");
const totalReward = ref(0);
const fareStreak = ref(0);

// Fare
const currentFare = ref({});
const farePerKm = ref(0);
const distanceTraveled = ref(0);
const totalFare = ref(0);
const timeMultiplier = ref(0);
const baseFareAmount = ref(0);
const totalTipsAmount = ref(0);
const tipBreakdownData = ref({});
const showTipBreakdown = ref(false);

// Vehicle Specific
const vehicleMultiplier = ref(0);
const currentCapacity = ref(0);

// Rider Details
const riderType = ref("Standard");
const riderCount = ref(0);
const riderRating = ref(0);
const driverRating = ref(5);
const lastPassengerRating = ref(null);
const driverRatingDisplay = computed(() => Number(driverRating.value ?? 5).toFixed(1));
const disabledReason = ref("");
const riderValueDisplay = computed(() => {
  const rating = Number(riderRating.value || 0);
  // Map 1-5 rating to $-$$$$$ for display of how "high paying"
  const count = Math.max(1, Math.min(5, Math.round(rating)));
  return "$".repeat(count);
});
const showInfo = ref(false);
const { scopes: modalScopes, back: closeTopLayer } = usePhoneAppLayers({
  complete: { open: () => currentState.value === 'complete', close: () => setState('ready') },
  disabled: { open: () => currentState.value === 'disabled', close: () => closeDisabledOverlay() },
  info: { open: () => showInfo.value, close: () => { showInfo.value = false } },
})

const riderDescription = ref("");
const toggleInfo = () => {
  showInfo.value = !showInfo.value;
};
const taxiSkillLevel = ref(1);
const taxiFareBonusPercent = ref(0);
const taxiSkillDisplay = computed(() => `Lvl ${taxiSkillLevel.value} | Fare +${taxiFareBonusPercent.value}%`);
const taxiSkillXpAmount = computed(() => {
  const awardedXp = Number(currentFare.value?.taxiSkillXpAwarded ?? 0);
  return Number.isFinite(awardedXp) ? Math.max(0, Math.floor(awardedXp)) : 0;
});
const passengerRatingDisplay = computed(() => {
  const v = lastPassengerRating.value;
  if (v === null || typeof v === "undefined" || isNaN(v)) return "5.0";
  return Number(v).toFixed(1);
});

const formatCurrency = (value) => {
  if (value >= 1e6) {
    const millions = (value / 1e6).toPrecision(3);
    return `${millions.replace(/\.0+$|(\.[0-9]*[1-9])0+$/, "$1")}M`;
  }
  if (value >= 1e3) {
    const thousands = (value / 1e3).toPrecision(3);
    return `${thousands.replace(/\.0+$|(\.[0-9]*[1-9])0+$/, "$1")}k`;
  }
  return value.toFixed(0);
};

const formatWholeNumber = (value) => {
  const numericValue = Number(value);
  if (!Number.isFinite(numericValue)) return "0";
  return Math.floor(numericValue).toLocaleString("en-US");
};

const setState = (newState) => {
  currentState.value = newState;
  if (newState === "start") {
    lua.overhaul_jobs_taxi_taxi.prepareTaxiJob();
    totalReward.value = 0;
  } else if (newState === "reject") {
    lua.overhaul_jobs_taxi_taxi.rejectJob();
    currentState.value = "ready";
  } else if (newState === "ready") {
    lua.overhaul_jobs_taxi_taxi.setAvailable();
  } else if (newState === "working") {
    lua.overhaul_jobs_taxi_taxi.acceptJob();
    currentState.value = "pickup";
  } else if (newState === "stop") {
    lua.overhaul_jobs_taxi_taxi.stopTaxiJob();
    currentState.value = "start";
  }
};

const handleBackgroundClick = () => {
  if (currentState.value === "complete") {
    setState("ready");
  }
};

const closeDisabledOverlay = () => {
  // Navigate back to start state when closing disabled overlay
  if (currentState.value === "disabled") {
    setState("start");
  }
};

const handleFare = () => {
  if (!currentFare.value) return;

  farePerKm.value = Number(currentFare.value.baseFare ?? 0);
  riderCount.value = Number(currentFare.value.passengers ?? 0);
  riderRating.value = Number(currentFare.value.passengerRating ?? 0);
  totalFare.value = Number(currentFare.value.totalFare ?? 0);
  distanceTraveled.value = Number(currentFare.value.totalDistanceKm ?? (currentFare.value.paidDistance ?? 0) / 1000);
  timeMultiplier.value = Number(currentFare.value.timeMultiplier ?? 1);
  riderType.value = currentFare.value.passengerTypeName ?? "Standard";
  riderDescription.value = currentFare.value.passengerDescription ?? "";

  // Handle new tip breakdown data
  baseFareAmount.value = Number(currentFare.value.baseFare ?? 0);
  totalTipsAmount.value = Number(currentFare.value.totalTips ?? 0);
  tipBreakdownData.value = currentFare.value.tipBreakdown ?? {};
  showTipBreakdown.value = false;
};

const toggleTipBreakdown = () => {
  showTipBreakdown.value = !showTipBreakdown.value;
};

const handleTaxiState = (state) => {
  currentState.value = state.state;
  currentFare.value = state.currentFare;
  currentCapacity.value = state.availableSeats;
  vehicleMultiplier.value = state.vehicleMultiplier;
  totalReward.value = state.cumulativeReward;
  fareStreak.value = state.fareStreak;

  // Update passenger type if available from state
  if (state.currentPassengerType) {
    riderType.value = state.currentPassengerType;
  }
  if (typeof state.playerRating !== "undefined") {
    driverRating.value = Number(state.playerRating);
  }
  if (typeof state.lastPassengerRating !== "undefined") {
    lastPassengerRating.value = Number(state.lastPassengerRating);
  }
  if (typeof state.disabledReason !== "undefined") {
    disabledReason.value = state.disabledReason;
  }
  if (typeof state.taxiSkillLevel !== "undefined") {
    taxiSkillLevel.value = Number(state.taxiSkillLevel) || 1;
  }
  if (typeof state.taxiFareBonusPercent !== "undefined") {
    taxiFareBonusPercent.value = Number(state.taxiFareBonusPercent) || 0;
  }

  handleFare();
};

let mapView = null;

onMounted(() => {
  events.on("updateTaxiState", handleTaxiState);
  store.acquire();
  mapView = store.mountMap(container.value.querySelector('.map-container'));
  lua.overhaul_jobs_taxi_taxi.requestTaxiState();
});

onUnmounted(() => {
  events.off("updateTaxiState", handleTaxiState);
  mapView?.dispose();
  store.release();
});
</script>

<style scoped lang="scss">
.phone-overlay-dismiss { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; background: transparent; }
.disabled-modal { z-index: 1; }
.taxi-container {
  position: relative;
  width: 100%;
  height: 100%;
}

.map-container {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  background: rgba(40, 40, 40, 0.9);
}

.minimap-layer {
  position: absolute;
  width: 100%;
  height: 100%;
  pointer-events: none;
}

.bottom-panel {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  background: rgb(216, 224, 246);
  color: rgb(0, 0, 0);
  padding: 0.75em;
  margin: 0.5em;
  margin-bottom: 2em;
  border-radius: 15px;

  &.rider {
    background: rgb(216, 224, 246);
    color: rgb(0, 0, 0);
    font-weight: 600;
  }
}

.capacity-display {
  display: flex;
  gap: 2em;
  margin-bottom: 1.5em;
  justify-content: space-between;
  padding: 0.5em 3em 0 3em;
  font-size: 1.25em;
  font-family: "Overpass", sans-serif;
  font-weight: 600;
  align-items: center;

  .capacity-item {
    display: flex;
  }
}

.reward-bubble {
  position: absolute;
  top: 40px;
  left: 50%;
  transform: translateX(-50%);
  background: rgba(0, 0, 0, 0.9);
  padding: 0.5em 1em;
  border-radius: 25px;
  color: white;
  font-weight: bold;
  font-size: 1.1em;
  box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
  display: inline-flex;
  gap: 0.5em;
  align-items: center;
}

.reward-bubble .divider {
  opacity: 0.5;
}
.reward-bubble .driver {
  opacity: 0.9;
}

.rider-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-family: "Overpass", sans-serif;
}

.rider-title {
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
}

.info-button {
  margin-left: 0.2em;
  height: 1.4em;
  min-width: 1.4em;
  border: none;
  border-radius: 0.4em;
  background: rgb(196, 205, 230);
  color: rgb(0, 0, 0);
  font-weight: 800;
  cursor: pointer;
}

.rider-type {
  font-size: 1em;
  background: rgb(196, 205, 230);
  color: rgb(0, 0, 0);
  padding: 0.25em 0.5em 0.15em 0.5em;
  border-radius: 0.5em;
  font-weight: 600;
  align-items: center;
  justify-content: center;
}

.ride-status {
  font-size: 1.5em;
  font-weight: 700;
  color: #010101;
  margin-top: 0.25em;
  margin-bottom: 0.25em;
  font-family: "Overpass", sans-serif;

  &.center {
    text-align: center;
  }
}

.fare-display {
  font-size: 1.8em;
  color: #010101;
  margin-top: 0.25em;
  margin-bottom: 0.25em;
  font-family: "Overpass", sans-serif;

  &.center {
    text-align: center;
  }

  &.small {
    font-size: 1.2em;
  }
}

.tip-note {
  font-size: 0.6em;
  color: #666666;
  font-weight: 400;
}

.rider-details {
  display: flex;
  margin-bottom: 0.5em;
  font-family: "Overpass", sans-serif;

  .rider-info {
    font-size: 1.1em;

    background: rgb(196, 205, 230);
    color: rgb(0, 0, 0);
    padding: 0.1em 0.5em 0.05em 0.5em;
    margin-left: 0.25em;
    margin-right: 0.25em;
    border-radius: 0.5em;
  }

  &.center {
    justify-content: center;
  }
}

.progress-chip {
  font-weight: 700;
}

.state-button {
  width: 100%;
  padding: 0.75em 0em 0.65em 0em;
  background: #2f2bff;
  color: rgb(255, 255, 255);
  border: none;
  border-radius: 10px;
  font-size: 1.75em;
  font-weight: 600;
  font-family: "Overpass", sans-serif;

  &.stop {
    background: #ff1744;
  }

  &.complete {
    background: #0f7b0f;
  }

  &:hover {
    transform: scale(1.02);
  }
}

.complete-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.5);
  display: flex;
  justify-content: center;
  align-items: center;
}

.info-popover {
  position: absolute;
  bottom: 8.5em;
  left: 0.75em;
  right: 0.75em;
  background: rgba(216, 224, 246, 0.98);
  color: rgb(0, 0, 0);
  border-radius: 12px;
  padding: 0.75em;
  box-shadow: 0 8px 18px rgba(0, 0, 0, 0.25);
  border: 1px solid rgba(0, 0, 0, 0.1);
}
.info-title {
  font-weight: 700;
  margin-bottom: 0.25em;
}
.info-body {
  font-weight: 500;
}
.info-close {
  margin-top: 0.5em;
  width: 100%;
  padding: 0.5em 0;
  background: #2f2bff;
  color: #fff;
  border: none;
  border-radius: 8px;
}

.complete-modal {
  background: rgb(216, 224, 246);
  font-weight: 600;
  padding: 1em;
  border-radius: 20px;
  width: 90%;
  column-gap: 5em;
  max-height: 80vh;
  overflow-y: auto;
  color: rgb(0, 0, 0);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
  border: 1px solid rgba(0, 0, 0, 0.1);
}

.fare-header {
  display: flex;
  align-items: baseline;
  justify-content: center;
  gap: 0.75em;
}
.fare-rating {
  font-size: 1em;
  font-weight: 700;
  background: rgba(196, 205, 230, 0.75);
  padding: 0.2em 0.5em;
  border-radius: 8px;
}

.fare-breakdown {
  margin: 1em 0;
  padding: 0.5em;
  background: rgba(196, 205, 230, 0.35);
  border-radius: 10px;
}

.breakdown-section {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.25em 0;
  border-bottom: none;
}
.breakdown-section.clickable {
  font: inherit; color: inherit; text-align: left; width: 100%; border: 0; background: transparent;
  cursor: pointer;
}

.breakdown-section:last-child {
  border-bottom: none;
}

.breakdown-label {
  font-size: 1.1em;
  font-weight: 600;
  color: rgb(0, 0, 0);
}

.breakdown-amount {
  font-size: 1.1em;
  font-weight: 700;
  color: rgb(0, 0, 0);
}

.tip-breakdown-toggle {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.5em;
  margin-top: 0.5em;
  cursor: pointer;
  font-weight: 600;
  color: rgb(0, 0, 0);
  border-top: none;
  border-radius: 8px;
  transition: background-color 0.2s ease;
  user-select: none;
  gap: 0.5em;
}

.tip-breakdown-toggle:hover {
  background: rgba(196, 205, 230, 0.45);
}

.tip-breakdown-toggle:active {
  background: rgba(196, 205, 230, 0.6);
}

.toggle-right-group {
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
}

.dropdown-icon {
  font-size: 1.2em;
  color: rgb(0, 0, 0);
  font-weight: bold;
  transition: transform 0.2s ease;
}

.dropdown-icon.open {
  transform: rotate(180deg);
}

.count-badge {
  background: #2f2bff;
  color: #ffffff;
  border-radius: 999px;
  padding: 0.05em 0.45em 0.1em 0.45em;
  font-size: 0.85em;
  line-height: 1.2;
}

.collapse-enter-active,
.collapse-leave-active {
  transition:
    max-height 0.25s ease,
    opacity 0.25s ease;
}
.collapse-enter-from,
.collapse-leave-to {
  max-height: 0;
  opacity: 0;
}
.collapse-enter-to,
.collapse-leave-from {
  max-height: 260px;
  opacity: 1;
}

.tip-breakdown {
  margin-top: 0.5em;
  padding-top: 0.5em;
  border-top: 1px solid rgba(0, 0, 0, 0.2);
}

.tip-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.2em 0;
  font-size: 0.9em;
}

.tip-name {
  font-weight: 500;
  color: rgb(0, 0, 0);
}

.tip-amount {
  font-weight: 600;
  color: rgb(0, 0, 0);

  &.positive {
    color: #0f7b0f;
  }

  &.negative {
    color: #ff1744;
  }
}

.app-icon {
  font-size: 125%;
  color: rgb(0, 0, 0);
  align-content: center;
}

.x-icon {
  font-size: 1em;
  color: rgb(0, 0, 0);
  justify-content: center;
  align-items: center;
}

.close-button {
  font-size: 1.25em;
  height: 1.75em;
  width: 1.75em;
  border: none;
  background: rgb(196, 205, 230);
  border-radius: 0.5em;
  float: right;

  &:hover {
    transform: scale(1.15);
  }
}

.disabled-overlay {
  position: absolute;
  top: 40px; /* Start below the phone header */
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  justify-content: center;
  align-items: center;
  z-index: 10; /* Lower z-index to not block phone navigation */
  pointer-events: none; /* Allow clicks to pass through to elements behind */
}

.disabled-modal {
  display: flex;
  justify-content: center;
  width: 85%;
  animation: fadeInUp 0.3s cubic-bezier(0.23, 1, 0.32, 1);
  position: relative;
  pointer-events: auto; /* Allow interaction with the card itself */
}

@keyframes fadeInUp {
  from {
    opacity: 0;
    transform: translateY(20px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
</style>
