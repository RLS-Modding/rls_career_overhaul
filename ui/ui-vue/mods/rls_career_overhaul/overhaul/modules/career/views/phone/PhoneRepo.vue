<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="repo-container" ref="container" @click="handleBackgroundClick">
    <!-- Minimap Background -->
    <div class="map-container">
    </div>

    <!-- Reward Bubble -->
    <div class="reward-bubble" v-if="currentReward > 0"> ${{ formatCurrency(currentReward) }} </div>

    <!-- No Mission State -->
    <div class="bottom-panel" v-if="currentState === 'no_mission'">
      <div class="panel-header">Vehicle Repo Service</div>
      <div class="panel-content">
        <div class="instruction-text" v-if="isInRepoVehicle"
          >Generate a new repo mission to earn money by recovering vehicles.</div
        >
        <div class="instruction-text" v-if="!isInRepoVehicle">You need to be in a vehicle to start missions.</div>
      </div>
      <button class="state-button" @click.stop="generateMission()" v-if="isInRepoVehicle"> Generate Mission </button>
      <button class="state-button disabled" v-if="!isInRepoVehicle" disabled> Need Vehicle </button>
    </div>

    <div class="bottom-panel" v-if="currentState === 'loading'">
      <div class="panel-header">Loading</div>
      <div class="panel-content">
        <div class="instruction-text">Loading Mission...</div>
      </div>
    </div>

    <!-- Picking Up State -->
    <div class="bottom-panel" v-if="currentState === 'picking_up'">
      <div class="panel-header">
        <span class="vehicle-type">Repo</span>
        <button class="close-button" @click.stop="abandonMission()">
          <BngIcon class="x-icon" :type="icons.xmark" />
        </button>
      </div>
      <div class="vehicle-display">{{ vehicleBrand }} {{ vehicleName }}</div>
      <div class="instruction-text">Find and collect this vehicle</div>
      <div class="repo-meta" v-if="repoTierLabel || repoSkillLevel > 0">
        <span class="repo-chip" v-if="repoTierLabel">{{ repoTierLabel }}</span>
        <span class="repo-chip" v-if="repoSkillLevel === 1 && repoPayoutBonusPercent === 0">Repo level {{ repoSkillLevel }}</span>
        <span class="repo-chip bonus" v-else-if="repoSkillLevel > 0"
          >Repo Lv {{ repoSkillLevel }} • +{{ formatBonusPercent(repoPayoutBonusPercent) }}</span
        >
      </div>
      <div class="vehicle-details">
        <span class="vehicle-info">
          {{ vehicleYear }}
        </span>
        <span class="vehicle-info">
          {{ units.buildString("length", vehicleMileage, 0) }}
        </span>
      </div>
    </div>

    <!-- Dropping Off State -->
    <div class="bottom-panel" v-if="currentState === 'dropping_off'">
      <div class="panel-header">
        <span class="vehicle-type">Repo</span>
        <button class="close-button" @click.stop="abandonMission()">
          <BngIcon class="x-icon" :type="icons.xmark" />
        </button>
      </div>
      <div class="vehicle-display">{{ vehicleBrand }} {{ vehicleName }}</div>
      <div class="instruction-text">Deliver to: {{ deliveryLocation }}</div>
      <div class="repo-meta" v-if="repoTierLabel || repoSkillLevel > 0">
        <span class="repo-chip" v-if="repoTierLabel">{{ repoTierLabel }}</span>
        <span class="repo-chip bonus" v-if="repoSkillLevel > 0"
          >Repo Lv {{ repoSkillLevel }} • +{{ formatBonusPercent(repoPayoutBonusPercent) }}</span
        >
      </div>
      <div class="vehicle-details">
        <span class="vehicle-info">
          {{ vehicleYear }}
        </span>
        <span class="vehicle-info">
          {{ formatDistance(distanceToDestination) }}
        </span>
      </div>
    </div>

    <!-- Disabled State Overlay -->
    <div class="disabled-overlay" v-if="currentState === 'disabled'" @click="closeDisabledOverlay">
      <div class="disabled-modal" @click.stop>
        <PhoneAppNotice card :icon="icons.person" :message="disabledReason || 'Repo is currently disabled'">
          <button type="button" @click="closeDisabledOverlay">OK</button>
        </PhoneAppNotice>
      </div>
    </div>

    <!-- Completed State -->
    <div class="complete-overlay" v-if="currentState === 'completed'">
      <div class="complete-modal">
        <div class="fare-display center">${{ formatCurrency(currentReward) }}</div>
        <div class="vehicle-details center">
          <span class="vehicle-info">{{ vehicleBrand }} {{ vehicleName }}</span>
        </div>
        <div class="vehicle-details center">
          <span class="vehicle-info">
            {{ formatDistance(totalDistance) }}
          </span>
        </div>
        <button class="state-button complete" @click.stop="completeMission()">Complete</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from "vue";
import { useMinimapStore } from "../../stores/minimapStore";
import { BngIcon, icons } from "@/common/components/base";
import PhoneAppNotice from "../../components/phone/PhoneAppNotice.vue";
import { lua, useBridge } from "@/bridge";

const { units, events } = useBridge();

const store = useMinimapStore();
const container = ref(null);

// State management
const currentState = ref("no_mission");
const currentReward = ref(0);
const isInRepoVehicle = ref(false);
const disabledReason = ref("");

// Vehicle Details
const vehicleBrand = ref("");
const vehicleName = ref("");
const vehicleYear = ref("");
const vehicleMileage = ref(0);
const deliveryLocation = ref("");
const distanceToDestination = ref(0);
const totalDistance = ref(0);
const repoTag = ref("");
const repoTierLabel = ref("");
const repoSkillLevel = ref(0);
const repoPayoutBonusPercent = ref(0);

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

const formatDistance = (distance) => {
  if (distance < 1000) {
    return `${Math.round(distance)} m`;
  } else {
    return `${(distance / 1000).toFixed(1)} km`;
  }
};

const formatBonusPercent = (value) => `${Math.round((Number(value) || 0) * 100)}%`;

const generateMission = () => {
  lua.overhaul_jobs_repo.generateJob();
  currentState.value = "loading";
};

const abandonMission = () => {
  lua.overhaul_jobs_repo.cancelJob();
  currentState.value = "no_mission";
  currentReward.value = 0;
};

const completeMission = () => {
  lua.overhaul_jobs_repo.completeJob();
  currentState.value = "no_mission";
  currentReward.value = 0;
};

const handleBackgroundClick = () => {
  if (currentState.value === "completed") {
    completeMission();
  }
};

const closeDisabledOverlay = () => {
  // Navigate back to start state when closing disabled overlay
  if (currentState.value === "disabled") {
    currentState.value = "no_mission";
  }
};

const updateRepoState = (data) => {
  if (!data) return;

  // Update state based on repo job data
  if (data.state) {
    currentState.value = data.state;
  }

  // Update vehicle details
  if (data.vehicle) {
    vehicleBrand.value = data.vehicle.Brand || "";
    vehicleName.value = data.vehicle.Name || "";
    vehicleYear.value = data.vehicle.year || "";
    vehicleMileage.value = data.vehicle.Mileage || 0;
  }

  // Update location information
  if (typeof data.deliveryLocation !== "undefined") {
    deliveryLocation.value = data.deliveryLocation || "";
  }

  if (typeof data.distanceToDestination !== "undefined") {
    distanceToDestination.value = data.distanceToDestination || 0;
  }

  if (typeof data.totalDistance !== "undefined") {
    totalDistance.value = data.totalDistance || 0;
  }

  // Update reward
  if (typeof data.reward !== "undefined") {
    currentReward.value = data.reward || 0;
  }

  // Update isInRepoVehicle
  if (data.isRepoVehicle !== undefined) {
    isInRepoVehicle.value = data.isRepoVehicle;
  }

  // Update disabled reason
  if (typeof data.disabledReason !== "undefined") {
    disabledReason.value = data.disabledReason;
  }

  if (typeof data.repoTag !== "undefined") {
    repoTag.value = data.repoTag || "";
  }

  if (typeof data.repoTierLabel !== "undefined") {
    repoTierLabel.value = data.repoTierLabel || "";
  }

  if (typeof data.repoSkillLevel !== "undefined") {
    repoSkillLevel.value = Number(data.repoSkillLevel) || 0;
  }

  if (typeof data.repoPayoutBonusPercent !== "undefined") {
    repoPayoutBonusPercent.value = Number(data.repoPayoutBonusPercent) || 0;
  }
};

let mapView = null;

onMounted(() => {
  // Listen for updates from Lua
  events.on("updateRepoState", updateRepoState);

  // Initialize minimap
  store.acquire();
  mapView = store.mountMap(container.value.querySelector('.map-container'));

  // Request initial state
  lua.overhaul_jobs_repo.requestRepoState();
});

onUnmounted(() => {
  events.off("updateRepoState", updateRepoState);
  mapView?.dispose();
  store.release();
});
</script>

<style scoped lang="scss">
.repo-container {
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
}

.panel-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-family: "Overpass", sans-serif;
  font-size: 1.2em;
  font-weight: 600;
  margin-bottom: 0.5em;
}

.reward-bubble {
  position: absolute;
  top: 40px;
  left: 50%;
  transform: translateX(-50%);
  background: rgba(0, 0, 0, 0.9);
  padding: 0.5em 1.5em;
  border-radius: 25px;
  color: white;
  font-weight: bold;
  font-size: 1.2em;
  box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
}

.vehicle-type {
  font-size: 1em;
  background: rgba(30, 144, 255, 0.6);
  color: rgb(255, 255, 255);
  padding: 0.25em 0.5em 0.15em 0.5em;
  border-radius: 0.5em;
  font-weight: 600;
  align-items: center;
  justify-content: center;
}

.vehicle-display {
  font-size: 1.8em;
  font-weight: 700;
  color: #010101;
  margin-top: 0.25em;
  margin-bottom: 0.25em;
  font-family: "Overpass", sans-serif;
}

.instruction-text {
  font-size: 1.2em;
  color: #333;
  margin-bottom: 0.5em;
  font-family: "Overpass", sans-serif;
}

.repo-meta {
  display: flex;
  gap: 0.4em;
  flex-wrap: wrap;
  margin-bottom: 0.55em;
  font-family: "Overpass", sans-serif;
}

.repo-chip {
  font-size: 1em;
  background: rgba(30, 144, 255, 0.12);
  color: #0b396d;
  padding: 0.18em 0.55em 0.12em 0.55em;
  border-radius: 999px;
  border: 1px solid rgba(30, 144, 255, 0.24);
  font-weight: 700;
}

.repo-chip.bonus {
  background: rgba(15, 123, 15, 0.12);
  color: #0f5f0f;
  border-color: rgba(15, 123, 15, 0.24);
}

.vehicle-details {
  display: flex;
  margin-bottom: 0.5em;
  font-family: "Overpass", sans-serif;

  .vehicle-info {
    font-size: 1.1em;
    background: rgba(196, 205, 230, 0.8);
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

.state-button {
  width: 100%;
  padding: 0.75em 0em 0.65em 0em;
  background: #1e90ff;
  color: rgb(255, 255, 255);
  border: none;
  border-radius: 10px;
  font-size: 1.75em;
  font-weight: 600;
  font-family: "Overpass", sans-serif;

  &.abandon {
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

.complete-modal {
  background: rgb(216, 224, 246);
  font-weight: 600;
  padding: 1em;
  border-radius: 20px;
  width: 90%;
}

.fare-display {
  font-size: 1.8em;
  color: #010101;
  margin: 0.5em 0;
  font-family: "Overpass", sans-serif;

  &.center {
    text-align: center;
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
  background: rgba(196, 205, 230, 0.8);
  border-radius: 0.5em;
  float: right;

  &:hover {
    transform: scale(1.15);
  }
}

.panel-content {
  margin-bottom: 1em;
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
