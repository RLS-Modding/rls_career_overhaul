<template>
  <div class="card-expand">
    <div class="card-actions">
      <button type="button" class="act-btn route" @click.stop="$emit('set-route', ev.raceName)">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
        Set Route
      </button>
    </div>
    <div class="detail-section">
      <div class="detail-heading">Event Goals</div>
      <div class="detail-grid">
        <div class="detail-row" v-if="!ev.isDemoEvent && !isScoreEvent(ev) && !ev.hasTopSpeed && !ev.isPulling && ev.bestTime != null">
          <span class="detail-label">Target Time</span>
          <span class="detail-value">{{ formatTime(ev.bestTime) }}</span>
        </div>
        <div class="detail-row" v-if="ev.isPulling">
          <span class="detail-label">Full Pull</span>
          <span class="detail-value">{{ (ev.pullDistanceMeters * FEET_PER_METER).toFixed(1) }} ft</span>
        </div>
        <div class="detail-row" v-if="ev.isDemoEvent">
          <span class="detail-label">Mode</span>
          <span class="detail-value">Last car standing</span>
        </div>
        <div class="detail-row">
          <span class="detail-label">Reward</span>
          <span class="detail-value">{{ careerActive ? '$' + formatPrice(ev.reward) : 'Career only' }}</span>
        </div>
        <div class="detail-row" v-if="ev.isDemoEvent">
          <span class="detail-label">Reward Gate</span>
          <span class="detail-value">Top 50% placement</span>
        </div>
        <div class="detail-row" v-if="ev.hotlap && !isScoreEvent(ev)">
          <span class="detail-label">Hotlap</span>
          <span class="detail-value">{{ formatTime(ev.hotlap) }}</span>
        </div>
        <div class="detail-row" v-if="ev.hasDamageFactor">
          <span class="detail-label">Damage</span>
          <span class="detail-value">{{ Math.round(ev.damageFactor * 100) }}%</span>
        </div>
        <div class="detail-row" v-if="ev.hasTopSpeed && ev.topSpeedGoal">
          <span class="detail-label">Speed</span>
          <span class="detail-value">{{ ev.topSpeedGoal.toFixed(1) }} mph</span>
        </div>
        <div class="detail-row" v-if="isScoreEvent(ev) && !ev.hasBurnout && scoreTarget(ev) != null">
          <span class="detail-label">Target Score</span>
          <span class="detail-value">{{ formatScore(scoreTarget(ev)) }}</span>
        </div>
        <div class="detail-row" v-if="ev.hasBurnout">
          <span class="detail-label">Score</span>
          <span class="detail-value">Open, {{ (ev.scoreGoal || DEFAULT_SCORE_GOAL).toLocaleString() }} pts for max reward</span>
        </div>
        <div class="detail-row" v-if="ev.hasBurnout">
          <span class="detail-label">Penalty</span>
          <span class="detail-value">Chassis impacts reduce score</span>
        </div>
      </div>
    </div>
    <div class="detail-section" v-if="ev.hasAltRoute">
      <div class="detail-heading">Alternative Route</div>
      <div class="detail-row">
        <span class="detail-label">Route</span><span class="detail-value">{{ ev.altRouteLabel }}</span>
      </div>
      <div class="detail-row" v-if="!isScoreEvent(ev) && ev.altRouteBestTime != null">
        <span class="detail-label">Target Time</span><span class="detail-value">{{ formatTime(ev.altRouteBestTime) }}</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Reward</span><span class="detail-value">{{ careerActive ? '$' + formatPrice(ev.altRouteReward) : 'Career only' }}</span>
      </div>
    </div>
    <div class="detail-section">
      <div class="detail-heading">Your Progress</div>
      <EventBestResult v-if="!ev.isDemoEvent && !ev.isPulling" :ev="ev" />
      <div v-else class="detail-row">
        <span class="detail-label">{{ ev.currentVehicleName || 'No Vehicle' }}</span>
        <span class="detail-value">{{ ev.isDemoEvent ? ((ev.demoStats && ev.demoStats.runs > 0) ? (ev.demoStats.runs + ' derby runs') : 'No derby runs') : (ev.currentVehicleBestPullDistance ? (ev.currentVehicleBestPullDistance * FEET_PER_METER).toFixed(1) + ' ft' : 'No result yet') }}</span>
      </div>
    </div>
    <div class="detail-section" v-if="ev.isDemoEvent">
      <div class="detail-heading">Derby Stats</div>
      <div class="detail-grid">
        <div class="detail-row" v-if="ev.demoStats && ev.demoStats.runs > 0">
          <span class="detail-label">Wins</span>
          <span class="detail-value">{{ ev.demoStats.wins || 0 }} / {{ ev.demoStats.runs || 0 }}</span>
        </div>
        <div class="detail-row" v-if="ev.demoStats && ev.demoStats.runs > 0">
          <span class="detail-label">Podium Rate</span>
          <span class="detail-value">{{ formatPercent(ev.demoStats.podiumRate || 0) }}</span>
        </div>
        <div class="detail-row" v-if="ev.demoStats && ev.demoStats.runs > 0">
          <span class="detail-label">Average Placement</span>
          <span class="detail-value">{{ formatPlacement(ev.demoStats.averagePlacement) }}</span>
        </div>
        <div class="detail-row" v-if="ev.demoStats && ev.demoStats.fastestEliminationTime">
          <span class="detail-label">Fastest Elimination</span>
          <span class="detail-value">{{ formatTime(ev.demoStats.fastestEliminationTime) }}</span>
        </div>
        <div class="detail-row" v-if="ev.demoStats && ev.demoStats.runs > 0">
          <span class="detail-label">Avg Survival</span>
          <span class="detail-value">{{ formatTime(ev.demoStats.averageSurvivalTime) }}</span>
        </div>
        <div class="detail-row" v-if="!ev.demoStats || ev.demoStats.runs <= 0">
          <span class="detail-label">Status</span>
          <span class="detail-value">No derby record yet</span>
        </div>
      </div>
    </div>
    <div class="detail-section" v-if="ev.vehicleRecords && ev.vehicleRecords.length > 0">
      <div class="detail-heading">Records</div>
      <div class="records-list">
        <div class="record-row" v-for="rec in (ev.isDemoEvent || ev.isPulling ? ev.vehicleRecords : eventRecords(ev))" :key="String(rec.inventoryId) + '-' + String(rec.sledId || '')">
          <span class="record-name">{{ rec.vehicleName }}</span>
          <span class="record-time" v-if="ev.isPulling">
            Sled: {{ rec.sledLabel }}<br />Distance: {{ (rec.pullDistance * FEET_PER_METER).toFixed(1) }} ft<span v-if="rec.fullPull && rec.time != null"><br />Time: {{ formatTime(rec.time) }}</span>
          </span>
          <span class="record-time" v-else-if="!ev.isDemoEvent">{{ bestLabel(ev) }}: {{ bestValue(ev, rec) }}</span>
          <span class="record-time" v-else>
            <template v-if="rec.demoStats && rec.demoStats.runs > 0">
              {{ rec.demoStats.wins || 0 }}W, {{ formatPercent(rec.demoStats.podiumRate || 0) }} podium, avg {{ formatPlacement(rec.demoStats.averagePlacement) }}
            </template>
            <template v-else>No derby runs</template>
          </span>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
// The expanded body of one event card: the set-route action, goals, alternative route, progress, derby stats and
// vehicle records. Pure presentation of one event: it reads props and reports Set Route as an event.
import EventBestResult from './EventBestResult.vue'
import { bestLabel, bestValue, eventRecords, isScoreEvent, scoreTarget, formatScore, FEET_PER_METER, formatPercent, formatPlacement, formatPrice, formatTime } from './eventFormat.js'

// Score goal shown for a burnout event that does not carry its own.
const DEFAULT_SCORE_GOAL = 6000

defineProps({
  ev: { type: Object, required: true },
  careerActive: { type: Boolean, required: true },
})

defineEmits(['set-route'])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.card-expand {
  padding: 0;
  animation: slideDown 0.2s ease;
  width: 100%;
  box-sizing: border-box;
}

.card-actions {
  display: flex;
  padding: 10px 16px 12px;
  border-bottom: 1px solid rgba(31,35,40,0.12);
  width: 100%;
  box-sizing: border-box;
}

.card-actions .act-btn {
  width: 100%;
  justify-content: center;
  padding: 10px 14px;
  font-size: 13px;
}

.detail-section {
  padding: 12px 16px;
  width: 100%;
  box-sizing: border-box;
  & + .detail-section {
    border-top: 1px solid rgba(31,35,40,0.12);
  }
}

.detail-heading {
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: rgba(31,35,40,0.55);
  margin-bottom: 8px;
}

.detail-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  column-gap: 14px;
  row-gap: 0;
  width: 100%;
}

.detail-grid .detail-row {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 2px;
  padding: 8px 0;
  border-bottom: 1px solid rgba(31,35,40,0.1);
  min-width: 0;
}

.detail-grid .detail-label {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.3px;
  color: rgba(31,35,40,0.62);
}

.detail-grid .detail-value {
  font-size: 15px;
  font-weight: 700;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 5px 0;
  width: 100%;
  box-sizing: border-box;
}

.detail-label {
  font-size: 12px;
  color: rgba(31,35,40,0.72);
}

.detail-value {
  font-size: 12px;
  font-weight: 600;
  color: #1f2328;
}

.records-list {
  display: flex;
  flex-direction: column;
  gap: 0;
  width: 100%;
}

.record-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 7px 0;
  border-bottom: 1px solid rgba(31,35,40,0.1);
  &:last-child { border-bottom: none; }
}

.record-name {
  font-size: 12px;
  color: rgba(31,35,40,0.74);
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-right: 8px;
}

.record-time {
  font-size: 12px;
  font-weight: 600;
  color: rgba(31,35,40,0.9);
  white-space: nowrap;
}

.act-btn {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 8px 14px;
  border-radius: 10px;
  border: none;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  transition: opacity 0.15s ease;
  &:hover { opacity: 0.85; }
  &.route { background: rgba(230,57,70,0.15); color: #e63946; }
}

@keyframes slideDown {
  from { opacity: 0; transform: translateY(-6px); }
  to { opacity: 1; transform: translateY(0); }
}
</style>
