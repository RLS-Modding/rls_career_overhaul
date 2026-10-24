<template>

  <div
    class="cargo-drop-off-wrapper rls-house"
    v-bng-blur
    v-bng-scoped-nav="{ scopeId: 'cargo-drop-off', preferAutoFocus: true, canDeactivate: () => false }"
    v-bng-on-ui-nav:back,menu="onBack"
    v-if="mode !== MODES.wait">
    <div class="reward-wrapper" :class="{ 'showing-results': mode === MODES.results }" >


      <section class="handoff-panel" v-if="mode === MODES.cargoSelection">

        <header class="handoff-header"><span class="caption">Job Broker delivery</span><h1>Unload cargo</h1></header>
        <div class="card-content" v-bng-ui-nav-scroll>
          <p v-if="data.customAmountPerMaterialType.some(info => !info.virtualCapacity)" class="notice limited-capacity-info">
            <BngIcon :type="icons.info" /> This facility has limited capacity for ordinary cargo.
          </p>
          <div class="scroll-wrapper">
            <template v-for="info in data.customAmountPerMaterialType">
              <CardGroup class="fullwidth-group" :label="info.material.name" :meta="info.meta">
                <p v-if="info.virtualCapacity" class="hint group-note">
                  <BngIcon :type="icons.checkmark" /> Project capacity is reserved for the full contract load.
                </p>
                <p v-if="info.isFull" class="notice warn group-note">
                  <BngIcon :type="icons.abandon" /> The storage for this material is completely filled. Come back later.
                </p>
                <template v-for="item in info.items">
                  <div class="cargo-wrapper">
                    <div class="header">
                      <span class="fact"><span class="fact-key">Origin</span><span class="fact-value">{{ item.originName }}</span></span>
                      <span class="fact"><span class="fact-key">Container</span><span class="fact-value">{{ item.containerName }}</span></span>
                    </div>
                    <div class="amount-controls">
                      <HouseButton :disabled="info.isFull" class="less" compact variant="quiet" :icon="icons.minus" aria-label="Less"
                        @click="adjustAmount(info, item, -1)" />
                      <HouseSlider
                          :disabled="info.isFull"
                          class="slider"
                          :min="0"
                          :max="item.loadSliderMax"
                          v-model="item.amountSelector"
                          :step="1"
                          @change="updateSliderAmounts(info, item)"
                          />
                      <HouseButton :disabled="info.isFull" class="more" compact variant="quiet" :icon="icons.plus" aria-label="More"
                        @click="adjustAmount(info, item, 1)" />
                      <div class="amount">
                        <strong>{{ item.amountSelector }}</strong><span> / {{ item.slots }}</span>
                      </div>
                    </div>
                  </div>
                </template>
              </CardGroup>
            </template>
          </div>

        </div>

        <footer class="handoff-actions">
          <!-- B / Cancel leaves without unloading (Lua drops the pending selection in dropOffPopupClosed) -->
          <HouseButton variant="quiet" class="footer-btn cancel-btn" binding="back" :disabled="selectionSent" @click="cancelSelection">Cancel</HouseButton>
          <HouseButton variant="primary" class="footer-btn" :disabled="selectionSent" bng-scoped-nav-autofocus @click="confirmSelection"><BngBinding ui-event="ok" deviceMask="xinput" /><span>Confirm Selection</span></HouseButton>
        </footer>
      </section>
      <section class="handoff-panel" v-if="mode === MODES.results">
        <header class="handoff-header"><span class="caption">{{ resultSourceName }}</span><h1>{{ resultsHeading }}</h1><p v-if="resultsRoute" class="result-route">{{ resultsRoute }}</p></header>
        <!-- read-only breakdown; focus sits on the footer button, so the right stick scrolls it regardless -->
        <div class="card-content" v-bng-ui-nav-scroll.force>

          <div v-if="contractProgressList.length" class="contract-progress-panel">
            <p class="contract-held-note" v-if="contractRewardsHeld">Rewards are held until this contract is finished.</p>
            <div v-for="progress in contractProgressList" :key="progress.id || progress.name" class="contract-progress-row">
              <div class="contract-progress-header">
                <strong>{{ progress.name || 'Contract' }}</strong>
                <span v-if="progress.kind === 'finkHaul'">
                  {{ progress.deliveredCount || 0 }} / {{ progress.totalCount || 0 }} cars
                </span>
                <span v-else>
                  {{ formatContractAmount(progress.deliveredAmount, progress.units) }}
                  /
                  {{ formatContractAmount(progress.totalAmount, progress.units) }}
                </span>
              </div>
              <div class="contract-progress-bar-wrap">
                <div class="contract-progress-bar" :style="{ transform: `scaleX(${contractProgressPercent(progress) / 100})` }"></div>
              </div>
              <div class="contract-escrow">
                {{ progress.complete ? 'Paid' : 'Held' }}
                <span class="money"><BngUnit :money="progress.escrowedMoney || 0" /></span>
              </div>
            </div>
          </div>

          <template v-if="!contractRewardsHeld">
          <div v-if="summary.detailledList.length > 1" class="detail-control">
            <HouseSwitch v-model="cargoOverviewStore.detailedDropOff">Detailed</HouseSwitch>
          </div>

          <div class="rewards-breakdown-container padding-bottom">
            <!-- TODO - This is tabular data, would be more appropriate to use a table, and could do away with a lot of CSS -->
            <div class="grid-wrapper breakdown">
              <template v-if="summary.detailledList.length <= 1 || cargoOverviewStore.detailedDropOff">
                <div v-for="result in summary.detailledList" class="grid-row grid">
                  <h2 v-if="summary.detailledList.length > 1" class="delivery-group-name">{{ result.label }}</h2>
                  <div class="label primary">{{ $translate.instant('ui.career.cargoDropOff.basePay') }}</div>
                  <div class="rewards primary"><RewardValues :rewards="result.rewards" /></div>
                  <div class="grid-wrapper wide">
                    <div v-for="breakdown in result.breakdown" class="grid">
                      <div class="label secondary">{{ breakdown.label }}</div>
                      <div class="rewards secondary"><RewardValues :rewards="breakdown.rewards" /></div>
                    </div>
                  </div>
                </div>
              </template>
              <template v-else>
                <div class="grid-row grid" v-if="summary.simpleBreakdown.base.length">
                  <div class="label primary">{{ $translate.instant('ui.career.cargoDropOff.basePay') }}</div>
                  <div class="rewards primary"><RewardValues :rewards="summary.simpleBreakdown.base" /></div>
                </div>
                <div class="grid-row grid" v-if="summary.simpleBreakdown.bonus.length">
                  <div class="label primary">Bonuses</div>
                  <div class="rewards primary"><RewardValues :rewards="summary.simpleBreakdown.bonus" /></div>
                </div>
                <div class="grid-row grid" v-if="summary.simpleBreakdown.loaner.length">
                  <div class="label primary">Loaner Cuts</div>
                  <div class="rewards primary"><RewardValues :rewards="summary.simpleBreakdown.loaner" /></div>
                </div>
                <div class="grid-row grid" v-if="summary.simpleBreakdown.branch.length">
                  <div class="label primary">Logistics Level Multiplier</div>
                  <div class="rewards primary"><RewardValues :rewards="summary.simpleBreakdown.branch" /></div>
                </div>
              </template>
              <div class="grid-row grid" v-if="demandInfo">
                <div class="label primary">{{ $translate.instant('ui.career.cargoDropOff.includedDemand', { percent: demandInfo.pct }) }}</div>
                <div class="rewards primary demand-bonus"><BngUnit :money="demandInfo.bonusMoney" /></div>
              </div>
              <div class="grid-row grid summary">
                <div class="label primary">{{ $translate.instant('ui.career.cargoDropOff.appliedRewards') }}</div>
                <div class="rewards primary"><RewardValues :rewards="summary.total.rewards" /></div>
              </div>
            </div>
          </div>

          <!-- running totals and progress after this delivery -->
          <div class="totals">
          <div v-for="reward in summary.total.rewards">
            <div class="total-row" :class="{ 'animate-progress-background': reward.animationData.numStep != 0, bar: reward.animationData.type != 'number' }" v-if="reward.animationData.id != 'missing'">
              <BngIcon class="total-icon" v-if="reward.icon" :type="icons[reward.icon]"/>
              <div v-if="reward.animationData.type == 'number'" class="total-number">
                <div class="numberReward" v-if="reward.attributeKey == 'money'">
                  <BngUnit :money="reward.animationData.smoothedValue" no-icon />
                </div>
                <div class="numberReward" v-else-if="reward.attributeKey == 'beamXP'">
                  <BngUnit :beamXP="reward.animationData.smoothedValue" no-icon />
                </div>
                <div v-else>
                  {{ reward.animationData.smoothedValue.toFixed(2) }}
                </div>
              </div>
              <div v-else class="total-bar">
                <BngProgressBar
                  class="stat-progress-bar"
                  :headerLeft="$translate.instant(reward.animationData.name)"
                  :headerRight="reward.animationData.levelLabel"
                  :value="~~reward.animationData.displayValue"
                  :old-value="~~reward.animationData.displayValueBefore"
                  :max="reward.animationData.max"
                  :showValueLabel="true"
                  :valueColor="reward.valueColor"
                  :oldValueColor="reward.valueBeforeColor"
                  :valueLabelFormat="$translate.instant('ui.career.justXP', { cur: reward.animationData.maxLevel ? ~~reward.animationData.displayValue : '#value#' })"
                  :animate-difference="true" />
              </div>
            </div>
          </div>
          </div>
          </template>

          <div v-if="showUnloadingDelay" class="unloading">
            <span class="caption">Unloading delay</span>
            <BngProgressBar
              class="timer"
              :value="data.unloadingDelay - confirmButtonTimer"
              :max="data.unloadingDelay"
              :min="0"
              :valueLabelFormat="getNiceTime()" />
          </div>
        </div>

        <footer class="handoff-actions">
          <HouseButton class="footer-btn" :variant="rewardAnimationIndex < 0 ? 'primary' : 'neutral'" v-bng-focus-if="rewardAnimationIndex == 0" :disabled="!data.dismissImmediately && rewardAnimationIndex < 0 && !confirmButtonEnabled" @click="confirm">
            <BngBinding ui-event="ok" deviceMask="xinput" /><span>{{data.dismissImmediately || rewardAnimationIndex < 0 ? "Continue" : "Skip"}}</span>
          </HouseButton>
        </footer>
      </section>
    </div>
  </div>

</template>

<script setup>
import { createCargoRewardLevels } from './createCargoRewardLevels.js'
import { reportUiFailure } from "../utils/safeLua"

import { $translate as gameTranslate } from "@/services/translation"
import { createDeliveryTranslator } from "../utils/deliveryTranslations.js"
const $translate = createDeliveryTranslator(gameTranslate)
import { useRouteReady } from "@/services/routeReadiness"
import { BngProgressBar, BngBinding, BngUnit, BngIcon, icons } from "@/common/components/base"
import { HouseButton, HouseSlider, HouseSwitch } from "../components/house/index.js"

import RewardValues from "../components/RewardValues.vue"
import { BUILTIN_PHONE_APP_NAMES } from "../utils/builtinPhoneRoutes"

import { onMounted, ref, computed, onBeforeUnmount, watch, nextTick } from "vue"
import { vBngUiNavScroll } from "@/common/directives"
import { refocusIfLost } from "../composables/useScreenEntryFocus"
import { lua, useBridge } from "@/bridge"
import { vBngBlur, vBngOnUiNav, vBngFocusIf, vBngScopedNav } from "@/common/directives"
import { useCargoOverviewStore } from "../stores/cargoOverviewStore"
import CardGroup from "@/modules/career/components/cargoOverview/CardGroup.vue"

const ANIMATION_START_DELAY = 400
const ANIMATION_DURATION = 3000
const ANIMATION_UPDATE_RATE = 30

const BAR_COLOR_DEFAULT = '#ff6600'
const BAR_COLOR_ADDITION = '#ff6600'
const BAR_COLOR_SUBTRACTION = '#fca5a5'

const MODES = {

wait: "wait",
cargoSelection: "cargoSelection",
results: "results",
}

const cargoOverviewStore = useCargoOverviewStore()


const props = defineProps({
facilityId: String,
parkingSpotPath: String,
})

const { events } = useBridge()

const mode = ref(MODES.wait)

const data = ref({})
const summary = ref([])
const contractRewardsHeld = computed(() => !!data.value?.contractRewardsHeld)
const contractProgressList = computed(() => data.value?.contractProgress || [])
const resultSourceName = computed(() => BUILTIN_PHONE_APP_NAMES[data.value?.sourceAppId] || "Delivery")
const singleResultOffer = computed(() => data.value?.rewardOffers?.length === 1 && !data.value?.rewardParcels?.length
  ? data.value.rewardOffers[0].offer : null)
const deliveredOfferName = offer => {
  const vehicle = offer?.vehicle
  if (!vehicle?.name) return null
  return vehicle.brand && !vehicle.name.toLowerCase().includes(vehicle.brand.toLowerCase())
    ? `${vehicle.brand} ${vehicle.name}` : vehicle.name
}
const resultsHeading = computed(() => {
  if (contractRewardsHeld.value) return "Contract Progress"
  if (data.value?.contractJustCompleted) return "Contract Complete!"
  if (!data.value?.rewardOffers?.length && summary.value?.detailledList?.length === 1) {
    return summary.value.detailledList[0].label || "Delivery Complete!"
  }
  return deliveredOfferName(singleResultOffer.value) || "Delivery Complete!"
})
const resultsRoute = computed(() => {
  const route = singleResultOffer.value?.resultRoute
  const pickup = route?.pickupName && $translate.instant(route.pickupName)
  const dropOff = route?.dropOffName && $translate.instant(route.dropOffName)
  if (pickup && dropOff) return $translate.instant("ui.career.cargoDropOff.route", { pickup, dropOff })
  if (pickup) return $translate.instant("ui.career.cargoDropOff.pickupOnly", { pickup })
  if (dropOff) return $translate.instant("ui.career.cargoDropOff.dropOffOnly", { dropOff })
  return ""
})

const formatContractAmount = (value, units) => {
  const amount = Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
  return units ? `${amount} ${units}` : amount
}

const contractProgressPercent = progress => {
  if (!progress) return 0
  if (progress.kind === "finkHaul") {
    const total = Math.max(1, Number(progress.totalCount) || 1)
    return Math.min(100, ((Number(progress.deliveredCount) || 0) / total) * 100)
  }
  const total = Math.max(1, Number(progress.totalAmount) || 1)
  return Math.min(100, ((Number(progress.deliveredAmount) || 0) / total) * 100)
}
const demandInfo = computed(() => data.value && data.value.demandInfo ? data.value.demandInfo : null)

const showConfirmDelay = ref(false)
const confirmButtonEnabled = ref(false)
const confirmButtonTimer = ref(0)
let confirmButtonTimerId = 0
let dropOffAlive = true
const animationTimeouts = new Set()
const smoothingTimers = new Set()

function scheduleAnimation(callback, delay) {
  const id = setTimeout(() => {
    animationTimeouts.delete(id)
    if (dropOffAlive) callback()
  }, delay)
  animationTimeouts.add(id)
  return id
}

function stopSmoothing(reward) {
  clearInterval(reward.animationData.numTimer)
  smoothingTimers.delete(reward.animationData.numTimer)
}

const rewardAnimationIndex = ref(-1)
let animationSkipped = false
let showUnloadingDelay = true

const { normalizeBranchLevels, getLevelFromValue } = createCargoRewardLevels({ $translate })

// Reward levels use the same translation context as the delivery screen.

// B unwinds: in the selection step it cancels the hand-off; on the results it is Continue / Skip as before
const onBack = () => {
  if (mode.value === MODES.cargoSelection) return cancelSelection()
  confirm()
}

const confirm = () => {
if (data.value.dismissImmediately) return confirmDropOff()
if (rewardAnimationIndex.value < 0) {
  if (confirmButtonEnabled.value) {
    confirmDropOff()
  }
} else {
  skipAnimations()
}
}

const getNiceTime = () => (confirmButtonTimer.value > 0 ? confirmButtonTimer.value.toFixed(1) + "s remaining..." : "Done!")

const exit = () => {
window.bngVue.gotoGameState("play")
}

function updateDisplayValue(reward) {
if (reward.branchLevels && reward.branchLevels.length) {
  let displayData = getLevelFromValue(reward.animationData.smoothedValue, reward)
  reward.animationData.max = displayData.max
  reward.animationData.displayValue = displayData.displayValue
  reward.animationData.levelLabel = displayData.levelLabel
  reward.animationData.level = displayData.level
  reward.animationData.maxLevel = displayData.maxLevel

  let displayDataBefore = getLevelFromValue(reward.animationData.value - reward.rewardAmount, reward)

  if (displayData.level == displayDataBefore.level) {
    reward.animationData.displayValueBefore = displayDataBefore.displayValue
    if (displayData.displayValue >= displayDataBefore.displayValue) {
      reward.valueColor = BAR_COLOR_ADDITION
      reward.valueBeforeColor = BAR_COLOR_DEFAULT
    } else {
      reward.valueBeforeColor = BAR_COLOR_SUBTRACTION
      reward.valueColor = BAR_COLOR_DEFAULT
    }

  } else if (displayData.level > displayDataBefore.level) {
    reward.animationData.displayValueBefore = 0
    reward.valueColor = BAR_COLOR_ADDITION
    reward.valueBeforeColor = BAR_COLOR_DEFAULT

  } else {
    reward.animationData.displayValueBefore = displayData.max
    reward.valueColor = BAR_COLOR_DEFAULT
    reward.valueBeforeColor = BAR_COLOR_SUBTRACTION
  }
}
}

const startSmoothingValue = (reward, duration) => {
reward.animationData.numStep = ((reward.animationData.value - reward.animationData.smoothedValue) / duration) * ANIMATION_UPDATE_RATE
stopSmoothing(reward)

reward.animationData.numTimer = setInterval(() => {
  reward.animationData.smoothedValue += reward.animationData.numStep
  if (reward.animationData.numStep > 0 ? reward.animationData.smoothedValue >= reward.animationData.value : reward.animationData.smoothedValue <= reward.animationData.value) {
    lua.overhaul_career_logistics_progress.activateSound("", false)
    reward.animationData.smoothedValue = reward.animationData.value
    reward.animationData.numStep = 0
    stopSmoothing(reward)
  }
  reward.highlight = reward.animationData.numStep != 0

  updateDisplayValue(reward)
}, ANIMATION_UPDATE_RATE)
smoothingTimers.add(reward.animationData.numTimer)
}

function skipAnimations() {
for (let reward of summary.value.total.rewards) {
  if ("animationOrderIndex" in reward) {
    reward.animationData.smoothedValue = reward.animationData.value
    reward.animationData.numStep = 0
    reward.highlight = false
    stopSmoothing(reward)

    updateDisplayValue(reward)
  }
}

lua.overhaul_career_logistics_progress.activateSound("", false)
for (const id of animationTimeouts) clearTimeout(id)
animationTimeouts.clear()
rewardAnimationIndex.value = -1
animationSkipped = true

}

const rewardTypeToDurationFactor = {
money: 15000,
beamXP: 800
}

function getAnimationDuration(reward) {
if (!reward.animationData.max) {
  //rewardTypeToDurationFactor[reward.attributeKey]
  return 1000
}
return Math.max((reward.animationData.value - reward.animationData.smoothedValue) / (reward.animationData.max) * ANIMATION_DURATION, 800)
}

function startProgressBarAnimation() {
if (!dropOffAlive || animationSkipped) {
  return
}

rewardAnimationIndex.value++
for (let reward of summary.value.total.rewards) {
  if ("animationOrderIndex" in reward) {
    if (rewardAnimationIndex.value == reward.animationOrderIndex) {
      lua.overhaul_career_logistics_progress.activateSound(reward.animationData.type == "number" ? "money" : "progressBar", true)
      let duration = getAnimationDuration(reward)

      startSmoothingValue(reward, duration)

      // The payout already celebrates crossed levels through playerAttributes.
      scheduleAnimation(startProgressBarAnimation, duration + ANIMATION_START_DELAY)
      return
    }
  }
}
rewardAnimationIndex.value = -1
}

const start = () => {
lua.overhaul_career_logistics_general.setDeliveryTimePaused(true)
lua.overhaul_career_logistics_cargoScreen.requestDropOffData(props.facilityId, props.parkingSpotPath)
}

const kill = () => {
dropOffAlive = false
for (const id of animationTimeouts) clearTimeout(id)
animationTimeouts.clear()
for (const id of smoothingTimers) clearInterval(id)
smoothingTimers.clear()
lua.overhaul_career_logistics_progress.activateSound("", false)
lua.overhaul_career_logistics_general.setDeliveryTimePaused(false)
// off(name) on the shared emitter removes every listener.
events.off("SetDeliveryDropOffCargoSelection", setDropOffCargoSelection)
events.off("SetDeliveryDropOffRewardResult", setDropOffRewardResult)
cancelAnimationFrame(confirmButtonTimerId)
clearTimeout(selectionSentTimerId)
lua.overhaul_career_logistics_cargoScreen.dropOffPopupClosed(mode.value)
}

// set once the selection went to Lua: from then on the results are on their way, and leaving would skip
// the results-close hooks (pending employment, transfer HUD), so Cancel / B stay inert. confirmDropOffData
// returns nothing to the UI; when Lua rejects a stale selection (it shows a message and no results come),
// the buttons come back after a few seconds so the player is not stuck on the card.
const SELECTION_REJECT_TIMEOUT_MS = 4000
const selectionSent = ref(false)
let selectionSentTimerId = 0

const cancelSelection = () => {
  if (mode.value !== MODES.cargoSelection || selectionSent.value) return
  exit()
}

const confirmSelection = () => {
if (selectionSent.value) return
let confirmedCargoIds = []

/*
if (data.value.playerVehicleData.length) {
  data.value.playerVehicleData.forEach(vehData => {
    vehData.containers.forEach(conData => {
      conData.cargo.forEach(cargo => {
        if (cargo.amountSelector > 0) {
          if (cargo.amountSelectorPerSlot) {
            //handle like fluid
            confirmedCargoIds.push({ id: cargo.ids[0], amount: cargo.amountSelector })
          } else {
            //handle as individual IDs
            confirmedCargoIds = Array.from({ length: cargo.amountSelector }, (_, i) => ({ id: cargo.ids[i] }))
          }
        }
      })
    })
  })
}
if (data.value.vehicleData.length) value.vehicleData.forEach(veh => confirmedOfferIds.push(veh.id))
*/

data.value.customAmountPerMaterialType.forEach(info => {
  info.items.forEach(item => {
    const amount = Number(item.amountSelector) || 0
    if (amount > 0) {
      confirmedCargoIds.push({
        id: item.ids[0],
        ids: item.ids,
        amount: amount,
      })
    }
  })
})

let confirmedOfferIds = []
let confirmedDropOffs = {
  confirmedCargoIds: confirmedCargoIds,
  confirmedOfferIds: confirmedOfferIds,
}

selectionSent.value = true
clearTimeout(selectionSentTimerId)
selectionSentTimerId = setTimeout(() => {
  if (mode.value === MODES.cargoSelection) selectionSent.value = false
}, SELECTION_REJECT_TIMEOUT_MS)
lua.overhaul_career_logistics_cargoScreen.confirmDropOffData(confirmedDropOffs, props.facilityId, props.parkingSpotPath)
//exit()
}

let confirmDropOff = () => {
exit()
}

let branchInfo
function rewardMapToRewardList(rewards) {
let newRewards = []
const metaKeys = { economyMultiplier: true, moneyMultiplier: true }

for (let key in rewards) {
  if (metaKeys[key]) continue
  let amount = rewards[key]
  if (typeof amount !== "number") continue
  if (!branchInfo || !branchInfo[key]) continue
  let rewardInfo = {
    attributeKey: key,
    rewardAmount: amount,
    order: branchInfo[key].order,
    animationData: branchInfo[key].animationData,
    branchLevels: branchInfo[key].branchLevels,
    showLevelUpPopup: false,
    unlockPopupHeader: branchInfo[key].unlockPopupHeader,
    type: branchInfo[key].type
  }
  if (branchInfo[key].icon) rewardInfo.icon = branchInfo[key].icon

  newRewards.push(rewardInfo)
}

newRewards.sort((a, b) => a.order - b.order)

return newRewards
}

let cargoBySummaryId = []
const calculateSummary = () => {
// build summary data
let simpleBreakdownRewardsByType = {
  base: [],
  bonus: [],
  loaner: [],
  branch: [],
}
summary.value = {
  detailledList: [],
  total: {
    label: "Total",
    rewards: {},
  },
}

for (let id in cargoBySummaryId) {
  let group = cargoBySummaryId[id]
  let first = group.list[0]
  let totalCount = 0
  for (let cargo of group.list) {
    totalCount = totalCount + 1
  }
  let sum = {
    label: first.name,
    rewards: rewardMapToRewardList(first.originalRewards),
    breakdown: [],
  }
  for (let i = 0; i < totalCount; i++) simpleBreakdownRewardsByType["base"].push(first.originalRewards)
  if (first.breakdown.length) {
    for (let bd of first.breakdown) {
      sum.breakdown.push({
        label: bd.label,
        rewards: rewardMapToRewardList(bd.rewards),
      })
      if (bd.simpleBreakdownType) {
        if (!simpleBreakdownRewardsByType[bd.simpleBreakdownType]) {
          simpleBreakdownRewardsByType[bd.simpleBreakdownType] = []
        }
        for (let i = 0; i < totalCount; i++) simpleBreakdownRewardsByType[bd.simpleBreakdownType].push(bd.rewards)
      }
    }
  }
  for (let elem of sum.rewards) {
    elem.rewardAmount *= totalCount
  }
  for (let bd of sum.breakdown) {
    for (let elem of bd.rewards) {
      elem.rewardAmount *= totalCount
    }
  }
  sum.label = sum.label + " x" + totalCount
  if (totalCount > 0) {
    summary.value.detailledList.push(sum)
  }
}
if (data.value.rewardOffers.length) {
  for (let veh of data.value.rewardOffers) {
    let sum = {
      label: deliveredOfferName(veh.offer) || "Delivery",
      rewards: rewardMapToRewardList(veh.originalRewards),
      breakdown: [],
    }
    simpleBreakdownRewardsByType["base"].push(veh.originalRewards)
    if (veh.breakdown.length)
      for (let bd of veh.breakdown) {
        sum.breakdown.push({
          label: bd.label,
          rewards: rewardMapToRewardList(bd.rewards),
        })
        if (bd.simpleBreakdownType) {
          if (!simpleBreakdownRewardsByType[bd.simpleBreakdownType]) {
            simpleBreakdownRewardsByType[bd.simpleBreakdownType] = []
          }
          simpleBreakdownRewardsByType[bd.simpleBreakdownType].push(bd.rewards)
        }
      }
    summary.value.detailledList.push(sum)
  }
}

//complete simple breakdown by transforming into proper data type
for (let type in simpleBreakdownRewardsByType) {
  let sum = {}
  for (let elem of simpleBreakdownRewardsByType[type]) {
    for (let attKey in elem) {
      if (!sum[attKey]) {
        sum[attKey] = 0
      }
      sum[attKey] += elem[attKey]
    }
  }
  simpleBreakdownRewardsByType[type] = rewardMapToRewardList(sum)
}
summary.value.simpleBreakdown = simpleBreakdownRewardsByType

// Settlement owns credited totals, including escrow, canonical XP and capped reputation.
summary.value.total.rewards = rewardMapToRewardList(data.value.payoutRewards)

let counter = 0
for (let reward of summary.value.total.rewards) {
  if (reward.animationData.id != "missing") {
    reward.animationOrderIndex = counter
    reward.animationData.smoothedValue = reward.animationData.value - reward.rewardAmount
    reward.animationData.numStep = 0
    reward.highlight = false
    updateDisplayValue(reward)

    counter++
  }
}
rewardAnimationIndex.value = -1
animationSkipped = false
}

// Dropoff controls
const setDropOffCargoSelection = dd => {
data.value = dd
selectionSent.value = false
mode.value = MODES.cargoSelection
branchInfo = dd.branchInfo

if (dd.unloadingDelay > 0.1) {
  showUnloadingDelay = true
} else {
  showUnloadingDelay = false
}

if (data.value.playerVehicleData.length) {
  data.value.customAmountPerMaterialType.forEach(info => {
    let remainingFreeAmount = info.storage.capacity - info.storage.storedVolume
    info.items.sort((a,b) => a.slots-b.slots)
    info.items.forEach(item => {
        item.amountSelectorPerSlot = item.type === "fluid" || item.type === "dryBulk"  || item.type === "cement" || item.type === "cash"
        item.maxCount = item.ids.length
        if (item.amountSelectorPerSlot) item.maxCount = item.slots
        item.amountSelector = Math.max(0, Math.min(item.maxCount, remainingFreeAmount))
        remainingFreeAmount -= item.amountSelector
        item.showAmountSelector = true
        item.loadSliderMax = Math.min(item.maxCount, info.storage.capacity - info.storage.storedVolume)
    })


    info.meta = {
      type:"container",
      usedCargoSlots: info.storage.storedVolume,
      totalCargoSlots: info.storage.capacity,
      fillPercent: info.storage.storedVolume / info.storage.capacity,
      icon:info.material.icon
    }

    info.meta.usedCargoSlots = info.storage.storedVolume
    info.items.forEach(item => {
      info.meta.usedCargoSlots += item.amountSelector
    })
    info.meta.fillPercentHighlight = info.meta.usedCargoSlots / info.storage.capacity
    if(info.storage.capacity <= info.storage.storedVolume) {
      info.isFull = true
    }
  })
}

//calculateSummary()
}
events.on("SetDeliveryDropOffCargoSelection", setDropOffCargoSelection)


const adjustAmount = (info, item, direction) => {
  item.amountSelector = Math.max(0, Math.min(Number(item.loadSliderMax) || 0, (Number(item.amountSelector) || 0) + direction))
  updateSliderAmounts(info, item)
}

const updateSliderAmounts = (info, changedItem) => {
info.meta.usedCargoSlots = info.storage.storedVolume
info.items.forEach(item => {
  info.meta.usedCargoSlots += item.amountSelector
})
let tooMuch = info.meta.usedCargoSlots - info.meta.totalCargoSlots
if(tooMuch > 0) {
  info.items.reverse()
  info.items.forEach(item => {
    //item.loadSliderMax = Math.min(item.maxCount, item.amountSelector + remainingFreeAmount)
    if(item !== changedItem) {
      let before = item.amountSelector
      item.amountSelector = Math.max(0, item.amountSelector - tooMuch)
      let diff = item.amountSelector - before
      tooMuch += diff
    }
  })
  info.items.reverse()
}
info.meta.usedCargoSlots = info.storage.storedVolume
info.items.forEach(item => {
  info.meta.usedCargoSlots += item.amountSelector
})
info.meta.fillPercentHighlight = info.meta.usedCargoSlots / info.storage.capacity
}


const setDropOffRewardResult = dd => {

data.value = dd
branchInfo = dd.branchInfo
mode.value = MODES.results
confirmButtonEnabled.value = true
showConfirmDelay.value = false
if (!dd.dismissImmediately && dd.unloadingDelay > 0.1) {
  confirmButtonEnabled.value = false
  confirmButtonTimer.value = dd.unloadingDelay
  showConfirmDelay.value = true

  // start a countdown timer
  const endTime = Date.now() + confirmButtonTimer.value * 1000
  const countdown = () => {
    const timeLeft = (endTime - Date.now()) / 1000
    if (timeLeft > 0) {
      confirmButtonTimer.value = timeLeft
      confirmButtonTimerId = requestAnimationFrame(countdown)
    } else {
      confirmButtonTimer.value = 0
      confirmButtonEnabled.value = true
    }
  }
  confirmButtonTimerId = requestAnimationFrame(countdown)
  showUnloadingDelay = true
} else {
  showUnloadingDelay = false
}
if (dd.rewardParcels.length) {
  for (let cargo of dd.rewardParcels) {
    if (!cargoBySummaryId[cargo.summaryId]) cargoBySummaryId[cargo.summaryId] = { list: [], display: {} }
    cargoBySummaryId[cargo.summaryId].list.push(cargo)
  }
}
calculateSummary()
if (dd.dismissImmediately) {
  skipAnimations()
} else if (!dd.contractRewardsHeld) {
  scheduleAnimation(startProgressBarAnimation, ANIMATION_START_DELAY)
} else {
  rewardAnimationIndex.value = -1
}
}
events.on("SetDeliveryDropOffRewardResult", setDropOffRewardResult)

// Controller entry for each step (this screen has no scope, so nothing is focused by itself): the
// footer's primary button, which carries the A glyph; v-bng-focus-if only fires when a reward
// animation plays
const pickFooterPrimary = () =>
  document.querySelector(".cargo-drop-off-wrapper .handoff-actions .footer-btn:not(.cancel-btn):not([disabled])")
watch(mode, () => refocusIfLost(pickFooterPrimary), { flush: "post" })
// a rejected selection re-enables the footer; the disabled Confirm had dropped focus
watch(selectionSent, sent => { if (!sent) refocusIfLost(pickFooterPrimary) }, { flush: "post" })
watch(confirmButtonEnabled, enabled => {
  if (enabled) refocusIfLost(pickFooterPrimary)
}, { flush: "post" })

useRouteReady({
  async waitUntilReady() {
    if (mode.value === MODES.wait) {
      await new Promise(resolve => {
        const stop = watch(mode, nextMode => {
          if (nextMode === MODES.wait) return
          stop()
          resolve()
        })
      })
    }
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
})

onMounted(start)
onBeforeUnmount(kill)
</script>

<script>
import { popupPosition, popupContainer } from "@/services/popup"
export default {
wrapper: {
  fade: true, // everything but popup will fade away (become semi-transparent and desaturated)
  blur: true, // fullscreen in-game blur
  style: popupContainer.transparent, // can be multiple in array
},
position: [popupPosition.center, popupPosition.center], // can be single w/o array
}
</script>

<style scoped lang="scss">
@use "@/styles/modules/animations" as animations;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house drop-off: one centred near-black card (like the pickups and the delivery reward),
   em off a resolution-scaled font. Unload cargo and the delivery results share the card. */
.cargo-drop-off-wrapper {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  padding: 2em;
  box-sizing: border-box;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  color: #fff;
  background: rgba(5, 8, 10, 0.55);
  overflow: auto;
}
.reward-wrapper {
  width: min(48em, 100%);
  max-height: 100%;
  min-height: 0;
  display: flex;
}
.reward-wrapper.showing-results { width: min(84em, 100%); }
.handoff-panel {
  display: flex;
  flex-direction: column;
  width: 100%;
  max-height: calc(100vh - 4em);
  min-height: 0;
  border-radius: var(--radius-control);
  overflow: hidden;
  background: rgba(21, 21, 23, 0.95);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}
.handoff-header {
  flex: 0 0 auto;
  display: grid;
  gap: 0.2em;
  padding: 1em 1.1em 0.6em;
  h1 {
    margin: 0;
    font-size: 1.45em;
    font-weight: 800;
    line-height: 1.15;
  }
}
.card-content {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 1em;
  padding: 0.4em 0.6em 1em 1.1em;
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-gutter: stable;
  // no scrollbar-width / scrollbar-color: in Chromium 121+ they override the ::-webkit-scrollbar styling
  // below and draw the native bar with arrow buttons
  &::-webkit-scrollbar { width: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
  > * { flex: 0 0 auto; }
}
.handoff-actions {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-end;
  gap: 0.6em;
  padding: 0.3em 1.1em 1em;
}
.footer-btn {
  min-width: 9em;
  &.cancel-btn { min-width: 0; }
  :deep(.btn-label) {
    display: inline-flex;
    align-items: center;
    gap: 0.4em;
  }
}
.money,
.money :deep(.info-item),
.money :deep(.value-label) {
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  --units-icon-color: var(--money);
}
.notice {
  display: flex;
  align-items: center;
  gap: 0.5em;
  margin: 0;
}
.hint {
  display: flex;
  align-items: center;
  gap: 0.4em;
  margin: 0;
}

/* ---- unload cargo: one group per material, one row per load */
.scroll-wrapper {
  display: grid;
  gap: 0.9em;
}
.fullwidth-group {
  display: grid;
  gap: 0.5em;
  :deep(.info-container .header) {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 1em;
    padding: 0;
  }
  :deep(.info-container .label) {
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }
  :deep(.cards) {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(20em, 1fr));
    gap: 0.5em;
    padding: 0;
  }
}
.group-note {
  grid-column: 1 / -1;
}
.cargo-wrapper {
  display: grid;
  gap: 0.5em;
  padding: 0.7em 0.8em 0.6em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  .header {
    display: flex;
    flex-wrap: wrap;
    gap: 0.3em 1.6em;
  }
  .fact {
    display: grid;
    gap: 0.1em;
    min-width: 0;
  }
  .fact-key {
    color: var(--faint);
    font-size: 0.68em;
    font-weight: 700;
    letter-spacing: 0.09em;
    text-transform: uppercase;
  }
  .fact-value {
    font-weight: 700;
    overflow-wrap: anywhere;
  }
}
.amount-controls {
  display: flex;
  align-items: center;
  gap: 0.4em;
  .slider {
    flex: 1 1 auto;
    min-width: 0;
  }
  .amount {
    flex: 0 0 auto;
    min-width: 5.5em;
    text-align: right;
    font-variant-numeric: tabular-nums;
    strong {
      font-size: 1.15em;
      font-weight: 800;
    }
    span {
      color: var(--faint);
      font-weight: 700;
    }
  }
}

/* ---- results: contract progress */
.contract-progress-panel {
  display: grid;
  gap: 0.8em;
}
.contract-held-note {
  margin: 0;
  color: var(--muted);
  font-weight: 600;
}
.contract-progress-row {
  display: grid;
  gap: 0.35em;
  padding: 0.7em 0.85em 0.6em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.contract-progress-header {
  display: flex;
  justify-content: space-between;
  gap: 1em;
  font-variant-numeric: tabular-nums;
  strong {
    font-weight: 800;
    overflow-wrap: anywhere;
  }
  span {
    flex: 0 0 auto;
    color: var(--muted);
    font-weight: 700;
  }
}
.contract-progress-bar-wrap {
  position: relative;
  height: 0.4em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);
}
.contract-progress-bar {
  position: absolute;
  inset: 0;
  border-radius: inherit;
  background: var(--accent);
  transform-origin: left center;
  transition: transform 0.4s ease-out;
}
.contract-escrow {
  display: flex;
  align-items: baseline;
  gap: 0.45em;
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 700;
}

/* ---- results: what was delivered + the reward breakdown (same look as the delivery reward screen) */
.detail-control { display: flex; justify-content: flex-end; }
.result-route { margin: 0; line-height: 1.5; overflow-wrap: anywhere; }
.rewards-breakdown-container {
  display: grid;
  gap: 0.5em;
}
.breakdown {
  display: grid;
  border-radius: var(--radius-panel);
  background: var(--panel);
  overflow: hidden;
}
.grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  column-gap: 1em;
  align-items: center;
}
.grid-row {
  row-gap: 0.4em;
  padding: 0.6em 0.85em 0.5em;
  border-bottom: 1px solid var(--line);
}
.delivery-group-name { grid-column: 1 / -1; margin: 0 0 0.25rem; font-size: 1.1rem; line-height: 1.4; }
.grid-row:last-child { border-bottom: 0; }
.breakdown :deep(.grid-row) {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  column-gap: 1em;
  align-items: center;
  padding: 0.6em 0.85em 0.5em;
  border-bottom: 1px solid var(--line);
}
.label { grid-column: 1 / span 1; min-width: 0; overflow-wrap: anywhere; line-height: 1.25; }
.rewards { grid-column: 1 / -1; min-width: 0; }
.primary { font-weight: 700; }
.secondary { font-weight: 600; }
.label.secondary { color: var(--text); font-size: 1em; }
.grid-row.summary { background: var(--panel); }
.grid-row.summary .label { font-size: 1.05em; }
.wide {
  grid-column: 1 / -1;
  display: grid;
  grid-template-columns: subgrid;
  row-gap: 0.3em;
}
.wide:empty { display: none; }
.wide > .grid { grid-column: 1 / -1; grid-template-columns: subgrid; }

.demand-bonus {
  color: var(--money);
  --units-icon-color: var(--money);
}

/* ---- running totals and branch / organisation progress */
.totals {
  display: grid;
  gap: 0.6em;
}
.totals > div:empty { display: none; }
.total-row {
  display: flex;
  align-items: center;
  gap: 0.6em;
  padding: 0.2em 0.2em;
  border-radius: var(--radius-tile);
  &.bar {
    align-items: flex-start;
  }
}
.total-icon {
  flex: 0 0 auto;
  width: 1.4em;
  font-size: 1.2em;
  text-align: center;
  color: var(--faint);
  .bar & {
    margin-top: 0.1em;
  }
}
.total-number {
  font-size: 1.1em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
.numberReward {
  font-weight: 800;
}
.total-bar {
  flex: 1 1 auto;
  min-width: 0;
}
.stat-progress-bar {
  position: relative;
  display: grid;
  gap: 0.45em;
  padding-bottom: 1.35em;
  font-family: inherit;
  font-size: 1em;
  font-weight: 600;
  line-height: 1.25;
  :deep(.header) {
    gap: 1em;
    align-items: baseline;
    font-style: normal;
  }
  :deep(.header-left) {
    min-width: 0;
    font-weight: 700;
    color: #fff;
  }
  :deep(.header-right) {
    flex: 0 0 auto;
    font-size: 0.85em;
    font-weight: 700;
    color: var(--muted);
  }
  :deep(.progress-bar) {
    height: 0.55em;
    border-radius: 1em;
    background-color: rgba(255, 255, 255, 0.12);
    overflow: visible;
  }
  :deep(.progress-fill),
  :deep(.second-progress-fill) {
    border-radius: 1em;
  }
  :deep(.info) {
    position: absolute;
    left: 0;
    right: 0;
    top: calc(100% + 0.5em);
    padding: 0;
    font-size: 0.82em;
    font-weight: 600;
    line-height: 1;
    white-space: nowrap;
    color: var(--muted);
    font-variant-numeric: tabular-nums;
  }
}

/* the value that is still counting up gets a soft highlight (opacity pulse only) */
@keyframes pulsingProgressBar {
  50% { opacity: 0.4; }
}
.animate-progress :deep(.progress-fill) {
  animation: pulsingProgressBar 1s ease-in-out infinite;
}
.animate-progress-background {
  background-color: rgba(255, 255, 255, 0.06);
}

.unloading {
  display: grid;
  gap: 0.4em;
  :deep(.progress-bar) {
    height: 0.45em;
    border-radius: 1em;
    background-color: rgba(255, 255, 255, 0.12);
  }
  :deep(.progress-fill) {
    border-radius: 1em;
  }
}

.unlocks-wrapper {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.5em;
}
.span2-heading {
  grid-column: 1 / -1;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint);
}
</style>
