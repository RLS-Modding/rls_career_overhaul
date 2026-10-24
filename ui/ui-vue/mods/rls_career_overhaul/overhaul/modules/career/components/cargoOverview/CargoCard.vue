<template>
  <BngCard
    class="card-item"
    :class="getCargoCardClass(card)"
    :data-selected="isSelected || null"
    :data-highlighted="isHighlighted || null"
    v-bind="!detailed && { 'bng-nav-item': true, tabindex: 1 }"
    @click.stop>

    <AspectRatio v-if="!detailed && card.thumbnail" class="image" :ratio="'4:3'" :external-image="card.thumbnail">
      <BngIcon v-if="!card.enabled && card.disableReason.type == 'locked'" :type="icons.lockClosed" class="icon"  />

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
              </div>
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
          <BngPropVal v-else-if="rewardMoney" class="reward-money" :iconType="icons.beamCurrency" :valueLabel="rewardMoney" />
          <BngPropVal v-if="demandPct > 0" class="demand-pill" :valueLabel="'+' + demandPct + '%'" />
          <BngPropVal v-if="hasIds && !card.transientMove" class="amount-avail" :valueLabel="'×' + card.ids.length" />
          <BngPropVal v-if="hasIds && card.transientMove" class="amount-avail" :valueLabel="'×' + card.transientMoveCounts" />
          <BngPropVal v-if="isPerUnit" class="amount-avail" :valueLabel="'/'+ (card.units || 'L')" />
          <BngPropVal v-if="isPerUnit && card.rewardMoneyPerKg != null && !card.companyEmployment" class="amount-avail" :iconType="icons.beamCurrency" :valueLabel="units.beamBucks(card.rewardMoneyPerKg) + '/kg'" />
          <BngPropVal v-if="card.materialType" class="amount-avail" :valueLabel="card.slots + ' ' + (card.units || 'L')" />
        </div>
      </div>

      <div
        v-if="!card.showAmountSelector && cargoProps.length > 0 && detailed"
        v-bng-ui-nav-scroll.force="navScroll"
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

            <BngIcon class="icon" v-for="icon in propIcons" v-bind="icon" />
            <BngPropVal class="prop" v-for="props in cargoProps" v-bind="props" />
          </template>
        </div>

        <!-- wrapping the buttons themselves again so that they wrap around if there's too many -->
        <div class="load-actions-buttons" :class="{ undetailed: !detailed }" v-if="(card.enabled || card.materialContractActive) && showButtons">
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
            </template>
          </template>

          <template v-if="card.isFacilityCard">
            <BngButton
              v-if="card.cardType == 'passiveBusinessSupplyOffer'"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.boxPickUp01"
              :label="detailed ? 'Pick Up Paid Order' : ''"
              @click="openPassiveBusinessSupplyLoader(card)"
              :disabled="isMoving || !card.enabled"
              tabindex="0" />
            <BngButton
              v-if="card.cardType == 'engineShopSupplyOffer'"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.boxPickUp01"
              :label="detailed ? 'Pick Up Paid Engine Material' : ''"
              @click="openEngineShopSupplyLoader(card)"
              :disabled="isMoving || !card.enabled"
              tabindex="0" />
            <BngButton
              v-if="card.cardType == 'materialContractOffer'"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.checkboxOn"
              :label="detailed ? 'Accept Contract' : ''"
              @click="acceptMaterialContract(card.materialContractId)"
              :disabled="isMoving"
              tabindex="0" />
            <BngButton
              v-if="card.materialContractActive && card.atContractPickup"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.wrench"
              :label="detailed ? 'Open Material Loader' : ''"
              @click="openMaterialContractLoader(card)"
              :disabled="isMoving || !card.enabled"
              tabindex="0" />
            <BngButton
              v-if="card.materialContractActive && !card.atContractPickup"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.main"
              :icon="icons.routeSimple"
              :label="detailed ? 'Route to Pickup' : ''"
              @click="setMaterialContractPickupRoute(card.materialContractId)"
              :disabled="isMoving"
              tabindex="0" />
            <BngButton
              v-if="card.materialContractActive"
              :class="detailed ? '' : 'button-load'"
              :accent="ACCENTS.attention"
              :icon="icons.trashBin1"
              :label="detailed ? 'Abandon Contract' : ''"
              @click="abandonMaterialContract(card.materialContractId)"
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

      <div v-if="card.showAmountSelector" class="amount-selector">
        {{ $ctx_t({ txt: "ui.career.cargoCard.selectedAmount", context: { amount: card.amountSelector } }) }}
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
            <template v-if="card.remainingTime.type === 'offer'">
              Offer expires in: {{ formatTime(card.remainingTime.time, 2) }}
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
import { vBngUiNavScroll } from "@/common/directives"
import { $translate } from "@/services/translation"
import { formatTime } from "@/utils/datetime"
import { moneyText } from "../../utils/units"

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
  navScroll: Boolean,
  ribbon: {
    type: Boolean,
    default: true,
  },
})

// Initialize stores and utilities
const cargoOverviewStore = useCargoOverviewStore()
const { units, lua } = useBridge()

const acceptMaterialContract = contractId => lua.overhaul_career_logistics_cargoScreen.acceptMaterialContract(contractId)
const abandonMaterialContract = contractId => lua.overhaul_career_logistics_cargoScreen.abandonMaterialContract(contractId)
const setMaterialContractPickupRoute = contractId => lua.overhaul_career_logistics_cargoScreen.setMaterialContractPickupRoute(contractId)
const openMaterialContractLoader = card => lua.overhaul_career_logistics_cargoScreen.enterMaterialContractPickupScreen(card.materialContractId, card.sourceFacId, card.origin?.psPath)
const openPassiveBusinessSupplyLoader = card => lua.overhaul_career_logistics_cargoScreen.enterPassiveBusinessSupplyPickupScreen(card.sourceFacId, card.origin?.psPath)
const openEngineShopSupplyLoader = card => lua.overhaul_career_logistics_cargoScreen.enterEngineShopSupplyPickupScreen(card.sourceFacId, card.origin?.psPath)

// Selection/highlight state goes into data attributes, not :class - Vue overwrites className on class
// patches, which wipes the focus-visible class uiNavFocus adds to the focused card
const isSelected = computed(() => cargoOverviewStore.selectedCargo === props.card)
const isHighlighted = computed(() => !props.detailed && !!cargoOverviewStore.highlightedCards[props.card.cardId])

// Utility functions
const getCargoCardClass = card => ({
  cardRow: true,
  "bg-available": card.isFacilityCard && card.enabled,
  "bg-assigned": card.transientMove,
  "bg-locked": card.isFacilityCard && !card.enabled,
  "bg-loaded": card.isPlayerCard && !card.transientMove,

  //"bg-loading-right": !card.transientMove && isLoadingFacilityCard.value,
  "card-disabled": !card.enabled,
  "with-thumbnail": card.thumbnail,
  "card-detailed": props.detailed,
  //"bg-selected": cargoOverviewStore.selectedCargo === card,
})

const pad = n => ("" + n).padStart(2, 0)

const formatMaterialDestination = (location, unit = "L") => {
  let label = $translate.instant(location.name)
  if (typeof location.distance === "number" && location.distance >= 0) {
    label += ` (${units.buildString("distance", location.distance, 1)}`
    if (location.estimatedRewardPerUnit != null) {
      label += `, est. ${moneyText(units, location.estimatedRewardPerUnit)}/${unit}`
    }
    label += ")"
  }
  return label
}

// Computed properties for pill-conditions
const rewardMoney = computed(() => {
  if (props.card.companyEmployment) return undefined
  return (
    props.card.rewardMoney ||
    props.card.rewardMoneyPerUnit ||
    // the pill already carries the currency glyph
    (props.card.hourlyRate ? `${Number(props.card.hourlyRate).toLocaleString()}/hr` : undefined) ||
    (props.card.loanerCut ? -(props.card.loanerCut.value * 100 - ((props.card.loanerCut.value * 100) % 1)) + "%" : undefined)
  )
})
const demandPct = computed(() => {
  const m = Number(props.card.economyMultiplier)
  if (!Number.isFinite(m) || m < 1.10) return 0
  return Math.round((m - 1) * 100)
})
const hasIds = computed(() => props.card.rewardMoney && props.card.ids && props.card.ids.length > 0 && !props.card.materialType)
const isPerUnit = computed(() => props.card.rewardMoneyPerUnit)
const isLoadingFacilityCard = computed(() => {
  return props.card.transientMoveCounts > 0 || props.card.spawnWhenCommitingCargo || props.card._transientMaterialMoveAmount > 0
})

const context = computed(() => {
  if (props.card.materialContractActive) return "Active Contract"
  if (!props.card.enabled) return "Unavailable"
  if (props.card.cardType === "passiveBusinessSupplyOffer") return "Business Supplies"
  if (props.card.cardType === "engineShopSupplyOffer") return "Engine Materials"
  if (props.card.cardType === "materialContractOffer") return "Contract Offer"
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

// Access rows survive hideProps so locked cards still explain what prevents use.
function appendCargoAccessProperties(res, card, detailed, $ctx_t) {
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
      if (card.disableReason.type === "wrongPickup") {
        res.push({
          iconType: icons.locationSource,
          keyLabel: detailed ? "Pickup Required" : "",
          valueLabel: detailed ? card.disableReason.label : "Go to pickup",
          class: "full-width",
        })
      }
      if (card.disableReason.type === "inTransit") {
        res.push({
          iconType: icons.routeSimple,
          keyLabel: detailed ? "Cargo In Transit" : "",
          valueLabel: detailed ? card.disableReason.label : "Cargo in transit",
          class: "full-width",
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
  } else if (card.disableReason && card.disableReason.type === "locked") {
    const label = $ctx_t(card.disableReason.label) || card.disableReason.label || "Locked"
    res.push({
      iconType: icons.lockClosed,
      valueLabel: detailed ? label : "",
      keyLabel: detailed ? "Locked" : label,
      class: "full-width red",
      iconColor: "var(--bng-add-red-300)",
    })
  }
}

function appendCargoWorkProperties(res, card, detailed, focus) {
  if (card.standardLoadCount && (!focus || detailed)) {
    res.push({
      iconType: icons.boxPickUp01,
      keyLabel: detailed ? "Project Size" : "",
      valueLabel: `${card.standardLoadCount} standard loads`,
      class: "",
    })
  }
  if (card.cardType === "passiveBusinessSupplyOffer" && detailed) {
    const limits = card.supplyLimits || {}
    res.push({ iconType: icons.cardboardBox, keyLabel: "Pallet size", valueLabel: "128 slots", class: "" })
    res.push({ iconType: icons.beamCurrency, keyLabel: "Order price", valueLabel: `${Number(limits.unitCost || 0).toLocaleString()} each (already paid)`, class: "" })
    res.push({ iconType: icons.boxPickUp01, keyLabel: "Ready for pickup", valueLabel: `${limits.paidAtSupplier || 0} pallet(s)`, class: "" })
    res.push({ iconType: icons.boxPickUp01, keyLabel: "Chain capacity", valueLabel: `${limits.chainStored || 0} stored + ${limits.chainReserved || 0} reserved / ${limits.chainCapacity || 0}`, class: "full-width" })
    res.push({ iconType: icons.routeSimple, keyLabel: "Nearby vehicle space", valueLabel: `${limits.vehicleCapacity || 0} pallet(s)`, class: "" })
  }
  if (card.estimatedTrips != null && (!focus || detailed)) {
    res.push({
      iconType: icons.routeSimple,
      keyLabel: detailed ? "Estimated Trips" : "",
      valueLabel: card.estimatedTrips > 0 ? `${card.estimatedTrips} with nearby equipment` : "No compatible equipment nearby",
      class: "",
    })
  }
  if (card.estimatedStandardLoadPay && detailed && !card.companyEmployment) {
    res.push({
      iconType: icons.beamCurrency,
      keyLabel: "Standard-load Pay",
      valueLabel: Math.round(card.estimatedStandardLoadPay).toLocaleString(),
      class: "",
    })
  }
  if (card.materialContractActive && detailed) {
    const unit = card.units || "L"
    res.push({ iconType: icons.locationSource, keyLabel: "Pickup", valueLabel: card.pickupNameLong || card.pickupName, class: "full-width" })
    res.push({ iconType: icons.checkboxOn, keyLabel: "Delivered", valueLabel: `${card.deliveredAmount} ${unit}`, class: "" })
    res.push({ iconType: icons.routeSimple, keyLabel: "In Transit", valueLabel: `${card.inTransitAmount} ${unit}`, class: "" })
    res.push({ iconType: icons.boxPickUp01, keyLabel: "Remaining", valueLabel: `${card.remainingAmount} ${unit}`, class: "" })
    if (!card.companyEmployment) {
      res.push({ iconType: icons.beamCurrency, keyLabel: "Held", valueLabel: Number(card.escrowedMoney ?? card.paidMoney ?? 0).toLocaleString(), class: "" })
      res.push({ iconType: icons.beamCurrency, keyLabel: "Remaining Value", valueLabel: Number(card.remainingValue || 0).toLocaleString(), class: "" })
      res.push({ iconType: icons.warning, keyLabel: "Abandonment Fine", valueLabel: `${moneyText(units, card.abandonmentFine || 0)} (15% of undelivered value)`, class: "full-width red" })
    }
  } else if (card.cardType === "materialContractOffer" && detailed && !card.companyEmployment) {
    res.push({
      iconType: icons.warning,
      keyLabel: "Abandonment",
      valueLabel: "15% of the undelivered quoted value; completed loads remain paid.",
      class: "full-width",
    })
  }
}

function appendCargoRouteProperties(res, card, detailed, focus) {
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
        valueLabel: formatMaterialDestination(card.locations[0], card.units || "L"),
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
        destinationsList.push(formatMaterialDestination(location, card.units || "L"))
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
}

function appendCargoEquipmentProperties(res, card, detailed, focus, $tt) {
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
  if (card.cardType == "loaner" && card.hourlyRate && !focus && detailed) {
    res.push({
      iconType: icons.carCoins,
      keyLabel: detailed ? "Hourly rental" : "",
      valueLabel: detailed
        ? Number(card.hourlyRate).toLocaleString() + " per hour. No company share."
        : Number(card.hourlyRate).toLocaleString() + "/hr",
      class: "full-width",
    })
  }
  if (card.cardType == "loaner" && card.loanerCut && !card.hourlyRate && !focus && detailed) {
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
}

const cargoProps = computed(() => {
  const res = []
  const card = props.card
  const detailed = props.detailed
  const focus = props.focus
  const $tt = $translate.instant
  const $ctx_t = $translate.contextTranslate
  const hideProps = props.hideProps

  appendCargoAccessProperties(res, card, detailed, $ctx_t)
  if (hideProps) {
    return res
  }
  appendCargoWorkProperties(res, card, detailed, focus)
  appendCargoRouteProperties(res, card, detailed, focus)
  appendCargoEquipmentProperties(res, card, detailed, focus, $tt)
  return res
})
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/modules/density" as *;

.card-item {
  :deep(.card-cnt){
    display: flex;
    flex-direction: row;
  }
  &.card-detailed :deep(.card-cnt) {
    flex: 1 1 auto;
    min-height: 0;
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
.card-detailed .card-content-flex {
  min-height: 0;
  .amount-selector {
    flex: 0 0 auto;
  }
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
      flex: 0 0 auto;
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

      :deep(.demand-pill.info-item) {
        --font-weight-value: 800;
        color: #34d399;
        background: rgba(52, 211, 153, 0.15);
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
    &.footer-detailed {
      flex: 0 0 auto;
    }
  }

  .load-actions-wrapper {
    display: flex;
    justify-content: flex-start;
    grid-column: 1 / -1;
    padding: 0 0.375rem 0.375rem;

    &.footer-detailed {
      flex: 0 0 auto;
    }

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

    &.content-detailed {
      flex: 1 1 auto;
      min-height: 0;
      overflow-y: auto;
    }

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

    &.footer-detailed {
      flex: 0 0 auto;
    }

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
.bg-assigned[data-selected] {
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

.bg-loaded[data-selected] {
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
.bg-available[data-selected] {
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
.bg-locked[data-selected] {
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
