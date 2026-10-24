<template>
  <div class="pc-status-section">
    <div v-if="!hero" class="pc-money">{{ moneySign(money?.value) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(money?.value || 0) }}</div>

    <!-- The featured card is the one the player is most likely to press,
         so it answers "where was I?" without being opened first: what you
         are worth, what you own, what you are good at, what just moved. -->
    <!-- Two rows: what the save is worth, then what it owns. Five figures
         across one row collided and truncated their own captions. -->
    <template v-if="hero">
      <div class="pc-tiles pc-tiles--money">
        <div v-for="tile in heroMoneyTiles" :key="tile.label" :class="['pc-tile', { 'pc-tile--cash': tile.cash }]">
          <span class="pc-tile-cap">{{ tile.label }}</span>
          <span class="pc-tile-num"><template v-if="tile.money">{{ tile.sign }}<BngIcon class="cur" :type="icons.beamCurrency" /></template>{{ tile.value }}</span>
        </div>
      </div>
      <div class="pc-tiles">
        <div v-for="tile in heroCountTiles" :key="tile.label" class="pc-tile">
          <span class="pc-tile-cap">{{ tile.label }}</span>
          <span class="pc-tile-num">{{ tile.value }}</span>
        </div>
      </div>
    </template>

    <!-- Side by side on the featured card, a plain block on every other one. -->
    <div :class="['pc-detail', { 'pc-detail--split': hero }]">
      <div v-if="topSkills.length" class="pc-skills">
        <div v-if="hero" class="pc-col-title">Skills</div>
        <div v-for="sk in topSkills" :key="sk.id" class="pc-skill">
          <BngIcon :type="sk.icon" class="pc-skill-icon" />
          <span class="pc-skill-name">{{ sk.label }}</span>
          <span class="pc-skill-lvl">{{ $ctx_t(sk.levelLabel) }}</span>
          <div v-if="hero" class="pc-bar">
            <div class="pc-bar-fill" :style="{ width: `${Math.round(skillRatio(sk) * 100)}%` }" />
          </div>
        </div>
      </div>

      <!-- Always present on the selected card, even before its rows have
           been read. Making the column conditional on the data meant the
           whole panel relaid out a beat after every step. -->
      <div v-if="hero" class="pc-txns">
        <div class="pc-col-title">Recent money</div>
        <div v-for="(txn, i) in recentMoney" :key="i" class="pc-txn">
          <span class="pc-txn-label">{{ txn.label ? $ctx_t(txn.label) : "Transaction" }}</span>
          <span :class="['pc-txn-amount', txn.amount < 0 ? 'pc-txn-amount--out' : 'pc-txn-amount--in']">
            {{ txn.amount < 0 ? "−" : "+" }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(Math.abs(txn.amount)) }}
          </span>
        </div>
        <!-- Blank while it is still being read: an empty-state message that
             turns into rows is its own little flash. -->
        <div v-if="!recentMoney.length && !highlightsPending" class="pc-txns-empty">
          Nothing recorded yet
        </div>
      </div>
    </div>

    <!-- The card's switches and actions go after the figures, in the card's own template. -->
    <slot />
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { shrinkNum } from "@/utils/format"

const props = defineProps({
  money: Object,
  hero: Boolean,
  freSkills: { type: [Array, Object], default: () => [] },
  /** [{amount, label, time}] newest first — fetched by the parent, hero only. */
  recentMoney: { type: Array, default: () => [] },
  /** True while the highlights are still being read, so empty is not mistaken for none. */
  highlightsPending: Boolean,
  /** Owned vehicles valued at age + mileage, summed. Hero only. */
  assetValue: Number,
  vehicleCount: Number,
  garageCount: Number,
  insuranceScore: Object,
})

/**
 * Magnitude only: the template puts the sign, then the game currency glyph, before it.
 * Six figures and up are shortened, because the balance and the history column both
 * have to hold one line.
 * Stays local: utils/units.js formatMoney fixes the fraction digits, has no k/M shortening, shows a dash for
 * non-finite input and keeps the sign. The money line is pinned by profile_card_characterization_test.cjs.
 */
function formatMoney(value) {
  const n = Number(value)
  if (!Number.isFinite(n)) return "0"
  const abs = Math.abs(n)
  // Cents only where they carry meaning. On a four-figure balance they are noise
  // and they were wide enough to push the figure into the tile beside it.
  let body
  if (abs > 100000) body = shrinkNum(abs, 1)
  else if (abs >= 1000) body = Math.round(abs).toLocaleString()
  else body = abs.toLocaleString(undefined, { maximumFractionDigits: 2 })
  return body
}

const moneySign = value => (Number(value) < 0 ? "−" : "")

const formatCount = num => {
  const n = Number(num)
  if (!Number.isFinite(n)) return "0"
  return Math.round(n).toLocaleString()
}

/**
 * What the save is worth in things, not in points. BeamXP is deliberately absent:
 * nothing in the overhaul gates on it, so it was a number with no consequence.
 */
const heroMoneyTiles = computed(() => [
  { label: "Balance", value: formatMoney(props.money?.value || 0), sign: moneySign(props.money?.value), money: true, cash: true },
  // "—" while the figure is still being read — "$0" would read as broke.
  { label: "Asset value", value: props.assetValue == null ? "—" : formatMoney(props.assetValue), sign: moneySign(props.assetValue), money: props.assetValue != null },
])

const heroCountTiles = computed(() => {
  const tiles = []
  if (props.vehicleCount != null) tiles.push({ label: "Vehicles", value: formatCount(props.vehicleCount) })
  if (props.garageCount != null) tiles.push({ label: "Garages", value: formatCount(props.garageCount) })
  // Vouchers deliberately absent: nothing in the overhaul spends them.
  if (props.insuranceScore) tiles.push({ label: "Driver score", value: formatCount(props.insuranceScore.value) })
  return tiles
})

function skillRatio(skill) {
  const span = Number(skill?.neededForNext)
  const progress = Number(skill?.curLvlProgress)
  if (!Number.isFinite(span) || span <= 0 || !Number.isFinite(progress)) return 0
  return Math.min(1, Math.max(0, progress / span))
}

const topSkills = computed(() => {
  // Lua sends {} for an empty skill table, so accept an object as well as an array
  const raw = props.freSkills
  const list = Array.isArray(raw) ? raw : Object.values(raw || {})
  if (!list.length) return []
  return [...list]
    .sort((a, b) => {
      const ld = (Number(b.level) || 0) - (Number(a.level) || 0)
      if (ld !== 0) return ld
      return (Number(b.value) || 0) - (Number(a.value) || 0)
    })
    .slice(0, props.hero ? 5 : 3)
})
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.pc-col-title,
.pc-tile-cap {
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.45);
}

.pc-col-title {
  font-size: 0.68em;
}

/* Flex, not a fixed column count — the strip has to stay even however many of
   these actually have a value to show. */
.pc-tiles {
  display: flex;
  padding-bottom: 0.5em;
  margin-bottom: 0.5em;
  border-bottom: 1px solid #1e2533;
}

.pc-tiles--money {
  padding-bottom: 0.4em;
  margin-bottom: 0.4em;
}

/* Ruled columns rather than gaps: bare numbers in a row need the divisions
   drawn, otherwise they read as one number. */
.pc-tile {
  display: flex;
  flex: 1 1 0;
  flex-direction: column;
  gap: 0.1em;
  min-width: 0;
  padding: 0 0.6em;
  border-left: 1px solid #1e2533;

  &:first-child {
    padding-left: 0;
    border-left: 0;
  }
}

.pc-tile-cap {
  font-size: 0.6em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.pc-tile-num {
  font-size: 1.1em;
  font-weight: 800;
  line-height: 1.1;
}

/* Both money figures read large; only the spendable one is green. */
.pc-tiles--money .pc-tile-num {
  font-size: 1.4em;
}

.pc-tile--cash .pc-tile-num {
  color: #86efac;
}

/* Two columns on the featured card, one plain block everywhere else. */
.pc-detail {
  min-height: 0;
}

.pc-col-title {
  margin-bottom: 0.3em;
}

.pc-txns {
  display: flex;
  flex-direction: column;
  gap: 0.15em;
  min-width: 0;
}

.pc-txn {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
  padding: 0.16em 0;
  font-size: 0.78em;
  border-bottom: 1px solid rgba(30, 37, 51, 0.7);
}

.pc-txn-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: rgba(255, 255, 255, 0.7);
}

.pc-txn-amount {
  flex: 0 0 auto;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.pc-txn-amount--in { color: #86efac; }
.pc-txn-amount--out { color: #fca5a5; }

.pc-txns-empty {
  padding-top: 0.2em;
  font-size: 0.75em;
  color: rgba(255, 255, 255, 0.35);
}

.pc-bar {
  grid-column: 1 / -1;
  height: 0.25em;
  margin-bottom: 0.1em;
  border-radius: 999px;
  background: rgba(100, 116, 139, 0.3);
  overflow: hidden;
}

.pc-bar-fill {
  height: 100%;
  border-radius: 999px;
  background: linear-gradient(90deg, #ff7a1a, #ff9647);
}

.pc-money {
  display: flex;
  justify-content: flex-end;
  font-weight: 700;
  font-size: 1.05em;
  padding-bottom: 0.4em;
  border-bottom: 1px solid #1e2533;
  margin-bottom: 0.35em;
}

.pc-skills {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  margin-bottom: 0.5em;
}

.pc-skill {
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding: 0.2em 0;

  .pc-skill-icon {
    flex: 0 0 auto;
    font-size: 1.15em;
    opacity: 0.85;
  }

  .pc-skill-name {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 600;
    font-size: 0.82em;
  }

  .pc-skill-lvl {
    flex: 0 0 auto;
    font-size: 0.72em;
    font-weight: 700;
    opacity: 0.6;
  }
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
