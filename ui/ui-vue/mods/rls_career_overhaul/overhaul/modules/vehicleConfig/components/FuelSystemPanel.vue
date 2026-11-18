<template>
  <div v-if="panel.open && !panel.paused" class="fuel-shade rls-house rls-house-card" :class="{dock: isPump}" v-bng-scoped-nav="{scopeId: 'rls-fuel-system'}" v-bng-on-ui-nav:back="onNavBack" @pointerdown.capture="onFuelPointerDown" @focusin="onFuelFocusIn" @focusout="onFuelFocusOut" @keydown="onFuelKey" @keyup="onFuelKey" @keypress="onFuelKey">
    <section class="fuel-panel" :class="{workspace: !isPump, dock: isPump}" role="dialog" aria-modal="true" :aria-label="isPump ? 'Choose your fuel' : isHardware ? 'Fuel Hardware' : 'Fuel and Ignition'">

      <header v-if="!isPump" class="rhead">
        <div class="ttl">
          <span class="kicker">Engine management</span>
          <h1>{{ isHardware ? 'Fuel Hardware' : 'Fuel & Ignition' }}</h1>
          <span v-if="panel.payerLabel" class="faint">Paid by {{ panel.payerLabel }}</span>
        </div>
        <span v-if="draft && !isHardware" class="hd-status" :class="dirty ? 'ready' : 'on'">{{ dirty ? 'Draft' : engine?.control?.mode === 'native' ? 'Native' : 'Installed' }}</span>
        <HouseAccordion v-if="engines.length > 1" class="menu" :class="{disabled:dirty||panel.busy}" data-fuel-menu="menu0" v-model="menus.menu0" id="fuel-menu0" :title="(engineName)" :disabled="dirty||panel.busy"><div class="pop"><HouseButton v-for="item in engines" :key="item.name" type="button" :class="{on:engineName===item.name}" @click="chooseEngine($event, item.name)">{{ item.name }}</HouseButton></div></HouseAccordion>
        <div v-if="workspaceTabs.length > 1" class="seg push" role="tablist" aria-label="Fuel and Ignition sections">
          <HouseButton v-for="t in workspaceTabs" :key="t.id" type="button" role="tab" :aria-selected="workspaceTab===t.id" :class="{on:workspaceTab===t.id}" @click="workspaceTab=t.id"><FuelIcon :name="t.icon" />{{ t.label }}</HouseButton>
        </div>
        <HouseButton v-if="panel.busy && !panel.pumping" type="button" class="btn sm" @click="lua.overhaul_career_maintenance_fuelSystem.cancelBusy()">Cancel operation</HouseButton>
        <HouseButton type="button" class="icon-btn" :class="{push:isHardware}" aria-label="Close" :disabled="panel.busy && !panel.pumping" @click="close"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></HouseButton>
      </header>

      <p v-if="bannerMessage" class="banner" role="status">{{ bannerMessage }}</p>
      <p v-if="!panel.data" class="banner">Reading vehicle…</p>

      <template v-else>
        <div v-if="panel.data.unsupported?.length" class="banner warn">
          <div v-for="item in panel.data.unsupported" :key="item.name">{{ item.name }}: {{ item.reason }}</div>
        </div>

        <!-- ================= PUMP ================= -->
        <!-- Laid out like a real dispenser: readout, grade keys, tank and amount, then one Fuel button.
             A nitrous bottle or battery is picked like a tank; it then shows the station's nitrous or charging instead of fuel grades. -->
        <div v-if="isPump" class="body pump-body">
          <section class="pump-display" :class="{live: !!panel.pumping}" role="status" aria-label="Pump display">
            <div class="lcd-row">
              <span class="lcd-key">Total<small>{{ panel.data.career ? '$' : 'free' }}</small></span>
              <span class="lcd big" data-ghost="8888.88">{{ fmt(pumpTotal, 2) }}</span>
            </div>
            <div class="lcd-row">
              <span class="lcd-key">{{ lcdName }}<small>{{ panel.pumping ? `of ${vol(panel.pumping.total)}` : lastSale ? 'last sale' : 'bought' }}</small></span>
              <span class="lcd big" data-ghost="888.88">{{ lcdAmount }}</span>
            </div>
            <div class="lcd-row sub">
              <span class="lcd-key">Price / {{ store ? storeUnit : volU }}<small>{{ store ? storeGradeName : selectedGradeName }}</small></span>
              <span class="lcd" data-ghost="88.88">{{ fmt(store ? perStore(storeUnitPrice) : perVol(selectedPricePerL), 2) }}</span>
            </div>
          </section>

          <fieldset class="bare" :disabled="!!panel.pumping || panel.busy">
            <!-- One row of keys like the dispenser; details sit in each key's tooltip and the line below. -->
            <template v-if="!store">
              <div class="grade-row" role="group" aria-label="Fuel grade" :style="{'--n': tankGrades.length}">
                <HouseButton v-for="grade in tankGrades" :key="grade.id" type="button" class="grade" :class="[{on: gradeId===grade.id}, gradeFit(grade)?.tone]" :data-tip="gradeTip(grade)" :aria-pressed="gradeId===grade.id" @click="chooseGrade(grade.id)">
                  <span class="grade-name">{{ gradePresentation(grade).name }}</span>
                  <span class="grade-key"><b>{{ gradeCode(grade) }}</b><small>Press</small><i v-if="gradeFit(grade)?.tone" class="grade-dot" aria-hidden="true"></i></span>
                </HouseButton>
              </div>
            </template>
            <template v-else-if="storeOffered">
              <div class="grade-row" role="group" :aria-label="storeGradeName" style="--n: 1">
                <HouseButton type="button" class="grade on" aria-pressed="true" :data-tip="`${battery ? 'Electricity' : 'Nitrous oxide'}\n${panel.data.career ? `$${fmt(perStore(storeUnitPrice),2)} / ${storeUnit}` : 'Free'}`">
                  <span class="grade-name">{{ storeGradeName }}</span>
                  <span class="grade-key"><b>{{ battery ? 'kWh' : 'N2O' }}</b><small>Press</small></span>
                </HouseButton>
              </div>
            </template>
            <p v-else class="alert"><span class="pill">Nitrous</span><span>This station doesn't sell nitrous.</span></p>

            <section class="panel pump-tank" aria-label="Tank and amount">
              <div v-if="store" class="row tank-info">
                <span class="faint">{{ battery ? 'Battery' : 'N2O bottle' }}</span>
                <span class="push strong">{{ storeText(Math.min(store.amount, store.capacity)) }}<span class="faint"> / {{ storeText(store.capacity) }} {{ storeUnit }}</span></span>
              </div>
              <div v-else-if="tank" class="row tank-info">
                <span class="faint">{{ tankShortLabel }}</span>
                <span class="push strong">{{ vol(panel.pumping?.drain ? meterLevel*tank.capacity : tank.liters) }}<span class="faint"> / {{ capText(tank.capacity) }} {{ volU }}</span></span>
              </div>
              <div v-if="tanks.length + stores.length > 1" class="seg sm tank-seg" role="group" aria-label="Tank to fill">
                <HouseButton v-for="(item,index) in tanks" :key="item.name" type="button" :class="{on: !store && tankName===item.name}" :aria-pressed="!store && tankName===item.name" :disabled="!!panel.pumping || panel.busy" @click="storeKey='';chooseTank($event, item.name, true)">Tank {{ index+1 }}<i class="sep" aria-hidden="true"></i>{{ vol(item.capacity,0) }} {{ volU }}</HouseButton>
                <HouseButton v-for="item in stores" :key="item.key" type="button" :class="{on: storeKey===item.key}" :aria-pressed="storeKey===item.key" :disabled="!!panel.pumping || panel.busy" @click="chooseStore(item.key)"><template v-if="item.kind==='battery'"><FuelIcon name="spark" />Battery<i class="sep" aria-hidden="true"></i>{{ fmt(item.capacity,0) }} kWh</template><template v-else><FuelIcon name="bottle" />Nitrous<i class="sep" aria-hidden="true"></i>{{ wt(item.capacity) }} {{ wtU }}</template></HouseButton>
              </div>
              <div v-if="store || tank" class="mix" :class="{labelled: mixSegments.length > 0}" :style="{'--add': addColor}">
              <div class="tank-meter" :class="{n2o: store?.kind==='n2o', battery}" role="img" :aria-label="meterLabel">
                <!-- Stripes stay put underneath; the empty cover slides off them and the fill grows over them.
                     The fill is split by what is in the tank. -->
                <i class="adding"></i>
                <i class="empty" :style="{transform: `translateX(${Math.min(1, meterLevel + meterAdding)*100}%)`}"></i>
                <i class="level" :style="{transform: `scaleX(${meterLevel})`, background: levelFill}"></i>
                <!-- Draining: red over the end of the fuel that is going; it shrinks as the tank empties. -->
                <i v-if="drainFrac > 0" class="drain-cut" :style="{left: (meterLevel - drainFrac)*100+'%', width: drainFrac*100+'%'}"></i>
                <span v-for="q in [25,50,75]" :key="q" class="tick" :style="{left: q+'%'}"></span>
                <span class="tank-label"><b>{{ fmt(meterLevel*100,0) }}% full</b><span>{{ slotStatus }}</span></span>
              </div>
              <div v-if="mixSegments.length" class="mix-hits">
                <span v-for="seg in mixSegments" :key="seg.key" class="mix-seg" :class="{adding: seg.adding}" :style="{left: seg.left+'%', width: seg.width+'%'}" :data-tip="seg.tip"><b v-if="seg.width >= 9 && seg.text">{{ seg.text }}</b></span>
              </div>
              </div>
              <div class="row amount-row">
                <div class="seg sm presets" role="group" aria-label="Amount presets">
                  <HouseButton v-if="canDrain" type="button" class="empty-preset" :class="{on: draining && Math.abs(drainLiters-tank.liters)<.05}" @click="emptyTank">Empty</HouseButton>
                  <HouseButton v-for="l in slotPresets" :key="l" type="button" :class="{on: !draining && Math.abs(slotAmount-l)<.05}" :disabled="slotFree<=0" @click="signedAmount=l">{{ l }} {{ slotUnit }}</HouseButton>
                  <HouseButton type="button" :class="{on: !draining && slotFree>0 && Math.abs(slotAmount-slotFree)<.05}" :disabled="slotFree<=0" @click="fillSlot">Full</HouseButton>
                </div>
              </div>
              <div class="amount-line" :class="{signed: canDrain, draining}">
                <!-- Rebuilt when the range flips: a range input clamps its value to a raised min and keeps it when the min drops again. -->
                <HouseSlider :key="canDrain ? 'signed' : 'add'" v-model.number="sliderPos" :aria-label="canDrain ? 'Fuel amount: left drains, right adds' : 'Fuel amount'" :aria-valuetext="draining ? `Drain ${volText(drainLiters)}` : `Add ${slotAmount} ${slotUnit}`" :min="canDrain ? -100 : 0" max="100" step=".5" :orig-value="canDrain ? 0 : null" />
                <div class="stepper">
                  <HouseButton type="button" class="step" :aria-label="`One ${slotUnit} less`" :disabled="signedAmount<=signedMin" @click="stepAmount(-1)">−</HouseButton>
                  <input v-model.number="signedAmount" :aria-label="canDrain ? `${volName} to add; negative drains` : `${store ? storeUnitName : volName} to add`" type="number" :min="signedMin" :max="slotFree" step=".1">
                  <span class="unit">{{ slotUnit }}</span>
                  <HouseButton type="button" class="step" :aria-label="`One ${slotUnit} more`" :disabled="signedAmount>=slotFree" @click="stepAmount(1)">+</HouseButton>
                </div>
              </div>
            </section>

          </fieldset>

          <div class="pump-actions" :class="{'pay-split': owed>0 && !panel.pumping && !panel.busy}">
            <HouseButton v-if="panel.pumping && !drainHold" type="button" class="btn fuel-go stop" @click="lua.overhaul_career_maintenance_fuelSystem.stopPumping()">{{ panel.pumping.drain ? 'Stop draining' : 'Stop pumping' }}</HouseButton>
            <HouseButton v-else-if="store" type="button" class="btn fuel-go" :class="{'btn-primary': owed<=0}" :data-tip="storeShort ? fundsTip : null" :aria-description="storeShort ? fundsTip : null" :disabled="!storeOffered || storeAddAmount<=0 || storeShort || panel.busy" @click="buyStore"><FuelIcon :name="battery ? 'spark' : 'bottle'" />{{ storePayLabel }}<small v-if="panel.data.career && storeOffered && storeAddAmount>0" class="go-est">est. ${{ fmt(storePrice,2) }}</small></HouseButton>
            <HouseButton v-else-if="draining || drainHold" type="button" class="btn fuel-go btn-danger" :class="{'hold-active': !!drainHold}" :style="{'--hold-time': DRAIN_HOLD_MS+'ms'}" :disabled="!drainHold && (panel.busy || serviceWorking || !drainValid)" :data-tip="drainTip || null" :aria-description="drainTip || null" v-bng-on-ui-nav:ok.asMouse.focusRequired @mousedown.left="beginDrainHold" @keydown.enter.space.prevent="beginDrainHold"><FuelIcon name="droplet" />{{ drainHold ? 'Draining' : 'Drain' }} {{ volText(drainHold ? drainHold.liters : drainLiters) }}<small class="go-est">Hold</small></HouseButton>
            <HouseButton v-else type="button" class="btn fuel-go" :class="quoteWarning ? 'btn-danger' : owed<=0 && !fuelShort ? 'btn-primary' : ''" :disabled="!quoteData || !(quoteData.liters > 0) || fuelShort" :data-tip="fuelShort ? fundsTip : quoteWarning || null" :aria-description="fuelShort ? fundsTip : quoteWarning || null" @click="payNow"><FuelIcon :name="quoteWarning ? 'warn' : 'droplet'" :class="{'go-warn': quoteWarning}" />{{ payLabel }}<small v-if="panel.data.career && quoteData" class="go-est">est. ${{ fmt(quoteData.price,2) }}</small></HouseButton>
            <HouseButton v-if="owed>0 && !panel.pumping" type="button" class="btn fuel-go pay-leave btn-primary" :disabled="panel.busy" @click="lua.overhaul_career_maintenance_fuelSystem.payAndLeave()">Pay ${{ fmt(owed,2) }} &amp; leave</HouseButton>
            <HouseButton v-else type="button" class="icon-btn pump-close" :aria-label="owed>0 ? 'Pay and close' : 'Close'" :disabled="panel.busy && !panel.pumping" @click="close"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></HouseButton>
            <HouseButton v-if="otherEnergyLabel && !panel.pumping" type="button" class="btn other-energy" :disabled="panel.busy" @click="lua.overhaul_career_maintenance_fuelSystem.otherFuelTypes()"><FuelIcon name="pump" />{{ otherEnergyLabel }}</HouseButton>
            <HouseButton v-if="panel.busy && !panel.pumping" type="button" class="btn cancel-op" @click="lua.overhaul_career_maintenance_fuelSystem.cancelBusy()">Cancel operation</HouseButton>
          </div>
        </div>

        <!-- ================= GARAGE ================= -->
        <template v-else>
          <div v-if="engine && draft" class="stats">
            <div v-for="s in statStrip" :key="s.key" class="stat has-ico" :class="s.tone"><FuelIcon :name="s.icon" class="stat-ico" /><span class="stat-key">{{ s.key }}</span><span class="stat-value">{{ s.value }}<small v-if="s.sub">{{ s.sub }}</small></span></div>
            <HouseButton type="button" class="text-btn push" :aria-expanded="liveOpen" @click="liveOpen=!liveOpen"><FuelIcon name="pulse" />Live readouts <i class="chev" :class="{up:liveOpen}" aria-hidden="true"></i></HouseButton>
          </div>

          <!-- The div scrolls: CEF does not scroll a fieldset inside a flex column. -->
          <div class="body-scroll"><fieldset class="bare" :disabled="panel.busy">
            <div v-if="engine && draft" class="body">
              <section v-if="liveOpen" class="panel live" aria-label="Live readouts">
                <div class="row"><span class="kicker"><FuelIcon name="pulse" />Live readouts</span><span v-if="panel.mode === 'garage'" class="pill" :class="engine.condition?.diagnoses?.length ? 'bad' : 'ok'">{{ engine.condition?.diagnoses?.length ? 'Engine faults' : 'Engine OK' }}</span></div>
                <div class="live-grid">
                  <div v-for="r in liveReadings" :key="r.key" class="stat" :class="r.tone"><span class="stat-key">{{ r.key }}</span><span class="stat-value">{{ r.value }}<small v-if="r.sub">{{ r.sub }}</small></span></div>
                </div>
                <ul v-if="engine.condition?.diagnoses?.length" class="diag"><li v-for="d in engine.condition.diagnoses" :key="d">{{ d }}</li></ul>
                <p v-if="engine.condition?.limited" class="muted">{{ engine.condition.limitation }}</p>
                <p v-if="!dieselTune && !nitroTune" class="faint">Knock protection: {{ engine.profile.knockControlSource }}<template v-if="engine.profile.knockControl">, up to {{ fmt(engine.profile.maxKnockRetard, 1) }}° retard</template>. It can't save a very aggressive tune. Fixing the fuel or map does not repair damage.</p>
              </section>

              <div v-for="a in engineAlerts" :key="a" class="alert warn"><span class="pill warn">Check</span><span>{{ a }}</span></div>
              <div v-if="rpmRangeDiffers" class="alert"><span class="pill">Rev limiter</span><span>Rev limiter is {{ limiterRpmText }}; this map ends at {{ mapRpmText }}.</span><HouseButton type="button" class="text-btn push" :disabled="dirty || panel.busy" @click="recalibrateRpm">{{ dirty ? 'Apply or discard first' : `Match map to ${limiterRpmText}` }}</HouseButton></div>

              <!-- ================= TUNE ================= -->
              <template v-if="workspaceTab === 'tune'">
                <div class="row">
                  <div class="seg" role="group" aria-label="Tuning complexity"><HouseButton type="button" :class="{on:editorMode==='simple'}" @click="editorMode='simple'"><FuelIcon name="sliders" />Simple</HouseButton><HouseButton type="button" :class="{on:editorMode==='advanced'}" @click="editorMode='advanced'"><FuelIcon name="grid" />Advanced</HouseButton></div>
                  <div v-if="editorMode==='advanced'" class="seg sm" role="group" aria-label="Map">
                    <HouseButton type="button" :class="{on:field==='lambda'}" @click="field='lambda'"><FuelIcon name="droplet" />AFR</HouseButton>
                    <HouseButton v-if="!dieselTune" type="button" :class="{on:field==='timing'}" @click="field='timing'"><FuelIcon name="spark" />Timing</HouseButton>
                    <HouseButton type="button" :class="{on:isBoost}" @click="field='boost'"><FuelIcon name="turbo" />Boost by gear</HouseButton>
                  </div>
                  <span v-else class="faint">Three dials for the whole map. Switch to Advanced for cell-by-cell edits.</span>
                  <HouseButton v-if="(engine.state.tune.afrTrim||0)!==0 || (draft.afrTrim||0)!==0" type="button" class="pill accent pill-btn" :disabled="panel.busy || !(draft.afrTrim||0)" :title="(draft.afrTrim||0)!==(engine.state.tune.afrTrim||0) ? 'Draft change. Apply to save.' : 'Clear phone fuel trim in the draft'" @click="resetTrim">Phone trim {{ (draft.afrTrim||0) > 0 ? '+' : '' }}{{ draft.afrTrim||0 }}%<span v-if="draft.afrTrim" aria-hidden="true"> ✕</span></HouseButton>
                  <div class="row push">
                    <HouseButton type="button" class="icon-btn" aria-label="Undo" :disabled="!undoStack.length" @click="undoEdit"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/></svg></HouseButton>
                    <HouseButton type="button" class="icon-btn" aria-label="Redo" :disabled="!redoStack.length" @click="redoEdit"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 14l5-5-5-5"/><path d="M20 9H10a6 6 0 0 0 0 12h3"/></svg></HouseButton>
                    <HouseAccordion class="menu" data-fuel-menu="menu2" v-model="menus.menu2" id="fuel-menu2" :title="&quot;Tune options&quot;"><div class="pop right">
                      <HouseButton type="button" @click="resetSliders($event)">Reset sliders to stock</HouseButton>
                      <HouseButton v-if="rpmRangeDiffers" type="button" :disabled="dirty || panel.busy" @click="pickChoice($event,recalibrateRpm)">Match map to rev limiter ({{ limiterRpmText }})</HouseButton>
                      <hr><HouseButton type="button" class="danger" @click="requestReset($event)">Reset whole tune…</HouseButton>
                    </div></HouseAccordion>
                  </div>
                </div>
                <p v-if="dirty && (engine.state.revision||0)!==draftRevision" class="alert warn">The installed tune changed while this draft was open. Discard to reload before applying.</p>

                <section v-if="engine.nitrousInstalled || draft.nitrous" class="panel" aria-label="Nitrous tuning">
                  <div class="row"><span class="kicker"><FuelIcon name="bottle" />Nitrous activation</span>
                    <HouseMenu :model-value="draft.nitrous?.mode || 'original'" :items="nitrousModes" aria-label="Nitrous activation mode" :disabled="panel.busy" @update:model-value="changeNitrousMode" />
                  </div>
                  <p class="faint">Choose speed or RPM / gear. Limits use the installed shot; arm nitrous normally. Full throttle, an engaged forward gear and native bottle / engine limits still apply.</p>
                  <p v-if="!engine.nitrousSupported" class="alert warn">{{ engine.nitrousSupportReason }} Select Stock to remove this calibration.</p>
                  <p v-else-if="engine.nitrousCalibrationReason" class="alert warn">{{ engine.nitrousCalibrationReason }} Review the limits and Apply. Nitrous is inhibited until the calibration matches.</p>
                  <div v-if="draft.nitrous && draft.nitrous.mode !== 'original'" class="nitrous-fields">
                    <label v-for="f in nitrousFields" :key="f.key" class="nitrous-field"><span class="stat-key">{{ f.label }}</span>
                      <input class="num-input" type="number" :aria-label="f.label" :value="nitrousEntry?.key===f.key ? nitrousEntry.text : draft.nitrous[f.key]" :min="f.min" :max="f.max" :step="f.step" :disabled="panel.busy" @input="nitrousEntry={key:f.key,text:$event.target.value}" @change="changeNitrousValue(f.key,$event)" @blur="nitrousEntry=null">
                    </label>
                  </div>
                </section>

                <!-- ---------- Simple ---------- -->
                <div v-if="editorMode==='simple'" class="simple-grid" :class="{'no-boost': !boostCardShown}">
                  <p v-if="hasCustomMap" class="alert span-all"><span class="pill">Custom map</span><span>Moving a slider rebuilds the map from these dials. Undo brings your edits back.</span></p>
                  <div class="panel dial">
                    <div class="row"><span class="kicker"><FuelIcon name="droplet" />Mixture</span><HouseButton type="button" class="tip" data-tip="Lower AFR = more fuel. Stock values: gas 14.7, E85 9.8, M100 6.4, Nitro 1.7. Too lean knocks and damages the engine." aria-label="About mixture">?</HouseButton><span class="pill push">stock {{ fmt(simpleStockAFR) }}</span></div>
                    <label class="big"><input class="big-input" type="number" aria-label="Full-load AFR" :value="simpleAFREntry ?? simpleAFR" :min="simpleBounds[0]" :max="simpleBounds[1]" step=".01" @input="simpleAFREntry=$event.target.value" @change="changeSimpleAFR($event)" @blur="simpleAFREntry=null"><small>AFR</small></label>
                    <HouseSlider  aria-label="Full-load AFR slider" :model-value="Number(simpleAFR)" @update:model-value="simpleAFR=$event" :min="simpleBounds[0]" :max="simpleBounds[1]" step=".01" @change="generateSimple" />
                    <div class="scale"><span>◀ Richer</span><span class="mark" :style="{left: markPercent(simpleStockAFR, simpleBounds[0], simpleBounds[1])}">stock</span><span>Leaner ▶</span></div>
                    <p class="faint foot">Sets the full-throttle target. Light-load cells stay near {{ fmt(afrBasis) }}.</p>
                  </div>
                  <div v-if="!dieselTune" class="panel dial">
                    <div class="row"><span class="kicker"><FuelIcon name="spark" />Timing</span><HouseButton type="button" class="tip" data-tip="Earlier spark makes more power until it knocks. Ethanol adds room (E85 about +8°), M100 +20°, Nitro +15°." aria-label="About timing">?</HouseButton><span class="pill push" :class="{accent: Number(simpleTiming)!==0}">{{ Number(simpleTiming)===0 ? 'stock' : `${signed(simpleTiming,1)}° from stock` }}</span></div>
                    <label class="big"><input class="big-input" type="number" aria-label="Timing trim degrees" v-model.number="simpleTiming" min="-20" max="20" step=".5" @change="generateSimple"><small>DEG</small></label>
                    <HouseSlider  aria-label="Timing trim slider" v-model.number="simpleTiming" min="-20" max="20" step=".5" @change="generateSimple" />
                    <div class="scale"><span>◀ Retard</span><span class="mark" style="left: 50%">stock</span><span>Advance ▶</span></div>
                    <p class="faint foot">Relative to the engine's original timing. Too far and you lose power or knock.</p>
                  </div>
                  <div v-if="boostCardShown" class="panel dial boost-card">
                    <div class="row"><span class="kicker"><FuelIcon name="turbo" />Boost</span><HouseButton type="button" class="tip" data-tip="Stock boost, a limit per gear, or a full rpm × gear map. Boost cut stops fuel if boost overshoots." aria-label="About boost">?</HouseButton><span v-if="Number.isFinite(engine.telemetry?.boostTargetPsi)" class="pill push">target {{ pressureText(engine.telemetry.boostTargetPsi) }} now</span></div>
                    <FuelBoostEditor :key="pressure.unit" :pressure="pressure" :active="!!engine.state.control?.boost && engine.state.tune.boost?.enabled===true" :disabled="panel.busy" :tune="draft" :gears="engine.boostGears || []" :baseline="factoryBoostPsi + (engine.profile.wastegateHalfRangePsi || 0)" :supported="!!engine.boostSupported" :support-reason="engine.boostSupportReason" @change="changeBoost" @open-map="editorMode='advanced';field='boost'" />
                    <div v-if="factoryBoostPsi > 0" class="cut">
                      <div class="row"><span class="faint">Boost cut</span><HouseButton type="button" class="tip" data-tip="Cuts fuel when boost stays above this for a moment. Same setting as the phone PRO Tuner." aria-label="About boost cut">?</HouseButton><strong class="push">{{ pressureText(factoryBoostPsi + boostCutDisplay) }}</strong><span class="pill" :class="boostCutDisplay === BOOST_CUT_STOCK ? 'ok' : 'accent'">{{ boostCutDisplay === BOOST_CUT_STOCK ? 'stock' : 'raised' }}</span></div>
                      <HouseSlider  aria-label="Boost cut pressure" :disabled="engine?.boostCutEditable === false" :title="engine?.boostCutEditable === false ? engine.boostCutLockReason : null" :min="pressure.toDisplay(BOOST_CUT_MIN)" :max="pressure.toDisplay(BOOST_CUT_MAX)" :step="pressure.toDisplay(.5)" :model-value="pressure.toDisplay(boostCutDisplay)" :aria-valuetext="pressureText(factoryBoostPsi + boostCutDisplay)" @update:model-value="previewBoostCut(pressure.fromDisplay($event))" @change="commitBoostCut(pressure.fromDisplay($event))" @blur="boostCutPreview=null" />
                      <div class="scale"><span>{{ pressureText(factoryBoostPsi + BOOST_CUT_MIN) }}</span><span class="mark" :style="{left: markPercent(BOOST_CUT_STOCK, BOOST_CUT_MIN, BOOST_CUT_MAX)}">stock</span><span>{{ pressureText(factoryBoostPsi + BOOST_CUT_MAX) }}</span></div>
                    </div>
                  </div>
                </div>

                <!-- ---------- Advanced ---------- -->
                <template v-if="editorMode==='advanced'">
                  <template v-if="isBoost">
                    <div class="adv-boost">
                      <div class="panel">
                        <div class="row"><span class="kicker"><FuelIcon name="turbo" />Boost control</span><HouseButton type="button" class="tip" data-tip="Same switch as the Simple view. Whatever is selected when you apply is what the car uses." aria-label="About boost control">?</HouseButton></div>
                        <FuelBoostEditor :key="pressure.unit" :pressure="pressure" :active="!!engine.state.control?.boost && engine.state.tune.boost?.enabled===true" :disabled="panel.busy" :tune="draft" :gears="engine.boostGears || []" :baseline="factoryBoostPsi + (engine.profile.wastegateHalfRangePsi || 0)" :supported="!!engine.boostSupported" :support-reason="engine.boostSupportReason" @change="changeBoost" @open-map="field='boost'" />
                      </div>
                      <div v-if="factoryBoostPsi > 0" class="panel cut">
                        <div class="row"><span class="kicker"><FuelIcon name="gauge" />Boost cut</span><strong class="push">{{ pressureText(factoryBoostPsi + boostCutDisplay) }}</strong><span class="pill" :class="boostCutDisplay === BOOST_CUT_STOCK ? 'ok' : 'accent'">{{ boostCutDisplay === BOOST_CUT_STOCK ? 'stock' : 'raised' }}</span></div>
                        <HouseSlider  aria-label="Boost cut pressure" :disabled="engine?.boostCutEditable === false" :min="pressure.toDisplay(BOOST_CUT_MIN)" :max="pressure.toDisplay(BOOST_CUT_MAX)" :step="pressure.toDisplay(.5)" :model-value="pressure.toDisplay(boostCutDisplay)" @update:model-value="previewBoostCut(pressure.fromDisplay($event))" @change="commitBoostCut(pressure.fromDisplay($event))" @blur="boostCutPreview=null" />
                        <div class="scale"><span>{{ pressureText(factoryBoostPsi + BOOST_CUT_MIN) }}</span><span>{{ pressureText(factoryBoostPsi + BOOST_CUT_MAX) }}</span></div>
                      </div>
                    </div>
                  </template>

                  <div v-if="showAdvancedTable && gridRows.length && gridColumns.length" class="toolstrip" aria-label="Table tools">
                    <span class="pill accent">{{ selectionCount }} {{ selectionCount === 1 ? 'cell' : 'cells' }}</span><span class="faint">{{ selectionLabel }}</span><span class="vsep"></span>
                    <HouseAccordion class="menu" :class="{disabled:panel.busy}" data-fuel-menu="menu3" v-model="menus.menu3" id="fuel-menu3" :title="(bulkShortLabel)" :disabled="panel.busy"><div class="pop"><HouseButton v-for="choice in bulkChoices" :key="choice.value" type="button" :class="{on:bulkOperation===choice.value}" @click="setBulkOperation($event, choice.value)">{{ choice.label }}</HouseButton></div></HouseAccordion>
                    <input class="num-input" type="number" aria-label="Bulk value" v-model.number="bulkValue" @change="bulkValue=$event.target.value" :disabled="!gridEditable" :step="bulkOperation === 'percent' ? 1 : isBoost ? pressure.step : field === 'lambda' ? .01 : .5"><span class="faint">{{ bulkOperation === 'percent' ? '%' : field === 'lambda' ? 'AFR' : isBoost ? pressure.unit : '°' }}</span>
                    <HouseButton type="button" class="btn sm btn-primary" :disabled="!gridEditable" @click="bulkEdit">Apply to cells</HouseButton><span class="vsep"></span>
                    <HouseButton type="button" class="icon-btn" aria-label="Nudge selection down" :disabled="!gridEditable" @click="adjust(-1)"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14"/></svg></HouseButton>
                    <HouseButton type="button" class="icon-btn" aria-label="Nudge selection up" :disabled="!gridEditable" @click="adjust(1)"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg></HouseButton><span class="vsep"></span>
                    <HouseButton type="button" class="btn sm" @click="copySelection">Copy</HouseButton><HouseButton type="button" class="btn sm" :disabled="!gridEditable || !clipboardText" @click="pasteText(clipboardText)">Paste</HouseButton>
                    <span v-if="isBoost" class="faint push">Cell {{ pressureText(gridValues[selected.y]?.[selected.x]) }}. With phone offsets: {{ pressureText(selectedBoostTarget) }}</span>
                    <HouseAccordion class="menu" :class="{push: !isBoost}" data-fuel-menu="menu4" v-model="menus.menu4" id="fuel-menu4" :title="&quot;More&quot;"><div class="pop right more-pop">
                      <HouseButton type="button" :disabled="!gridEditable || bounds.x2-bounds.x1 < 2" @click="pickChoice($event,()=>interpolate('rpm'))">Interpolate across rpm</HouseButton>
                      <HouseButton v-if="!isBoost" type="button" :disabled="!gridEditable || bounds.y2-bounds.y1 < 2" @click="pickChoice($event,()=>interpolate('load'))">Interpolate across load</HouseButton>
                      <HouseButton type="button" :disabled="!gridEditable || bounds.x2-bounds.x1 < 2 || (!isBoost && bounds.y2-bounds.y1 < 2)" @click="pickChoice($event,smoothSelection)">Smooth inside selection</HouseButton>
                      <HouseButton type="button" @click="pickChoice($event,selectAll)">Select all</HouseButton>
                      <label class="pop-check"><input type="checkbox" v-model="showChanges">Mark changed cells</label>
                      <HouseButton type="button" @click="openDrawer('clipboard')">Paste from text…</HouseButton>
                      <hr>
                      <div class="pop-sub"><span class="stat-key">RPM columns</span>
                        <div class="seg sm"><HouseButton v-for="spacing in ['even',100,500,1000]" :key="spacing" type="button" :class="{on:rpmSpacing===spacing}" @click="rpmSpacing=spacing">{{ spacing==='even'?'12 even':`${spacing}` }}</HouseButton></div>
                        <label class="row">Up to <input class="num-input" type="number" min="1000" max="50000" step="500" v-model.number="rpmLimit" aria-label="Upper RPM"> rpm</label>
                        <HouseButton type="button" class="btn sm" @click="pickChoice($event,resizeDraft)">Resize draft</HouseButton>
                        <span class="faint">Interpolates values. Never moves the rev limiter.</span>
                      </div>
                    </div></HouseAccordion>
                  </div>

                  <div v-if="showAdvancedTable && gridRows.length && gridColumns.length" class="map-scroll" @keydown="tableKey" @paste="pasteEvent">
                    <table class="rmap" :aria-label="isBoost ? 'RPM by gear boost targets' : 'RPM and load tuning map'">
                      <thead><tr><th><HouseButton type="button" class="axis corner" @click="selectAll">{{ isBoost ? 'Gear / rpm' : 'Load / rpm' }}</HouseButton></th><th v-for="(label, x) in gridColumns" :key="label"><HouseButton type="button" class="axis" @click="selectColumn(x)">{{ Number(label).toLocaleString() }}</HouseButton></th></tr></thead>
                      <tbody><tr v-for="(label, y) in gridRows" :key="y"><th><HouseButton type="button" class="axis rowh" @click="selectRow(y)">{{ isBoost ? `Gear ${label}` : `${Math.round(label * 100)}%` }}</HouseButton></th>
                        <td v-for="(_, x) in gridColumns" :key="x" :style="cellStyle(y, x)" :class="{op: operatingCell(y, x), sel: inSelection(y,x), changed: showChanges && isChanged(y,x)}" @pointerdown="startSelection($event,y,x)" @mousedown="!isEditing(y,x) && $event.preventDefault()" @pointerenter="extendSelection($event,y,x)" :data-y="y" :data-x="x">
                          <input :value="isEditing(y,x) ? editingCell.text : fmt(displayCell(gridValues[y][x]), isBoost || field === 'lambda' ? 2 : 1)" type="number" :aria-label="isBoost ? `${draft.rpm[x]} RPM gear ${boostGrid.gears[y]} target ${pressure.unit}` : `${field==='lambda'?'AFR':'Timing'}, ${draft.rpm[x]} RPM, ${Math.round(label * 100)} percent load`" :min="displayLimits()[0]" :max="displayLimits()[1]" :step="isBoost ? pressure.step : field === 'lambda' ? .01 : .5" :disabled="!gridEditable" @focus="selected = {y, x}; row = Math.min(y,7)" @input="isEditing(y,x) && (editingCell.text=$event.target.value)" @change="editGridCell(y,x,$event)" :readonly="!isEditing(y,x)" @click="onGridClick($event,y,x)" @dblclick="beginEdit($event,y,x)" @blur="editingCell = null">
                        </td>
                      </tr></tbody>
                    </table>
                  </div>

                  <div v-if="showAdvancedTable && gridRows.length" class="row legend-row">
                    <div class="legend">
                      <template v-if="isBoost || colorMode==='absolute'"><span><i :style="absLegend(0)"></i>{{ isBoost ? pressureText(0) : 'Low' }}</span><span><i :style="absLegend(1)"></i>{{ isBoost ? pressureText(gridColorRange[1]) : 'High' }}</span></template>
                      <template v-else><span><i class="lg-rich"></i>{{ field==='lambda' ? 'Richer than stock' : 'Less advance' }}</span><span><i class="lg-stock"></i>Stock</span><span><i class="lg-lean"></i>{{ field==='lambda' ? 'Leaner than stock' : 'More advance' }}</span></template>
                      <span><i class="lg-op"></i>Engine is here now</span>
                    </div>
                    <div class="row push">
                      <span v-if="!isBoost" class="seg-label"><FuelIcon name="palette" />Color</span><div v-if="!isBoost" class="seg sm" role="group" aria-label="Cell colors"><HouseButton type="button" :class="{on:colorMode==='stock'}" @click="colorMode='stock'">vs stock</HouseButton><HouseButton type="button" :class="{on:colorMode==='absolute'}" @click="colorMode='absolute'">Absolute</HouseButton></div>
                      <HouseButton v-if="!isBoost" type="button" class="text-btn" :aria-expanded="curveOpen" @click="curveOpen=!curveOpen"><FuelIcon name="chart" />{{ curveOpen ? 'Hide' : 'Show' }} map shape <i class="chev" :class="{up:curveOpen}" aria-hidden="true"></i></HouseButton>
                    </div>
                  </div>

                  <section v-if="curveOpen && !isBoost" class="panel curve" aria-label="Draft and installed map comparison">
                    <div class="row"><span class="kicker"><FuelIcon name="chart" />Map shape</span><span class="faint">{{ field === 'lambda' ? 'Target AFR' : 'Timing trim (degrees)' }}</span>
                      <HouseAccordion class="menu" data-fuel-menu="menu5" v-model="menus.menu5" id="fuel-menu5" :title="&quot;Load &quot; + (Math.round((draft.load[row] || 0) * 100)) + &quot;%&quot;"><div class="pop"><HouseButton v-for="(l,i) in draft.load" :key="i" type="button" :class="{on:row===i}" @click="setCurveLoad($event, i)">{{ Math.round(l*100) }}%</HouseButton></div></HouseAccordion>
                      <div class="legend push"><span><i class="lg-draft"></i>Draft</span><span><i class="lg-inst"></i>Installed</span></div>
                    </div>
                    <div class="curve-body"><div class="y-labels"><span>{{ fmt(curveData.hi,field==='lambda'?2:1) }}</span><span>{{ fmt(curveData.lo,field==='lambda'?2:1) }}</span></div>
                      <svg viewBox="0 0 660 136" preserveAspectRatio="none" role="img" :aria-label="`${field==='lambda'?'AFR':'Timing'} draft and installed maps at ${Math.round(draft.load[row]*100)} percent load`" @mousemove="hoverCurve" @mouseleave="curveHover=null">
                        <path d="M0 12 H660 M0 68 H660 M0 124 H660" class="curve-grid"/><polyline :points="curveData.installed" class="installed-line"/><polyline :points="curveData.draft" class="draft-line"/>
                        <line v-if="curveHover!==null" :x1="draft.rpm[curveHover]/draft.rpm.at(-1)*660" :x2="draft.rpm[curveHover]/draft.rpm.at(-1)*660" y1="0" y2="136" class="cursor-line"/>
                      </svg>
                    </div>
                    <div class="row faint"><span v-if="curveHover!==null">{{ draft.rpm[curveHover].toLocaleString() }} rpm. Draft: {{ fmt(displayCell(draft[field][row][curveHover]),field==='lambda'?2:1) }}; installed: {{ fmt(displayCell(installedValue(field,row,draft.rpm[curveHover])),field==='lambda'?2:1) }}</span><span v-else>Hover to compare values</span><span class="push">{{ changedCount }} changed cells</span></div>
                  </section>
                </template>

                <!-- ---------- Decel ---------- -->
                <section v-if="!dieselTune" class="collapse" aria-label="Decel tuning">
                  <div class="row">
                    <span class="kicker dim"><FuelIcon name="flame" />Decel</span>
                    <div class="seg sm" role="group" aria-label="Decel mode"><HouseButton type="button" :class="{on:decelUi==='stock'}" @click="setDecelUi('stock')">Stock</HouseButton><HouseButton type="button" :class="{on:decelUi==='off'}" @click="setDecelUi('off')">Off</HouseButton><HouseButton type="button" :class="{on:decelUi==='custom'}" @click="setDecelUi('custom')">Custom</HouseButton></div>
                    <span class="faint">{{ decelUi === 'stock' ? "The engine's original off-throttle behavior." : decelUi === 'off' ? 'No extra fuel when you lift off.' : 'What the engine does when you lift off.' }}</span>
                  </div>
                  <template v-if="decelUi === 'custom'">
                    <div class="decel-grid">
                      <div class="panel inset"><div class="row"><span class="faint">Extra fuel</span><strong class="push">{{ Math.round(decelDisplay.fueling*100) }}%</strong></div><HouseSlider  aria-label="Decel fuel" min="0" max="200" step="10" :model-value="decelDisplay.fueling*100" @update:model-value="previewDecel('fueling',Number($event)/100)" @change="commitDecel('fueling',Number($event)/100)" @blur="decelPreview={}" /><div class="scale"><span>None</span><span>Double</span></div></div>
                      <div class="panel inset"><div class="row"><span class="faint">Cut delay</span><strong class="push">{{ decelDraft.continuous ? 'All decel' : `${fmt(decelDisplay.cutDelay,1)} s` }}</strong></div><HouseSlider  aria-label="Decel cut delay" min="0" max="5" step=".1" :disabled="decelDraft.continuous" :model-value="decelDisplay.cutDelay" @update:model-value="previewDecel('cutDelay',$event)" @change="commitDecel('cutDelay',$event)" @blur="decelPreview={}" /><label class="row check"><input type="checkbox" :checked="decelDraft.continuous" @change="changeDecel('continuous',$event.target.checked)">Keep fueling through all decel</label></div>
                      <div class="panel inset"><div class="row"><span class="faint">Spark retard</span><strong class="push">{{ decelDisplay.retard }}°</strong></div><HouseSlider  aria-label="Decel spark retard" min="0" max="20" step="1" :model-value="decelDisplay.retard" @update:model-value="previewDecel('retard',$event)" @change="commitDecel('retard',$event)" @blur="decelPreview={}" /><div class="scale"><span>0°</span><span>20°</span></div></div>
                    </div>
                    <p class="faint">Extra fuel and retard add native lift-off pops, shift bangs and overrun afterfire. Requires delivered fuel and a warm engine/exhaust; stock muffling still applies.</p>
                    <p v-if="engine.afterfire?.adapter?.warning" class="note warm" role="status">{{ engine.afterfire.adapter.warning }}</p>
                  </template>
                </section>
              </template>

              <!-- ================= HARDWARE ================= -->
              <template v-else-if="workspaceTab === 'hardware'">
                <p v-if="dirty" class="alert"><span class="pill accent">Draft open</span><span>Apply or discard your tune changes before changing hardware.</span></p>
                <p v-else-if="!hardwareAccess" class="alert"><span class="pill">Garage only</span><span>Kits and hardware can be installed through Fuel Hardware at a garage computer.</span></p>
                <template v-if="!dieselTune">
                  <div class="row"><span class="kicker"><FuelIcon name="engine" />Fuel system</span><HouseButton type="button" class="tip" data-tip="Decides which fuels the engine can burn. Your hardware and tank stay as they are." aria-label="About the fuel system">?</HouseButton></div>
                  <div class="kit-grid">
                    <article v-for="kit in kitChoices" :key="kit.kind" class="kit" :class="{installed: installedFuelKind===kit.kind}">
                      <div class="kit-copy"><strong>{{ kit.title }}</strong><span class="faint">{{ kit.fuels }}</span>
                        <div class="row"><span class="money">{{ panel.data.career && kit.price>0 ? `$${Number(kit.price).toLocaleString()}` : 'Free' }}</span>
                          <span v-if="installedFuelKind===kit.kind" class="pill ok push">Installed</span>
                          <HouseButton v-else type="button" class="btn sm push" :disabled="panel.busy || dirty || !hardwareAccess" @click="requestService(kit.kind==='gasoline'?'remove':kit.kind,$event)">{{ kit.kind==='gasoline' ? 'Switch back' : 'Review' }}</HouseButton>
                        </div>
                      </div>
                    </article>
                  </div>
                </template>

                <div class="row"><span class="kicker"><FuelIcon name="pump" />Fuel delivery</span><HouseButton type="button" class="tip" data-tip="Can the injectors and pump feed the engine at full throttle? Both have to keep up; the smaller one is your limit. Injector size is the flow of one injector." aria-label="About fuel delivery">?</HouseButton></div>
                <div class="panel delivery">
                  <div class="delivery-stats">
                    <div class="stat" :class="deliveryNeed>1 ? 'bad' : deliveryNeed>.9 ? 'warn' : 'ok'"><span class="stat-key">Supports</span><span class="stat-value">{{ pw(supportedHp(capacityLps)) }}<small>{{ pwU }}</small></span></div>
                    <div class="stat"><span class="stat-key">System flow</span><span class="stat-value">{{ ccmin(capacityLps) }}<small>cc/min</small></span></div>
                    <div v-if="limitingPart" class="stat"><span class="stat-key">Limit</span><span class="stat-value">{{ limitingPart }}</span></div>
                  </div>
                  <div class="meter"><i :style="{width: Math.min(100,(deliveryNeed||0)*100)+'%', background: deliveryNeed>1 ? '#fca5a5' : deliveryNeed>.9 ? '#fbbf24' : '#4ade80'}"></i></div>
                  <div class="scale"><span>Stock needs {{ deliveryNeed==null ? '—' : Math.round(deliveryNeed*100)+'%' }}</span><span class="mark" style="left: 90%">90%</span><span>Now {{ fmt((engine.telemetry?.deliveryDuty||0)*100,0) }}%</span></div>
                </div>

                <div class="hw-grid">
                <section v-for="component in ['injector','pump']" :key="component" class="panel hw" :aria-label="component === 'injector' ? 'Injector upgrades' : 'Fuel pumps'">
                  <div class="row"><strong>{{ component === 'injector' ? 'Injector upgrades' : 'Fuel pump' }}</strong><HouseButton type="button" class="tip" :data-tip="component === 'injector' ? 'Size and flow are for one injector, rated at 3 bar (43.5 psi). Stock and legacy systems without a declared individual size keep their original rating.' : 'Each pump is rated in L/h. Packages show the number of pumps. A bigger pump has no idle penalty.'" :aria-label="component === 'injector' ? 'About injector upgrades' : 'About fuel pumps'">?</HouseButton>
                    <HouseAccordion v-if="retiredHardware(component).length" class="menu push" :data-fuel-menu="'menu6-'+component" v-model="menus['menu6-'+component]" :id="'fuel-menu6-'+component" :title="&quot;Previously owned (&quot; + (retiredHardware(component).length) + &quot;)&quot;"><div class="pop right hw-owned-pop">
                      <HouseButton v-for="option in retiredHardware(component)" :key="option.id" type="button" :class="{on: engine.state.hardware?.[component]===option.id}" @click="pickChoice($event,()=>pickHardware(component,option.id))">{{ option.label || hwLabel(option,component) }}</HouseButton>
                    </div></HouseAccordion>
                  </div>
                  <!-- Pick from a list; the card below shows the installed part, or what you hover or pick, and what changes. -->
                  <div class="hw-controls">
                    <div class="hw-field"><span class="stat-key">{{ component === 'injector' ? 'Injector size' : 'Pump size' }}</span>
                      <HouseAccordion class="menu hw-menu" :data-fuel-menu="'hw-'+component" v-model="menus['hw-'+component]" :id="'fuel-hw-'+component">
                        <template #title="{ expanded }"><span class="hw-current">{{ pickedHardware(component) ? hwSize(pickedHardware(component), component) : 'Choose' }}</span><i class="chev" :class="{up: expanded}" aria-hidden="true"></i></template>
                        <div class="pop hw-pop" :class="{up: hwUp[component]}" role="listbox" :aria-label="component === 'injector' ? 'Injector size' : 'Pump size'" @mouseleave="hwHover=null">
                          <HouseButton v-for="option in hardwareChoices(component)" :key="option.id" type="button" role="option" class="hw-option" :aria-selected="pickedHardware(component)?.id===option.id" :class="{on: pickedHardware(component)?.id===option.id, inst: engine.state.hardware?.[component]===option.id}" @mouseenter="hwHover={component, id: option.id}" @focus="hwHover={component, id: option.id}" @click="pickChoice($event,()=>{pickHardware(component,option.id);hwHover=null})">
                            <b>{{ hwSize(option, component) }}</b>
                            <span class="hw-sub">{{ pw(hardwarePower(option)) }} {{ pwU }}</span>
                            <span class="hw-delta" :class="hwDelta(component, option, 'hp')?.tone">{{ hwDelta(component, option, 'hp')?.text || '' }}</span>
                            <span class="hw-tag" :class="{ok: engine.state.hardware?.[component]===option.id || option.owned}">{{ hwTag(option, component) }}</span>
                          </HouseButton>
                        </div>
                      </HouseAccordion>
                    </div>
                  </div>
                  <div v-if="hwShown(component)" class="detail spec" :class="{preview: hwPreviewing(component)}">
                    <div class="spec-head">
                      <span class="stat-key">{{ hwPreviewing(component) ? 'Previewing' : engine.state.hardware?.[component]===hwShown(component).id ? 'Installed' : 'Selected' }}</span>
                      <strong class="row">{{ hwShown(component).systemName || hwShown(component).label }}<HouseButton v-if="hwShown(component).assemblyNote" type="button" class="tip" :data-tip="hwShown(component).assemblyNote" aria-label="About this part">?</HouseButton></strong>
                    </div>
                    <div class="spec-stats">
                      <div class="stat"><span class="stat-key">{{ component === 'injector' ? (hwShown(component).equivalentCCPerCylinder ? 'Equivalent per cylinder' : 'Per injector') : 'Per pump' }}</span><span class="stat-value">{{ hwFlow(hwShown(component),component) }}<small>{{ component === 'injector' ? 'cc/min' : 'L/h' }}</small></span><span class="hw-delta" :class="hwDelta(component, hwShown(component), 'flow')?.tone">{{ hwDelta(component, hwShown(component), 'flow')?.text || '' }}</span></div>
                      <div class="stat"><span class="stat-key">Supports</span><span class="stat-value">{{ pw(hardwarePower(hwShown(component))) }}<small>{{ pwU }}</small></span><span class="hw-delta" :class="hwDelta(component, hwShown(component), 'hp')?.tone">{{ hwDelta(component, hwShown(component), 'hp')?.text || '' }}</span></div>
                    </div>
                    <div class="spec-buy">
                      <span v-if="engine.state.hardware?.[component]===hwShown(component).id" class="pill ok">Installed</span>
                      <template v-else>
                        <span class="money big-money">{{ hwShown(component).owned || !panel.data.career ? 'Free' : `$${Number(hwShown(component).price).toLocaleString()}` }}</span>
                        <HouseButton type="button" class="btn btn-primary" :disabled="panel.busy || dirty || !hardwareAccess || hwPreviewing(component)" @click="buyHardware(component,hwShown(component))">{{ hwShown(component).owned || !panel.data.career ? 'Install' : 'Buy & install' }}</HouseButton>
                      </template>
                    </div>
                  </div>
                </section>
                </div>
              </template>

              <!-- ================= TANK ================= -->
              <template v-else-if="workspaceTab === 'tank'">
                <div class="tank-grid">
                  <section class="panel" aria-label="Current tank blend">
                    <div class="row"><span class="kicker"><FuelIcon name="tank" />In your tank</span>
                      <HouseAccordion v-if="tanks.length>1" class="menu" :class="{disabled:panel.busy}" data-fuel-menu="menu7" v-model="menus.menu7" id="fuel-menu7" :title="(tankName)" :disabled="panel.busy"><div class="pop"><HouseButton v-for="item in tanks" :key="item.name" type="button" :class="{on:tankName===item.name}" @click="chooseTank($event, item.name, false)">{{ item.name }}</HouseButton></div></HouseAccordion>
                      <span v-if="tank && tank.liters>0" class="pill push" :class="tankSuitability ? 'warn' : 'ok'">{{ tankSuitability ? 'Check fuel' : `Works with ${kitShort}` }}</span>
                    </div>
                    <template v-if="tank && tank.liters > 0">
                      <div class="row baseline"><span class="big">{{ tankBlendName }}</span><span class="faint">{{ tankSubLabel }}</span><span class="push strong">{{ vol(tank.liters) }}<span class="faint"> / {{ vol(tank.capacity,0) }} {{ volU }}</span></span></div>
                      <div class="blend" role="img" :aria-label="tankBlendDescription"><i v-for="part in tankParts" :key="part.label" :style="{width:part.percent+'%',background:part.color}"></i></div>
                      <div class="row faint"><span v-for="part in tankParts" :key="part.label"><i class="sw" :style="{background:part.color}"></i>{{ part.label }} {{ fmt(part.percent,1) }}%</span></div>
                      <p v-if="tankSuitability" class="alert warn"><span>{{ tankSuitability }}</span></p>
                    </template>
                    <p v-else class="muted">Tank empty. Choose your next fuel at a pump.</p>
                  </section>
                  <section v-if="tank && tank.liters>0" class="panel" aria-label="Drain fuel">
                    <div class="row"><span class="kicker"><FuelIcon name="droplet" />Drain</span><span class="faint">Free. The fuel is thrown away</span></div>
                    <div class="row baseline"><label class="big"><input class="big-input" type="number" :aria-label="`${volName} to drain`" v-model.number="drainShown" min="0" :max="toVol(tank.liters)" step="0.1" :disabled="panel.busy || !serviceAccess"><small>{{ volU.toUpperCase() }} OUT</small></label><span class="push faint">{{ drainValid ? `${volText(drainRemaining)} left, same blend` : `Choose 0 to ${volText(tank.liters)}` }}</span></div>
                    <HouseSlider  aria-label="Fuel drain slider" v-model.number="drainShown" min="0" :max="toVol(tank.liters)" step="0.1" :disabled="panel.busy || !serviceAccess" />
                    <div class="scale"><span>0</span><span>Empty tank</span></div>
                    <p v-if="!serviceAccess" class="faint">Draining is available at a garage computer.</p>
                    <div class="row"><HouseButton type="button" class="btn sm" :disabled="panel.busy || !serviceAccess" @click="drainLiters=Number(tank.liters)">Drain everything</HouseButton><HouseButton type="button" class="btn btn-danger push" :disabled="panel.busy || !serviceAccess || !drainValid || drainLiters<=0" @click="requestService('drain',$event)">Drain {{ drainValid ? volText(drainLiters) : '—' }}</HouseButton></div>
                  </section>
                </div>
              </template>
            </div>
            <p v-else class="banner">No supported combustion engine is available.</p>
          </fieldset></div>

          <footer v-if="engine && draft && !isHardware" class="rfoot">
            <span class="pill" :class="dirty ? 'accent' : 'ok'">{{ dirty ? (changedCount ? `${changedCount} changed cells` : 'Unapplied changes') : engine.control?.dormantCalibration ? 'Stored map' : engine.control?.mode === 'native' ? 'Native' : 'Installed' }}</span>
            <span class="note">{{ dirty ? 'Nothing changes on the car until you apply.' : engine.control?.dormantCalibration ? 'Older map retained but inactive. Apply it deliberately to activate its settings.' : engine.control?.mode === 'native' ? 'Original engine behavior is active. Applying a change enables fuel tuning.' : 'Your applied fuel changes are active.' }}</span>
            <HouseAccordion class="menu push up" data-fuel-menu="menu8" v-model="menus.menu8" id="fuel-menu8" :title="&quot;Saved maps&quot;"><div class="pop right up presets-pop">
              <div class="row"><input v-model="presetName" class="text-input" aria-label="Map name" placeholder="Name this map" maxlength="40" @keydown.enter.prevent="savePreset"><HouseButton type="button" class="btn sm btn-primary" :disabled="!presetName.trim() || panel.busy" @click="savePreset">Save</HouseButton></div>
              <hr>
              <p v-if="!presetNames.length" class="faint pad">No saved maps yet.</p>
              <div v-for="name in presetNames" :key="name" class="saved-map-row">
                <HouseButton class="saved-map-name" type="button" :class="{on:selectedPreset===name}" :disabled="panel.busy || presetDialogOpen" @click="loadPresetNamed($event,name)">{{ name }}</HouseButton>
                <HouseButton class="saved-map-action" :aria-label="'Rename ' + name" :disabled="panel.busy || presetDialogOpen" @click="renamePreset(name)">Rename</HouseButton>
                <HouseButton class="saved-map-action danger" :aria-label="'Delete ' + name" :disabled="panel.busy || presetDialogOpen" @click="deletePreset(name)">Delete</HouseButton>
              </div>
              <hr><span class="faint pad">Loading only changes the draft.</span>
            </div></HouseAccordion>
            <HouseButton type="button" class="btn" :disabled="!dirty || panel.busy" @click="loadDraft">Discard</HouseButton>
            <HouseButton type="button" class="btn btn-primary" :disabled="(!dirty && !engine.control?.dormantCalibration) || panel.busy" @click="apply">Apply to engine</HouseButton>
          </footer>
        </template>
      </template>

      <div v-if="editorMessage" class="toast" role="status"><i></i><span>{{ editorMessage }}</span><HouseButton type="button" aria-label="Dismiss status" @click="dismissStatus">×</HouseButton></div>

      <div v-if="drawer==='clipboard'" class="modal-backdrop" @keydown.stop="drawerKey"><button type="button" class="modal-scrim" tabindex="-1" aria-label="Cancel dialog" @click="closeDrawer"></button><section class="modal help-drawer" role="dialog" aria-modal="true" aria-label="Paste from text">
        <span class="kicker">Table</span><h2>Paste from text</h2><p class="muted">Tab-separated rows. One value fills the selection; a block starts at its top-left cell.</p>
        <textarea aria-label="Table clipboard" v-model="clipboardText" rows="8" placeholder="Paste values here"></textarea>
        <div class="acts"><HouseButton type="button" class="btn drawer-close" @click="closeDrawer">Cancel</HouseButton><HouseButton type="button" class="btn btn-primary" @click="pasteText(clipboardText);closeDrawer()">Paste into selection</HouseButton></div>
      </section></div>

      <div v-if="serviceAction" class="modal-backdrop" @keydown.stop="serviceKey"><button type="button" class="modal-scrim" tabindex="-1" aria-label="Cancel dialog" @click="cancelService"></button><section class="modal service-confirm" role="dialog" aria-modal="true" aria-labelledby="serviceTitle">
        <span class="kicker">{{ serviceAction==='drain' ? 'Tank' : 'Fuel system' }}</span><h2 id="serviceTitle">{{ serviceHeading }}</h2>
        <p class="muted">{{ serviceBlurb }}</p>
        <div class="acts"><HouseButton type="button" class="btn" :disabled="serviceWorking" @click="cancelService">Cancel</HouseButton><HouseButton type="button" class="btn" :class="serviceAction==='drain' ? 'btn-danger' : 'btn-primary'" :disabled="serviceWorking" @click="confirmService">{{ serviceWorking ? 'Working…' : serviceConfirmLabel }}</HouseButton></div>
      </section></div>

      <div v-if="resetOpen" class="modal-backdrop" @keydown.stop="resetKey"><button type="button" class="modal-scrim" tabindex="-1" aria-label="Cancel dialog" @click="cancelReset"></button><section class="modal reset-dialog" role="dialog" aria-modal="true" aria-labelledby="resetTitle">
        <span class="kicker">Tune</span><h2 id="resetTitle">Reset the whole tune?</h2>
        <p class="muted">Mixture, timing, boost, Decel, boost cut and phone trims go back to safe stock values. RPM columns, hardware, fuel and saved maps stay. You can still undo, and nothing changes until you apply. A reset does not repair engine damage.</p>
        <div class="acts"><HouseButton type="button" class="btn" :disabled="resetWorking" @click="cancelReset">Keep editing</HouseButton><HouseButton type="button" class="btn btn-danger" :disabled="resetWorking" @click="confirmReset">{{ resetWorking ? 'Preparing…' : 'Reset draft' }}</HouseButton></div>
      </section></div>

      <div v-if="discardOpen" class="modal-backdrop" @keydown.stop="discardKey"><button type="button" class="modal-scrim" tabindex="-1" aria-label="Cancel dialog" @click="cancelDiscard"></button><section class="modal discard-dialog" role="dialog" aria-modal="true" aria-labelledby="discardTitle">
        <span class="kicker">Unsaved changes</span><h2 id="discardTitle">Close without applying?</h2>
        <p class="muted">Your draft changes will be lost. The car keeps its current tune.</p>
        <div class="acts"><HouseButton type="button" class="btn" @click="cancelDiscard">Keep editing</HouseButton><HouseButton type="button" class="btn btn-danger" @click="discardAndClose">Discard</HouseButton></div>
      </section></div>
    </section>
  </div>
</template>
<script setup>


import { ref, shallowRef, computed, onUnmounted, nextTick, watch } from 'vue'
import FuelBoostEditor from './FuelBoostEditor.vue'
import FuelIcon from './FuelIcon.vue'
import { adaptFuelBoost, gearBoost, resizeFuelTune, validFuelTune, conservativeFuelTune, sameFuelTune, decelSettings, simpleFuelTune, simpleFuelSettings, boostCutMargin, BOOST_CUT_STOCK, BOOST_CUT_MIN, BOOST_CUT_MAX } from '../utils/fuelMapEditor'

import { useBridge } from '@/bridge'

import { BngButton } from '@/common/components/base'
import { HouseButton, HouseMenu, HouseSlider, HouseAccordion, openHouseConfirmation, openHousePrompt } from '../../career/components/house/index.js'

import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'

import { fuelPressureUnits } from '../utils/fuelPressureUnits'
import { fuelDisplayUnits } from '../utils/fuelDisplayUnits'

import { installLuaBridgeFallbacks } from '../../career/utils/installLuaBridgeFallbacks'

installLuaBridgeFallbacks()

const { lua, events, units } = useBridge()
const pressureSystem=ref(units.uiUnits.uiUnitPressure)
const pressure=computed(()=>fuelPressureUnits(units,pressureSystem.value))
// Volume, power and temperature follow the game's unit settings too; fuel stays in litres internally.
const unitSystems=ref({volume:units.uiUnits.uiUnitVolume,weight:units.uiUnits.uiUnitWeight,power:units.uiUnits.uiUnitPower,temperature:units.uiUnits.uiUnitTemperature})
function unitSettingsChanged(data){const v=data.values||{};unitSystems.value={volume:v.uiUnitVolume||unitSystems.value.volume,weight:v.uiUnitWeight||unitSystems.value.weight,power:v.uiUnitPower||unitSystems.value.power,temperature:v.uiUnitTemperature||unitSystems.value.temperature}}
events.on('SettingsChanged',unitSettingsChanged)
onUnmounted(()=>events.off('SettingsChanged',unitSettingsChanged))
const shown=computed(()=>fuelDisplayUnits(units,unitSystems.value))
const volU=computed(()=>shown.value.volumeUnit),volName=computed(()=>shown.value.volumeName),wtU=computed(()=>shown.value.weightUnit),wtName=computed(()=>shown.value.weightName),pwU=computed(()=>shown.value.powerUnit)
const vol=(liters,decimals=1)=>shown.value.volume(liters,decimals)
const capText=liters=>{const v=toVol(liters);return vol(liters,Math.abs(v-Math.round(v))<.05?0:1)}
const volText=(liters,decimals=1)=>`${vol(liters,decimals)} ${volU.value}`
const toVol=liters=>Math.round(shown.value.toVolume(Number(liters)||0)*10)/10
const perVol=pricePerLiter=>shown.value.perVolume(pricePerLiter)
const wt=(kg,decimals=1)=>shown.value.weight(kg,decimals)
const toWt=kg=>Math.round(shown.value.toWeight(Number(kg)||0)*10)/10
const perWt=pricePerKg=>shown.value.perWeight(pricePerKg)
const pw=hp=>shown.value.power(hp)
const tempText=(celsius,decimals=0)=>shown.value.temperature(celsius,decimals)
const tempDelta=(celsius,decimals=0)=>shown.value.temperatureDelta(celsius,decimals)
function pressureSettingsChanged(data){if(data.values?.uiUnitPressure)pressureSystem.value=data.values.uiUnitPressure}
events.on('SettingsChanged',pressureSettingsChanged)
onUnmounted(()=>events.off('SettingsChanged',pressureSettingsChanged))

const menus = ref({})
const panel = ref({open:false}), engineName = ref(''), tankName = ref(''), draft = ref(null), dirty = ref(false)

const gradeId = ref('regular'), amount = ref(10), acknowledged = ref(false), quoteData = ref(null)

const field = ref('lambda'), row = ref(7), selected = ref({y:7,x:0}), presetName = ref(''), selectedPreset = ref('')

const preview = ref([]), flushConfirm = ref(false)

let draftRevision=0
let identity = '', waitingApply = false, applyWasBusy = false, previewGeneration = 0, quoteGeneration = 0

const clone = value => value == null ? value : JSON.parse(JSON.stringify(value))
const requestContext = () => ({vehicleId:panel.value.data?.vehicleId,generation:panel.value.data?.generation,mode:panel.value.mode,revision:draftRevision})

const fmt = (n, digits=2) => Number.isFinite(Number(n)) ? Number(n).toFixed(digits) : '—'

const isPump = computed(() => panel.value.mode === 'pump')

const engines = computed(() => Object.values(panel.value.data?.engines || {}))

// At the pump, only the tanks it sells a fuel for.
// Lua sends an empty grade list (a charger) as an object, not an array.
const pumpGrades = computed(() => Object.values(panel.value.grades || {}))
const tanks = computed(() => Object.values(panel.value.data?.tanks || {}).filter(t=>!isPump.value || pumpGrades.value.some(g=>!!g.diesel===(t.energyType==='diesel'))))

const engine = computed(() => panel.value.data?.engines?.[engineName.value])
// Same endpoint as rlsFuelModel.rpmAxis: the last of 12 columns spaced to the limiter.
const rpmAxisEnd = maxRPM => Math.floor(Math.max(1000, Number(maxRPM) || 6500) + 0.5)
const limiterRpm = computed(() => engine.value ? rpmAxisEnd(engine.value.profile.maxRPM) : null)
const mapRpm = computed(() => engine.value?.state?.tune?.rpm?.at(-1))
const rpmRangeDiffers = computed(() => limiterRpm.value != null && mapRpm.value !== limiterRpm.value)
const limiterRpmText = computed(() => limiterRpm.value == null ? '' : limiterRpm.value.toLocaleString() + ' RPM')
const mapRpmText = computed(() => mapRpm.value == null ? '' : Number(mapRpm.value).toLocaleString() + ' RPM')

const tank = computed(() => panel.value.data?.tanks?.[tankName.value])

const freeSpace = computed(() => Math.max(0, (tank.value?.capacity || 0) - (tank.value?.liters || 0)))

const readings = computed(() => {

  const t=engine.value?.telemetry || {}

  return [{label:'RPM',value:fmt(t.rpm,0)},{label:'Load',value:`${fmt(t.load*100,0)}%`},

    {label:'Estimated AFR',value:fmt(t.afr)},{label:'Ethanol',value:`${fmt(t.ethanol*100,1)}%`},
    {label:'Nitromethane',value:`${fmt((t.nitromethane || 0)*100,1)}%`},{label:'Exhaust burning',value:`${fmt((t.exhaustBurnW || 0)/1000,1)} kW`},{label:'Methanol',value:`${fmt((t.methanol || 0)*100,1)}%`},{label:'Estimated charge cooling',value:tempDelta(t.chargeCoolingC,1)},
    {label:'Estimated cold-running severity',value:fmt(t.coldRunningSeverity)},

    {label:'Estimated delivery duty',value:`${fmt(t.deliveryDuty*100,1)}%`},{label:'Estimated knock',value:fmt(t.knock)},
    {label:'Estimated protection retard',value:`${fmt(t.knockRetard,1)}°`},
    {label:'Effective ignition trim',value:`${fmt(t.effectiveTiming,1)}°`},

    {label:t.pressureEstimated ? 'Estimated manifold' : 'Manifold absolute',value:pressure.value.kPaText(t.manifoldPressureKPa)},

    {label:'Oil',value:tempText(t.oilTemperature,1)},{label:'Coolant',value:tempText(t.coolantTemperature,1)}]

})

let statusArmed=false
const seenBoostAdaptations=new Set()
function adaptDraftBoost(tune){
  if(!tune?.boost)return false
  const installed=engine.value
  return installed && adaptFuelBoost(tune,installed.boostGears || [],(installed.profile.factoryBoostPsi || 0)+(installed.profile.wastegateHalfRangePsi || 0))
}
function receiveBoostAdaptation(){
  if(!engine.value)return
  const adaptation=engine.value.boostAdaptation
  const draftAdapted=adaptDraftBoost(draft.value)
  // History may contain boost even when the current draft has no boost table.
  for(const tune of [...undoStack.value,...redoStack.value])adaptDraftBoost(tune)
  if(adaptation && draftRevision===adaptation.previousRevision && engine.value.state.revision===adaptation.revision)draftRevision=adaptation.revision
  if(draftAdapted){
    syncSimpleControls();lastSnapshot=clone(draft.value)
    dirty.value=!sameFuelTune(draft.value,engine.value.state.tune)
    preview.value=[];previewGeneration++
  }
  if(!adaptation || engine.value.state.revision!==adaptation.revision)return
  const key=`${identity}:${engineName.value}:${adaptation.revision}`
  if(seenBoostAdaptations.has(key))return
  seenBoostAdaptations.add(key);say(adaptation.message)
}
function receive(value) {

  const key=`${value.data?.vehicleId}:${value.data?.generation}:${value.mode}`

  const changed=key!==identity || !panel.value.open

  panel.value={...panel.value,...value}
  if (value.paused) setTextEntry(false)

  if (!value.open) {dirty.value=false;waitingApply=false;previewGeneration++;clearEditorContext();setTextEntry(false);pendingPreset=null;statusArmed=false;return}

  if (changed) {clearEditorContext();identity=key;engineName.value=engines.value[0]?.name || '';tankName.value=tanks.value[0]?.name || '';loadDraft();clearQuote();flushConfirm.value=false}

  if (waitingApply && value.busy) applyWasBusy=true
  // A periodic snapshot can arrive between the click and its busy acknowledgment.
  // It is not the completion of this request, even if it repeats an older status.
  if (waitingApply && applyWasBusy && !value.busy) {waitingApply=false;applyWasBusy=false;if(value.message==='Completed')loadDraft()}

  if (pendingPreset && value.busy) pendingPreset.wasBusy=true
  if (pendingPreset && pendingPreset.wasBusy && !value.busy) {
    const saved=pendingPreset
    pendingPreset=null
    const presets=engine.value?.state?.presets || {}
    const confirmed=saved.kind==='delete' ? !Object.hasOwn(presets,saved.name) : Object.hasOwn(presets,saved.name)
    if (value.message==='Completed' && identity===saved.identity && engineName.value===saved.engine && confirmed) {
      if (saved.kind==='delete') {if(selectedPreset.value===saved.name)selectedPreset.value=''}
      else if (saved.kind==='rename') {if(selectedPreset.value===saved.previousName)selectedPreset.value=saved.name}
      else {selectedPreset.value=saved.name;presetName.value=''}
      // Only this save may advance the draft guard; an intervening update must
      // still force a reload before an unsaved draft can be applied.
      if (draftRevision===saved.revision && engine.value.state.revision===saved.revision+1) draftRevision++
    }
  }

  // Hardware, presets and phone trims can advance the revision without an Apply.
  // Refresh only clean drafts; unsaved edits must retain their stale-write guard.
  if (engine.value && (!draft.value || (!dirty.value && !editingCell.value && draftRevision !== (engine.value.state.revision || 0)))) loadDraft()

  if (value.quote && value.quote.clientToken===quoteGeneration) quoteData.value=value.quote

  if (value.busy) {quoteData.value=null;statusArmed=true}
  // Later snapshots repeat the same status. Show it once, until the next operation.
  if (!isPump.value && (value.message==='Completed' || value.message==='Map preset saved')) {if(statusArmed){statusArmed=false;say(value.message)}panel.value.message=''}

  receiveBoostAdaptation()

}

events.on('RlsFuelPanel',receive)

onUnmounted(() => {events.off('RlsFuelPanel',receive);previewGeneration++})

function loadDraft(){draftRevision=engine.value?.state.revision ?? 0;simpleAFREntry.value=null;nitrousEntry.value=null;decelPreview.value={};previewGeneration++;draft.value=engine.value ? clone(engine.value.state.tune) : null;dirty.value=false;preview.value=[];if(draft.value){const values=simpleFuelSettings(draft.value,nitroTune.value);simpleLambda.value=values.lambda;simpleTiming.value=values.timing}}

function edited(){dirty.value=true;preview.value=[];previewGeneration++}

function cellStyle(y,x){const v=Number(gridValues.value[y][x]);const [lo,hi]=gridColorRange.value;const f=Math.max(0,Math.min(1,(v-lo)/(hi-lo)));return {background:`hsl(${200-180*f} 48% 23%)`}}

function operatingCell(y,x){const t=engine.value?.telemetry;if(!t || isBoost.value)return false;const nearest=(a,v)=>a.reduce((best,n,i)=>Math.abs(n-v)<Math.abs(a[best]-v)?i:best,0);return y===nearest(draft.value.load,t.load) && x===nearest(draft.value.rpm,t.rpm)}

function adjust(direction){const {y,x}=selected.value;const lo=field.value==='lambda'?.6:-20,hi=field.value==='lambda'?1.4:20,step=field.value==='lambda'?.01:.5;gridValues.value[y][x]=Math.max(lo,Math.min(hi,Number((Number(gridValues.value[y][x])+direction*step).toFixed(2))));edited()}

function moveCell(event,y,x){if(!event.altKey)return;const delta={ArrowLeft:[0,-1],ArrowRight:[0,1],ArrowUp:[-1,0],ArrowDown:[1,0]}[event.key];if(!delta)return;event.preventDefault();const table=event.target.closest('tbody');table?.rows[Math.max(0,Math.min(7,y+delta[0]))]?.cells[Math.max(0,Math.min(draft.value.rpm.length-1,x+delta[1]))+1]?.querySelector('input')?.focus()}

async function resetConservative(){const g=++previewGeneration;const key=identity;const name=engineName.value;const tune=await lua.overhaul_career_maintenance_fuelSystem.conservativeMap(name,requestContext());if(tune && g===previewGeneration && key===identity && name===engineName.value){draft.value=tune;edited();return true}return false}

async function apply(){waitingApply=true;applyWasBusy=false;if(await lua.overhaul_career_maintenance_fuelSystem.applyTune(engineName.value,clone(draft.value),requestContext())===false)waitingApply=false}
async function recalibrateRpm(){if(dirty.value||panel.value.busy||!rpmRangeDiffers.value)return;waitingApply=true;applyWasBusy=false;if(await lua.overhaul_career_maintenance_fuelSystem.recalibrateRpm(engineName.value,requestContext())===false)waitingApply=false}

let pendingPreset=null
const presetDialogOpen=ref(false)
const presetNames=computed(()=>Object.keys(engine.value?.state?.presets||{}))
function validPresetName(value){const name=typeof value==='string'?value.trim():'';return name.length>0 && new TextEncoder().encode(name).length<=40 && !/[\u0000-\u001f\u007f]/.test(name)}
async function savePreset(){
  const name=presetName.value.trim();if(!name||panel.value.busy||pendingPreset)return
  if(!validPresetName(name)){say('Enter a valid map name, using fewer characters if needed.');return}
  const pending={name,identity,engine:engineName.value,revision:draftRevision,wasBusy:false}
  pendingPreset=pending
  if(await lua.overhaul_career_maintenance_fuelSystem.savePreset(engineName.value,name,clone(draft.value),requestContext())===false && pendingPreset===pending) pendingPreset=null
}

function escapeMapName(name){return String(name).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;')}
async function managePreset(kind,name){
  if(panel.value.busy || pendingPreset || presetDialogOpen.value || !Object.hasOwn(engine.value?.state?.presets || {},name))return
  const owner=identity,ownerEngine=engineName.value
  const expected={...requestContext(),revision:engine.value.state.revision || 0}
  presetDialogOpen.value=true
  setTextEntry(false)
  try {
    let newName
    if(kind==='delete') {
      const confirmed=await openHouseConfirmation('Delete saved map?',`Delete <strong>${escapeMapName(name)}</strong>? The engine keeps its current settings.`,[
        {label:'Cancel',value:false,extras:{cancel:true}},
        {label:'Delete',value:true,extras:{confirm:true,destructive:true}},
      ])
      if(!confirmed)return
    } else {
      newName=await openHousePrompt('', 'Rename saved map', {defaultValue:name,maxLength:40,confirmLabel:'Rename',
        validate:validPresetName,errorMessage:'Enter a valid map name, using fewer characters if needed.'})
      if(typeof newName!=='string' || newName.trim()===name)return
      newName=newName.trim()
    }
    if(!panel.value.open || identity!==owner || engineName.value!==ownerEngine || panel.value.busy || pendingPreset)return
    const pending={kind,name:kind==='rename'?newName:name,previousName:name,identity:owner,engine:ownerEngine,revision:expected.revision,wasBusy:false}
    pendingPreset=pending
    const accepted=kind==='delete'
      ? await lua.overhaul_career_maintenance_fuelSystem.deletePreset(ownerEngine,name,expected)
      : await lua.overhaul_career_maintenance_fuelSystem.renamePreset(ownerEngine,name,newName,expected)
    if(accepted===false && pendingPreset===pending)pendingPreset=null
  } catch {
    pendingPreset=null
    say('The saved map could not be updated. Try again.')
  } finally {presetDialogOpen.value=false}
}
async function deletePreset(name){return managePreset('delete',name)}
async function renamePreset(name){return managePreset('rename',name)}

function loadPreset(){draft.value=clone(engine.value.state.presets[selectedPreset.value]);const adapted=adaptDraftBoost(draft.value);edited();return adapted}

function convert(kind){waitingApply=true;lua.overhaul_career_maintenance_fuelSystem.convert(engineName.value,kind,requestContext())}

function setDeliveryStage(stage){waitingApply=true;lua.overhaul_career_maintenance_fuelSystem.setDeliveryStage(engineName.value,stage,requestContext())}
function removeConversion(){waitingApply=true;lua.overhaul_career_maintenance_fuelSystem.removeConversion(engineName.value,requestContext())}

function flush(){if(!flushConfirm.value){flushConfirm.value=true;return}flushConfirm.value=false;lua.overhaul_career_maintenance_fuelSystem.flush(tankName.value)}

function clearQuote(){flushConfirm.value=false;quoteGeneration++;quoteData.value=null;acknowledged.value=false;lua.overhaul_career_maintenance_fuelSystem.invalidateQuote()}
const gradeNames={diesel:{name:'Diesel',detail:'Diesel fuel'},regular:{name:'Regular',detail:'87 AKI; ethanol: E10'},premium:{name:'Premium',detail:'93 AKI; ethanol: E10'},e85:{name:'E85',detail:'85% ethanol'},m100:{name:'M100',detail:'Methanol'},nitro90:{name:'Nitro 90',detail:'90% nitro; methanol: 10%'}};
function gradePresentation(grade){return gradeNames[grade.id] || {name:grade.label,detail:''}}
function fuelBlendLabel(blend){if(!blend)return '';if((blend.nitromethane||0)>.001)return `${fmt(blend.nitromethane*100,0)}% nitro; ${fmt((blend.methanol||0)*100,0)}% methanol`;if((blend.methanol||0)>.001)return `${fmt(blend.methanol*100,0)}% methanol`;return `${fmt(blend.aki,0)} AKI; ethanol: E${fmt((blend.ethanol||0)*100,0)}`}
const estimatedFuelPrice=computed(()=>Math.max(0,Number(amount.value)||0)*(panel.value.pricePerL||0)*(pumpGrades.value.find(g=>g.id===gradeId.value)?.priceFactor||0));
function chooseGrade(id){gradeId.value=id;lastSale.value=null;clearQuote()}
// A diesel tank gets the diesel key, a gasoline tank the gasoline grades; switching tank picks the first that fits.
const tankGrades=computed(()=>pumpGrades.value.filter(g=>!!g.diesel===(tank.value?.energyType==='diesel')));
watch(tankGrades,list=>{if(list.length&&!list.some(g=>g.id===gradeId.value))gradeId.value=list[0].id},{immediate:true});
// The amount is litres; the input, slider and presets work in the chosen volume unit.
const freeShown=computed(()=>toVol(freeSpace.value))
const amountPresets=computed(()=>shown.value.presets)
const amountShown=computed({get:()=>toVol(amount.value),set:value=>{amount.value=Math.min(freeSpace.value,Math.max(0,shown.value.fromVolume(Number(value)||0)));lastSale.value=null;clearQuote()}})
function stepAmount(direction){signedAmount.value=Math.min(slotFree.value,Math.max(signedMin.value,Math.round(signedAmount.value)+direction))}
// Like a real pump, the display keeps the last sale until the next order starts.
// Lua reports it as "Delivered <L> L · $<paid>[ · <failure>]"; only a failure stays as a banner.
const lastSale=ref(null);
const SALE_MESSAGE=/^Delivered ([\d.]+) L · \$([\d.]+)/,NITROUS_SALE=/^Filled ([\d.]+) kg nitrous · \$([\d.]+)/,CHARGE_SALE=/^Charged ([\d.]+) kWh · \$([\d.]+)/,DRAIN_DONE=/^Drained [\d.]+ L/;
watch(()=>panel.value.message,message=>{if(!isPump.value)return;const text=String(message||''),m=text.match(SALE_MESSAGE),n=text.match(NITROUS_SALE),c=text.match(CHARGE_SALE);if(m)lastSale.value={liters:Number(m[1]),paid:Number(m[2])};else if(n)lastSale.value={kg:Number(n[1]),paid:Number(n[2])};else if(c)lastSale.value={kwh:Number(c[1]),paid:Number(c[2])}});
watch(()=>panel.value.open,open=>{if(!open)lastSale.value=null});
const bannerMessage=computed(()=>{const m=String(panel.value.message||'');if(!m||m==='Completed')return '';if(isPump.value&&(SALE_MESSAGE.test(m)||NITROUS_SALE.test(m)||CHARGE_SALE.test(m)))return m.split(' · ').slice(2).join(' · ');if(isPump.value&&DRAIN_DONE.test(m))return m.split(' · ').slice(1).join(' · ');return m});
const selectedGrade=computed(()=>pumpGrades.value.find(g=>g.id===gradeId.value)||null);
const selectedGradeName=computed(()=>selectedGrade.value?gradePresentation(selectedGrade.value).name:'');
const selectedPricePerL=computed(()=>panel.value.data?.career?(panel.value.pricePerL||0)*(selectedGrade.value?.priceFactor||0):0);
const pumpAddLiters=computed(()=>Math.min(Math.max(0,Number(amount.value)||0),freeSpace.value));
// The readout shows what was bought, like a real pump: the live delivery, then the last sale.
const pumpTotal=computed(()=>{if(!panel.value.data?.career)return 0;if(panel.value.pumping)return Number(panel.value.pumping.paid)||0;return lastSale.value?lastSale.value.paid:0});
const tankLevel=computed(()=>{const t=tank.value;return t?Math.min(1,Math.max(0,t.liters/Math.max(.001,t.capacity))):0});
// Striped part of the tank bar: the order before pumping, what is still to come while pumping.
const tankAdding=computed(()=>{const t=tank.value;if(!t)return 0;const p=panel.value.pumping;if(p?.drain)return 0;const liters=p?Math.max(0,(Number(p.total)||0)-(Number(p.delivered)||0)):pumpAddLiters.value;return Math.min(1-tankLevel.value,liters/Math.max(.001,t.capacity))});
// The big key on each grade button, like the octane number on a real pump.
const gradeKeys={diesel:'D',regular:'87',premium:'93',e85:'E85',m100:'M100',nitro90:'N90'};
function gradeCode(grade){return gradeKeys[grade.id]||(Number.isFinite(Number(grade.aki))?fmt(grade.aki,0):String(grade.label||'').slice(0,4))}
// Nitrous bottles and batteries sit next to the fuel tanks in the tank switcher; the pump sells
// nitrous by weight (kg in Lua) and charge by the kWh.
const nitrous=computed(()=>panel.value.nitrous||null);
const charge=computed(()=>panel.value.charge||null);
// Lua sends an empty list as {}, so read it like the tanks.
const bottles=computed(()=>Object.values(nitrous.value?.bottles||{}));
const batteries=computed(()=>Object.values(charge.value?.batteries||{}));
// Both in one shape: amount and capacity in kg (nitrous) or kWh (battery).
const stores=computed(()=>[...bottles.value.map(b=>({kind:'n2o',key:'n2o:'+b.name,name:b.name,amount:b.kg,capacity:b.capacityKg})),
 ...batteries.value.map(b=>({kind:'battery',key:'kwh:'+b.name,name:b.name,amount:b.kwh,capacity:b.capacityKWh}))]);
const storeKey=ref(''),storeAdd=ref(0);
const store=computed(()=>stores.value.find(s=>s.key===storeKey.value)||null);
const battery=computed(()=>store.value?.kind==='battery');
const storeFree=computed(()=>store.value?Math.max(0,store.value.capacity-store.value.amount):0);
const storeAddAmount=computed(()=>Math.min(Math.max(0,Number(storeAdd.value)||0),storeFree.value));
const storeOffered=computed(()=>battery.value?!!charge.value?.offered:!!nitrous.value?.offered);
const storeUnitPrice=computed(()=>(battery.value?charge.value?.pricePerKWh:nitrous.value?.pricePerKg)||0);
const storePrice=computed(()=>panel.value.data?.career?Math.round(storeAddAmount.value*storeUnitPrice.value*100)/100:0);
const storeGradeName=computed(()=>battery.value?'Charge':'Nitrous');
const storePayLabel=computed(()=>!storeOffered.value?'Not sold here':storeShort.value?'Not enough money':storeAddAmount.value<=0?(battery.value?'Battery is full':'Bottle is full'):battery.value?'Charge battery':'Fill bottle');
// Nitrous shows in the player's weight unit; charge is always kWh.
const storeUnit=computed(()=>battery.value?'kWh':wtU.value),storeUnitName=computed(()=>battery.value?'kWh':wtName.value);
const toStore=x=>battery.value?Math.round((Number(x)||0)*10)/10:toWt(x);
const storeText=(x,decimals=1)=>battery.value?fmt(x,decimals):wt(x,decimals);
const perStore=price=>battery.value?price:perWt(price);
function chooseStore(key){if(panel.value.busy||panel.value.pumping)return;storeKey.value=key;lastSale.value=null;storeAdd.value=storeFree.value}
function buyStore(){if(!store.value||storeAddAmount.value<=0)return;lastSale.value=null;const pump=lua.overhaul_career_maintenance_fuelSystem;if(battery.value)pump.purchaseCharge(store.value.name,storeAddAmount.value);else pump.purchaseNitrous(store.value.name,storeAddAmount.value)}
watch(()=>panel.value.open,open=>{if(!open){storeKey.value='';storeAdd.value=0}});
// After a fill the store is full, so the amount follows the new free space.
watch(storeFree,free=>{if(storeAdd.value>free)storeAdd.value=free});
// An electric car has no fuel tank: start on its battery.
// Keyed on the visit too: closing clears the choice, and the same car reopens with the same key.
watch(()=>panel.value.open&&!tanks.value.length&&stores.value[0]?.key,key=>{if(key&&!store.value)chooseStore(key)},{immediate:true});
// One set of tank, amount and readout controls, for the selected fuel tank, bottle or battery.
const slotLevel=computed(()=>store.value?Math.min(1,store.value.amount/Math.max(.001,store.value.capacity)):tankLevel.value);
const slotAdding=computed(()=>store.value?Math.min(1-slotLevel.value,storeAddAmount.value/Math.max(.001,store.value.capacity)):tankAdding.value);
const slotUnit=computed(()=>store.value?storeUnit.value:volU.value);
const slotFree=computed(()=>store.value?toStore(storeFree.value):freeShown.value);
const slotPresets=computed(()=>battery.value?[5,10,25]:store.value?shown.value.weightPresets:amountPresets.value);
const slotAmount=computed({get:()=>store.value?toStore(storeAdd.value):amountShown.value,set:value=>{if(store.value){const v=Math.max(0,Number(value)||0);storeAdd.value=Math.min(storeFree.value,battery.value?v:shown.value.fromWeight(v));lastSale.value=null}else amountShown.value=value}});
function fillSlot(){drainLiters.value=0;if(store.value){storeAdd.value=storeFree.value;lastSale.value=null}else{amount.value=freeSpace.value;lastSale.value=null;clearQuote()}}
const slotStatus=computed(()=>{if(draining.value)return `${volText(Math.max(0,tank.value.liters-drainLiters.value))} left`;if(panel.value.pumping)return `${vol(panel.value.pumping.delivered)} of ${volText(panel.value.pumping.total)} ${panel.value.pumping.drain?'drained':'pumped'}`;if(slotFree.value<.05)return '';return store.value?`${storeText(storeFree.value)} ${storeUnit.value} free`:`${volText(freeSpace.value)} free`});
const meterLabel=computed(()=>store.value?`${storeText(store.value.amount,2)} of ${storeText(store.value.capacity)} ${storeUnit.value}, adding ${storeText(storeAddAmount.value,2)}`:`${vol(tank.value?.liters)} of ${vol(tank.value?.capacity,0)} ${volU.value}, adding ${vol(pumpAddLiters.value)}`);
const lcdName=computed(()=>{const sale=lastSale.value;if(panel.value.pumping)return volName.value;if(sale)return sale.kwh!=null?'kWh':sale.kg!=null?wtName.value:volName.value;return store.value?storeUnitName.value:volName.value});
const lcdAmount=computed(()=>{if(panel.value.pumping)return vol(Number(panel.value.pumping.delivered)||0,2);if(lastSale.value?.kwh!=null)return fmt(lastSale.value.kwh,2);if(lastSale.value?.kg!=null)return wt(lastSale.value.kg,2);if(lastSale.value)return vol(lastSale.value.liters,2);return '0.00'});

function quote(){clearQuote();lua.overhaul_career_maintenance_fuelSystem.quote(tankName.value,gradeId.value,Number(amount.value),quoteGeneration)}

function purchase(){if(quoteData.value)lua.overhaul_career_maintenance_fuelSystem.purchaseFuel(quoteData.value.id,acknowledged.value)}

// Dialog cancellation must keep the return target captured when it opened.
function close(){if(discardOpen.value){cancelDiscard();return}if(serviceAction.value){cancelService();return}if(resetOpen.value){cancelReset();return}if(drawer.value){closeDrawer();return}const active=document.activeElement;const editingText=active?.closest?.('.fuel-shade')&&isEditableText(active);if(editingText){rememberFocus();active.blur()}if(editingCell.value){document.activeElement?.blur();editingCell.value=null}if(panel.value.busy&&!panel.value.pumping){say('Waiting for the current operation to finish.');return}if(dirty.value){if(!editingText)rememberFocus();discardOpen.value=true;nextTick(()=>document.querySelector('.discard-dialog button')?.focus());return}setTextEntry(false);lua.overhaul_career_maintenance_fuelSystem.close()}
function cancelDiscard(){discardOpen.value=false;restoreFocus()}
function discardAndClose(){discardOpen.value=false;loadDraft();setTextEntry(false);lua.overhaul_career_maintenance_fuelSystem.close()}
function discardKey(e){dialogKey(e,'.discard-dialog',cancelDiscard)}
let suppressNavBackUntil=0
// Rename and Delete dialogs own Back and Escape while they are open.
function onNavBack(){if(!panel.value.open||panel.value.paused||presetDialogOpen.value||performance.now()<suppressNavBackUntil)return;suppressNavBackUntil=performance.now()+150;if(Object.values(menus.value).some(Boolean)){dismissMenus();return}close()}
function onEscape(event){if(panel.value.paused||presetDialogOpen.value||event.key!=='Escape'||(!panel.value.open&&performance.now()>=suppressNavBackUntil))return;event.preventDefault();event.stopImmediatePropagation();if(!event.repeat)onNavBack()}
window.addEventListener('keydown',onEscape,true)
onUnmounted(()=>window.removeEventListener('keydown',onEscape,true))
// Engine navigation starts at the focused element, which can still be behind this overlay.
function onPanelNavigation(event){if(panel.value.paused||presetDialogOpen.value||!['back','menu'].includes(event.detail?.name)||(!panel.value.open&&performance.now()>=suppressNavBackUntil))return;event.preventDefault();event.stopImmediatePropagation();if(event.detail.value===1)onNavBack()}
window.addEventListener('ui_nav',onPanelNavigation,true)
onUnmounted(()=>window.removeEventListener('ui_nav',onPanelNavigation,true))
// BeamNG keeps the keyboard for driving until a text field asks for it. Spinner arrows are mouse clicks, so they worked without this.
// The game can also take the keyboard back on its own (alt-tab, another screen releasing typing),
// so a click or focus on a field always asks again instead of trusting textEntryActive.
let textEntryActive=false
let textEntryFocusRequest=0
function isTextEntry(el){if(!el||typeof el.matches!=='function'||!el.matches('input, textarea'))return false;const type=(el.getAttribute('type')||'text').toLowerCase();return !['checkbox','range','button','radio','submit','color','file'].includes(type)}
function isEditableText(el){return isTextEntry(el)&&!el.readOnly&&!el.disabled}
// Selected map cells are read-only until Enter, but already need arrow keys.
function needsKeyboard(el){return isEditableText(el)||(isTextEntry(el)&&!el.disabled&&el.matches('.rmap td input'))}
function setTextEntry(active,{force=false}={}){
 if(!active)textEntryFocusRequest++
 if(!force&&textEntryActive===active)return
 textEntryActive=active
 const on=!!active
 try{
  if(typeof lua.setCEFTyping==='function')return lua.setCEFTyping(on)
  return new Promise(resolve=>{
   if(window.bngApi?.engineLua)window.bngApi.engineLua(`setCEFTyping(${on})`,resolve)
   else resolve()
  })
 }catch(_){}
}
// Mouse clicks still arrive while the game holds the keyboard, but focus does not land (no caret,
// no outline), so the click itself asks for typing and then focuses the field again.
function onFuelPointerDown(event){
 const el=event.target
 const request=++textEntryFocusRequest
 if(!needsKeyboard(el)){
  if(textEntryActive&&!needsKeyboard(document.activeElement))setTextEntry(false)
  return
 }
 const vehicleContext=identity,selectedEngine=engineName.value
 const modal=document.querySelector('.modal-backdrop'),previousFocus=document.activeElement
 // Walking can still own the keyboard on the next frame. Wait for the engine
 // to grant typing before retrying the click's focus.
 Promise.resolve(setTextEntry(true,{force:true})).then(()=>requestAnimationFrame(()=>{
  // A dialog or a newer context owns focus once this click is no longer current.
  if(request!==textEntryFocusRequest||!textEntryActive)return
  const active=document.activeElement,currentModal=document.querySelector('.modal-backdrop')
  const releaseUnusedTyping=()=>{if(!currentModal&&!needsKeyboard(active))setTextEntry(false)}
  if(vehicleContext!==identity||selectedEngine!==engineName.value||!panel.value.open||panel.value.paused){releaseUnusedTyping();return}
  if(currentModal!==modal||!document.contains(el)||!needsKeyboard(el)){releaseUnusedTyping();return}
  // Blurring the accordion trigger can leave the page body focused while
  // walking still owns the keyboard. Another control must retain its focus.
  if(active!==el&&active!==previousFocus&&active!==document.body&&active!=null){releaseUnusedTyping();return}
  el.focus()
 }),()=>{})
}
function onFuelFocusIn(event){if(needsKeyboard(event.target))setTextEntry(true,{force:true})}
// Same as the game's own text inputs: when the game takes typing back, let go of the field.
function onTypingTakenBack(){textEntryFocusRequest++;if(!textEntryActive)return;textEntryActive=false;const active=document.activeElement;if(active?.closest?.('.fuel-shade'))active.blur()}
events.on('CEFTypingLostFocus',onTypingTakenBack)
onUnmounted(()=>events.off('CEFTypingLostFocus',onTypingTakenBack))
function onFuelFocusOut(event){
 // A button losing focus is part of the click into a field, not the end of
 // text entry. Likewise, moving between fields must retain the pending retry.
 if(!isTextEntry(event.target)||needsKeyboard(event.relatedTarget))return
 setTextEntry(false)
}
function onFuelKey(event){const el=event.target;if(isTextEntry(el)&&!el.readOnly&&!el.disabled)event.stopPropagation()}
onUnmounted(()=>setTextEntry(false))


// Draft editing never changes the vehicle until Apply succeeds.
const editorMode=ref('simple'),editorMessage=ref(''),simpleLambda=ref(.86),simpleTiming=ref(0),simpleConfirm=ref(false);
const anchor=ref({y:7,x:0}),extent=ref({y:7,x:0}),dragging=ref(false),editingCell=ref(null),showChanges=ref(true);
const bulkOperation=ref('add'),bulkValue=ref(0),clipboardText=ref(''),undoStack=ref([]),redoStack=ref([]);
const bulkChoices=[{value:'set',label:'Set value'},{value:'add',label:'Add / subtract'},{value:'percent',label:'Scale values by %'}];
const bulkOperationLabel=computed(()=>bulkChoices.find(choice=>choice.value===bulkOperation.value)?.label||'Add / subtract');
// BeamNG draws this panel off-screen, so a native select popup never appears. These menus are drawn in the panel instead.
function pickChoice(event,apply){apply();const key=event.currentTarget.closest('[data-fuel-menu]')?.dataset.fuelMenu;if(key)menus.value[key]=false}
function setBulkOperation(event,operation){if(panel.value.busy)return;pickChoice(event,()=>{bulkOperation.value=operation})}
function setCurveLoad(event,index){pickChoice(event,()=>{row.value=index})}
function chooseEngine(event,name){if(dirty.value||panel.value.busy)return;pickChoice(event,()=>{engineName.value=name;loadDraft()})}
function chooseTank(event,name,quoted){if(panel.value.busy)return;pickChoice(event,()=>{tankName.value=name;if(quoted){lastSale.value=null;clearQuote()}})}
function choosePreset(event,name){pickChoice(event,()=>{selectedPreset.value=name})}
let lastSnapshot=null,lastSimple=null,messageTimer,returnFocus,sourceReset;
const decelDraft=computed(()=>decelSettings(draft.value));
const decelPreview=ref({});
const decelDisplay=computed(()=>({...decelDraft.value,...decelPreview.value}));
function previewDecel(key,value){if(!panel.value.busy)decelPreview.value={[key]:Number(value)}}
function commitDecel(key,value){decelPreview.value={};changeDecel(key,Number(value))}
const nitroTune=computed(()=>engine.value?.state.conversionKind==='nitromethane');
const dieselTune=computed(()=>engine.value?.profile.fuelType==='diesel');
const afrBasis=computed(()=>dieselTune.value?14.5:Number(engine.value?.telemetry?.calibrationAFR)||({ethanol:9.8,methanol:6.4,nitromethane:1.7}[engine.value?.state.conversionKind]||14.7));
const simpleBounds=computed(()=>(dieselTune.value?[12,200]:[(nitroTune.value?.6:.8)*afrBasis.value,(nitroTune.value?1:.94)*afrBasis.value]).map(v=>Number(v.toFixed(2))));
const simpleAFR=computed({get:()=>(simpleLambda.value*afrBasis.value).toFixed(2),set:v=>simpleLambda.value=Number(Number(v).toFixed(2))/afrBasis.value});
// Telemetry redraws must keep the unfinished entry until change commits it.
const simpleAFREntry=ref(null);
function changeSimpleAFR(event){if(event.target.value!=='' && Number.isFinite(Number(event.target.value))){simpleAFR.value=event.target.value;generateSimple()}simpleAFREntry.value=null;event.target.value=simpleAFR.value;}
function displayCell(v){return isBoost.value?pressure.value.toDisplay(v):field.value==='lambda'?v*afrBasis.value:v}
function storeCell(v){return isBoost.value?pressure.value.fromDisplay(v):field.value==='lambda'?v/afrBasis.value:v}
function displayLimits(){return limits().map(displayCell)}
const rpmSpacing=ref('even'),rpmLimit=ref(6500);
watch(()=>engine.value?.state.tune.rpm.at(-1),v=>{if(v)rpmLimit.value=v});
watch(dieselTune,v=>{if(v)field.value='lambda'});
function resizeDraft(){try{const next=resizeFuelTune(draft.value,rpmLimit.value,rpmSpacing.value);mutate(()=>{draft.value=next;extraSelection.value=null;anchor.value={y:0,x:0};extent.value={y:0,x:0};curveHover.value=null},'Resized draft. Review and Apply.')}catch(e){say(e.message)}}
const nitrousModes=computed(()=>[{value:'original',label:'Stock'},{value:'speed',label:'By speed',disabled:!engine.value?.nitrousSupported},{value:'rpmGear',label:'By RPM / gear',disabled:!engine.value?.nitrousSupported || !engine.value?.boostGears?.length}])
const nitrousEntry=ref(null)
const nitrousFields=computed(()=>draft.value?.nitrous?.mode==='speed' ? [
 {key:'minSpeed',label:'Minimum speed (km/h)',min:0,max:1000,step:1},{key:'maxSpeed',label:'Maximum speed (km/h)',min:0,max:1000,step:1}
] : [{key:'minRPM',label:'Minimum RPM',min:0,max:50000,step:100},{key:'maxRPM',label:'Maximum RPM',min:0,max:50000,step:100},
 {key:'minGear',label:'First gear',min:1,max:engine.value?.boostGears?.at(-1)||1,step:1},{key:'maxGear',label:'Last gear',min:1,max:engine.value?.boostGears?.at(-1)||1,step:1}])
function changeNitrousMode(mode){if(panel.value.busy)return;nitrousEntry.value=null;mutate(()=>{draft.value.nitrous={minSpeed:30,maxSpeed:300,minRPM:3000,maxRPM:Math.max(3100,engine.value?.profile.maxRPM||6000),minGear:1,maxGear:engine.value?.boostGears?.at(-1)||1,...draft.value.nitrous,mode}},'Nitrous draft updated. Apply when ready.')}
function changeNitrousValue(key,event){if(panel.value.busy)return;const n=event.target.value==='' ? null : Number(event.target.value);mutate(()=>{draft.value.nitrous={...draft.value.nitrous,[key]:n}},'Nitrous draft updated. Apply when ready.');nitrousEntry.value=null}
function changeBoost(boost){mutate(()=>{draft.value.version=2;draft.value.boost=boost},'Boost draft updated. Apply when ready.')}
function resetTrim(){mutate(()=>draft.value.afrTrim=0,'Fuel trim reset in draft. Apply when ready.')}
function hardwareChoices(component){const options=engine.value?.hardware?.[component==='injector'?'injectors':'pumps'];return Array.isArray(options)?options:[]}
function retiredHardware(component){const options=engine.value?.hardware?.[component==='injector'?'retiredInjectors':'retiredPumps'];return Array.isArray(options)?options:[]}
function installedRetiredHardware(component){return retiredHardware(component).find(option=>option.id===engine.value?.state.hardware?.[component])}
function hardwarePower(option){const ref=engine.value?.profile;const density=Number(engine.value?.telemetry?.fuelDensity)||({ethanol:.786,methanol:.792,nitromethane:1.10}[engine.value?.state.conversionKind]||.75);const factor=dieselTune.value?1:14.7/afrBasis.value*.75/density;return Math.round((ref?.referencePowerKW||0)/.7457*option.flowLps/Math.max(.000001,(ref?.baseFlowLps||0)*factor)*.85)}
async function buyHardware(component,option){if(dirty.value||panel.value.busy)return;await lua.overhaul_career_maintenance_fuelSystem.installHardware(engineName.value,component,option.id,requestContext())}
const factoryBoostPsi=computed(()=>Number(engine.value?.profile?.factoryBoostPsi)||0);

const isBoost=computed(()=>field.value==='boost');
const boostGrid=computed(()=>draft.value?.boost || gearBoost(draft.value,engine.value?.boostGears || [],factoryBoostPsi.value+(engine.value?.profile.wastegateHalfRangePsi||0)));
const showAdvancedTable=computed(()=>!isBoost.value || (engine.value?.boostSupported && boostGrid.value.mode==='map'));
const boostMismatch=computed(()=>!!draft.value?.boost && JSON.stringify(draft.value.boost.gears)!==JSON.stringify(engine.value?.boostGears || []));
const gridRows=computed(()=>!draft.value?[]:isBoost.value?boostGrid.value.gears:draft.value.load);
const gridColumns=computed(()=>draft.value?.rpm || []);
const gridValues=computed(()=>!draft.value?[]:isBoost.value?boostGrid.value.gears.map((_,g)=>draft.value.rpm.map((_,r)=>boostGrid.value.targets[r][g])):draft.value[field.value]);
const gridColorRange=computed(()=>isBoost.value?[0,Math.max(1,factoryBoostPsi.value*2,...gridValues.value.flat())]:limits());
const gridEditable=computed(()=>!panel.value.busy && showAdvancedTable.value && (!isBoost.value || !boostMismatch.value));
const selectedBoostTarget=computed(()=>{const b=boostGrid.value,x=selected.value.y;return Math.max(0,Math.min(200,(b.targets[selected.value.x]?.[x]||0)+(b.offset||0)+(b.offsets[x]||0)))});
// Display uses gear rows and RPM columns; saved targets retain RPM rows for existing tunes.
function setGridValue(y,x,value){if(isBoost.value){if(!draft.value.boost){draft.value.version=2;draft.value.boost=clone(boostGrid.value)}draft.value.boost.mode='map';draft.value.boost.targets[x][y]=value}else draft.value[field.value][y][x]=value}
function editGridCell(y,x,event){const n=Number(event.target.value),[lo,hi]=displayLimits();if(!gridEditable.value || event.target.value==='' || !Number.isFinite(n) || n<lo || n>hi){event.target.value=fmt(displayCell(gridValues.value[y][x]),isBoost.value||isBoost.value||field.value==='lambda'?2:1);if(isEditing(y,x))editingCell.value.text=event.target.value;say('Invalid entry reverted. Other cells are unchanged.');return}const keepEditing=isEditing(y,x)&&document.activeElement===event.target;mutate(()=>setGridValue(y,x,storeCell(n)),'Cell updated in the draft.');if(keepEditing)editingCell.value={y,x,text:String(n)}}
watch(field,()=>{lastGridClick=null;extraSelection.value=null;anchor.value={y:0,x:0};extent.value={y:0,x:0};selected.value={y:0,x:0};row.value=0;editingCell.value=null;curveHover.value=null});
watch(editorMode,mode=>{if(mode==='simple' && isBoost.value)field.value='lambda'});

function pressureText(psi){return pressure.value.text(psi)}
watch(pressureSystem,()=>{lastGridClick=null;editingCell.value=null;boostCutPreview.value=null;bulkValue.value=0;clipboardText.value=''})
const boostCutPreview=ref(null);
const boostCutDisplay=computed(()=>boostCutPreview.value??boostCutMargin(draft.value));
function previewBoostCut(value){if(!panel.value.busy)boostCutPreview.value=Number(value)}
// The stock margin is stored as no override, so returning to it is not a custom map.
function commitBoostCut(value){boostCutPreview.value=null;value=Number(value);mutate(()=>{if(Math.abs(value-BOOST_CUT_STOCK)<1e-8)delete draft.value.boostCut;else draft.value.boostCut=value},'Boost cut draft updated. Apply when ready.')}
function changeDecel(key,value){decelPreview.value={};mutate(()=>{draft.value.decel={...decelDraft.value,[key]:value}},'Decel draft updated. Apply when ready.')}
const workspaceTab=ref('tune'),drawer=ref(''),resetOpen=ref(false),resetWorking=ref(false),discardOpen=ref(false),curveHover=ref(null);
const drawerTitle=computed(()=>({guide:'Tuning guide',presets:'Saved maps',clipboard:'Table clipboard',engine:'Engine details'}[drawer.value]||''));
function dismissMenus(){Object.keys(menus.value).forEach(key=>menus.value[key]=false)}
function rememberFocus(event){const target=event?.currentTarget||document.activeElement;returnFocus=target?.closest('[data-fuel-menu]')?.querySelector('button')||document.activeElement;dismissMenus()}
function restoreFocus(){nextTick(()=>returnFocus?.isConnected&&returnFocus.focus())}
function openDrawer(name,section){rememberFocus();drawer.value=name;nextTick(()=>{const target=section ? document.getElementById(section) : document.querySelector('.drawer-close');target?.focus()})}
function closeDrawer(){drawer.value='';restoreFocus()}
function dialogKey(event,selector,close){
 if(event.key==='Escape'){event.preventDefault();close();return}
 if(event.key!=='Tab')return;
 const nodes=[...document.querySelectorAll(selector+' button:not(:disabled),'+selector+' input,'+selector+' select,'+selector+' textarea,'+selector+' a[href]')].filter(e=>e.getClientRects().length);
 if(!nodes.length)return;
 if(event.shiftKey&&document.activeElement===nodes[0]){event.preventDefault();nodes.at(-1).focus()}
 else if(!event.shiftKey&&document.activeElement===nodes.at(-1)){event.preventDefault();nodes[0].focus()}
}
function drawerKey(e){dialogKey(e,'.help-drawer',closeDrawer)}
function requestReset(event){rememberFocus(event);resetOpen.value=true;nextTick(()=>document.querySelector('.reset-dialog button')?.focus())}
function cancelReset(){if(resetWorking.value)return;resetOpen.value=false;restoreFocus()}
function resetKey(e){dialogKey(e,'.reset-dialog',cancelReset)}
async function confirmReset(){
 if(resetWorking.value)return;resetWorking.value=true;
 try{const reset=await sourceReset();if(!reset){say('Calibration changed. Reopen reset and try again.');resetOpen.value=false;return}syncSimpleControls();simpleConfirm.value=false;say('Draft reset to conservative. Undo is available.');resetOpen.value=false;restoreFocus()}
 finally{resetWorking.value=false}
}
const curveData=computed(()=>{
 if(!draft.value||!engine.value||isBoost.value)return {lo:0,hi:1,draft:'',installed:''};
 const a=draft.value[field.value][row.value].map(displayCell),b=engine.value.state.tune[field.value][row.value].map(displayCell);
 const values=[...a,...b],min=Math.min(...values),max=Math.max(...values),pad=Math.max((max-min)*.15,field.value==='lambda'?.02:1);
 const lo=min-pad,hi=max+pad;
 const points=(values,axis)=>values.map((v,i)=>`${axis[i]/draft.value.rpm.at(-1)*660},${124-(v-lo)/(hi-lo)*112}`).join(' ');
 return {lo,hi,draft:points(a,draft.value.rpm),installed:points(b,engine.value.state.tune.rpm)};
});
function hoverCurve(event){const box=event.currentTarget.getBoundingClientRect(),rpm=(event.clientX-box.left)/box.width*draft.value.rpm.at(-1);curveHover.value=draft.value.rpm.reduce((best,v,i)=>Math.abs(v-rpm)<Math.abs(draft.value.rpm[best]-rpm)?i:best,0)}
const extraSelection=ref(null);
const bounds=computed(()=>({y1:Math.min(anchor.value.y,extent.value.y),y2:Math.max(anchor.value.y,extent.value.y),x1:Math.min(anchor.value.x,extent.value.x),x2:Math.max(anchor.value.x,extent.value.x)}));
const selectionCount=computed(()=>extraSelection.value ? extraSelection.value.size : (bounds.value.y2-bounds.value.y1+1)*(bounds.value.x2-bounds.value.x1+1));
const selectionLabel=computed(()=>!draft.value?'':extraSelection.value?'Individual cells. Units: '+(isBoost.value?pressure.value.unit:field.value==='lambda'?'AFR':'degrees'):isBoost.value?`${draft.value.rpm[bounds.value.x1]}–${draft.value.rpm[bounds.value.x2]} RPM. Gears: ${boostGrid.value.gears[bounds.value.y1]}–${boostGrid.value.gears[bounds.value.y2]}. Units: ${pressure.value.unit}`:`${draft.value.rpm[bounds.value.x1].toLocaleString()}–${draft.value.rpm[bounds.value.x2].toLocaleString()} RPM. Load: ${Math.round(draft.value.load[bounds.value.y1]*100)}–${Math.round(draft.value.load[bounds.value.y2]*100)}% load`);
function installedValue(f,y,rpm){const t=engine.value.state.tune;let i=0;while(i<t.rpm.length-2&&t.rpm[i+1]<rpm)i++;const w=Math.max(0,Math.min(1,(rpm-t.rpm[i])/(t.rpm[i+1]-t.rpm[i])));return t[f][y][i]*(1-w)+t[f][y][i+1]*w}
const changedCount=computed(()=>!draft.value||!engine.value?0:['lambda','timing'].reduce((sum,f)=>sum+draft.value[f].reduce((n,r,y)=>n+r.filter((v,x)=>Math.abs(v-installedValue(f,y,draft.value.rpm[x]))>1e-8).length,0),0));
const hasCustomMap=computed(()=>{if(!draft.value)return false;return simpleFuelSettings(draft.value,nitroTune.value).custom});
function say(s){clearTimeout(messageTimer);editorMessage.value=s;messageTimer=setTimeout(()=>editorMessage.value='',5500)}
function dismissStatus(){clearTimeout(messageTimer);editorMessage.value=''}
onUnmounted(()=>clearTimeout(messageTimer));
function limits(){return isBoost.value?[0,200]:field.value==='lambda'?(dieselTune.value?[12/14.5,200/14.5]:[.6,1.4]):[-20,20]}
function round(v){return Math.round(v*10000)/10000}
function inSelection(y,x){if(extraSelection.value)return extraSelection.value.has(`${y}:${x}`);const b=bounds.value;return y>=b.y1&&y<=b.y2&&x>=b.x1&&x<=b.x2}
function isChanged(y,x){if(isBoost.value){const t=engine.value.state.tune,b=t.boost;return !b || t.rpm[x]!==draft.value.rpm[x] || b.gears[y]!==boostGrid.value.gears[y] || Math.abs(gridValues.value[y][x]-b.targets[x]?.[y])>1e-8}return engine.value.state.tune.rpm[x]!==draft.value.rpm[x] || Math.abs(draft.value[field.value][y][x]-engine.value.state.tune[field.value][y]?.[x])>1e-8}
function isEditing(y,x){return editingCell.value?.y===y&&editingCell.value?.x===x}
// The game can forward a double-click as two single-count CEF clicks.
const GRID_DOUBLE_CLICK_MS=400
let lastGridClick=null
function onGridClick(event,y,x){if(event.button!==0||!gridEditable.value||isEditing(y,x)){lastGridClick=null;return}const atMs=performance.now(),context=`${identity}:${engineName.value}:${field.value}`;const repeated=lastGridClick?.target===event.currentTarget&&lastGridClick.context===context&&atMs-lastGridClick.atMs<=GRID_DOUBLE_CLICK_MS;lastGridClick=repeated?null:{target:event.currentTarget,context,atMs};if(repeated)beginEdit(event,y,x)}
function beginEdit(event,y,x){if(!gridEditable.value||isEditing(y,x))return;setTextEntry(true,{force:true});editingCell.value={y,x,text:fmt(displayCell(gridValues.value[y][x]),field.value==='lambda'?2:1)};nextTick(()=>{const input=document.querySelector(`td[data-y="${y}"][data-x="${x}"] input`);input?.focus();input?.select()})}
function focusCell(y,x){nextTick(()=>document.querySelector(`td[data-y="${y}"][data-x="${x}"] input`)?.focus({preventScroll:true}))}
// Cancel native text selection on mousedown; canceling pointerdown also suppresses double-click.
function startSelection(event,y,x){if(event.button!==0||isEditing(y,x))return;editingCell.value=null;
 if(event.ctrlKey||event.metaKey){const cells=new Set();selectionCells((sy,sx)=>cells.add(`${sy}:${sx}`));const key=`${y}:${x}`;cells.has(key)?cells.delete(key):cells.add(key);if(!cells.size)cells.add(key);extraSelection.value=cells;extent.value={y,x};selected.value={y,x};row.value=Math.min(y,7);dragging.value=false;focusCell(y,x);return}
 extraSelection.value=null;if(!event.shiftKey)anchor.value={y,x};extent.value={y,x};selected.value={y,x};row.value=Math.min(y,7);dragging.value=true;focusCell(y,x)}
function extendSelection(event,y,x){if(!dragging.value||!(event.buttons&1))return;extent.value={y,x};selected.value={y,x};row.value=Math.min(y,7)}
function stopSelection(){dragging.value=false}
window.addEventListener('pointerup',stopSelection);
onUnmounted(()=>window.removeEventListener('pointerup',stopSelection));
function selectAll(){extraSelection.value=null;anchor.value={y:0,x:0};extent.value={y:gridRows.value.length-1,x:gridColumns.value.length-1};editingCell.value=null}
function selectRow(y){extraSelection.value=null;anchor.value={y,x:0};extent.value={y,x:gridColumns.value.length-1};selected.value={y,x:0};row.value=Math.min(y,7);editingCell.value=null}
function selectColumn(x){extraSelection.value=null;anchor.value={y:0,x};extent.value={y:gridRows.value.length-1,x};selected.value={y:gridRows.value.length-1,x};editingCell.value=null}
function selectionCells(fn){if(extraSelection.value){for(const key of extraSelection.value){const [y,x]=key.split(':').map(Number);fn(y,x)}return}const b=bounds.value;for(let y=b.y1;y<=b.y2;y++)for(let x=b.x1;x<=b.x2;x++)fn(y,x)}
function recordChange(){
 const snap=clone(draft.value);if(sameFuelTune(snap,lastSnapshot))return;
 if(lastSnapshot){undoStack.value.push(clone(lastSnapshot));if(undoStack.value.length>40)undoStack.value.shift()}
 lastSnapshot=snap;redoStack.value=[];
}
function clampSelection(){if(!draft.value)return;if(extraSelection.value)extraSelection.value=new Set([...extraSelection.value].filter(key=>{const [y,x]=key.split(':').map(Number);return y<gridRows.value.length&&x<gridColumns.value.length}));for(const r of [anchor,extent,selected])r.value={y:Math.max(0,Math.min(gridRows.value.length-1,r.value.y)),x:Math.max(0,Math.min(gridColumns.value.length-1,r.value.x))};editingCell.value=null;curveHover.value=null}
function syncSimpleControls(){clampSelection();if(draft.value){const values=simpleFuelSettings(draft.value,nitroTune.value);simpleLambda.value=values.lambda;simpleTiming.value=values.timing}}
function finalize(message){syncSimpleControls();recordChange();dirty.value=!sameFuelTune(draft.value,engine.value.state.tune);preview.value=[];previewGeneration++;simpleConfirm.value=false;say(message)}
function mutate(fn,message){if(!draft.value||panel.value.busy)return;const before=clone(draft.value);fn();if(!validFuelTune(draft.value)){draft.value=before;say('Change rejected: the whole draft must contain valid values.');return}finalize(message)}
function undoEdit(){if(panel.value.busy)return;if(!undoStack.value.length)return;redoStack.value.push(clone(draft.value));draft.value=undoStack.value.pop();syncSimpleControls();lastSnapshot=clone(draft.value);dirty.value=!sameFuelTune(draft.value,engine.value.state.tune);preview.value=[];previewGeneration++;simpleConfirm.value=false;say('Undid the last draft edit. The installed calibration is unchanged.')}
function redoEdit(){if(panel.value.busy)return;if(!redoStack.value.length)return;undoStack.value.push(clone(draft.value));draft.value=redoStack.value.pop();syncSimpleControls();lastSnapshot=clone(draft.value);dirty.value=!sameFuelTune(draft.value,engine.value.state.tune);preview.value=[];previewGeneration++;simpleConfirm.value=false;say('Redid the draft edit. The installed calibration is unchanged.')}
function draftRange(f){if(!draft.value)return '—';const a=draft.value[f].flat();return `${fmt(Math.min(...a),f==='lambda'?2:1)}–${fmt(Math.max(...a),f==='lambda'?2:1)}`}
function generateSimple(){
 const lam=Number(simpleLambda.value),tim=Number(simpleTiming.value);
 if(!Number.isFinite(lam)||lam<simpleBounds.value[0]/afrBasis.value||lam>simpleBounds.value[1]/afrBasis.value||!Number.isFinite(tim)||tim< -20||tim>20){say('Use AFR within the shown range and timing -20 to +20 degrees.');return}
 mutate(()=>{draft.value=simpleFuelTune(draft.value,lam,tim,nitroTune.value);lastSimple=clone(draft.value)},'Draft updated. Apply when ready.');
}
function bulkEdit(){
 if(!gridEditable.value)return;
 const n=Number(bulkValue.value);if(String(bulkValue.value).trim()===''||!Number.isFinite(n)){say('Enter a finite number.');return}if(bulkOperation.value==='percent'&&!Number.isInteger(n)){say('Enter a whole percentage, such as 1, 2 or 12.');return}
 const [lo,hi]=displayLimits();let bounded=0;
 mutate(()=>selectionCells((y,x)=>{const old=displayCell(Number(gridValues.value[y][x]));const v=bulkOperation.value==='set'?n:bulkOperation.value==='percent'?old*(1+n/100):old+n;if(v<lo||v>hi)bounded++;setGridValue(y,x,storeCell(round(Math.max(lo,Math.min(hi,v)))))}),`${selectionCount.value} selected cells updated in the draft.`);
 if(bounded)say(`${selectionCount.value} selected cells updated; ${bounded} reached the supported limit (${lo} to ${hi}).`);
}
function copySelection(){if(extraSelection.value){say('Choose a rectangular range to copy table data. Single-value paste and bulk edits support individual cells.');return}const b=bounds.value;clipboardText.value=gridValues.value.slice(b.y1,b.y2+1).map(r=>r.slice(b.x1,b.x2+1).map(v=>Number(displayCell(v).toFixed(4))).join('\t')).join('\n');say(`Copied ${selectionCount.value} cells. Paste uses this local buffer; the expandable text box supports external data.`);if(navigator.clipboard&&document.hasFocus())navigator.clipboard.writeText(clipboardText.value).catch(()=>{})}
function pasteText(text){
 if(!gridEditable.value)return;
 text=String(text||'').trim();if(!text){say('Copy cells or enter table data first.');return}
 const raw=text.split(/\r?\n/).map(r=>r.trim().split(/[\t, ]+/));const cols=raw[0].length;
 if(raw.some(r=>r.length!==cols||r.some(v=>v===''||!Number.isFinite(Number(v))))){say('Paste rejected: data must form a rectangle of finite numbers.');return}
 const values=raw.map(r=>r.map(Number)),[lo,hi]=displayLimits();
 if(values.some(r=>r.some(v=>v<lo||v>hi))){say(`Paste rejected: values must be ${lo} to ${hi}. No cells changed.`);return}
 const b=bounds.value;
 if(values.length===1&&cols===1){mutate(()=>selectionCells((y,x)=>setGridValue(y,x,storeCell(values[0][0]))),'Pasted one value throughout the selection.');return}
 if(extraSelection.value){say('Choose a rectangular range for a block paste. A single value can fill individual cells.');return}
 if(b.y1+values.length>gridRows.value.length||b.x1+cols>gridColumns.value.length){say('Paste rejected: the complete block must fit within the table. No cells changed.');return}
 mutate(()=>values.forEach((r,dy)=>r.forEach((v,dx)=>setGridValue(b.y1+dy,b.x1+dx,storeCell(v)))),'Pasted the complete block into the draft.');
 extent.value={y:b.y1+values.length-1,x:b.x1+cols-1};anchor.value={y:b.y1,x:b.x1};
}
function pasteEvent(event){if(editingCell.value)return;event.preventDefault();pasteText(event.clipboardData.getData('text/plain'))}
function interpolate(direction){
 if(extraSelection.value){say('Choose a rectangular range to interpolate.');return}
 if(!gridEditable.value || (isBoost.value && direction!=='rpm'))return;
 const b=bounds.value;
 if(direction==='rpm'&&b.x2-b.x1<2 || direction==='load'&&b.y2-b.y1<2)return;
 mutate(()=>{const a=clone(gridValues.value);selectionCells((y,x)=>{
   if(direction==='rpm'){const f=(draft.value.rpm[x]-draft.value.rpm[b.x1])/(draft.value.rpm[b.x2]-draft.value.rpm[b.x1]);setGridValue(y,x,round(a[y][b.x1]*(1-f)+a[y][b.x2]*f))}
   else{const f=(draft.value.load[y]-draft.value.load[b.y1])/(draft.value.load[b.y2]-draft.value.load[b.y1]);setGridValue(y,x,round(a[b.y1][x]*(1-f)+a[b.y2][x]*f))}
 })},isBoost.value?'Interpolated RPM within each gear. Endpoints retained.':`Interpolated along ${direction} using the existing endpoints.`)
}
function smoothSelection(){
 if(extraSelection.value){say('Choose a rectangular range to smooth.');return}
 if(!gridEditable.value)return;const b=bounds.value;
 if(b.x2-b.x1<2 || (!isBoost.value && b.y2-b.y1<2))return;
 mutate(()=>{const a=clone(gridValues.value);
   if(isBoost.value){for(let y=b.y1;y<=b.y2;y++)for(let x=b.x1+1;x<b.x2;x++)setGridValue(y,x,round((a[y][x-1]+a[y][x]+a[y][x+1])/3))}
   else{for(let y=b.y1+1;y<b.y2;y++)for(let x=b.x1+1;x<b.x2;x++){let sum=0;for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++)sum+=a[y+dy][x+dx];setGridValue(y,x,round(sum/9))}}
 },isBoost.value?'Smoothed RPM within each gear. Endpoints retained.':'Smoothed selected interior. Boundary cells retained.')
}
function tableKey(event){

 if(editingCell.value){if(event.key==='Enter'||event.key==='Escape'){event.preventDefault();event.target.blur();editingCell.value=null}return}
 const key=event.key.toLowerCase(),ctrl=event.ctrlKey||event.metaKey;
 if(ctrl&&['z','y','a','c'].includes(key)){event.preventDefault();if(key==='z')event.shiftKey?redoEdit():undoEdit();if(key==='y')redoEdit();if(key==='a')selectAll();if(key==='c')copySelection();return}
 const delta={ArrowLeft:[0,-1],ArrowRight:[0,1],ArrowUp:[-1,0],ArrowDown:[1,0]}[event.key];
 if(delta){event.preventDefault();extraSelection.value=null;const p=extent.value,n={y:Math.max(0,Math.min(gridRows.value.length-1,p.y+delta[0])),x:Math.max(0,Math.min(gridColumns.value.length-1,p.x+delta[1]))};if(!event.shiftKey)anchor.value=n;extent.value=n;selected.value=n;row.value=Math.min(n.y,7);focusCell(n.y,n.x);return}
 if(event.key==='PageUp'||event.key==='PageDown'){event.preventDefault();adjust(event.key==='PageUp'?1:-1);return}
 if(event.key==='Enter' && gridEditable.value){event.preventDefault();const p=selected.value;beginEdit(event,p.y,p.x)}
}
{
 sourceReset=resetConservative;resetConservative=requestReset;
 const sourceLoad=loadDraft;loadDraft=function(){sourceLoad();extraSelection.value=null;clampSelection();lastSnapshot=clone(draft.value);lastSimple=null;undoStack.value=[];redoStack.value=[];editorMessage.value='';simpleConfirm.value=false;editingCell.value=null};
 const sourceEdited=edited;edited=function(){if(!validFuelTune(draft.value)){draft.value=clone(lastSnapshot);say('Invalid draft reverted.');return}sourceEdited();finalize('Draft updated. Apply when ready.')};
 adjust=function(direction){const before=bulkValue.value,op=bulkOperation.value;bulkValue.value=direction*(isBoost.value?pressure.value.step:field.value==='lambda'?.01:.5);bulkOperation.value='add';bulkEdit();bulkValue.value=before;bulkOperation.value=op};
 moveCell=function(){}; // Grid keyboard handling is on its enclosing table container
}

// Services use the same owner and generation as the displayed engine and tank.
const serviceAction=ref(''),serviceWorking=ref(false),drainLiters=ref(0);
const drainValid=computed(()=>drainLiters.value!=='' && Number.isFinite(Number(drainLiters.value)) && Number(drainLiters.value)>=0 && Number(drainLiters.value)<=Number(tank.value?.liters||0));
const drainShown=computed({get:()=>toVol(drainLiters.value),set:value=>{drainLiters.value=Math.min(Number(tank.value?.liters||0),Math.max(0,shown.value.fromVolume(Number(value)||0)))}})
const drainRemaining=computed(()=>drainValid.value?Math.max(0,Number(tank.value?.liters||0)-Number(drainLiters.value)):0);
let serviceTarget=null;
const serviceAccess=computed(()=>!panel.value.data?.career||panel.value.mode==='garage');
const hardwareAccess=computed(()=>!panel.value.data?.career||isHardware.value);
// Pumps can drain too (free; the fuel is thrown away).
function serviceAllowed(action){return action==='drain' ? serviceAccess.value||isPump.value : hardwareAccess.value}
const installedKit=computed(()=>dieselTune.value?'Diesel fuel system':engine.value?.state.conversionKind==='nitromethane'?'Nitro 90 racing system':engine.value?.state.conversionKind==='methanol'?'M100 racing system':engine.value?.state.conversion?'Flex-fuel system':'Standard gasoline system');
const installedFuelKind=computed(()=>engine.value?.state.conversion ? engine.value.state.conversionKind||'ethanol' : 'gasoline');
const kitChoices=computed(()=>[
 {kind:'gasoline',tag:'STANDARD',title:'Standard gasoline',fuels:'Return to the standard fuel system',effects:['Restores baseline gasoline tuning','Fuel in all tanks stays unchanged'],price:0},
 {kind:'ethanol',tag:'FLEX-FUEL',title:'Flex-fuel conversion',fuels:'Gasoline + ethanol blends, including E85',effects:['More fuel used on E85','Helps cool the incoming air'],price:panel.value.conversionPrice},
 {kind:'methanol',tag:'M100',title:'Methanol conversion',fuels:'Dedicated to nearly pure methanol',effects:['Much higher fuel use','Stronger cooling of incoming air'],price:panel.value.methanolConversionPrice},
 {kind:'nitromethane',tag:'NITRO 90',title:'Nitro 90 conversion',fuels:'90% nitromethane / 10% methanol',effects:['Very high fuel delivery','Retains engine and drivetrain strength limits'],price:panel.value.nitroConversionPrice}
]);
const tankParts=computed(()=>{if(tank.value?.energyType==='diesel')return [{label:'Diesel',percent:100,color:'#d7b561'}];const b=tank.value?.blend||{},e=b.ethanol||0,m=b.methanol||0,n=b.nitromethane||0;return [{label:'Gasoline',percent:Math.max(0,1-e-m-n)*100,color:'#e8b978'},{label:'Ethanol',percent:e*100,color:'#6cd1b8'},{label:'Methanol',percent:m*100,color:'#af9beb'},{label:'Nitromethane',percent:n*100,color:'#f18b61'}].filter(p=>p.percent>1e-6)});
const tankBlendName=computed(()=>{if(!tank.value||tank.value.liters<=0)return 'Empty';const e=Number(tank.value.blend.ethanol)||0,m=Number(tank.value.blend.methanol)||0,n=Number(tank.value.blend.nitromethane)||0;if(n>.001)return Math.abs(n-.9)<.002&&Math.abs(m-.1)<.002?'Nitro 90':'Mixed nitro fuel';return m>=.98?'M100':m>.001?'Mixed fuels':`E${Math.round(e*1000)/10}`});
// The pump bar blends neighbouring fuels over a short stretch instead of a hard edge.
const BLEND_EDGE=6;
const levelFill=computed(()=>{if(store.value)return null;const parts=tankParts.value;if(parts.length<2)return parts[0]?.color||null;
 const stops=[];let at=0;parts.forEach((part,i)=>{const prev=parts[i-1],next=parts[i+1];
  const from=prev?at+Math.min(BLEND_EDGE,prev.percent,part.percent)/2:0,to=next?at+part.percent-Math.min(BLEND_EDGE,part.percent,next.percent)/2:100;
  stops.push(`${part.color} ${from}%`,`${part.color} ${to}%`);at+=part.percent});
 return `linear-gradient(90deg,${stops.join(',')})`});
const tankBlendDescription=computed(()=>tankParts.value.map(p=>`${fmt(p.percent,1)}% ${p.label.toLowerCase()}`).join(', '));
const tankSuitability=computed(()=>{if(!tank.value||tank.value.liters<=0)return '';const e=tank.value.blend.ethanol||0,m=tank.value.blend.methanol||0,kind=engine.value?.state.conversionKind,n=tank.value.blend.nitromethane||0;if(kind==='nitromethane')return Math.abs(n-.9)>.02||Math.abs(m-.1)>.02?'This kit needs Nitro 90. Drain before switching fuels.':'';if(n>.001)return 'This blend needs a dedicated Nitro 90 conversion.';if(kind==='methanol'&&m<.98)return 'This kit needs nearly pure methanol. Drain, then refill with M100.';if(kind!=='methanol'&&m>.001)return 'This blend needs an M100 system and suitable calibration.';if(!engine.value?.state.conversion&&e>.15)return 'This ethanol blend needs a flex-fuel kit.';return ''});
const serviceTitle=computed(()=>serviceAction.value==='drain'?'Drain this tank?':serviceAction.value==='remove'?'Return to standard gasoline?':serviceAction.value==='ethanol'?'Install flex-fuel kit?':serviceAction.value==='nitromethane'?'Install Nitro 90 kit?':'Install M100 kit?');
const serviceSummary=computed(()=>serviceAction.value==='drain'?`Drain ${volText(serviceTarget?.drain)} from ${serviceTarget?.tank}. ${volText((serviceTarget?.liters||0)-(serviceTarget?.drain||0))} will remain. No fee or fuel refund.`:serviceAction.value==='remove'?'Remove the conversion hardware for free.':`${panel.value.data?.career?`$${Number(serviceAction.value==='ethanol'?panel.value.conversionPrice:serviceAction.value==='nitromethane'?panel.value.nitroConversionPrice:panel.value.methanolConversionPrice).toLocaleString()}`:'Free'}; ${serviceAction.value==='ethanol'?'Flex-fuel conversion':serviceAction.value==='nitromethane'?'Nitro 90 conversion':'M100 conversion'}.`);
function requestService(action,event){
 if(!serviceAllowed(action)||panel.value.busy||serviceWorking.value||!engine.value)return;
 if(action!=='drain'&&dirty.value)return;
 if(action==='drain'&&(!tank.value||!drainValid.value||Number(drainLiters.value)<=0))return;
 if(action==='remove'&&!engine.value.state.conversion)return;
 if(['ethanol','methanol','nitromethane'].includes(action)&&engine.value.state.conversionKind===action)return;
 if(!['ethanol','methanol','nitromethane','drain','remove'].includes(action))return;
 rememberFocus(event);serviceTarget={identity,engine:engineName.value,tank:tankName.value,liters:tank.value?.liters,drain:Number(drainLiters.value),blend:JSON.stringify(tank.value?.blend)};serviceAction.value=action;
 nextTick(()=>document.querySelector('.service-confirm button')?.focus());
}
function cancelService(){if(serviceWorking.value)return;serviceAction.value='';serviceTarget=null;restoreFocus()}
function serviceKey(e){dialogKey(e,'.service-confirm',cancelService)}
async function confirmService(){
 if(!serviceAction.value||serviceWorking.value)return;
 if(!serviceTarget||serviceTarget.identity!==identity||serviceTarget.engine!==engineName.value||serviceTarget.tank!==tankName.value||!serviceAllowed(serviceAction.value)||panel.value.busy){cancelService();return}
 if(serviceAction.value==='drain'&&(Math.abs(serviceTarget.liters-(tank.value?.liters||0))>0.02||serviceTarget.blend!==JSON.stringify(tank.value?.blend))){cancelService();drainLiters.value=0;say('Tank contents changed. Choose an amount again.');return}
 serviceWorking.value=true;
 try{if(serviceAction.value==='drain'){await lua.overhaul_career_maintenance_fuelSystem.drain(tankName.value,serviceTarget.drain,serviceTarget.liters,JSON.parse(serviceTarget.blend),requestContext());drainLiters.value=0}else if(serviceAction.value==='remove'){removeConversion()}else{convert(serviceAction.value)}serviceAction.value='';serviceTarget=null;restoreFocus()}
 finally{serviceWorking.value=false}
}
watch(()=>[identity,engineName.value,tankName.value],()=>{drainLiters.value=0;if(serviceAction.value&&!serviceWorking.value)cancelService()})
watch(()=>[tank.value?.liters,JSON.stringify(tank.value?.blend)],()=>{
 if(serviceWorking.value)return
 if(serviceAction.value==='drain' && serviceTarget && (Math.abs(serviceTarget.liters-(tank.value?.liters||0))>.02 || serviceTarget.blend!==JSON.stringify(tank.value?.blend))) cancelService()
})
function clearEditorContext(){lastGridClick=null;nitrousEntry.value=null;hwHover.value=null;drawer.value='';resetOpen.value=false;discardOpen.value=false;serviceAction.value='';serviceTarget=null;drainLiters.value=0;curveHover.value=null;simpleConfirm.value=false;workspaceTab.value=isHardware.value?'hardware':'tune';waitingApply=false}

// ---- RLS layout: tabs, stat strip, live readouts, pump flow, hardware pickers, decel modes and map colors.
const isHardware=computed(()=>panel.value.mode==='hardware');
const workspaceTabs=computed(()=>{
 const tabs=[{id:'tune',label:'Tune',icon:'sliders'},{id:'hardware',label:'Hardware',icon:'wrench'},{id:'tank',label:'Tank',icon:'tank'}];
 return isHardware.value ? tabs.filter(t=>t.id==='hardware') : panel.value.data?.career ? tabs.filter(t=>t.id!=='hardware') : tabs;
});
const liveOpen=ref(false),curveOpen=ref(false),colorMode=ref('stock');
const kitShort=computed(()=>dieselTune.value?'Diesel':engine.value?.state.conversionKind==='nitromethane'?'Nitro 90':engine.value?.state.conversionKind==='methanol'?'M100':engine.value?.state.conversion?'Flex-fuel':'Gasoline');
function blendAkiText(blend){if(!blend||(blend.methanol||0)>.001||(blend.nitromethane||0)>.001||!Number.isFinite(Number(blend.aki)))return '';return `${fmt(blend.aki,0)} AKI`}
const tankSubLabel=computed(()=>tank.value?.energyType==='diesel'?'diesel':blendAkiText(tank.value?.blend));
const tankShortLabel=computed(()=>{const t=tank.value;if(!t)return '';if(t.liters<=0)return 'Empty';if(t.energyType==='diesel')return 'Diesel';const aki=blendAkiText(t.blend);return aki?`${tankBlendName.value} blend; ${aki}`:tankBlendName.value});
function signed(v,d=1){const n=Number(v)||0;return `${n>0?'+':''}${fmt(n,d)}`}
function markPercent(v,lo,hi){const f=(Number(v)-Number(lo))/Math.max(1e-9,Number(hi)-Number(lo));return `${Math.max(0,Math.min(100,f*100))}%`}
const boostAvailable=computed(()=>factoryBoostPsi.value>0||!!engine.value?.boostSupported||!!draft.value?.boost);
const boostCardShown=boostAvailable;
const simpleStockAFR=computed(()=>(dieselTune.value?18/14.5:nitroTune.value?.72:.86)*afrBasis.value);
function resetSliders(event){pickChoice(event,()=>{simpleLambda.value=dieselTune.value?18/14.5:(nitroTune.value?.72:.86);simpleTiming.value=0;simpleConfirm.value=false;say('Sliders back to stock. The draft changes when you move one.')})}
function loadPresetNamed(event,name){pickChoice(event,()=>{selectedPreset.value=name;const adapted=loadPreset();say(`Loaded ${name} into the draft.${adapted ? (engine.value.boostGears?.length ? ' Boost by gear adapted to this transmission.' : ' Boost by gear reset to stock control for this transmission.') : ''} Apply when ready.`)})}
const bulkShortLabel=computed(()=>({set:'Set to',add:'Add',percent:'Scale %'}[bulkOperation.value]||'Add'));

// Stat strip and live readouts use the panel's own telemetry. Estimates are labeled as such.
const stockHp=computed(()=>Math.round((Number(engine.value?.profile?.referencePowerKW)||0)/.7457));
function fuelVolumeFactor(){const density=Number(engine.value?.telemetry?.fuelDensity)||({ethanol:.786,methanol:.792,nitromethane:1.10}[engine.value?.state.conversionKind]||.75);return dieselTune.value?1:14.7/afrBasis.value*.75/density}
function supportedHp(flowLps){const base=Number(engine.value?.profile?.baseFlowLps)||0;if(!(base>0)||!(flowLps>0))return 0;return stockHp.value*flowLps/(base*fuelVolumeFactor())*.85}
function installedFlow(component){const id=engine.value?.state.hardware?.[component];const o=[...hardwareChoices(component),...retiredHardware(component)].find(x=>x.id===id);return Number(o?.flowLps)||0}
const capacityLps=computed(()=>{const v=[installedFlow('injector'),installedFlow('pump')].filter(n=>n>0);return v.length?Math.min(...v):Number(engine.value?.state.deliveryLps)||0});
const limitingPart=computed(()=>{const i=installedFlow('injector'),p=installedFlow('pump');if(i>0&&p>0)return i<=p?'Injectors':'Pump';const l=engine.value?.telemetry?.deliveryLimit;return l?String(l).replace(/^./,c=>c.toUpperCase()):''});
const deliveryNeed=computed(()=>{const hp=supportedHp(capacityLps.value);return hp>0&&stockHp.value>0?stockHp.value/hp:null});
function dutyTone(d){return d==null?'':d>1?'bad':d>.9?'warn':'ok'}
const statStrip=computed(()=>{
 const e=engine.value;if(!e)return [];const t=e.telemetry||{};const out=[];
 if(tank.value)out.push({key:'Fuel',icon:'droplet',value:tank.value.liters>0?tankBlendName.value:'Empty',sub:tank.value.liters>0?tankSubLabel.value:''});
 if(!dieselTune.value&&!nitroTune.value&&e.state.conversionKind!=='methanol')out.push({key:'Engine needs',icon:'gauge',value:`${fmt(e.profile.requiredAKI,0)} AKI`,sub:e.profile.estimated?'estimated':''});
 out.push({key:'System',icon:'engine',value:kitShort.value});
 if(deliveryNeed.value!=null)out.push({key:'Delivery at stock power',icon:'pump',value:`${Math.round(deliveryNeed.value*100)}%`,sub:'estimated',tone:dutyTone(deliveryNeed.value)});
 if(!dieselTune.value){const r=Number(t.knockRetard)||0;out.push({key:'Knock retard',icon:'spark',value:`${fmt(r,1)}°`,tone:r>.25?'warn':''})}
 if(factoryBoostPsi.value>0&&Number.isFinite(Number(t.boostTargetPsi)))out.push({key:'Boost target',icon:'turbo',value:pressureText(t.boostTargetPsi)});
 return out});
const liveReadings=computed(()=>{
 const e=engine.value;if(!e)return [];const t=e.telemetry||{};
 const out=[{key:'RPM; load',value:Number.isFinite(Number(t.rpm))?Math.round(t.rpm).toLocaleString():'—',sub:`${fmt((t.load||0)*100,0)}%`},
  {key:'AFR now',value:fmt(t.afr),sub:Number.isFinite(Number(t.targetAFR))?`target ${fmt(t.targetAFR)}`:''},
  {key:t.pressureEstimated?'Manifold (est.)':'Manifold',value:pressure.value.kPaText(t.manifoldPressureKPa)}];
 if(!dieselTune.value)out.push({key:'Knock retard',value:`${fmt(t.knockRetard,1)}°`,sub:e.profile.knockControl?`max ${fmt(e.profile.maxKnockRetard,1)}°`:'no protection',tone:(Number(t.knockRetard)||0)>.25?'warn':''});
 out.push({key:'Delivery now',value:`${fmt((t.deliveryDuty||0)*100,0)}%`,sub:`inj ${fmt((t.injectorDuty||0)*100,0)}%; pump ${fmt((t.pumpDuty||0)*100,0)}%`,tone:dutyTone(t.deliveryDuty)==='ok'?'':dutyTone(t.deliveryDuty)});
 out.push({key:'Coolant; oil',value:tempText(t.coolantTemperature),sub:tempText(t.oilTemperature)});
 if((Number(t.ethanol)||0)+(Number(t.methanol)||0)+(Number(t.nitromethane)||0)>.001)out.push({key:'Charge cooling',value:tempDelta(t.chargeCoolingC,1),sub:'estimated'});
 if((Number(t.exhaustBurnW)||0)>0)out.push({key:'Exhaust burning',value:`${fmt((t.exhaustBurnW||0)/1000,1)} kW`});
 return out});
const engineAlerts=computed(()=>[engine.value?.warning,engine.value?.condition?.warning].filter(Boolean));

// Map colors: change against the conservative stock map (blue richer / orange leaner), or absolute shading.
const stockGrid=computed(()=>{if(!draft.value)return null;try{return conservativeFuelTune(draft.value,nitroTune.value)}catch(_){return null}});
function absShade(f){return {background:`rgba(255,102,0,${(.06+.6*Math.max(0,Math.min(1,f))).toFixed(3)})`}}
function absLegend(f){return absShade(f)}
cellStyle=function(y,x){
 const v=Number(gridValues.value[y]?.[x]);if(!Number.isFinite(v))return {};
 if(isBoost.value){const [lo,hi]=gridColorRange.value;return absShade((v-lo)/Math.max(1e-9,hi-lo))}
 if(colorMode.value==='absolute'){const all=gridValues.value.flat().map(Number);const lo=Math.min(...all),hi=Math.max(...all);return absShade(hi>lo?(v-lo)/(hi-lo):0)}
 const ref=field.value==='lambda'?Number(stockGrid.value?.lambda?.[y]?.[x]):0;if(!Number.isFinite(ref))return {background:'rgba(255,255,255,.05)'};
 const d=field.value==='lambda'?(v-ref)*afrBasis.value:v-ref,scale=field.value==='lambda'?Math.max(.1,afrBasis.value*.05):5;
 if(Math.abs(d)<(field.value==='lambda'?.005:.05))return {background:'rgba(255,255,255,.05)'};
 const a=Math.min(.75,.22+Math.abs(d)/scale*.5).toFixed(3);return {background:d<0?`rgba(96,165,250,${a})`:`rgba(255,102,0,${a})`}};

// Decel: Stock = original native behavior; Off = custom with no extra fuel; Custom = custom with fuel.
const decelUi=computed(()=>decelDraft.value.mode==='original'?'stock':decelDraft.value.enabled===false?'off':'custom');
function setDecelUi(mode){if(mode===decelUi.value)return;decelPreview.value={};mutate(()=>{draft.value.decel={...decelDraft.value,mode:mode==='stock'?'original':'custom',enabled:mode!=='off'}},mode==='stock'?'Decel back to stock in the draft.':mode==='off'?'Decel extra fuel off in the draft.':'Custom decel in the draft. Apply when ready.')}

// Hardware: pick a size from the chips, then one buy/install action.
const hardwarePick=ref({injector:'',pump:''});
function hwLabel(o,component){return o?hwSize(o,component,true):''}
// Read authored individual/equivalent ratings, never derive a rating from total flow.
function injectorRate(o){const rate=Number(o?.equivalentCCPerCylinder ?? o?.ccPerInjector);return Number.isFinite(rate)&&rate>0?rate:null}
function pumpRate(o){const rate=Number(o?.lphPerPump);return Number.isFinite(rate)&&rate>0?rate:null}
function hwFlow(o,component){const rate=component==='injector'?injectorRate(o):pumpRate(o);return rate==null?'—':Math.round(rate).toLocaleString()}
function hwSize(o,component,always){if(o.id==='equipped'&&!always)return 'Stock';const rate=component==='injector'?injectorRate(o):pumpRate(o);if(rate==null)return o.label||'Size unavailable';if(component==='injector')return `${hwFlow(o,component)} cc/min ${o.equivalentCCPerCylinder?'equivalent':'each'}`;return `${o.pumpCount>1?`${o.pumpCount} × `:''}${hwFlow(o,component)} L/h`}
function ccmin(flowLps){return Math.round((Number(flowLps)||0)*60000).toLocaleString()}
function pickHardware(component,id){hardwarePick.value={...hardwarePick.value,[component]:id}}
function pickedHardware(component){const id=hardwarePick.value[component]||engine.value?.state.hardware?.[component];const o=[...hardwareChoices(component),...retiredHardware(component)].find(x=>x.id===id);return o?{...o,label:hwLabel(o,component)}:null}
// Hardware lists: hovering an option previews it in the card; deltas compare with what is installed.
const hwHover=ref(null),hwUp=ref({});
watch(()=>[menus.value['hw-injector'],menus.value['hw-pump']],(open)=>{['injector','pump'].forEach((component,i)=>{if(!open[i]){if(hwHover.value?.component===component)hwHover.value=null;return}hwUp.value={...hwUp.value,[component]:false};nextTick(()=>{const pop=document.querySelector(`[data-fuel-menu="hw-${component}"] .hw-pop`);const scroller=pop?.closest('.body-scroll');if(!pop||!scroller)return;const box=pop.getBoundingClientRect(),area=scroller.getBoundingClientRect(),trigger=pop.parentElement.getBoundingClientRect();hwUp.value={...hwUp.value,[component]:box.bottom>area.bottom&&trigger.top-area.top>box.height}})})});
function installedHardware(component){const id=engine.value?.state.hardware?.[component];return [...hardwareChoices(component),...retiredHardware(component)].find(o=>o?.id===id)||null}
function hwPreviewing(component){return hwHover.value?.component===component&&hwHover.value.id!==pickedHardware(component)?.id}
function hwShown(component){if(!hwPreviewing(component))return pickedHardware(component);const o=hardwareChoices(component).find(x=>x.id===hwHover.value.id);return o?{...o,label:hwLabel(o,component)}:pickedHardware(component)}
function hwHp(option){return Number(hardwarePower(option))||0}
function hwDelta(component,option,kind){const base=installedHardware(component);if(!base||!option||base.id===option.id)return null;if(kind!=='hp'&&component==='injector'&&(base.equivalentCCPerCylinder||option.equivalentCCPerCylinder))return null;const rate=component==='injector'?injectorRate:pumpRate;if(kind!=='hp'&&(rate(option)==null||rate(base)==null))return null;const diff=kind==='hp'?shown.value.powerValue(hwHp(option)-hwHp(base)):rate(option)-rate(base);if(Math.round(diff)===0)return null;return {text:`${diff>0?'+':'−'}${Math.round(Math.abs(diff)).toLocaleString()} ${kind==='hp'?pwU.value:component==='injector'?'cc/min each':'L/h each'}`,tone:diff>0?'up':'down'}}
function hwTag(option,component){if(engine.value?.state.hardware?.[component]===option.id)return 'Installed';if(option.owned)return 'Owned';return panel.value.data?.career&&option.price>0?`$${Number(option.price).toLocaleString()}`:'Free'}
watch(()=>`${engineName.value}|${JSON.stringify(engine.value?.state.hardware||{})}`,()=>{hardwarePick.value={injector:'',pump:''}});

// Pump: price updates live; a fuel/kit mismatch turns the button into an explicit "anyway" purchase.
function gradeFit(grade){
 const e=engine.value;if(!e||dieselTune.value||!grade)return null;const kind=installedFuelKind.value;
 if(grade.id==='nitro90')return kind==='nitromethane'?{label:'Fits your kit',tone:'ok'}:{label:'Needs Nitro kit',tone:'bad'};
 if(grade.id==='m100')return kind==='methanol'?{label:'Fits your kit',tone:'ok'}:{label:'Needs M100 kit',tone:'bad'};
 if(kind==='nitromethane'||kind==='methanol')return {label:'Wrong fuel for kit',tone:'bad'};
 if(grade.id==='e85')return kind==='ethanol'?{label:'Best for your kit',tone:'ok'}:{label:'Needs flex-fuel kit',tone:'bad'};
 const aki=Number(grade.aki)||({regular:87,premium:93}[grade.id]);const need=Number(e.profile?.requiredAKI);
 if(Number.isFinite(aki)&&Number.isFinite(need)&&aki+.25<need)return {label:`Below ${fmt(need,0)} AKI`,tone:'warn'};
 return {label:'OK',tone:''}}
const quoteWarning=computed(()=>{let w=String(quoteData.value?.warning||'');if(!w)return '';for(const e of engines.value)if(engines.value.length===1)w=w.split(`${e.name}: `).join('');return w});
const payLabel=computed(()=>{if(fuelShort.value)return 'Not enough money';const q=quoteData.value;if(!q)return Number(amount.value)>0&&tank.value?'Getting price…':'Choose an amount';if(!panel.value.data?.career)return quoteWarning.value?'Refuel anyway':'Refuel';return quoteWarning.value?'Refuel anyway':'Refuel'});
// What this visit has put on the tab; Lua bills it on Pay & leave or when the pump closes.
const owed=computed(()=>Number(panel.value.owed)||0);
// Money left to spend here after the tab (null when the fill is free or business-paid).
// A fill it would not cover is flagged before the player presses anything.
const funds=computed(()=>typeof panel.value.funds==='number'?panel.value.funds:null);
const fillPrice=computed(()=>quoteData.value?.price??estimatedFuelPrice.value);
const fuelShort=computed(()=>funds.value!=null&&!store.value&&pumpAddLiters.value>0&&fillPrice.value>funds.value+.005);
// Short on money: the disabled buy button explains why in its tooltip.
const fundsTip=computed(()=>fuelShort.value||storeShort.value?`You have $${fmt(funds.value,2)}${owed.value>0?' after your tab':''}; this costs about $${fmt(store.value?storePrice.value:fillPrice.value,2)}.`:'');
const storeShort=computed(()=>funds.value!=null&&!!store.value&&storeAddAmount.value>0&&storePrice.value>funds.value+.005);
// Grade keys: a tooltip with the details; the selected grade's line sits under the row.
function gradeTip(grade){const fit=gradeFit(grade);const price=panel.value.data?.career?`$${fmt(perVol(panel.value.pricePerL*grade.priceFactor),2)} / ${volU.value}`:'Free';return [gradePresentation(grade).name,price,gradePresentation(grade).detail,fit?.label&&fit.label!=='OK'?fit.label:''].filter(Boolean).join('\n')}
// The tank bar: each fuel already in the tank, then the fuel being added, labelled with tooltips.
const gradeColors={diesel:'#d7b561',regular:'#e8b978',premium:'#e8b978',e85:'#6cd1b8',m100:'#af9beb',nitro90:'#f18b61'};
const addColor=computed(()=>battery.value?'#4ade80':store.value?'#38bdf8':drainPending.value>0?'#f87171':gradeColors[gradeId.value]||'#e8b978');
const mixSegments=computed(()=>{
 const t=tank.value;if(!t||store.value)return [];
 const out=[],level=meterLevel.value*100;let left=0;
 for(const part of tankParts.value){const width=level*part.percent/100;out.push({key:part.label,left,width,text:drainPending.value>0?'':`${Math.round(part.percent)}%`,tip:`${part.label}\n${volText(t.liters*part.percent/100)}\n${fmt(part.percent,0)}% of the fuel in the tank`});left+=width}
 if(drainPending.value>0){const d=drainFrac.value*100;out.push({key:'drain',adding:true,left:level-d,width:d,text:`−${Math.round(d)}%`,tip:`Draining\n${volText(drainPending.value)}\nThrown away, no refund`});return out}
 const adding=tankAdding.value*100;
 if(adding>.01)out.push({key:'adding',adding:true,left:level,width:adding,text:`+${Math.round(adding)}%`,tip:`${panel.value.pumping?'Still to pump':'Adding'} ${selectedGradeName.value}\n${volText(adding/100*t.capacity)}\n${fmt(adding,0)}% of the tank`});
 return out});
// Pump amount is signed: below zero drains the tank (free, the fuel is thrown away), above zero adds fuel.
// The slider keeps zero in the middle: its left half spans the fuel in the tank, its right half the free space.
const canDrain=computed(()=>isPump.value&&!store.value&&!!tank.value&&tank.value.liters>0&&!panel.value.pumping);
const draining=computed(()=>canDrain.value&&Number(drainLiters.value)>0);
const signedMin=computed(()=>canDrain.value?-toVol(tank.value.liters):0);
const signedAmount=computed({get:()=>draining.value?-toVol(drainLiters.value):slotAmount.value,set:value=>{const v=Number(value)||0;
 if(v<0&&canDrain.value){drainLiters.value=Math.min(Number(tank.value.liters),shown.value.fromVolume(-v));amount.value=0;lastSale.value=null;clearQuote()}
 else{drainLiters.value=0;slotAmount.value=Math.max(0,v)}}});
const sliderPos=computed({get:()=>{const v=signedAmount.value;const span=v<0?-signedMin.value:slotFree.value;return span>0?Math.max(-100,Math.min(100,v/span*100)):0},
 set:pos=>{const p=Number(pos)||0;signedAmount.value=p<0?p/100*-signedMin.value:p/100*slotFree.value}});
const DRAIN_HOLD_MS=800;
// Only shown when the car also has a store this pump can't fill (a hybrid's battery, diesel...).
const otherEnergyLabel=computed(()=>{const kinds=Array.isArray(panel.value.otherEnergy)?panel.value.otherEnergy:Object.values(panel.value.otherEnergy||{});if(!kinds.length)return '';return kinds.length===1&&kinds[0]==='electricEnergy'?'Charge battery':'Other fuel'});
const drainTip=computed(()=>{if(!draining.value)return '';const left=Math.max(0,tank.value.liters-drainLiters.value);return `${left<.05?'Empties the tank.':`${volText(left)} of the same blend stays in the tank.`} The drained fuel is thrown away, no refund.`});
// Pressing Drain starts draining at once (Lua drains it in steps, like pumping). Letting go
// before the hold fills stops it; holding through lets it run on to the chosen amount.
const drainHold=shallowRef(null);
function beginDrainHold(){
 if(drainHold.value||!draining.value||!drainValid.value||panel.value.busy||panel.value.pumping||serviceWorking.value)return;
 const hold={liters:Number(drainLiters.value),timer:0,end:null};
 const events=['mouseup','keyup','blur'];
 // Letting go early keeps the chosen amount on the slider; a finished hold clears it.
 const release=()=>{hold.end(true);lua.overhaul_career_maintenance_fuelSystem.stopPumping()};
 hold.end=keep=>{for(const e of events)window.removeEventListener(e,release);clearTimeout(hold.timer);if(drainHold.value===hold){drainHold.value=null;if(keep!==true)drainLiters.value=0}};
 for(const e of events)window.addEventListener(e,release);
 hold.timer=setTimeout(hold.end,DRAIN_HOLD_MS);
 drainHold.value=hold;drainStart.value=Number(tank.value.liters);
 lua.overhaul_career_maintenance_fuelSystem.startDrain(tankName.value,hold.liters,Number(tank.value.liters),JSON.parse(JSON.stringify(tank.value.blend)),requestContext()).then(ok=>{if(!ok){hold.end();drainStart.value=null}});
}
onUnmounted(()=>{if(drainHold.value){drainHold.value.end();lua.overhaul_career_maintenance_fuelSystem.stopPumping()}});
function emptyTank(){if(canDrain.value){drainLiters.value=Number(tank.value.liters);amount.value=0;lastSale.value=null;clearQuote()}}
watch(()=>panel.value.open,open=>{if(!open)drainLiters.value=0});
// A stopped drain leaves less in the tank; a kept amount larger than that becomes "empty it".
watch(()=>tank.value?.liters,liters=>{if(isPump.value&&!drainHold.value&&Number(drainLiters.value)>Number(liters||0))drainLiters.value=Number(liters||0)});
// Fuel about to go: the chosen drain, or what a running pump drain still has to take.
const drainPending=computed(()=>{if(draining.value)return Number(drainLiters.value);const p=panel.value.pumping;return p?.drain&&!store.value?Math.max(0,(Number(p.total)||0)-(Number(p.delivered)||0)):0});
// The bar keeps showing the fuel in the tank. A running drain lowers it by what the pump has
// confirmed drained, so it falls step by step even before the next tank snapshot arrives.
const drainStart=ref(null);
watch(()=>!!panel.value.pumping?.drain,on=>{if(!on)drainStart.value=null});
const meterLevel=computed(()=>{const p=panel.value.pumping,t=tank.value;
 if(p?.drain&&drainStart.value!=null&&t)return Math.min(slotLevel.value,Math.max(0,drainStart.value-(Number(p.delivered)||0))/Math.max(.001,t.capacity));
 return slotLevel.value});
const drainFrac=computed(()=>drainPending.value>0&&tank.value?Math.min(meterLevel.value,drainPending.value/Math.max(.001,tank.value.capacity)):0);
const meterAdding=computed(()=>drainPending.value>0?0:slotAdding.value);
function payNow(){if(!quoteData.value||panel.value.pumping||panel.value.busy)return;acknowledged.value=!!quoteData.value.warning;purchase()}
let quoteTimer=null;
watch(()=>panel.value.open&&isPump.value?`${tankName.value}|${gradeId.value}|${Number(amount.value)}|${tank.value?.liters}|${JSON.stringify(tank.value?.blend||{})}|${panel.value.pumping?1:0}|${panel.value.busy?1:0}`:'',key=>{
 clearTimeout(quoteTimer);if(!key||panel.value.pumping||panel.value.busy||!tank.value||!(Number(amount.value)>0))return;
 quoteTimer=setTimeout(()=>{if(panel.value.open&&isPump.value&&!panel.value.pumping&&!panel.value.busy&&!quoteData.value)quote()},250)});
onUnmounted(()=>clearTimeout(quoteTimer));

// Confirmation copy.
const serviceHeading=computed(()=>serviceAction.value==='drain'?`Drain ${volText(drainLiters.value)}?`:serviceAction.value==='remove'?'Switch back to gasoline?':serviceAction.value==='ethanol'?'Install flex-fuel kit?':serviceAction.value==='nitromethane'?'Install Nitro 90 kit?':'Install M100 kit?');
const servicePrice=computed(()=>{if(!panel.value.data?.career)return 'Free';const p=serviceAction.value==='ethanol'?panel.value.conversionPrice:serviceAction.value==='nitromethane'?panel.value.nitroConversionPrice:panel.value.methanolConversionPrice;return `$${Number(p||0).toLocaleString()}`});
const serviceBlurb=computed(()=>{const a=serviceAction.value;
 if(a==='drain')return `${volText(drainRemaining.value)} of the same blend stays in ${tankName.value}. The drained fuel is thrown away, no refund.`;
 if(a==='remove')return 'Free. Removes the kit and restores the stock gasoline tune. Saved maps and fuel stay. Drain ethanol or methanol before filling with gasoline.';
 const fuel=a==='ethanol'?'gasoline up to E85':a==='nitromethane'?'Nitro 90 only':'nearly pure methanol only';
 return `${servicePrice.value}; Runs on ${fuel}. Starts you on a safe map for this fuel; your current map is replaced. Saved maps, hardware and tank stay.`});
const serviceConfirmLabel=computed(()=>serviceAction.value==='drain'?`Drain ${volText(drainLiters.value)}`:serviceAction.value==='remove'?'Switch back':panel.value.data?.career?`Install ${servicePrice.value}`:'Install');
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/components/house/houseFieldSkin.scss" as *;
/* RLS house style (rlsCard / Job Broker): charcoal card, white-alpha panels, orange accent, Overpass, em-scaled. */
.fuel-shade{position:fixed;inset:0;z-index:1000;background:rgba(5,6,8,.72);display:grid;place-items:center;pointer-events:auto}
.fuel-panel{--accent:var(--bng-orange-b400,#ff6600);--panel:rgba(255,255,255,.06);--panel-2:rgba(255,255,255,.1);--line:rgba(255,255,255,.1);--muted:rgba(255,255,255,.72);--faint:rgba(255,255,255,.55);--money:#fde68a;--ok:#4ade80;--warn:#fbbf24;--bad:#fca5a5;
  /* One spacing scale for the whole panel: edge inset, section gap, card padding. */
  --fp-x:1em;--fp-y:.6em;--fp-gap:.75em;--fp-pad:.75em .9em;
  position:relative;font-family:"Overpass",var(--fnt-defs,sans-serif);font-size:clamp(.7rem,calc(1.48vh * var(--ui-scale,1)),2.4rem);line-height:1.35;color:#fff;
  width:min(90em,94vw);max-height:92vh;display:flex;flex-direction:column;overflow:hidden;background:rgba(21,21,23,.97);border-radius:.6em;box-shadow:0 0 0 1px rgba(255,255,255,.06),0 14px 40px rgba(0,0,0,.45)}
/* Tune, Hardware and Tank share one height so switching tabs does not resize the window. */
.fuel-panel.workspace{height:92vh}
.fuel-panel *{box-sizing:border-box}
.fuel-panel p{margin:0}
.bare{border:0;padding:0;margin:0;min-width:0}
.body-scroll{flex:1 1 auto;min-height:0;overflow:auto;scrollbar-gutter:stable}
.body-scroll::-webkit-scrollbar,.map-scroll::-webkit-scrollbar{width:.5em;height:.5em}
.body-scroll::-webkit-scrollbar-thumb,.map-scroll::-webkit-scrollbar-thumb{background:rgba(255,255,255,.22);border-radius:1em}
.body{padding:var(--fp-gap) var(--fp-x);display:flex;flex-direction:column;gap:var(--fp-gap)}
.pump-body{flex:1 1 auto;min-height:0;overflow:auto}
.fuel-panel.dock .pump-body{overflow-x:hidden}

/* header */
.rhead{display:flex;align-items:center;gap:.8em;padding:.75em var(--fp-x) .6em;border-bottom:1px solid var(--line);flex-shrink:0}
.ttl{display:grid;gap:.1em}
.rhead h1{margin:0;font-size:1.55em;font-weight:800;font-style:italic;letter-spacing:-.01em;line-height:1.1}
.kicker{display:inline-flex;align-items:center;gap:.45em;font-size:.75em;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:var(--accent)}
.kicker .fuel-ico{width:1.4em;height:1.4em}
.kicker.dim{color:rgba(255,255,255,.55)}
.hd-status{font-size:.7em;font-weight:700;letter-spacing:.08em;text-transform:uppercase;padding:.55em .75em .35em;line-height:1;border-radius:1em;background:rgba(255,255,255,.1);color:rgba(255,255,255,.75)}
.hd-status.ready{background:rgba(255,102,0,.22);color:#ffb27a}
.hd-status.on{background:rgba(74,222,128,.18);color:#86efac}
.push,.fuel-panel .push{margin-left:auto}
.banner{margin:var(--fp-gap) var(--fp-x) 0;padding:.6em .9em .5em;border-radius:.5em;background:var(--panel);font-weight:600}
.banner.warn{background:rgba(251,191,36,.12)}

/* stat strip */
.stats{display:flex;flex-wrap:wrap;align-items:center;gap:.45em 1.75em;padding:var(--fp-y) var(--fp-x);border-bottom:1px solid var(--line);background:rgba(255,255,255,.025);flex-shrink:0}
.stat{display:grid;gap:.15em;min-width:0}
.stat-key{font-size:.68em;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:rgba(255,255,255,.5)}
.stat-value{font-weight:700;font-size:1.08em;line-height:1.2;white-space:nowrap}
.stat.has-ico{grid-template-columns:auto minmax(0,1fr);column-gap:.6em;row-gap:.1em}
.stat-ico{grid-row:1/3;align-self:center;width:1.55em;height:1.55em;color:var(--faint)}
.stat.ok .stat-ico{color:var(--ok)}.stat.warn .stat-ico{color:var(--warn)}.stat.bad .stat-ico{color:var(--bad)}
.stat-value small{font-weight:600;font-size:.75em;color:var(--faint);margin-left:.3em}
.stat.ok .stat-value{color:var(--ok)}.stat.warn .stat-value{color:var(--warn)}.stat.bad .stat-value{color:var(--bad)}

/* controls */
.row{display:flex;align-items:center;gap:.6em;flex-wrap:wrap;min-width:0}
/* .row here is a layout line, not the house list row: drop its full width, padding, fill and hover. */
.fuel-panel .row{width:auto;padding:0;border-radius:0;background:transparent;color:inherit;font-size:inherit;font-weight:inherit;text-align:inherit;cursor:auto}
.fuel-panel .row:hover{background:transparent}
.row.baseline{align-items:baseline}
.seg{display:inline-flex;gap:.2em;padding:.2em;background:var(--panel);border-radius:.65em}
/* Segments size to their label: the house .seg shares width equally, which clipped "Hardware" and "Advanced". */
.seg button{appearance:none;flex:0 0 auto;border:0;background:transparent;color:var(--muted);font:inherit;font-weight:700;padding:.5em .9em .4em;border-radius:.45em;line-height:1;white-space:nowrap;cursor:pointer}
.seg button.on{background:rgba(255,255,255,.16);color:#fff}
.seg button .fuel-ico{opacity:.7}
.seg button.on .fuel-ico{opacity:1;color:var(--accent)}
.seg-label{display:inline-flex;align-items:center;gap:.4em;font-size:.72em;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--faint)}
.seg button:disabled{opacity:.4;cursor:default}
.seg.sm{font-size:.85em}
.btn{appearance:none;border:0;margin:0;padding:.72em 1.2em .58em;border-radius:.6em;font:inherit;font-weight:700;line-height:1;color:#fff;background:var(--panel-2);white-space:nowrap;cursor:pointer;transition:background-color .12s,transform .08s}
.btn:hover:not(:disabled){background:rgba(255,255,255,.18)}
.btn:active:not(:disabled){transform:translateY(1px)}
.btn:disabled{opacity:.45;cursor:default}
.btn.sm{font-size:.85em;padding:.6em .95em .48em}
.btn-primary{background:var(--accent)}.btn-primary:hover:not(:disabled){background:#ff7a1f}
.btn-danger{background:#b91c1c}.btn-danger:hover:not(:disabled){background:#dc2626}
.text-btn{appearance:none;border:0;background:none;color:var(--accent);font:inherit;font-weight:700;padding:.3em 0;cursor:pointer;display:inline-flex;align-items:center;gap:.3em;white-space:nowrap}
.text-btn:disabled{opacity:.45;cursor:default}
.icon-btn{appearance:none;border:0;display:grid;place-items:center;width:2.3em;height:2.3em;border-radius:.6em;background:var(--panel-2);color:#fff;padding:0;cursor:pointer;flex-shrink:0}
.icon-btn svg{width:1.1em;height:1.1em;fill:none;stroke:currentColor;stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round}
.icon-btn:disabled{opacity:.4;cursor:default}
.chev{display:inline-block;width:.45em;height:.45em;border-right:.14em solid currentColor;border-bottom:.14em solid currentColor;transform:translateY(-.15em) rotate(45deg);margin-left:.35em}
.chev.up{transform:translateY(.1em) rotate(-135deg)}
.dd{display:inline-flex;align-items:center;gap:.3em;font:inherit;font-weight:700;color:#fff;background:var(--panel-2);border-radius:.6em;padding:.55em .85em .42em .95em;cursor:pointer;list-style:none;white-space:nowrap}
.dd .chev{color:var(--accent)}
.dd.sm{font-size:.85em}
.menu{position:relative;display:inline-block}
.menu>summary::-webkit-details-marker{display:none}
.menu.disabled{opacity:.45;pointer-events:none}
.pop{position:absolute;z-index:20;left:0;top:calc(100% + .35em);min-width:14em;background:#232327;border-radius:.6em;box-shadow:0 0 0 1px rgba(255,255,255,.08),0 12px 36px rgba(0,0,0,.55);padding:.4em;display:grid;gap:.15em}
.pop.right{left:auto;right:0}
.pop.up{top:auto;bottom:calc(100% + .35em)}
.pop button{appearance:none;border:0;background:transparent;color:#fff;font:inherit;font-weight:700;text-align:left;padding:.6em .8em .5em;border-radius:.4em;cursor:pointer;white-space:nowrap}
.pop button:hover:not(:disabled),.pop button.on{background:rgba(255,255,255,.1)}
.pop button:disabled{opacity:.45;cursor:default}
.pop .danger{color:var(--bad)}
.pop hr{border:0;border-top:1px solid var(--line);margin:.2em 0;width:100%}
.pop .pad{padding:.3em .8em .4em}
.pop-check{display:flex;align-items:center;gap:.5em;padding:.5em .8em;font-weight:700}
.pop-sub{display:grid;gap:.45em;padding:.4em .8em .5em}
.more-pop{min-width:18em}
.presets-pop{min-width:20em;max-width:27em}
/* Saved map rows: the name loads the map; Rename and Delete follow as smaller menu actions.
   Names wrap in full (40 characters at most), so two long names never shorten to the same text. */
.saved-map-row{display:flex;align-items:center;gap:.15em;min-width:0}
.pop .saved-map-name{flex:1 1 0;min-width:0;justify-content:flex-start;line-height:1.2;white-space:normal;overflow-wrap:anywhere}
.pop .saved-map-action{font-size:.85em;padding:.6em .7em .48em;color:var(--muted)}
.pop .saved-map-action:hover:not(:disabled){color:#fff}
.pop .saved-map-action.danger{color:var(--bad)}
.pop .saved-map-action.danger:hover:not(:disabled){background:rgba(185,28,28,.35);color:#fecaca}
.pill{display:inline-flex;align-items:center;gap:.3em;width:fit-content;padding:.4em .55em .25em;line-height:1;border-radius:.3em;background:rgba(255,255,255,.09);color:rgba(255,255,255,.8);font-size:.74em;font-weight:700;white-space:nowrap}
.pill.accent{background:rgba(255,102,0,.25);color:#ffb27a}.pill.ok{background:rgba(74,222,128,.18);color:#86efac}.pill.warn{background:rgba(251,191,36,.18);color:#fde68a}.pill.bad{background:rgba(252,165,165,.18);color:var(--bad)}
.pill-btn{appearance:none;border:0;font:inherit;font-size:.74em;cursor:pointer}
.tip{position:relative;display:grid;place-items:center;width:1.5em;height:1.5em;border-radius:50%;border:0;background:transparent;color:var(--faint);font:inherit;font-weight:800;font-size:.85em;padding:0;box-shadow:inset 0 0 0 .1em rgba(255,255,255,.3);cursor:help;flex-shrink:0}
.tip::after{content:attr(data-tip);position:absolute;left:calc(100% + .5em);top:50%;transform:translate(-.3em,-50%);width:20em;padding:.6em .75em .5em;border-radius:.45em;background:#2b2c30;color:#fff;font-size:.95em;font-weight:600;line-height:1.35;text-align:left;box-shadow:0 10px 30px rgba(0,0,0,.55);opacity:0;pointer-events:none;transition:opacity .12s,transform .12s;z-index:30;white-space:normal}
.tip:hover::after,.tip.focus-visible::after{opacity:1;transform:translate(0,-50%)}
.muted{color:var(--muted);font-size:.9em;font-weight:600}
.faint{color:var(--faint);font-size:.82em;font-weight:600}
.strong{font-weight:800}
.money{color:var(--money);font-weight:800}
.panel{padding:var(--fp-pad);border-radius:.5em;background:var(--panel);display:grid;gap:.5em;align-content:start;min-width:0}
.panel.inset{background:rgba(0,0,0,.25)}
.alert{display:flex;align-items:center;gap:.7em;padding:.55em .9em .45em;border-radius:.5em;background:var(--panel);font-weight:600;font-size:.9em}
.alert.warn{background:rgba(251,191,36,.12)}
.span-all{grid-column:1/-1}
input[type=range]{width:100%;margin:.3em 0 0;accent-color:var(--accent);height:1.2em;cursor:pointer}
input[type=range]:disabled{opacity:.35;cursor:default}
input[type=checkbox]{width:1.1em;height:1.1em;margin:0;accent-color:var(--accent)}
.check{font-weight:700;font-size:.9em}
/* Nitrous limits: labelled house fields in a grid, not bare browser inputs. */
.nitrous-fields{display:grid;grid-template-columns:repeat(auto-fill,minmax(9em,1fr));gap:.6em}
.nitrous-field{display:grid;gap:.3em;min-width:0}
.nitrous-field .num-input{width:100%}
.num-input,.num input,.text-input{font:inherit;font-weight:700;color:#fff;background:rgba(0,0,0,.3);border:1px solid var(--line);border-radius:.5em;padding:.5em .6em .35em;width:5.5em;text-align:right}
.text-input{text-align:left;flex:1;width:auto}
.num{display:inline-flex;align-items:center;gap:.4em;font-weight:700}
.fuel-panel input[type=number]{appearance:textfield}
.fuel-panel input[type=number]::-webkit-inner-spin-button,.fuel-panel input[type=number]::-webkit-outer-spin-button{-webkit-appearance:none;appearance:none;margin:0}
input.focus-visible,button.focus-visible,summary.focus-visible{outline:none;box-shadow:0 0 0 2px #fff,0 0 0 4px rgba(255,102,0,.7)}
.scale{position:relative;display:flex;justify-content:space-between;font-size:.72em;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--faint)}
.mark{position:absolute;top:-.1em;transform:translateX(-50%);color:#fff;opacity:.8}
.mark::before{content:'';display:block;width:2px;height:.7em;background:#fff;margin:0 auto .2em;opacity:.7}
.meter{height:.7em;border-radius:1em;background:rgba(255,255,255,.1);overflow:hidden;display:flex}
.meter i{display:block;height:100%}

/* tune: simple */
.simple-grid{display:grid;grid-template-columns:1fr 1fr 1.35fr;gap:var(--fp-gap)}
.simple-grid.no-boost{grid-template-columns:1fr 1fr}
.dial{gap:.45em}
.big{display:flex;align-items:baseline;gap:.3em;font-size:1.75em;font-weight:800;line-height:1}
.big small{font-size:.45em;font-weight:700;color:var(--faint);letter-spacing:.06em}
.big-input{width:3.3em;font:inherit;font-weight:800;color:#fff;background:transparent;border:0;border-bottom:.06em solid transparent;padding:0;font-variant-numeric:tabular-nums}
.big-input:hover,.big-input:focus{border-bottom-color:rgba(255,255,255,.3)}
.foot{margin-top:auto}
.cut{border-top:1px solid var(--line);padding-top:.6em;display:grid;gap:.3em}
.panel.cut{border-top:0}

/* tune: advanced */
.adv-boost{display:grid;grid-template-columns:1.4fr 1fr;gap:var(--fp-gap)}
.toolstrip{display:flex;align-items:center;gap:.5em;flex-wrap:wrap;padding:.45em .6em;border-radius:.5em;background:var(--panel)}
.vsep{width:1px;height:1.6em;background:var(--line);margin:0 .2em}
.map-scroll{overflow:auto;max-height:26em;font-variant-numeric:tabular-nums}
table.rmap{border-collapse:separate;border-spacing:3px;width:100%;font-size:.82em}
table.rmap thead th{position:sticky;top:0;z-index:2;background:#1b1b1d}
table.rmap tbody th{position:sticky;left:0;z-index:1;background:#1b1b1d;text-align:right}
.axis{appearance:none;border:0;background:none;color:var(--faint);font:inherit;font-weight:700;padding:.35em .2em .2em;cursor:pointer;white-space:nowrap}
.axis:hover{color:#fff}
.axis.rowh{padding-right:.6em}
table.rmap td{padding:0;border-radius:.3em;position:relative}
table.rmap td input{width:100%;min-width:4.2em;background:transparent;border:0;color:#fff;font:inherit;font-weight:700;text-align:center;padding:.5em .1em .35em;cursor:cell}
table.rmap td input[readonly]::-webkit-inner-spin-button,table.rmap td input[readonly]::-webkit-outer-spin-button{display:none}
table.rmap td.op{box-shadow:inset 0 0 0 2px #fde68a}
table.rmap td.sel{box-shadow:inset 0 0 0 2px var(--accent)}
table.rmap td.op.sel{box-shadow:inset 0 0 0 2px var(--accent),inset 0 0 0 4px #fde68a}
table.rmap td.changed::after{content:'';position:absolute;top:.25em;right:.25em;width:.35em;height:.35em;border-radius:50%;background:#fff;opacity:.7;pointer-events:none}
.legend-row{row-gap:.5em}
.legend{display:flex;align-items:center;gap:1.2em;flex-wrap:wrap;font-size:.75em;font-weight:700;color:var(--faint)}
.legend i{display:inline-block;width:.9em;height:.9em;border-radius:.2em;margin-right:.35em;vertical-align:-.1em}
.lg-rich{background:rgba(96,165,250,.6)}.lg-stock{background:rgba(255,255,255,.1)}.lg-lean{background:rgba(255,102,0,.6)}.lg-op{box-shadow:inset 0 0 0 2px #fde68a}
.lg-draft{height:0!important;border-top:2px solid var(--accent);border-radius:0!important}.lg-inst{height:0!important;border-top:2px dashed rgba(255,255,255,.6);border-radius:0!important}
.curve-body{display:flex;gap:.5em}
.y-labels{display:flex;flex-direction:column;justify-content:space-between;width:3em;flex-shrink:0;font-size:.72em;font-weight:700;color:var(--faint);padding:.6em 0}
.curve svg{display:block;width:calc(100% - 3.5em);height:8em;overflow:visible}
.curve-grid{fill:none;stroke:rgba(255,255,255,.08);stroke-width:1}
.draft-line,.installed-line{fill:none;stroke-width:2.5;vector-effect:non-scaling-stroke}
.draft-line{stroke:#ff6600}.installed-line{stroke:rgba(255,255,255,.55);stroke-dasharray:7 5;stroke-width:2}
.cursor-line{stroke:rgba(255,255,255,.4);stroke-dasharray:2 4}

/* decel */
.collapse{display:grid;gap:.7em;padding:var(--fp-pad);border-radius:.5em;background:var(--panel)}
.collapse strong{font-weight:800}
.decel-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:var(--fp-gap)}

/* hardware */
.kit-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:var(--fp-gap)}
.kit{position:relative;display:grid;grid-template-columns:minmax(0,1fr);border-radius:.5em;overflow:hidden;background:var(--panel);min-width:0}
/* Installed outline surrounds the whole card without intercepting its controls. */
.kit.installed::after{content:'';position:absolute;inset:0;border-radius:inherit;box-shadow:inset 0 0 0 2px rgba(255,102,0,.7);pointer-events:none;z-index:1}
.kit-copy{display:grid;gap:.35em;padding:.7em .85em .8em;align-content:start}
.kit-copy strong{font-size:1.05em;line-height:1.15}
.detail{display:flex;align-items:center;gap:1.2em;padding:.7em .9em;border-radius:.5em;background:rgba(0,0,0,.25)}
.detail-copy{display:grid;gap:.15em;min-width:0}
.hw-controls{display:flex;flex-wrap:wrap;align-items:end;gap:var(--fp-gap)}
.hw-field{display:grid;gap:.3em}
.hw-menu :deep(.house-button){min-width:13em;justify-content:space-between;gap:.8em}
.hw-current{display:inline-flex;align-items:baseline;gap:.5em;font-weight:800}
.hw-current small{font-size:.8em;font-weight:700;color:var(--faint)}
.hw-pop{min-width:32em;max-height:22em;overflow:auto}
.hw-owned-pop{width:30em;max-width:calc(100vw - 4em)}
.hw-owned-pop button{white-space:normal}
.hw-pop button.hw-option{display:block;width:100%}
.hw-option :deep(.btn-label){display:grid !important;grid-template-columns:10.5em minmax(4.5em,1fr) 5.5em 5em;align-items:baseline;gap:.6em;width:100%}
.hw-option b{font-weight:800}
.hw-option .hw-sub{color:var(--faint);font-size:.85em;font-weight:600}
.hw-option .hw-tag{justify-self:end;font-size:.85em;color:var(--money)}
.hw-option .hw-tag.ok{color:var(--ok-ink,#86efac)}
.hw-option.inst{box-shadow:inset .2em 0 0 var(--ok)}
/* Dot separator: the font's middle dot swallows the space after it. */
.sep{display:inline-block;width:.26em;height:.26em;border-radius:50%;background:currentColor;opacity:.55;margin:0 .5em;vertical-align:.22em}
.hw-delta{font-size:.82em;font-weight:700;color:var(--faint);white-space:nowrap}
.hw-delta.up{color:var(--ok-ink,#86efac)}.hw-delta.down{color:var(--bad)}
.hw-option .hw-delta{justify-self:end}
.detail.spec{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,2fr) auto;align-items:center;gap:1em}
.detail.spec.preview{box-shadow:inset 0 0 0 1px rgba(255,255,255,.18)}
.spec-head{display:grid;gap:.15em;min-width:0}
.spec-stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.6em}
.spec-stats .stat{gap:.1em}
.spec-buy{display:flex;align-items:center;gap:.8em;justify-self:end}
.delivery-stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.6em}
.hw-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--fp-gap);align-items:start}
.hw-grid .detail.spec{grid-template-columns:minmax(0,1fr);gap:.6em}
.hw-grid .spec-buy{justify-self:stretch;justify-content:space-between}
.big-money{font-size:1.2em}

/* tank */
.tank-grid{display:grid;grid-template-columns:1.3fr 1fr;gap:var(--fp-gap);align-items:start}
.blend{height:1.1em;border-radius:.4em;overflow:hidden;display:flex}
.blend i{display:block;height:100%}
.sw{display:inline-block;width:.8em;height:.8em;border-radius:.2em;margin-right:.35em;vertical-align:-.05em}

/* pump: a flat dispenser. Readout and tank on top, grade keys, one Fuel button. */
.pump-body{gap:var(--fp-gap)}
.pump-body fieldset.bare{display:grid;gap:var(--fp-gap)}
.pump-display{display:grid;gap:.35em;align-content:start;padding:var(--fp-pad);border-radius:.5em;background:rgba(0,0,0,.35);box-shadow:inset 0 0 0 1px var(--line)}
.lcd-row{display:grid;grid-template-columns:6.5em minmax(0,1fr);align-items:center;gap:.8em}
.lcd-row.sub{grid-template-columns:6.5em auto;justify-content:start;padding-top:.35em;margin-top:.1em;border-top:1px solid var(--line)}
.lcd-key{display:grid;font-size:.75em;font-weight:800;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);line-height:1.15}
.lcd-key{white-space:nowrap}
.lcd-key small{font-size:.85em;font-weight:700;letter-spacing:.04em;text-transform:none;color:var(--faint)}
/* Seven-segment readout. The ghost "8"s behind the digits are the unlit segments of a real display. */
.lcd{position:relative;display:block;justify-self:stretch;text-align:right;font-family:"RLS DSEG7","Digital",monospace;font-variant-numeric:tabular-nums;letter-spacing:.09em;font-size:1.7em;line-height:1;color:#fff;padding:.3em .31em .22em;border-radius:.3em;background:rgba(255,255,255,.05);white-space:nowrap}
.lcd.big{font-size:2.9em}
.lcd::before{content:attr(data-ghost);position:absolute;right:.31em;top:.3em;color:rgba(255,255,255,.06);pointer-events:none}
.lcd-row.sub .lcd{min-width:5.5em}
.pump-display.live .lcd{color:var(--accent-soft,#ffb27a)}
.pump-tank{align-content:start}
.pump-tank .tank-seg{display:flex;width:100%;box-sizing:border-box}
.pump-tank .tank-seg button{flex:1 1 0;min-width:0;justify-content:center}
/* Opaque track: the empty cover must match it exactly. */
.tank-meter{--track:#333336;position:relative;height:1.6em;border-radius:.35em;background:var(--track);overflow:hidden}
.tank-meter i{position:absolute;top:0;bottom:0;left:0;width:100%;transform-origin:left center;transition:transform .25s linear}
.tank-meter .level{background:var(--accent)}
.tank-meter .empty{background:var(--track)}
.tank-meter .adding{transition:none}
.tank-meter.n2o .level{background:#38bdf8}
.tank-meter.battery .level{background:#4ade80}
.tank-meter .adding{background:repeating-linear-gradient(45deg,color-mix(in srgb,var(--add,#ff6600) 60%,transparent) 0 .4em,color-mix(in srgb,var(--add,#ff6600) 25%,transparent) .4em .8em)}
.tank-meter i.drain-cut{width:auto;transform:none;background:repeating-linear-gradient(45deg,rgba(239,68,68,.92) 0 .4em,rgba(153,27,27,.92) .4em .8em);box-shadow:inset 1px 0 0 rgba(0,0,0,.35);transition:left .25s linear,width .25s linear}
.tank-meter .tick{position:absolute;top:0;bottom:0;width:1px;background:rgba(0,0,0,.35)}
/* Fill level and free space ride on the bar itself; the shadow keeps them readable over orange and dark. */
.tank-meter .tank-label{position:absolute;inset:0;display:flex;align-items:center;justify-content:space-between;padding:.1em .6em 0;font-size:.8em;font-weight:700;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.75);font-variant-numeric:tabular-nums;pointer-events:none}
.tank-meter .tank-label b{font-weight:800}
.grade-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(9em,1fr));gap:var(--fp-gap)}
.grade{appearance:none;border:0;font:inherit;color:#fff;display:grid;gap:.2em;justify-items:center;align-content:start;text-align:center;padding:.7em .8em .75em;border-radius:.5em;background:var(--panel);cursor:pointer}
.grade:hover:not(:disabled){background:var(--panel-2)}
.grade .grade-name{font-size:.75em;font-weight:800;letter-spacing:.09em;text-transform:uppercase;color:#fff}
.grade em{font-style:normal;font-weight:800;color:var(--money);font-size:1em;font-variant-numeric:tabular-nums}
.grade em small{color:var(--faint);font-weight:700;font-size:.75em}
/* The flat stand-in for the pump's big grade key. */
/* The pump's grade key, flat: a slot notch on top, the big number, and a Press caption. */
.grade .grade-key{position:relative;display:grid;justify-items:center;gap:.15em;min-width:3.3em;margin:.25em 0 .1em;padding:.55em .55em .3em;border-radius:.35em .35em .6em .6em;background:rgba(255,255,255,.1);box-shadow:inset 0 -.12em 0 rgba(0,0,0,.25);font-size:1.9em;line-height:1;color:#fff}
.grade .grade-key::before{content:'';position:absolute;top:.18em;left:50%;width:1.1em;height:.16em;border-radius:1em;background:rgba(0,0,0,.35);transform:translateX(-50%)}
.grade .grade-key b{font-weight:900;font-style:italic}
.grade .grade-key small{font-size:.26em;font-weight:800;letter-spacing:.3em;text-transform:uppercase;opacity:.7;padding-left:.3em}
.grade:hover:not(:disabled) .grade-key{background:rgba(255,255,255,.16)}
/* Pressing a grade pushes only its key down, like a pump button; the card stays put. */
.grade-row .grade:active:not(:disabled){transform:none}
.grade .grade-key{transition:transform .06s ease-out,box-shadow .06s ease-out}
.grade-row .grade:active:not(:disabled) .grade-key{transform:translateY(.06em);box-shadow:inset 0 -.04em 0 rgba(0,0,0,.25)}
.grade .grade-detail{font-size:.8em;font-weight:600;color:var(--faint)}
.grade .pill{font-size:.72em}
.grade.on{box-shadow:inset 0 0 0 2px var(--accent);background:rgba(255,102,0,.12)}
/* The selected key keeps its colour; only its light turns on. */
.grade.on .grade-key::before{background:var(--accent);box-shadow:0 0 .35em .05em rgba(255,102,0,.8)}
/* No section headers: the blend line, bar, presets and slider read as one compact block. */
.pump-tank .tank-info{font-size:.88em;gap:.5em}
.pump-tank .amount-row .presets{flex:1 1 auto;display:flex}
.pump-tank .amount-row .presets button{flex:1 1 0;justify-content:center;padding-left:.3em;padding-right:.3em}
.amount-line{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:.7em}
.stepper{display:inline-flex;align-items:center;border-radius:.5em;background:rgba(0,0,0,.3);box-shadow:inset 0 0 0 1px var(--line)}
.stepper input{width:3.2em;border:0;background:transparent;color:#fff;font:inherit;font-weight:800;text-align:right;padding:.4em .1em .3em;font-variant-numeric:tabular-nums}
.stepper .unit{font-size:.78em;font-weight:700;color:var(--faint);padding:0 .4em 0 .25em}
.stepper .step{appearance:none;border:0;border-radius:.45em;background:transparent;color:var(--muted);font:inherit;font-size:1em;font-weight:800;width:1.9em;height:2em;padding:0;display:grid;place-items:center;flex:0 0 auto}
.stepper .step:hover:not(:disabled){background:var(--panel-2);color:#fff}
.stepper .step:disabled{opacity:.35}
.presets{gap:.35em}
.pump-actions{display:flex;align-items:center;gap:var(--fp-gap);flex-wrap:wrap}
.fuel-go{flex:1 1 16em;justify-content:center;padding:.9em 1.2em .75em;font-size:1.1em;letter-spacing:.02em}
/* Estimate tag: the fill goes on the tab; only Pay & leave charges. */
.fuel-go .go-est{font-size:.72em;font-weight:700;padding:.3em .55em .2em;border-radius:.35em;background:rgba(0,0,0,.25);color:rgba(255,255,255,.75);letter-spacing:.02em}
.fuel-go.stop{background:var(--panel-2);box-shadow:inset 0 0 0 2px var(--accent)}

/* Pump docks on the left as one narrow column, so the car and the station stay in view. */
.fuel-shade.dock{background:transparent;place-items:center start;padding-left:max(1.5vw, var(--safezone-left, 0px));pointer-events:none}
.fuel-panel.dock{pointer-events:auto;width:min(26em,92vw);max-height:94vh;--fp-x:.75em;--fp-gap:.55em;--fp-pad:.65em .75em}
.fuel-panel.dock .pump-body{gap:var(--fp-gap);padding:var(--fp-x)}
.fuel-panel.dock .pump-body fieldset.bare{gap:var(--fp-gap)}
.fuel-panel.dock .pump-display{gap:.3em}
.fuel-panel.dock .lcd-row,.fuel-panel.dock .lcd-row.sub{grid-template-columns:5.6em minmax(0,1fr)}
.fuel-panel.dock .lcd.big{font-size:2.15em}
.fuel-panel.dock .lcd{font-size:1.35em}
.fuel-panel.dock .pump-tank{gap:.4em}
.fuel-panel.dock .tank-meter{height:1.55em}
.fuel-panel.dock .grade-grid{grid-template-columns:repeat(auto-fit,minmax(6.6em,1fr));gap:var(--fp-gap)}
.fuel-panel.dock .grade{padding:.6em .45em;gap:.15em}
.fuel-panel.dock .grade .grade-key{font-size:1.45em;min-width:2.8em;margin:.1em 0}
.fuel-panel.dock .grade .grade-detail{display:none}
.fuel-panel.dock .grade .pill{font-size:.66em}
/* Grade keys in one row; details in a tooltip above each key. */
.grade-row{display:grid;grid-template-columns:repeat(var(--n,3),minmax(0,1fr));gap:.5em}
/* The key is the button: it fills the tile and is the only part that lights up. */
/* Same box in every state, so nothing shifts on hover or select. */
.fuel-panel .grade-row .grade,.fuel-panel .grade-row .grade.on,.fuel-panel .grade-row .grade:hover:not(:disabled){position:relative;overflow:visible;padding:.6em .4em .5em;background:var(--panel);box-shadow:none}
.grade-row .grade :deep(.btn-label){display:grid;justify-items:center;gap:.45em;overflow:visible;width:100%}
.grade-row .grade .grade-name{font-size:.62em;letter-spacing:.06em;white-space:nowrap}
.fuel-panel.dock .grade-row .grade .grade-key{font-size:calc(2.05em - var(--n,3) * .16em);min-width:0;width:100%;max-width:none;margin:0;padding:.6em .2em .32em}
/* Fit warning: a small lamp in the key's corner, clear of the grade name. */
.grade-dot{position:absolute;top:.22em;right:.22em;width:.2em;height:.2em;border-radius:50%;background:var(--bad)}
.grade.warn .grade-dot{background:var(--warn)}
.grade-row .grade[data-tip]::after,.mix-seg[data-tip]::after{content:attr(data-tip);position:absolute;bottom:calc(100% + .45em);left:50%;transform:translate(-50%,.25em);width:max-content;max-width:15em;padding:.45em .6em .35em;border-radius:.4em;background:#2b2c30;color:#fff;font-size:.78em;font-weight:600;line-height:1.35;text-align:center;white-space:pre-line;box-shadow:0 10px 30px rgba(0,0,0,.55);opacity:0;pointer-events:none;transition:opacity .12s ease,transform .12s ease;z-index:30}
.grade-row .grade:first-child::after,.mix-seg:first-child::after{left:0;transform:translate(0,.25em)}
.grade-row .grade:last-child:not(:first-child)::after{left:auto;right:0;transform:translate(0,.25em)}
.grade-row .grade:hover::after,.grade-row .grade.focus-visible::after,.mix-seg:hover::after{opacity:1;transform:translate(-50%,0)}
.grade-row .grade:first-child:hover::after,.grade-row .grade:first-child.focus-visible::after,.grade-row .grade:last-child:not(:first-child):hover::after,.grade-row .grade:last-child:not(:first-child).focus-visible::after,.mix-seg:first-child:hover::after{transform:translate(0,0)}
/* Tank mix: percentages over the bar; hovering a part names it. */
.mix{position:relative}
.mix.labelled{padding-top:1.2em}
.mix-hits{position:absolute;inset:0}
.mix-seg{position:absolute;top:0;bottom:0;display:flex;justify-content:center;cursor:help}
.mix-seg b{font-size:.68em;font-weight:800;line-height:1.7;color:var(--faint);white-space:nowrap}
.mix-seg.adding b{color:var(--add,var(--accent))}
/* Signed amount: zero mark in the middle; the fill runs from zero to the thumb, red when draining. */
.amount-line :deep(.bng-slider){--r:.225em;--x0:.35em;--x1:calc(100% - .35em);--trk:rgba(255,255,255,.12);--fill:var(--accent);--cap-l:var(--fill);--cap-r:var(--trk);
  background-image:radial-gradient(circle at 100% 50%,var(--cap-l) calc(var(--r) - .5px),transparent var(--r)),radial-gradient(circle at 0 50%,var(--cap-r) calc(var(--r) - .5px),transparent var(--r)),
    linear-gradient(90deg,transparent var(--x0),var(--fill) var(--x0) var(--fill-x),var(--trk) var(--fill-x) var(--x1),transparent var(--x1))!important;
  background-size:var(--r) calc(var(--r) * 2),var(--r) calc(var(--r) * 2),100% calc(var(--r) * 2)!important;
  background-position:left calc(var(--x0) - var(--r)) center,right calc(var(--x0) - var(--r)) center,0 50%!important;background-repeat:no-repeat!important}
.amount-line.signed :deep(.bng-slider){--zero-x:calc(.575em + var(--d,.5) * (100% - 1.15em));--cap-l:var(--trk);
  background-image:linear-gradient(90deg,transparent calc(var(--zero-x) - 1px),rgba(255,255,255,.75) calc(var(--zero-x) - 1px) calc(var(--zero-x) + 1px),transparent calc(var(--zero-x) + 1px)),
    radial-gradient(circle at 100% 50%,var(--cap-l) calc(var(--r) - .5px),transparent var(--r)),radial-gradient(circle at 0 50%,var(--cap-r) calc(var(--r) - .5px),transparent var(--r)),
    linear-gradient(90deg,transparent var(--x0),var(--trk) var(--x0) min(var(--fill-x),var(--zero-x)),var(--fill) 0 max(var(--fill-x),var(--zero-x)),var(--trk) 0 var(--x1),transparent var(--x1))!important;
  background-size:100% .85em,var(--r) calc(var(--r) * 2),var(--r) calc(var(--r) * 2),100% calc(var(--r) * 2)!important;
  background-position:0 50%,left calc(var(--x0) - var(--r)) center,right calc(var(--x0) - var(--r)) center,0 50%!important}
.amount-line.draining :deep(.bng-slider){--fill:#ef4444}
.amount-line.draining .stepper input{color:#fca5a5}
.presets .empty-preset.on{background:#b91c1c;color:#fff}
/* Quote warning: a "!" on the button; hovering shows the warning. */
/* Overpass sits low in its line box: lift the triangle and the estimate pill onto the text's cap height. */
.fuel-go .go-warn{color:#fde68a;vertical-align:-.08em;margin-right:.1em}
.fuel-go .go-est{display:inline-block;vertical-align:.12em;margin-left:.35em}
.fuel-go[data-tip]{position:relative;overflow:visible}
.fuel-go[data-tip]::after{content:attr(data-tip);position:absolute;bottom:calc(100% + .45em);left:0;right:0;padding:.45em .6em;border-radius:.4em;background:#1a1a1c;box-shadow:0 0 0 1px rgba(255,255,255,.1),0 6px 16px rgba(0,0,0,.45);color:#fff;font-size:.78em;font-weight:600;line-height:1.35;text-align:left;white-space:normal;pointer-events:none;opacity:0;transform:translateY(.25em);transition:opacity .12s,transform .12s;z-index:5}
/* A disabled button still shows its tooltip at full strength: dim the face, not the whole button. */
.fuel-go[data-tip]:disabled{opacity:1;box-shadow:inset 0 0 0 100em rgba(24,24,27,.55)}
.fuel-go[data-tip]:disabled :deep(.btn-label){opacity:.5}
.fuel-go[data-tip]:hover::after,.fuel-go[data-tip].focus-visible::after{opacity:1;transform:none}
.fuel-panel.dock .pump-actions{gap:var(--fp-gap)}
.fuel-panel.dock .fuel-go{flex:1 1 auto;padding:.8em .8em .65em}
.fuel-panel.dock .fuel-go.pay-leave{flex:0 1 auto}
/* Refuel and Pay & leave share one row; the estimate wraps under the label when it doesn't fit. */
.fuel-panel.dock .pump-actions.pay-split{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);align-items:stretch}
.fuel-panel.dock .pump-actions.pay-split .fuel-go{min-width:0;font-size:1em;padding-left:.5em;padding-right:.5em;text-align:center}
.fuel-panel.dock .pump-actions.pay-split .fuel-go :deep(.btn-label){flex-wrap:wrap;justify-content:center;row-gap:.3em}
.fuel-panel.dock .pump-actions .other-energy{flex:1 1 100%;grid-column:1/-1;font-size:.85em}
.fuel-panel.dock .pump-actions .cancel-op{flex:1 1 100%;font-size:.85em}
.fuel-panel.dock .pump-actions .btn.pump-close{flex:0 0 auto;width:3em;height:auto;align-self:stretch}

/* footer, toast, modals */
.rfoot{display:flex;align-items:center;gap:.7em;padding:.65em var(--fp-x);border-top:1px solid var(--line);background:rgba(0,0,0,.2);flex-shrink:0}
.rfoot .note{color:var(--faint);font-size:.85em;font-weight:600}
.toast{position:absolute;left:50%;bottom:4.6em;transform:translateX(-50%);display:inline-flex;align-items:center;gap:.8em;max-width:90%;background:#232327;border-radius:.6em;padding:.6em .6em .5em .9em;box-shadow:0 0 0 1px rgba(255,255,255,.08),0 10px 30px rgba(0,0,0,.5);font-weight:700;font-size:.9em;z-index:25}
.toast>i{width:.55em;height:.55em;border-radius:50%;background:var(--accent);display:block;flex-shrink:0}
.toast button{appearance:none;border:0;background:none;color:var(--faint);font:inherit;font-size:1.3em;cursor:pointer;padding:0 .3em}
.modal-backdrop{position:fixed;inset:0;z-index:40;display:grid;place-items:center;background:rgba(3,4,6,.6);padding:1em}
.modal{width:min(30em,92vw);background:#1b1b1e;border-radius:.6em;box-shadow:0 0 0 1px rgba(255,255,255,.08),0 20px 60px rgba(0,0,0,.6);padding:1.3em 1.4em 1.2em;display:grid;gap:.6em}
.modal h2{margin:0;font-size:1.45em;font-weight:800;font-style:italic;line-height:1.15}
.modal .acts{display:flex;justify-content:flex-end;gap:.5em;margin-top:.5em}
.modal textarea{width:100%;font:.85em/1.5 monospace;color:#fff;background:rgba(0,0,0,.3);border:1px solid var(--line);border-radius:.5em;padding:.6em;resize:vertical}
.live-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(10em,1fr));gap:.8em 1.4em}
.diag{margin:0;padding-left:1.2em;color:var(--bad);font-weight:600;font-size:.9em}

@media (max-width: 1100px){.hw-grid,.delivery-stats{grid-template-columns:1fr 1fr}.simple-grid,.simple-grid.no-boost,.adv-boost,.tank-grid,.decel-grid{grid-template-columns:1fr}.kit-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
</style>

<style>
/* Seven-segment readouts on the pump. The font ships with the game (OFL, /ui/common/DSEG-LICENSE.txt). */
@font-face{font-family:"RLS DSEG7";src:url("/ui/common/DSEG7Classic-Regular.ttf") format("truetype");font-display:block}
</style>

<style scoped>
.menu :deep(.accordion-body){overflow:visible;max-height:none;padding:0}
/* Icon + text inside HouseButton labels; segments never clip their text. */
.fuel-panel :deep(.btn-label){display:inline-flex;align-items:center;gap:.45em}
.seg :deep(.btn-label){overflow:visible}
/* Grade keys stack name, price, key and fit like the label strip on a real pump. */
.grade :deep(.btn-label){display:grid;justify-items:center;gap:.2em;overflow:visible}
.modal-scrim{position:absolute;inset:0;border:0;background:transparent}
.modal-backdrop>.modal{position:relative}
</style>
