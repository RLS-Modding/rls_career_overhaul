<template>
  <dl v-if="rewards.length" class="reward-values">
    <div v-for="reward in rewards" :key="reward.attributeKey" class="reward-value" :class="{ negative: reward.rewardAmount < 0 }">
      <dt>{{ rewardLabel(reward) }}</dt>
      <dd><BngIcon v-if="reward.attributeKey === 'money'" class="currency-icon" :type="icons.beamCurrency" /><span class="reward-amount">{{ formatRewardAmount(reward) }}</span></dd>
    </div>
  </dl>
  <p v-else class="no-change">No reward change</p>
</template>

<script setup>
import { BngIcon, icons } from "@/common/components/base"
import { useBridge } from "@/bridge"
import { $translate as gameTranslate } from "@/services/translation"
import { createDeliveryTranslator } from "../utils/deliveryTranslations.js"
const $translate = createDeliveryTranslator(gameTranslate)
const { units } = useBridge()
const formatRewardAmount = reward => reward.attributeKey === "money"
  ? units.beamBucks(reward.rewardAmount)
  : reward.rewardAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })

defineProps({ rewards: { type: Array, default: () => [] } })
const rewardLabel = reward => {
  if (reward.attributeKey === "money") return "Money"
  const name = $translate.instant(reward.animationData?.name || reward.attributeKey)
  if (reward.type === "reputation") return /reputation/i.test(name) ? name : `${name} reputation`
  if (reward.type === "xp") return /xp$/i.test(name) ? name : `${name} XP`
  return name
}
</script>

<style scoped>
.reward-values { display: grid; grid-template-columns: repeat(auto-fit, minmax(12rem, 1fr)); gap: 0.5rem 1rem; margin: 0; }
.reward-value { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; min-height: 3.5rem; box-sizing: border-box; padding: 0.5rem 0.65rem; background: rgba(255, 255, 255, 0.06); border-radius: 0.35rem; }
dt, dd { margin: 0; padding: 0; font-family: inherit; font-size: 1rem; line-height: 1.5rem; }
dt { min-width: 0; font-weight: 500; }
dd { display: flex; align-items: center; flex: 0 0 auto; gap: 0.375rem; font-weight: 700; font-variant-numeric: tabular-nums; }
.reward-amount { display: block; line-height: inherit; }
.currency-icon { display: flex; align-items: center; justify-content: center; width: 1rem; height: 1.5rem; margin: 0; padding: 0; font-size: 1rem; line-height: 1.5rem; transform: none; }
.negative { color: #fca5a5; }
.no-change { margin: 0; font-size: 1rem; line-height: 1.4; font-weight: 400; }
</style>
