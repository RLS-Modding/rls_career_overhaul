<template>
  <ComputerWrapper :title="$translate.instant('ui.career.insurance.title')" @back="close">
    <BngCard class="insurances-card rls-house">
      <!-- a class's plans -->
      <div v-if="selectedInsuranceClassId" class="small-insurance-cards-wrapper scroll" v-bng-ui-nav-scroll.force>
        <SmallInsuranceCard
          v-for="insurance in plClassesData[selectedInsuranceClassId].insurances"
          :key="insurance.id"
          :insuranceData="insurance"
          :driverScoreData="driverScoreData" />
      </div>
      <!-- overview: the three classes, then anything left uninsured -->
      <div v-else class="cards-wrapper">
        <span class="caption">Choose a class</span>
        <div class="insurance-tiers-wrapper">
          <InsuranceTierCard
            v-for="({ classId, classData }, i) in sortedInsuranceClasses"
            :key="classId"
            :data-class-id="classId"
            :bng-scoped-nav-autofocus="i === 0 && !uninsuredOpener ? true : undefined"
            :classId="classId"
            :classData="classData"
            @select="selectInsuranceClass" />
        </div>
        <UninsuredCard
          :bng-scoped-nav-autofocus="uninsuredOpener ? true : undefined"
          :uninsuredVehsData="uninsuredVehsData"
          @open="openUninsuredVehicles" />
      </div>
    </BngCard>

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { onBeforeMount, onUnmounted, computed, ref, nextTick } from "vue"
import { BngCard, BngBinding } from "@/common/components/base"
import { addPopup } from "@/services/popup"
import { lua, useBridge } from "@/bridge"
import { $translate } from "@/services/translation"
import { useScopedNav } from "@/services/scopedNav/api"
import { vBngUiNavScroll } from "@/common/directives"
import { useScreenEntry, returnFocusToOpener } from "../composables/useScreenEntryFocus"

import SmallInsuranceCard from "../components/insurance/smallInsuranceCard.vue"
import UninsuredVehicles from "../components/insurance/uninsuredVehicles.vue"
import InsuranceTierCard from "../components/insurance/insuranceTierCard.vue"
import UninsuredCard from "../components/insurance/uninsuredCard.vue"
import ComputerWrapper from "./ComputerWrapper.vue"

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()

const { events } = useBridge()
const scopedNav = useScopedNav()

const invVehsInsurancesData = ref({})
const plClassesData = ref({})
const uninsuredVehsData = ref({})
const driverScoreData = ref({})

const selectedInsuranceClassId = ref(null)
const uninsuredOpener = ref(false)

const onInsurancesData = data => {
  invVehsInsurancesData.value = data.invVehsInsurancesData
  plClassesData.value = data.plClassesData
  uninsuredVehsData.value = data.uninsuredVehsData
  driverScoreData.value = data.driverScoreData
  // entry: the computer route's root scope (Lua targetScope) lands on the first class
  focusScreenEntry()
}
events.on("insurancesData", onInsurancesData)

// focus is asked for after the swap has rendered, or the scope would pick the cards being removed
const selectInsuranceClass = (classId) => {
  uninsuredOpener.value = false
  selectedInsuranceClassId.value = classId
  nextTick(() => scopedNav.requestCurrentScopeFocus())
}

const sortedInsuranceClasses = computed(() => {
  const classes = plClassesData.value
  if (!classes) return []

  return Object.entries(classes)
    .map(([classId, classData]) => ({ classId, classData }))
    .sort((a, b) => a.classData.priority - b.classData.priority)
})

const start = () => {
  lua.overhaul_career_repair_insurance.sendUIData()
}

const kill = () => {
  lua.extensions.hook("onExitInsurancesComputerScreen")
  // off(name) on the shared emitter removes every listener.
  events.off("insurancesData", onInsurancesData)
}

onBeforeMount(start)
onUnmounted(kill)

const close = () => {
  if (selectedInsuranceClassId.value) {
    // B leaves the class and lands back on its tile
    const classId = selectedInsuranceClassId.value
    selectedInsuranceClassId.value = null
    nextTick(() => {
      const tile = [...document.querySelectorAll(".insurance-tier-card[data-class-id]")].find(el => el.dataset.classId === classId)
      if (tile) tile.focus()
      else scopedNav.requestCurrentScopeFocus()
    })
  } else {
    lua.overhaul_career_repair_insurance.closeMenu()
  }
}

const openUninsuredVehicles = () => {
  const opener = document.activeElement
  // The stock root resumes with preferAutoFocus after the native dialog closes.
  // Make its entry target the tile that opened this popup.
  uninsuredOpener.value = true
  const popup = addPopup(UninsuredVehicles, { uninsuredData: uninsuredVehsData.value })
  popup.promise.then(() => returnFocusToOpener(() => opener))
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* House insurance overview: near-black card, em off a resolution-scaled font */
.insurances-card.rls-house {
  --bng-card-height: auto;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: fit-content;
  max-width: 94vw;
  max-height: 100%;
  margin: 0; // under the screen heading, like the other computer screens
  align-self: flex-start;
  color: #fff;
  border-radius: var(--radius-control);
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  :deep(.card-cnt) {
    min-height: 0;
    padding: 1.2em;
    background: rgba(var(--bng-off-black-rgb), 0.9);
  }
}

.cards-wrapper {
  width: min(62em, 90vw);
  display: flex;
  flex-direction: column;
  gap: 0.7em;
  min-height: 0;
}

.insurance-tiers-wrapper {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.6em;
}

/* a class's plans: side by side, scroll sideways if there are many */
.small-insurance-cards-wrapper {
  max-width: calc(94vw - 2.2em);
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  gap: 0.8em;
  max-height: 100%;
  overflow-x: auto;
  overflow-y: hidden;
  padding: 0.2em;
  > :deep(*) {
    flex: 0 0 auto; // plan cards keep their width; the row scrolls instead of squeezing them
  }
}
</style>
