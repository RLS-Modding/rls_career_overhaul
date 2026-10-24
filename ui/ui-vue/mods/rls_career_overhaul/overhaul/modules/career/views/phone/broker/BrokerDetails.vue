<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
          <section data-broker-scope class="detail-pane" aria-label="Selected load"><div data-broker-scope class="scroll detail-scroll" v-bng-ui-nav-scroll>
            <div data-broker-scope class="detail-hero" :class="{ 'no-photo': !rowImage(s.selectedRow) }">
              <img data-broker-scope v-if="rowImage(s.selectedRow)" :src="rowImage(s.selectedRow)" alt="" />
              <button data-broker-scope class="icon-btn detail-close" :aria-label="s.expanded ? 'Clear selection' : 'Back to loads'" :title="s.expanded ? 'Clear selection' : 'Back to loads'" @click="closeDetail"><svg data-broker-scope viewBox="0 0 24 24"><path data-broker-scope d="M6 6l12 12M18 6L6 18"/></svg></button>
              <div data-broker-scope class="detail-hero-copy">
                <p data-broker-scope class="eyebrow">{{ markets.find(m => m.id === s.selectedRow.market)?.name }}</p>
                <h2 data-broker-scope><span data-broker-scope v-if="selectedListRow?.groupCount > 1" class="group-mult">{{ selectedListRow.groupCount }}×</span>{{ s.selectedRow.title }}</h2>
              </div>
              <div data-broker-scope class="detail-hero-pay">
                <span data-broker-scope class="detail-pay"><MoneyAmount data-broker-scope>{{ money(payOf(s.selectedRow)) }}</MoneyAmount></span>
                <span data-broker-scope v-if="s.selectedRow.status" class="pill accent">{{ statusName(s.selectedRow.status) }}</span>
                <span data-broker-scope v-else-if="s.selectedRow.kind === 'material'" class="pill">Full contract</span>
              </div>
            </div>
            <div data-broker-scope v-if="showLoader" class="loader">
              <div data-broker-scope class="block-head"><div data-broker-scope class="kicker">Load at {{ s.selectedRow.from }}</div><button data-broker-scope type="button" class="tip-btn" :class="{ spinning: containerLoading }" :disabled="containerLoading" aria-label="Refresh equipment" data-tip="Rescan cargo space" @click="refreshContainers"><svg data-broker-scope viewBox="0 0 24 24"><path data-broker-scope d="M20 12a8 8 0 1 1-2.35-5.65"/><path data-broker-scope d="M20 4v4.5h-4.5"/></svg></button><button data-broker-scope v-if="parcelBoxes.length > 1 && pickupParcels.length > 1" type="button" class="text-btn split-btn" :disabled="working" @click="autoSplit()">Auto split</button></div>
              <p data-broker-scope v-if="containerLoading || containerError || !parcelBoxes.length" class="muted" role="status" aria-live="polite">{{ containerLoading ? 'Checking nearby cargo space…' : containerError || 'No cargo boxes nearby. Bring a vehicle with cargo space, then refresh.' }}</p>
              <template v-else>
                <p data-broker-scope v-if="loadVehicle" class="load-veh">Into your {{ loadVehicle }}</p>
                <ul data-broker-scope class="bins" aria-label="Cargo boxes">
                  <li data-broker-scope v-for="(c, i) in parcelBoxes" :key="c.key" class="bin" :class="{ planned: boxUse(c.key) > 0 }">
                    <span data-broker-scope class="bin-no">{{ i + 1 }}</span>
                    <span data-broker-scope class="bin-copy"><strong data-broker-scope>{{ boxLabel(c) }}</strong><small data-broker-scope v-if="!loadVehicle">{{ c.vehName || '' }}</small></span>
                    <span data-broker-scope class="bin-left"><b data-broker-scope>{{ boxLeft(c) }}</b> left</span>
                    <span data-broker-scope class="bin-bar" :title="`${boxHeld(c)} held · ${boxUse(c.key)} planned · ${boxLeft(c)} free of ${boxCap(c)}`"><span data-broker-scope class="held" :style="{ flexBasis: share(boxHeld(c), boxCap(c)) }"></span><span data-broker-scope class="plan" :style="{ flexBasis: share(boxUse(c.key), boxCap(c)) }"></span></span>
                  </li>
                </ul>
                <div data-broker-scope class="parcels" role="group" aria-label="Parcels to load">
                  <div data-broker-scope v-for="g in pickupGroups" :key="g.id" class="parcel" :class="{ off: !groupLoad(g), stuck: groupStuck(g) > 0 }">
                    <button data-broker-scope type="button" class="tick" role="checkbox" :aria-checked="!groupLoad(g) ? 'false' : groupLoad(g) === g.groupCount ? 'true' : 'mixed'" :class="{ part: groupLoad(g) && groupLoad(g) < g.groupCount }" :aria-label="`Load ${g.title}`" @click="toggleGroup(g)"><svg data-broker-scope viewBox="0 0 24 24"><path data-broker-scope v-if="groupLoad(g) && groupLoad(g) < g.groupCount" d="M6 12h12" /><path data-broker-scope v-else d="M5 12.5l4.2 4.2L19 7" /></svg></button>
                    <span data-broker-scope class="parcel-copy"><strong data-broker-scope><span data-broker-scope v-if="g.groupCount > 1" class="group-mult">{{ g.groupCount }}×</span>{{ g.title }}</strong><small data-broker-scope><span data-broker-scope v-if="g.status && !s.selectedRow.status">Reserved</span><span data-broker-scope>{{ `${slotsOf(g)} ${slotsOf(g) === 1 ? 'slot' : 'slots'}${g.groupCount > 1 ? ' each' : ''}` }}</span><span data-broker-scope>{{ g.to }}</span></small></span>
                    <span data-broker-scope v-if="g.groupCount > 1 && groupLoad(g)" class="count" role="group" :aria-label="`How many ${g.title} to load`"><button data-broker-scope type="button" aria-label="Load one fewer" @click="stepGroup(g, -1)">−</button><b data-broker-scope>{{ groupLoad(g) }}</b><button data-broker-scope type="button" aria-label="Load one more" :disabled="groupLoad(g) >= g.groupCount" @click="stepGroup(g, 1)">+</button></span>
                    <span data-broker-scope v-if="groupLoad(g)" class="splits">
                      <button data-broker-scope v-for="sp in groupSplits(g)" :key="sp.key" type="button" class="box-pick" :disabled="!canMove(sp.job)" :title="canMove(sp.job) ? 'Move one to the next box with room' : 'No other box has room'" @click="cycleBox(sp.job)"><span data-broker-scope class="bin-no">{{ boxIndex(sp.key) + 1 }}</span>{{ boxLabel(boxByKey(sp.key)) }}<em data-broker-scope v-if="g.groupCount > 1">×{{ sp.n }}</em><svg data-broker-scope v-if="canMove(sp.job)" viewBox="0 0 24 24"><path data-broker-scope d="M7 4v16M7 20l-3-3M7 20l3-3M17 20V4M17 4l-3 3M17 4l3 3" /></svg></button>
                      <span data-broker-scope v-if="groupStuck(g)" class="box-pick nope">{{ groupStuck(g) > 1 || g.groupCount > 1 ? `${groupStuck(g)} won't fit` : 'No room' }}</span>
                    </span>
                  </div>
                </div>
              </template>
            </div>
            <div data-broker-scope class="detail-head">
              <div data-broker-scope class="facts">
                <div data-broker-scope v-for="f in detailFacts" :key="f.k" class="fact"><span data-broker-scope class="fact-key">{{ f.k }}</span><span data-broker-scope class="fact-value" :class="f.cls"><BngIcon data-broker-scope v-if="f.icon" :type="f.icon" /><MoneyAmount data-broker-scope v-if="f.money">{{ f.v }}</MoneyAmount><template v-else>{{ f.v }}</template></span></div>
              </div>
            <p data-broker-scope v-if="!isLocked(s.selectedRow) && s.selectedRow.kind !== 'material'" class="pay-note">{{ Number(s.selectedRow.levelBonus) > 0 ? 'Pay shown includes your Logistics level bonus.' : 'Pay shown is the base rate.' }} On-time, no-damage and parking bonuses are paid on top.</p>
              <BrokerTimeline data-broker-scope v-if="s.selectedRow.status" :row="s.selectedRow" />
              <BrokerAccess data-broker-scope :row="s.selectedRow" />
              <button data-broker-scope v-if="isLocked(s.selectedRow)" class="text-btn" @click="openRequirements">View Logistics skills</button>
            </div>
            <div data-broker-scope class="route-row" aria-label="Route">
              <div data-broker-scope class="route-cell"><small data-broker-scope>Pickup</small><strong data-broker-scope>{{ s.selectedRow.from }}</strong><BrokerPickup :row="s.selectedRow" /></div>
              <span data-broker-scope class="route-arrow"><svg data-broker-scope viewBox="0 0 24 24" aria-hidden="true"><path data-broker-scope d="M9 5l7 7-7 7" /></svg><em data-broker-scope :aria-label="dist(s.selectedRow.haulDistance) + ' haul'">{{ dist(s.selectedRow.haulDistance) }}</em></span>
              <div data-broker-scope class="route-cell"><small data-broker-scope>Delivery</small><strong data-broker-scope>{{ s.selectedRow.to }}</strong></div>
            </div>
            <div data-broker-scope v-if="s.selectedRow.remaining != null" class="progress" aria-label="Progress">
              <div data-broker-scope class="bar"><span data-broker-scope class="done" :style="{ width: pct(s.selectedRow.delivered) }"></span><span data-broker-scope class="transit" :style="{ width: pct(s.selectedRow.inTransit) }"></span></div>
              <div data-broker-scope class="legend"><span data-broker-scope><b data-broker-scope>{{ s.selectedRow.delivered || 0 }}</b> delivered</span><span data-broker-scope><b data-broker-scope>{{ s.selectedRow.inTransit || 0 }}</b> in transit</span><span data-broker-scope><b data-broker-scope>{{ s.selectedRow.remaining }}</b> remaining</span></div>
            </div>
            <div data-broker-scope v-if="s.selectedRow.atPickup && s.selectedRow.kind === 'material'" class="pickup-form">
              <div data-broker-scope class="block-head"><div data-broker-scope class="kicker">Load into</div><button data-broker-scope type="button" class="tip-btn" :class="{ spinning: containerLoading }" :disabled="containerLoading" aria-label="Refresh equipment" data-tip="Rescan cargo space" @click="refreshContainers"><svg data-broker-scope viewBox="0 0 24 24"><path data-broker-scope d="M20 12a8 8 0 1 1-2.35-5.65"/><path data-broker-scope d="M20 4v4.5h-4.5"/></svg></button></div>
              <p data-broker-scope v-if="containerLoading || containerError || !s.containers.length" class="muted" role="status" aria-live="polite">{{ containerLoading ? 'Checking nearby cargo space…' : containerError || 'No cargo containers detected. Bring a vehicle with cargo boxes or a suitable tank, then refresh.' }}</p>
              <div data-broker-scope v-else class="chips" role="radiogroup" aria-label="Cargo space"><button data-broker-scope v-for="c in s.containers" :key="c.key" type="button" role="radio" :aria-checked="container === c.key" :class="{ active: container === c.key }" @click="container = c.key">{{ c.name }} <span data-broker-scope class="pill">{{ c.free }} free</span></button></div>
            </div>
            <div data-broker-scope v-if="s.selectedRow.kind === 'cars' && s.selectedRow.status" class="car-choices">
              <div data-broker-scope class="kicker">Vehicles</div>
              <button data-broker-scope v-for="car in s.selectedRow.vehicles" :key="car.key" type="button" class="car" :class="{ picked: selectedCars.includes(car.key), done: car.status && car.status !== 'pending' }" :disabled="!!(car.status && car.status !== 'pending')" :aria-pressed="selectedCars.includes(car.key)" @click="toggleCar(car.key)"><span data-broker-scope class="car-img"><img data-broker-scope v-if="car.thumbnail" :src="car.thumbnail" alt="" loading="lazy" /><BngIcon data-broker-scope v-else :type="icons.keys1" /></span><span data-broker-scope class="car-copy"><strong data-broker-scope>{{ car.label }}</strong><small data-broker-scope>{{ car.destFacName }}</small></span><span data-broker-scope class="car-state" :class="car.status === 'delivered' ? 'ok' : car.status && car.status !== 'pending' ? 'busy' : ''">{{ car.status === 'delivered' ? 'Delivered' : car.status && car.status !== 'pending' ? car.status : 'Pending' }}</span></button>
            </div>
            <button data-broker-scope class="text-btn" @click="s.view = 'loaners'; s.selected = null">Browse loaner equipment →</button>
            <RouteMap data-broker-scope v-if="!s.expanded && !showLoader" class="detail-map inline" :legs="routePreview?.legs || []" :points="routePreview?.points || {}">{{ routeLoading ? 'Tracing route…' : 'Route preview unavailable' }}</RouteMap>
          </div><div data-broker-scope v-if="s.expanded && !showLoader" class="detail-map-slot"><RouteMap data-broker-scope class="detail-map" :legs="routePreview?.legs || []" :points="routePreview?.points || {}">{{ routeLoading ? 'Tracing route…' : 'Route preview unavailable' }}</RouteMap></div><div data-broker-scope class="detail-actions">
            <button data-broker-scope v-if="!s.selectedRow.status && s.selectedRow.atPickup && !isLocked(s.selectedRow)" class="primary" :data-fk="'start:' + s.selectedRow.id" :aria-busy="!!working" @click="startHere(s.selectedRow)">Start here</button>
            <template v-if="!s.selectedRow.status && showLoader"><div data-broker-scope class="next-step"><span data-broker-scope class="kicker">Here</span><span data-broker-scope class="next-step-text">{{ loadStep.hint }}</span></div><button data-broker-scope class="primary" :disabled="working || loadStep.disabled" @click="loadParcels">{{ loadStep.label }}</button><button data-broker-scope :disabled="working || isLocked(s.selectedRow)" @click="reserveSelected">{{ reserveAmount > 1 ? `Reserve ${reserveAmount} instead` : 'Reserve instead' }}</button><button data-broker-scope @click="s.action('plan', { id: s.selectedRow.id })">{{ isSaved(s.selectedRow) ? 'Remove saved plan' : 'Save to route' }}</button></template>
            <template v-else-if="!s.selectedRow.status"><div data-broker-scope v-if="reserveGroup > 1" class="reserve-amount"><span data-broker-scope class="kicker">Reserve</span><span data-broker-scope class="count" role="group" aria-label="How many to reserve"><button data-broker-scope type="button" aria-label="Reserve one fewer" :disabled="reserveAmount <= 1" @click="stepReserve(-1)">−</button><b data-broker-scope>{{ reserveAmount }}</b><button data-broker-scope type="button" aria-label="Reserve one more" :disabled="reserveAmount >= reserveMax" @click="stepReserve(1)">+</button></span><span data-broker-scope class="reserve-note"><span data-broker-scope>of {{ reserveGroup }}</span><span data-broker-scope>{{ reserveSlots(reserveAmount) }}</span></span><span data-broker-scope class="reserve-pay"><MoneyAmount data-broker-scope>{{ money(payOf(s.selectedRow) * reserveAmount) }}</MoneyAmount></span></div><button data-broker-scope class="primary" :disabled="working || isLocked(s.selectedRow)" @click="reserveSelected">{{ reserveAmount > 1 ? `Reserve ${reserveAmount} loads` : 'Reserve load' }}</button><button data-broker-scope @click="s.action('plan', { id: s.selectedRow.id })">{{ isSaved(s.selectedRow) ? 'Remove saved plan' : 'Save to route' }}</button></template>
            <template v-else-if="s.selectedRow.status !== 'complete' && nextStep">
              <div data-broker-scope class="next-step"><span data-broker-scope class="kicker">Next</span><span data-broker-scope class="next-step-text">{{ nextStep.hint }}</span></div>
              <button data-broker-scope class="primary" :disabled="working || nextStep.disabled" @click="nextStep.run()">{{ nextStep.label }}</button>
              <button data-broker-scope v-if="nextStep.key !== 'toPickup'" :disabled="working" @click="s.action('navigate', { id: s.selectedRow.id, leg: 'pickup' })">Navigate to pickup</button>
              <button data-broker-scope v-if="s.selectedRow.atPickup && s.selectedRow.kind !== 'parcel' && !['stage', 'collect', 'load'].includes(nextStep.key)" :disabled="working || s.selectedRow.kind === 'parcel' && !container" @click="collect">{{ s.selectedRow.kind === 'cars' ? 'Stage selected vehicles' : 'Collect load' }}</button>
              <button data-broker-scope v-if="!['toDelivery', 'deliver'].includes(nextStep.key)" :disabled="working" @click="s.action('navigate', { id: s.selectedRow.id, leg: 'delivery' })">Navigate to delivery</button>
              <button data-broker-scope v-if="s.selectedRow.status === 'reserved'" :disabled="working" @click="cancelReservation">Cancel reservation</button>
              <button data-broker-scope @click="s.action('plan', { id: s.selectedRow.id })">{{ s.data.plans[s.selectedRow.id] ? 'Remove from route' : 'Add to route' }}</button>
              <button data-broker-scope v-if="s.selectedRow.status === 'active'" :disabled="working" @click="abandon">{{ confirmingAbandon ? `Confirm abandon, ${money(abandonFine)}` : 'Abandon work' }}</button><small data-broker-scope v-if="confirmingAbandon">Existing delivery fines and reputation rules apply.</small>
            </template>
          </div></section>
</template>

<script setup>
import { vPhoneNumber } from "../../../components/phone/phoneNumber.js"
import { vBngUiNavScroll } from "@/common/directives"
import { vBngTextInput } from "@/common/directives"
import MoneyAmount from '../../../components/MoneyAmount.vue'
import BrokerAccess from './BrokerAccess.vue'
import BrokerPickup from './BrokerPickup.vue'
import BrokerTimeline from './BrokerTimeline.vue'
import { inject } from 'vue'
const { startHere, isLocked, openRequirements, BngIcon, icons, markets, RouteMap, s, route, container, selectedCars, confirmingAbandon, rowImage, routePreview, routeLoading, containerLoading, containerError, working, selectedListRow, money, rate, dist, fact, pct, payOf, detailFacts, statusName, closeDetail, refreshContainers, reserveAmount, reserveGroup, reserveMax, reserveSlots, stepReserve, reserveSelected, showLoader, slotsOf, pickupParcels, parcelBoxes, boxByKey, loadVehicle, boxIndex, boxCap, boxHeld, boxUse, boxLeft, canMove, share, boxLabel, autoSplit, cycleBox, pickupGroups, groupLoad, groupStuck, groupSplits, toggleGroup, stepGroup, loadParcels, loadStep, abandonFine, cancelReservation, abandon, collect, nextStep, toggleCar, isSaved } = inject(Symbol.for('overhaul.phoneBroker'))
</script>
