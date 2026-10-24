<!-- Engine shop (engineShop), house style. Faint caption + title + hint with gold account
     and brand facts on the right; near-black panels and .sheet tables with caption column heads; status
     as short pills; neutral row buttons with one orange per view; slim scaleX bars; quiet dev folds. -->
<template>
  <div ref="rootRef" class="engine-shop rls-house">
    <header class="shop-header">
      <div class="shop-heading">
        <span class="caption">{{ shop.businessName || data?.businessName || 'Engine shop' }}</span>
        <h2 class="page-title">{{ title }}</h2>
        <p class="hint page-hint">{{ subtitle }}</p>
      </div>
      <div class="facts head-facts">
        <div class="fact money"><span class="fact-key">Business account</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(shop.balance) }}</span></div>
        <div class="fact"><span class="fact-key">Brand</span><span class="fact-value">{{ number(shop.brandPopularity, 1) }}<small>/100</small></span></div>
      </div>
    </header>

    <p v-if="message" class="notice" :class="messageError ? 'bad' : 'ok'" role="status">{{ message }}</p>

    <template v-if="view === 'overview'">
      <EngineShopOverview :business-name="shop.businessName || data?.businessName" :supplier-name="shop.supplierName" @manage="switchView('engines')" />
    </template>

    <template v-else-if="view === 'dashboard'">
      <div class="panel summary-panel">
        <div class="facts summary-facts" aria-label="Shop summary">
          <div class="fact"><span class="fact-key">Certified</span><span class="fact-value">{{ shop.blueprints.length }}</span></div>
          <div class="fact"><span class="fact-key">Lines running</span><span class="fact-value">{{ activeLineCount }}<small>/{{ shop.lineCapacity || 1 }}</small></span></div>
          <div class="fact"><span class="fact-key">Warehouse</span><span class="fact-value">{{ shop.warehouseUsed || 0 }}<small>/{{ shop.warehouseCapacity || 0 }}</small></span></div>
          <div class="fact"><span class="fact-key">Finished</span><span class="fact-value">{{ shop.warehousePackages.length }}</span></div>
          <div class="fact"><span class="fact-key">Next sale</span><span class="fact-value">{{ salesCountdown }}</span></div>
        </div>
      </div>

      <section class="panel work-bay">
        <div class="bay-copy">
          <span class="caption">Work bay</span>
          <h3 class="item-title">{{ shop.localizedVehicle?.niceName || 'Bay empty' }}</h3>
          <p v-if="shop.localizedVehicle" class="body-copy">Personal vehicle #{{ shop.localizedVehicle.inventoryId }} is inside the Engine Works service zone.</p>
          <p v-else class="body-copy">Park a personal vehicle in the marked garage bay to unlock service controls.</p>
          <div v-if="(shop.bayVehicles || []).length > 1" class="cluster bay-picker">
            <HouseButton
              v-for="bayVehicle in shop.bayVehicles"
              :key="bayVehicle.inventoryId"
              compact
              :variant="String(bayVehicle.inventoryId) === String(shop.localizedVehicle?.inventoryId) ? 'neutral' : 'quiet'"
              :aria-disabled="busy"
              :data-fk="'selectBayVehicle-' + bayVehicle.inventoryId" @click="perform('selectBayVehicle', bayVehicle.inventoryId)"
            >{{ bayVehicle.niceName }} #{{ bayVehicle.inventoryId }}</HouseButton>
          </div>
        </div>
        <div class="bay-actions">
          <HouseButton variant="primary" :aria-disabled="busy" :data-fk="'openEnginePackages-' + 'action'" @click="perform('openEnginePackages')">Manage Engine Packages</HouseButton>
          <div class="cluster">
            <HouseButton compact :disabled="!shop.localizedVehicle" :data-fk="'openParts-' + 'action'" @click="perform('openParts')">Parts</HouseButton>
            <HouseButton compact :disabled="!shop.localizedVehicle" :data-fk="'openTuning-' + 'action'" @click="perform('openTuning')">Tuning</HouseButton>
            <HouseButton compact :disabled="!shop.localizedVehicle" :data-fk="'openRepair-' + 'action'" @click="perform('openRepair')">Repair</HouseButton>
          </div>
        </div>
      </section>

      <section class="block">
        <div class="block-head">
          <span class="caption">Operations</span>
          <span class="hint">Sales timers run during active career play</span>
        </div>
        <div class="sheet lines">
          <div class="line op-line"><span class="op-key">Certification</span><strong class="num">{{ pendingCertificationCount }} active</strong><span class="op-note">Each test takes 10 minutes of active play.</span></div>
          <div class="line op-line"><span class="op-key">Materials</span><strong class="num" :class="{ attention: waitingReservationCount > 0 }">{{ waitingReservationCount }} awaiting pickup</strong><span class="op-note">Collect prepaid loads at {{ shop.supplierName || 'the supplier' }}.</span></div>
          <div class="line op-line"><span class="op-key">Sales floor</span><strong class="num" :class="{ attention: shop.salesState !== 'selling' }">{{ salesCountdown }}</strong><span class="op-note"><template v-if="shop.salesState === 'selling'">{{ shop.salesCurrentName }} will sell for <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(shop.salesCurrentPrice) }}.</template><template v-else>{{ salesOperationCopy }}</template></span></div>
        </div>
      </section>

      <details v-if="shop.devTools" class="dev-tools">
        <summary bng-nav-item>Developer verification</summary>
        <div class="cluster dev-actions">
          <HouseButton compact variant="quiet" @click="debugTests">Run invariant tests</HouseButton>
          <HouseButton compact variant="quiet" :data-fk="'debugAdvanceCalendar-' + 'action'" @click="perform('debugAdvanceCalendar', 60)">Advance 60m</HouseButton>
          <HouseButton compact variant="quiet" :data-fk="'debugAdvanceCalendar-' + 'action'" @click="perform('debugAdvanceCalendar', 480)">Advance 8h</HouseButton>
          <HouseButton compact variant="quiet" :data-fk="'debugAdvanceCalendar-' + 'action'" @click="perform('debugAdvanceCalendar', 1440)">Advance 1 day</HouseButton>
        </div>
      </details>
    </template>

    <template v-else-if="view === 'engines'">
      <section class="panel intro">
        <div class="intro-copy">
          <h3 class="item-title">Personal engine packages</h3>
          <p class="body-copy">Store an engine, then certify its exact parts and tune to create a production blueprint.</p>
          <p class="hint">Changing the package after certification invalidates that recipe.</p>
        </div>
        <HouseButton variant="primary" :aria-disabled="busy" :data-fk="'openEnginePackages-' + 'action'" @click="perform('openEnginePackages')">Open Package Manager</HouseButton>
      </section>

      <div v-if="shop.packages.length" class="package-list">
        <article v-for="pkg in shop.packages" :key="pkg.id" class="panel package-row">
          <div class="pkg-photo">
            <img v-if="thumbnailUrl(pkg)" :src="thumbnailUrl(pkg)" alt="" @error="thumbnailFailed[packageImageKey(pkg)] = true" />
            <BngIcon v-else class="pkg-photo-glyph" :type="icons.engine" />
          </div>
          <div class="package-copy">
            <span class="pill" :class="certTone(pkg)">{{ certificationLabel(pkg) }}</span>
            <h3 class="item-title">{{ pkg.name }}</h3>
            <p class="sub">{{ pkg.engineName }}</p>
            <div class="meta-row">
              <span>{{ packageStatus(pkg) }}</span>
              <span>Fresh value <b class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(pkg.freshValue) }}</b></span>
              <span>Test fee <b class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(pkg.certificationFee) }}</b></span>
            </div>
            <p v-if="pkg.certification?.status === 'pending'" class="status-note">Ready in {{ duration(secondsUntil(pkg.certification.expiresAtSeconds, nowSeconds)) }} of active play.</p>
            <p v-else-if="pkg.certification?.status === 'failed'" class="status-note bad">{{ pkg.certified ? 'Latest test failed its declared torque or RPM threshold; this recipe already has a valid blueprint.' : 'Failed its declared torque or RPM threshold. Modify the recipe before testing again.' }}</p>
            <p v-else-if="pkg.certification?.status === 'unknown'" class="status-note warn">{{ pkg.certification.reason || 'Rating unknown' }}</p>
            <p v-else-if="pkg.certification?.status === 'passed'" class="status-note">Certified at {{ certifiedOutput(pkg) }}.</p>
          </div>
          <div class="row-actions">
            <HouseButton v-if="!pkg.certified && pkg.certification?.status !== 'pending'" :aria-disabled="busy" :disabled="!pkg.stored || pkg.certification?.status === 'pending' || pkg.certified" :data-fk="'startCertification-' + pkg.id" @click="perform('startCertification', pkg.id)">Certify for <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(pkg.certificationFee) }}</HouseButton>
            <details v-if="shop.devTools && pkg.certification?.status === 'pending'" class="dev-tools row-dev">
              <summary bng-nav-item>Dev result</summary>
              <div class="cluster dev-actions">
                <HouseButton compact variant="quiet" :data-fk="'debugForceCertification-' + pkg.id" @click="perform('debugForceCertification', pkg.id, true)">Pass</HouseButton>
                <HouseButton compact variant="quiet" :data-fk="'debugForceCertification-' + pkg.id" @click="perform('debugForceCertification', pkg.id, false)">Fail</HouseButton>
              </div>
            </details>
          </div>
        </article>
      </div>
      <section v-else class="panel empty">
        <h3>No engine packages</h3>
        <p>Park a personal combustion vehicle in the work bay, then capture its installed engine in the Package Manager.</p>
        <HouseButton :aria-disabled="busy" :data-fk="'openEnginePackages-' + 'action'" @click="perform('openEnginePackages')">Open Package Manager</HouseButton>
      </section>
    </template>

    <template v-else-if="view === 'myParts'">
      <section class="panel intro">
        <div class="intro-copy">
          <h3 class="item-title">Player part inventory</h3>
          <p class="body-copy">Browse and manage all parts you own, independent of the vehicle in the bay.</p>
          <p class="hint">Use this when building packages or moving parts between cars.</p>
        </div>
        <HouseButton variant="primary" :aria-disabled="busy" :data-fk="'openMyParts-' + 'action'" @click="perform('openMyParts')">Open My Parts</HouseButton>
      </section>
    </template>

    <template v-else-if="view === 'production'">
      <div class="production-list">
        <article v-for="line in shop.lines" :key="line.id" class="panel production-line" :class="{ locked: line.id > shop.lineCapacity }">
          <header class="line-header">
            <div class="line-identity">
              <h3 class="item-title">Line {{ line.id }}</h3>
              <span class="pill" :class="lineTone(line)">{{ lineStatus(line) }}</span>
              <HouseButton v-if="line.id <= shop.lineCapacity && !line.broken && line.blueprintId && rawFor(line.blueprintId) < 1" class="material-shortcut" compact variant="quiet" @click="switchView('warehouse')">Order Material</HouseButton>
            </div>
            <div class="line-command">
              <HouseButton v-if="line.id > shop.lineCapacity" disabled>Locked</HouseButton>
              <HouseButton v-else-if="line.broken" class="warn-btn" :data-fk="'overhaulLine-' + line.id" @click="perform('overhaulLine', line.id)">Overhaul Line</HouseButton>
              <HouseButton v-else-if="!line.running" :variant="String(primaryStartLineId) === String(line.id) ? 'primary' : 'neutral'" :disabled="!line.blueprintId" :data-fk="'setLineRunning-' + line.id" @click="perform('setLineRunning', line.id, true)">Start Line</HouseButton>
              <HouseButton v-else :data-fk="'setLineRunning-' + line.id" @click="perform('setLineRunning', line.id, false)">Stop Line</HouseButton>
            </div>
          </header>
          <p v-if="line.id > shop.lineCapacity" class="hint locked-note">Purchase Production Line {{ line.id }} from Upgrades to commission this bay.</p>
          <div class="line-flow">
            <div class="stage blueprint-stage">
              <span class="caption">Blueprint</span>
              <div class="stage-row">
                <HouseMenu :model-value="String(lineSelection[line.id] ?? '')" :items="productionItems" placeholder="Select a certified blueprint" :disabled="line.id > shop.lineCapacity || line.attemptStarted" @update:model-value="value => lineSelection[line.id] = value" />
                <HouseButton compact :disabled="line.id > shop.lineCapacity || !lineSelection[line.id] || String(lineSelection[line.id]) === String(line.blueprintId)" :data-fk="'assignLineBlueprint-' + line.id" @click="perform('assignLineBlueprint', line.id, lineSelection[line.id])">Assign blueprint</HouseButton>
              </div>
            </div>
            <div class="stage cycle-stage">
              <span class="caption">Cycle</span>
              <div class="cycle-readout"><strong>{{ line.running ? 'Running' : 'Stopped' }}</strong><span class="num">{{ duration(lineElapsedSeconds(line)) }} / {{ duration(line.cycleSeconds) }}</span></div>
              <div class="track"><span :style="fill(lineProgress(line))" /></div>
            </div>
            <div class="stage output-stage">
              <span class="caption">Material / output</span>
              <strong class="num flow-count">{{ rawFor(line.blueprintId) }} raw <i>→</i> {{ finishedFor(line.blueprintId) }} finished</strong>
              <span class="hint">{{ shop.warehouseFree }} shared warehouse spots free</span>
            </div>
          </div>
          <details class="line-settings">
            <summary bng-nav-item>
              <span>Line upgrades</span>
              <span class="upgrade-summary"><span v-for="row in lineUpgradeRows" :key="row.id" class="pill">{{ row.name }} {{ line.upgrades?.[row.id] || 0 }}</span></span>
            </summary>
            <div class="lines upgrade-lines">
              <div v-for="upgrade in lineUpgradeRows" :key="upgrade.id" class="line line-upgrade">
                <div class="line-upgrade-copy"><strong>{{ upgrade.name }}</strong><span class="hint">{{ lineUpgradeBonus(line, upgrade.id) }}</span></div>
                <span class="num level">Level {{ line.upgrades?.[upgrade.id] || 0 }} / 3</span>
                <HouseButton compact :disabled="line.id > shop.lineCapacity || (line.upgrades?.[upgrade.id] || 0) >= 3" :data-fk="'purchaseLineUpgrade-' + line.id" @click="perform('purchaseLineUpgrade', line.id, upgrade.id)"><template v-if="lineUpgradeCost(line, upgrade) == null">Max level</template><template v-else>Upgrade for <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(lineUpgradeCost(line, upgrade)) }}</template></HouseButton>
              </div>
            </div>
          </details>
          <details v-if="shop.devTools" class="dev-tools line-dev">
            <summary bng-nav-item>Developer controls</summary>
            <div class="cluster dev-actions">
              <HouseButton compact variant="quiet" :disabled="!line.blueprintId || rawFor(line.blueprintId) < 1" :data-fk="'debugForceProduction-' + line.id" @click="perform('debugForceProduction', line.id, true, false)">Force success</HouseButton>
              <HouseButton compact variant="quiet" :disabled="!line.blueprintId || rawFor(line.blueprintId) < 1" :data-fk="'debugForceProduction-' + line.id" @click="perform('debugForceProduction', line.id, false, true)">Force failure + breakdown</HouseButton>
            </div>
          </details>
        </article>
      </div>
    </template>

    <template v-else-if="view === 'warehouse'">
      <section class="panel warehouse-gauge">
        <div class="gauge-copy">
          <span class="caption">Shared warehouse</span>
          <strong class="item-title num">{{ shop.warehouseUsed || 0 }} / {{ shop.warehouseCapacity || 0 }} occupied</strong>
          <span class="hint">{{ shop.warehouseFree || 0 }} spaces available. Raw loads and finished engines share this capacity.</span>
        </div>
        <div class="track gauge-track"><span :style="fill(warehousePercent)" /></div>
        <HouseButton :disabled="!nextWarehouseUpgrade" @click="nextWarehouseUpgrade && perform('purchaseUpgrade', nextWarehouseUpgrade.id)"><template v-if="nextWarehouseUpgrade">Expand for <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(nextWarehouseUpgrade.cost) }}</template><template v-else>Fully Expanded</template></HouseButton>
      </section>

      <section class="block">
        <div class="block-head"><span class="caption">Order raw materials</span><span class="hint">Orders are prepaid and collected manually at {{ shop.supplierName || 'the supplier' }}.</span></div>
        <div v-if="shop.blueprints.length" class="sheet">
          <div class="line col-head material-grid"><span>Blueprint</span><span>On hand</span><span>Per load</span><span>Quantity</span><span></span></div>
          <div class="lines">
            <div v-for="bp in shop.blueprints" :key="bp.id" class="line material-grid" bng-nav-item tabindex="0" aria-label="Order quantity" :data-fk="`quantity-${bp.id}`" v-bng-on-ui-nav-focus.repeat="dir => stepQuantity(bp.id, dir)">
              <strong class="row-name">{{ bp.name }}</strong>
              <span class="num">{{ bp.rawCount }} raw</span>
              <span class="num money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(bp.freshValue) }}</span>
              <input v-model.number="rawQuantity[bp.id]" class="field qty-field" type="number" min="1" aria-label="Order quantity" bng-no-nav="true" v-bng-text-input @focus="onInputFocus" @blur="onInputBlur" @keydown.stop @keyup.stop @keypress.stop />
              <div class="row-end">
                <HouseButton compact :disabled="shop.warehouseFree < 1" :data-fk="'orderRawMaterials-' + bp.id" @click="perform('orderRawMaterials', bp.id, rawQuantity[bp.id] || 1)">Place Order</HouseButton>
                <details v-if="shop.devTools" class="dev-tools row-dev">
                  <summary bng-nav-item>Dev</summary>
                  <HouseButton compact variant="quiet" :disabled="shop.warehouseFree < 1" :data-fk="'debugAddRaw-' + bp.id" @click="perform('debugAddRaw', bp.id, 1)">Add 1 raw</HouseButton>
                </details>
              </div>
            </div>
          </div>
        </div>
        <p v-else class="panel empty-line">Certify an engine package before ordering recipe-specific material.</p>
      </section>

      <section class="block">
        <div class="block-head"><span class="caption">Paid orders</span><span v-if="shop.reservations.length" class="pill">{{ shop.reservations.length }} open</span></div>
        <p v-if="!shop.reservations.length" class="panel empty-line">No paid loads are waiting or in transit.</p>
        <div v-else class="sheet">
          <div class="line col-head reservation-grid"><span>Order</span><span>Blueprint</span><span>Status</span><span>Paid</span></div>
          <div class="lines">
            <div v-for="reservation in shop.reservations" :key="reservation.id" class="line reservation-grid">
              <span class="num serial">#{{ reservation.id }}</span>
              <strong class="row-name">{{ blueprintName(reservation.blueprintId) }}</strong>
              <span class="pill" :class="reservation.status === 'available' ? 'warn' : ''">{{ reservationLabel(reservation.status) }}</span>
              <span class="num money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(reservation.paidCost) }}</span>
            </div>
          </div>
        </div>
      </section>

      <section class="block">
        <div class="block-head"><span class="caption">Finished engines</span><span v-if="shop.warehousePackages.length" class="pill">{{ shop.warehousePackages.length }} stored</span></div>
        <p v-if="!shop.warehousePackages.length" class="panel empty-line">No finished engines are stored.</p>
        <div v-else class="sheet lines">
          <div v-for="pkg in shop.warehousePackages" :key="pkg.id" class="line finished-grid">
            <span class="num serial">#{{ pkg.id }}</span>
            <div class="finished-copy"><strong class="row-name">{{ pkg.name }}</strong><span v-if="pkg.engineName" class="hint">{{ pkg.engineName }}</span></div>
            <div class="row-end">
              <HouseButton compact :disabled="!shop.localizedVehicle" :data-fk="'installWarehousePackage-' + pkg.id" @click="perform('installWarehousePackage', pkg.id)">Install in Bay Vehicle</HouseButton>
              <HouseButton compact variant="quiet-danger" :data-fk="'junkWarehousePackage-' + pkg.id" @click="perform('junkWarehousePackage', pkg.id)">Junk</HouseButton>
            </div>
          </div>
        </div>
      </section>
    </template>

    <template v-else-if="view === 'sales'">
      <section class="panel sales-queue">
        <div class="queue-head">
          <div class="queue-copy">
            <span class="caption">Sales queue</span>
            <h3 class="item-title">{{ shop.salesState === 'selling' ? shop.salesCurrentName : 'Sales paused' }}</h3>
            <p class="body-copy">{{ salesQueueCopy }}</p>
          </div>
          <div class="queue-timer">
            <template v-if="shop.salesState === 'selling'">
              <span class="pill accent num">Next sale {{ salesCountdown }}</span>
              <span class="payout"><b class="money num"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(shop.salesCurrentPrice) }}</b> payout</span>
            </template>
            <span v-else class="pill" :class="shop.salesState === 'waitingForStock' ? 'warn' : ''">{{ shop.salesState === 'waitingForStock' ? 'Out of stock' : 'Not listed' }}</span>
          </div>
        </div>
        <div class="track"><span :style="fill(salesProgressPercent)" /></div>
        <span v-if="shop.salesState === 'selling'" class="hint">One physical engine sells when this timer reaches zero.</span>
        <span v-else class="hint">The timer starts as soon as a listed engine is in warehouse stock.</span>
      </section>

      <section v-if="shop.blueprints.length" class="sales-list">
        <article v-for="bp in shop.blueprints" :key="bp.id" class="panel sale-row">
          <div class="sale-product">
            <span class="pill" :class="String(shop.salesCurrentBlueprintId) === String(bp.id) ? 'accent' : (bp.listed ? '' : 'soft')">{{ String(shop.salesCurrentBlueprintId) === String(bp.id) ? 'Selling next' : (bp.listed ? 'In queue' : 'Unlisted') }}</span>
            <h3 class="item-title">{{ bp.name }}</h3>
            <p v-if="bp.certification?.status === 'failed' || bp.certification?.status === 'unknown'" class="status-note bad">{{ bp.certification.reason || 'Certification no longer passes the installed engine rating.' }} Listing and production are paused; your blueprint and stock are retained.</p>
            <div class="meta-row"><span class="num">{{ bp.finishedCount }} finished</span><span><b class="money num"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(bp.landedCost) }}</b> landed cost</span></div>
            <span class="profit">Profit at asking price <b class="num" :class="(bp.price || 0) - (bp.landedCost || 0) < 0 ? 'negative' : 'money'">{{ moneySign((bp.price || 0) - (bp.landedCost || 0)) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ absMoney((bp.price || 0) - (bp.landedCost || 0)) }}</b></span>
          </div>
          <div class="sheet lines sale-terms">
            <div class="line"><span class="line-key">Supported price</span><strong class="num money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(bp.suggestedPrice) }}</strong></div>
            <div class="line"><span class="line-key">Maximum price</span><strong class="num money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(bp.maxSalePrice) }}</strong></div>
            <div class="line"><span class="line-key">Sale interval</span><strong class="num">{{ duration(bp.saleCycleSeconds) }}</strong></div>
            <div class="line awareness">
              <div class="awareness-head"><span class="line-key">Awareness</span><strong class="num">{{ number(bp.awareness, 1) }} / 100</strong></div>
              <div class="track"><span :style="fill(bp.awareness)" /></div>
              <span class="hint">Brand and awareness make room for higher prices before the 15-minute timer limit. Discounts can sell faster.</span>
            </div>
          </div>
          <div class="price-control">
            <label class="field-block" bng-nav-item tabindex="0" aria-label="Sale price" :data-fk="`price-field-${bp.id}`" v-bng-on-ui-nav-focus.repeat="dir => stepPrice(bp, dir)"><span class="caption">Sale price</span><input v-model.number="salePrice[bp.id]" class="field price-field" bng-no-nav="true" type="number" min="1" :max="bp.maxSalePrice" v-bng-text-input @focus="onInputFocus" @blur="onInputBlur" @input="markSalePriceDirty(bp.id)" @keydown.stop @keyup.stop @keypress.stop /></label>
            <div class="cluster">
              <HouseButton compact @click="updateBlueprintPrice(bp)">Update Price</HouseButton>
              <HouseButton compact :variant="bp.listed ? 'quiet' : 'neutral'" :data-fk="'setBlueprintListed-' + bp.id" @click="perform('setBlueprintListed', bp.id, !bp.listed)">{{ bp.listed ? 'Stop Selling' : 'List Engine' }}</HouseButton>
            </div>
          </div>
        </article>
      </section>
      <section v-else class="panel empty"><h3>No certified engines</h3><p>Certify an engine package to create a saleable production blueprint.</p></section>

      <section class="block">
        <div class="block-head"><span class="caption">Recent sales</span></div>
        <p v-if="!recentSales.length" class="panel empty-line">No engines have sold yet.</p>
        <div v-else class="sheet">
          <div class="line col-head history-grid"><span>Time</span><span>Engine</span><span>Qty</span><span>Payout</span><span>Interval</span></div>
          <div class="lines">
            <div v-for="(row, index) in recentSales" :key="index" class="line history-grid">
              <span class="num faint">{{ saleTime(row) }}</span>
              <strong class="row-name">{{ row.name }}</strong>
              <span class="num">{{ row.sold || 0 }}</span>
              <span class="num money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money((row.price || 0) * (row.sold || 0)) }}</span>
              <span class="num faint">{{ row.saleCycleSeconds ? duration(row.saleCycleSeconds) : 'Legacy daily sale' }}</span>
            </div>
          </div>
        </div>
      </section>
    </template>

    <template v-else-if="view === 'upgrades'">
      <section class="sheet">
        <div class="line col-head upgrade-grid"><span>Facility upgrade</span><span>Effect</span><span>Status</span><span></span></div>
        <div class="lines">
          <div v-for="upgrade in shop.upgrades" :key="upgrade.id" class="line upgrade-grid">
            <strong class="row-name">{{ upgrade.name }}</strong>
            <div class="upgrade-effect"><span>{{ upgrade.effect }}</span><span v-if="upgrade.requires" class="hint">Requires {{ upgradeName(upgrade.requires) }}</span></div>
            <span v-if="upgrade.owned" class="pill ok">Installed</span>
            <strong v-else class="num money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(upgrade.cost) }}</strong>
            <div class="row-end">
              <span v-if="upgrade.owned" class="pill">Owned</span>
              <HouseButton v-else compact :disabled="upgrade.owned || (upgrade.requires && !upgradeOwned(upgrade.requires))" :data-fk="'purchaseUpgrade-' + upgrade.id" @click="perform('purchaseUpgrade', upgrade.id)">Purchase</HouseButton>
            </div>
          </div>
        </div>
      </section>
    </template>

    <template v-else-if="view === 'finances'">
      <section class="panel finance-summary">
        <span class="caption">Engine Works account</span>
        <strong class="balance num" :class="{ negative: (Number(shop.balance) || 0) < 0 }">{{ moneySign(shop.balance) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ absMoney(shop.balance) }}</strong>
        <p class="body-copy">Sales and production costs flow through this business account.</p>
      </section>
      <section class="panel business-sale">
        <div class="sale-copy">
          <span class="caption">Ownership</span>
          <h3 class="item-title">Sell Engine Works</h3>
          <p class="body-copy">Review the settlement before selling. Finished engines, paid material, upgrades, and the business account are included. Pending certifications and deliveries end with the sale.</p>
        </div>
        <HouseButton ref="reviewSaleButtonRef" :disabled="saleLoading || saleSubmitting" @click="requestSaleQuote">{{ saleLoading ? 'Calculating...' : 'Review Sale' }}</HouseButton>
      </section>
    </template>

    <Teleport to="body">
      <div v-if="saleQuote" class="rls-house engine-sale-overlay" @click.self="closeSaleQuote">
        <section ref="saleDialogRef" class="modal engine-sale-dialog" v-bng-scoped-nav="saleModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="onSaleBack" role="dialog" aria-modal="true" aria-labelledby="engine-sale-title">
          <span class="caption">Sale settlement</span>
          <h2 id="engine-sale-title" class="page-title">Sell {{ saleQuote.businessName || 'Engine Works' }}</h2>
          <p>Sale closes the account and removes business stock, paid material, active deliveries, certifications, and shop progress. Personal engines remain yours.</p>
          <p v-if="message" class="notice bad" role="status">{{ message }}</p>
          <dl class="sheet lines settlement-rows">
            <div class="line"><dt>Base resale</dt><dd><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.baseResaleValue) }}</dd></div>
            <div class="line"><dt>Stock and upgrades</dt><dd><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.assetLiquidationValue) }}</dd></div>
            <div v-if="saleQuote.upgradeLiquidationValue" class="line"><dt>Other upgrades</dt><dd><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.upgradeLiquidationValue) }}</dd></div>
            <div class="line"><dt>Account balance</dt><dd>{{ moneySign(saleQuote.accountBalance) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ absMoney(saleQuote.accountBalance) }}</dd></div>
            <div v-if="saleQuote.loanPayoffAmount" class="line"><dt>Loan payoff</dt><dd>-<BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.loanPayoffAmount) }}</dd></div>
            <div v-if="saleQuote.convertedDebt" class="line"><dt>Debt moved to personal account</dt><dd><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.convertedDebt) }}</dd></div>
            <div class="line settlement-total"><dt>Net payout</dt><dd><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.netPayout) }}</dd></div>
          </dl>
          <div class="sale-dialog-actions">
            <HouseButton variant="quiet" bng-scoped-nav-autofocus :disabled="saleSubmitting" @click="closeSaleQuote">Cancel</HouseButton>
            <HouseButton variant="danger" :disabled="saleSubmitting" @click="confirmSale">{{ saleSubmitting ? 'Selling...' : 'Confirm Sale' }}</HouseButton>
          </div>
        </section>
      </div>
    </Teleport>
  </div>
</template>

<script setup>
import { useScopedNav } from "@/services/scopedNav/api"
import { safeLua } from "../../../../utils/safeLua.js"

import { useActionFocus } from "../../../../composables/useActionFocus.js"
import { useNowSeconds } from "../../../../composables/useNowSeconds.js"
import { assignChanged, secondsUntil } from "../../../../stores/businessComputer/businessTime.js"
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { vBngTextInput, vBngOnUiNavFocus, vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { bcModalScope, vBcModalFocus } from '../../bcModalNav'
import { HouseButton, HouseMenu } from '../../../house/index.js'
import { BngIcon, icons } from '@/common/components/base'
import { useBusinessComputerStore } from "../../../../stores/businessComputerStore"
import EngineShopOverview from './EngineShopOverview.vue'

const props = defineProps({ data: Object })
const { units } = useBridge()
const nowSeconds = useNowSeconds()
let unmounted = false
const computerStore = useBusinessComputerStore()
// sale settlement dialog: own controller scope, opens on Cancel, B cancels unless the sale is being submitted
const saleModalScope = bcModalScope('engine-shop-sale')
function onSaleBack() { closeSaleQuote(); return false }
const shop = reactive({ bayVehicles: [], packages: [], blueprints: [], lines: [], warehousePackages: [], reservations: [], upgrades: [], salesHistory: [], lineUpgrades: {}, rawStock: {}, salesState: 'notListed' })
const rootRef = ref(null)
const { busy, run } = useActionFocus(rootRef)
const message = ref(''), messageError = ref(false)
function stepQuantity(id, direction) { rawQuantity[id] = Math.max(1, Math.min(Number(shop.warehouseFree) || 1, (Number(rawQuantity[id]) || 1) + direction)) }
function stepPrice(bp, direction) {
  salePrice[bp.id] = Math.max(1, Math.min(Number(bp.maxSalePrice) || 1, (Number(salePrice[bp.id]) || 1) + direction))
  markSalePriceDirty(bp.id)
}
async function switchView(view) {
  await computerStore.switchView(view)
  await nextTick()
  const nav = useScopedNav()
  nav.requestScopeFocus('business-computer-content')
}
const saleLoading = ref(false), saleSubmitting = ref(false), saleQuote = ref(null)
const saleDialogRef = ref(null), reviewSaleButtonRef = ref(null)
const lineSelection = reactive({}), rawQuantity = reactive({}), salePrice = reactive({}), salePriceDirty = reactive({})
const thumbnailFailed = reactive({})
let poll, inputFocused = false
let saleModalPushedEl = null
let saleKeyListenerActive = false

const SETTLEMENT_COMPARE_KEYS = [
  'baseResaleValue', 'assetLiquidationValue', 'upgradeLiquidationValue',
  'accountBalance', 'loanPayoffAmount', 'convertedDebt', 'netPayout',
  'grossProceeds', 'businessLoanPrincipal'
]
function settlementChanged(a, b) {
  if (String(a?.businessType || '') !== String(b?.businessType || '')) return true
  if (String(a?.businessId || '') !== String(b?.businessId || '')) return true
  if (String(a?.accountId || '') !== String(b?.accountId || '')) return true
  return SETTLEMENT_COMPARE_KEYS.some(key => Number(a?.[key] || 0) !== Number(b?.[key] || 0))
}

function resolveFocusableRoot(refValue) {
  if (!refValue) return null
  const root = refValue.$el || refValue
  if (!root) return null
  if (root.matches?.('button, summary, [bng-nav-item]')) return root
  return root.querySelector?.('button, summary, [bng-nav-item]') || root
}

function getSaleDialogFocusables() {
  const dialog = saleDialogRef.value
  if (!dialog) return []
  return Array.from(dialog.querySelectorAll('button:not([disabled]), summary, [bng-nav-item]:not([disabled]):not([bng-no-nav="true"])'))
    .filter(el => {
      const style = window.getComputedStyle(el)
      return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null
    })
}

function focusSaleDialogFirst() {
  const focusables = getSaleDialogFocusables()
  const target = focusables[0]
  if (target?.focus) target.focus()
}

function focusReviewSaleButton() {
  const target = resolveFocusableRoot(reviewSaleButtonRef.value)
  if (target?.focus) target.focus()
}

function onSaleDialogKeydown(e) {
  if (!saleQuote.value) return
  if (e.key !== 'Tab') return
  const focusables = getSaleDialogFocusables()
  if (focusables.length === 0) return
  const first = focusables[0]
  const last = focusables[focusables.length - 1]
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault()
    last.focus()
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault()
    first.focus()
  } else if (!focusables.includes(document.activeElement)) {
    e.preventDefault()
    ;(e.shiftKey ? last : first).focus()
  }
}

function enableSaleKeyListener() {
  if (saleKeyListenerActive) return
  document.addEventListener('keydown', onSaleDialogKeydown, true)
  saleKeyListenerActive = true
}

function disableSaleKeyListener() {
  if (!saleKeyListenerActive) return
  document.removeEventListener('keydown', onSaleDialogKeydown, true)
  saleKeyListenerActive = false
}

const view = computed(() => props.data?.view || 'dashboard')
const titles = { dashboard: 'Shop Floor', engines: 'Engine Packages', myParts: 'My Parts', production: 'Production Floor', warehouse: 'Warehouse', sales: 'Sales Desk', upgrades: 'Facility Upgrades', finances: 'Finances', overview: 'Business Overview' }
const subtitles = { dashboard: 'Run the bay and keep the business moving.', engines: 'Certify personal engines into repeatable production recipes.', myParts: 'Open your owned parts inventory from the Engine Works computer.', production: 'Assign blueprints, feed material, and control each line.', warehouse: 'Order material and manage finished engine stock.', sales: 'Price finished engines and track the next automatic sale.', upgrades: 'Expand storage and commission additional production lines.', finances: 'Review the business account and ownership settlement.', overview: 'Review the operating loop, sales model, and ways to grow demand.' }
const title = computed(() => titles[view.value]); const subtitle = computed(() => subtitles[view.value])
// numbers only: the template puts the game currency glyph in front, with any sign before the glyph
const money = value => Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
const moneySign = value => Math.round(Number(value) || 0) < 0 ? '-' : ''
const absMoney = value => Math.abs(Math.round(Number(value) || 0)).toLocaleString()
const number = (value, digits = 0) => (Number(value) || 0).toFixed(digits)
const packageImageKey = pkg => pkg?.thumbnail ? `${pkg.thumbnail}?${pkg.dirtyDate || 0}` : null
const thumbnailUrl = pkg => {
  const url = packageImageKey(pkg)
  return url && !thumbnailFailed[url] ? url : null
}
const certifiedOutput = pkg => { const mechanicalHp = Number(pkg?.certification?.peakHorsepower) || 0; return `${units.buildString('power', mechanicalHp / 0.98632, 0)} and ${units.buildString('torque', Number(pkg?.certification?.peakTorque) || 0, 0)}` }
const activeLineCount = computed(() => shop.lines.filter(line => line.running).length)
const pendingCertificationCount = computed(() => shop.packages.filter(pkg => pkg.certification?.status === 'pending').length)
const waitingReservationCount = computed(() => shop.reservations.filter(row => row.status === 'available').length)
const listedCount = computed(() => shop.blueprints.filter(bp => bp.listed).length)
const recentSales = computed(() => [...shop.salesHistory].reverse().slice(0, 12))
const salesCountdown = computed(() => shop.salesState === 'selling' ? duration(secondsUntil(shop.salesCycleExpiresAtSeconds, nowSeconds.value)) : shop.salesState === 'waitingForStock' ? 'Out of stock' : 'Not listed')
const salesProgressPercent = computed(() => shop.salesState === 'selling' ? Math.max(0, Math.min(100, (Math.max(0, (Number(shop.salesCycleSeconds) || 0) - secondsUntil(shop.salesCycleExpiresAtSeconds, nowSeconds.value))) / Math.max(1, Number(shop.salesCycleSeconds) || 1) * 100)) : 0)
// the 'selling' line is in the template (it carries the currency glyph)
const salesOperationCopy = computed(() => shop.salesState === 'waitingForStock' ? `${listedCount.value} listed engine${listedCount.value === 1 ? '' : 's'} need finished stock.` : 'List a certified engine to begin automatic sales.')
const salesQueueCopy = computed(() => shop.salesState === 'selling' ? 'The queue sells one stocked engine at a time during active career play.' : shop.salesState === 'waitingForStock' ? 'Your listings are active, but none have a finished engine in the warehouse.' : 'Choose a price and list a certified engine to start the timer.')
const lineUpgradeRows = computed(() => Object.values(shop.lineUpgrades || {}))
const nextWarehouseUpgrade = computed(() => shop.upgrades.find(row => (row.id === 'warehouse1' || row.id === 'warehouse2') && !row.owned && (!row.requires || upgradeOwned(row.requires))))
const warehousePercent = computed(() => Math.max(0, Math.min(100, (Number(shop.warehouseUsed) || 0) / Math.max(1, Number(shop.warehouseCapacity) || 1) * 100)))
const productionItems = computed(() => {
  const rows = [{ label: 'Select a certified blueprint', value: '' }], seen = new Set()
  for (const pkg of shop.packages) {
    if (pkg.certified && pkg.blueprintId && !seen.has(String(pkg.blueprintId))) { rows.push({ label: `✓ ${pkg.name} (certified)`, value: String(pkg.blueprintId) }); seen.add(String(pkg.blueprintId)) }
    else if (!pkg.certified) rows.push({ label: `○ ${pkg.name} (not certified)`, value: `package:${pkg.id}`, disabled: true })
  }
  for (const bp of shop.blueprints) if (!seen.has(String(bp.id))) rows.push({ label: `✓ ${bp.name} (certified blueprint)`, value: String(bp.id) })
  return rows
})

function markSalePriceDirty(id) {
  if (id === undefined || id === null) return
  salePriceDirty[id] = true
}
function clearSalePriceDirty(id) {
  if (id === undefined || id === null) return
  delete salePriceDirty[id]
}

function hydrate(result) {
  for (const key of ['bayVehicles', 'packages', 'blueprints', 'lines', 'warehousePackages', 'reservations', 'upgrades', 'salesHistory']) result[key] = Array.isArray(result[key]) ? result[key] : Object.values(result[key] || {})
  const receivedAtSeconds = Math.floor(Date.now() / 1000)
  result.packages = result.packages.map(pkg => pkg.certification?.status === 'pending'
    ? { ...pkg, certification: { ...pkg.certification, expiresAtSeconds: receivedAtSeconds + Math.max(0, Number(pkg.certification.remainingSeconds) || 0) } }
    : pkg)
  result.salesCycleExpiresAtSeconds = receivedAtSeconds + Math.max(0, Number(result.salesCycleRemainingSeconds) || 0)
  result.lines = result.lines.map(line => line.running
    ? { ...line, startedAtSeconds: receivedAtSeconds - (Number(line.progressSeconds) || 0) } : line)
  assignChanged(shop, result)
  for (const line of shop.lines) if (lineSelection[line.id] === undefined) lineSelection[line.id] = line.blueprintId || ''
  for (const bp of shop.blueprints) {
    if (rawQuantity[bp.id] === undefined) rawQuantity[bp.id] = 1
    if (salePriceDirty[bp.id]) {
      if (Number(salePrice[bp.id]) === Number(bp.price)) clearSalePriceDirty(bp.id)
      else continue
    }
    salePrice[bp.id] = bp.price
  }
}
let refreshInFlight = false
let refreshQueued = false
async function refresh(force = false) {
  if (unmounted) return
  if (refreshInFlight) { refreshQueued ||= force === true; return }
  refreshInFlight = true
  const businessId = props.data?.businessId
  try {
    const result = await lua.overhaul_career_business_computer.getBusinessComputerUIData('engineShop', businessId)
    if (!unmounted && result && typeof result === 'object' && businessId === props.data?.businessId) hydrate(result)
  } finally {
    refreshInFlight = false
    if (refreshQueued) { refreshQueued = false; void refresh() }
  }
}
// Non-finite numbers serialize as empty Lua arguments.
function updateBlueprintPrice(bp) {
  const price = Number(salePrice[bp.id])
  if (!Number.isFinite(price)) { messageError.value = true; message.value = 'Enter a valid price.'; return }
  perform('setBlueprintPrice', bp.id, price)
}
async function perform(method, ...args) {
  if (busy.value) return
  return run(async () => {
  message.value = ''
  try {
    const result = await lua.overhaul_career_business_computer.performEngineShopAction(method, props.data?.businessId, ...args)
    messageError.value = result?.success === false
    message.value = result?.message || ''
    if (method === 'setBlueprintPrice' && result?.success !== false) clearSalePriceDirty(args[0])
    if (!['openEnginePackages', 'openParts', 'openMyParts', 'openTuning', 'openRepair'].includes(method)) await refresh(true)
  }
  catch (error) { messageError.value = true; message.value = String(error) }
  })
}
async function requestSaleQuote() {
  if (saleLoading.value || saleSubmitting.value) return
  saleLoading.value = true; message.value = ''
  try {
    const result = await lua.overhaul_career_business_manager.requestBusinessSaleData('engineShop', props.data?.businessId)
    if (result?.success) saleQuote.value = result
    else { messageError.value = true; message.value = result?.message || 'Sale quote is unavailable.' }
  } catch (error) { messageError.value = true; message.value = String(error) }
  finally { saleLoading.value = false }
}
function closeSaleQuote() { if (!saleSubmitting.value) saleQuote.value = null }
async function confirmSale() {
  if (!saleQuote.value || saleSubmitting.value) return
  saleSubmitting.value = true; message.value = ''
  try {
    const latest = await lua.overhaul_career_business_manager.requestBusinessSaleData('engineShop', props.data?.businessId)
    if (!latest?.success) { messageError.value = true; message.value = latest?.message || 'Sale quote is no longer available.'; saleQuote.value = null; return }
    if (settlementChanged(latest, saleQuote.value)) {
      saleQuote.value = latest; messageError.value = true; message.value = 'The sale amount changed. Review the updated settlement and confirm again.'; return
    }
    const result = await lua.overhaul_career_business_manager.sellBusiness('engineShop', props.data?.businessId, saleQuote.value)
    if (result?.success) saleQuote.value = null
    else {
      messageError.value = true
      message.value = result?.message || 'Engine Works could not be sold.'
      if (result?.quote) saleQuote.value = result.quote
    }
  } catch (error) { messageError.value = true; message.value = String(error) }
  finally { saleSubmitting.value = false }
}
async function debugTests() { const result = await lua.overhaul_career_business_computer.runEngineShopInvariantTests(); messageError.value = !result?.success; message.value = result?.success ? `All ${result.checks} invariant groups passed.` : `Failures: ${(result?.failures || []).join(', ')}` }
function onInputFocus() { inputFocused = true }
function onInputBlur() { inputFocused = false }
function certificationLabel(pkg) { if (pkg.certification?.status === 'unknown') return 'Rating unknown'; if (pkg.certified) return 'Certified recipe'; if (pkg.certification?.status === 'pending') return 'Testing'; if (pkg.certification?.status === 'failed') return 'Failed'; return 'Uncertified' }
function certClass(pkg) { if (pkg.certified) return 'certified'; if (pkg.certification?.status === 'pending') return 'pending'; if (pkg.certification?.status === 'failed') return 'failed'; return '' }
function packageStatus(pkg) { return pkg.status === 'installed' ? `Installed in vehicle #${pkg.installedInventoryId}` : pkg.status === 'stored' ? 'Stored' : 'Incomplete package' }
function blueprintName(id) { return shop.blueprints.find(bp => String(bp.id) === String(id))?.name || `Blueprint ${id}` }
function rawFor(id) { return id ? Number(shop.rawStock?.[id] || 0) : 0 }
function finishedFor(id) { return id ? shop.warehousePackages.filter(pkg => String(pkg.blueprintId) === String(id)).length : 0 }
function lineElapsedSeconds(line) {
  return lineStatus(line) === 'Producing' && Number.isFinite(line.startedAtSeconds)
    ? Math.min(Number(line.cycleSeconds) || 0, Math.max(0, nowSeconds.value - line.startedAtSeconds))
    : Number(line.progressSeconds) || 0
}
function lineProgress(line) { return Math.max(0, Math.min(100, lineElapsedSeconds(line) / Math.max(1, Number(line.cycleSeconds) || 1) * 100)) }
function lineStatus(line) { if (line.id > shop.lineCapacity) return 'Locked'; if (line.broken) return 'Breakdown'; if (!line.blueprintId) return 'Needs blueprint'; if (rawFor(line.blueprintId) < 1) return 'Waiting for material'; return line.running ? 'Producing' : 'Ready' }
function lineStateClass(line) { if (line.id > shop.lineCapacity) return 'muted'; if (line.broken || rawFor(line.blueprintId) < 1) return 'alert'; if (line.running) return 'active'; return '' }
function lineUpgradeBonus(line, kind) { if (kind === 'speed') return `${duration(line.cycleSeconds)} active time per engine`; if (kind === 'quality') return `${number((line.successChance || 0) * 100)}% success chance`; return `${number((line.breakdownChance || 0) * 100)}% breakdown, ${number((line.maintenanceDiscount || 0) * 100)}% overhaul discount` }
// null once maxed; the template shows the cost with the currency glyph
function lineUpgradeCost(line, upgrade) { const level = line.upgrades?.[upgrade.id] || 0; return level >= 3 ? null : upgrade.costs?.[level] }
function upgradeOwned(id) { return !!shop.upgrades.find(row => row.id === id)?.owned }
function upgradeName(id) { return shop.upgrades.find(row => row.id === id)?.name || id }
function duration(value) { const total = Math.max(0, Math.ceil(Number(value) || 0)); const hours = Math.floor(total / 3600); const minutes = Math.floor((total % 3600) / 60); const seconds = total % 60; return hours ? `${hours}h ${minutes}m` : minutes ? `${minutes}m ${seconds.toString().padStart(2, '0')}s` : `${seconds}s` }
// display-only helpers: pill tones, reservation wording, scaleX fills, the one orange Start Line
function certTone(pkg) { if (pkg.certification?.status === 'unknown') return 'warn'; if (pkg.certified) return 'ok'; if (pkg.certification?.status === 'pending') return 'accent'; if (pkg.certification?.status === 'failed') return 'bad'; return '' }
function lineTone(line) { return { Producing: 'accent', 'Needs blueprint': 'warn', 'Waiting for material': 'warn', Breakdown: 'bad' }[lineStatus(line)] || '' }
const primaryStartLineId = computed(() => shop.lines.find(line => line.id <= shop.lineCapacity && !line.broken && !line.running && line.blueprintId && rawFor(line.blueprintId) >= 1)?.id)
function reservationLabel(status) { return { available: 'Awaiting pickup', inTransit: 'In transit', delivered: 'Delivered', cancelled: 'Cancelled' }[status] || status }
function fill(percent) { return { transform: `scaleX(${Math.max(0, Math.min(100, Number(percent) || 0)) / 100})` } }
function saleTime(row) { const minute = Number(row?.minuteOfDay); if (!Number.isFinite(minute)) return `Day ${Number(row?.day) || 0}`; const hours = Math.floor(minute / 60).toString().padStart(2, '0'); const minutes = Math.floor(minute % 60).toString().padStart(2, '0'); return `D${Number(row?.day) || 0} ${hours}:${minutes}` }

watch(() => props.data?.businessId, () => refresh(true))
watch(view, () => { saleQuote.value = null })
watch(saleQuote, (quote) => {
  if (quote) {
    nextTick(() => {
      const dialogEl = saleDialogRef.value
      if (!dialogEl) return
      if (dialogEl !== saleModalPushedEl) {
        saleModalPushedEl = dialogEl
        focusSaleDialogFirst()
      }
      enableSaleKeyListener()
    })
  } else {
    disableSaleKeyListener()
    saleModalPushedEl = null
    nextTick(() => focusReviewSaleButton())
  }
})
onMounted(() => { refresh(true); poll = setInterval(refresh, 5000) })
onUnmounted(() => {
  unmounted = true
  clearInterval(poll)
  if (inputFocused) onInputBlur()
  disableSaleKeyListener()
  saleModalPushedEl = null
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* ---------- page ---------- */
.engine-shop {
  display: grid;
  gap: 1em;
  width: 100%;
  max-width: 110em;
  margin: 0 auto;
  font-size: 1em;
}
h2, h3, p, dl, dd, dt { margin: 0; }
.num { font-variant-numeric: tabular-nums; }
.money { color: var(--money); }
.negative { color: var(--bad); }
.faint { color: var(--faint); }
b { font-weight: 800; }

.page-title { font-size: 1.4em; font-weight: 800; line-height: 1.15; color: #fff; }
.item-title { font-size: 1.15em; font-weight: 800; line-height: 1.2; color: #fff; overflow-wrap: anywhere; }
.body-copy { color: var(--muted); font-size: 1em; font-weight: 600; line-height: 1.4; }
.hint { font-size: 0.78em; line-height: 1.35; }
.caption { font-size: 0.74em; }
.cluster { gap: 0.45em; }

/* header: caption + title + hint, account facts right */
.shop-header {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 1em 2em;
  flex-wrap: wrap;
}
.shop-heading { display: grid; gap: 0.3em; min-width: 0; }
.page-hint { font-size: 0.9em; }
.facts.head-facts {
  grid-template-columns: repeat(2, auto);
  column-gap: 2em;
  text-align: right;
  .fact-value { font-size: 1.3em; font-variant-numeric: tabular-nums; }
}
.fact-key { font-size: 0.72em; }
.fact-value {
  font-variant-numeric: tabular-nums;
  overflow: visible;
  white-space: normal;
  small { margin-left: 0.15em; font-size: 0.72em; font-weight: 600; color: var(--faint); }
}

.notice.ok, .notice.bad { font-size: 1em; }

/* section head: caption left, hint/pill right */
.block { display: grid; gap: 0.5em; }
.block-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.3em 1em;
  padding: 0 0.15em;
}
.panel { padding: var(--inset) 1em; gap: 0.6em; }
.sheet { border-radius: var(--radius-panel); background: var(--panel); }

/* sheet tables: caption column heads, tabular numbers. The small caption size sits on the
   head's cells, not the row, so the em-sized grid tracks and side padding match the body rows
   (a 0.74em row shrank every column and shifted the heads left of their values). */
.col-head {
  border-bottom: 1px solid var(--line);
  > span {
    min-width: 0;
    color: var(--faint);
    font-size: 0.74em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
}
.sheet .line { padding-top: 0.65em; padding-bottom: 0.5em; }
.sheet .line.col-head { padding-top: 0.45em; padding-bottom: 0.35em; }
.row-name { font-weight: 700; line-height: 1.25; overflow-wrap: anywhere; min-width: 0; }
.row-end { display: flex; align-items: center; justify-content: flex-end; flex-wrap: wrap; gap: 0.45em; }
.serial { color: var(--faint); font-size: 0.9em; }
.empty-line { color: var(--faint); font-size: 0.92em; font-weight: 600; }
.empty:not(.bng-button) { justify-items: start; text-align: left; }

/* slim progress: scaleX fill */
.track {
  height: 0.4em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  > span {
    display: block;
    height: 100%;
    background: var(--accent);
    transform-origin: left center;
    transition: transform 0.4s ease;
  }
}

/* developer tools: quiet collapsed fold */
.dev-tools {
  color: var(--faint);
  > summary {
    width: fit-content;
    cursor: pointer;
    user-select: none;
    padding: 0.25em 0.1em;
    color: var(--faint);
    font-size: 0.72em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    opacity: 0.75;
    &:hover { opacity: 1; }
    @include house-focus;
    &.focus-visible, &.focus-visible { border-radius: var(--radius-pill); }
  }
  &[open] > summary { margin-bottom: 0.4em; }
}
.row-dev[open] { display: flex; align-items: center; flex-wrap: wrap; gap: 0.4em; > summary { margin-bottom: 0; } }

/* ---------- dashboard ---------- */
.facts.summary-facts {
  grid-template-columns: repeat(5, minmax(0, 1fr));
  .fact-value { font-size: 1.25em; }
}
.work-bay {
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: 1em 2em;
}
.bay-copy { display: grid; gap: 0.3em; min-width: 0; }
.bay-picker { margin-top: 0.3em; }
.bay-actions { display: grid; justify-items: end; gap: 0.5em; }
.op-line {
  display: grid;
  grid-template-columns: minmax(8em, 0.55fr) minmax(10em, 0.7fr) 1.7fr;
  align-items: baseline;
  gap: 1em;
  strong { font-weight: 700; }
  strong.attention { color: var(--warn); }
}
.op-key { color: var(--faint); font-size: 0.78em; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; }
.op-note { color: var(--muted); font-size: 0.9em; }

/* ---------- engine packages ---------- */
.intro {
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: 1em 2em;
}
.intro-copy { display: grid; gap: 0.3em; min-width: 0; }
.package-list, .production-list, .sales-list { display: grid; gap: 0.6em; }
.package-row {
  grid-template-columns: 15em minmax(0, 1fr) auto;
  align-items: center;
  gap: 1.1em;
  padding: 0.6em;
}
.pkg-photo {
  display: grid;
  place-items: center;
  width: 100%;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);
  .pkg-photo-glyph { font-size: 3em; color: var(--muted); }
  img { width: 100%; height: 100%; object-fit: contain; object-position: center; display: block; }
}
.package-copy { display: grid; gap: 0.3em; min-width: 0; justify-items: start; }
.package-copy .item-title { font-size: 1.3em; }
.sub { color: var(--muted); font-weight: 600; }
.meta-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2em 1.2em;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.status-note { margin-top: 0.15em; color: var(--muted); font-size: 0.9em; font-weight: 600; line-height: 1.35; }
.status-note.warn { color: var(--warn); }
.status-note.bad { color: var(--bad); }
.row-actions { display: grid; justify-items: end; gap: 0.5em; padding-right: 0.4em; }

/* ---------- production ---------- */
.production-line { padding: 0; gap: 0; }
.production-line.locked { opacity: 0.6; }
.line-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.6em 1em;
  padding: 0.75em 1em 0.65em;
  border-bottom: 1px solid var(--line);
}
.line-identity { display: flex; align-items: center; flex-wrap: wrap; gap: 0.7em; }
.engine-shop .warn-btn { color: var(--warn); }
.locked-note { padding: 0.55em 1em; border-bottom: 1px solid var(--line); }
.line-flow { display: grid; grid-template-columns: minmax(18em, 1.35fr) minmax(12em, 0.8fr) minmax(14em, 1fr); }
.stage {
  display: grid;
  align-content: center;
  gap: 0.5em;
  min-width: 0;
  padding: 0.85em 1em;
  border-right: 1px solid var(--line);
  &:last-child { border-right: 0; }
}
.stage-row { display: flex; align-items: center; gap: 0.5em; > .house-menu { flex: 1 1 auto; } }
.cycle-readout {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 1em;
  strong { font-weight: 700; }
  span { color: var(--faint); font-size: 0.9em; }
}
.flow-count { font-size: 1.1em; font-weight: 700; i { margin: 0 0.3em; color: var(--faint); font-style: normal; } }
.line-settings {
  border-top: 1px solid var(--line);
  > summary {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 0.5em 1em;
    padding: 0.6em 1em 0.5em;
    cursor: pointer;
    user-select: none;
    color: var(--muted);
    font-size: 0.9em;
    font-weight: 700;
    &:hover { background: rgba(255, 255, 255, 0.03); }
    @include house-focus(var(--focus-inset));
  }
}
.upgrade-summary { display: inline-flex; flex-wrap: wrap; gap: 0.35em; }
.upgrade-lines { padding: 0 1em 0.3em; border-top: 1px solid var(--line); }
.line-upgrade {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 8em auto;
  align-items: center;
  gap: 1em;
}
.line-upgrade-copy { display: grid; gap: 0.15em; min-width: 0; }
.level { color: var(--faint); font-size: 0.9em; }
.line-dev { padding: 0.45em 1em 0.6em; border-top: 1px solid var(--line); }

/* ---------- warehouse ---------- */
.warehouse-gauge {
  grid-template-columns: minmax(16em, 0.75fr) minmax(14em, 1.25fr) auto;
  align-items: center;
  gap: 1em 2em;
}
.gauge-copy { display: grid; gap: 0.25em; }
.material-grid { display: grid; grid-template-columns: minmax(12em, 1.4fr) 6em 7em 6.5em minmax(10em, auto); align-items: center; gap: 1em; }
.reservation-grid { display: grid; grid-template-columns: 7em minmax(12em, 1fr) 10em 8em; align-items: center; gap: 1em; }
.finished-grid { display: grid; grid-template-columns: 6em minmax(12em, 1fr) auto; align-items: center; gap: 1em; }
.finished-copy { display: grid; gap: 0.15em; min-width: 0; }
.qty-field, .price-field { font-variant-numeric: tabular-nums; padding-top: 0.55em; padding-bottom: 0.4em; }

/* ---------- sales ---------- */
.sales-queue { gap: 0.65em; }
.queue-head { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: start; gap: 1em 2em; }
.queue-copy { display: grid; gap: 0.3em; min-width: 0; }
.queue-copy .item-title { font-size: 1.3em; }
.queue-timer { display: grid; justify-items: end; gap: 0.45em; }
.queue-timer .pill { font-size: 0.9em; }
.payout { color: var(--faint); font-size: 0.9em; font-weight: 600; b { font-size: 1.15em; } }
.sale-row {
  grid-template-columns: minmax(16em, 1.2fr) minmax(15em, 0.9fr) minmax(14em, 0.75fr);
  align-items: start;
  gap: 1.5em;
}
.sale-product { display: grid; gap: 0.35em; justify-items: start; min-width: 0; }
.sale-product .item-title { font-size: 1.3em; }
.profit { color: var(--faint); font-size: 0.9em; font-weight: 600; }
.sale-terms { background: rgba(0, 0, 0, 0.2); }
.sale-terms .line-key { color: var(--muted); font-size: 0.9em; }
.sale-terms strong { font-weight: 700; }
.awareness { display: grid; gap: 0.45em; justify-content: stretch; }
.awareness-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1em; }
.price-control { display: grid; gap: 0.6em; align-content: start; }
.history-grid { display: grid; grid-template-columns: 6em minmax(12em, 1fr) 4em 8em 9em; align-items: center; gap: 1em; }

/* ---------- upgrades ---------- */
.upgrade-grid { display: grid; grid-template-columns: minmax(12em, 0.8fr) minmax(16em, 1.5fr) 8em 8em; align-items: center; gap: 1em; }
.upgrade-effect { display: grid; gap: 0.15em; color: var(--muted); min-width: 0; }

/* ---------- finances ---------- */
.finance-summary { gap: 0.35em; }
.balance { font-size: 1.8em; font-weight: 800; color: var(--money); line-height: 1.1; }
.balance.negative { color: var(--bad); }
.business-sale { grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 1em 2em; }
.sale-copy { display: grid; gap: 0.3em; min-width: 0; }

/* ---------- sale settlement modal (teleported: carries .rls-house + the em scale itself) ---------- */
.engine-sale-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.engine-sale-dialog {
  width: min(100%, 32em);
  max-height: calc(100vh - 2em);
  overflow-y: auto;
  padding: 1.2em;
  gap: 0.75em;
  color: #fff;
  .page-title { font-size: 1.35em; }
}
.settlement-rows {
  background: rgba(255, 255, 255, 0.05);
  dt { color: var(--muted); font-weight: 600; }
  dd { color: var(--money); font-weight: 800; font-variant-numeric: tabular-nums; }
  .settlement-total { font-size: 1.12em; dt { color: #fff; font-weight: 800; } }
}
.sale-dialog-actions { display: flex; justify-content: space-between; gap: 0.6em; margin-top: 0.2em; }

/* ---------- narrow ---------- */
@media (max-width: 70em) {
  .line-flow, .sale-row { grid-template-columns: 1fr; }
  .stage { border-right: 0; border-bottom: 1px solid var(--line); &:last-child { border-bottom: 0; } }
  .warehouse-gauge { grid-template-columns: 1fr auto; }
  .gauge-track { grid-column: 1 / -1; grid-row: 2; }
  .facts.summary-facts { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .material-grid { grid-template-columns: minmax(10em, 1fr) 5em 6em 5.5em; .row-end { grid-column: 1 / -1; justify-content: flex-start; } }
  .material-grid.col-head > span:last-child { display: none; }
}
@media (max-width: 46em) {
  .work-bay, .intro, .business-sale, .queue-head { grid-template-columns: 1fr; }
  .bay-actions, .queue-timer, .row-actions { justify-items: start; }
  .facts.head-facts { text-align: left; }
  .facts.summary-facts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .package-row, .op-line, .finished-grid, .line-upgrade { grid-template-columns: 1fr; }
  .warehouse-gauge { grid-template-columns: 1fr; }
  .gauge-track { grid-column: 1; grid-row: auto; }
  .col-head { display: none; }
  .material-grid, .reservation-grid, .history-grid, .upgrade-grid { grid-template-columns: 1fr 1fr; }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
