<!-- Owns the Motorsport phone view. components/motorsport supplies result boards; overhaul_phone_apps_motorsportEvents owns actions. -->
<template>

    <div ref="screenRef" class="rls-house rls-house-phone motorsport" :class="{ expanded }" v-bng-on-ui-nav:tab_l="event => changeTab(-1, event)" v-bng-on-ui-nav:tab_r="event => changeTab(1, event)" v-bng-on-ui-nav:context="toggleExpanded">
      <header class="chrome">
        <h2 v-if="expanded" class="ms-title">Motorsport</h2>
        <nav class="seg bar tabs" role="tablist" aria-label="Motorsport sections">
          <BngBinding class="tab-binding" ui-event="tab_l" controller />
          <HouseButton v-for="item in tabs" :key="item.id" compact role="tab" :data-fk="`tab-${item.id}`" :icon="icons[item.icon]" :aria-selected="tab === item.id" :bng-scoped-nav-autofocus="tab === item.id ? '' : null" :class="{ active: tab === item.id }" :variant="tab === item.id ? 'primary' : 'quiet'" @click="tab = item.id">{{ item.label }}</HouseButton>
          <BngBinding class="tab-binding" ui-event="tab_r" controller />
        </nav>
        <HouseButton data-fk="expand" compact binding="context" @click="toggleExpanded">{{ expanded ? 'Collapse' : 'Expand' }}</HouseButton>
      </header>
      <main class="content scroll" v-bng-ui-nav-scroll.force>
        <div v-if="error && !loadFailed" class="action-error ms-caption ms-tone-blocked" role="alert"><span>{{ error }}</span><HouseButton compact variant="quiet" @click="error = ''">Dismiss</HouseButton></div>
        <HouseLoader v-if="loading" label="Loading events..." />
        <section v-else-if="loadFailed" class="panel empty" role="alert"><BngIcon class="empty-icon ms-bad" :type="icons.caution" /><h3 class="ms-heading">Couldn't load events</h3><p class="ms-caption">The event service did not respond. Try loading it again.</p><HouseButton data-fk="retry" :busy="pendingAction === 'refresh'" :disabled="busy" @click="retryLoad">Retry</HouseButton></section>
        <section v-else-if="!state.careerActive" class="panel empty"><BngIcon class="empty-icon" :type="icons.raceFlag" /><h3 class="ms-heading">Career required</h3><p class="ms-caption">Open a career to race motorsport events.</p></section>
        <section v-else-if="tab === 'guide'" class="panel rules-guide" aria-label="Racing rules">
          <dl>
            <div><dt>Register</dt><dd>Pay per class at the desk. Start Event closes registration.</dd></div>
            <div><dt>Index</dt><dd>The fastest legal time for your class. Faster is a breakout.</dd></div>
            <div><dt>Qualify</dt><dd>{{ event?.eventDefinition?.qualifyingAttempts ?? 3 }} passes per class. Best legal elapsed time sets your seed; the top {{ qualifyingFieldSize || 16 }} advance.</dd></div>
            <div><dt>Reaction</dt><dd>Time from green to launch. It counts toward winning a heat.</dd></div>
            <div><dt>Eliminate</dt><dd>Win to advance. Red lights and fouls lose the pass. Smaller breakout wins if both break out.</dd></div>
            <div><dt>Between passes</dt><dd>Keep registered parts fitted. Follow your paddock call, then the staging route.</dd></div>
            <div><dt>When out</dt><dd>Walk into the stands to watch. Finish Event simulates the remaining heats and closes the event.</dd></div>
          </dl>
        </section>
        <section v-else-if="!event && (tab !== 'event' || !hasCalendar)" class="panel empty">
          <BngIcon class="empty-icon" :type="icons.raceFlag" /><h3 class="ms-heading">{{ tab === 'event' ? 'No offers right now' : 'No event yet' }}</h3><p class="ms-caption">{{ tab === 'event' ? 'A league posts one each career day.' : "Accept today's offer to see standings and brackets here." }}</p>
          <HouseButton v-if="tab !== 'event'" compact :icon="icons.arrowLargeRight" @click="tab = 'event'">Today's offer</HouseButton>
        </section>
        <template v-if="event && !loading && !loadFailed && state.careerActive && tab !== 'guide'">
          <!-- One card per event: the name and venue, the weekend as a four-part bar, the status in its colour, then
               the numbers and one line of buttons. On the board tabs only a status that needs the player is shown. -->
          <section v-if="tab === 'event' || urgentStatus" class="panel event-card" :class="{ 'board-summary': tab !== 'event' }">
            <div v-if="tab === 'event'" class="card-head">
              <div class="card-title"><h3 class="ms-heading">{{ event.name }}</h3><span class="ms-meta">{{ event.stripName }}</span></div>
              <HouseButton v-if="event.phase !== 'complete' && !runtime.playerPass && playerStatus.role === 'entrant'" class="withdraw" data-fk="withdraw" compact variant="text" :busy="busy && pendingAction === 'withdrawEvent'" :disabled="busy || confirmationPending" @click="withdrawEvent">Withdraw</HouseButton>
            </div>
            <ol v-if="tab === 'event'" class="stage-rail" aria-label="Event stages">
              <li v-for="stage in stages" :key="stage.id" :class="[stage.state, stage.state === 'current' ? stageTone : '']" :aria-current="stage.state === 'current' ? 'step' : null"><span class="stage-bar" aria-hidden="true" /><span class="stage-label">{{ stage.label }}</span></li>
            </ol>
            <div v-if="callout && (tab === 'event' || urgentStatus)" class="status ms-wash" :class="`ms-tone-${callout.tone}`" role="status">
              <div class="status-copy">
                <strong class="status-title ms-status">{{ callout.title }}</strong>
                <span v-if="callout.text" class="ms-caption">{{ callout.text }}</span>
                <dl v-if="playerStatus.nextPairing" class="ms-facts status-facts"><div><dt class="ms-label">Next heat</dt><dd>{{ playerStatus.nextPairing.names.join(' vs ') }}</dd></div><div><dt class="ms-label">Your lane</dt><dd class="lane">{{ playerStatus.nextPairing.lane }}</dd></div></dl>
                <dl v-if="callout.countdown != null" class="ms-facts status-facts"><div><dt class="ms-label">{{ callout.id === 'waitForSession' ? 'Opens in' : 'Next pass in' }}</dt><dd class="ms-time countdown-value">{{ duration(callout.countdown) }}</dd></div></dl>
                <dl v-if="playerStatus.outcome?.bestTime && (!help.entries || playerStatus.outcome.cutTime)" class="ms-facts status-facts"><div v-if="!help.entries"><dt class="ms-label">Best</dt><dd class="ms-time">{{ playerStatus.outcome.bestTime.toFixed(3) }} s</dd></div><div v-if="playerStatus.outcome.cutTime"><dt class="ms-label">Bracket cut</dt><dd class="ms-time">{{ playerStatus.outcome.cutTime.toFixed(3) }} s</dd></div></dl>
              </div>
              <HouseButton v-if="tab === 'event' && playerStatus.role === 'entrant' && state.skipToGroup?.available" class="status-action" data-fk="skip-group" compact variant="primary" :icon="icons.fastTravel" :busy="busy && pendingAction === 'skipToMyGroup'" :disabled="busy || confirmationPending" @click="skipToMyGroup">Skip to my group</HouseButton>
              <MotorsportPartChanges v-if="callout.id === 'hold'" class="status-action" :changes="state.startBlocked?.partChanges || []" :car-name="session.currentVehicleName" />
            </div>
            <dl v-if="tab === 'event' && facts.length && event.phase !== 'complete'" class="ms-facts ms-num"><div v-for="fact in facts" :key="fact.label"><dt class="ms-label">{{ fact.label }}</dt><dd>{{ fact.value }}</dd></div></dl>
            <div v-if="liveVisible && qualifyingPhase && currentPlayerEntry" class="best">
              <div v-if="cutGauge" class="cut-gauge" :class="cutGauge.inside ? 'inside' : 'outside'" role="img" :aria-label="`Your best ${qualifyingTime(currentPlayerEntry)}, bracket cut ${cutGauge.cutLabel}`">
                <div class="cut-gauge-head"><span class="ms-label">Your best</span><strong class="ms-time">{{ qualifyingTime(currentPlayerEntry) }}</strong><span class="cut-gauge-margin"><b class="ms-time">{{ cutGauge.marginTime }}</b> {{ cutGauge.inside ? 'inside the cut' : 'outside the cut' }}</span></div>
                <div class="cut-gauge-track"><span class="cut-gauge-safe" :style="{ width: cutGauge.cutPercent + '%' }" /><span class="cut-gauge-cut" :style="{ left: cutGauge.cutPercent + '%' }" /><span v-if="cutGauge.indexPercent != null" class="cut-gauge-index" :style="{ left: cutGauge.indexPercent + '%' }" /><span class="cut-gauge-you" :style="{ left: cutGauge.bestPercent + '%' }" /></div>
                <div class="cut-gauge-scale ms-num"><span v-if="cutGauge.indexPercent != null" :style="{ left: cutGauge.indexPercent + '%' }">Index <b class="ms-time">{{ cutGauge.indexLabel }}</b></span><span class="cut" :style="{ left: cutGauge.cutPercent + '%' }">Cut <b class="ms-time">{{ cutGauge.cutLabel }}</b></span></div>
              </div>
              <dl class="ms-facts ms-num"><div v-if="!cutGauge && currentPlayerEntry.qualifying?.valid"><dt class="ms-label">Your best</dt><dd class="ms-time">{{ qualifyingTime(currentPlayerEntry) }}</dd></div><div><dt class="ms-label">Passes</dt><dd>{{ attemptCount(currentPlayerEntry).replace(' passes', '') }}</dd></div><div v-if="latestOutcome(currentPlayerEntry, true)"><dt class="ms-label">Last pass</dt><dd :class="resultTone(latestAttempt(currentPlayerEntry)) === 'bad' ? 'ms-bad' : 'ms-ok'">{{ latestOutcome(currentPlayerEntry, true) }}</dd></div></dl>
            </div>
            <p v-if="livePairing" class="ms-body live">{{ livePairing }}</p>
            <div v-if="tab === 'event' && registrations.length > 1 && !help.entries && progressRows.length && event.phase !== 'complete'" class="sheet lines">
              <div v-for="row in progressRows" :key="row.key" class="line"><span class="ms-caption">{{ row.label }}</span><span v-if="row.tone" class="pill" :class="`ms-tone-${row.tone}`">{{ row.progress }}</span><strong v-else class="ms-meta">{{ row.progress }}</strong></div>
            </div>
            <!-- Results sit in the event card: placing first, payout in gold, the class winner named. -->
            <div v-if="tab === 'event' && event.phase === 'complete' && (!withdrawn || resultsEarned)" class="results" aria-label="Results">
              <div v-for="session in completedClasses" :key="session.id || session.classId" class="result" :class="{ won: resultPlace(session) === 1 }">
                <span class="ms-place" :class="`place-${resultPlace(session) || (resultEntryOutcome(session)?.role === 'out' ? 'out' : 'unknown')}`">{{ resultPlace(session) ? ordinal(resultPlace(session)) : resultEntryOutcome(session)?.role === 'out' ? 'Out' : '—' }}</span>
                <div class="result-copy"><strong class="ms-body">{{ session.name }}</strong><span v-if="resultEntryOutcome(session)?.bestTime" class="ms-meta">Best <b class="ms-time">{{ resultEntryOutcome(session).bestTime.toFixed(3) }} s</b></span><span v-if="resultEntryDetail(session)" class="ms-meta">{{ resultEntryDetail(session) }}</span><span v-if="resultPlace(session) !== 1" class="ms-meta">Class winner: {{ entrantName(session.winnerId || session.bracket?.winnerId, session) }}</span></div>
                <strong class="result-payout ms-num" :class="moneyTone(session.reward)">{{ money(session.reward) }}</strong>
              </div>
              <div v-if="completedClasses.length !== 1" class="result-total"><span class="ms-label">Total payout</span><strong class="ms-num" :class="moneyTone(event.reward)">{{ money(event.reward) }}</strong></div>
            </div>
            <p v-if="tab === 'event' && freshMessage" class="ms-meta note"><BngIcon class="ms-icon" :type="icons.info" />{{ freshMessage }}</p>
            <div v-if="tab === 'event'" class="actions ms-foot">
              <HouseButton v-if="checkInVisible && !checkIn.atCheckIn" data-fk="route-check-in" compact variant="primary" :icon="icons.routeSimple" :busy="busy && pendingAction === 'routeRegistration'" :disabled="busy || confirmationPending" @click="routeRegistration">Show route</HouseButton>
              <HouseButton v-if="event.phase === 'registration' && !registration.atRegistration" data-fk="route-registration" compact :variant="registrations.length ? 'neutral' : 'primary'" :icon="icons.routeSimple" :busy="busy && pendingAction === 'routeRegistration'" :disabled="busy || confirmationPending" @click="routeRegistration">Show route</HouseButton>
              <HouseButton v-if="event.phase === 'registration' && registrations.length" data-fk="start-event" compact variant="primary" :icon="icons.raceFlag" :disabled="busy || confirmationPending" :busy="busy && pendingAction === 'startRegisteredEvent'" @click="startEvent">Start Event</HouseButton>
              <HouseButton v-if="!callout && state.skipToGroup?.available" data-fk="skip-group" compact variant="primary" :icon="icons.fastTravel" :busy="busy && pendingAction === 'skipToMyGroup'" :disabled="busy || confirmationPending" @click="skipToMyGroup">Skip to my group</HouseButton>
              <HouseButton v-if="!session.spectatorOnly && !state.skipToGroup?.available && session.waiting && session.canAdvanceDay" data-fk="advance-day" compact variant="primary" :icon="icons.fastTravel" :busy="busy && pendingAction === 'advanceDay'" :disabled="busy || confirmationPending" @click="advanceDay">{{ advanceDayLabel }}</HouseButton>
              <HouseButton v-if="stagingAvailable" data-fk="staging" compact variant="primary" :icon="icons.routeSimpleFlag" :busy="busy && pendingAction === 'drive'" :disabled="busy || confirmationPending" @click="drive">Go to staging</HouseButton>
              <HouseButton v-if="state.watching" data-fk="leave-spectator" compact :icon="icons.exit" :busy="busy && pendingAction === 'stopWatching'" :disabled="busy || confirmationPending" @click="leaveSpectatorMode">Stop watching</HouseButton>
              <HouseButton v-if="state.canFinishWeekend" data-fk="finish-weekend" compact :icon="icons.checkmark" :busy="busy && pendingAction === 'finishSpectatorWeekend'" :disabled="busy || confirmationPending" @click="finishWeekend">Finish Event</HouseButton>
              <HouseButton v-if="stagingAvailable" data-fk="cancel-pass" compact variant="quiet-danger" :icon="icons.xmark" :busy="busy && pendingAction === 'cancelPass'" :disabled="busy || confirmationPending" @click="act('cancelPass')">Cancel pass</HouseButton>
            </div>
          </section>
          <MotorsportFold v-if="tab === 'event' && registrations.length" id="motorsport-entries" icon="car" title="Your entries" :meta="entriesMeta" :model-value="!!help.entries" @update:model-value="value => help.entries = value">
            <div class="sheet lines">
              <template v-for="entry in registrations" :key="entry.registrationId || entry.id || entry.inventoryId">
                <div class="line entry"><span class="ms-caption"><strong class="ms-body">{{ entry.vehicleName || entry.model }}</strong><small class="ms-meta">{{ entry.declaredClassName || entry.className || className(entry.declaredClassId || entry.classId) || 'No class' }} <template v-if="Number.isFinite(entry.indexSeconds)">(<b class="ms-time">{{ entry.indexSeconds.toFixed(2) }} s</b> index)</template><template v-else>(No index)</template></small><small v-if="entry.qualifying?.valid" class="ms-meta">Best <span class="ms-time">{{ qualifyingTime(entry) }}</span></small><small v-if="entry.reason || entry.error || entry.classError" class="ms-meta ms-bad">{{ entry.reason || entry.error || entry.classError }}</small></span><span class="pill" :class="`ms-tone-${entryStatus(entry).tone}`">{{ entryStatus(entry).label }}</span></div>
              </template>
            </div>
          </MotorsportFold>
          <MotorsportFold v-if="tab === 'event' && event.prizes?.version === 2" id="motorsport-help-prizes" icon="star" title="Prizes" :model-value="!!help.prizes" @update:model-value="value => help.prizes = value">
            <template #meta>1st <span class="ms-money">{{ money(event.prizes.winner) }}</span></template>
            <dl class="prizes prize-ladder">
              <div v-for="row in prizeRows(event.prizes, false)" :key="row.label" class="prize"><dt class="ms-caption">{{ row.label }}</dt><span class="ms-bar" aria-hidden="true"><span :style="{ transform: `scaleX(${prizeShare(row.value, event.prizes)})` }" /></span><dd class="ms-caption ms-num" :class="moneyTone(row.value)">{{ money(row.value) }}</dd></div>
            </dl>
            <p class="prize-note ms-meta">Per class. 3rd is raced off; other ties go to round, then time.</p>
          </MotorsportFold>
          <template v-if="tab === 'qualifying'">
            <MotorsportFold v-for="group in resultClasses" :id="`motorsport-qualifying-${group.key}`" :key="group.key" icon="timer" :title="group.name" :meta="group.standings.length ? `${group.standings.filter(e => e.qualifying?.valid).length} of ${group.standings.length} legal` : 'No times yet'" :model-value="!!qualifyingOpen[group.key]" @update:model-value="value => qualifyingOpen[group.key] = value">
              <p v-if="!group.standings.length" class="ms-caption">Times appear as passes finish.</p>
              <MotorsportQualifyingBoard v-else :key="expanded" :entrants="group.standings" :bracket="group.bracket" :compact="!expanded" :field-size="qualifyingFieldSize" :index-seconds="group.indexSeconds ?? asArray(group.entrants).find(entry => Number.isFinite(entry.indexSeconds))?.indexSeconds ?? registrations.find(entry => entry.declaredClassId === (group.id || group.classId))?.indexSeconds" :player-status="state.playerStatus" :class-id="group.id || group.classId" />

            </MotorsportFold>
            <div v-if="state.watching" class="actions"><HouseButton data-fk="leave-spectator" compact :icon="icons.exit" :aria-busy="busy || confirmationPending" @click="leaveSpectatorMode">Stop watching</HouseButton></div>
          </template>
          <template v-if="tab === 'bracket'">
            <MotorsportFold v-for="group in resultClasses" :id="`motorsport-bracket-${group.key}`" :key="group.key" icon="listIndented" :title="group.name" :meta="group.bracket?.complete ? 'Complete' : asArray(group.bracket?.rounds?.[0]?.matches).length ? (round => roundLabel({ ...round, championship: false, fullMatchCount: asArray(round.matches).filter(match => match.kind !== 'thirdPlace').length }))(asArray(group.bracket.rounds).find(r => r.number === group.bracket.currentRound) || { number: group.bracket.currentRound || 1 }) : 'After qualifying'" :model-value="!!bracketOpen[group.key]" @update:model-value="value => bracketOpen[group.key] = value">
              <p v-if="!group.bracket" class="ms-caption">Seeded when this class finishes qualifying.</p>
              <MotorsportBracket v-else :key="expanded" :compact="!expanded" :bracket="group.bracket" :entrants="asArray(group.entrants)" :racing-ids="runtime.phase === 'racing' ? asArray(runtime.racers).map(racer => racer.entrantId) : []" :player-status="state.playerStatus" :class-id="group.id || group.classId" />

            </MotorsportFold>
            <div v-if="state.watching" class="actions"><HouseButton data-fk="leave-spectator" compact :icon="icons.exit" :aria-busy="busy || confirmationPending" @click="leaveSpectatorMode">Stop watching</HouseButton></div>
          </template>
        </template>
        <!-- Daily offer board; after a finished event it follows the results. -->
        <section v-if="!loading && !loadFailed && state.careerActive && tab === 'event' && hasCalendar && (!event || event.phase === 'complete')" class="panel offer" :class="{ 'offer-following': event }">
          <div v-if="!calendar.ready" class="offer-empty">
            <template v-if="calendar.message"><BngIcon class="head-icon ms-bad" :type="icons.caution" /><h3 class="ms-heading">{{ calendar.message }}</h3><HouseButton data-fk="retry-calendar" :busy="pendingAction === 'refresh'" :disabled="busy" @click="retryLoad">Retry</HouseButton></template>
            <HouseLoader v-else label="Loading the calendar..." />
          </div>
          <template v-else-if="offer">
            <div class="card-head offer-head">
              <div class="card-title"><h3 class="ms-title">{{ offer.leagueName || leagueName(offer.leagueId) }}</h3><span class="ms-caption offer-venue">{{ offer.venueName || 'Venue not on this map' }}</span></div>
              <dl class="purse">
                <div v-if="offer.prizes"><dt class="ms-label">1st in class</dt><dd class="purse-win ms-money ms-num">{{ money(offer.prizes.winner) }}</dd></div>
                <div><dt class="ms-label">Entry per class</dt><dd class="ms-num" :class="moneyTone(offer.fee)">{{ money(offer.fee) }}</dd></div>
              </dl>
            </div>
            <!-- The weekend, one labelled value per day. -->
            <dl class="ms-facts ruled offer-days" aria-label="Schedule">
              <div v-for="(row, index) in offerItinerary" :key="row.day"><dt class="ms-label">{{ index === 0 ? offerStartLabel : `Day ${row.day}` }}</dt><dd class="ms-num">{{ row.text }}</dd></div>
            </dl>
            <div class="offer-body">
              <section v-if="offer.prizes" class="offer-section" aria-label="Prizes">
                <dl class="prizes prize-ladder">
                  <div v-for="row in prizeRows(offer.prizes, true)" :key="row.label" class="prize"><dt class="ms-caption">{{ row.label }}</dt><span class="ms-bar" aria-hidden="true"><span :style="{ transform: `scaleX(${prizeShare(row.value, offer.prizes)})` }" /></span><dd class="ms-caption ms-num" :class="moneyTone(row.value)">{{ money(row.value) }}</dd></div>
                </dl>
              </section>
              <section v-if="asArray(offer.classes).length" class="offer-section" aria-label="Classes">
                <div class="sheet lines offer-classes">
                  <MotorsportClassDetails v-for="choice in asArray(offer.classes)" :key="choice.id" :choice="choice" context="offer" />
                </div>
              </section>
            </div>
            <p v-if="offerUnavailableReason" class="status-line ms-caption ms-bad" role="alert"><BngIcon class="ms-icon" :type="icons.caution" />{{ offerUnavailableReason }}</p>
            <dl v-if="calendar.clockFrozen" class="ms-facts offer-expiry"><div><dt class="ms-label">Offer expires in</dt><dd class="ms-time">{{ duration(calendar.expiresInSeconds) }}</dd></div><div><dt class="ms-label">If you decline</dt><dd><b class="ms-time">30 min</b> wait</dd></div></dl>
            <div class="actions offer-actions ms-foot">
              <HouseButton data-fk="accept-offer" variant="primary" :icon="icons.checkmark" :busy="busy && pendingAction === 'acceptOffer'" :disabled="busy || confirmationPending || !!offerUnavailableReason" @click="acceptOffer">Accept</HouseButton>
              <HouseButton data-fk="decline-offer" variant="quiet-danger" :busy="busy && pendingAction === 'declineOffer'" :disabled="busy || confirmationPending" @click="declineOffer">Decline</HouseButton>
              <HouseButton v-if="calendar.canAdvanceOffer" data-fk="next-offer" compact variant="quiet" :busy="busy && pendingAction === 'advanceOffer'" :disabled="busy || confirmationPending" @click="advanceOffer">Skip to next day</HouseButton>
            </div>
          </template>
          <div v-else class="offer-empty ms-tone-wait">
            <BngIcon class="head-icon" :type="icons.timeUnlockOutline" />
            <div class="card-title"><span v-if="calendar.clockFrozen && calendar.cooldown" class="offer-arrival" role="status"><span class="ms-caption">Next offer in</span><strong class="countdown ms-time">{{ countdown(calendar.remainingSeconds) }}</strong><span class="ms-meta">Real time</span></span><span v-else class="ms-heading" role="status">{{ calendar.message || 'No event today.' }}</span></div>
            <HouseButton v-if="calendar.canAdvanceOffer" data-fk="next-offer" compact variant="quiet" :icon="icons.fastTravel" :busy="busy && pendingAction === 'advanceOffer'" :disabled="busy || confirmationPending" @click="advanceOffer">Skip to next day</HouseButton>
          </div>
        </section>
        <MotorsportFold v-if="!loading && !loadFailed && state.careerActive && tab === 'event' && state.devTools" id="motorsport-dev-tools" icon="wrench" title="Developer tools" meta="Testing" :model-value="!!help.dev" @update:model-value="value => help.dev = value">
          <p class="ms-meta">Skips the daily offer and opens registration at a drag venue on this map.</p>
          <div class="sheet lines"><div class="line"><span class="ms-caption">Venues</span><strong class="ms-caption">{{ availableVenues.map(v => v.name).join(', ') || 'None on this map' }}</strong></div></div>
          <div class="actions">
            <HouseButton data-fk="dev-start" compact variant="primary" :busy="busy && pendingAction === 'devStartEvent'" :disabled="(!availableVenues.length || (event && event.phase !== 'complete')) || (busy || confirmationPending)" @click="act('devStartEvent')">Start event</HouseButton>
            <HouseButton v-if="event" data-fk="dev-cancel" compact variant="quiet-danger" :busy="busy && pendingAction === 'devCancelEvent'" :disabled="busy || confirmationPending" @click="cancelEvent">Cancel event</HouseButton>
            <HouseButton v-if="event?.phase === 'qualifying'" data-fk="dev-qualifying" compact :busy="busy && pendingAction === 'devSimulateQualifying'" :disabled="(session.waiting || runtime.phase !== 'idle') || (busy || confirmationPending)" @click="act('devSimulateQualifying')">Sim qualifying</HouseButton>
            <HouseButton v-if="canSimulateNpcRaces" data-fk="dev-races" compact :busy="busy && pendingAction === 'devSimulateRaces'" :disabled="(session.waiting || runtime.phase !== 'idle') || (busy || confirmationPending)" @click="act('devSimulateRaces')">Sim NPC races</HouseButton>
          </div>
          <p v-if="event && event.phase !== 'complete'" class="ms-meta">Estimated times. Your own passes stay live<template v-if="event.roundRotation === true">, and so do elimination and final heats</template>.</p>
        </MotorsportFold>
      </main>
    </div>

</template>

<script setup>
import MotorsportClassDetails from '../../components/motorsport/MotorsportClassDetails.vue'
import { computed, ref, watch, nextTick, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngBinding, BngIcon, icons } from '@/common/components/base'
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import useControls from '@/services/controls'
import { setFocus } from '@/services/uiNavFocus'
import { HouseButton, HouseLoader, openHouseConfirmation } from '../../components/house/index.js'
import MotorsportPartChanges from '../../components/motorsport/MotorsportPartChanges.vue'
import { acquireScope, releaseScope } from '../../utils/luaScopes'
import { usePhoneScreen } from '../../composables/usePhoneScreen.js'
import { useActionFocus } from '../../composables/useActionFocus.js'
import { usePhoneAppFocus } from './controllerLayers.js'
import { nextTab } from '../../utils/controllerTabs.js'
import MotorsportQualifyingBoard from '../../components/motorsport/MotorsportQualifyingBoard.vue'
import MotorsportBracket from '../../components/motorsport/MotorsportBracket.vue'
import MotorsportFold from '../../components/motorsport/MotorsportFold.vue'
import { labels, count, duration, money, moneyTone, actionError, dragResultReason } from '../../utils/motorsportLabels.js'
import { confirmFinishEvent, confirmStartEvent, confirmationRows } from '../../utils/motorsportConfirmations.js'

const events = useEvents(), screenRef = ref(null), expanded = ref(false), tab = ref('event'), state = ref({}), loading = ref(true), error = ref(''), loadFailed = ref(false)
const { busy, run, remember, restore } = useActionFocus(screenRef)
const tabs = [{ id: 'event', label: 'Event', icon: 'raceFlag' }, { id: 'qualifying', label: 'Qualify', icon: 'timer' }, { id: 'bracket', label: 'Bracket', icon: 'listIndented' }, { id: 'guide', label: 'Rules', icon: 'info' }]
// The island fits about 14 characters; the store and home screen keep the full 'Motorsport Events'.
// Expand grows into the big phone board, like Job Broker; the frame and status bar stay.
usePhoneScreen({ appName: 'Motorsport Events', title: 'Motorsport', expanded, onBack: () => {
  if (!expanded.value) return false
  expanded.value = false
  return true
} })
usePhoneAppFocus()
const selectedTabControl = () => screenRef.value?.querySelector(`[data-fk="tab-${tab.value}"]`)
watch(expanded, async () => {
  await nextTick()
  const target = selectedTabControl()
  if (target && useControls().isControllerUsed) setFocus(target, true, true, true)
})
function toggleExpanded(event) {
  event?.stopPropagation()
  expanded.value = !expanded.value
}
async function changeTab(direction, event) {
  event?.stopPropagation()
  const next = nextTab(tabs, tab.value, direction)
  if (next) tab.value = next.id
  await nextTick()
  const target = selectedTabControl()
  if (target) setFocus(target, true, true, true)
}
const confirmationPending = ref(false), pendingAction = ref('')
// Open/closed state of the optional help disclosures; rules stay one tap away instead of filling the screen.
const help = ref({})
const qualifyingOpen = ref({})
const bracketOpen = ref({})
const qualifyingFieldSize = computed(() => event.value ? event.value.eventDefinition?.qualifyingFieldSize ?? 16 : null)
const event = computed(() => state.value.event), runtime = computed(() => state.value.runtime || {phase: 'idle'})
const session = computed(() => state.value.session || {})
const calendar = computed(() => state.value.calendar || {})
const hasCalendar = computed(() => !!state.value.calendar)
const offer = computed(() => calendar.value.ready ? calendar.value.offer : null)
// With a frozen clock qualifying opens after registration, so the first stop has no clock time.
const offerItinerary = computed(() => offer.value ? itinerary(offer.value.stages, offer.value.totalDays, calendar.value.clockFrozen ? '' : clockLabel(offer.value.startWorldMinute) || clockLabel(stageMap(offer.value.stages).qualifying?.minuteOfDay) || '10:00') : [])
const offerStartLabel = computed(() => calendar.value.clockFrozen ? 'After registration' : Number.isFinite(offer.value?.startWorldMinute) ? relativeDayLabel(offer.value.startWorldMinute, offer.value.dayIndex) : 'Day 1')
const advanceDayLabel = computed(() => session.value.advanceLabel || (session.value.nextDay ? `Skip to Day ${session.value.nextDay}` : 'Skip ahead'))
const calendarWarning = 'Career time moves forward, so loans and payments do too.'
const canSimulateNpcRaces = computed(() => event.value?.phase === 'eliminations' && event.value.roundRotation !== true)
const waitingPanelVisible = computed(() => tab.value === 'event' && !!session.value.waiting && event.value?.phase !== 'registration')
const entryLabel = (vehicle, className) => vehicle && className ? `${vehicle} (${className})` : vehicle || className || ''
const paddock = computed(() => state.value.paddock || {})
const asArray = value => Array.isArray(value) ? value : []
const availableVenues = computed(() => asArray(state.value.availableVenues))
const activeEntrants = computed(() => asArray(event.value?.entrants))
const registration = computed(() => state.value.registration || {})
const checkIn = computed(() => state.value.checkIn || {})
const pendingInspection = computed(() => session.value.checkInRequired || asArray(checkIn.value.entries).some(entry => !entry.inspected))
const checkInVisible = computed(() => event.value?.checkInVersion === 1 && !['registration', 'complete'].includes(event.value.phase) && (session.value.inspectionAvailable ?? !session.value.waiting) && !session.value.spectatorOnly && playerStatus.value.role === 'entrant' && pendingInspection.value)
const progressRows = computed(() => registrations.value.map(entry => ({ key: entry.registrationId || entry.id || entry.inventoryId, label: entryLabel(entry.vehicleName || entry.model, entry.declaredClassName || entry.className), progress: entryProgress(entry), tone: entryStatus(entry).tone })).filter(row => row.progress))
const leagues = computed(() => asArray(registration.value.leagues))
const registrations = computed(() => asArray(event.value?.registrations ?? registration.value.registrations))
const activeResultsClassId = computed(() => event.value?.activeClassId || registrations.value.find(row => row.registrationId === event.value?.activeRegistrationId)?.declaredClassId || '')
const classes = computed(() => {
  const stored = asArray(state.value.classes ?? event.value?.classes)
  const views = stored.map(c => (c.id || c.classId) === activeResultsClassId.value && activeEntrants.value.length
    ? { ...c, entrants: activeEntrants.value, bracket: event.value?.bracket || c.bracket } : c)
  const seen = new Set(views.map(c => c.id || c.classId))
  for (const row of registrations.value) {
    const id = row.classId || row.declaredClassId
    if (!id || row.excluded || seen.has(id)) continue
    seen.add(id)
    const player = { ...row, player: true, name: row.name || 'You' }
    views.push({ id, classId: id, name: row.className || row.declaredClassName || id, leagueId: row.leagueId,
      phase: 'qualifying', entrants: id === activeResultsClassId.value && activeEntrants.value.length ? activeEntrants.value : [...asArray(row.qualifyingOpponents), player] })
  }
  return views
})
const playerEntrant = computed(() => activeEntrants.value.find(e => e.player))
const currentPlayerEntry = computed(() => registrations.value.find(e => event.value?.activeRegistrationId && e.registrationId === event.value.activeRegistrationId) || registrations.value.find(e => playerEntrant.value && e.inventoryId === playerEntrant.value.inventoryId && e.leagueId === playerEntrant.value.leagueId && e.declaredClassId === playerEntrant.value.declaredClassId) || playerEntrant.value)
const resultClasses = computed(() => (classes.value.length ? classes.value : [{
  ...event.value, name: event.value?.className || 'Event class', standings: state.value.standings, entrants: event.value?.entrants,
}]).map(group => ({
  ...group,
  key: `${group.leagueId || 'event'}-${group.id || group.classId || 'current'}`,
  name: group.name || group.className || className(group.classId || group.id) || 'Event class',
  // Lua publishes both pending registration fields and stored class sessions.
  standings: asArray(state.value.classStandings?.[group.id || group.classId] ?? group.standings),
})))
function countdown(value) { const seconds = Math.max(0, Math.ceil(Number(value) || 0)); return duration(seconds) }
const qualifyingPhase = computed(() => ['playerQualifying', 'qualifying'].includes(event.value?.phase))
const qualifyingProgress = computed(() => {
  const round = state.value.qualifyingRound
  return !session.value.waiting && qualifyingPhase.value && round?.maxRounds > 0 ? count(round.number, round.maxRounds, 'Round') : ''
})
const withdrawn = computed(() => event.value?.withdrawn === true)
// A withdrawal keeps any payout already earned; only then is there a result to show.
const resultsEarned = computed(() => Number(event.value?.reward || 0) > 0 || classes.value.some(c => c.playerPlace))
const racingFinished = computed(() => playerStatus.value.role === 'out' && playerStatus.value.outcome?.id === 'placed')
// The open stage of the weekend bar takes the status colour.
const stageTone = computed(() => `ms-tone-${playerStatus.value.step?.tone || 'wait'}`)
const passActive = computed(() => playerStatus.value.role === 'entrant' && !waitingPanelVisible.value && event.value?.phase !== 'registration' && !session.value.checkInRequired)
const liveVisible = computed(() => tab.value === 'event' && passActive.value && (qualifyingPhase.value && !!currentPlayerEntry.value || runtime.value.playerPass && runtime.value.phase !== 'idle'))
const livePairing = computed(() => liveVisible.value && runtime.value.phase !== 'idle' ? asArray(runtime.value.racers).map(racer => entrantName(racer.entrantId)).join(' vs ') : '')
const entriesMeta = computed(() => { const cars = new Set(registrations.value.map(row => row.inventoryId)).size; return `${registrations.value.length} ${registrations.value.length === 1 ? 'entry' : 'entries'}, ${cars} ${cars === 1 ? 'car' : 'cars'}` })
const playerStatus = computed(() => state.value.playerStatus || { role: 'entrant', entries: [] })
const callout = computed(() => playerStatus.value.step || null)
const stagingAvailable = computed(() => passActive.value && runtime.value.playerPass && ['stageRoute', 'stage'].includes(callout.value?.id))
// A status that needs the player (their move, or something to fix) also shows above the standings and the bracket.
const urgentStatus = computed(() => !!callout.value && ['act', 'blocked'].includes(callout.value.tone))
// Backend status text, unless the callout already says it.
const freshMessage = computed(() => {
  const text = state.value.message
  if (playerStatus.value.role !== 'entrant' || !text || text === state.value.startBlockedReason || event.value?.phase === 'registration') return ''
  if (callout.value && [callout.value.title, callout.value.text].some(part => part && (part.includes(text) || text.includes(part)))) return ''
  // A live pairing supersedes its announcement; preserve messages with any additional information.
  if (livePairing.value && (text === livePairing.value || text === `Qualifying: ${livePairing.value}` || text === 'Next elimination heat ready.')) return ''
  // A wait status already says to wait; a backend line that only says "Waiting ..." adds nothing under it.
  return callout.value?.tone === 'wait' && /^waiting\b/i.test(text) ? '' : text
})
// Class requirement text arrives dot-separated from settings; show it as a plain list.
const ordinal = n => { const v = Number(n); const s = ['th', 'st', 'nd', 'rd'][(v % 100 - 20) % 10] || ['th', 'st', 'nd', 'rd'][v % 100] || 'th'; return `${v}${s}` }
// The places below first; first prize has its own line above every ladder.
const prizeRows = (prizes, withParticipation) => [['2nd', prizes.runnerUp], ['3rd', prizes.third], ['4th–10th', prizes.topTen], ...(withParticipation ? [['11th and below', prizes.participation]] : [])].map(([label, value]) => ({ label, value }))
// One status block per card: what is happening now and what to do next.
function clockLabel(minute) {
  if (!Number.isFinite(minute)) return ''
  const m = ((Math.floor(minute) % 1440) + 1440) % 1440
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
}
function relativeDayLabel(minute, todayIndex) {
  const days = Number.isFinite(todayIndex) ? Math.floor(minute / 1440) - todayIndex : 0
  return days <= 0 ? 'Today' : days === 1 ? 'Tomorrow' : `In ${days} days`
}
function worldTimeLabel(minute, todayIndex) {
  return Number.isFinite(minute) ? `${relativeDayLabel(minute, todayIndex)} at ${clockLabel(minute)}` : 'Not scheduled'
}
// Backend stages arrive as {qualifying: {day, minuteOfDay}, ...} or as [{id, day, minuteOfDay}, ...].
function stageMap(stages) { return Array.isArray(stages) ? Object.fromEntries(stages.filter(s => s?.id || s?.stage).map(s => [s.id || s.stage, s])) : stages && typeof stages === 'object' ? stages : {} }
// Weekend days from the event's stages. Without stages, totalDays still places the finals on the last day (legacy 3-day weekends).
function itinerary(stages, totalDays, qualifyingStart) {
  const map = stageMap(stages), total = Math.max(1, Math.floor(Number(totalDays) || 2))
  const fallback = { qualifying: 1, eliminations: Math.min(2, total), finals: total }, names = { qualifying: 'Qualifying', eliminations: 'Eliminations', finals: 'final' }
  const rows = []
  for (const id of ['qualifying', 'eliminations', 'finals']) {
    const day = Math.floor(Number(map[id]?.day)) || fallback[id]
    let row = rows.find(r => r.day === day)
    if (!row) rows.push(row = { day, stages: [], text: '' })
    row.stages.push(id)
    row.text = row.text ? `${row.text}, then ${names[id].toLowerCase()}` : id === 'qualifying' && qualifyingStart ? `Qualifying from ${qualifyingStart}` : names[id][0].toUpperCase() + names[id].slice(1)
  }
  return rows.sort((a, b) => a.day - b.day)
}
function laterStagesText(rows) {
  const day = id => rows.find(r => r.stages.includes(id))?.day
  return day('eliminations') === day('finals') ? `eliminations and the final run on Day ${day('finals')}` : `eliminations run on Day ${day('eliminations')} and the final on Day ${day('finals')}`
}
function entryOutcome(entry) {
  const classId = entry.declaredClassId || entry.classId
  return asArray(playerStatus.value.entries).find(row => (!classId || row.classId === classId)
    && (row.id === (entry.registrationId || entry.id) || row.entrantId === entry.id))
}
function entryProgress(entry) {
  if (entry.excluded) return labels.excluded
  const outcome = entryOutcome(entry)
  if (outcome?.idOutcome) return outcome.label || labels[outcome.idOutcome] || 'Racing finished'
  return state.value.playerProgress?.[entry.registrationId || `${entry.id || `player-${entry.inventoryId}`}:${entry.leagueId}`]
}
function leagueName(id) { return leagues.value.find(l => l.id === id)?.name || ({pro: 'Pro', ss: 'Super Street', street: 'Street'})[id] || id }
function className(id) { return classes.value.find(c => (c.id || c.classId) === id)?.name || '' }
function entryStatus(entry) {
  if (entry.excluded) return { label: labels.excluded, tone: 'blocked' }
  const status = entryOutcome(entry)
  if (status?.idOutcome === 'placed') return { label: status.label || 'Racing finished', tone: 'done' }
  if (status?.idOutcome === 'excluded') return { label: labels.excluded, tone: 'blocked' }
  if (status?.idOutcome === 'eliminated') return { label: labels.eliminated, tone: 'blocked' }
  if (status?.idOutcome === 'didNotQualify') return { label: labels.didNotQualify, tone: 'blocked' }
  if (entryProgress(entry) === labels.didNotQualify) return { label: labels.didNotQualify, tone: 'blocked' }
  if (entry.qualifierDone && !entry.qualifying?.valid) return { label: labels.didNotQualify, tone: 'blocked' }
  if (entry.qualifierDone) {
    const competition = classes.value.find(c => (c.id || c.classId) === (entry.classId || entry.declaredClassId))
    if (competition?.bracket) {
      const entered = asArray(competition.bracket.rounds?.[0]?.matches).some(m => m.a === entry.id || m.b === entry.id)
      return { label: entered ? 'Qualified' : labels.didNotQualify, tone: entered ? 'done' : 'blocked' }
    }
    return { label: 'Qualified', tone: 'done' }
  }
  return { label: 'Entered', tone: '' }
}
function entrantName(id, session = event.value) { return asArray(session?.entrants).find(e => e.id === id)?.name || registrations.value.find(e => e.id === id)?.name || 'Not decided' }
function qualifyingTime(e) { const q = e?.qualifying; return q?.valid && Number.isFinite(q.time) ? `${q.time.toFixed(3)} s` : e?.qualifierDone ? 'DNQ' : '—' }
function attemptCount(entry) { return `${count(asArray(entry?.qualifyingAttempts).length, entry?.qualifyingLimit || event.value?.eventDefinition?.qualifyingAttempts || 3)} passes` }
function latestAttempt(entry) { return asArray(entry?.qualifyingAttempts).at(-1) }
function latestOutcome(entry) { const pass = latestAttempt(entry); return pass ? pass.valid ? pass.qualifyingRedLight ? 'Legal ET; red light' : 'Legal' : dragResultReason(pass.reason) || 'Invalid pass' : '' }
function resultTone(result) {
  if (result?.valid === false || result?.qualifyingRedLight) return 'bad'
  return result?.valid === true ? 'ok' : ''
}
function roundLabel(round) { if (round.championship) return labels.final; const count = round.fullMatchCount || asArray(round.matches).length; return count === 1 ? 'Final' : count === 2 ? 'Semifinals' : count === 4 ? 'Quarterfinals' : count === 8 ? 'Round of 16' : `Round ${round.number}` }
const completedClasses = computed(() => classes.value.filter(row => row.playerPlace || row.winnerId || row.bracket?.winnerId || !withdrawn.value && row.placings))
function resultEntryOutcome(group) { return asArray(playerStatus.value.entries).find(row => row.classId === (group.id || group.classId)) }
function resultPlace(group) {
  const outcome = resultEntryOutcome(group)
  const placing = outcome?.entrantId && asArray(group.placings).find(row => row.id === outcome.entrantId)
  return group.playerPlace || outcome?.place || placing?.place
}
function resultEntryDetail(group) {
  const outcome = resultEntryOutcome(group)
  return [outcome?.roundName || '', outcome?.label || labels[outcome?.idOutcome] || ''].filter(Boolean).join(', ')
}
const offerUnavailableReason = computed(() => offer.value?.available === false ? offer.value.unavailableReason || 'This event is unavailable.'
  : !asArray(offer.value?.classes).length ? 'No classes are available.' : !offer.value?.venueName ? 'No supported venue on this map.' : '')
// The weekend as four stops. Between days the session the player is waiting for is the open one.
const stages = computed(() => {
  const waitingFor = session.value.waiting ? { qualifying: 1, eliminations: 2, final: 3, finals: 3 }[String(session.value.nextLabel || '').toLowerCase()] : null
  const open = event.value?.phase === 'complete' || racingFinished.value ? 4 : event.value?.phase === 'registration' ? 0 : waitingFor ?? (qualifyingPhase.value ? 1 : session.value.stage === 'finals' ? 3 : 2)
  const stopped = ['out', 'withdrawn'].includes(playerStatus.value.role)
  return [['registration', 'Register'], ['qualifying', 'Qualify'], ['eliminations', 'Eliminations'], ['final', labels.final]].map(([id, label], index) => ({
    id, label, state: index < open ? 'done' : index > open ? 'upcoming' : stopped ? 'out' : 'current',
  }))
})
// Labelled values under the status; the weekend bar already carries the phase.
const facts = computed(() => {
  const s = session.value, out = []
  if (event.value?.className && event.value.phase !== 'registration') out.push({ label: 'Class', value: event.value.className })
  if (s.day) out.push({ label: withdrawn.value ? 'Left on day' : 'Day', value: count(s.day, s.totalDays || 3) })
  if (withdrawn.value) return out
  const round = state.value.qualifyingRound
  if (qualifyingProgress.value) out.push({ label: 'Round', value: count(round.number, round.maxRounds) })
  if (paddock.value.groupNumber && !s.waiting) out.push({ label: 'Group', value: count(paddock.value.groupNumber, paddock.value.groupCount) })
  if (state.value.round && event.value?.phase === 'eliminations' && playerStatus.value.role !== 'out') out.push({ label: 'Bracket', value: state.value.round.name })
  return out
})
// Where the player's best legal time sits between the class index and the bracket cut.
const GAUGE_LEAD_PERCENT = 4, GAUGE_CUT_SHARE = 0.8
const cutGauge = computed(() => {
  const entry = currentPlayerEntry.value, best = entry?.qualifying?.valid ? entry.qualifying.time : null
  if (!Number.isFinite(best)) return null
  const classId = entry.declaredClassId || entry.classId
  const legalTimes = asArray(resultClasses.value.find(group => (group.id || group.classId) === classId)?.standings).filter(row => row.qualifying?.valid).map(row => row.qualifying.time)
  const cut = legalTimes[(qualifyingFieldSize.value || 16) - 1]
  if (!Number.isFinite(cut)) return null
  const index = Number.isFinite(entry.indexSeconds) ? entry.indexSeconds : null
  const fastest = Math.min(best, index ?? best, legalTimes[0] ?? best), span = Math.max(cut - fastest, 0.001) / GAUGE_CUT_SHARE
  const percent = time => Math.max(0, Math.min(100, (time - fastest) / span * 100 + GAUGE_LEAD_PERCENT))
  const margin = cut - best
  return { bestPercent: percent(best), cutPercent: percent(cut), indexPercent: index == null ? null : percent(index), inside: margin >= 0,
    cutLabel: `${cut.toFixed(3)} s`, indexLabel: index == null ? '' : `${index.toFixed(2)} s`,
    marginTime: `${Math.abs(margin).toFixed(3)} s` }
})
const prizeShare = (value, prizes) => Math.max(0, Number(value) || 0) / (Number(prizes?.winner) || 1)
async function retryLoad() {
  return run(async () => {
    pendingAction.value = 'refresh'
    try { await acquireScope(lua, 'phone.motorsportEvents'); await refresh(); if (!disposed) startPolling() }
    catch (_) { if (!disposed) loadFailed.value = true }
    finally { if (!disposed) { loading.value = false; pendingAction.value = '' } }
  })
}
async function refresh() { if (disposed) return; const result = await lua.overhaul_phone_apps_motorsportEvents.getState(); if (!disposed && result) { state.value = result; loadFailed.value = false } }
async function act(method, ...args) {
  return run(async () => {
    error.value = ''; pendingAction.value = method
    let result
    try {
      result = await lua.overhaul_phone_apps_motorsportEvents[method](...args)
      if (!result?.ok) error.value = actionError(method, result?.error)
    } catch (_) { error.value = actionError(method); result = {ok: false, error: error.value} }
    // A failed re-read must not report a completed action as failed.
    const actionFailure = error.value
    try { await refresh() } catch (_) {}
    finally { pendingAction.value = '' }
    if (actionFailure && !disposed) error.value = actionFailure
    return result
  })
}
// Re-read backend state after a confirmation so a decision made against an old offer/event is not sent.
async function stillCurrent(check, message) {
  try { await refresh() } catch (_) {
    error.value = 'Unable to verify the current event. Please try again.'
    return false
  }
  if (check()) return true
  error.value = message
  return false
}
async function confirmThen(title, message, confirmLabel, cancelLabel, run, destructive = false) {
  if (busy.value || confirmationPending.value) return
  remember()
  confirmationPending.value = true
  try {
    const confirmed = await openHouseConfirmation(title, message, [{label: confirmLabel, value: true, extras: destructive ? {destructive: true} : {default: true}}, {label: cancelLabel, value: false, extras: destructive ? {cancel: true, default: true} : {cancel: true}}])
    if (confirmed === true) await run()
  } finally { confirmationPending.value = false; await restore() }
}
async function acceptOffer() {
  const current = offer.value
  if (!current?.id || offerUnavailableReason.value) return
  const id = current.id
  const schedule = calendar.value.clockFrozen ? 'Qualifying opens after registration; each new day follows a 30 min real-time wait.' : `Qualifying ${worldTimeLabel(current.startWorldMinute, current.dayIndex).toLowerCase()}; ${laterStagesText(offerItinerary.value)}.`
  await confirmThen('Join this event?', confirmationRows({ rows: [{ label: 'League', value: current.leagueName || leagueName(current.leagueId) }, { label: 'Venue', value: current.venueName }, { label: 'Qualifying', value: calendar.value.clockFrozen ? 'After registration' : worldTimeLabel(current.startWorldMinute, current.dayIndex) }, { label: 'Later rounds', value: laterStagesText(offerItinerary.value).replace(/^./, letter => letter.toUpperCase()) }, { label: 'Entry fee per class', value: current.fee, money: true }, { label: 'Charged now', value: 0, money: true }], note: 'Pay at registration. Other leagues stay locked until you finish or withdraw.' }), 'Accept', 'Not now', async () => {
    if (await stillCurrent(() => (!event.value || event.value.phase === 'complete') && offer.value?.id === id && offer.value.available !== false,"Today's offer changed while you were deciding. Review it again.")) await act('acceptOffer', id)
  })
}
async function declineOffer() {
  const id = offer.value?.id
  if (!id) return
  const wait = calendar.value.clockFrozen ? 'in 30 real minutes (even while paused)' : 'tomorrow'
  await confirmThen('Decline this offer?', `The next league's offer arrives ${wait}.`, 'Decline', 'Keep offer', async () => {
    if (await stillCurrent(() => offer.value?.id === id, 'This offer changed while you were deciding. Review it again.')) await act('declineOffer', id)
  }, true)
}
async function advanceOffer() {
  const id = offer.value?.id || calendar.value.id, target = calendar.value.nextOfferWorldMinute
  if (!id || !calendar.value.canAdvanceOffer) return
  await confirmThen('Skip to next day?', `Jump to ${worldTimeLabel(target, offer.value?.dayIndex).toLowerCase()}, when the next league offers. ${calendarWarning}`, 'Skip to next day', 'Cancel', async () => {
    if (await stillCurrent(() => (offer.value?.id || calendar.value.id) === id && calendar.value.canAdvanceOffer, "Today's offer changed. Review it again before advancing time.")) await act('advanceOffer', id)
  })
}
async function withdrawEvent() {
  const id = event.value?.id
  if (!id || event.value.phase === 'complete') return
  const entries = registrations.value.length, paid = registrations.value.reduce((sum, row) => sum + Number(row.refundPaid ? 0 : row.fee || 0), 0)
  const fees = !entries ? 'No fees paid yet.' : `Paid fees${paid > 0 ? ` (${money(paid)})` : ''} aren't refunded.`
  await confirmThen('Withdraw?', `Leave ${event.value.name || 'this event'}. ${fees} Results and payouts so far are kept. Next offer ${session.value.clockFrozen ? 'in 30 real minutes' : 'tomorrow'}.`, 'Withdraw', 'Stay in', async () => {
    if (await stillCurrent(() => event.value?.id === id && event.value.phase !== 'complete', 'The event changed. Review it again.')) await act('withdrawEvent', id)
  }, true)
}
async function finishWeekend() {
  if (busy.value || confirmationPending.value) return
  remember()
  confirmationPending.value = true
  try {
    const confirmed = await confirmFinishEvent({ eventName: event.value?.name, reward: event.value?.reward })
    if (confirmed === true) await act('finishSpectatorWeekend')
  } finally { confirmationPending.value = false; await restore() }
}
async function routeRegistration() { if (busy.value || confirmationPending.value) return; const result = await act('routeRegistration'); if (result?.ok && !error.value) await drive() }
async function startEvent() {
  const id = event.value?.id
  if (!id || event.value.phase !== 'registration' || !registrations.value.length) return
  if (busy.value || confirmationPending.value) return
  remember(); confirmationPending.value = true
  try {
    const confirmed = await confirmStartEvent({ entries: registrations.value, eventName: event.value.name })
    if (confirmed === true && await stillCurrent(() => event.value?.id === id && event.value.phase === 'registration' && registrations.value.length, 'The event changed. Review your entries again.')) await act('startRegisteredEvent', id)
  } finally { confirmationPending.value = false; await restore() }
}
async function advanceDay() {
  if (!session.value.canAdvanceDay) return
  const id = event.value?.id, target = session.value.scheduledWorldMinute
  const when = session.value.targetTimeLabel?.replace(/^Tomorrow/, 'tomorrow').replace(/^Today/, 'today') || (session.value.nextDay ? `Day ${session.value.nextDay}` : 'the next session')
  await confirmThen(`${advanceDayLabel.value}?`, `Jump to ${when}${session.value.nextLabel ? ` for ${session.value.nextLabel}` : ''}. ${calendarWarning} You still need the daily inspection.`, advanceDayLabel.value, 'Cancel', async () => {
    if (await stillCurrent(() => event.value?.id === id && session.value.canAdvanceDay && session.value.scheduledWorldMinute === target, 'The event schedule changed. Review it again before advancing time.')) await act('advanceDay')
  })
}
async function skipToMyGroup() {
  if (!state.value.skipToGroup?.available) return
  const id = event.value?.id, key = state.value.skipToGroup.key
  const prompt = session.value.clockFrozen ? 'The groups ahead of you are simulated. Your own runs stay live; career time stays put.' : `The groups ahead of you are simulated. Your own runs stay live. ${calendarWarning}`
  await confirmThen('Skip to my group?', prompt, 'Skip to my group', 'Cancel', async () => {
    if (await stillCurrent(() => event.value?.id === id && state.value.skipToGroup?.available && state.value.skipToGroup.key === key, 'The running order changed. Review your next run again.')) await act('skipToMyGroup', id, key)
  })
}
async function cancelEvent() { await confirmThen('Cancel event?', 'Discards this event and its standings.', 'Cancel event', 'Keep event', () => act('devCancelEvent'), true) }
async function drive() { if (!busy.value && !confirmationPending.value) await lua.extensions.ui_router.navigate('play') }
async function leaveSpectatorMode() { if (busy.value || confirmationPending.value) return; const result = await act('stopWatching'); if (result?.ok && !error.value) { if (result.eventComplete) tab.value = 'event'; else await drive() } }
function update(data) { if (!disposed && data) { state.value = data; loadFailed.value = false } }
watch(() => event.value?.id, () => { qualifyingOpen.value = {}; bracketOpen.value = {} })
watch(() => event.value?.phase, phase => { if (phase === 'complete') tab.value = 'event' })
let timer, disposed = false
function startPolling() { if (!disposed && !timer) timer = setInterval(() => refresh().catch(() => {}), 1000) }
onMounted(async () => {
  events.on('motorsportEventsUpdated', update)
  try {
    await acquireScope(lua, 'phone.motorsportEvents')
    if (disposed) return
    await refresh()
    if (disposed) return
    startPolling()
  }
  catch (_) { if (!disposed) loadFailed.value = true }
  finally { if (!disposed) loading.value = false }
})
onUnmounted(() => { disposed = true; events.off('motorsportEventsUpdated', update); clearInterval(timer); releaseScope(lua, 'phone.motorsportEvents') })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
// House phone density; spacing and type come from motorsport.scss so the overlays and boards match.
.motorsport { @include ms.ms-scale; height: 100%; padding-top: 4.1em; display: flex; flex-direction: column; }
.chrome { display: flex; align-items: center; gap: var(--ms-stack); padding: var(--ms-stack) var(--ms-pad); }
.tabs { flex: 1 1 auto; display: flex; gap: .2em; min-width: 0; }
.tabs > .house-button { flex: 1 1 0; min-width: 0; }
.content { flex: 1; min-height: 0; overflow: auto; padding: 0 var(--ms-pad) var(--ms-pad); display: flex; flex-direction: column; gap: var(--ms-gap); }
// Cards and folds keep their height so the list scrolls instead of squeezing the last fold shut.
.content > * { flex-shrink: 0; }
// Today's offer keeps its natural height; a long one scrolls with the page.
.content > .panel.offer:not(.offer-following) { flex: 0 0 auto; min-height: 0; }
.panel { flex: 0 0 auto; display: flex; flex-direction: column; gap: var(--ms-stack); padding: var(--ms-pad); }
.offer-empty { flex: 1 1 auto; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: var(--ms-stack); text-align: center; }
.offer-empty .head-icon { font-size: 2.2em; }
.offer-empty .card-title { flex: 0 0 auto; gap: .5em; }
.offer-empty .ms-heading { font-size: 1.35em; }
.offer-empty .ms-caption { font-size: 1.1em; }
// After an event the next offer is one line: what is next on the left, the skip button on the right.
.offer-following .offer-empty { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; text-align: left; }
.offer-following .offer-empty .head-icon { font-size: 1.35em; }
.offer-following .offer-empty .card-title { gap: .15em; }
.offer-following .offer-empty .ms-heading, .offer-following .offer-empty .ms-caption { font-size: 1em; }
.card-head { display: flex; align-items: center; gap: var(--ms-stack); }
.card-title { flex: 1 1 auto; display: grid; gap: .15em; min-width: 0; }
.head-icon { flex: 0 0 auto; font-size: 1.6em; --bng-icon-color: currentColor; color: var(--faint); }
.offer-head { align-items: flex-start; flex: 0 0 auto; }
.offer-head .card-title { gap: .3em; }
.offer-head .ms-title { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; font-size: 1.7em; letter-spacing: -0.025em; line-height: 1.05; }
.offer-venue { font-size: 1.05em; font-weight: 650; color: var(--muted); }
// Buttons sit on one line; they shorten before they wrap.
.actions { justify-content: flex-start; }
.actions:empty { display: none; }
.actions > .house-button { flex: 0 1 auto; min-width: 0; }
.note { display: flex; align-items: center; gap: .35em; }
.line { gap: var(--ms-stack); padding-top: var(--ms-row); padding-bottom: calc(var(--ms-row) - .08em); }
.sheet .line { padding-left: var(--ms-pad); padding-right: var(--ms-pad); }
.line > span:first-child { min-width: 0; }
.line small { display: block; }
/* Prizes: clean stacked rows (label left, amount right), one quiet note under the list. */
.prizes { display: flex; flex-direction: column; gap: 1px; margin: 0; overflow: hidden; border-radius: var(--radius-panel); }
.prize { display: flex; align-items: baseline; justify-content: space-between; gap: var(--ms-stack); padding: calc(var(--ms-row) * .55) 0.55em; background: var(--panel); }
.prize dt { color: var(--muted); white-space: nowrap; }
.prize dd { margin: 0; font-weight: 700; font-variant-numeric: tabular-nums; }
.prize-note { margin: 0; color: var(--faint); line-height: 1.3; }
.value { flex: 0 0 auto; display: grid; justify-items: end; max-width: 50%; text-align: right; }
.value small { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
.entry > span:first-child { display: grid; gap: .1em; }
.content > .empty { flex: 1 1 auto; align-content: center; }
.empty { align-items: center; text-align: center; padding: 1.4em var(--ms-pad); }
.empty .ms-heading { font-size: 1.35em; }
.empty .ms-caption { font-size: 1.1em; }
.empty-icon { font-size: 2.2em; --bng-icon-color: currentColor; color: var(--faint); }
.expanded > .chrome { width: min(100%, 76rem); align-self: center; box-sizing: border-box; }
.expanded > .content { padding-left: max(var(--ms-pad), calc((100% - 76rem) / 2 + var(--ms-pad))); padding-right: max(var(--ms-pad), calc((100% - 76rem) / 2 + var(--ms-pad))); }
.expanded .tabs { flex: 0 1 auto; }
.expanded .tabs > .house-button { flex: 0 0 auto; }

.tabs > .house-button:not(.active):hover { background: var(--panel-hover); }
.tabs :deep(.btn-icon) { display: none; }
.tabs > .house-button { font-size: .88em; padding-left: .35em; padding-right: .35em; }
.panel.offer { gap: .8em; justify-content: flex-start; padding: .9em var(--ms-pad) .8em; }
.offer-body { display: flex; flex-direction: column; gap: .8em; flex: 0 0 auto; min-height: 0; }
.offer-actions :deep(.house-button) { min-height: 2.7em; font-size: 1.02em; font-weight: 750; flex-shrink: 0; }
.offer-actions :deep(.house-button .btn-label) { overflow: visible; text-overflow: clip; white-space: nowrap; min-width: max-content; }
.offer-actions :deep(.house-button[data-fk="accept-offer"]) { flex: 1 1 auto; min-width: 4em; }
.offer-actions :deep(.house-button[data-fk="decline-offer"]) { flex: 0 0 auto; min-width: max-content; padding-left: .8em; padding-right: .8em; }
.offer-actions :deep(.house-button[data-fk="next-offer"]) { flex: 0 0 auto; min-width: max-content; }
// Event card: the name and venue, the weekend bar, the status, then the numbers and the buttons.
.event-card { gap: .7em; }
// The weekend as four parts of one bar: run parts are light, the open part takes the status colour, the rest wait.
.stage-rail { display: flex; gap: .3em; margin: .1em 0 0; padding: 0; list-style: none; }
.stage-rail li { flex: 1 1 0; display: grid; gap: .35em; min-width: 0; }
.stage-bar { height: .3em; border-radius: 1em; background: rgba(255, 255, 255, .13); }
.done > .stage-bar { background: rgba(255, 255, 255, .6); }
.current > .stage-bar { background: var(--tone); }
.out > .stage-bar { background: var(--ms-stop); }
.stage-label { font-size: .74em; font-weight: 700; color: var(--faint); white-space: nowrap; }
.done > .stage-label { color: var(--muted); }
.current > .stage-label { color: #fff; }
.out > .stage-label { color: var(--ms-stop-ink); }
// The status is the one coloured thing on the card: its sentence in the status colour on a faint ground of it.
.status { display: grid; gap: .55em; padding: .7em .85em .65em; }
.status-copy { display: grid; gap: .2em; min-width: 0; }
.status-title { font-size: 1.3em; letter-spacing: -.01em; }
.status .ms-caption { color: rgba(255, 255, 255, .82); }
.status-action { justify-self: start; margin: 0; }
.status-facts { margin-top: .35em; gap: .4em 1.4em; }
.status-facts .ms-time { font-size: 1.25em; line-height: 1.15; }
.status-facts .countdown-value { font-size: 1.9em; line-height: 1.1; }
.lane { text-transform: capitalize; }
.board-summary { padding: 0; background: none; }
.board-summary .status-title { font-size: 1.05em; }
.best { display: grid; gap: .6em; }
// Who is in this pass: the pairing, in full strength, needs no label.
.live { margin: 0; font-weight: 700; }
// Qualifying gauge: the index on the left, the bracket cut on the right, the player's best between them.
.cut-gauge { display: grid; gap: .45em; }
.cut-gauge-head { display: flex; align-items: baseline; gap: .6em; }
.cut-gauge-head .ms-time { font-size: 1.6em; line-height: 1; }
.cut-gauge-margin { margin-left: auto; font-size: .86em; font-weight: 700; color: var(--ok); }
.cut-gauge-head .cut-gauge-margin .ms-time, .cut-gauge-scale .ms-time { font-size: 1em; color: inherit; }
.result-copy .ms-time, .entry .ms-time { font-size: 1em; }
.outside .cut-gauge-margin { color: var(--bad); }
.cut-gauge-track { position: relative; height: .55em; border-radius: 1em; background: color-mix(in srgb, var(--ms-stop) 30%, transparent); }
.cut-gauge-safe { position: absolute; inset: 0 auto 0 0; border-radius: 1em 0 0 1em; background: linear-gradient(90deg, color-mix(in srgb, var(--ms-go) 75%, #111), color-mix(in srgb, var(--ms-go) 38%, #111)); }
.cut-gauge-cut, .cut-gauge-index { position: absolute; top: -.3em; bottom: -.3em; width: 2px; margin-left: -1px; border-radius: 1px; background: #fff; }
.cut-gauge-index { background: var(--accent-soft); }
// The player's best is a needle on the bar: taller and wider than the index and cut marks.
.cut-gauge-you { position: absolute; top: -.45em; bottom: -.45em; width: .36em; margin-left: -.18em; border-radius: .2em; background: #fff; box-shadow: 0 0 0 .16em #222224; }
.cut-gauge-scale { position: relative; height: 1.1em; font-size: .78em; font-weight: 700; }
.cut-gauge-scale span { position: absolute; top: 0; white-space: nowrap; color: var(--accent-soft); }
.cut-gauge-scale .cut { transform: translateX(-50%); color: var(--muted); }
// Results: placing first, payout in gold.
.results { display: grid; gap: .5em; }
.result { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: .75em; padding: .65em .75em; border-radius: var(--radius-tile); background: var(--panel); }
.result.won { background: linear-gradient(100deg, color-mix(in srgb, var(--ms-gold) 20%, transparent), var(--panel) 70%); }
.result-copy { display: grid; gap: .1em; min-width: 0; }
.result .place-unknown { color: var(--muted); }
.result-payout { font-size: 1.35em; }
.result-total { display: flex; align-items: baseline; justify-content: space-between; padding: 0 .75em; }
.result-total strong { font-size: 1.7em; line-height: 1.1; }
.card-head > .withdraw { flex: 0 0 auto; align-self: start; margin: -.25em -.4em 0 0; color: var(--bad); }
.card-head > .withdraw:hover:not(:disabled) { color: #fecaca; }
.event-card .note { color: var(--faint); }
// Offer card: the purse and the fee beside the league, the weekend day by day, the prize ladder drawn.
.purse { flex: 0 0 auto; display: grid; gap: .4em; margin: 0; text-align: right; }
.purse > div { display: grid; justify-items: end; gap: .08em; }
.purse dd { margin: 0; font-size: 1.05em; font-weight: 800; }
.purse .purse-win { font-size: 1.9em; line-height: 1; letter-spacing: -.02em; }
.offer-days > * { flex: 1 1 0; }
.offer-days dd { font-size: .92em; }
.offer-section { display: flex; flex-direction: column; gap: .45em; flex: 0 0 auto; min-height: 0; }
.offer-section .prizes { flex: 0 0 auto; border-radius: var(--radius-tile); }
.offer-section .prize { padding: calc(var(--ms-row) * .5) .5em; }
.offer-section .sheet.lines { flex: 0 0 auto; }
.prize-ladder .prize { display: grid; grid-template-columns: 6.6em minmax(0, 1fr) 4.4em; align-items: center; }
.prize-ladder .prize dd { text-align: right; }
// The action bar stays in reach and sits on the card's own colour, so long offers scroll under it cleanly.
.offer-actions { position: sticky; bottom: 0; z-index: 1; flex: 0 0 auto; align-items: stretch; gap: .45em; margin: auto calc(-1 * var(--ms-pad)) -.8em; padding: .6em var(--ms-pad) .7em; border-radius: 0 0 var(--radius-panel) var(--radius-panel); background: #222224; box-shadow: 0 -.9em .8em -.5em #222224; }
.offer-expiry .ms-time { font-size: 1.05em; }
.status-line { display: flex; align-items: flex-start; gap: .4em; margin: 0; padding: var(--ms-stack) var(--space-3); background: color-mix(in srgb, var(--ms-stop) 14%, transparent); border-radius: var(--radius-tile); }
.offer-arrival { display: grid; justify-items: center; gap: .1em; }
.countdown { display: block; font-size: 2.4em; line-height: 1.15; color: var(--tone-ink); }
.offer-following .offer-arrival { justify-items: start; }
.offer-following .countdown { font-size: 1.6em; }
.action-error { position: absolute; z-index: 3; left: var(--ms-pad); right: var(--ms-pad); bottom: var(--ms-pad); display: flex; align-items: center; gap: .6em; padding: .6em .7em; border-radius: var(--radius-tile); background: color-mix(in srgb, var(--ms-stop) 22%, var(--page)); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--ms-stop) 48%, transparent), 0 .4em 1.2em rgba(0, 0, 0, .5); }
.action-error > span { flex: 1 1 auto; min-width: 0; }
.rules-guide dl { margin: 0; display: grid; }
.rules-guide dl > div { display: grid; grid-template-columns: 6.4em minmax(0, 1fr); gap: .7em; padding: .5em 0; border-bottom: 1px solid var(--line); }
.rules-guide dl > div:last-child { border-bottom: 0; padding-bottom: 0; }
.rules-guide dt { color: #fff; font-size: .86em; font-weight: 700; line-height: 1.35; }
.rules-guide dd { margin: 0; color: var(--muted); font-size: .86em; line-height: 1.35; }
</style>

<style>
/* The shell's heads-up banner overlays the top of the screen; move Motorsport's tabs below it while it shows. */
.phone-screen:has(.phone-heads-up) .motorsport { padding-top: 8.2em; }
</style>
