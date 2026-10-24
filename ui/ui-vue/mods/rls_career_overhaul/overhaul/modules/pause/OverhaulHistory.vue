<!-- Pause menu > History > Rewards History: the stock digest fed from Overhaul's player attributes.
     Financial History has its own card (OverhaulFinancialHistory.vue). -->
<template>
  <CareerHistoryDigest class="overhaul-rewards-history" history-type="gameplay" :entries="entries" full />
</template>

<script setup>
import { onMounted, ref } from "vue"
import { lua } from "@/bridge"
import "../career/utils/installLuaBridgeFallbacks.js"
import CareerHistoryDigest from "@/modules/pause/views/content/CareerHistoryDigest.vue"

defineOptions({ name: "OverhaulHistory" })

const entries = ref([])

onMounted(async () => {
  const result = await lua.overhaul_career_economy_playerAttributes.getGameplayHistory()
  entries.value = Array.isArray(result) ? result : []
})
</script>

<style scoped>
/* The stock row lets the reward pills shrink below their content, so they slide over the
   reason text, and cuts the reason to one line. Keep pills whole and wrap the reason. */
.overhaul-rewards-history :deep(.history-reward) {
  flex: 0 0 auto;
  max-width: 60%;
}
.overhaul-rewards-history :deep(.history-reason) {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  white-space: normal;
  overflow-wrap: break-word;
}
/* Reveal the complete reason in place for mouse and keyboard/controller users.
   Keep full reasons available without relying on native browser title tooltips. */
.overhaul-rewards-history :deep(.history-row:hover .history-reason),
.overhaul-rewards-history :deep(.history-row.focus-visible .history-reason) {
  display: block;
  -webkit-line-clamp: unset;
}
</style>
