<template>
  <div class="beameats-container">
    <!-- Header / Status -->
    <div class="app-header">
      <BngIcon :type="icons.fastFood" class="header-icon" />
      <h1>BeamEats Driver</h1>
    </div>

    <!-- Main Status Panel -->
    <div class="status-panel">
      <div class="status-row">
        <span class="label">Status:</span>
        <span class="value" :class="statusClass">{{ statusText }}</span>
      </div>
      <div class="status-row">
        <span class="label">Rating:</span>
        <span class="value rating">⭐ {{ playerRating }}</span>
      </div>
      <div class="status-row">
        <span class="label">Today's Earnings:</span>
        <span class="value">${{ formatCurrency(cumulativeReward) }}</span>
      </div>
      <div class="status-row">
        <span class="label">Streak:</span>
        <span class="value">{{ orderStreak }}</span>
      </div>
    </div>

    <!-- Active Job Info (if any) -->
    <div class="job-panel" v-if="currentOrder && state !== 'completed'">
      <div class="job-header">{{ state === "incoming" ? "Incoming Offer" : "Current Order" }}</div>
      <div class="job-details">
        <div class="detail-row">
          <span class="icon">🏪</span>
          <span>{{ currentOrder.restaurant }}</span>
        </div>
        <div class="detail-row">
          <span class="icon">📍</span>
          <span>{{ currentOrder.destination.name || "Customer" }}</span>
        </div>
        <div class="detail-row">
          <span class="icon">💰</span>
          <span>Base Pay: ${{ currentOrder.baseFareDisplay }}</span>
        </div>
        <div class="detail-row" v-if="state === 'incoming'">
          <span class="icon">📏</span>
          <span>{{ currentOrder.totalDistanceDisplay }} km</span>
        </div>
        <div class="detail-row" v-if="state === 'incoming'">
          <span class="icon">⏱️</span>
          <span>{{ currentOrder.expectedTimeDisplay }}</span>
        </div>
      </div>
    </div>

    <!-- Summary View (when state is 'completed') -->
    <div class="job-panel summary-panel" v-if="state === 'completed' && currentOrder">
      <div class="job-header">Earnings Summary</div>
      <div class="job-details">
        <div class="detail-row">
          <span>Base Fare:</span>
          <span class="value-right">${{ currentOrder.baseFareDisplay }}</span>
        </div>
        <div class="detail-row tip">
          <span>Tips:</span>
          <span class="value-right">+${{ currentOrder.totalTipsDisplay }}</span>
        </div>
        <div class="detail-row streak" v-if="currentOrder.streakBonus > 0">
          <span>Streak Bonus:</span>
          <span class="value-right">+${{ currentOrder.streakBonus.toFixed(2) }}</span>
        </div>
        <div class="detail-row bonus">
          <span>Logistics XP:</span>
          <span class="value-right">+{{ streakXP }} XP</span>
        </div>

        <hr class="summary-divider" />

        <div class="detail-row total">
          <span>TOTAL:</span>
          <span class="value-right">${{ currentOrder.totalPaymentDisplay }}</span>
        </div>

        <div class="detail-row distance">
          <small>{{ currentOrder.totalDistanceDisplay }}km driven</small>
        </div>
      </div>
    </div>

    <!-- Controls -->
    <div class="controls-container">
      <button
        class="action-button start-btn"
        v-if="state === 'start' || state === 'disabled'"
        @click="startShift"
        :disabled="state === 'disabled'"
      >
        {{ state === "disabled" ? "Unavailable" : "Start Shift" }}
      </button>

      <div v-if="state === 'incoming'" class="incoming-actions">
        <button class="action-button accept-btn" @click="acceptOrder">Accept</button>
        <button class="action-button decline-btn" @click="declineOrder">Decline</button>
      </div>

      <button class="action-button continue-btn" v-if="state === 'completed'" @click="dismissSummary">
        Continue
      </button>

      <button
        class="action-button stop-btn"
        v-if="state !== 'start' && state !== 'disabled' && state !== 'incoming' && state !== 'completed'"
        @click="endShift"
      >
        End Shift
      </button>
    </div>

    <!-- Disabled Message -->
    <div class="disabled-msg" v-if="state === 'disabled'">
      {{ disabledReason }}
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, computed } from "vue";
import { BngIcon, icons } from "@/common/components/base";
import { lua, useBridge } from "@/bridge";
import { acquireScope } from "../../utils/luaScopes";

const { events } = useBridge();

// State
const state = ref("start");
const currentOrder = ref(null);
const cumulativeReward = ref(0);
const orderStreak = ref(0);
const streakXP = ref(0);
const disabledReason = ref("");
const playerRating = ref("0.0");

// Computed
const statusText = computed(() => {
  switch (state.value) {
    case "start":
      return "Offline";
    case "ready":
      return "Looking for orders...";
    case "incoming":
      return "New Order Available!";
    case "pickup":
      return "Picking up order";
    case "dropoff":
      return "Delivering order";
    case "completed":
      return "Delivery Complete";
    case "disabled":
      return "Unavailable";
    default:
      return state.value;
  }
});

const statusClass = computed(() => {
  switch (state.value) {
    case "start":
      return "text-grey";
    case "ready":
      return "text-blue";
    case "incoming":
      return "text-orange";
    case "pickup":
      return "text-orange";
    case "dropoff":
      return "text-green";
    case "completed":
      return "text-green";
    case "disabled":
      return "text-red";
    default:
      return "";
  }
});

// Formatting
const formatCurrency = (val) => {
  return val.toFixed(2);
};

// Actions
const startShift = () => {
  lua.overhaul_jobs_beamEats.setAvailable();
};

const endShift = () => {
  lua.overhaul_jobs_beamEats.stopBeamEatsJob();
};

const acceptOrder = () => {
  lua.overhaul_jobs_beamEats.acceptOrder();
};

const declineOrder = () => {
  lua.overhaul_jobs_beamEats.rejectOrder();
};

const dismissSummary = () => {
  lua.overhaul_jobs_beamEats.dismissSummary();
};

// Event Handling
const updateState = (data) => {
  if (!data) return;
  state.value = data.state || "start";
  currentOrder.value = data.currentOrder || null;
  cumulativeReward.value = data.cumulativeReward || 0;
  orderStreak.value = data.orderStreak || 0;
  // Ensure streakXP is treated as a number
  streakXP.value = typeof data.streakXP === "number" ? data.streakXP : 0;
  // Log for debugging
  disabledReason.value = data.disabledReason || "";
  playerRating.value = data.playerRating || "0.0";
};

onMounted(async () => {
  events.on("updateBeamEatsState", updateState);
  // Ensure the extension is loaded when the app opens
  await acquireScope(lua, "activity.beamEats");
  await lua.overhaul_jobs_beamEats.requestBeamEatsState();
});

onUnmounted(() => {
  events.off("updateBeamEatsState", updateState);
});
</script>

<style scoped lang="scss">
.beameats-container {
  padding: 46px 10px 12px;
  height: 100%;
  display: flex;
  flex-direction: column;
  background: linear-gradient(to bottom, #fff5f5, #ffe0e0);
  color: #333;
  overflow-y: auto; /* Allow scrolling if content is too tall */
  box-sizing: border-box;
}

.app-header {
  display: flex;
  align-items: center;
  justify-content: center;
  margin-bottom: 8px;
  gap: 6px;

  h1 {
    font-size: 1rem;
    font-weight: 800;
    color: #ff4757;
    margin: 0;
  }

  .header-icon {
    color: #ff4757;
    font-size: 1.1rem;
  }
}

.status-panel {
  background: white;
  padding: 9px 10px;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.05);
  margin-bottom: 8px;
}

.status-row {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 4px;
  font-size: 0.85rem;

  &:last-child {
    margin-bottom: 0;
  }

  .label {
    font-weight: 600;
    color: #666;
  }

  .value {
    font-weight: 700;
  }

  &.promotion-detail {
    font-size: 0.78rem;
  }
}

.value.promotion {
  color: #ff6b35;
}

.job-panel {
  background: white;
  padding: 9px 10px;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.05);
  margin-bottom: 8px;

  .job-header {
    font-size: 0.95rem;
    font-weight: 800;
    color: #333;
    margin-bottom: 6px;
    border-bottom: 2px solid #eee;
    padding-bottom: 6px;
  }

  .detail-row {
    display: flex;
    gap: 6px;
    margin-bottom: 4px;
    align-items: center;
    font-size: 0.85rem;
  }
}

.controls-container {
  margin-top: auto;
  padding-top: 8px;
  /* Clears the phone screen's rounded bottom corners. Lives on the child rather
       than the scrolling container so it survives when the content overflows. */
  padding-bottom: 16px;
  flex-shrink: 0; /* Prevent shrinking */
}

.action-button {
  width: 100%;
  padding: 10px;
  border: none;
  border-radius: 8px;
  font-size: 0.95rem;
  font-weight: 700;
  cursor: pointer;
  transition: transform 0.1s;

  &:active {
    transform: scale(0.98);
  }

  &.start-btn {
    background: #ff4757;
    color: white;

    &:disabled {
      background: #ccc;
      cursor: not-allowed;
    }
  }

  &.stop-btn {
    background: #2f3542;
    color: white;
  }

  &.accept-btn {
    background: #2ed573;
    color: white;
    margin-bottom: 0;
    flex: 1;
  }

  &.decline-btn {
    background: #a4b0be;
    color: white;
    flex: 1;
  }

  &.continue-btn {
    background: #1e90ff;
    color: white;
  }
}

.incoming-actions {
  display: flex;
  flex-direction: row;
  gap: 6px;
  width: 100%;
}

.summary-divider {
  border: none;
  border-top: 1px solid #eee;
  margin: 6px 0;
}

.value-right {
  margin-left: auto;
  font-weight: 700;
}

.tip {
  color: #2ed573;
}
.bonus {
  color: #2ed573;
}
.streak {
  color: #ffa502;
  font-size: 0.78rem;
}
.penalty {
  color: #ff4757;
}
.total {
  font-size: 1rem;
  border-top: 2px solid #ddd;
  padding-top: 6px;
  margin-top: 6px;
}
.distance {
  color: #999;
  font-size: 0.75rem;
  justify-content: center;
  margin-top: 6px;
}

.disabled-msg {
  text-align: center;
  color: #ff4757;
  margin-top: 6px;
  font-size: 0.8rem;
  font-weight: 600;
}

// Text Colors
.text-grey {
  color: #999;
}
.text-blue {
  color: #1e90ff;
}
.text-orange {
  color: #ffa502;
}
.text-green {
  color: #2ed573;
}
.text-red {
  color: #ff4757;
}

.rating {
  color: #ffa502;
} /* Gold color for stars */
</style>
