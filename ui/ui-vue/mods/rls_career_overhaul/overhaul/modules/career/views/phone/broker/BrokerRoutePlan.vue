<template>
        <div data-broker-scope class="scroll route-plan" v-bng-ui-nav-scroll>
          <RouteMap data-broker-scope v-if="s.data.stops.length" class="plan-map" :legs="planPreview?.legs || []" :points="planPreview?.points || {}">{{ planLoading ? 'Tracing route…' : 'Route preview unavailable' }}</RouteMap>
          <div data-broker-scope class="route-summary">
            <div data-broker-scope class="route-stats">
              <div data-broker-scope class="stat"><span data-broker-scope class="stat-key">Stops</span><span data-broker-scope class="stat-value">{{ s.data.stops.length }}</span></div>
              <div data-broker-scope class="stat"><span data-broker-scope class="stat-key">Total drive</span><span data-broker-scope class="stat-value">{{ s.data.route?.total ? dist(s.data.route.total) : '—' }}</span></div>
              <div data-broker-scope class="stat"><span data-broker-scope class="stat-key">Reserved</span><span data-broker-scope class="stat-value">{{ s.data.reservationCount }}</span></div>
            </div>
            <div data-broker-scope class="route-actions">
              <button data-broker-scope class="primary" :disabled="working || !s.data.stops.length" @click="s.action('showRoute')"><BngIcon data-broker-scope :type="icons.routeSimple" />Show on map</button>
              <button data-broker-scope :disabled="working || s.data.stops.length < 2" @click="s.action('optimizeStops')">Auto-order</button>
              <button data-broker-scope class="text-btn" :disabled="working" @click="s.action('clearRoute')">Clear markers</button>
            </div>
          </div>
          <div data-broker-scope v-if="s.data.stops.length" class="stop-list">
            <div data-broker-scope v-for="(stop, index) in s.data.stops" :key="stop.id" class="plan-stop" :class="stop.kind">
              <span data-broker-scope class="plan-index">{{ index + 1 }}</span>
              <button data-broker-scope class="stop-main" @click="openStop(stop)">
                <span data-broker-scope class="stop-kind pill" :class="stop.kind === 'pickup' ? 'accent' : ''">{{ stop.kind === 'pickup' ? 'Pickup' : 'Deliver' }}</span>
                <strong data-broker-scope>{{ stopJob(stop)?.title || 'Unavailable load' }}</strong>
                <small data-broker-scope>{{ stop.name || stopJob(stop)?.[stop.kind === 'pickup' ? 'from' : 'to'] }}</small>
              </button>
              <span data-broker-scope class="leg"><span data-broker-scope class="leg-dist">{{ legDistance(stop) }}</span><span data-broker-scope class="leg-status">{{ stopJob(stop)?.status ? statusName(stopJob(stop).status) : 'Saved' }}</span></span>
              <div data-broker-scope class="plan-move"><button data-broker-scope :disabled="working || !index" aria-label="Move stop up" @click="s.action('moveStop', { index: index + 1, delta: -1 })"><BngIcon data-broker-scope :type="icons.arrowSmallUp" /></button><button data-broker-scope :disabled="working || index === s.data.stops.length - 1" aria-label="Move stop down" @click="s.action('moveStop', { index: index + 1, delta: 1 })"><BngIcon data-broker-scope :type="icons.arrowSmallDown" /></button></div>
            </div>
          </div>
          <div data-broker-scope v-else class="empty"><BngIcon data-broker-scope :type="icons.routeSimple" /><h3 data-broker-scope>No stops yet</h3><p data-broker-scope>Save loads to plan a route. Saving does not reserve them.</p></div>
        </div>
</template>

<script setup>
import { vBngUiNavScroll } from "@/common/directives"
import { inject } from 'vue'
const { BngIcon, icons, RouteMap, s, route, planPreview, planLoading, working, dist, legDistance, statusName, stopJob, openStop } = inject(Symbol.for('overhaul.phoneBroker'))
</script>
