<template>
  <ComputerWrapper ref="wrapper" :path="[computerStore.computerData.facilityName]" title="Insurance policies" back @back="close">
    <BngCard class="insurancePoliciesListCard">
      <div class="innerList">
        <InsurancePoliciesList />
      </div>
    </BngCard>
  </ComputerWrapper>
</template>

<script setup>
import { lua } from "@/bridge"
import { onBeforeMount, onUnmounted } from "vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useInsurancePoliciesStore } from "../stores/insurancePoliciesStore"
import { BngCard } from "@/common/components/base"
import InsurancePoliciesList from "../components/insurancePolicies/insurancePoliciesList.vue"
import { useComputerStore } from "../stores/computerStore"

const computerStore = useComputerStore()
const insurancePoliciesStore = useInsurancePoliciesStore()

const start = () => {
  insurancePoliciesStore.requestInitialData()
}

const kill = () => {
  lua.extensions.hook("onExitInsurancePoliciesList")
  //insuranceStore.partInventoryClosed()
  insurancePoliciesStore.$dispose()
}

onBeforeMount(start)
onUnmounted(kill)

const close = () => {
  insurancePoliciesStore.closeMenu()
}
</script>

<style scoped lang="scss">
.insurancePoliciesListCard {
  overflow-y: hidden;
  height: 100%;
  padding: 10px;
  color: white;
  background-color: rgba(0, 0, 0, 0.9);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.2);
  }
}

.innerList {
  height: 100%;
}

.status {
  position: absolute;
  top: 0;
  right: 0;
  color: white;
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}
</style>
