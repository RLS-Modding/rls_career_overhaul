<!-- Shared class wording for offers and venue registration. House controls own disclosure/focus. -->
<template>
  <div class="class-details">
    <MotorsportFold :id="`${context}-${choice.id}`" :title="choice.name" :meta="format" :model-value="open" @update:model-value="open = $event">
      <p v-if="choice.description" class="ms-caption">{{ choice.description }}</p>
      <div class="sheet lines">
        <div class="line"><span><strong class="ms-body">Race format</strong><small class="ms-caption">{{ raceText }}</small></span></div>
        <div class="line"><span><strong class="ms-body">Class rules</strong><small class="ms-caption">{{ requirements }}</small></span></div>
        <div v-if="choice.cageText" class="line"><span><strong class="ms-body">Roll cage</strong><small class="ms-caption">{{ choice.cageText }} {{ choice.cageExceptionsText }}</small></span></div>
      </div>
      <MotorsportFold :id="`${context}-${choice.id}-racing`" title="Full racing rules" :model-value="racingOpen" @update:model-value="racingOpen = $event">
        <ul class="ms-caption rules">
          <li>Your best legal qualifying time sets your seed. Only the top qualifying field advances.</li>
          <li>Reaction time matters. Red lights and other fouls can disqualify a pass.</li>
          <li v-if="choice.indexSeconds">A legal opponent beats a breakout. If both break out, the smaller breakout wins.</li>
          <li>Keep your registered parts fitted. Tuning and paint changes are allowed.</li>
        </ul>
      </MotorsportFold>
    </MotorsportFold>
    <p v-if="!open" class="ms-meta summary"><strong>Requirements:</strong> {{ requirements }}</p>
  </div>
</template>

<script setup>
import { computed, ref } from 'vue'
import MotorsportFold from './MotorsportFold.vue'
const props = defineProps({ choice: { type: Object, required: true }, context: { type: String, required: true } })
const open = ref(false), racingOpen = ref(false)
// Old event snapshots may only carry separator-delimited requirement text.
const requirements = computed(() => String(props.choice.classRulesText || props.choice.requirementsText || props.choice.descriptor || 'See event requirements.').split(/\s*[\u00b7\u2022]\s*/).filter(Boolean).join('; '))
const format = computed(() => props.choice.indexSeconds ? `${Number(props.choice.indexSeconds).toFixed(2)} s index` : 'Heads-up')
const raceText = computed(() => props.choice.indexSeconds
  ? `Run ${Number(props.choice.indexSeconds).toFixed(2)} seconds or slower. A faster pass is a breakout.`
  : 'No index or breakout limit. First legal finisher wins.')
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
.class-details { min-width: 0; }
.summary { padding: .3em var(--ms-pad, var(--inset)) .65em; }
.line > span { min-width: 0; display: grid; gap: .3em; }
.rules { padding-left: 1.3em; margin: 0; display: grid; gap: .4em; }
</style>
