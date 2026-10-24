<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Engine Works purchase brief and owned-shop reference. Prices arrive from the purchase
     view; potential bonuses and timer come from the shop pricing config via getBriefData. -->
<template>
  <section class="rls-house engine-overview" :class="{ 'purchase-mode': purchaseMode }">
    <header class="overview-masthead">
      <div class="masthead-copy">
        <span class="caption">Owner's brief</span>
        <h1 class="overview-title">Engine shop</h1>
        <p class="lead">Your engine build. A repeatable product.</p>
      </div>
      <dl v-if="purchaseMode" class="purchase-terms">
        <div class="fact money">
          <dt class="fact-key">Purchase price</dt>
          <dd class="fact-value">
            <BngIcon class="cur" :type="icons.beamCurrency" />
            {{ money(price) }}
          </dd>
        </div>
        <div v-if="financingAllowed" class="fact money">
          <dt class="fact-key">Finance entry</dt>
          <dd class="fact-value">
            <BngIcon class="cur" :type="icons.beamCurrency" />
            {{ money(downPayment) }}
            <small>down</small>
          </dd>
        </div>
      </dl>
    </header>
    <div class="workbench">
      <figure class="engine-photo">
        <img
          src="/ui/ui-vue/mods/rls_career_overhaul/overhaul/assets/engineBriefHero.jpg"
          alt="V8 engine on a wooden pallet"
        />
        <figcaption>Build it once. Make it yours.</figcaption>
      </figure>
      <div class="workbench-loop">
        <section class="pipeline-section">
          <h3 class="section-bar">From your garage to the customer</h3>
          <ol class="visual-loop">
            <li v-for="(step, index) in briefSteps" :key="step.title" class="visual-step" :title="step.detail">
              <div class="step-art">
                <BngIcon :type="icons[step.icon]" />
              </div>
              <div class="step-copy">
                <span class="step-number">{{ String(index + 1).padStart(2, '0') }}</span>
                <strong>{{ step.title }}</strong>
                <p>{{ step.line }}</p>
              </div>
              <BngIcon v-if="index < briefSteps.length - 1" class="flow-arrow" :type="icons.arrowSmallRight" />
            </li>
          </ol>
        </section>
      </div>
      <div class="workbench-market">
        <section class="awareness-section">
          <h3 class="section-bar">Earn a better selling price</h3>
          <div v-if="market" class="bonus-list">
            <div class="bonus-row" v-for="item in bonuses" :key="item.name">
              <BngIcon class="bonus-icon" :type="icons[item.icon]" />
              <div class="bonus-copy">
                <strong class="bonus-source">{{ item.source }}</strong>
                <div class="bonus-title">
                  <span>{{ item.name }}</span>
                  <span class="money">Up to {{ item.percent }} price</span>
                </div>
              </div>
            </div>
          </div>
          <p v-if="!market" class="market-status" role="status">
            {{ marketError ? 'Price bonuses unavailable. Reopen the brief to retry.' : 'Loading price bonuses...' }}
          </p>
          <p v-if="market" class="price-build">Base price + earned bonuses = <strong>Supported price</strong></p>
          <div
            v-if="market"
            class="price-time"
            :title="'Brand and product awareness also raise the maximum asking price. A listed physical engine sells when its countdown reaches zero.'"
          >
            <BngIcon :type="icons.timer" />
            <span>Ask above supported price</span>
            <BngIcon :type="icons.arrowSmallRight" />
            <span>Longer sale timer</span>
            <strong>Up to {{ maxMinutes }} min</strong>
          </div>
          <p v-if="market" class="decay-note">Each sale uses some product awareness. Keep racing.</p>
        </section>
      </div>
    </div>
    <div class="brief-detail">
      <HouseButton
        variant="text"
        compact
        :nav-item="!navLocked"
        :aria-expanded="detailsOpen"
        aria-controls="engine-brief-details"
        @click="detailsOpen = !detailsOpen"
      >
        How it works
      </HouseButton>
      <div v-if="detailsOpen && !navLocked" id="engine-brief-details" class="detail-copy">
        <p v-for="step in briefSteps" :key="step.title">
          <strong>{{ step.title }}:</strong>
          {{ step.detail }}
        </p>
        <p>
          Promotion is earned, with no advertising purchase. List the blueprint, install its exact recipe in your
          personal car, then finish a freeroam race. Repeat finishes raise awareness with smaller gains near the
          maximum. Shop brand benefits every product. Product awareness benefits its matching blueprint. Both raise the
          maximum asking price.
        </p>
      </div>
    </div>
    <footer v-if="purchaseMode" class="overview-footer purchase-actions">
      <div class="footer-copy">
        <span class="caption">Acquire the works</span>
        <strong>Ready to build?</strong>
      </div>
      <!-- navLocked: the finance step is open over this, so these leave controller navigation -->
      <div class="action-buttons">
        <HouseButton variant="quiet" binding="back" :nav-item="!navLocked" @click="$emit('cancel')">Leave</HouseButton>
        <HouseButton v-if="financingAllowed" class="finance-button" :nav-item="!navLocked" @click="$emit('finance')">
          Finance with
          <BngIcon class="cur" :type="icons.beamCurrency" />
          {{ money(downPayment) }} down
        </HouseButton>
        <HouseButton variant="primary" :disabled="cantPay" :nav-item="!navLocked" @click="$emit('purchase')">
          Purchase outright for
          <BngIcon class="cur" :type="icons.beamCurrency" />
          {{ money(price) }}
        </HouseButton>
      </div>
    </footer>
    <footer v-else class="overview-footer reference-actions">
      <p class="hint">This overview remains available from the Reference section of the Engine Works menu.</p>
      <HouseButton variant="primary" @click="$emit('manage')">Go to Engine Packages</HouseButton>
    </footer>
  </section>
</template>

<script setup>
import { computed, ref, onMounted } from 'vue'
import { runRaw } from '@/bridge/libs/Lua.js'
import { BngIcon, icons } from '@/common/components/base'
import { HouseButton } from '../../../house/index.js'

const props = defineProps({
  businessName: { type: String, default: '' },
  supplierName: { type: String, default: '' },
  purchaseMode: { type: Boolean, default: false },
  price: { type: Number, default: 0 },
  downPayment: { type: Number, default: 0 },
  cantPay: { type: Boolean, default: false },
  financingAllowed: { type: Boolean, default: true },
  // purchase mode: true while a step (finance) is open over the overview
  navLocked: { type: Boolean, default: false }
})

defineEmits(['purchase', 'finance', 'cancel', 'manage'])

// number only: the template puts the game currency glyph in front
const money = (value) => Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
const market = ref(null)
const marketError = ref(false)
const detailsOpen = ref(false)
onMounted(async () => {
  try {
    market.value = await runRaw('overhaul_career_business_engineShop.getBriefData()')
    if (!market.value) marketError.value = true
  } catch {
    marketError.value = true
  }
})
const percent = (value) => `+${Math.round(value * 100)}%`
const maxMinutes = computed(() => (market.value ? Math.ceil(market.value.maxSaleSeconds / 60) : null))
const bonuses = computed(() =>
  market.value
    ? [
        { name: 'Shop brand', percent: percent(market.value.brandPriceBonus), icon: 'medal', source: 'Complete sales' },
        {
          name: 'Product awareness',
          percent: percent(market.value.productPriceBonus),
          icon: 'raceFlag',
          source: 'Race the engine'
        }
      ]
    : []
)
const briefSteps = computed(() => [
  {
    title: 'Certify',
    line: 'Save and test your exact build.',
    icon: 'engine',
    detail: 'Store a personal engine package and test its exact parts and tune to create a repeatable blueprint.'
  },
  {
    title: 'Supply',
    line: 'Bring recipe loads to receiving.',
    icon: 'cardboardBox',
    detail: `Order recipe-specific loads, collect them at ${props.supplierName || 'the supplier'}, and deliver them to receiving.`
  },
  {
    title: 'Produce',
    line: 'Turn raw loads into engines.',
    icon: 'cogs',
    detail:
      'Assign a blueprint to a line. Each completed cycle consumes one raw load and may produce one physical engine.'
  },
  {
    title: 'Sell',
    line: 'List stock and set your price.',
    icon: 'shoppingCart',
    detail:
      'Stock and list an engine to start its visible timer. One physical engine sells when the countdown reaches zero.'
  }
])
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss' as *;

.engine-overview {
  --loop-gap: 1.6em;
  width: 100%;
  display: grid;
  gap: 1.5em;
  color: #fff;
}

/* Purchase screen: the overview stands alone over the world, so it carries the house modal look
   and the shell's vh-based font size itself. */
.engine-overview.purchase-mode {
  width: min(68em, calc(100vw - 4em));
  max-height: calc(100vh - 3em);
  overflow-y: auto;
  padding: 1.4em 1.6em;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow:
    0 0 0 1px rgba(255, 255, 255, 0.08),
    0 18px 40px rgba(0, 0, 0, 0.55);
}

h1,
h2,
h3,
p,
dl,
dd,
ol {
  margin: 0;
}

/* masthead */
.overview-masthead {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 2em;
  align-items: end;
}

.masthead-copy {
  display: grid;
  gap: 0.35em;
}

.overview-title {
  font-size: 1.5em;
  font-weight: 800;
  line-height: 1.15;
}

.lead {
  max-width: 44em;
  color: var(--muted);
  font-size: 1em;
  line-height: 1.45;
}

.purchase-terms {
  display: grid;
  grid-auto-flow: column;
  gap: 2em;
}

.purchase-terms .fact-key {
  font-size: 0.75em;
}

.purchase-terms .fact-value {
  font-size: 1.35em;
  font-variant-numeric: tabular-nums;
  overflow: visible;
  text-overflow: clip;

  small {
    color: var(--faint);
    font-size: 0.6em;
    font-weight: 700;
  }
}

.caption {
  font-size: 0.75em;
}
.step-number {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

/* footer */
.overview-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1em;
  padding-top: 1.1em;
  border-top: 1px solid var(--line);
}

.reference-actions .hint {
  font-size: 0.85em;
}

.footer-copy {
  display: grid;
  gap: 0.2em;

  strong {
    font-size: 1.1em;
    font-weight: 700;
  }
}

.action-buttons {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.6em;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}

/* Open workbench: the photo balances the earnings explanation; the process spans both. */
.engine-overview.purchase-mode {
  width: min(74em, calc(100vw - 4em));
  gap: 1.1em;
  padding: 1.4em 1.6em 1.2em;
}
.overview-title {
  font-size: 2.1em;
}
.overview-masthead {
  align-items: center;
}
.section-bar {
  font-size: 1.05em;
  font-weight: 800;
  padding: 0.4em 0.8em 0.4em 0.55em;
  background: linear-gradient(105deg, #353538 0%, #353538 85%, transparent 85%);
}
.workbench {
  display: grid;
  grid-template-columns: 1fr 1.05fr;
  gap: 1.3em 2em;
  align-items: start;
}
.engine-photo {
  margin: 0;
  min-width: 0;
}
.engine-photo img {
  display: block;
  width: 100%;
  height: 17em;
  object-fit: cover;
}
.engine-photo figcaption {
  font-size: 1.4em;
  font-weight: 800;
  margin-top: 0.5em;
}
.workbench-market {
  grid-column: 2;
  grid-row: 1;
  min-width: 0;
}
.awareness-section {
  display: grid;
  gap: 0.8em;
}
.bonus-list {
  display: grid;
}
.bonus-row {
  display: flex;
  align-items: center;
  gap: 0.8em;
  padding: 0.7em 0;
  border-bottom: 1px solid var(--line);
}
.bonus-icon {
  font-size: 2.2em;
  color: #ededed;
}
.bonus-copy {
  flex: 1;
  min-width: 0;
}
.bonus-source {
  font-size: 1.15em;
}
.bonus-title {
  display: flex;
  justify-content: space-between;
  gap: 0.6em;
  margin-top: 0.3em;
  color: var(--muted);
}
.bonus-title .money {
  font-weight: 800;
  white-space: nowrap;
  color: var(--money);
  font-variant-numeric: tabular-nums;
}
.price-build {
  color: var(--muted);
  font-size: 0.91em;
}
.price-build strong {
  color: var(--money);
}
.price-time {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.45em;
  font-size: 0.91em;
}
.price-time > :deep(.icon-base):first-child {
  font-size: 1.8em;
}
.price-time strong {
  font-variant-numeric: tabular-nums;
}
.decay-note {
  color: var(--faint);
  font-size: 0.82em;
}
.workbench-loop {
  grid-column: 1 / -1;
  grid-row: 2;
  min-width: 0;
}
.visual-loop {
  display: flex;
  list-style: none;
  padding: 1em 0 0;
  gap: 2em;
}
.visual-step {
  display: flex;
  align-items: center;
  gap: 0.65em;
  flex: 1;
  position: relative;
  min-width: 0;
}
.step-art {
  flex: 0 0 2.8em;
  color: #ededed;
}
.step-art > :deep(.icon-base) {
  font-size: 2.8em;
}
.step-copy {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 0.2em 0.45em;
  align-items: baseline;
}
.step-copy strong {
  font-size: 1.2em;
}
.step-copy p {
  grid-column: 1 / -1;
  color: var(--muted);
  font-size: 0.91em;
  line-height: 1.35;
}
.flow-arrow {
  position: absolute;
  right: -1.5em;
  color: var(--faint);
  font-size: 1.2em;
}
.brief-detail {
  position: relative;
  font-size: 0.85em;
  color: var(--muted);
}
.brief-detail :deep(.focus-visible) {
  outline: 2px solid var(--bng-orange-b400, #ff6600);
  outline-offset: 2px;
}
.detail-copy {
  position: absolute;
  bottom: 1.7em;
  left: 0;
  z-index: 2;
  width: min(48em, 70vw);
  padding: 1.2em;
  background: #252528;
  border: 1px solid #555;
  box-shadow: 0 8px 24px #0008;
}
.detail-copy p + p {
  margin-top: 0.6em;
}
.overview-footer {
  padding-top: 0.8em;
}
.action-buttons {
  flex-wrap: nowrap;
}
.footer-copy strong {
  font-size: 1.05em;
}
@media (max-width: 900px) {
  .overview-masthead, .workbench {
    grid-template-columns: 1fr;
  }
  .workbench-loop, .workbench-market {
    grid-column: 1;
    grid-row: auto;
  }
  .visual-loop {
    flex-direction: column;
  }
  .flow-arrow {
    display: none;
  }
  .overview-footer {
    align-items: flex-start;
    flex-direction: column;
  }
  .action-buttons {
    flex-wrap: wrap;
  }
}
</style>
