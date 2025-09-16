<template>
  <BngCard class="card-item" :class="getCargoCardClass(card)" v-bind="!detailed && { 'bng-nav-item': true, tabindex: 1 }" @click.stop>
    <!--template v-if="card.transientMoveCounts > 0 || card.spawnWhenCommitingCargo">
      <div  class="bg-gradient bg-loading">
      </div>
    </template>
    <template v-else>
      <div v-if="!card.enabled && card.disableReason && card.disableReason.type == 'locked'" class="bg-gradient bg-locked">
      </div>
      <div v-if="!card.enabled && card.disableReason && card.disableReason.type == 'expired'" class="bg-gradient bg-expired">
      </div>
      <div v-if="!card.enabled && card.disableReason && card.disableReason.type == 'noSpace'" class="bg-gradient bg-noSpace">
      </div>
      <div v-if="!card.enabled && card.disableReason && card.disableReason.type == 'limit'" class="bg-gradient bg-noSpace">
      </div>
    </template>
    <div v-if="!detailed && cargoOverviewStore.selectedCargo == card" class="bg-selected" />
    <div v-if="!detailed && cargoOverviewStore.selectedCargo == card" class="fg-selected" / -->
    <AspectRatio v-if="!detailed && card.thumbnail" class="image" :ratio="'4:3'" :external-image="card.thumbnail">
      <BngIcon v-if="!card.enabled && card.disableReason.type == 'locked'" :type="icons.lockClosed" class="icon"  />
      <!--<img v-else-if="src || externalSrc" class="icon" :src="assetURL" />-->
    </AspectRatio>
    <div :class="{ 'card-content-flex': true, 'with-actions': !detailed }">
      <div class="heading-wrapper" :class="{ 'heading-detailed': detailed }">
        <template v-if="detailed">
          <BngCardHeading :type="ribbon ? 'ribbon' : 'none'" class="card-heading">
            <template v-if="context !== ''">
              <span class="context">
                {{ context }}
              </span>
            </template>
            <div>
              <template v-if="!card.vehName">
                {{ card.name }}
              </template>
              <template v-else>
                {{ card.vehName }}
              </template>
              <!--
              <template v-if="hasIds && card.transientMoveCounts > 0 && !card.transientMove">
                 ({{card.ids.length-card.transientMoveCounts}}/{{card.ids.length}})
              </template>
            --></div>
          </BngCardHeading>
        </template>
        <template v-else>
          <div class="card-label" v-if="!card.vehName">
            {{ card.name }}
          </div>
          <div v-else class="card-label">
            {{ card.vehName }}
          </div>
        </template>
        <div class="pill pill-blue" :class="{ ['pill-orange']: isLoadingFacilityCard }">
          <BngUnit v-if="typeof rewardMoney === 'number'" class="reward-money" :money="rewardMoney" />
          <BngPropVal v-else class="reward-money" :iconType="icons.beamCurrency" :valueLabel="rewardMoney" />
          <BngPropVal v-if="hasIds && !card.transientMove" class="amount-avail" :valueLabel="'×' + card.ids.length" />
          <BngPropVal v-if="hasIds && card.transientMove" class="amount-avail" :valueLabel="'×' + card.transientMoveCounts" />
          <BngPropVal v-if="isPerUnit" class="amount-avail" :valueLabel="'/'+ (card.units || 'L')" />
          <BngPropVal v-if="card.materialType" class="amount-avail" :valueLabel="card.slots + ' L'" />
        </div>
      </div>

      <div
        v-if="!card.showAmountSelector && cargoProps.length > 0 && detailed"
        :class="{ 'body-grid': detailed, 'body-list-wrapped': !detailed, 'content-detailed': detailed }">
        <BngPropVal v-for="props in cargoProps" v-bind="props" />
      </div>

      <div
        v-if="detailed && isMoving"
        class="buttons-disabled-reason"
        :class="{'disabled-load-actions': !card.enabled || !showButtons,'footer-detailed': detailed}">
        <BngPropVal class="prop" :iconType="icons.info" :keyLabel="''" :valueLabel="'Cannot modify cargo while any vehicle is moving.'" />
      </div>
      <div
        class="load-actions-wrapper"
        :class="{
          'disabled-load-actions': !card.enabled || !showButtons,
          'footer-detailed': detailed,
          'chevrons-bg': card.transientMoveCounts > 0 || card.spawnWhenCommitingCargo || card._transientMaterialMoveAmount > 0,
        }">
        <div class="simple-props-wrapper">
          <template v-if="!detailed">
            <!--<BngIcon :type="icons.cardboardBox" class="prop" />-->
            <BngIcon class="icon" v-for="icon in propIcons" v-bind="icon" />
            <BngPropVal class="prop" v-for="props in cargoProps" v-bind="props" />
          </template>
        </div>

        <!-- wrapping the buttons themselves again so that they wrap around if there's too many -->
        <div class="load-actions-buttons" :class="{ undetailed: !detailed }" v-if="card.enabled && showButtons">
          <!-- Loading Buttons -->
          <template v-if="card.cardType == 'parcelGroup'">
            <template v-if="card.isFacilityCard">
              <BngButton
                v-if="card.transientMoveCounts != 0"
                :class="detailed ? '' : 'button-load'"
                :accent="ACCENTS.secondary"
                :icon-right="icons.undo"
                :label="detailed ? 'Clear load' : ''"
                @click="cargoOverviewStore.clearLoad(card)"
                :disabled="isMoving"
                tabindex="0" />
              <BngButton
                v-if="!(card.autoLoadLocations && card.autoLoadLocations.length == 0)"
                :class="detailed ? '' : 'button-load'"
                :accent="ACCENTS.secondary"
                :icon-right="icons.wrench"
                :label="detailed ? 'Custom load' : ''"
                @click="cargoOverviewStore.loadCargoCustom(card)"
                :disabled="isMoving"
                tabindex="0" />
              <BngButton
                v-if="!(card.transientMoveCounts == card.ids.length || card.autoLoadLocations.length == 0 || !card.autoLoadLocations.length)"
                :class="detailed ? '' : 'button-load'"
                :accent="ACCENTS.main"
                :icon-right="icons.arrowLargeRight"
                :label="detailed ? 'Load all' : ''"
                @click="cargoOverviewStore.loadCargoAuto(card)"
                :disabled="isMoving"
                tabindex="0" />
            </template>
            <template v-else>
              <template v-if="card.transientMoveCounts > 0">
                <BngButton
                  :class="detailed ? '' : 'button-load'"
                  :accent="ACCENTS.attention"
                  :icon-right="icons.undo"
                  :label="detailed ? 'Clear Load' : ''"
                  @click="cargoOverviewStore.clearLoad(card)"
                  :disabled="isMoving"
                  tabindex="0" />
              </template>
              <template v-else>
                <BngButton
                  :class="detailed ? '' : 'button-load'"
                  :accent="ACCENTS.attention"
                  :icon-right="icons.trashBin1"
                  :label="detailed ? 'Throw Away' : ''"
                  @click="cargoOverviewStore.throwAway(card)"
                  :disabled="isMoving"
                  tabindex="0" />
              </template>
              <BngButton
                v-if="card.materialType === undefined"
                :class="detailed ? '' : 'button-load'"
                :accent="ACCENTS.primary"
                :icon-right="icons.wrench"
                :label="detailed ? 'Custom load' : ''"
                @click="cargoOverviewStore.loadCargoCustom(card)"
                :disabled="isMoving"
                tabindex="0" />

              <BngButton
                v-if="card.materialType !== undefined && card.transientMove"
                :class="detailed ? '' : 'button-load'"
                :accent="ACCENTS.primary"
                :icon-right="icons.wrench"
                :label="detailed ? 'Custom Load' : ''"
                @click="cargoOverviewStore.modifyMaterialLoad(card)"
                :disabled="isMoving"
                tabindex="0" />
            </template>
          </template>

          <template v-if="card.isFacilityCard">
            <BngButton
              v-if="card.cardType == 'storage'"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.wrench"
              :label="detailed ? 'Custom load' : ''"
              @click="cargoOverviewStore.loadStorageCustom(card)"
              :disabled="isMoving"
              tabindex="0" />
            <BngButton
              v-if="card.cardType == 'vehicleOffer' && !card.spawnWhenCommitingCargo"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.keys1"
              :label="detailed ? 'Accept Job' : ''"
              @click="cargoOverviewStore.loadOffer(card)"
              :disabled="isMoving"
              tabindex="0" />
            <BngButton
              v-if="card.cardType == 'vehicleOffer' && card.spawnWhenCommitingCargo"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.attention"
              :icon="icons.undo"
              :label="detailed ? 'Decline Job' : ''"
              @click="cargoOverviewStore.loadOffer(card)"
              :disabled="isMoving"
              tabindex="0" />

            <BngButton
              v-if="card.cardType == 'loaner' && !card.spawnWhenCommitingCargo"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.keys1"
              :label="detailed ? 'Accept Loaner' : ''"
              @click="cargoOverviewStore.loadLoaner(card)"
              :disabled="isMoving"
              tabindex="0" />
            <BngButton
              v-if="card.cardType == 'loaner' && card.spawnWhenCommitingCargo"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.attention"
              :icon="icons.undo"
              :label="detailed ? 'Decline Loaner' : ''"
              @click="cargoOverviewStore.loadLoaner(card)"
              :disabled="isMoving"
              tabindex="0" />
          </template>
          <template v-else>
            <BngButton
              v-if="card.cardType == 'vehicleOffer' && !card.spawnWhenCommitingCargo"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.attention"
              :icon="icons.trashBin1"
              :label="detailed ? 'Abandon Job' : ''"
              @click="cargoOverviewStore.abandonOffer(card)"
              :disabled="isMoving"
              tabindex="0" />
            <BngButton
              v-if="card.cardType == 'loaner' && card.isSpawnedLoaner"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.attention"
              :icon="icons.trashBin1"
              :label="detailed ? 'Return Loaner' : ''"
              @click="cargoOverviewStore.returnLoaner(card.id)"
              :disabled="isMoving"
              tabindex="0" />
          </template>
        </div>
        <div v-if="chevronProp" class="to-load">
          <BngPropVal class="amount-load" v-bind="chevronProp" />
          <!--
          <BngPropVal v-if="alwaysShowLoadingWrapper && card.transientMoveCounts == 0"
          class="amount-load no-amount"  :valueLabel="'0 / ' + card.ids.length" />


          <BngPropVal v-if="card.transientMoveCounts > 0  && !card.materialType"
          class="amount-load" :valueLabel="card.transientMoveCounts + ' / ' + card.ids.length" />
          <BngPropVal v-if="card.transientMoveCounts > 0 && card.materialType"
          class="amount-load" :valueLabel="'Loading '+card.slots +' L'" />
          <BngPropVal v-if="card._transientMaterialMoveAmount"
          class="amount-load" :valueLabel="'Loading '+card._transientMaterialMoveAmount +' L'" />

          <BngPropVal v-if="card.spawnWhenCommitingCargo"
          class="amount-load" :iconType="icons.fastTravel" :valueLabel="'Accepted'" />-->
          <div class="chevron-arrow">
            <svg class="chevron-outer" width="100%" height="100%" xmlns="http://www.w3.org/2000/svg">
              <svg class="chevron-inner" viewBox="4 2 12 60" preserveAspectRatio="xMaxYMid slice">
                <path
                  v-if="card.transientMoveCounts === 0"
                  d="M-11 -2H1L14 32L1 66H-11V-2Z"
                  fill="rgb(var(--chevron-color))"
                  fill-opacity="var(--chevron-alpha)"
                  stroke="rgb(var(--chevron-color))"
                  stroke-width="3"
                  vector-effect="non-scaling-stroke" />
                <path
                  v-else
                  d="M-11 -2H1L14 32L1 66H-11V-2Z"
                  fill="rgb(var(--chevron-color))"
                  fill-opacity="var(--chevron-alpha)"
                  stroke="var(--bng-orange-500)"
                  stroke-width="3"
                  vector-effect="non-scaling-stroke" />
              </svg>
            </svg>
          </div>
        </div>
      </div>

      <div v-if="card.showAmountSelector">
        Selected Amount: {{ card.amountSelector }}
        <BngSlider class="slider" :min="0" :max="card.maxCount" :step="1" v-model="card.amountSelector" @valueChanged="onAmountSelectorChanged"> </BngSlider>
      </div>

      <div class="footer-grid" :class="{ 'footer-detailed': detailed }">
        <template v-if="detailed">
          <div class="modifiers" v-if="(focus === 'none' || !focus) && !hideModsAndTimer">
            <template v-for="mod in card.modifiers" v-if="!detailed">
              <BngIcon :type="icons[mod.icon]" />
            </template>
          </div>
          <div class="timer-value" v-if="card.remainingTime && (focus === 'none' || !focus) && !hideModsAndTimer">
            <template v-if="card.remainingTime.type === 'preLoad'">
              <div class="orange">Time for delivery: {{ formatTime(card.remainingTime.time, 2) }}</div>
            </template>
            <template v-if="card.remainingTime.type === 'untilDelayed'">
              Time until delivery is Delayed: {{ formatTime(card.remainingTime.time, 2) }}
            </template>
            <template v-if="card.remainingTime.type === 'untilLate'"> Time until delivery is Late: {{ formatTime(card.remainingTime.time, 2) }} </template>
            <template v-if="card.remainingTime.type === 'late'"> Delivery is late </template>
          </div>
        </template>

        <div class="timer-progress-bar" :class="{ slim: !detailed }" v-if="card.remainingTime && card.remainingTime.percent && card.isPlayerCard">
          <div class="progress-bar-fill" :style="{ width: card.remainingTime.percent * 100 + '%' }"></div>
        </div>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { useBridge } from "@/bridge"
import { BngButton, BngIcon, BngUnit, BngSlider, BngCard, BngPropVal, BngCardHeading, icons, ACCENTS } from "@/common/components/base"
import { useCargoOverviewStore } from "../../stores/cargoOverviewStore"
import { computed } from "vue"
import { AspectRatio } from "@/common/components/utility"
import { $translate } from "@/services/translation"
import { formatTime } from "@/utils/datetime"

// Define emits for event handling
const emit = defineEmits(["cargoHovered", "onAmountSelectorChanged"])
function onAmountSelectorChanged(value) {
  emit("onAmountSelectorChanged", value)
}

// Define props for the component
const props = defineProps({
  card: {
    type: Object,
    required: false,
  },
  hideProps: Boolean,
  hideModsAndTimer: Boolean,
  focus: String,
  detailed: Boolean,
  showButtons: { type: Boolean, default: true },
  alwaysShowLoadingWrapper: Boolean,
  ribbon: {
    type: Boolean,
    default: true,
  },
})

// Initialize stores and utilities
const cargoOverviewStore = useCargoOverviewStore()
const { units } = useBridge()

// Utility functions
const getCargoCardClass = card => ({
  cardRow: true,
  "bg-available": card.isFacilityCard && card.enabled,
  "bg-available-selected": card.isFacilityCard && card.enabled && cargoOverviewStore.selectedCargo === card,
  "bg-assigned": card.transientMove,
  "bg-assigned-selected": card.transientMove && cargoOverviewStore.selectedCargo === card,
  "bg-locked": card.isFacilityCard && !card.enabled,
  "bg-locked-selected": card.isFacilityCard && !card.enabled && cargoOverviewStore.selectedCargo === card,
  "bg-loaded": card.isPlayerCard && !card.transientMove,
  "bg-loaded-selected": card.isPlayerCard && !card.transientMove && cargoOverviewStore.selectedCargo === card,

  //"bg-loading-right": !card.transientMove && isLoadingFacilityCard.value,
  "highlight-poi-selected": !props.detailed && cargoOverviewStore.highlightedCards[card.cardId] ? true : false,
  "card-disabled": !card.enabled,
  "with-thumbnail": card.thumbnail,
  //"bg-selected": cargoOverviewStore.selectedCargo === card,
})

const pad = n => ("" + n).padStart(2, 0)

// Computed properties for pill-conditions
const rewardMoney = computed(
  () =>
    props.card.rewardMoney ||
    props.card.rewardMoneyPerUnit ||
    (props.card.loanerCut ? -(props.card.loanerCut.value * 100 - ((props.card.loanerCut.value * 100) % 1)) + "%" : undefined)
)
const hasIds = computed(() => props.card.rewardMoney && props.card.ids && props.card.ids.length > 0 && !props.card.materialType)
const isPerUnit = computed(() => props.card.rewardMoneyPerUnit)
const isLoadingFacilityCard = computed(() => {
  return props.card.transientMoveCounts > 0 || props.card.spawnWhenCommitingCargo || props.card._transientMaterialMoveAmount > 0
})

const context = computed(() => {
  if (!props.card.enabled) return "Locked"
  if (props.card.isFacilityCard) return "Available"
  if (props.card.transientMoveCounts > 0 || props.card.spawnWhenCommitingCargo || props.card._transientMaterialMoveAmount) return "Assigned"
  return "Loaded"
})

const isMoving = computed(() => {
  return cargoOverviewStore.cargoData.player.isMoving
})

const chevronProp = computed(() => {
  let card = props.card
  if (card.isPlayerCard) return

  if (card.cardType === "parcelGroup") {
    if (card.materialType) {
      return card.transientMoveCounts > 0 || props.alwaysShowLoadingWrapper
        ? {
            class: card.transientMoveCounts == 0 ? "amount-load no-load" : "amount-load",
            valueLabel: card.slots + "L",
          }
        : undefined
    } else {
      return card.transientMoveCounts > 0 || props.alwaysShowLoadingWrapper
        ? {
            class: card.transientMoveCounts == 0 ? "amount-load no-load" : "amount-load",
            valueLabel: card.transientMoveCounts + " / " + card.ids.length,
          }
        : undefined
    }
  } else if (card.cardType === "vehicleOffer") {
    return card.spawnWhenCommitingCargo
      ? {
          class: "amount-load",
          valueLabel: "Accepted",
          iconType: icons.fastTravel,
        }
      : undefined
  } else if (card.cardType === "storage") {
    return card._transientMaterialMoveAmount > 0 || props.alwaysShowLoadingWrapper
      ? {
          class: card._transientMaterialMoveAmount == 0 ? "amount-load no-load" : "amount-load",
          valueLabel: card._transientMaterialMoveAmount + "L / " + card.storage.storedVolume + "L",
        }
      : undefined
  }
  return undefined
})

const propIcons = computed(() => {
  const res = []
  const card = props.card
  if (props.detailed) return res

  if (card.enabled && card.modifiers && card.modifiers.length) {
    for (let mod of card.modifiers) {
      if (mod.important) {
        res.push({
          type: icons[mod.icon],
          color: "var(--bng-orange-300)",
        })
      }
    }
  }
  if (card.disableReason && card.disableReason.type === "locked") {
    res.push({
      type: icons.lockClosed,
      color: "var(--bng-add-red-300)",
    })
  }
  return res
})

// Computed cargo properties and conditions

// For LUA back-end
// const cargoProps = computed(() => Array.isArray(PROPS) ? PROPS : [])

const cargoProps = computed(() => {
  const res = []
  const card = props.card
  const detailed = props.detailed
  const focus = props.focus
  const $tt = $translate.instant
  const $ctx_t = $translate.contextTranslate
  const hideProps = props.hideProps



  /**if (detailed && card.transientMoveCounts > 0) {
    res.push({
      iconType: icons.boxPickUp01,
      valueLabel: detailed ? ('Loading ' + card.transientMoveCounts + ' of this.') : ('Loading ' + card.transientMoveCounts),
      class: '',
    })
  }
  if (detailed && card.spawnWhenCommitingCargo) {
    res.push({
      iconType: icons.boxPickUp01,
      valueLabel: detailed ? ('Bringing out at ' + card.locationName +'.') : ('Bringin out.'),
      class: 'full-width',
    })
  }**/
  if (card.isFacilityCard && !card.enabled && (!card.transientMoveCounts || card.transientMoveCounts <= 0)) {
    if (!card.disableReason) {
      res.push({
        iconType: icons.lockClosed,
        keyLabel: detailed ? "Locked..?" : "",
        valueLabel: detailed ? "Not enabled but no disablereason given!" : "Locked..?",
        class: "full-width",
        iconColor: "var(--bng-add-red-300)",
      })
    } else {
      if (card.disableReason.type === "noSpace") {
        res.push({
          iconType: icons.info,
          keyLabel: detailed ? "No Space" : "",
          valueLabel: detailed ? (card.disableReason.label ? card.disableReason.label : "Not enough space to load this.") : "No Space",
          class: "full-width red",
          iconColor: "var(--bng-add-red-300)",
        })
      }
      if (card.disableReason.type === "expired") {
        res.push({
          iconType: icons.info,
          keyLabel: detailed ? "Expired" : "",
          valueLabel: detailed ? (card.disableReason.label ? card.disableReason.label : "This offer is already expired.") : "Expired",
          class: "full-width ",
        })
      }
      if (card.disableReason.type === "limit") {
        res.push({
          iconType: icons.info,
          keyLabel: detailed ? "Limit reached" : "",
          valueLabel: detailed ? (card.disableReason.label ? card.disableReason.label : "You cannot deliver more cars at the same time.") : "Limit reached",
          class: "full-width red",
          iconColor: "var(--bng-add-red-300)",
        })
      }
    }
  }

  if (card.unlockInfo) {
    let locked = card.disableReason && card.disableReason.type == "locked"
    if (detailed || locked) {
      res.push({
        iconType: icons[card.unlockInfo.icon],
        valueLabel: detailed ? $ctx_t(card.unlockInfo.longLabel) : "",
        keyLabel: detailed ? (locked ? "Locked" : "") : $ctx_t(card.unlockInfo.shortLabel),
        class: "full-width " + (locked ? "red" : ""),
        iconColor: locked ? "var(--bng-add-red-300)" : "",
      })
    }
  }

  if (hideProps) {
    return res
  }
  if (card.nextTasks && card.nextTasks.length > 0 && (!focus || focus === "nextTasks" || detailed)) {
    for (let task of card.nextTasks) {
      res.push({
        iconType: icons[task.checked ? "checkboxOn" : "checkboxOff"],
        keyLabel: detailed ? "Next Task" : "",
        valueLabel: task.label,
        class: "full-width",
      })
    }
  }
  if (card.locationName && (!focus || focus === "location" || detailed)) {
    res.push({
      iconType: icons.locationSource,
      keyLabel: detailed ? "Location" : "",
      valueLabel: detailed ? card.locationNameLong : card.locationName,
      class: "full-width",
    })
  }
  if (card.destinationName && (!focus || focus === "destination" || detailed)) {
    res.push({
      iconType: icons.locationDestination,
      keyLabel: detailed ? "Destination" : "",
      valueLabel: detailed ? card.destinationNameLong : card.destinationName,
      class: "full-width",
    })
  }
  if (card.locations && (!focus || focus === "destination") && !detailed) {
    res.push({
      iconType: icons.mapPoint,
      valueLabel: card.locations.length + " possible Destinations",
      class: "full-width",
    })
  }
  if (card.locations && detailed) {
    if (card.locations.length == 1) {
      res.push({
        iconType: icons.locationDestination,
        keyLabel: "Destination",
        valueLabel: card.locations[0].name,
        class: "full-width",
      })
    } else {
      res.push({
        iconType: icons.location2,
        keyLabel: "Multiple Destinations",
        valueLabel: "Deliver this cargo to any of the possible destinations.",
        class: "full-width",
      })
      let destinationsList = []
      for (let location of card.locations) {
        destinationsList.push($tt(location.name)) // +  ' (' + units.buildString('distance', location.distance, 1) + ')')
      }
      //prohibit breaking of individual destinations inside the string
      destinationsList = destinationsList.map(str => str.replace(/ /g, " "))
      res.push({
        iconType: icons.mapPoint,
        keyLabel: "Possible Destinations",
        valueLabel: destinationsList.join(", "),
        class: "full-width",
      })
    }
  }
  if (card.distance && (!focus || focus === "distance" || detailed)) {
    res.push({
      iconType: icons.routeSimple,
      keyLabel: detailed ? "Distance" : "",
      valueLabel: units.buildString("distance", card.distance, 1),
      class: "",
    })
  }
  if (card.vehMileage && (!focus || focus === "vehMileage" || detailed)) {
    res.push({
      iconType: icons.odometer,
      keyLabel: detailed ? "Mileage" : "",
      valueLabel: units.buildString("distance", card.vehMileage, 1),
      class: "",
    })
  }
  if (card.weight && (!focus || focus === "weight" || detailed)) {
    res.push({
      iconType: icons.weight,
      keyLabel: detailed ? "Weight" : "",
      valueLabel: units.buildString("weight", card.weight, 1),
      class: "",
    })
  }
  if (card.density && (!focus || focus === "density" || detailed)) {
    res.push({
      iconType: icons.weight,
      keyLabel: detailed ? "Density" : "",
      valueLabel: units.buildString("weight", card.density, 2),
      class: "",
    })
  }
  if (card.storage && (!focus || focus === "storage" || detailed)) {
    res.push({
      iconType: icons.boxDropOff01,
      keyLabel: detailed ? "Available Volume" : "",
      valueLabel: (card.storage.storedVolume + (detailed ? " / " + card.storage.capacity : "")).replace(/ /g, " "), //avoid breaking the fraction into two lines
      class: "",
    })
  }
  if (card.slots && (!focus || focus === "slots" || detailed)) {
    res.push({
      iconType: icons.boxDropOff01,
      keyLabel: detailed ? "Slots" : "",
      valueLabel: card.slots,
      class: "",
    })
  }
  if (card.task && (!focus || focus === "task" || detailed)) {
    res.push({
      iconType: icons.checkboxOff,
      keyLabel: detailed ? "Task" : "",
      valueLabel: card.task,
      class: "full-width",
    })
  }
  if (card.cardType == "loaner" && (!focus || detailed)) {
    res.push({
      iconType: icons.steeringWheelSporty,
      keyLabel: detailed ? "Loaner" : "",
      valueLabel: detailed ? (card.isFacilityCard ? "This vehicle can be loaned for delivery." : "This vehicle can be used for delivery.") : "Loaner",
      class: "full-width",
    })
  }
  if (card.cardType == "loaner" && card.loanerCut && !focus && detailed) {
    res.push({
      iconType: icons.carCoins,
      keyLabel: detailed ? "Loaner Cut" : "",
      valueLabel: detailed
        ? "Organization takes " + (card.loanerCut.value * 100 - ((card.loanerCut.value * 100) % 1)) + "% of rewards earned with this loaner."
        : card.loanerCut.value * 100 - ((card.loanerCut.value * 100) % 1) + "%",
      class: "full-width",
    })
  }
  if (card.organizationName && (!focus || detailed)) {
    res.push({
      iconType: icons.peopleOutline,
      keyLabel: detailed ? "Organization" : "",
      valueLabel: $tt(card.organizationName),
      class: "",
    })
  }
  if (card.capacity && card.capacity.length) {
    for (let cap of card.capacity) {
      res.push({
        iconType: icons[cap.icon],
        keyLabel: detailed ? "Capacity" : "",
        valueLabel: detailed ? cap.labelLong : cap.labelShort,
        class: "",
      })
    }
  }
  if (detailed && card.modifiers && card.modifiers.length > 0) {
    for (let mod of card.modifiers) {
      res.push({
        iconType: icons[mod.icon],
        keyLabel: mod.label,
        valueLabel: mod.description,
        class: "full-width" + (mod.important ? " orange" : ""),
        iconColor: mod.important ? "var(--bng-orange-300)" : "",
      })
    }
  }

  return res
})
</script>

<style scoped lang="scss">
@import "@/styles/modules/mixins";

.card-item {
  :deep(.card-cnt){
    display: flex;
    flex-direction: row;
  }
  .image {
    background-position: right;
    flex: 0 0 30%;
    .icon {
      color: white;
      position: relative;
      top: 0;
      bottom: 0;
      right: 0;
      left: 0;
      font-size: 4rem;
      z-index: 100;
      text-shadow: 0 0 1rem black;
    }
  }
  height: auto;
  z-index: 0;



  box-sizing: border-box;
  border: solid 2px transparent;

  @include modify-focus($border-rad-1, 0px);

  &[bng-nav-item]:not(.card-disabled) {
    cursor: pointer;
  }

  &:hover {
    :deep(.button-load) {
      visibility: visible !important;
      opacity: 1 !important;
    }
  }
}

.with-thumbnail {
  grid-column: span 2;
}

.card-disabled {
  opacity: 0.6;
}

.with-actions {
  grid-template-columns: auto 3rem;
}
.card-content-flex {
  flex: 1 1 auto;
  z-index: 2;
  display: flex;
  flex-flow: column;
  align-items: stretch;

  // grid-auto-rows: minmax(max-content 1fr);
  // grid-template-columns: repeat(auto-fill, minmax(8rem, 1fr));
  // gap: 0.5rem;
  color: white;
  background-color: var(--bng-black-60);
  transition: all 0.15s ease-in;
  &:hover {
    background-color: #ffffff22;
    .load-actions-wrapper {
      .load-actions-buttons {
        visibility: visible !important;
        opacity: 1 !important;
      }
    }
  }
  flex: 1;

  > :not(:last-child) {
    padding-left: 1rem;
    padding-right: 0.5rem;
  }

  .heading-wrapper {
    display: flex;
    padding-left: 0rem;
    padding-right: 0.5rem;
    padding-top: 0.5rem;
    padding-bottom: 0.5rem;
    grid-template-columns: 1fr auto;

    align-items: start;
    &.heading-detailed {
      align-items: center;
    }

    flex-flow: row nowrap;
    grid-column: 1 / -1;
    grid-row: 1;
    flex: 1 0 auto;

    .card-label {
      font-weight: 700;
      font-size: 1.125em;
      flex: 1 1 auto;
      padding: 0.5rem 1rem 0;
    }
    .card-heading {
      flex: 1 1 auto;
      display: flex;
      flex-flow: row nowrap;
      position: relative;
      overflow: visible;

      .context {
        position: absolute;
        top: -0.9rem;
        font-size: 0.75rem;
        font-weight: 500;
        text-transform: uppercase;
        font-style: normal;
      }
    }
    .pill-blue {
      --pill-color: var(--bng-ter-blue-gray-800);
    }
    .pill-orange {
      --pill-color: var(--bng-orange-700) !important;
    }
    .pill {
      display: flex;
      flex-flow: row nowrap;
      align-items: stretch;

      border-radius: var(--bng-corners-1);
      border: 0.125rem solid var(--pill-color);

      font-size: 1rem;
      line-height: 1.25rem;

      :deep(.value-label) {
        font-family: "Overpass", var(--fnt-defs);
      }

      :deep(.icon) {
        --icon-size: 1.25em;
      }

      :deep(.reward-money.info-item) {
        --font-weight-value: 900;
      }

      :deep(.info-item) {
        --paddings: 0.125em 0.5em 0.125em 0.25em;
        line-height: 1.25rem;
        .value-key,
        .value-label {
          font-family: var(--fnt-defs) !important;
        }
      }

      :deep(.amount-avail) {
        background-color: var(--pill-color);
        --paddings: 0.125em 0.25em 0.125em 0.5em;
      }
    }
  }

  .buttons-disabled-reason {
    display: flex;
    justify-content: flex-end;
    padding-bottom:0.5rem;

  }

  .load-actions-wrapper {
    display: flex;
    justify-content: flex-start;
    grid-column: 1 / -1;
    padding: 0 0.375rem 0.375rem;

    &.disabled-load-actions {
      background-color: 3333;
    }

    .simple-props-wrapper {
      flex: 1 1 auto;
      padding-left: 0.5rem;
      .prop {
        padding-right: 0.15rem;
      }
      .icon {
        align-self: baseline;
        transform: translateY(0.0625em);
        //padding-top: 0.15rem;
      }
    }

    .load-actions-buttons {
      display: flex;
      flex-flow: row wrap;
      row-gap: 0.25rem;
      align-items: baseline;
      &.undetailed {
        visibility: hidden;
        opacity: 0;
      }
      transition: all 0.1s ease-in-out;
      :deep(.bng-button) {
        padding-top: 0.1em;
        padding-bottom: 0.25em;
        margin: 0;
        &:not(:last-child) {
          margin-right: 0.4em;
        }
        .icon {
          // transform: none;
        }
      }
    }

    .to-load {
      flex: 0 0 auto;
      margin-left: 0.4rem;
      color: white;
      position: relative;

      display: flex;
      align-items: stretch;

      max-height: 1.95rem; //TODO: fix the element stretching over the whole width when the buttons wrap...

      --chevron-color: var(--bng-cool-gray-700-rgb);
      --chevron-alpha: 1;

      border-radius: 0.25rem 0 0 0.25rem;

      overflow: hidden;

      padding-right: 1.25rem;

      :deep(.amount-load) {
        display: flex;
        align-items: baseline;
        line-height: 1.5rem;
        position: relative;
        background: linear-gradient(90deg, rgba(var(--bng-orange-500-rgb), 0.25) 0%, rgba(var(--bng-orange-500-rgb), 0) 90%);
        background-color: rgba(var(--chevron-color), var(--chevron-alpha));
        --paddings: 0.125em 0 0.225em 0.75em;
        font-size: 1.15rem;
      }

      :deep(.no-amount) {
        background: none;
        background-color: rgba(var(--chevron-color), var(--chevron-alpha));
        color: gray;
      }

      .chevron-arrow {
        position: absolute;
        top: 0;
        bottom: 0;
        right: 0;
        width: 1.25rem;
        // height: 2rem;
        overflow: hidden;
        .chevron-outer {
          overflow: hidden;
        }
      }
    }
  }

  .body-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0.5rem;
    align-items: flex-start;
    padding-bottom: 0.5rem;
    padding-left: 1rem;
    padding-right: 0.5rem;
    padding-top: 0.5rem;

    flex: 1 0 auto;

    > * {
      flex: 0 1 auto;
      padding: 0.25rem 1rem 0rem 0;
      :deep(.value-label) {
        font-weight: 400;
      }
      //border-radius: var(--bng-corners-2);
      //background-color: rgba(255, 255, 255, 0.1);
    }

    .full-width {
      grid-column: 1 / -1;
    }
  }
  .red {
    :deep(.key-label) {
      color: var(--bng-add-red-200);
    }
    :deep(.value-label) {
      color: var(--bng-add-red-300);
    }
  }
  .blue {
    :deep(.key-label) {
      color: var(--bng-add-blue-100);
    }
    :deep(.value-label) {
      color: var(--bng-add-blue-300);
    }
  }

  .orange {
    :deep(.key-label) {
      color: var(--bng-orange-200);
    }
    :deep(.value-label) {
      color: var(--bng-orange-300);
    }
  }

  .body-list-wrapped {
    display: flex;
    flex-flow: row wrap;
    align-items: flex-start;
    padding-bottom: 0.5rem;
    > * {
      flex: 0 1 auto;
      padding: 0.25rem 1rem 0.5rem 0;
      :deep(.value-label) {
        font-weight: 400;
      }
    }
  }

  .footer-grid {
    display: grid;
    grid-template-columns: 1fr auto;
    //grid-template-rows: auto 0.5rem;
    align-items: baseline;

    //border-top: solid 1px #ffffff88;
    padding-top: 0.2rem;

    .modifiers {
      padding: 0.5rem 0 0.5rem 1rem;

      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(1.25rem, 1fr));
      grid-gap: 0.5rem;
    }

    .timer-value {
      padding: 0.5rem 1rem 0.5rem 0;
      font-weight: 600;
      .orange {
        color: var(--bng-orange-300);
      }
    }

    .timer-progress-bar {
      background-color: black;
      position: relative;
      grid-column: 1 / -1;
      height: 0.5rem;
      &.slim {
        height: 0.2rem;
      }

      background-color: var(--bng-orange-800);

      .progress-bar-fill {
        position: absolute;
        top: 0;
        bottom: 0;
        right: 0;
        background-color: var(--bng-orange-400);
        width: 33%;
      }
    }
  }

  .actions-grid {
    grid-column: -1 / -2;
    width: 1rem;

    .actionButton {
      height: auto;
    }
  }
}

.detail-buttons {
  display: flex;
  flex-flow: row nowrap;
  // align/justify to the right?
}

.fg-selected {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 0;
  width: 100%;
  border-radius: var(--bng-corners-2);
  z-index: 100;
  border: solid 2px rgb(255, 120, 0, 1);
  pointer-events: none;
}

.bg-assigned {
  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-orange-800-rgb), 0.55), rgba(var(--bng-orange-900-rgb), 0.55));
  }

  :deep(.pill-blue) {
    --pill-color: var(--bng-orange-600) !important;
  }
  border-width: 2px;
  border-style: dashed;
  border-color: rgba(var(--bng-orange-100-rgb), 0.5);
  //border-image: linear-gradient(to right, black 25%, rgba(0, 0, 0, 0) 25%) 2; /* Adjust the percentage and the number (5) */
}
.bg-assigned-selected {
  border-width: 2px;
  border-style: dashed;
  border-color: rgba(var(--bng-orange-200-rgb), 0.8);
  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-orange-700-rgb), 1), rgba(var(--bng-orange-800-rgb), 1));
  }
  :deep(.heading-detailed) {
    background-color: rgba(var(--bng-orange-700-rgb), 1);
  }
  :deep(.content-detailed) {
    background-image: linear-gradient(180deg, rgba(var(--bng-orange-800-rgb), 1), rgba(var(--bng-orange-900-rgb), 1));
  }
  :deep(.footer-detailed) {
    background-color: rgba(var(--bng-orange-900-rgb), 1);
  }
}

.bg-loaded {
  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-ter-blue-gray-800-rgb), 0.55), rgba(var(--bng-ter-blue-gray-900-rgb), 0.55));
  }
}

.bg-loaded-selected {
  border-width: 2px;
  border-style: solid;
  border-color: rgba(var(--bng-add-blue-600-rgb), 0.5);
  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-ter-blue-gray-700-rgb), 1), rgba(var(--bng-ter-blue-gray-800-rgb), 1));
  }
  :deep(.heading-detailed) {
    background-color: rgba(var(--bng-ter-blue-gray-700-rgb), 1);
  }
  :deep(.content-detailed) {
    background-image: linear-gradient(180deg, rgba(var(--bng-ter-blue-gray-800-rgb), 1), rgba(var(--bng-ter-blue-gray-900-rgb), 1));
  }
  :deep(.footer-detailed) {
    background-color: rgba(var(--bng-ter-blue-gray-900-rgb), 1);
  }
}

.bg-available {
  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-add-green-800-rgb), 0.55), rgba(var(--bng-add-green-900-rgb), 0.55));
  }

  :deep(.pill-blue) {
    --pill-color: var(--bng-add-green-600) !important;
  }
}
.bg-available-selected {
  border-width: 2px;
  border-style: solid;
  border-color: rgba(var(--bng-add-green-600-rgb), 0.5);

  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-add-green-700-rgb), 1), rgba(var(--bng-add-green-800-rgb), 1));
  }
  :deep(.heading-detailed) {
    background-color: rgba(var(--bng-add-green-700-rgb), 1);
  }
  :deep(.content-detailed) {
    background-image: linear-gradient(180deg, rgba(var(--bng-add-green-800-rgb), 1), rgba(var(--bng-add-green-900-rgb), 1));
  }
  :deep(.footer-detailed) {
    background-color: rgba(var(--bng-add-green-900-rgb), 1);
  }
}

.bg-locked {
  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-add-red-800-rgb), 0.55), rgba(var(--bng-add-red-900-rgb), 0.55));
  }
  :deep(.pill-blue) {
    --pill-color: var(--bng-add-red-600) !important;
  }
}
.bg-locked-selected {
  border-width: 2px;
  border-style: solid;
  border-color: rgba(var(--bng-add-red-400-rgb), 0.5);
  :deep(.card-cnt) {
    background-image: linear-gradient(180deg, rgba(var(--bng-add-red-700-rgb), 1), rgba(var(--bng-add-red-800-rgb), 1));
  }
  :deep(.heading-detailed) {
    background-color: rgba(var(--bng-add-red-700-rgb), 1);
  }
  :deep(.content-detailed) {
    background-image: linear-gradient(180deg, rgba(var(--bng-add-red-800-rgb), 1), rgba(var(--bng-add-red-900-rgb), 1));
  }
  :deep(.footer-detailed) {
    background-color: rgba(var(--bng-add-red-900-rgb), 1);
  }
}

.chevrons-bg {
  position: relative; /* Ensure the pseudo-element positions correctly */
}

.chevrons-bg::before {
  content: "";
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0.375rem;
  height: 1.9rem;
  background-image: url("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAADQSURBVHgBtZBBCsMgEEVnhOQgoYsssuhRCt30ioEuepTuiqEnUdRqKSXGSUh0/BAl/JHHPIRfpJQvf/VN0/Rd10lYJLcXs5lHOIwxF6CT1f8BWusx3NbaG/U6t8f5Tw1NAnasWdJHgBqacDnErUnAjjVL+gTArQmpIU5NlKIQNk0kgFMTCWjbFrZypF9TdA0HIt5LexLgnPuurpQaS/sEME3T2V8n/z2HYXiX9mJrPaBzqE8AnHoSALeeBADMehIAt54IUENPBIAKeiJADT0hH4NSSqH7uLBmAAAAAElFTkSuQmCC");
  background-repeat: repeat-x;
  background-size: auto 100%;
  background-position: top center;
  opacity: 0.2; /* Adjust the opacity here */
  z-index: 0; /* Place it behind the content */
}
</style>
