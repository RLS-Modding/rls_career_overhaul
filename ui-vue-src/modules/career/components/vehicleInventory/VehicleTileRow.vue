<template>
  <div v-if="data" :class="{ 'vehicle-tile-row': true, selected, 'hover-enabled': enableHover }" role="button" v-bng-disabled="data.disabled">
    <div :class="{ preview: true, locked, small }">
      <AspectRatio v-if="thumbUrl" :ratio="'16:9'" :external-image="thumbUrl" class="preview-image">
        <div class="indicators-overlay">
          <BngIcon v-if="data.favorite" :type="icons.star" color="#fd0" v-bng-tooltip="'Favourite'" />
          <BngIcon v-if="data.delayReason === 'repair'" :type="icons.wrench" color="#fff" />
          <BngCondition v-else :integrity="partConditionAvg" :integrity-warning="data.needsRepair" :color="colour" show-tooltip />
          <div class="performance-index">
            {{ data.certificationData && data.certificationData.vehicleClass ? data.certificationData.vehicleClass.performanceIndex.toFixed(0) : 'N/A' }}
          </div>
        </div>
        <span class="lock-reason" v-if="locked">{{ locked.reason }}</span>
        <span class="lock-time" v-if="locked && locked.eta">{{ locked.eta }}</span>
      </AspectRatio>
      <span class="valueReduced" v-if="!(data.returnLoanerPermission && data.returnLoanerPermission.allow) && data.partConditionAvg < 1">Value reduced!</span>
      <InsurancePerkIcon class="not-insured-overlay" v-if="!data.isInsured" :perkIconData="{iconOnly: data.isInsured, color: 'red', smallText: 'Not insured' }" />
    </div>

    <div class="content" v-if="!data._message">
      <div class="header">
        <div class="title-section">
          <div class="name">{{ data.niceName }}</div>
        </div>
      </div>

      <div class="details">
        <div class="location-section">
          <span class="location-label">Location:</span>
          <span class="location-value">{{ location }}</span>
        </div>

        <div class="value-section" v-if="!data.returnLoanerPermission?.allow">
          <span v-if="partConditionAvg < 1" class="value-label reduced">Current Value:</span>
          <span v-else class="value-label">Value:</span>
          <BngUnit :money="data.value" />
          <div v-if="partConditionAvg < 1" class="total-value">
            Total Value: <BngUnit :money="data.valueRepaired" />
          </div>
        </div>

        <div class="insurance-section">
          <span class="insurance-label">Insurance:</span>
          <span class="insurance-value">{{ data.insuranceInfo ? data.insuranceInfo.name : "n/a" }}</span>
          <div v-if="!data.isInsured" class="warn">Not Insured!</div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  width: 100, // em
  margin: 0.25, // em, on each side
}
</script>

<script setup>
import { computed } from "vue"
import { BngCondition, BngUnit, BngIcon, icons } from "@/common/components/base"
import { AspectRatio } from "@/common/components/utility"
import { vBngDisabled, vBngTooltip } from "@/common/directives"
import InsurancePerkIcon from "@/modules/career/components/insurance/insurancePerkIcon.vue"
import { useBridge } from "@/bridge"
const { units } = useBridge()

const props = defineProps({
  data: Object,
  isTutorial: Boolean,
  selected: Boolean,
  enableHover: {
    type: Boolean,
    default: true
  },
  small: Boolean,
})

const partConditionAvg = computed(() => {
  if (!props.data) return 1
  if (props.data.partConditions) {
    const conds = Object.values(props.data.partConditions)
    return conds.reduce((i, c) => i + c.integrityValue, 0) / conds.length
  }
  return 1
})

const colour = computed(() => props.data?.config?.paints?.[0]?.baseColor ?? "#ccc")

const thumbUrl = computed(() => props.data.thumbnail ? `${props.data.thumbnail}?${props.data.dirtyDate}` : null)

const location = computed(() => {
  let res
  if (locked.value && !locked.value.location) {
    res = locked.value.reason
  } else if (props.data.niceLocation) {
    res = props.data.niceLocation
  } else if (props.data.inGarage) {
    res = "In garage"
  } else if (props.data.distance) {
    res = `${units.buildString("length", props.data.distance, 0)} away`
  } else {
    res = "Storage"
  }
  return res
})

const locked = computed(() => {
  /**
   * @type {Object}
   * @prop {string} [reason] Blocking reason
   * @prop {string} [eta] Estimated time
   * @prop {boolean} [location] If location should be processed and displayed normally
   */
  let res
  if (props.data._message) {
    res = { reason: props.data._message }
  } else if (props.data.missingFile) {
    res = { reason: "Missing File!" }
  } else if (props.data.timeToAccess) {
    const eta = `${~~(props.data.timeToAccess / 60)}:${String(~~props.data.timeToAccess % 60).padStart(2, "0")}`
    if (props.data.delayReason === "bought") {
      res = { reason: "Out for delivery", eta }
    } else if (props.data.delayReason === "repair") {
      res = { reason: "Being repaired", eta }
    } else {
      res = { reason: "Available in", eta }
    }
  } else if (props.data.needsRepair) {
    res = { reason: "Needs repair", location: true }
  }
  return res
})
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;
@use "@/styles/modules/density" as *;

.vehicle-tile-row {
  display: flex;
  flex-flow: row nowrap;
  align-items: stretch;
  padding: 0.5em;
  box-sizing: border-box;

  font-family: "Overpass", var(--fnt-defs);
  background-color: rgba(#000, 0.6);
  color: #fff;
  border-radius: var(--bng-corners-1);
  border: 1px solid rgba(255, 255, 255, 0.1);

  // Modify the focus frame radius and offset based on tile corner radius
  @include modify-focus($rad, $f-offset);

  &:focus,
  &:focus-within,
  &.hover-enabled:hover {
    background-color: rgba(var(--bng-cool-gray-700-rgb), 0.8);
  }

  &.selected {
    padding-left: 1em;
    border-left: 0.5em solid #f60;
  }


  &[disabled] {
    pointer-events: none;
    opacity: 0.5;
    > * {
      color: #aaa;
    }
  }
}

.preview {
  position: relative;
  flex: 0 0 18rem;
  width: auto;
  height: auto;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  overflow: hidden;
  border-radius: var(--bng-corners-1);
  background-color: rgba(0, 0, 0, 0.3);

  &.small {
    flex: 0 0 12rem;
  }

  .preview-image {
    width: 100%;
    height: 100%;
  }

  > .not-insured-overlay {
    position: absolute;
    top: 0.5em;
    right: 0.5em;
    padding: 0.25em 0.5em;
    border-radius: 0.25em;
    font-size: 0.8em;
    font-weight: 600;
    text-shadow: 0 0 0.2em #000;
    z-index: 10;
  }

  .indicators-overlay {
    position: absolute;
    bottom: 0.5em;
    left: 0.5em;
    display: flex;
    align-items: center;
    gap: 0.5em;
    z-index: 10;
    background-color: rgba(0, 0, 0, 0.7);
    padding: 0.25em 0.5em;
    border-radius: var(--bng-corners-1);

    .class-badge {
      background-color: rgba(90, 78, 20, 0.8);
      color: #f0a500;
      padding: 0.15em 0.4em;
      border-radius: 0.25em;
      font-size: 0.8em;
      font-weight: 600;
    }

    .performance-index {
      background-color: rgba(90, 78, 20, 0.8);
      color: #f0a500;
      padding: 0.15em 0.4em;
      border-radius: 0.25em;
      font-size: 0.8em;
      font-weight: 600;
    }
  }
}

[disabled],
.locked {
  .preview-image {
    filter: brightness(50%) saturate(50%);
  }
}

   .lock-reason,
   .lock-time {
    font-size: 1.5em;
    text-align: center;
    text-shadow: 0 0 0.5em #000;
    z-index: 5;
    position: relative;
  }
   .lock-time {
    font-size: 1.5em;
    font-weight: 200;
    letter-spacing: 0.1em;
  }
   .valueReduced {
    font-size: 1em;
    font-weight: 200;
    color: red;
    z-index: 5;
    position: relative;
  }

.content {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  padding: 0.5em 1em;
  min-width: 0; // Allow flex item to shrink below content size
  overflow: hidden; // Prevent content from overflowing
}

.header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 0.5em;
}

.title-section {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;

  .name {
    font-size: 1.4em;
    font-weight: 700;
    margin-bottom: 0.25em;
    white-space: nowrap;
    text-overflow: ellipsis;
    overflow: hidden;
    max-width: 100%;
  }
}


.details {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  flex: 1 1 auto;
}

.location-section,
.value-section,
.insurance-section {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.9em;
}

.location-label,
.value-label,
.insurance-label {
  font-weight: 600;
  color: var(--bng-cool-gray-300);
  flex: 0 0 auto;
}

.location-value,
.insurance-value {
  flex: 1 1 auto;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
}

.value-label.reduced {
  color: red;
}

.total-value {
  font-size: 0.8em;
  color: var(--bng-cool-gray-300);
  margin-top: 0.25em;
}

.warn {
  color: rgb(242, 75, 75);
  font-size: 0.8em;
  margin-left: 0.5em;
}


// Responsive adjustments
@media screen and (max-width: 768px) {
  .vehicle-tile-row {
    height: auto;
    min-height: 8em;
    flex-direction: column;

    .preview {
      flex: 0 0 8em;
      width: 100%;
    }

    .content {
      padding: 0.5em;
    }

    .details {
      flex-direction: row;
      flex-wrap: wrap;
      gap: 0.5em;
    }

    .location-section,
    .value-section,
    .insurance-section {
      flex: 1 1 50%;
      min-width: 0;
    }
  }
}
</style>
