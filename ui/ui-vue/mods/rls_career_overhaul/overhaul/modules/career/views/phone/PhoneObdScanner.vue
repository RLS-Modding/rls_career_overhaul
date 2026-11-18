<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="scanner" v-bng-on-ui-nav:tab_l="event => changePhoneTab(-1, event)" v-bng-on-ui-nav:tab_r="event => changePhoneTab(1, event)">
    <header class="hero">
      <div>
        <div class="eyebrow" :class="{ online: scannerConnected, caution: scannerNeedsIgnition }">{{ connectionPresentation.eyebrow }}</div>
        <h1>{{ vehicleTitle }}</h1>
      </div>
      <span class="status" :class="{ online: scannerConnected, caution: scannerNeedsIgnition }">{{ connectionPresentation.status }}</span>
    </header>

    <template v-if="tunerOpen">
      <main class="tuner-page">
        <HouseButton type="button" class="tuner-back" @click="closeTuner">
          <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
            <path d="M8 2L4 6l4 4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
          Back
        </HouseButton>
        <section class="card tuner-offer">
          <template v-if="proTunerUnlocked">
            <header class="tuner-offer-head">
              <span class="tuner-entry-icon" aria-hidden="true">
                <svg viewBox="0 0 24 24">
                  <path d="M4.8 16.8a8.2 8.2 0 1 1 14.4 0" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
                  <path d="M12 16.8L16.4 10.6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
                  <circle cx="12" cy="16.8" r="1.35" fill="currentColor" />
                </svg>
              </span>
              <div>
                <p class="tuner-brand">Kapoow Racing</p>
                <h2>PRO Tuner</h2>
                </div>
              </header>
              <p class="tuner-copy">{{ tuner.description || (tuner.available ? 'Live wastegate adjustment.' : tuner.reason) }}</p>
              <p v-if="fuelControl" class="tuner-copy fuel-note" role="status">{{ fuelControl.control?.mode==='native' ? 'Original engine behavior is active.' : 'Applied fuel tuning is active.' }} <template v-if="fuelControl.control?.dormantCalibration">An older tune is saved but inactive. Apply it in the garage to use it.</template></p>
              <div v-if="fuelControl" class="tuner-dyno-metrics fuel-now">
                <article><span>AFR estimate</span><strong>{{ fuelDecimal(fuelControl.afr,2) }}</strong><small>target {{ fuelDecimal(fuelControl.targetAFR,2) }}</small></article>
                <article :class="fuelControl.injectorDuty >= 1 ? 'bad' : fuelControl.injectorDuty >= .9 ? 'warn' : null"><span>Injectors</span><strong>{{ fuelDutyText(fuelControl.injectorDuty) }}</strong><small>{{ fuelControl.control?.mode==='native' ? 'Native delivery' : 'of capacity' }}</small></article>
                <article :class="fuelControl.pumpDuty >= 1 ? 'bad' : fuelControl.pumpDuty >= .9 ? 'warn' : null"><span>Pump</span><strong>{{ fuelDutyText(fuelControl.pumpDuty) }}</strong><small>{{ fuelControl.control?.mode==='native' ? 'Native delivery' : 'of capacity' }}</small></article>
              </div>
              <template v-if="tuner.available && !fuelBoostActive">
                <div class="tuner-value-row">
                  <span>{{ tuner.title }}</span>
                  <strong :style="{ color: tunerSliderColor }">{{ tunerValueText }}</strong>
              </div>
              <BngSlider
                class="tuner-slider"
                :min="tuner.min"
                :max="tuner.max"
                :step="tuner.step"
                :model-value="tuner.value"
                :style="{ accentColor: tunerSliderColor }"
                @update:model-value="onTunerInput"
                aria-label="Wastegate pressure"
              />
              <div class="tuner-range">
                <small>{{ tunerBoundText(tuner.min) }}</small>
                <small>{{ tunerBoundText(tuner.max) }}</small>
              </div>
              <p v-if="tuner.mode === 'software'" class="tuner-copy tuner-copy-follow">
                  Note: The wastegate only holds boost down. Not every turbocharger can actually make more if you raise it.
                </p>
              </template>
                <template v-if="boostCut && !boostCutInFuelCard">
                  <div class="tuner-value-row tuner-cut-row">
                    <span>Boost cut</span>
                    <strong>{{ boostCutText }}</strong>
                  </div>
                  <HouseSlider
                    class="tuner-slider"

                    aria-label="Boost cut pressure"
                    :min="boostCut.minMarginPsi"
                    :max="boostCut.maxMarginPsi"
                    :step="boostCut.step"
                    :model-value="boostCutMargin"
                    :disabled="!boostCut.editable"
                    @update:modelValue="value => onBoostCutInput({target:{value}})"
                    @valueChanged="value => onBoostCutChange({target:{value}})"
                   />
                  <div class="tuner-range">
                    <small>{{ boostCutBoundText(boostCut.minMarginPsi) }}</small>
                    <small>{{ boostCutMargin === boostCut.stockMarginPsi ? 'Stock' : `Stock cut ${boostCutBoundText(boostCut.stockMarginPsi)}` }}</small>
                    <small>{{ boostCutBoundText(boostCut.maxMarginPsi) }}</small>
                  </div>
                  <p class="tuner-copy tuner-copy-follow">
                    {{ boostCut.editable ? 'Cuts fuel when boost stays above this. Same setting as Fuel & Ignition.' : boostCut.reason }}
                  </p>
                </template>
            </template>
            <template v-else>
              <header class="tuner-offer-head">
              <span class="tuner-entry-icon" aria-hidden="true">
                <svg viewBox="0 0 24 24">
                  <path d="M4.8 16.8a8.2 8.2 0 1 1 14.4 0" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
                  <path d="M12 16.8L16.4 10.6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
                  <circle cx="12" cy="16.8" r="1.35" fill="currentColor" />
                </svg>
              </span>
              <div>
                <p class="tuner-brand">Kapoow Racing</p>
                <h2>PRO Tuner license</h2>
              </div>
            </header>
            <p class="tuner-copy">{{ canBuyProTuner ? proTunerOfferText : tunerLockText }}</p>
            <div v-if="canBuyProTuner" class="tuner-offer-price">
              <span>One-time license</span>
              <strong><MoneyAmount>{{ proTunerPriceText }}</MoneyAmount></strong>
            </div>
            <HouseButton
              v-if="canBuyProTuner"
              type="button"
              class="tuner-buy"
              :disabled="purchasingProTuner || tuner.canAfford === false"
              @click="purchaseProTuner"
            >
              {{ purchasingProTuner ? 'Purchasing...' : 'Get license' }}
            </HouseButton>
              <p v-if="canBuyProTuner && tuner.canAfford === false" class="tuner-copy tuner-copy-follow">Not enough money.</p>
            </template>
          </section>
          <template v-if="proTunerUnlocked && fuelControl">
            <section class="card fuel-card" aria-label="Live fuel trim">
              <h2 class="card-title">Fuel trim <span class="tuner-pull-label">Saved on engine</span></h2>
              <div v-if="tuner.fuelControls?.length>1" class="tuner-value-row"><span>Engine</span><HouseMenu class="fuel-engine-pick" aria-label="Engine" v-model="fuelEngine" :disabled="fuelWriting" :items="tuner.fuelControls.map(e=>({value:e.engine,label:e.engine}))" /></div>
              <div class="tuner-value-row"><span>Whole-map fuel</span><strong class="fuel-accent">{{ fuelSigned(fuelControl.afrTrim, 0) }}%</strong></div>
              <HouseSlider  class="tuner-slider" aria-label="Live AFR fuel trim"  min="-20" max="20" step="1" :model-value="fuelControl.afrTrim" :disabled="fuelWriting" @valueChanged="value => writeFuelControl({afrTrim:Number(value)})" />
              <div class="tuner-range"><small>Leaner −20%</small><small>Richer +20%</small></div>
              <div class="fuel-actions"><span class="fuel-status" role="status">{{ fuelWriteMessage }}</span><HouseButton type="button" class="fuel-ghost" :disabled="fuelWriting || !fuelControl.afrTrim" @click="writeFuelControl({afrTrim:0})">Reset</HouseButton></div>
            </section>
            <section class="card fuel-card" aria-label="Live boost offsets">
              <h2 class="card-title">Boost <span class="tuner-pull-label tuner-pull-label-live">{{ !fuelBoostActive ? 'Original control' : fuelControl.boost.mode==='map' ? 'RPM map' : 'Per-gear limits' }}</span></h2>
              <template v-if="fuelBoostActive">
                <div class="tuner-value-row"><span>Offset, all gears</span><strong>{{ fuelSigned(fuelControl.boost.offset, 1) }} psi</strong></div>
                <HouseSlider  class="tuner-slider" aria-label="Global boost offset PSI"  min="-30" max="30" step=".5" :model-value="fuelControl.boost.offset" :disabled="fuelWriting" @valueChanged="value => writeFuelControl({boostOffset:Number(value)})" />
                <div class="tuner-range"><small>−30</small><small>requested {{ fuelDecimal(fuelControl.boostTargetPsi,1) }} psi</small><small>+30</small></div>
                <div class="fuel-gears"><label v-for="(g,i) in fuelControl.boost.gears" :key="g">G{{ g }}<input type="number" min="-30" max="30" step=".5" :aria-label="'Gear '+g+' boost offset PSI'" :value="fuelControl.boost.offsets[i]" :disabled="fuelWriting" @change="writeGearOffset(i,$event)"><small v-if="fuelControl.boost.mode!=='map'">{{ fuelDecimal(Math.max(0,Math.min(200,fuelControl.boost.caps[i]+fuelControl.boost.offset+fuelControl.boost.offsets[i])),1) }}</small></label></div>
              </template>
              <p v-else class="tuner-copy fuel-note"><template v-if="tuner.available">Original boost control. Use the wastegate slider above, or apply Simple gear caps or an Advanced boost map in the garage to enable offsets here.</template><template v-else>{{ fuelControl.boostSupportReason || 'Boost control is unavailable for this setup.' }} Fuel trim still works.</template></p>
              <div v-if="boostCut && boostCutInFuelCard" class="fuel-cut">
                <div class="tuner-value-row"><span>Boost cut</span><strong>{{ boostCutText }}</strong></div>
                <HouseSlider  class="tuner-slider"  aria-label="Boost cut pressure" :min="boostCut.minMarginPsi" :max="boostCut.maxMarginPsi" :step="boostCut.step" :model-value="boostCutMargin" :disabled="!boostCut.editable" @update:modelValue="value => onBoostCutInput({target:{value}})" @valueChanged="value => onBoostCutChange({target:{value}})" />
                <div class="tuner-range"><small>{{ boostCutBoundText(boostCut.minMarginPsi) }}</small><small>{{ boostCutMargin === boostCut.stockMarginPsi ? 'Stock' : `Stock cut ${boostCutBoundText(boostCut.stockMarginPsi)}` }}</small><small>{{ boostCutBoundText(boostCut.maxMarginPsi) }}</small></div>
                <p v-if="!boostCut.editable" class="tuner-copy fuel-note">{{ boostCut.reason }}</p>
              </div>
              <div v-if="fuelBoostActive" class="fuel-actions"><span></span><HouseButton type="button" class="fuel-ghost" :disabled="fuelWriting" @click="writeFuelControl({boostOffset:0,gearOffsets:fuelControl.boost.gears.map(()=>0)})">Reset boost</HouseButton></div>
            </section>
          </template>
          <section v-if="proTunerUnlocked && fuelMonitored && fuelControl" class="card">
            <h2 class="card-title">
              Fuel
              <span class="tuner-pull-label" :class="{ 'tuner-pull-label-live': !fuelPull }">{{ fuelPull ? 'Last pull' : 'Live' }}</span>
            </h2>
            <p class="tuner-dyno-date">{{ fuelPullNote }}</p>
            <div class="tuner-dyno-metrics">
              <article :class="fuelCard.mixtureBad ? 'bad' : null">
                <span>AFR</span>
                <strong>{{ fuelCardText.afr }}</strong>
                <small>{{ fuelCardText.target }}</small>
              </article>
              <article v-if="fuelSystem?.fuelType!=='diesel'" :class="fuelCard.knock ? 'bad' : fuelCard.held ? 'warn' : null">
                <span>{{ fuelPull ? 'Peak retard' : 'Knock retard' }}</span>
                <strong>{{ fuelCardText.retard }}</strong>
                <small>{{ fuelCardRetardNote }}</small>
              </article>
              <article :class="fuelCard.limited ? 'bad' : null">
                <span>{{ fuelPull ? 'Peak delivery' : 'Fuel delivery' }}</span>
                <strong>{{ fuelCardText.duty }}</strong>
                <small>{{ fuelControl.control?.mode==='native' ? 'Native delivery' : 'of capacity' }}</small>
              </article>
            </div>
          </section>
          <section v-else-if="proTunerUnlocked && fuelSystem && fuelSystem.monitored === false" class="card">
            <h2 class="card-title">Fuel</h2>
            <p class="tuner-copy">{{ fuelSystem.reason || 'Fuel system not monitored.' }}</p>
          </section>
          <section v-if="proTunerUnlocked && latestPull" class="card">
            <h2 class="card-title">
              Dyno sheet
            <span class="tuner-pull-label">Latest</span>
          </h2>
          <p v-if="pullDateText(latestPull)" class="tuner-dyno-date">{{ pullDateText(latestPull) }}</p>
          <div class="tuner-dyno-metrics">
            <article>
              <span>Peak power</span>
              <strong>{{ power(latestPull.peakPower) || '--' }}</strong>
              <small>{{ pullRpmAtText(latestPull.peakPowerRpm) }}</small>
            </article>
            <article>
              <span>Peak dyno tq</span>
              <strong>{{ torque(latestPull.peakTorque) || '--' }}</strong>
              <small>{{ pullRpmAtText(latestPull.peakTorqueRpm) }}</small>
            </article>
            <article :class="pullQualityClass(latestPull)">
              <span>Pull quality</span>
              <strong>{{ pullQualityLabel(latestPull) }}</strong>
              <small>{{ pullSampleText(latestPull) }}</small>
            </article>
          </div>
          <div v-if="latestPowerCurvePoints" class="tuner-dyno-curve">
            <div class="tuner-dyno-legend">
              <span class="legend-power">Power</span>
              <span class="legend-torque">Torque</span>
            </div>
            <svg viewBox="0 0 320 120" preserveAspectRatio="none" class="tuner-dyno-svg" aria-hidden="true">
              <polyline class="tuner-dyno-grid" points="10,10 310,10" />
              <polyline class="tuner-dyno-grid" points="10,60 310,60" />
              <polyline class="tuner-dyno-grid" points="10,110 310,110" />
              <polyline class="tuner-dyno-torque" :points="latestTorqueCurvePoints" />
              <polyline class="tuner-dyno-power" :points="latestPowerCurvePoints" />
            </svg>
            <div class="tuner-dyno-axis">
              <span>{{ graphRpmLabel(latestGraphScale.minRpm) }}</span>
              <span>{{ graphRpmLabel(latestGraphScale.maxRpm) }}</span>
            </div>
            </div>
          </section>
          <p v-if="proTunerUnlocked" class="tuner-firmware">
            <b>Kapoow Racing PRO Tuner 2.0</b>
            Live AFR trim and global/per-gear boost offsets are included with your existing license.
          </p>
        </main>
      </template>

    <template v-else>
    <nav class="tabs" aria-label="Scanner sections">
      <HouseButton v-for="item in tabs" :key="item.id" :class="{ active: tab === item.id }" @click="tab = item.id">
        {{ item.label }}
      </HouseButton>
    </nav>

    <Notice v-if="!scannerConnected" :title="connectionPresentation.noticeTitle">
      {{ connectionPresentation.noticeText }}
    </Notice>

    <main v-else-if="tab === 'live'">
      <section class="gauges">
        <article v-if="isNumber(live.rpm)" class="gauge">
          <span>{{ live.hasElectricDrive ? 'Drive motor speed' : 'Engine speed' }}</span><strong>{{ whole(live.rpm) }}</strong><small>rpm</small>
          <div v-if="rpmScale" class="bar"><i :class="live.hasElectricDrive ? null : engineRpmTone(live.rpm)" :style="{ width: rpmPercent + '%' }"></i></div>
        </article>
        <article v-if="live.isHybrid && isNumber(live.engineRpm)" class="gauge">
          <span>Generator engine speed</span><strong>{{ whole(live.engineRpm) }}</strong><small>rpm</small>
          <div v-if="engineRpmScale" class="bar"><i :class="engineRpmTone(live.engineRpm)" :style="{ width: engineRpmPercent + '%' }"></i></div>
        </article>
        <article v-if="live.hasCoolingSystem !== false && !live.isElectric && isNumber(live.coolantTemp)" class="gauge">
          <span>{{ live.isHybrid ? 'Generator coolant' : 'Coolant temperature' }}</span><strong>{{ temperature(live.coolantTemp) }}</strong>
          <div v-if="coolantGauge" class="bar"><i :class="coolantGauge.tone" :style="{ width: coolantGauge.percent + '%' }"></i></div>
        </article>
        <article v-if="!live.isElectric && isNumber(live.oilTemp)" class="gauge">
          <span>{{ live.isHybrid ? 'Generator oil' : 'Oil temperature' }}</span><strong>{{ temperature(live.oilTemp) }}</strong>
          <div v-if="oilGauge" class="bar"><i :class="oilGauge.tone" :style="{ width: oilGauge.percent + '%' }"></i></div>
        </article>
        <article v-if="!live.isElectric && isNumber(live.fuel)" class="gauge">
          <span>{{ live.isHybrid ? 'Diesel fuel' : 'Fuel level' }}</span><strong>{{ percent(live.fuel) }}</strong>
          <div class="bar"><i :class="{ warn: live.lowFuel === true }" :style="{ width: clampPercent(live.fuel) + '%' }"></i></div>
        </article>
        <article v-if="live.hasElectricDrive && isNumber(live.batteryCharge)" class="gauge">
          <span>Battery charge</span><strong>{{ percent(live.batteryCharge) }}</strong>
          <div class="bar"><i :style="{ width: clampPercent(live.batteryCharge) + '%' }"></i></div>
        </article>
      </section>

      <section class="card grid">
        <Metric :label="live.hasElectricDrive ? 'Vehicle state' : 'Ignition'" :value="ignitionText" />
        <Metric :label="live.hasElectricDrive ? 'Propulsion load' : 'Engine load'" :value="percent(live.hasElectricDrive ? live.propulsionLoad : live.engineLoad)" />
        <Metric v-if="isNumber(live.turboBoostPsi)" label="Boost pressure" :value="boostPressure(live.turboBoostPsi)" />
        <Metric label="Diagnostic status" :value="diagnosticStatusText" :warn="hasActiveFault" />
        <Metric label="Next service (est.)" :value="nextServiceText" :caution="nextServiceMiles != null && nextServiceMiles <= 0" />
      </section>

      <section v-if="diagnosticFindings.length" class="card findings-card">
        <h2>Diagnostic findings</h2>
        <article v-for="finding in diagnosticFindings" :key="finding.key" class="finding" :class="finding.severity">
          <b>{{ finding.title }}</b>
          <p v-if="finding.cause"><span>Probable cause</span>{{ finding.cause }}</p>
          <p v-if="finding.effect"><span>Observed effect</span>{{ finding.effect }}</p>
          <p v-if="finding.action"><span>Recommended action</span>{{ finding.action }}</p>
        </article>
      </section>

      <HouseButton
        v-if="proTunerEnabled"
        type="button"
        class="tuner-entry"
        :class="{ 'tuner-entry-locked': !proTunerUnlocked && !canBuyProTuner }"
        @click="openTuner"
      >
        <span class="tuner-entry-icon" aria-hidden="true">
          <svg viewBox="0 0 24 24">
            <path d="M4.8 16.8a8.2 8.2 0 1 1 14.4 0" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
            <path d="M12 16.8L16.4 10.6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
            <circle cx="12" cy="16.8" r="1.35" fill="currentColor" />
          </svg>
        </span>
        <span class="tuner-entry-copy">
          <b>{{ canBuyProTuner ? 'PRO Tuner license' : 'PRO Tuner' }}</b>
          <small>{{ proTunerRowSubtext }}</small>
        </span>
        <span v-if="canBuyProTuner" class="tuner-entry-get">GET</span>
        <svg v-else class="tuner-entry-chevron" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
          <path d="M4 2l4 4-4 4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </HouseButton>
    </main>

    <main v-else-if="tab === 'engine'">
      <section v-if="live.hasElectricDrive && motors.length" class="card specs-card">
        <h2>Drive motor specifications</h2>
        <div class="spec-list">
          <template v-for="motor in motors" :key="motor.id">
            <div><span>{{ motor.position ? `${motor.position} motor` : 'Motor' }}</span><strong>{{ motor.name }}</strong></div>
            <div v-if="isNumber(motor.maxRpm)"><span>Maximum motor speed</span><strong>{{ whole(motor.maxRpm) }} rpm</strong></div>
          </template>
          </div>
        </section>

        <section v-if="!live.isElectric && (live.engineName || live.forcedInductionName || live.forcedInductionType || hasEcuCalibration || fuelMonitored)" class="card specs-card">
          <h2>Engine & ECU</h2>
          <div class="spec-list">
            <div v-if="live.engineName"><span>{{ live.isHybrid ? 'Generator engine' : 'Engine' }}</span><strong>{{ live.engineName }}</strong></div>
          <div v-if="live.forcedInductionName || live.forcedInductionType"><span>Forced induction</span><strong>{{ live.forcedInductionName || live.forcedInductionType }}</strong></div>
          <div v-if="isNumber(live.idleRpm)">
            <span>Target idle speed</span><strong>{{ whole(live.idleRpm) }} rpm</strong>
          </div>
          <div v-if="isNumber(live.ecuLimiterRpm)">
            <span>Rev limiter</span><strong>{{ whole(live.ecuLimiterRpm) }} rpm</strong>
          </div>
          <div v-if="limiterStrategyText">
            <span>Limiter strategy</span><strong>{{ limiterStrategyText }}</strong>
          </div>
          <div v-if="isNumber(limiterCutDurationMs)">
            <span>Cut duration</span><strong>{{ whole(limiterCutDurationMs) }} ms</strong>
          </div>
            <div v-if="isNumber(live.wastegateStartPsi)">
              <span>Wastegate opening pressure</span><strong>{{ boostPressure(live.wastegateStartPsi) }}</strong>
            </div>
            <div v-if="fuelMonitored && fuelSystem.system"><span>Fuel system</span><strong>{{ fuelSystem.system }}</strong></div>
            <div v-if="fuelMonitored && fuelSystem.fuelInUse"><span>Fuel in use</span><strong>{{ fuelSystem.fuelInUse }}</strong></div>
            <div v-if="fuelRequirementText"><span>Fuel requirement</span><strong>{{ fuelRequirementText }}</strong></div>
            <div v-if="fuelOctaneText"><span>Fuel octane</span><strong>{{ fuelOctaneText }}</strong></div>
          </div>
        </section>

      <section v-if="live.hasElectricDrive" class="card">
        <h2>Drive motor diagnostics</h2>
        <StatusRow label="Current propulsion output" :bad="motorRestrictionNeedsAttention" :warn="motorOutputRestricted && !motorRestrictionNeedsAttention" :text="motorOutputText" />
        <StatusRow v-if="!motorOutputRestricted && isNumber(recentMotorTorqueAvailability)" label="Observed under-load output" :warn="true" :text="`${percent(recentMotorTorqueAvailability)} available`" />
        <StatusRow v-for="motor in motors" :key="motor.id" :label="motor.position ? `${motor.position} motor` : motor.name" :bad="motor.broken === true || (motor.disabled === true && motor.hasEnergy === true)" :text="motor.broken === true ? 'Fault detected' : motor.disabled === true && motor.hasEnergy === true ? 'Unavailable' : 'Normal'" />
      </section>

      <section v-if="!live.isElectric" class="card">
        <h2>{{ live.isHybrid ? 'Generator engine diagnostics' : 'Diagnostics' }}</h2>
        <StatusRow v-if="maintenanceOnline" label="Output restriction" :bad="powerLimited" :warn="!powerLimited && Boolean(recentEngineRestrictionObservation)" :text="powerLimited ? powerLimitText : recentEngineRestrictionObservation ? 'Recently observed under load' : 'None'" />
        <StatusRow v-if="live.forcedInductionName || live.forcedInductionType" label="Forced induction" :bad="inductionDamageActive" :warn="!inductionDamageActive && (turboHotActive || inductionDamageRecent || turboHotRecent)" :text="forcedInductionStatusText" />
          <StatusRow v-if="roughnessState || live.recentCombustionStability" label="Combustion stability" :bad="roughnessState && roughnessState !== 'Normal'" :warn="roughnessState === 'Normal' && live.recentCombustionStability" :text="roughnessState && roughnessState !== 'Normal' ? roughnessState : live.recentCombustionStability ? 'Recently observed — elevated' : 'Normal'" />
          <StatusRow v-if="live.idleStability" label="Idle stability" :bad="live.idleStability === 'unstable'" :warn="live.idleStability === 'rough' || (live.idleStability === 'normal' && live.recentIdleStall === true)" :text="idleStabilityText" />
          <StatusRow v-if="misfireState || live.recentMisfireRisk" label="Estimated misfire risk" :bad="misfireState && misfireState !== 'Normal'" :warn="misfireState === 'Normal' && Boolean(live.recentMisfireRisk)" :text="misfireState && misfireState !== 'Normal' ? misfireState : live.recentMisfireRisk ? `Recently observed — ${live.recentMisfireRisk}` : 'Normal'" />
          <StatusRow v-if="fuelMonitored" label="Mixture" v-bind="fuelMixtureRow" />
          <StatusRow v-if="fuelMonitored" label="Knock" v-bind="fuelKnockRow" />
          <StatusRow v-if="fuelMonitored" label="Fuel delivery" v-bind="fuelDeliveryRow" />
          <StatusRow v-if="fuelMonitored && fuelAlerts.boostCut === true" label="Boost cut" :bad="true" text="Cutting fuel" />
          <StatusRow v-if="fuelSystem && fuelSystem.monitored === false" label="Fuel system" :warn="true" :text="fuelSystem.reason || 'Not monitored'" />
          <StatusRow v-if="maintenanceOnline" label="Engine condition" :warn="Boolean(engine.activeSymptom || recentEngineSymptom)" :text="engineConditionText" />
        </section>
      </main>

    <main v-else-if="tab === 'service'">
      <Notice v-if="live.isElectric && maintenanceOnline" title="RLS maintenance model">
        These service values are applied to this vehicle by RLS and can affect propulsion output, but they are not native EV component readings.
      </Notice>
      <Notice v-if="!maintenanceOnline" title="Service information unavailable">
        {{ maintenanceUnavailableText }}
      </Notice>
      <template v-if="maintenanceOnline">
        <section v-for="category in maintenanceCategories" :key="category.key" class="card service-card">
          <div class="card-title">
            <span>{{ category.label }}</span>
            <b :class="categoryConditionClass(category.data)">{{ categoryConditionState(category.data) }}</b>
          </div>
          <StatusRow v-if="category.key === 'radiator'" label="Cooling condition" :warn="Boolean(radiator.activeSymptom || recentCoolingSymptom)" :text="coolingConditionText" />
          <div v-if="isNumber(category.data.avgMiles)" class="mileage-wear">
            <div><span>Mileage wear</span><b :style="{ color: mileageWearColor(ageMiles(category.data)) }">{{ mileageWearPercent(ageMiles(category.data)) }}%</b></div>
            <div class="service-bar"><i :style="{ width: mileageWearPercent(ageMiles(category.data)) + '%', backgroundColor: mileageWearColor(ageMiles(category.data)) }"></i></div>
            <small>{{ distanceMiles(category.data.avgMiles) }} on installed components</small>
          </div>
          <div class="service-heading">Service condition remaining</div>
          <div v-if="isNumber(category.data.integrityValue) && category.data.integrityValue < 0.999" class="service-item">
            <div><span>Mechanical integrity</span><b :style="{ color: conditionColor(category.data.integrityValue) }">{{ percent(category.data.integrityValue) }}</b></div>
            <div class="service-bar"><i :style="{ width: clampPercent(category.data.integrityValue) + '%', backgroundColor: conditionColor(category.data.integrityValue) }"></i></div>
          </div>
          <div v-for="item in category.data.maintenanceItems || []" :key="item.name" class="service-item">
            <div><span>{{ serviceItemLabel(item) }}</span><b :style="{ color: serviceItemColor(item) }">{{ percent(item.value) }}</b></div>
            <div class="service-bar"><i :style="{ width: clampPercent(item.value) + '%', backgroundColor: serviceItemColor(item) }"></i></div>
            <small v-if="dueText(item)">{{ dueText(item) }}</small>
          </div>
          <div v-for="risk in diagnosticRisks(category.data.riskFlags, category.data, category.key)" :key="risk.key" class="risk" :class="risk.severity">
            <b>{{ diagnosticRiskLabel(risk) }}</b><span v-if="diagnosticRiskDetail(risk)">{{ diagnosticRiskDetail(risk) }}</span>
          </div>
        </section>
      </template>
    </main>

    <main v-else>
      <section v-if="live.hasElectricDrive" class="card specs-card">
        <h2>Electric drive</h2>
        <div class="spec-list">
          <div v-if="driveLayout"><span>Drive layout</span><strong>{{ driveLayout }}</strong></div>
          <template v-for="motor in motors" :key="motor.id">
            <div><span>{{ motor.position || 'Drive motor' }}</span><strong>{{ motor.name }}</strong></div>
            <div v-if="motor.reductionName"><span>Reduction unit</span><strong>{{ motor.reductionName }}</strong></div>
            <div v-if="motor.reductionRatios?.length"><span>Reduction ratios</span><strong>{{ ratioList(motor.reductionRatios) }}</strong></div>
            <div v-else-if="isNumber(motor.reductionRatio)"><span>{{ motor.reductionType === 'torsionReactor' ? 'Reduction ratio' : 'Current reduction' }}</span><strong>{{ decimal(motor.reductionRatio, 2) }}:1</strong></div>
            <div v-if="motor.differentialName"><span>Differential</span><strong>{{ motor.differentialName }}</strong></div>
            <div v-if="isNumber(motor.finalDriveRatio)"><span>Final drive</span><strong>{{ decimal(motor.finalDriveRatio, 2) }}:1</strong></div>
          </template>
        </div>
      </section>

      <section v-else class="card specs-card">
        <h2>Transmission</h2>
        <div class="spec-list">
          <div v-if="gearboxDisplayName"><span>Gearbox</span><strong>{{ gearboxDisplayName }}</strong></div>
          <div v-if="isNumber(live.forwardGearCount)"><span>Forward gears</span><strong>{{ whole(live.forwardGearCount) }}</strong></div>
          <div v-if="live.clutchName"><span>Clutch</span><strong>{{ live.clutchName }}</strong></div>
          <div v-if="live.flywheelName"><span>Flywheel</span><strong>{{ live.flywheelName }}</strong></div>
        </div>
      </section>

      <section v-if="live.transferCase" class="card specs-card">
        <h2>Transfer case</h2>
        <div class="spec-list">
          <div v-if="live.transferCase.name"><span>Transfer case</span><strong>{{ live.transferCase.name }}</strong></div>
          <div v-if="live.transferCase.driveModes?.length"><span>Drive modes</span><strong>{{ live.transferCase.driveModes.join(' / ') }}</strong></div>
          <div v-if="live.transferCase.rangeModes?.length"><span>Range modes</span><strong>{{ live.transferCase.rangeModes.join(' / ') }}</strong></div>
          <div v-if="transferCaseCurrentMode"><span>Current mode</span><strong>{{ transferCaseCurrentMode }}</strong></div>
        </div>
      </section>

      <section v-if="!live.hasElectricDrive" class="card grid">
        <Metric label="Shift response" :value="shiftQualityState" :warn="shiftQualityState !== 'Normal'" />
        <Metric v-if="hasClutchData" label="Estimated clutch condition" :value="clutchWearState" :warn="clutchWearState !== 'Normal'" />
        <Metric v-if="hasClutchData && isNumber(live.clutchTempC)" label="Clutch temperature" :value="temperature(live.clutchTempC)" :warn="clutchTemperatureHigh" :caution="clutchTemperatureElevated" />
        <Metric label="Fluid quality" :value="percent(transmission.maintenance?.fluidCondition)" />
        <Metric label="Fluid level" :value="percent(transmission.maintenance?.fluidLevel)" />
      </section>

      <section v-if="isNumber(live.airPressurePa)" class="card grid">
        <Metric label="Air pressure" :value="airPressure(live.airPressurePa)" :warn="live.lowAirPressure === true" />
        <Metric v-if="isBoolean(live.lowAirPressure)" label="Air system" :value="live.lowAirPressure ? 'Pressure low' : 'Normal'" :warn="live.lowAirPressure" />
        <Metric label="Pressure tank" :value="pressureTankLeakActive ? 'Leak detected' : 'Normal'" :warn="pressureTankLeakActive" />
        <Metric v-if="isBoolean(live.parkingBrakeApplied)" label="Parking brake" :value="live.parkingBrakeApplied ? 'Applied' : 'Released'" :warn="live.lowAirPressure && live.parkingBrakeApplied" />
      </section>

      <section v-if="!live.hasElectricDrive && hasDifferentialData" class="card differentials-card">
        <h2>Differentials</h2>
        <DifferentialBlock label="Front differential" :data="live.frontDifferential" :hide-final-drive="live.isElectric" />
        <DifferentialBlock label="Center coupling" :data="live.centerCoupling" :hide-final-drive="live.isElectric" />
        <DifferentialBlock label="Rear differential" :data="live.rearDifferential" :hide-final-drive="live.isElectric" />
      </section>

      <section v-if="hasDrivetrainStatus" class="card">
        <h2>Drivetrain status</h2>
        <StatusRow v-if="isBoolean(live.clutchDamaged)" label="Clutch" :bad="live.clutchDamaged" :text="live.clutchDamaged ? 'Fault detected' : 'Normal'" />
        <StatusRow v-if="live.hasDrivingDynamicsControl" label="Vehicle stability control" :bad="stabilityControlDegraded" :text="stabilityControlDegraded ? 'Degraded' : 'Normal'" />
        <StatusRow v-if="maintenanceOnline" label="Transmission condition" :warn="Boolean(transmission.activeSymptom || recentTransmissionSymptom)" :text="transmissionConditionText" />
        <StatusRow v-if="hasClutchHeatEvent" label="Clutch heat event" :bad="clutchTemperatureHigh" :warn="!clutchTemperatureHigh" :text="clutchTemperatureHigh || clutchTemperatureElevated ? 'Temperature high' : 'Recently observed'" />
        <StatusRow v-if="live.recentTransmissionThermalStress && !transmissionThermalStressActive" label="Transmission heat" :warn="true" :text="`Recently observed — ${live.recentTransmissionThermalStress}`" />
        <div v-for="risk in diagnosticRisks(transmission.riskFlags, transmission, 'transmission')" :key="risk.key" class="risk" :class="risk.severity">
          <b>{{ diagnosticRiskLabel(risk) }}</b><span v-if="diagnosticRiskDetail(risk)">{{ diagnosticRiskDetail(risk) }}</span>
        </div>
      </section>
    </main>

    <footer v-if="!(tab === 'live' && proTunerEnabled)">Read-only vehicle diagnostics</footer>
    </template>
  </div>
</template>

<script setup>
import { HouseButton, HouseMenu, HouseSlider } from "../../components/house/index.js"

import { usePhoneAppFocus } from './controllerLayers.js'

import { nextTab } from '../../utils/controllerTabs.js'
import { vBngOnUiNav } from '@/common/directives'
import { BngSlider } from '@/common/components/base'
import MoneyAmount from "../../components/MoneyAmount.vue"
import { createObdPresentation } from './createObdPresentation.js'
import { computed, h, onBeforeUnmount, onMounted, ref, watch, onUnmounted } from "vue"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"
import { $translate } from "@/services/translation"
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { buildDiagnosticFindings } from "../../utils/obdScannerDiagnostics.js"
import { callModLuaIfAvailable } from "../../utils/installLuaBridgeFallbacks"

usePhoneAppFocus()

function changePhoneTab(direction, event) {
  if (tunerOpen.value) return true
  event?.stopPropagation()
  const next = nextTab(tabs, tab.value, direction)
  if (next) tab.value = next.id
}


const Metric = (props) => props.value === null || props.value === undefined || props.value === '' ? null : h('div', { class: ['metric', props.warn && 'warn', props.caution && 'caution'] }, [
  h('span', props.label), h('strong', props.value), props.unit ? h('small', props.unit) : null,
])
const Notice = (props, { slots }) => h('section', { class: 'notice' }, [h('b', props.title), h('p', slots.default?.())])
const StatusRow = props => h('div', { class: ['status-row', props.bad && 'bad', props.warn && 'warn'] }, [h('span', props.label), h('b', props.text)])
const DifferentialBlock = props => {
  const data = props.data
  if (!data?.name) return null
  const settings = [
    !props.hideFinalDrive && isNumber(data.finalDriveRatio) && ['Final drive', `${decimal(data.finalDriveRatio, 2)}:1`],
    isNumber(data.powerLockPercent) && ['Power lock', `${Math.round(data.powerLockPercent)}%`],
    isNumber(data.coastLockPercent) && ['Coast lock', `${Math.round(data.coastLockPercent)}%`],
    isNumber(data.preloadNm) && ['Preload', torque(data.preloadNm)],
  ].filter(Boolean)
  return h('div', { class: 'differential-block' }, [
    h('div', { class: 'differential-title' }, [h('span', props.label), h('strong', data.name)]),
    settings.length ? h('div', { class: 'differential-settings' }, settings.map(([label, value]) => h('span', [label, h('b', value)]))) : null,
  ])
}
DifferentialBlock.props = ['label', 'data', 'hideFinalDrive']

// Diagnostic copy follows the maintenance categories for this vehicle.

const { api, units } = useBridge()
const events = useEvents()
const tab = ref('live')
const live = ref({})
// Part names arrive as plain text or as {txt, ctx} translation objects (stock trucks
// name their engines "BRAND 900CUI I6 Diesel Engine" with the brand in ctx).
const partLabel = name => (name && typeof name === 'object' ? $translate.contextTranslate(name) : name) || null
const withPartLabels = (target, keys) => {
  if (!target || typeof target !== 'object') return target
  const next = { ...target }
  for (const key of keys) if (key in next) next[key] = partLabel(next[key])
  return next
}
function translatePartNames(data) {
  const next = withPartLabels(data, ['engineName', 'gearboxName', 'clutchName', 'flywheelName', 'forcedInductionName'])
  for (const key of ['frontDifferential', 'rearDifferential', 'centerCoupling', 'transferCase']) {
    if (next[key]) next[key] = withPartLabels(next[key], ['name'])
  }
  if (Array.isArray(next.motors)) {
    next.motors = next.motors.map(motor => withPartLabels(motor, ['name', 'reductionName', 'differentialName']))
  }
  return next
}
const tunerOpen = ref(false)
const purchasingProTuner = ref(false)
const proTuner = ref({ enabled: false })
const tuner = computed(() => proTuner.value || { enabled: false })
const proTunerEnabled = computed(() => tuner.value.enabled === true)
const proTunerUnlocked = computed(() => tuner.value.unlocked === true)
const canBuyProTuner = computed(() => proTunerEnabled.value && !proTunerUnlocked.value)
// BeamNG serializes an empty Lua table as an object. Keep every consumer on a
// predictable array while preserving populated motor arrays for EVs/hybrids.
const motors = computed(() => Array.isArray(live.value.motors) ? live.value.motors : [])
const maintenance = ref({})
const recentSymptoms = ref({})
const liveOnline = ref(false)
const displayVehicleName = ref(null)
const isWalking = ref(null)
let latestMaintenance = null
let maintenanceRevision = null
let liveRevision = null
let lastSeenAt = 0
let lastAppliedAt = -Infinity
let staleTimer
const liveUpdateIntervalMs = 100
const staleAfterMs = 2000

const liveDigits = {
  rpm: 0, engineRpm: 0, idleRpm: 0, ecuLimiterRpm: 0, peakPowerRpm: 0, maxRpm: 0,
  motorMaxRpm: 0, overrevThresholdRpm: 0, revLimiterCutTime: 3,
  fuel: 2, batteryCharge: 2, propulsionLoad: 2, engineLoad: 2, load: 2,
  recentMotorTorqueAvailability: 2, reductionRatios: 2, reductionRatio: 2,
  finalDriveRatio: 2, powerLockPercent: 0, coastLockPercent: 0,
}
const liveUnits = {
  coolantTemp: ['temperature', 0], oilTemp: ['temperature', 0],
  clutchTempC: ['temperature', 0], recentClutchHeatPeakC: ['temperature', 0],
  airPressurePa: ['pressure', 1, 0.001],
  turboBoostPsi: ['pressure', 2, 6.894757], wastegateStartPsi: ['pressure', 2, 6.894757],
  motorRestrictionRatedTorqueNm: ['torque', 0], motorTorqueLimitNm: ['torque', 0],
  ratedTorqueNm: ['torque', 0], torqueLimitNm: ['torque', 0],
  clutchRatedTorqueNm: ['torque', 0], clutchAvailableTorqueNm: ['torque', 0], preloadNm: ['torque', 0],
}

function roundLiveReadings(value, key = '') {
  if (Array.isArray(value)) return value.map(item => roundLiveReadings(item, key))
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, roundLiveReadings(item, name)]))
  }
  if (!Number.isFinite(value)) return value
  const unit = liveUnits[key]
  if (unit) {
    const [name, digits, scale = 1] = unit
    // Round in the player's units, then retain the source units for diagnostics.
    const offset = units[name](0).val
    const factor = units[name](1).val - offset
    return (Number(units[name](value * scale).val.toFixed(digits)) - offset) / factor / scale
  }
  return key in liveDigits ? Number(value.toFixed(liveDigits[key])) : value
}

function clearMaintenance() {
  if (maintenanceRevision === null) return
  maintenanceRevision = null
  maintenance.value = {}
  recentSymptoms.value = {}
}

const tabs = [
  { id: 'live', label: 'Overview' }, { id: 'engine', label: 'Engine' },
  { id: 'service', label: 'Service' }, { id: 'drive', label: 'Drivetrain' },
]

function maintenanceMatchesVehicle(incoming) {
  return incoming?.vehicleId == null || live.value.vehicleId == null
    || incoming.vehicleId === live.value.vehicleId
}

function applyMaintenance(incoming) {
  if (!incoming || !maintenanceMatchesVehicle(incoming)) return
  const revision = JSON.stringify([incoming.vehicleId, incoming.inventoryId, incoming.debugMeta?.builtAt, incoming.debugMeta?.buildCount])
  if (revision === maintenanceRevision) return
  maintenanceRevision = revision
  const observed = { ...recentSymptoms.value }
  for (const categoryName of ['engine', 'radiator', 'transmission']) {
    const symptom = incoming.categories?.[categoryName]?.activeSymptom
    if (symptom) observed[categoryName] = { symptom, observedAt: Date.now() / 1000 }
  }
  recentSymptoms.value = observed
  maintenance.value = incoming
}

useStreams(['obdScannerData', 'vehicleMaintenanceDebugData'], streams => {
  if (streams.obdScannerData) {
    const now = Date.now()
    lastSeenAt = now
    if (!liveOnline.value) liveOnline.value = true
    const changedVehicle = live.value.vehicleId !== streams.obdScannerData.vehicleId
    if (changedVehicle || now - lastAppliedAt >= liveUpdateIntervalMs) {
      lastAppliedAt = now
      if (changedVehicle) clearMaintenance()
      const next = roundLiveReadings(streams.obdScannerData)
      const revision = JSON.stringify(next)
      if (revision !== liveRevision) {
        liveRevision = revision
        live.value = translatePartNames(next)
      }
      if (next.maintenanceModeEnabled !== true) {
        clearMaintenance()
        if (next.maintenanceModeEnabled === false) latestMaintenance = null
      } else {
        applyMaintenance(latestMaintenance)
      }
    }
  }
  if (streams.vehicleMaintenanceDebugData && live.value.maintenanceModeEnabled !== false) {
    const incoming = streams.vehicleMaintenanceDebugData
    latestMaintenance = incoming
    if (live.value.maintenanceModeEnabled === true) applyMaintenance(incoming)
  }
})

function connectVehicle() {
  api.activeObjectLua("extensions.load('overhaulObdScanner'); overhaulObdScanner.requestState()")
  api.engineLua(`(function()
    local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() or false
    local vehicle = be:getPlayerVehicle(0)
    if walking or not vehicle then return {isWalking = walking, vehicleName = nil} end
    local data = core_vehicles.getModel(vehicle.JBeam)
    local model = data and data.model
    local name = model and string.format("%s %s", model.Brand or "", model.Name or "") or nil
    return {isWalking = false, vehicleName = name}
  end)()`, value => {
    isWalking.value = value?.isWalking !== false
    displayVehicleName.value = value?.vehicleName || null
    refreshProTuner()
  })
}
events.on('VehicleReset', connectVehicle)
events.on('VehicleChange', connectVehicle)
onMounted(() => {
  connectVehicle()
  staleTimer = setInterval(() => {
    const online = lastSeenAt > 0 && Date.now() - lastSeenAt < staleAfterMs
    if (liveOnline.value !== online) liveOnline.value = online
  }, 1000)
})
onBeforeUnmount(() => {
  clearInterval(staleTimer)
  clearTimeout(tunerWriteTimer)
})
watch(() => live.value.vehicleId, () => {
  refreshProTuner()
})

const engine = computed(() => maintenance.value.categories?.engine || {})
const radiator = computed(() => live.value.hasCoolingSystem === false ? {} : (maintenance.value.categories?.radiator || {}))
const transmission = computed(() => maintenance.value.categories?.transmission || {})
const {
  POWER_LIMIT_DEFINITIONS, DIAGNOSTIC_RISK_DEFINITIONS, SERVICE_ITEM_LABELS, SERVICE_DUE_DETAILS, TRANSMISSION_SYMPTOM_DEFINITIONS,
  ENGINE_SYMPTOM_DEFINITIONS, COOLING_SYMPTOM_DEFINITIONS, NATIVE_DAMAGE_DEFINITIONS, isNumber, isBoolean,
  decimal, whole, temperature, percent, clampPercent,
  power, torque, distanceMiles, ratioList, airPressure,
  boostPressure, serviceConditionSeverity, conditionColor, serviceItemColor, ageMiles,
  mileageWearPercent, mileageWearColor, categoryConditionSeverity, categoryConditionClass, categoryConditionState,
  highIsBadState, elevatedAbove, lowIsBadState, serviceItemLabel, dueMaintenanceItem,
  maintenanceAction, powerLimitAction, recentSymptom, activeSymptomText, conditionSymptomText,
  engineSymptomFinding, coolingSymptomFinding, transmissionSymptomFinding, nativeDamageFinding, friendlyFindingCause,
  friendlyTransmissionType, friendlyLimitReason, diagnosticRiskLabel, categoryFluid, ageFluidLossPresentation,
  wearSpikePresentation, diagnosticRisks, diagnosticRiskDetail, dueText,
} = createObdPresentation({ units, engine, radiator, transmission, recentSymptoms })


const ignitionOn = computed(() => isNumber(live.value.ignition) && live.value.ignition >= 2)
const scannerNeedsIgnition = computed(() => isWalking.value === false && liveOnline.value && !ignitionOn.value)
const scannerConnected = computed(() => isWalking.value === false && liveOnline.value && ignitionOn.value)
const connectionPresentation = computed(() => scannerConnected.value
  ? { eyebrow: 'CONNECTED VEHICLE', status: 'CONNECTED', noticeTitle: null, noticeText: null }
  : scannerNeedsIgnition.value
    ? { eyebrow: 'VEHICLE DETECTED', status: 'TURN IGNITION ON', noticeTitle: 'Scanner unavailable', noticeText: 'Turn the ignition on to communicate with the vehicle control modules.' }
    : isWalking.value
      ? { eyebrow: 'OBD SCANNER', status: 'ENTER VEHICLE', noticeTitle: 'No vehicle connected', noticeText: 'Enter a vehicle to connect the scanner.' }
      : { eyebrow: 'OBD SCANNER', status: 'WAITING', noticeTitle: 'Waiting for vehicle connection', noticeText: 'Waiting for vehicle data.' })
const maintenanceOnline = computed(() => live.value.maintenanceModeEnabled === true && Boolean(maintenance.value.categories))
const maintenanceUnavailableText = computed(() => live.value.maintenanceModeEnabled === false
  ? 'RLS Maintenance Mode is disabled for this career save. Native vehicle diagnostics remain available.'
  : 'Service information is still initializing or is not available for this vehicle.')
const vehicleTitle = computed(() => isWalking.value ? 'No vehicle connected' : displayVehicleName.value || live.value.vehicleName || (liveOnline.value ? 'Connected vehicle' : 'No connection'))
const ignitionText = computed(() => live.value.isHybrid
  ? (live.value.ignition == null ? null : live.value.ignition >= 2
      ? (live.value.generatorRunning ? 'Ready — generator running' : 'Ready — generator standby')
      : live.value.ignition > 0 ? 'Accessory' : 'Off')
  : live.value.isElectric
    ? (live.value.ignition == null ? null : live.value.ignition >= 2 ? 'Ready' : live.value.ignition > 0 ? 'Accessory' : 'Off')
    : (live.value.engineRunning === true ? 'Engine running' : live.value.ignition == null ? null : live.value.ignition >= 2 ? 'Ignition on' : live.value.ignition > 0 ? 'Accessory' : 'Off'))
// No reported scale means no bar. A gauge fill needs a real maximum from the vehicle,
// and an empty bar next to a live rpm reading reads as zero rather than as unknown.
const rpmScale = computed(() => {
  const motorMaximum = motors.value.reduce((maximum, motor) => Math.max(maximum, isNumber(motor.maxRpm) ? motor.maxRpm : 0), 0)
  const maximum = live.value.hasElectricDrive ? motorMaximum : live.value.ecuLimiterRpm
  return isNumber(maximum) && maximum > 0 ? maximum : null
})
const engineRpmScale = computed(() => isNumber(live.value.ecuLimiterRpm) && live.value.ecuLimiterRpm > 0
  ? live.value.ecuLimiterRpm
  : null)
const rpmPercent = computed(() => rpmScale.value
  ? Math.min(100, Math.max(0, live.value.rpm / rpmScale.value * 100))
  : 0)
// Amber past the engine's peak-power rpm, red while the rev limiter is cutting.
function engineRpmTone(rpm) {
  if (live.value.revLimiterActive === true) return 'hot'
  const peak = live.value.peakPowerRpm
  return isNumber(rpm) && isNumber(peak) && peak > 0 && rpm >= peak ? 'warn' : null
}
const engineRpmPercent = computed(() => engineRpmScale.value
  ? Math.min(100, Math.max(0, live.value.engineRpm / engineRpmScale.value * 100))
  : 0)
// Bands come from the engine's own thermostat and fan points and BeamNG's damage thresholds.
const coolantGauge = computed(() => {
  const limits = live.value.thermalLimits
  const value = live.value.coolantTemp
  if (!limits || !isNumber(value)) return null
  const tone = value >= limits.coolantDamageC ? 'hot' : value >= limits.fanC ? 'warn' : value < limits.warmC ? 'cold' : null
  return { tone, percent: Math.min(100, Math.max(0, value / limits.coolantMaxC * 100)) }
})
const oilGauge = computed(() => {
  const limits = live.value.thermalLimits
  const value = live.value.oilTemp
  if (!limits || !isNumber(value)) return null
  const tone = value >= limits.oilDamageC ? 'hot' : value >= limits.oilWarnC ? 'warn' : value < limits.warmC ? 'cold' : null
  return { tone, percent: Math.min(100, Math.max(0, value / limits.oilDamageC * 100)) }
})
const limiterStrategyText = computed(() => ({ timeBased: 'Timed cut', rpmDrop: 'RPM-drop cut' })[live.value.revLimiterType] || null)
const limiterCutDurationMs = computed(() => limiterStrategyText.value && isNumber(live.value.revLimiterCutTime) ? live.value.revLimiterCutTime * 1000 : null)
const hasEcuCalibration = computed(() => isNumber(live.value.idleRpm) || isNumber(live.value.ecuLimiterRpm) || Boolean(limiterStrategyText.value) || isNumber(live.value.wastegateStartPsi))
const pistonRingsDamaged = computed(() => live.value.pistonRingsDamaged || engine.value.pistonRingsDamaged)
function createServiceEstimateSmoother() {
  let previousVehicle
  let previousValues = new Map()
  let previousTime = null
  let estimate = null

  return (vehicleId, items, now) => {
    const values = new Map(items.map(item => [item.key, item.value]))
    const due = items.map(item => item.dueMiles).filter(Number.isFinite)
    const current = due.length ? Math.max(0, Math.min(...due)) : null
    // Service restores condition; load changes only alter the distance prediction.
    const serviced = items.some(item => Number.isFinite(item.value)
      && Number.isFinite(previousValues.get(item.key))
      && item.value > previousValues.get(item.key))
    const changedItems = values.size !== previousValues.size
      || [...values.keys()].some(key => !previousValues.has(key))

    if (vehicleId !== previousVehicle || changedItems || serviced
      || current === null || current === 0 || estimate === null || estimate === 0) {
      estimate = current
    } else {
      const elapsed = Math.max(0, now - previousTime)
      const weight = 1 - Math.exp(-elapsed / 25000)
      estimate += (current - estimate) * weight
    }
    previousVehicle = vehicleId
    previousValues = values
    previousTime = now
    return estimate
  }
}

const smoothServiceEstimate = createServiceEstimateSmoother()
const nextServiceMiles = ref(null)
const nextServiceText = computed(() => nextServiceMiles.value === null
  ? null
  : nextServiceMiles.value <= 0 ? 'Service due now' : distanceMiles(nextServiceMiles.value))
const motorTorqueAvailability = computed(() => isNumber(live.value.motorRestrictionRatedTorqueNm) && live.value.motorRestrictionRatedTorqueNm > 0 && isNumber(live.value.motorTorqueLimitNm)
  ? Math.min(1, Math.max(0, live.value.motorTorqueLimitNm / live.value.motorRestrictionRatedTorqueNm))
  : null)
const hasMeasuredMotorRestriction = computed(() => isNumber(motorTorqueAvailability.value) && motorTorqueAvailability.value < 0.90)
const recentMotorTorqueAvailability = computed(() => isNumber(live.value.recentMotorTorqueAvailability)
  ? Math.min(1, Math.max(0, live.value.recentMotorTorqueAvailability))
  : null)
// Combustion torque-hold sets powerCapActive for any trim below 99.5%, including the
// ~5% service cap on a healthy generator. The manager already ignores that unless
// outputRestrictionDiagnostic (named fault or availability < 0.90). Hybrids used to
// treat the raw flag as a live propulsion and engine fault.
const motorOutputRestricted = computed(() => live.value.hasElectricDrive && (
  hasMeasuredMotorRestriction.value
  || radiator.value.liveMetrics?.powerLimitActive === true
))
const motorRestrictionNeedsAttention = computed(() => motorOutputRestricted.value
  && hasMeasuredMotorRestriction.value && motorTorqueAvailability.value < 0.9)
const motorOutputText = computed(() => motorOutputRestricted.value
  ? (hasMeasuredMotorRestriction.value ? `Reduced — ${percent(motorTorqueAvailability.value)} available` : 'Reduced')
  : 'Normal')
const motorUnavailable = computed(() => live.value.hasElectricDrive && live.value.motorDisabled === true && live.value.motorBroken !== true && live.value.motorHasEnergy === true)
const enginePowerLimited = computed(() => engine.value.outputRestrictionDiagnostic === true)
const powerLimited = computed(() => enginePowerLimited.value || radiator.value.liveMetrics?.powerLimitActive === true)
const powerLimitReason = computed(() => {
  const cooling = radiator.value.liveMetrics?.powerLimitActive === true
  return cooling ? radiator.value.liveMetrics?.powerLimitReason : engine.value.liveMetrics?.powerLimitReason
})
const powerLimitText = computed(() => powerLimited.value
  ? friendlyLimitReason(powerLimitReason.value)
  : 'None')
const recentEngineRestrictionObservation = computed(() => live.value.recentEngineRestriction || null)
const roughnessState = computed(() => elevatedAbove(engine.value.liveMetrics?.roughnessCoef, 1.25))
const idleStabilityText = computed(() => ({ unstable: 'Unstable — may stall', rough: 'Rough idle' })[live.value.idleStability]
  || (live.value.recentIdleStall === true ? 'Recently observed — stalled at idle' : 'Normal'))
const misfireState = computed(() => highIsBadState(engine.value.liveMetrics?.ignitionErrorChance, 0.01, 0.02))
const shiftQualityState = computed(() => lowIsBadState(transmission.value.liveMetrics?.shiftSpeedCoef ?? transmission.value.shiftSpeedCoef, 0.88, 0.78))
const clutchWearState = computed(() => highIsBadState(
  transmission.value.liveMetrics?.clutchFreePlayCoef ?? transmission.value.clutchFreePlayCoef,
  1.3, 1.7
))
const clutchTemperatureHigh = computed(() => isNumber(live.value.clutchTempC) && isNumber(live.value.clutchMaxSafeTempC)
  && live.value.clutchTempC >= live.value.clutchMaxSafeTempC)
const clutchTemperatureElevated = computed(() => !clutchTemperatureHigh.value && isNumber(live.value.clutchTempC)
  && isNumber(live.value.clutchWarningTempC) && live.value.clutchTempC >= live.value.clutchWarningTempC)
const recentTransmissionSymptom = computed(() => transmission.value.activeSymptom
  ? null
  : recentSymptom(transmission.value, 'transmission'))
const recentEngineSymptom = computed(() => engine.value.activeSymptom
  ? null
  : recentSymptom(engine.value, 'engine'))
const recentCoolingSymptom = computed(() => radiator.value.activeSymptom
  ? null
  : recentSymptom(radiator.value, 'radiator'))
const engineConditionText = computed(() => conditionSymptomText(
  engine.value.activeSymptom,
  recentEngineSymptom.value,
  ENGINE_SYMPTOM_DEFINITIONS,
  activeSymptomText(engine.value),
))
const coolingConditionText = computed(() => conditionSymptomText(
  radiator.value.activeSymptom,
  recentCoolingSymptom.value,
  COOLING_SYMPTOM_DEFINITIONS,
  radiator.value.activeSymptomLabel,
))
const transmissionConditionText = computed(() => {
  const active = transmission.value.activeSymptom
  if (active) return TRANSMISSION_SYMPTOM_DEFINITIONS[active]?.label || activeSymptomText(transmission.value)
  const recent = recentTransmissionSymptom.value
  return recent ? `Recently observed — ${TRANSMISSION_SYMPTOM_DEFINITIONS[recent]?.label || 'transmission condition'}` : 'Normal'
})
const recentClutchHeatObserved = computed(() => isNumber(live.value.recentClutchHeatPeakC))
const hasClutchHeatEvent = computed(() => clutchTemperatureHigh.value || clutchTemperatureElevated.value || recentClutchHeatObserved.value)
const transmissionThermalStressActive = computed(() => diagnosticRisks(transmission.value.riskFlags)
  .some(risk => risk.key === 'transmission_heat' || risk.key === 'transmission_overheat'))
const nativeDamageEvents = computed(() => Array.isArray(live.value.recentDamageEvents)
  ? live.value.recentDamageEvents
  : Object.values(live.value.recentDamageEvents || {}))
const nativeDamageActive = (group, name) => nativeDamageEvents.value.some(event => event.group === group && event.name === name && event.active === true)
const nativeDamageRecent = (group, name) => nativeDamageEvents.value.some(event => event.group === group && event.name === name && event.active === false)
const turboHotActive = computed(() => nativeDamageActive('engine', 'turbochargerHot'))
const inductionDamageActive = computed(() => nativeDamageActive('engine', 'inductionSystemDamaged'))
const turboHotRecent = computed(() => nativeDamageRecent('engine', 'turbochargerHot'))
const inductionDamageRecent = computed(() => nativeDamageRecent('engine', 'inductionSystemDamaged'))
const forcedInductionStatusText = computed(() => {
  if (inductionDamageActive.value) return 'Fault detected'
  if (turboHotActive.value) return 'Temperature high'
  if (inductionDamageRecent.value) return 'Recently observed — fault'
  if (turboHotRecent.value) return 'Recently observed — temperature high'
  return 'Normal'
})
const pressureTankLeakActive = computed(() => nativeDamageActive('pressureTank', 'deformationLeak') || nativeDamageActive('pressureTank', 'breakLeak'))
const stabilityControlDegraded = computed(() => nativeDamageActive('drivingDynamics', 'systemStateDegraded'))
const fuelSystem = computed(() => live.value.fuelSystem && typeof live.value.fuelSystem === 'object' ? live.value.fuelSystem : null)
const fuelMonitored = computed(() => fuelSystem.value?.monitored === true)
const fuelAlerts = computed(() => fuelSystem.value?.alerts || {})
// Knock getting through is a fault; protection retard holding it off is only a warning.
const fuelKnockDetected = computed(() => fuelAlerts.value.knock === true)
const fuelKnockHeld = computed(() => !fuelKnockDetected.value && fuelAlerts.value.knockRetard === true)
// The PRO card prefers the last full-load pull: at idle, where the phone can be
// used, the tune does not apply and every map reads the same.
const fuelPull = computed(() => {
  const pull = fuelSystem.value?.lastPull
  return pull && typeof pull === 'object' ? pull : null
})
const fuelCard = computed(() => {
  const pull = fuelPull.value
  if (pull) {
    const retard = Number(pull.peakRetardDeg) || 0
    return { afr: pull.afr, targetAFR: pull.targetAFR, lambda: pull.lambda, targetLambda: pull.targetLambda, retard, duty: pull.peakDuty,
      mixtureBad: pull.lean === true || pull.rich === true, knock: pull.knock === true,
      held: pull.knock !== true && retard > 0.25, limited: Number(pull.peakDuty) >= 1 }
  }
  const fuel = fuelSystem.value || {}
  return { afr: fuel.afr, targetAFR: fuel.targetAFR, lambda: fuel.lambda, targetLambda: fuel.targetLambda, retard: fuel.knockRetardDeg, duty: fuel.deliveryDuty,
    mixtureBad: fuelMixtureBad.value, knock: fuelKnockDetected.value, held: fuelKnockHeld.value, limited: fuelDeliveryLimited.value }
})
const fuelCardRetardNote = computed(() => {
  if (fuelSystem.value?.knockControl !== true) return fuelCard.value.knock ? 'Knock, no protection' : 'No knock protection'
  if (fuelCard.value.knock) return 'Knock past protection'
  return fuelCard.value.held ? 'Active' : 'None'
})
const fuelPullNote = computed(() => {
  const pull = fuelPull.value
  if (!pull) return 'Live estimates. A full-throttle pull records mixture and delivery under load.'
  const cut = pull.boostCut === true ? '; boost cut active' : ''
  const seconds = Math.max(0, Math.round(Number(pull.secondsAgo) || 0))
  const age = seconds < 60 ? `${seconds} s ago` : `${Math.round(seconds / 60)} min ago`
  const rpm = Number(pull.rpm)
  return Number.isFinite(rpm) ? `Full load up to ${Math.round(rpm)} rpm; recorded ${age}${cut}` : `Full load; recorded ${age}${cut}`
})
const fuelMixtureBad = computed(() => fuelAlerts.value.lean === true || fuelAlerts.value.rich === true)
const fuelDeliveryLimited = computed(() => fuelAlerts.value.deliveryLimited === true)
const fuelMixtureText = computed(() => fuelAlerts.value.lean === true ? 'Lean' : fuelAlerts.value.rich === true ? 'Rich' : 'On target')
// Engine rows: a live fault is red; otherwise the last full-load pull shows as a
// past warning, since the phone only opens when the tune no longer applies.
const fuelMixtureRow = computed(() => {
  if (fuelMixtureBad.value) return { bad: true, text: fuelMixtureText.value }
  const pull = fuelPull.value
  if (pull?.lean === true) return { warn: true, text: 'Lean on last pull' }
  if (pull?.rich === true) return { warn: true, text: 'Rich on last pull' }
  return { text: 'On target' }
})
const fuelKnockRow = computed(() => {
  if (fuelKnockDetected.value) return { bad: true, text: 'Detected' }
  if (fuelKnockHeld.value) return { warn: true, text: 'Held off by protection' }
  const pull = fuelPull.value
  if (pull?.knock === true) return { warn: true, text: 'Knock on last pull' }
  if (pull && Number(pull.peakRetardDeg) > 0.25) return { warn: true, text: 'Held off on last pull' }
  return { text: 'Normal' }
})
const fuelDeliveryRow = computed(() => {
  if (fuelDeliveryLimited.value) return { bad: true, text: 'At limit' }
  const duty = Number(fuelPull.value?.peakDuty)
  if (duty >= 1) return { warn: true, text: `Over limit on last pull (${Math.round(duty * 100)}%)` }
  return { text: 'Normal' }
})
function fuelAkiText(value) {
  const n = Number(value)
  return Number.isFinite(n) ? `${Math.round(n)} AKI` : null
}
const fuelRequirementText = computed(() => {
  if (!fuelMonitored.value || fuelSystem.value?.fuelType==='diesel') return null
  const aki = fuelAkiText(fuelSystem.value?.requiredAki)
  if (!aki) return null
  return fuelSystem.value.requirementEstimated === true ? `${aki} (estimated)` : aki
})
const fuelOctaneText = computed(() => {
  if (!fuelMonitored.value || fuelSystem.value?.fuelType==='diesel' || fuelSystem.value?.fuelInUse === 'Empty') return null
  return fuelAkiText(fuelSystem.value?.fuelAki)
})
function fuelDecimal(value, digits) {
  const n = value == null ? NaN : Number(value)
  return Number.isFinite(n) ? n.toFixed(digits) : '--'
}
const fuelCardText = computed(() => {
  const card = fuelCard.value
  const target = fuelDecimal(card.targetAFR, 2)
  const retard = fuelDecimal(card.retard, 1)
  const duty = Number(card.duty)
  return {
    afr: fuelDecimal(card.afr, 2),
    target: target === '--' ? 'target unavailable' : `target ${target}`,
    retard: retard === '--' ? '--' : `${retard}°`,
    duty: Number.isFinite(duty) ? `${Math.round(duty * 100)}%` : '--',
  }
})
const diagnosticFindings = computed(() => buildDiagnosticFindings({
  live: live.value,
  engine: engine.value,
  radiator: radiator.value,
  transmission: transmission.value,
  recentSymptoms: recentSymptoms.value,
  pistonRingsDamaged: pistonRingsDamaged.value,
  motorUnavailable: motorUnavailable.value,
  motorOutputRestricted: motorOutputRestricted.value,
  motorRestrictionNeedsAttention: motorRestrictionNeedsAttention.value,
  hasMeasuredMotorRestriction: hasMeasuredMotorRestriction.value,
  motorTorqueAvailability: motorTorqueAvailability.value,
  recentMotorTorqueAvailability: recentMotorTorqueAvailability.value,
  recentEngineRestriction: recentEngineRestrictionObservation.value,
  powerLimited: powerLimited.value,
  powerLimitReason: powerLimitReason.value,
  clutchTemperatureHigh: clutchTemperatureHigh.value,
  clutchTemperatureElevated: clutchTemperatureElevated.value,
  isNumber,
  percent,
  temperature,
  airPressure,
  nativeDamageFinding,
  friendlyFindingCause,
  powerLimitAction,
  maintenanceAction,
  activeSymptomText,
  recentSymptom,
  engineSymptomFinding,
  coolingSymptomFinding,
  transmissionSymptomFinding,
}))
const hasActiveFault = computed(() => diagnosticFindings.value.some(finding => finding.attention !== false))
const hasRecentFinding = computed(() => diagnosticFindings.value.some(finding => finding.recent === true))
const diagnosticStatusText = computed(() => hasActiveFault.value
  ? 'Attention required'
  : (hasRecentFinding.value
      ? 'Recent event observed'
      : (diagnosticFindings.value.length ? 'Advisory' : (liveOnline.value ? 'No issues detected' : null))))
const transmissionType = computed(() => friendlyTransmissionType(live.value.gearboxType))
const gearboxDisplayName = computed(() => live.value.gearboxName || (
  isNumber(live.value.forwardGearCount) && transmissionType.value
    ? `${whole(live.value.forwardGearCount)}-speed ${transmissionType.value}`
    : transmissionType.value
))
const hasDifferentialData = computed(() => Boolean(live.value.frontDifferential?.name || live.value.centerCoupling?.name || live.value.rearDifferential?.name))
const transferCaseCurrentMode = computed(() => [
  live.value.transferCase?.currentDriveMode,
  live.value.transferCase?.currentRangeMode,
].filter(Boolean).join(' ') || null)
const driveLayout = computed(() => {
  const motorPositions = motors.value.map(motor => motor.position || '')
  const hasFrontMotor = motorPositions.some(position => position.startsWith('Front'))
  const hasRearMotor = motorPositions.some(position => position.startsWith('Rear'))
  if (hasFrontMotor && hasRearMotor) return 'All-wheel drive'
  if (hasFrontMotor) return 'Front-wheel drive'
  if (hasRearMotor) return 'Rear-wheel drive'
  return live.value.frontDifferential?.name && live.value.rearDifferential?.name
  ? 'All-wheel drive'
  : live.value.frontDifferential?.name
    ? 'Front-wheel drive'
    : live.value.rearDifferential?.name
      ? 'Rear-wheel drive'
      : null
})
const hasClutchData = computed(() => Boolean(live.value.clutchName)
  || isNumber(live.value.clutchRatedTorqueNm)
  || isNumber(live.value.clutchAvailableTorqueNm)
  || isBoolean(live.value.clutchDamaged))
const hasDrivetrainStatus = computed(() => isBoolean(live.value.clutchDamaged) || Boolean(
  maintenanceOnline.value
) || diagnosticRisks(transmission.value.riskFlags).length > 0 || live.value.hasDrivingDynamicsControl === true)
const maintenanceCategories = computed(() => [
  { key: 'engine', label: 'Engine', data: engine.value },
  { key: 'radiator', label: 'Cooling', data: radiator.value },
  { key: 'transmission', label: 'Transmission', data: transmission.value },
].filter(category => category.data.hardwareInstalled !== false)
  .filter(category => category.key !== 'radiator' || live.value.hasCoolingSystem !== false))

watch(() => [live.value.vehicleId, maintenanceCategories.value], ([vehicleId, categories]) => {
  const items = categories.flatMap(category => (category.data.maintenanceItems || []).map(item => ({
    key: `${category.key}:${item.name}`,
    value: item.value,
    dueMiles: item.dueMiles ?? item.serviceDueMilesRemaining,
  })))
  nextServiceMiles.value = smoothServiceEstimate(vehicleId, items, performance.now())
}, { immediate: true })

// Unit labels retain the active bridge's unit preferences.

function closeTuner() {
  tunerOpen.value = false
}

function onBack() {
  if (tunerOpen.value) {
    closeTuner()
    return true
  }
  return false
}

const fuelEngine=ref(''),fuelWriting=ref(false),fuelWriteMessage=ref('');
// Boost cut sits with the fuel boost offsets once a garage per-gear/map boost is active.
const fuelBoostActive=computed(()=>!!(fuelControl.value?.boost && fuelControl.value.boost.mode!=='original' && fuelControl.value.boostSupported!==false));
const boostCutInFuelCard=computed(()=>proTunerUnlocked.value&&fuelBoostActive.value);
function fuelDutyText(value){return isNumber(value)?Math.round(value*100)+'%':'—'}
function fuelSigned(value,digits){const n=Number(value)||0;return `${n>0?'+':''}${n.toFixed(digits)}`}
const fuelControl=computed(()=>{const list=Array.isArray(tuner.value.fuelControls)?tuner.value.fuelControls:[];const e=list.find(e=>e.engine===fuelEngine.value)||list[0];if(!e)return;const f=fuelSystem.value;return f?.engine===e.engine && live.value.vehicleId===e.vehicleId?{...e,afr:f.afr,targetAFR:f.targetAFR,injectorDuty:f.injectorDuty,pumpDuty:f.pumpDuty,boostTargetPsi:f.boostTargetPsi}:e});
let fuelWriteTimeout,fuelWriteContext;
async function writeFuelControl(changes){
  if(fuelWriting.value||!fuelControl.value)return;
  fuelWriting.value=true;fuelWriteMessage.value='Waiting for engine confirmation';
  const e=fuelControl.value;fuelWriteContext={vehicleId:e.vehicleId,generation:e.generation,engine:e.engine,revision:e.revision};
  try{const result=await callModLuaIfAvailable('overhaul_vehicles_obdScanner.setProTunerFuel',changes,{vehicleId:e.vehicleId,generation:e.generation,revision:e.revision,engine:e.engine});
    if(!result?.ok){fuelWriting.value=false;fuelWriteMessage.value=result?.message||'Change not accepted';await refreshProTuner();return}
    if(!fuelWriting.value)return;
    fuelWriteTimeout=setTimeout(()=>{fuelWriting.value=false;fuelWriteMessage.value='Confirmation delayed. Refreshing installed state.';refreshProTuner()},4000);
  }catch(err){fuelWriting.value=false;fuelWriteMessage.value='Unable to apply tune';}
}
function writeGearOffset(i,event){const n=Number(event.target.value);if(event.target.value===''||!Number.isFinite(n)||Math.abs(n)>30){event.target.value=fuelControl.value.boost.offsets[i];return}const offsets=[...fuelControl.value.boost.offsets];offsets[i]=n;writeFuelControl({gearOffsets:offsets})}
function onFuelTrimResult(result){if(!fuelWriteContext||['vehicleId','generation','engine','revision'].some(k=>result[k]!==fuelWriteContext[k]))return;fuelWriteContext=null;clearTimeout(fuelWriteTimeout);fuelWriting.value=false;fuelWriteMessage.value=result.ok?'Applied to engine':result.message||'Change rejected';refreshProTuner()}
events.on('RlsFuelLiveTrimResult',onFuelTrimResult);
onUnmounted(()=>{events.off('RlsFuelLiveTrimResult',onFuelTrimResult);clearTimeout(fuelWriteTimeout)});

let tunerReadGeneration=0;
watch([() => fuelMonitored.value, () => live.value.vehicleId, () => fuelSystem.value?.engine], ([ready]) => {
  if (ready) refreshProTuner()
});
async function refreshProTuner() {
  const readGeneration=++tunerReadGeneration;
  const state = await callModLuaIfAvailable("overhaul_vehicles_obdScanner.getProTunerState")
  if(readGeneration!==tunerReadGeneration)return;
  proTuner.value = state && typeof state === "object" ? state : { enabled: false }
  if (proTuner.value.enabled !== true) tunerOpen.value = false
}

async function openTuner() {
  await refreshProTuner()
  if (proTuner.value.enabled === true) tunerOpen.value = true
}

async function purchaseProTuner() {
  if (!canBuyProTuner.value || purchasingProTuner.value) return
  purchasingProTuner.value = true
  try {
    const state = await callModLuaIfAvailable("overhaul_vehicles_obdScanner.purchaseProTunerLicense")
    if (state && typeof state === "object") proTuner.value = state
  } finally {
    purchasingProTuner.value = false
  }
}

let tunerWriteTimer
function onTunerInput(nextValue) {
  const value = Number(nextValue)
  proTuner.value = { ...proTuner.value, value }
  clearTimeout(tunerWriteTimer)
  tunerWriteTimer = setTimeout(() => writeTunerValue(value), 80)
}

async function writeTunerValue(value) {
  if (proTuner.value.unlocked !== true) return
  const state = await callModLuaIfAvailable("overhaul_vehicles_obdScanner.setProTunerValue", value)
  if (state && typeof state === "object") proTuner.value = state
}

// Boost cut is stored as psi above factory boost, shared with Fuel & Ignition.
const boostCutPreview = ref(null)
const boostCut = computed(() => {
  const cut = tuner.value.available ? tuner.value.boostCut : null
  return cut && isNumber(cut.factoryPsi) && isNumber(cut.marginPsi) ? cut : null
})
const boostCutMargin = computed(() => boostCutPreview.value ?? boostCut.value?.marginPsi)
const boostCutText = computed(() => boostCut.value ? formatTunePressure(boostCut.value.factoryPsi + boostCutMargin.value, 'psi') : null)
// Where the cut sits on the boost slider's scale (offset or absolute).
const boostCutMarker = computed(() => {
  const cut = boostCut.value
  if (!cut || !isNumber(cut.markerValue)) return null
  return cut.markerValue + (boostCutMargin.value - cut.marginPsi)
})
const boostCutReached = computed(() => isNumber(boostCutMarker.value) && isNumber(tuner.value.value) && tuner.value.value >= boostCutMarker.value)

function boostCutBoundText(margin) {
  return boostCut.value ? formatTunePressure(boostCut.value.factoryPsi + margin, 'psi') : null
}

function onBoostCutInput(event) {
  boostCutPreview.value = Number(event.target.value)
}

async function onBoostCutChange(event) {
  const margin = Number(event.target.value)
  boostCutPreview.value = margin
  try {
    const state = await callModLuaIfAvailable("overhaul_vehicles_obdScanner.setProTunerBoostCut", margin)
    if (state && typeof state === "object") proTuner.value = state
  } finally {
    boostCutPreview.value = null
  }
}

function formatTunePressure(value, unit) {
  if (!isNumber(value)) return null
  const normalized = String(unit || "psi").toLowerCase()
  // Wastegate settings are authored in psi; show them in the player's pressure unit.
  if (normalized === "psi") return units?.buildString ? units.buildString('pressure', value * 6.894757, 2) : `${decimal(value, 1)} psi`
  if (normalized === "bar") return `${decimal(value, 2)} bar`
  return unit ? `${decimal(value, 1)} ${unit}` : decimal(value, 1)
}

function tunerBoundText(value) {
  return formatTunePressure(value, tuner.value.unit)
}

function moneyText(amount) {
  const value = Number(amount)
  if (!Number.isFinite(value)) return "0"
  return Math.round(value).toLocaleString()
}

const proTunerPriceText = computed(() => moneyText(tuner.value.price))
const proTunerOfferText = "Live tuning software."
const proTunerRowSubtext = computed(() => {
  if (proTunerUnlocked.value) return "By Kapoow Racing"
  if (canBuyProTuner.value) return "Get the Kapoow Racing license"
  return "By Kapoow Racing"
})
const tunerLockText = computed(() => tuner.value.reason || proTunerOfferText)

const tunerValueText = computed(() => formatTunePressure(tuner.value.value, tuner.value.unit))
const tunerSliderColor = computed(() => {
  const min = tuner.value.min
  const max = tuner.value.max
  const value = tuner.value.value
  if (boostCutReached.value) return 'var(--red)'
  if (!isNumber(min) || !isNumber(max) || !isNumber(value) || max === min) return 'var(--green)'
  const amount = Math.max(0, Math.min(1, (value - min) / (max - min)))
  const green = [80, 227, 164]
  const amber = [255, 190, 85]
  const channel = index => Math.round(green[index] + (amber[index] - green[index]) * amount)
  return `rgb(${channel(0)}, ${channel(1)}, ${channel(2)})`
})
const latestPull = computed(() => {
  const pulls = tuner.value.recentPulls
  if (Array.isArray(pulls) && pulls[0]) return pulls[0]
  if (pulls && typeof pulls === "object") {
    return Object.values(pulls).find(pull => pull && typeof pull === "object") || null
  }
  return null
})
function pullDateText(pull) {
  const savedAt = Number(pull?.savedAt)
  if (!Number.isFinite(savedAt) || savedAt <= 0) return null
  return new Date(savedAt * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
}
function pullRpmAtText(rpm) {
  const value = Math.round(Number(rpm) || 0)
  return value > 0 ? `at ${whole(value)} rpm` : 'RPM unavailable'
}
function pullQualityFlags(pull) {
  const flags = pull?.qualityFlags
  if (Array.isArray(flags)) return flags.filter(Boolean)
  if (flags && typeof flags === "object") {
    return Object.keys(flags).filter(flag => flags[flag])
  }
  return []
}
function pullQualityLabel(pull) {
  if (!pull) return '--'
  if (pull.valid === false || pull.pullQuality === 'invalid') return 'Invalid'
  if (pull.pullQuality === 'warning' || pullQualityFlags(pull).length) return 'Warning'
  return 'Clean'
}
function pullQualityClass(pull) {
  const label = pullQualityLabel(pull)
  if (label === 'Invalid') return 'bad'
  if (label === 'Warning') return 'warn'
  return null
}
function pullSampleText(pull) {
  const accepted = Math.max(0, Math.round(Number(pull?.acceptedSampleCount) || 0))
  const rejected = Math.max(0, Math.round(Number(pull?.rejectedSampleCount) || 0))
  return `${accepted} accepted / ${rejected} rejected`
}
function pullCurve(pull) {
  const curve = pull?.curve
  if (Array.isArray(curve)) return curve
  if (curve && typeof curve === "object") {
    return Object.values(curve).filter(point => point && typeof point === "object")
  }
  return []
}
const latestGraphScale = computed(() => {
  const points = pullCurve(latestPull.value)
  if (!points.length) return { minRpm: 1000, maxRpm: 1500, maxValue: 1 }
  const minRpm = 1000
  const maxRpm = Math.max(minRpm + 500, Math.ceil(Math.max(...points.map(point => Number(point.rpm) || 0)) / 500) * 500)
  const maxValue = Math.max(...points.flatMap(point => [Number(point.power) || 0, Number(point.torque) || 0]), 1)
  return { minRpm, maxRpm, maxValue }
})
function pointsForLatestCurve(valueKey) {
  const curve = pullCurve(latestPull.value)
  const scale = latestGraphScale.value
  if (!curve.length) return ''
  const rpmRange = Math.max(scale.maxRpm - scale.minRpm, 1)
  return curve.map(point => {
    const x = ((Math.max(scale.minRpm, Number(point.rpm) || 0) - scale.minRpm) / rpmRange) * 300 + 10
    const y = 110 - ((Number(point[valueKey]) || 0) / scale.maxValue) * 100
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}
const latestPowerCurvePoints = computed(() => pointsForLatestCurve('power'))
const latestTorqueCurvePoints = computed(() => pointsForLatestCurve('torque'))
function graphRpmLabel(rpm) {
  const value = Number(rpm) || 0
  if (value >= 1000 && value % 1000 === 0) return `${value / 1000}k`
  if (value >= 1000) return `${(value / 1000).toFixed(1)}k`
  return String(Math.round(value))
}
usePhoneScreen({ onBack: onBack })
</script>

<style scoped>
.scanner{--bg:#0b1118;--card:#131d27;--line:#263541;--text:#eef5f3;--muted:#91a3aa;--green:#50e3a4;--amber:#ffbe55;--red:#ff6673;--blue:#5aa9ff;height:100%;overflow-y:auto;overscroll-behavior:contain;padding:3.2rem 14px 28px;background:var(--bg);color:var(--text);font-family:Inter,Arial,sans-serif;box-sizing:border-box}.hero{display:flex;align-items:center;justify-content:space-between;padding:6px 2px 14px}.eyebrow{font-size:9px;letter-spacing:.16em;color:var(--muted);font-weight:800}.eyebrow.caution{color:var(--amber)}.hero h1{font-size:20px;line-height:1.15;margin:4px 0 0;max-width:210px}.status{font-size:8px;font-weight:900;letter-spacing:.08em;color:var(--muted);border:1px solid var(--line);border-radius:99px;padding:6px 7px}.status.online,.eyebrow:not(.caution){color:var(--green)}.status.online{border-color:#287a5a;background:#10271f}.status.caution{color:var(--amber);border-color:#7c5d28;background:#271f10}.tabs{display:grid;grid-template-columns:repeat(4,1fr);gap:4px;padding:4px;background:#111a23;border-radius:11px;margin-bottom:10px}.tabs button{border:0;background:transparent;color:var(--muted);font-size:9px;font-weight:700;padding:8px 2px;border-radius:8px}.tabs button.active{background:#263541;color:white}.gauges{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:8px}.gauge,.card,.notice{background:var(--card);border:1px solid var(--line);border-radius:13px}.gauge{padding:12px}.gauge span,:deep(.metric span){display:block;color:var(--muted);font-size:10px}.gauge strong{display:inline-block;font-size:25px;margin-top:5px}.gauge small,:deep(.metric small){color:var(--muted);font-size:9px;margin-left:5px}.bar,.service-bar{height:5px;border-radius:5px;background:#263541;overflow:hidden;margin-top:8px}.bar i,.service-bar i{display:block;height:100%;background:var(--green);border-radius:inherit}.bar i.cold{background:var(--blue)}.bar i.warn{background:var(--amber)}.bar i.hot{background:var(--red)}.gauge:last-child:nth-child(odd){grid-column:span 2}.card{padding:12px;margin-bottom:8px}.grid{display:grid;grid-template-columns:1fr 1fr;padding:0}.metric{min-height:64px;padding:11px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);box-sizing:border-box}.metric:nth-child(even){border-right:0}.metric:nth-last-child(-n+2){border-bottom:0}.metric:nth-last-child(2):nth-child(even){border-bottom:1px solid var(--line)}.metric:last-child:nth-child(odd){grid-column:span 2;border-right:0}:deep(.metric strong){font-size:15px;display:inline-block;margin-top:7px}.metric.caution :deep(strong){color:var(--amber)}.metric.warn :deep(strong){color:var(--red)}.card h2,.card-title{font-size:12px;margin:0 0 10px;font-weight:800}.card-title{display:flex;justify-content:space-between;align-items:center}:deep(.notice p){font-size:9px;line-height:1.45;color:var(--muted);margin:8px 0 0}.status-row{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-top:1px solid var(--line);font-size:10px}:deep(.status-row b){text-align:right;color:var(--green)}.status-row.warn :deep(b){color:var(--amber)}.status-row.bad :deep(b){color:var(--red)}.notice{padding:13px;margin-bottom:8px;border-color:#5d4b2c;background:#211c14}:deep(.notice b){font-size:11px;color:var(--amber)}.mileage-wear{padding:2px 0 12px;border-bottom:1px solid var(--line)}.mileage-wear>div:first-child{display:flex;justify-content:space-between;font-size:10px}.mileage-wear small{display:block;color:var(--muted);font-size:8px;margin-top:6px}.service-heading{color:var(--muted);font-size:8px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;margin:12px 0 3px}.service-item{margin:11px 0}.service-item>div:first-child{display:flex;justify-content:space-between;font-size:10px}.service-item small{display:block;color:var(--muted);font-size:8px;margin-top:4px}.service-bar i.warn-text{background:var(--amber)}.service-bar i.bad-text{background:var(--red)}.service-bar i.neutral-text{background:var(--muted)}.good-text{color:var(--green)}.warn-text{color:var(--amber)}.bad-text{color:var(--red)}.neutral-text{color:var(--muted)}.risk{display:flex;flex-direction:column;gap:2px;padding:8px;margin-top:6px;border-left:3px solid var(--amber);background:#211c14;font-size:9px}.risk.high{border-color:var(--red);background:#251418}.risk span{color:var(--muted)}footer{text-align:center;color:#60737b;font-size:8px;padding:10px}
.scanner::-webkit-scrollbar{width:4px}
.eyebrow:not(.online):not(.caution){color:var(--muted)}
.scanner::-webkit-scrollbar-track{background:transparent}
.scanner::-webkit-scrollbar-thumb{background:rgba(255,255,255,.18);border-radius:999px}
.scanner::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,.3)}
.spec-list>div{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);font-size:10px}.spec-list>div:last-child{border-bottom:0}.spec-list span{color:var(--muted)}.spec-list strong{text-align:right}
:deep(.differential-block){padding:9px 0;border-top:1px solid var(--line)}:deep(.differential-block:first-of-type){border-top:0;padding-top:0}:deep(.differential-block:last-child){padding-bottom:0}:deep(.differential-title){display:flex;justify-content:space-between;gap:10px;font-size:10px}:deep(.differential-title span){color:var(--muted);flex:0 0 auto}:deep(.differential-title strong){max-width:62%;text-align:right}:deep(.differential-settings){display:flex;flex-wrap:wrap;gap:5px;margin-top:7px}:deep(.differential-settings span){display:flex;gap:4px;font-size:8px;color:var(--muted);background:#0d151d;padding:4px 6px;border-radius:5px}:deep(.differential-settings b){color:var(--text)}
.finding{padding:9px;border-left:3px solid var(--amber);background:#211c14;margin-top:7px}.finding.high{border-color:var(--red);background:#251418}.finding>b{font-size:10px}.finding p{display:grid;grid-template-columns:82px 1fr;gap:6px;font-size:9px;line-height:1.4;margin:6px 0 0;color:var(--text)}.finding p span{color:var(--muted)}
.tuner-entry{display:flex;align-items:center;gap:10px;width:100%;margin:0 0 8px;padding:11px 12px;box-sizing:border-box;border:1px solid var(--line);border-radius:13px;background:var(--card);color:var(--text);text-align:left}
.tuner-entry-locked .tuner-entry-icon{border-color:var(--line);background:#0d151d;color:var(--muted)}
.tuner-entry-icon{display:flex;align-items:center;justify-content:center;width:32px;height:32px;flex:none;border-radius:9px;border:1px solid #287a5a;background:#10271f;color:var(--green)}
.tuner-entry-icon svg{width:18px;height:18px}
.tuner-entry-copy{flex:1;min-width:0}
.tuner-entry-copy b{display:block;font-size:12px;font-weight:800}
.tuner-entry-copy small{display:block;margin-top:3px;color:var(--muted);font-size:9px}
.tuner-entry-get{flex:none;padding:5px 10px;border-radius:99px;border:1px solid #287a5a;background:#10271f;color:var(--green);font-size:9px;font-weight:800;letter-spacing:.08em}
.tuner-entry-chevron{flex:none;color:var(--muted)}
.tuner-back{display:inline-flex;align-items:center;gap:5px;margin:0 2px 8px;padding:0;border:0;background:transparent;color:var(--muted);font-size:9px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}
.tuner-offer{padding:15px 14px 14px}
.tuner-offer-head{display:flex;align-items:center;gap:10px;margin-bottom:12px}
.tuner-offer-head .tuner-entry-icon{width:40px;height:40px;border-radius:11px}
.tuner-offer-head .tuner-entry-icon svg{width:22px;height:22px}
.tuner-brand{margin:0 0 3px;font-size:9px;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:var(--green)}
.tuner-offer h2{margin:0;font-size:16px;line-height:1.2}
.tuner-copy{font-size:11px;line-height:1.45;color:var(--muted);margin:0 0 12px}
.tuner-offer .tuner-copy{font-size:12px;line-height:1.45;color:#c5d4d0;margin:0 0 14px}
.tuner-offer-price{display:flex;justify-content:space-between;align-items:baseline;gap:10px;margin:0 0 12px;padding-top:12px;border-top:1px solid var(--line)}
.tuner-offer-price span{color:var(--muted);font-size:10px}
.tuner-offer-price strong{font-size:18px}
.tuner-offer .tuner-copy.tuner-copy-follow{margin:12px 0 0;font-size:10px;line-height:1.4;color:var(--muted)}
.tuner-buy{width:100%;margin-top:2px;padding:13px 12px;border:1px solid #287a5a;border-radius:13px;background:#10271f;color:var(--green);font-size:13px;font-weight:800}
.tuner-buy:disabled{opacity:.45;color:var(--muted);border-color:var(--line);background:#0d151d}
.tuner-value-row{display:flex;justify-content:space-between;gap:10px;font-size:12px;margin-bottom:10px}
.tuner-value-row span{color:var(--muted)}
.tuner-value-row strong{font-size:14px}
.tuner-slider{display:inline-block;width:100%;height:16px;margin:0}
.tuner-slider :deep(.bng-slider-track-wrap){display:contents}
.tuner-slider :deep(input.bng-slider){all:revert;width:100%;height:16px;margin:0;accent-color:inherit;background:revert !important}
.tuner-slider :deep(input.bng-slider)::-webkit-slider-thumb{all:revert}
.tuner-range{display:flex;justify-content:space-between;margin-top:6px;color:var(--muted);font-size:10px}
.tuner-firmware{margin:10px 2px 4px;padding:10px 11px;border:1px dashed var(--line);border-radius:11px;color:var(--muted);font-size:10px;line-height:1.45}
.tuner-firmware b{display:block;margin-bottom:4px;color:var(--green);font-size:9px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}
.tuner-pull-label{font-size:8px;font-weight:800;letter-spacing:.08em;text-transform:uppercase;color:var(--green)}
.tuner-dyno-date{margin:-4px 0 10px;color:var(--muted);font-size:10px}
.tuner-dyno-metrics{display:grid;grid-template-columns:1fr 1fr 1fr;gap:6px;margin:0 0 10px}
.tuner-dyno-metrics article{min-width:0;padding:8px 7px;border:1px solid var(--line);border-radius:10px;background:#0d151d}
.tuner-dyno-metrics span{display:block;color:var(--muted);font-size:7px;font-weight:800;letter-spacing:.05em;text-transform:uppercase}
.tuner-dyno-metrics strong{display:block;font-size:13px;margin-top:5px;line-height:1.15}
.tuner-dyno-metrics small{display:block;color:var(--muted);font-size:8px;margin-top:3px;line-height:1.3}
.tuner-dyno-metrics article.warn strong{color:var(--amber)}
.tuner-dyno-metrics article.bad strong{color:var(--red)}
.tuner-dyno-legend{display:flex;justify-content:flex-end;gap:10px;margin-bottom:4px;font-size:8px;font-weight:700}
.tuner-dyno-legend span::before{content:"";display:inline-block;width:10px;margin-right:4px;border-top:2px solid currentColor;vertical-align:middle}
.legend-power{color:#f97316}
.legend-torque{color:#eef4ff}
.tuner-dyno-svg{display:block;width:100%;height:92px}
.tuner-dyno-svg polyline{fill:none;stroke-width:2}
.tuner-dyno-grid{stroke:#263541;stroke-width:1}
.tuner-dyno-power{stroke:#f97316}
.tuner-dyno-torque{stroke:#eef4ff}
.tuner-dyno-axis{display:flex;justify-content:space-between;margin-top:3px;color:var(--muted);font-size:8px}
.fuel-now{margin:0}
.fuel-card .tuner-value-row{margin-bottom:8px}
.fuel-accent{color:var(--green)}
.fuel-actions{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-top:10px}
.fuel-status{color:var(--muted);font-size:9px;min-height:1em}
.fuel-ghost{padding:6px 10px;border-radius:99px;border:1px solid var(--line);background:#0d151d;color:var(--muted);font-size:9px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}
.fuel-ghost:disabled{opacity:.4}
.fuel-note{margin:0;font-size:10px}
.fuel-gears{display:grid;grid-template-columns:repeat(auto-fit,minmax(40px,1fr));gap:4px;margin-top:10px}
.fuel-gears label{display:grid;gap:3px;justify-items:center;padding:6px 2px;border:1px solid var(--line);border-radius:8px;background:#0d151d;font-size:8px;font-weight:800;color:var(--muted)}
.fuel-gears input{width:100%;background:transparent;border:0;color:var(--text);text-align:center;font:inherit;font-size:11px;padding:0}
.fuel-gears input::-webkit-inner-spin-button{display:none}
.fuel-gears small{font-size:7px;color:var(--muted)}
.fuel-cut{margin-top:14px;padding-top:12px;border-top:1px solid var(--line)}
.fuel-engine-pick{position:relative}.fuel-engine-pick summary{cursor:pointer;color:var(--text);font-weight:800}.fuel-engine-pick button{display:block;margin-top:4px;background:#0d151d;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:5px 8px;font-size:10px}
.fuel-card .focus-visible,.fuel-now .focus-visible{outline:2px solid var(--green);outline-offset:2px}
</style>
