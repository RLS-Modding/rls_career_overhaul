<template>
  <aside v-if="phase" id="street-knights-hud">
    <strong>{{ title }}</strong>
    <p v-if="phase==='finished' && reason">{{ reason }}</p>
    <template v-if="phase==='finished' && challenge">
      <button @click="run('overhaul_career_economy_streetChallenges.openResult',[],{})">View result</button>
      <button v-if="canReturnToMeet" @click="run('overhaul_career_economy_streetChallenges.returnToMeet',[],{})">Return to meet</button>
    </template>
    <div v-if="phase!=='finished'" class="lights"><i :class="{amber:['prestage','staged','green'].includes(phase)}"/><i :class="{amber:['staged','green'].includes(phase)}"/><i :class="{green:phase==='green'}"/></div>
    <button v-if="phase!=='finished'" @click="run('overhaul_career_economy_streetKnights.abandon',[],{})">Abandon race</button>
  </aside>
</template>
<script setup>
import {ref,computed,onMounted,onUnmounted} from 'vue'
import {useBridge} from '@/bridge'
import {run} from '@/bridge/libs/Lua'
const {events}=useBridge(),phase=ref(''),outcome=ref(''),reason=ref(''),challenge=ref(false),canReturnToMeet=ref(false)
const labels={approach:'Drive to the white starting line',prestage:'Roll front wheels onto the white line and stop',staged:'Wait for green',green:'GO',finished:'Race over'}
const title=computed(()=>phase.value==='finished' ? ({win:'You won',loss:'You lost',void:'Stake returned'}[outcome.value]||labels.finished) : labels[phase.value])
const update=data=>{phase.value=data.phase||'';outcome.value=data.outcome||'';reason.value=data.reason||'';challenge.value=!!data.challenge;canReturnToMeet.value=!!data.canReturnToMeet}
onMounted(()=>events.on('StreetKnightsHud',update))
onUnmounted(()=>events.off('StreetKnightsHud',update))
</script>
<style scoped>
aside{position:fixed;top:8%;left:50%;transform:translateX(-50%);z-index:9000;background:#18202bed;color:white;border:1px solid #576473;border-radius:8px;padding:16px 24px;font:16px Segoe UI;text-align:center;pointer-events:auto}.lights{display:flex;gap:14px;justify-content:center;margin:12px}i{width:20px;height:20px;border-radius:50%;background:#48515e}i.amber{background:#ffdf91}i.green{background:#82e59a}.hint{color:#ffbf94;margin:8px 0 0}button{background:#303844;color:white;border:1px solid #687483;padding:8px 14px;border-radius:4px;cursor:pointer}
</style>
