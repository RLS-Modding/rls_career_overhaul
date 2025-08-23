<template>
  <div bng-ui-scope="cargoDropOff" v-bng-on-ui-nav:back,menu="confirm">

    <LayoutSingle
      class="layout-content-full flex-column layout-paddings layout-align-center"
      v-bng-blur
      v-if="mode !== MODES.wait">
      <div class="reward-wrapper" >
        <BngCard v-if="mode === MODES.wait">
          <CareerStatus class="career-status" />
          <BngCardHeading type="ribbon">Dropping off...</BngCardHeading>
        </BngCard>

      <BngCard v-if="mode === MODES.cargoSelection">
        <CareerStatus class="career-status" />
        <BngCardHeading type="ribbon">Dropping off...</BngCardHeading>
        <div class="card-content">
          <BngPropVal class="limited-capacity-info" :valueLabel="'This facility has limited capacity for cargo.'" :iconType="icons.info"/>
          <div class="scroll-wrapper">
            <template v-for="info in data.customAmountPerMaterialType">
              <CardGroup class="fullwidth-group" :label="info.material.name" :meta="info.meta">
                <div v-if="info.isFull">
                  <BngPropVal :valueLabel="'The storage for this material is completely filled. Come back later.'" :iconType="icons.abandon"/>
                </div>
                <template v-for="item in info.items">
                  <div class="cargo-wrapper">
                    <div class="header">
                      <BngPropVal :valueLabel="item.originName" :keyLabel="'Origin'" :iconType="icons.locationSource"/>
                      <BngPropVal :valueLabel="item.containerName" :keyLabel="'Container'" :iconType="icons.cardboardBox "/>
                    </div>
                    <div class="amount-controls">
                      <BngButton :disabled="info.isFull" class="less" :iconLeft="icons.minus" accent="text"
                      @click="less(target)">
                      </BngButton>

                      <BngSlider
                          :disabled="info.isFull"
                          class="slider"
                          :min="0"
                          :max="item.loadSliderMax"
                          v-model="item.amountSelector"
                          :step="1"
                          @change="updateSliderAmounts(info, item)"
                          />
                      <BngButton :disabled="info.isFull" class="more" :iconLeft="icons.plus" accent="text"
                      @click="more(target)">
                      </BngButton>
                      <div class="amount">
                        {{item.amountSelector}} / {{item.slots}}
                      </div>

                    </div>
                  </div>
                </template>
              </CardGroup>
            </template>
          </div>
          <!--
          <span class="span2-heading">Manual Deliveries</span>
          <div v-for="veh in data.playerVehicleData">
            <div v-for="con in veh.containers">
              <template v-for="cargo in con.cargo">
                <CargoCard v-if="cargo.showAmountSelector" :card="cargo" hideProps />

              </template>
            </div>
            <BngDivider />
            <span class="span2-heading">Mandatory Deliveries</span>
            <div v-for="veh in data.playerVehicleData">
              <div v-for="con in veh.containers">
                <template v-for="cargo in con.cargo">
                  <CargoCard v-if="!cargo.showAmountSelector" :card="cargo" hideProps />
                </template>
              </div>
            </div>
          </div>
        -->
        </div>

          <template #buttons>
            <BngButton @click="confirmSelection"><BngBinding ui-event="ok" deviceMask="xinput" /><span>Confirm Selection</span></BngButton>
          </template>
        </BngCard>
        <BngCard v-if="mode === MODES.results">
          <div class="card-content">
            <BngCardHeading type="ribbon">Delivery Complete!</BngCardHeading>

            <div style="display: flex;">
              <h3 style="float: left;">Delivered: {{ getDeliveryList() }}</h3>
              <BngSwitch v-if="summary.detailledList.length > 1" style="float: right;" v-model="cargoOverviewStore.detailedDropOff">Detailed</BngSwitch>
            </div>

            <div v-if="summary.detailledList.length <= 1 || cargoOverviewStore.detailedDropOff" class="rewards-breakdown-container padding-bottom">

              <!-- TODO - This is tabular data, would be more appropriate to use a table, and could do away with a lot of CSS -->
              <div class="grid-wrapper">
                <div v-for="result in summary.detailledList" class="grid-row grid">
                  <div class="label primary">{{ result.label }}</div>
                  <div class="rewards primary"><RewardsPills :rewards="result.rewards" /></div>
                  <div class="grid-wrapper wide">
                    <div v-for="breakdown in result.breakdown" class="grid">
                      <div class="label secondary">{{ breakdown.label }}</div>
                      <div class="rewards secondary"><RewardsPills :rewards="breakdown.rewards" /></div>
                    </div>
                  </div>
                </div>
                <BngDivider />
                <div class="grid-row grid">
                  <div class="label primary">Summary</div>
                  <div class="rewards primary"><RewardsPills :rewards="summary.total.rewards" /></div>
                </div>
              </div>
            </div>

            <div v-else class="rewards-breakdown-container padding-bottom">
              <!-- TODO - This is tabular data, would be more appropriate to use a table, and could do away with a lot of CSS -->
              <div class="grid-wrapper">
                <div class="grid-row grid" v-if="summary.simpleBreakdown.base.length">
                  <div class="label primary">Base Rewards</div>
                  <div class="rewards primary"><RewardsPills :rewards="summary.simpleBreakdown.base" /></div>
                </div>
                <div class="grid-row grid" v-if="summary.simpleBreakdown.bonus.length">
                  <div class="label primary">Bonuses</div>
                  <div class="rewards primary"><RewardsPills :rewards="summary.simpleBreakdown.bonus" /></div>
                </div>
                <div class="grid-row grid" v-if="summary.simpleBreakdown.loaner.length">
                  <div class="label primary">Loaner Cuts</div>
                  <div class="rewards primary"><RewardsPills :rewards="summary.simpleBreakdown.loaner" /></div>
                </div>
                <div class="grid-row grid" v-if="summary.simpleBreakdown.branch.length">
                  <div class="label primary">Logistics Level Multiplier</div>
                  <div class="rewards primary"><RewardsPills :rewards="summary.simpleBreakdown.branch" /></div>
                </div>
                <BngDivider />
                <div class="grid-row grid">
                  <div class="label primary">Summary</div>
                  <div class="rewards primary"><RewardsPills :rewards="summary.total.rewards" /></div>
                </div>
              </div>
            </div>

            <!-- TODO - Remove inline CSS -->
            <div v-for="reward in summary.total.rewards">
              <div :class="reward.animationData.numStep != 0 ? 'animate-progress-background' : ''" v-if="reward.animationData.id != 'missing'" style="display: flex; padding-bottom: 0.5em; padding-left: 0.2em; padding-right: 0.2em;">
                <div style="float: left;">
                  <BngIcon style="padding-top: 0.5em; padding-right: 0.3em;" v-if="reward.icon" :type="icons[reward.icon]"/>
                </div>
                <div v-if="reward.animationData.type == 'number'" style="float: left">
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
                <div
                  v-else
                  style="float: left; width: 100%; padding: 0.2em">
                  <BngProgressBar
                    :headerLeft="$t(reward.animationData.name)"
                    :headerRight="reward.animationData.levelLabel"
                    :value="~~reward.animationData.displayValue"
                    :old-value="~~reward.animationData.displayValueBefore"
                    :max="reward.animationData.max"
                    :showValueLabel="true"
                    :valueColor="reward.valueColor"
                    :oldValueColor="reward.valueBeforeColor"
                    :valueLabelFormat="reward.animationData.maxLevel ? ~~reward.animationData.displayValue + '&nbsp;XP' : '#value#&nbsp;XP'"
                    :animate-difference="true" />
                </div>
              </div>
            </div>

            <div v-if="showUnloadingDelay">
              <BngDivider />
              Unloading Delay
              <BngProgressBar
                class="timer"
                :value="data.unloadingDelay - confirmButtonTimer"
                :max="data.unloadingDelay"
                :min="0"
                :valueLabelFormat="getNiceTime()" />
            </div>
          </div>

          <template #buttons>
            <BngButton v-bng-focus-if="rewardAnimationIndex == 0" :disabled="rewardAnimationIndex < 0 && !confirmButtonEnabled" @click="confirm">
              <BngBinding deviceMask="xinput" /><span>{{rewardAnimationIndex < 0 ? "Continue" : "Skip"}}</span>
            </BngButton>
          </template>
        </BngCard>
      </div>
    </LayoutSingle>
  </div>

</template>

<script setup>
import { LayoutSingle } from "@/common/layouts"
import { BngButton, BngCard, BngCardHeading, BngDivider, BngProgressBar, BngBinding, BngSlider, BngSwitch, BngUnit, BngPropVal, BngIcon, icons } from "@/common/components/base"

import RewardsPills from "../components/progress/RewardsPills.vue"
import UnlockPopup from "../components/cargoOverview/UnlockPopup.vue"
import { CareerStatus } from "@/modules/career/components"

import { onMounted, ref, onUnmounted } from "vue"
import { lua, useBridge } from "@/bridge"
import { vBngBlur, vBngOnUiNav, vBngFocusIf } from "@/common/directives"
import UINavEvents from "@/bridge/libs/UINavEvents"
import { useUINavScope } from "@/services/uiNav"
import { addPopup } from "@/services/popup"
import CargoCard from "../components/cargoOverview/CargoCard.vue"
import { useCargoOverviewStore } from "../stores/cargoOverviewStore"
import CardGroup from "../components/cargoOverview/CardGroup.vue"
const ANIMATION_START_DELAY = 400
const ANIMATION_DURATION = 3000
const ANIMATION_UPDATE_RATE = 30

const BAR_COLOR_DEFAULT = '#ff6600'
const BAR_COLOR_ADDITION = '#ff6600'
const BAR_COLOR_SUBTRACTION = '#c00000'

const MODES = {

  wait: "wait",
  cargoSelection: "cargoSelection",
  results: "results",
}

const cargoOverviewStore = useCargoOverviewStore()

useUINavScope("cargoDropOff")

const props = defineProps({
  facilityId: String,
  parkingSpotPath: String,
})

const { events } = useBridge()

const mode = ref(MODES.wait)

const data = ref({})
const summary = ref([])

const showConfirmDelay = ref(false)
const confirmButtonEnabled = ref(false)
const confirmButtonTimer = ref(0)
let confirmButtonTimerId = 0

const rewardAnimationIndex = ref(-1)
let animationSkipped = false
let showUnloadingDelay = true

const getLevelFromValue = (value, reward) => {
  let branchLevels = reward.branchLevels
  let levelIndex = -1
  for (let i = 0; i < Object.keys(branchLevels).length; i++) {
    let levelData = branchLevels[i]
    if (levelData.requiredValue != undefined && value >= levelData.requiredValue) {
      levelIndex = i
    }
  }
  let maxLevel = !(branchLevels[levelIndex + 1] && branchLevels[levelIndex + 1].requiredValue != undefined)
  let displayValue = value - branchLevels[levelIndex].requiredValue

  return {
    min: 0,
    max: maxLevel ? displayValue : branchLevels[levelIndex + 1].requiredValue - branchLevels[levelIndex].requiredValue,
    displayValue: displayValue,
    levelLabel: reward.type == "reputation" ? branchLevels[levelIndex].label + " (Level " + (levelIndex-1) + ")" : branchLevels[levelIndex].levelLabel,
    level: levelIndex + 1,
    maxLevel: maxLevel
  }
}

const confirm = () => {
  if (rewardAnimationIndex.value < 0) {
    if (confirmButtonEnabled.value) {
      confirmDropOff()
    }
  } else {
    skipAnimations()
  }
}

const getDeliveryList = () => {
  return summary.value.detailledList.map(delivery => delivery.label).join(', ')
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
  clearInterval(reward.animationData.numTimer)

  reward.animationData.numTimer = setInterval(() => {
    reward.animationData.smoothedValue += reward.animationData.numStep
    if (reward.animationData.numStep > 0 ? reward.animationData.smoothedValue >= reward.animationData.value : reward.animationData.smoothedValue <= reward.animationData.value) {
      lua.career_modules_delivery_progress.activateSound("", false)
      reward.animationData.smoothedValue = reward.animationData.value
      reward.animationData.numStep = 0
      clearInterval(reward.animationData.numTimer)
    }
    reward.highlight = reward.animationData.numStep != 0

    updateDisplayValue(reward)
  }, ANIMATION_UPDATE_RATE)
}

async function openNewLevelPopup(reward) {
  lua.Engine.Audio.playOnce("AudioGui", "event:>UI>Career>Progress_LevelUp")
  await addPopup(UnlockPopup, { reward: reward }).promise
  startProgressBarAnimation()
}

function didPlayerLevelUp(reward) {
  let levelBefore = 0
  let levelAfter = 0
  if (reward.branchLevels && reward.branchLevels.length) {
    levelBefore = getLevelFromValue(
      reward.animationData.value - reward.rewardAmount,
      reward
    ).level
    levelAfter = getLevelFromValue(reward.animationData.value, reward).level
  }
  return levelBefore < levelAfter
}

function skipAnimations() {
  let popupsToOpen = []
  for (let reward of summary.value.total.rewards) {
    if ("animationOrderIndex" in reward) {
      reward.animationData.smoothedValue = reward.animationData.value
      reward.animationData.numStep = 0
      reward.highlight = false
      clearInterval(reward.animationData.numTimer)

      updateDisplayValue(reward)
      if (didPlayerLevelUp(reward) && reward.showLevelUpPopup) {
        popupsToOpen.push(reward)
      }
    }
  }

  lua.career_modules_delivery_progress.activateSound("", false)
  rewardAnimationIndex.value = -1
  animationSkipped = true

  for (let reward of popupsToOpen) {
    openNewLevelPopup(reward)
  }
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
  if (animationSkipped) {
    return
  }

  rewardAnimationIndex.value++
  for (let reward of summary.value.total.rewards) {
    if ("animationOrderIndex" in reward) {
      if (rewardAnimationIndex.value == reward.animationOrderIndex) {
        lua.career_modules_delivery_progress.activateSound(reward.animationData.type == "number" ? "money" : "progressBar", true)
        let duration = getAnimationDuration(reward)

        startSmoothingValue(reward, duration)

        if (didPlayerLevelUp(reward) && reward.showLevelUpPopup) {
          setTimeout(() => openNewLevelPopup(reward), duration)
        } else {
          setTimeout(startProgressBarAnimation, duration + ANIMATION_START_DELAY)
        }
        return
      }
    }
  }
  rewardAnimationIndex.value = -1
}

const start = () => {
  UINavEvents.activate()
  UINavEvents.clearFilteredEvents()
  lua.career_modules_delivery_general.setDeliveryTimePaused(true)
  lua.career_modules_delivery_cargoScreen.requestDropOffData(props.facilityId, props.parkingSpotPath)
}

const kill = () => {
  lua.career_modules_delivery_general.setDeliveryTimePaused(false)
  events.off("SetDeliveryDropOffCargoSelection")
  events.off("SetDeliveryDropOffRewardResult")
  clearInterval(confirmButtonTimerId)
  lua.career_modules_delivery_cargoScreen.dropOffPopupClosed(mode.value)
}

const confirmSelection = () => {
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
      if(item.amountSelector > 0)
        confirmedCargoIds.push({ id: item.ids[0], amount: item.amountSelector })
    })
  })

  let confirmedOfferIds = []
  let confirmedDropOffs = {
    confirmedCargoIds: confirmedCargoIds,
    confirmedOfferIds: confirmedOfferIds,
  }
  console.log(confirmedDropOffs)
  lua.career_modules_delivery_cargoScreen.confirmDropOffData(confirmedDropOffs, props.facilityId, props.parkingSpotPath)
  //exit()
}

let confirmDropOff = () => {
  exit()
}

let branchInfo
function rewardMapToRewardList(rewards) {
  let newRewards = []

  for (let key in rewards) {
    let amount = rewards[key]
    let rewardInfo = {
      attributeKey: key,
      rewardAmount: amount,
      order: branchInfo[key].order,
      animationData: branchInfo[key].animationData,
      branchLevels: branchInfo[key].branchLevels,
      showLevelUpPopup: branchInfo[key].showLevelUpPopup,
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
  let totalRewards = {}

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
        label: veh.offer.name,
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

  // totals
  for (let row of summary.value.detailledList) {
    for (let elem of row.rewards) {
      if (!totalRewards[elem.attributeKey]) totalRewards[elem.attributeKey] = 0
      totalRewards[elem.attributeKey] += elem.rewardAmount
    }
    for (let bd of row.breakdown) {
      for (let elem of bd.rewards) {
        if (!totalRewards[elem.attributeKey]) totalRewards[elem.attributeKey] = 0
        totalRewards[elem.attributeKey] += elem.rewardAmount
      }
    }
  }
  summary.value.total.rewards = rewardMapToRewardList(totalRewards)

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
          item.amountSelectorPerSlot = item.type === "fluid" || item.type === "dryBulk" || item.type === "cement" || item.type === "cash"
          item.maxCount = item.ids.length
          if (item.amountSelectorPerSlot) item.maxCount = item.slots
          item.amountSelector = ref(Math.max(0,Math.min(item.maxCount, remainingFreeAmount)))
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
  if (dd.unloadingDelay > 0.1) {
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
  setTimeout(startProgressBarAnimation, ANIMATION_START_DELAY)
}
events.on("SetDeliveryDropOffRewardResult", setDropOffRewardResult)

onMounted(start)
onUnmounted(kill)
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
@import "@/styles/modules/animations";

@keyframes pulsingProgressBar {
  50% {
    opacity: 0.4;
  }
}

.numberReward {
  font-weight: 600;
  padding-top: 0.5em;
}

.animate-progress :deep(.progress-fill) {
  animation: pulsingProgressBar 1s ease-in-out infinite;
}

.animate-progress-background {
  background-color: rgba(255, 255, 255, 0.527);
}

.padding-bottom {
  padding-bottom: 1.5rem !important;
}

.stat-progress-bar {
  font-size: 1.25rem;
  padding-bottom: 1rem;
}

.career-status {
  padding: 0;
  position: absolute;
  margin: 0.5em 0;
  right: 0;
  top: 0;
  zoom: 0.85;
}

.card-content {
  max-height: 80vh;
  padding: 1rem;

  height: 100%;
  overflow-y:auto;
  .scroll-wrapper {
  }
}

.reward-wrapper {
  position: relative;
  color: white;
  max-width: 50em;
  min-width: 42em;
  .rewards-breakdown-container {
    display: flex;
    flex-flow: row wrap;
    align-items: stretch;
    align-content: baseline;

    .grid-wrapper {
      width: 100%;
      display: grid;
      grid-template-columns: 1fr;
      grid-gap: 0.5rem; // Adjust the gap as needed

      .wide {
        grid-column: 1 / span 2;
      }
    }

    // Main Grid
    .grid {
      display: grid;
      grid-template-columns: 1fr minmax(5em, 2fr);
      grid-gap: 0.5rem; // Adjust the gap as needed
    }

    .label {
      grid-column: 1 / span 1; // Label takes the first column
    }

    .rewards {
      grid-column: 2 / span 1; // Rewards takes the second column
    }

    // Row Classes
    .primary {
      font-weight: bold;
    }

    .secondary {
      font-weight: normal;
    }
  }
}

.span2-heading {
  font-weight: 800;
  font-size: 1.3em;
  grid-column: 1 / -1;
}

.unlocks-wrapper {
  display: grid;
  grid-template-columns: 1fr 1fr;
  grid-gap: 0.5rem; // Adjust the gap as needed
  padding: 0.5rem;

  background-color: rgba(255, 255, 255, 0.15);
}

.limited-capacity-info {
  padding-bottom: 1rem;
}

.fullwidth-group {
  :deep(.cards) {
    grid-template-columns: repeat(auto-fill, minmax(20rem, 1fr));
    gap: 1rem;
    padding: 0.5rem;
  }
}

.cargo-wrapper {
  display: flex;
  flex-flow:column;
  background-color:rgba(var(--bng-ter-blue-gray-700-rgb),1);
  border-radius: var(--bng-corners-2);
  .header {
    padding: 0.5rem;
    display: flex;
    > * {
      padding-right: 2rem;
    }
  }
  .amount-controls {
    border-radius: 0 0 var(--bng-corners-2) var(--bng-corners-2);
    background-image: linear-gradient(180deg,
      rgba(var(--bng-ter-blue-gray-800-rgb),1),
      rgba(var(--bng-ter-blue-gray-900-rgb),1),
    );
    padding: 0.5rem;
    display: flex;
    .amount {
      min-width: 10rem;
      display:flex;
      align-items: center;
      justify-content: center;
      font-size: 1.25rem;
    }
  }
}
</style>
