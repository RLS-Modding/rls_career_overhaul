<template>
  <Accordion>
    <SlotItem v-for="childSlot in children"
      ref="slotItemRefs"
      :key="childSlot.path"
      :static="!childSlot.chosenPartName || !childSlot.children || Object.keys(childSlot.children).length === 0"
      :expanded="partShoppingStore.expandedSlots[childSlot.path]"
      :path="childSlot.path"
      :slotNiceName="childSlot.slotNiceName"
      :partNiceName="childSlot.chosenPartNiceName"
    >
      <PartSubTree
        v-if="childSlot.children && Object.keys(childSlot.children).length > 0"
        :children="childSlot.children"
      />
    </SlotItem>
  </Accordion>
</template>

<script setup>
import Accordion from "../PartsAccordion.vue"
// Stays its own component because it renders itself for each nested slot level.
import { ref } from "vue"
import SlotItem from "./SlotItem.vue"
import PartSubTree from "./PartSubTree.vue"
import { usePartShoppingStore } from "../../stores/partShoppingStore"

const slotItemRefs = ref([])

const props = defineProps({
  children: Object
})

const partShoppingStore = usePartShoppingStore()

</script>

<style lang="scss" scoped>
</style>
