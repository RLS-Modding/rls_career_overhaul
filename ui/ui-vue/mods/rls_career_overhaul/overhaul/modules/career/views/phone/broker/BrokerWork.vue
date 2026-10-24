<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <BrokerStyles />
        <div data-broker-scope v-if="s.view === 'loads' && (!s.selected || s.expanded)" class="toolbar">
          <div data-broker-scope v-if="s.expanded" class="breadcrumb"><button data-broker-scope class="text-btn" @click="s.view = 'markets'">‹ Markets</button><button data-broker-scope v-if="s.scope" class="text-btn" @click="s.scope = ''">All pickups</button></div>
          <div data-broker-scope class="toolbar-row">
            <input data-broker-scope :value="s.filter.search" v-bng-text-input bng-no-nav="true" placeholder="Search loads" aria-label="Search loads" @input="s.updateFilter('search', $event.target.value)" @keydown.stop @keyup.stop />
            <button data-broker-scope class="icon-btn" :aria-label="`Sort loads: ${sortOptions.find(option => option.value === s.filter.sort)?.label}`" aria-haspopup="dialog" :aria-expanded="sortOpen" @click="sortOpen = true"><BngIcon data-broker-scope :type="icons.sortAsc" /></button>
            <button data-broker-scope class="icon-btn filter-toggle" :aria-label="filterCount ? `Filters: ${filterCount} active` : 'Filters'" @click="filtersOpen = true"><BngIcon data-broker-scope :type="icons.filter" /><span data-broker-scope v-if="filterCount" class="pill accent count">{{ filterCount }}</span></button>
            <button data-broker-scope class="icon-btn" aria-label="Refresh loads" @click="refreshBroker"><BngIcon data-broker-scope :type="icons.restart" /></button>
            <BrokerExpand v-if="!s.expanded" />
          </div>
        </div>
        <div data-broker-scope v-if="s.view === 'loads' && !s.selected" class="jobs-tabs" role="tablist" aria-label="Load availability">
          <button data-broker-scope data-fk="available" role="tab" :aria-selected="s.availability === 'available'" :class="{ active: s.availability === 'available' }" @click="s.availability = 'available'">Available <span data-broker-scope class="pill count">{{ availableCount }}</span></button>
          <button data-broker-scope data-fk="locked" role="tab" :aria-selected="s.availability === 'locked'" :class="{ active: s.availability === 'locked' }" @click="s.availability = 'locked'">Locked <span data-broker-scope class="pill count">{{ lockedCount }}</span></button>
        </div>
        <div data-broker-scope v-if="s.view === 'jobs' && (!s.selected || s.expanded)" class="jobs-tabs"><button data-broker-scope :class="{ active: jobsTab === 'loads' }" @click="jobsTab = 'loads'">Loads<span data-broker-scope class="pill count">{{ activeJobs.length }}</span></button><button data-broker-scope :class="{ active: jobsTab === 'route' }" @click="jobsTab = 'route'; s.selected = null">Route plan</button><BrokerExpand v-if="!s.expanded" /></div>
        <BrokerRoutePlan @vue:mounted="focusView" v-if="s.view === 'jobs' && jobsTab === 'route' && !s.selected" />
        <div data-broker-scope v-else class="workarea" :class="{ 'has-detail': !!s.selectedRow }">
          <div data-broker-scope v-show="!s.selectedRow || s.expanded" ref="listEl" class="scroll load-list" v-bng-ui-nav-scroll @scroll="rememberScroll">
            <button data-broker-scope v-if="s.view === 'loads' && s.scope && !s.expanded" class="text-btn scope-clear" @click="s.scope = ''">All pickups</button>
            <p data-broker-scope v-if="s.expanded" class="list-caption">{{ s.view === 'jobs' ? activeJobs.length : visibleRows.length }} loads <span data-broker-scope v-if="s.view === 'jobs'">{{ s.data.reservationCount }} reserved</span></p>
            <div data-broker-scope class="list-columns" role="row">
              <div data-broker-scope
                v-for="col in tableColumns"
                :key="col.key"
                class="col-head"
                :class="{ 'span-2': col.span === 2, start: col.start }"
                role="columnheader"
              >
                <span data-broker-scope class="col-label" :title="col.hint || col.label">{{ col.label }}</span>
                <span data-broker-scope class="col-chevs">
                  <button data-broker-scope type="button" bng-no-nav="true" class="chev-btn" :class="{ active: columnSortActive(col.key, 'asc') }" :aria-label="col.ascLabel" @click.stop="setColumnSort(col.key, 'asc')"><svg data-broker-scope viewBox="0 0 24 24" aria-hidden="true"><path data-broker-scope d="M7 14l5-5 5 5" /></svg></button>
                  <button data-broker-scope type="button" bng-no-nav="true" class="chev-btn" :class="{ active: columnSortActive(col.key, 'desc') }" :aria-label="col.descLabel" @click.stop="setColumnSort(col.key, 'desc')"><svg data-broker-scope viewBox="0 0 24 24" aria-hidden="true"><path data-broker-scope d="M7 10l5 5 5-5" /></svg></button>
                </span>
              </div>
            </div>
            <template v-for="(row, index) in renderedRows" :key="row.groupKey || row.id">
            <div data-broker-scope v-if="unlockHeading(row, index)" class="list-heading unlock-heading"><h3 data-broker-scope>{{ unlockHeading(row, index).text }}</h3><progress data-broker-scope v-if="unlockHeading(row, index).reason?.progress?.needed" :value="requirementProgress(unlockHeading(row, index).reason)" max="1" :aria-label="unlockHeading(row, index).reason.label" /></div>
            <h3 data-broker-scope v-if="stageHeading(row, index)" class="list-heading stage-heading">{{ stageHeading(row, index) }}</h3>
            <h3 data-broker-scope v-if="pickupHeading(row, index)" class="list-heading pickup-heading"><span data-broker-scope class="pickup-name" :title="pickupHeading(row, index).name">{{ pickupHeading(row, index).name }}</span><BrokerPickup :row="pickupHeading(row, index).pickup" spelled /></h3>
            <article data-broker-scope class="load-entry" :class="{ 'at-pickup': row.atPickup, locked: isLocked(row), startable: canStartHere(row) }">
            <button data-broker-scope class="load-row" :data-fk="row.groupKey || row.id" :class="{ selected: rowSelected(row) }" :aria-pressed="isJobStack(row) ? undefined : s.selected === row.id" :aria-current="isJobStack(row) && rowSelected(row) ? 'true' : undefined" :aria-expanded="isJobStack(row) ? stackExpanded(row) : undefined" :aria-controls="isJobStack(row) ? 'stack-' + (row.groupKey || row.id) : undefined" @click="select(row)">
              <span data-broker-scope class="row-thumb" :class="{ empty: !rowImage(row) }"><img data-broker-scope v-if="rowImage(row)" :src="rowImage(row)" alt="" loading="lazy" /><BngIcon data-broker-scope v-else :type="marketIcon(row.market)" /><span data-broker-scope v-if="offerTimeLeft(row, s.data.logisticsTime)" class="row-expiry" :class="{ ended: offerTimeLeft(row, s.data.logisticsTime) === 'Expired' }" :title="'Offer expires in ' + offerTimeLeft(row, s.data.logisticsTime)"><BngIcon data-broker-scope :type="icons.timer" />{{ offerTimeLeft(row, s.data.logisticsTime) }}</span></span>
              <div data-broker-scope class="row-summary">
                <h3 data-broker-scope class="row-title" :title="row.title"><span data-broker-scope v-if="row.groupCount > 1" class="group-mult">{{ row.groupCount }}×</span>{{ row.title }}</h3>
                <strong data-broker-scope class="pay compact-pay" :class="{ 'stack-pay': isJobStack(row) }"><small data-broker-scope v-if="isJobStack(row)">Total pay</small><MoneyAmount data-broker-scope>{{ money(isJobStack(row) ? row.totalPay : payOf(row)) }}</MoneyAmount></strong>
                <div data-broker-scope class="route" :title="row.from + ' → ' + row.to">{{ groupsByPickup ? '' : row.from + ' ' }}→ {{ row.to }}<span data-broker-scope class="row-haul-inline" :aria-label="dist(row.haulDistance) + ' haul'"><BngIcon data-broker-scope :type="icons.routeSimple" />{{ dist(row.haulDistance) }}</span></div>
                <span data-broker-scope class="row-haul" :title="dist(row.haulDistance) + ' haul'"><BngIcon data-broker-scope :type="icons.routeSimple" />{{ dist(row.haulDistance) }}</span>
                <div data-broker-scope v-if="!isLocked(row)" class="row-status"><span data-broker-scope v-if="!groupsByPickup" class="row-meta"><BrokerPickup :row="row" /></span><BrokerAccess data-broker-scope :row="row" compact /></div>
                <BrokerAccess data-broker-scope v-if="isLocked(row) && !levelReason(row)" :row="row" compact />
              </div>
              <span data-broker-scope class="wide-cell"><BrokerPickup :row="row" /></span>
              <span data-broker-scope class="wide-cell" :aria-label="dist(row.haulDistance) + ' haul'">{{ dist(row.haulDistance) }}</span>
              <span data-broker-scope class="wide-cell cargo-cell" :title="fact(row)">{{ isJobStack(row) ? row.totalQuantity.toLocaleString() + ' ' + row.unit : fact(row) }}</span>
              <strong data-broker-scope class="wide-cell pay"><MoneyAmount data-broker-scope>{{ money(isJobStack(row) ? row.totalPay : payOf(row)) }}</MoneyAmount></strong>
            </button>
            <div data-broker-scope v-if="isJobStack(row)" class="rls-house stack-footer">
              <span data-broker-scope class="stack-cargo"><small data-broker-scope>Total cargo</small><strong data-broker-scope>{{ row.totalQuantity.toLocaleString() }} {{ row.unit }}</strong></span>
              <HouseButton data-broker-scope compact class="stack-toggle" :class="{ 'keyboard-focused': focusedStackControl === 'toggle:' + (row.groupKey || row.id) }" :data-fk="'toggle:' + (row.groupKey || row.id)" :aria-expanded="stackExpanded(row)" :aria-controls="'stack-' + (row.groupKey || row.id)" :aria-label="(stackExpanded(row) ? 'Hide jobs for ' : 'Choose a job from ') + row.title" @focus="focusStackControl" @blur="focusedStackControl = null" @click="toggleJobStack(row, $event.currentTarget)">{{ stackExpanded(row) ? 'Hide jobs' : 'Choose a job' }}</HouseButton>
            </div>
            <div data-broker-scope v-if="canStartHere(row)" class="start-col"><strong data-broker-scope class="pay"><MoneyAmount data-broker-scope>{{ money(payOf(row)) }}</MoneyAmount></strong><button data-broker-scope class="primary start-here" :data-fk="'start:' + row.id" :aria-busy="!!working" @click="startHere(row)">Start here</button></div>
            </article>
            <div data-broker-scope v-if="isJobStack(row) && stackExpanded(row)" :id="'stack-' + (row.groupKey || row.id)" class="rls-house stack-jobs" role="group" :aria-label="row.title + ' jobs'">
              <HouseButton data-broker-scope v-for="(job, jobIndex) in row.groupJobs" :key="job.id" variant="quiet" class="stack-job" :class="{ selected: s.selected === job.id, 'keyboard-focused': focusedStackControl === 'job:' + job.id }" :aria-pressed="s.selected === job.id" :data-fk="'job:' + job.id" @focus="focusStackControl" @blur="focusedStackControl = null" @click="select(job)">
                <span data-broker-scope class="stack-job-label">Load {{ jobIndex + 1 }}</span>
                <span data-broker-scope><small data-broker-scope>Cargo</small>{{ fact(job) }}</span>
                <span data-broker-scope class="stack-job-pay"><small data-broker-scope>Pay</small><MoneyAmount data-broker-scope>{{ money(payOf(job)) }}</MoneyAmount></span>
              </HouseButton>
            </div>
            </template>
            <button data-broker-scope v-if="renderedRows.length < visibleRows.length" class="browse-all" @click="rowLimit += 100">Show more loads</button><div data-broker-scope v-if="!visibleRows.length" class="empty"><p data-broker-scope>{{ s.view === 'jobs' ? 'No active loads.' : s.availability === 'locked' ? 'No locked loads match these filters.' : 'No available loads match these filters.' }}</p><button data-broker-scope v-if="s.view === 'loads'" @click="s.resetFilters">Reset filters</button></div>
          </div>
<BrokerDetails @vue:mounted="focusView" v-if="s.selectedRow" />
          <aside data-broker-scope v-else class="detail-placeholder" aria-label="Load details"><BngIcon data-broker-scope :type="icons.cardboardBox" /><h3 data-broker-scope>Select a load</h3><p data-broker-scope>Review the route, cargo and requirements here.</p><small data-broker-scope>{{ s.view === 'jobs' ? 'Manage your pickup and delivery.' : 'Reserve a load or save it to your route.' }}</small></aside>
        </div>
        <PhoneLayer data-broker-scope v-if="filtersOpen" label="Filters" class="broker-sort" @close="filtersOpen = false"><BrokerFilters @done="filtersOpen = false" /></PhoneLayer>
        <PhoneLayer data-broker-scope v-if="sortOpen" label="Sort loads" class="broker-sort" @close="sortOpen = false">
          <div data-broker-scope class="sort-panel">
            <h3 data-broker-scope>Sort loads</h3>
            <div data-broker-scope class="sort-options" role="group" aria-label="Sort order"><button data-broker-scope v-for="option in sortOptions" :key="option.value" type="button" :aria-pressed="s.filter.sort === option.value" :class="{ active: s.filter.sort === option.value }" @click="s.updateFilter('sort', option.value); sortOpen = false">{{ option.label }}</button></div>
            <button data-broker-scope @click="sortOpen = false">Cancel</button>
          </div>
        </PhoneLayer>
</template>

<script setup>
import { vBngTextInput, vBngUiNavScroll } from "@/common/directives"
import MoneyAmount from '../../../components/MoneyAmount.vue'
import HouseButton from '../../../components/house/HouseButton.vue'
import BrokerAccess from './BrokerAccess.vue'
import BrokerStyles from './BrokerStyles.vue'
import BrokerExpand from './BrokerExpand.vue'
import BrokerPickup from './BrokerPickup.vue'
import PhoneLayer from '../../../components/phone/PhoneLayer.vue'
import { inject, defineAsyncComponent, onMounted, onBeforeUnmount } from 'vue'
const BrokerDetails = defineAsyncComponent(() => import('./BrokerDetails.vue'))
const BrokerRoutePlan = defineAsyncComponent(() => import('./BrokerRoutePlan.vue'))
const BrokerFilters = defineAsyncComponent(() => import('./BrokerFilters.vue'))
const { isJobStack, stackExpanded, toggleJobStack, availableCount, lockedCount, offerTimeLeft, unlockHeading, levelReason, requirementProgress, stageHeading, groupsByPickup, pickupHeading, startHere, isLocked, focusView, ref, BngIcon, icons, markets, s, route, listEl, jobsTab, rowLimit, filtersOpen, rowImage, renderedRows, sortOptions, working, activeJobs, visibleRows, filterCount, marketIcon, money, dist, tableColumns, setColumnSort, columnSortActive, fact, payOf, legDistance, statusName, rememberScroll, select, stopJob, openStop, refreshBroker } = inject(Symbol.for('overhaul.phoneBroker'))
const sortOpen = ref(false)
const canStartHere = row => s.view === 'loads' && row.atPickup && !isLocked(row)
const rowSelected = row => isJobStack(row) ? row.groupJobs.some(job => s.selected === job.id) : s.selected === row.id
// Stock controller focus uses .focus-visible. Native Tab needs the same House
// ring while following the controller contract's class-based focus styling.
const focusedStackControl = ref(null)
let pointerFocus = false
const noteStackKeyboard = event => { if (event.key === 'Tab') pointerFocus = false }
const noteStackPointer = () => { pointerFocus = true; focusedStackControl.value = null }
const focusStackControl = event => {
  if (!pointerFocus) focusedStackControl.value = event.currentTarget.dataset.fk
}
onMounted(() => {
  document.addEventListener('keydown', noteStackKeyboard, true)
  document.addEventListener('pointerdown', noteStackPointer, true)
})
onBeforeUnmount(() => {
  document.removeEventListener('keydown', noteStackKeyboard, true)
  document.removeEventListener('pointerdown', noteStackPointer, true)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.stack-pay { display: grid; justify-items: end; align-self: start; }
.stack-pay small, .stack-cargo small, .stack-job small { display: block; color: var(--muted); font-size: .75em; font-weight: 700; }
.stack-footer { display: flex; align-items: center; justify-content: space-between; gap: var(--space-3); padding: 0 .75em .75em; }
.stack-cargo { display: grid; gap: .15em; }
.stack-toggle { margin-left: auto; }
.stack-jobs { display: grid; gap: var(--space-2); padding: .3em 0 .7em 1em; }
.stack-job { width: 100%; text-align: left; }
.stack-job.selected { border-color: rgba(255, 102, 0, 0.6); background: rgba(255, 102, 0, 0.1) !important; }
.stack-job :deep(.btn-label) { display: flex; width: 100%; justify-content: space-between; gap: 1em; }
.stack-job-pay { color: var(--money); white-space: nowrap; }
.stack-toggle, .stack-job {
  @include house-focus(var(--focus-inset));
  &.keyboard-focused { outline: none; box-shadow: var(--focus-inset); }
}
</style>
