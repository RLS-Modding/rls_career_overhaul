<template>
  <div class="settings-wrapper" bng-ui-scope="cargoScreenSettings">
    <BngCard>
      <BngCardHeading type="ribbon">{{ $t("ui.career.pause.settings") }}</BngCardHeading>
      <BngCardHeading>{{ $t("ui.career.cargoOverview.facilityDisplay") }}</BngCardHeading>
      <div class="cardContent">

        <div>
          {{ $t("ui.career.cargoOverview.groupBy") }}
          <template v-for="gKey in cargoOverviewStore.selectedFilter.groupings">
            <BngButton @click="setFacilityGroupKey(gKey)" >
              {{cargoOverviewStore.cargoData.facilityCardGroupSets[gKey].label}}
            </BngButton>
          </template>
        </div>
        <div>
          {{ $t("ui.career.cargoOverview.sorting") }}
          <template v-for="sKey in cargoOverviewStore.cargoData.facilityCardGroupSets[cargoOverviewStore.facilityGroupingKey].sortings">
            <BngButton @click="setFacilitySortKey(sKey)" >
              {{cargoOverviewStore.cargoData.sortingSets[sKey].label}}
            </BngButton>
          </template>
        </div>


      </div>
      <div class="content">
        <BngCardHeading>{{ $t("ui.career.cargoOverview.myCargoDisplay") }}</BngCardHeading>
        <BngSwitch v-model="cargoOverviewStore.automaticRoute">{{ $t("ui.career.cargoOverview.automaticRoute") }}</BngSwitch>
        <div>
          {{ $t("ui.career.cargoOverview.groupBy") }}
          <template v-for="gKey in cargoOverviewStore.playerGroupings">
            <BngButton @click="setPlayerGroupKey(gKey)" >
              {{cargoOverviewStore.cargoData.playerCardGroupSets[gKey].label}}
            </BngButton>
          </template>
        </div>
        <div>
          {{ $t("ui.career.cargoOverview.sorting") }}
          <template v-for="sKey in cargoOverviewStore.cargoData.playerCardGroupSets[cargoOverviewStore.facilityGroupingKey].sortings">
            <BngButton @click="setPlayerSortKey(sKey)" >
              {{cargoOverviewStore.cargoData.sortingSets[sKey].label}}
            </BngButton>
          </template>
        </div>

        <div class="acceptButton">
          <BngButton v-bng-on-ui-nav:back,menu.asMouse :label="$t('ui.common.continue')" :accent="ACCENTS.primary" @click="acceptClickHandler" />
        </div>
      </div>
    </BngCard>
  </div>
</template>

<script setup>
import { onMounted, ref } from "vue"
import { useCargoOverviewStore } from "../../stores/cargoOverviewStore"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngSlider, BngSwitch, BngDropdown} from "@/common/components/base"
import { vBngOnUiNav } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
useUINavScope("cargoScreenSettings")
const emit = defineEmits(["return"])
const cargoOverviewStore = useCargoOverviewStore();


const facilityGrouping = ref()

const facilityGroupingItems = [
  { label: "Item one", value: 1 },
  { label: "Item two", value: 2 },
  { label: "Item three", value: 3 },
  { label: "Item four", value: 4 },
  { label: "Item five", value: 5 },
  { label: "Item six", value: 6 },
  { label: "Item seven", value: 7 },
  { label: "Item eight", value: 8 },
  { label: "Item nine", value: 9 },
  { label: "Item ten", value: 10 },
  { label: "Item eleven", value: 11 },
  { label: "Item twelve", value: 12 },
  { label: "Item thirteen", value: 13 },
  { label: "Item fourteen", value: 14 },
  { label: "Item fifteen", value: 15 },
  { label: "Item sixteen", value: 16 },
  { label: "Item seventeen", value: 17 },
  { label: "Item eighteen", value: 18 },
  { label: "Item nineteen", value: 19 },
  { label: "Item twenty", value: 20 },
]
const facilitySorting = ref()
const playerGrouping = ref()
const playerSorting = ref()


const setFacilityGroupKey = (key) => {
  cargoOverviewStore.facilityGroupingKey = key
}
const setFacilitySortKey = (key) => {
  cargoOverviewStore.facilitySortingKey = key
}

const setPlayerGroupKey = (key) => {
  cargoOverviewStore.playerGroupingKey = key
}
const setPlayerSortKey = (key) => {
  cargoOverviewStore.playerSortingKey = key
}

onMounted(() => {
})

const acceptClickHandler = () => {
  emit("return", true)
}

</script>

<script>
import { popupPosition, popupContainer } from "@/services/popup"
export default {
  wrapper: {
    fade: true, // everything but popup will fade away (become semi-transparent and desaturated)
    blur: true, // fullscreen in-game blur
    style: popupContainer.default, // can be multiple in array
  },
  position: [popupPosition.center, popupPosition.center], // can be single w/o array
}
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/modules/density" as *;

$text-color: white;

.settings-wrapper {
  color: white;
  max-width: 32em;
}

:deep(.bng-card-wrapper)  {
  --bg-opacity: 1 !important;
}

.acceptButton {
  text-align: center;
}

.cardContent {
  padding: 1em;
}

</style>
