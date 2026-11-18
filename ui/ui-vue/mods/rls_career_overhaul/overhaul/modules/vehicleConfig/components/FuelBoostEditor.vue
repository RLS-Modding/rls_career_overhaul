<template>
  <section class="boost-caps" aria-label="Boost control">
    <HouseSwitch row :model-value="enabled" :disabled="disabled || (!enabled && (!supported || mismatch))" @update:model-value="setEnabled">Overhaul boost override</HouseSwitch>
    <p class="note">{{ active && !supported ? 'Boost override unavailable for this hardware' : active ? 'Current owner: Overhaul' : 'Current owner: vehicle / other boost tools' }}</p>
    <p v-if="!supported" class="note">{{ supportReason || 'Needs a controllable turbo and a gearbox with fixed gears.' }}</p>
    <template v-else>
      <p class="note">{{ enabled ? 'After Apply, Overhaul commands boost. Turbo, ECU and scanner boost settings are ignored.' : 'Override off. Other boost tools keep control; editing targets does not enable it.' }}</p>
      <div class="caps-row">
        <div class="seg" role="group" aria-label="Boost control">
          <HouseButton v-for="m in modes" :key="m.id" type="button" :class="{on: mode===m.id}" :disabled="disabled || mismatch" @click="setMode(m.id)">{{ m.label }}</HouseButton>
        </div>
        <span class="note">{{ mode==='caps' ? 'Per-gear target ('+pressure.unit+')' : mode==='map' ? 'Full rpm × gear map ('+pressure.unit+')' : 'Stock boost control' }}</span>
      </div>
      <p v-if="mismatch" class="note warn">Gearbox changed. <HouseButton type="button" class="link" :disabled="disabled" @click="reconcile">Match gears</HouseButton> then review before applying.</p>
      <div class="gears">
        <label v-for="(g,i) in value?.gears || gears" :key="g" class="gear"><span>G{{ g }}</span><input :disabled="disabled || mismatch" type="number" :min="0" :max="pressure.toDisplay(200)" :step="pressure.step" :aria-label="`Gear ${g} boost target ${pressure.unit}`" :value="editing?.index===i ? editing.text : capValue(i)" @focus="beginEdit(i,$event)" @input="editing={index:i,text:$event.target.value}" @blur="editing=null" @change="edit(i,$event)" @keydown.enter.prevent="$event.target.blur()"></label>
      </div>
      <p v-if="mode==='caps' && hasOffsets" class="note">Phone offsets add {{ offsetText }} on top.</p>
      <p v-if="mode==='map'" class="note">RPM map selected. Editing a gear target above switches to Per gear. <HouseButton type="button" class="link" @click="$emit('open-map')">Edit it in Advanced</HouseButton></p>
    </template>
  </section>
</template>
<script setup>
import { HouseButton, HouseSwitch } from '../../career/components/house/index.js'
import { computed, ref, watch } from 'vue'
import { gearBoost } from '../utils/fuelMapEditor'
const props=defineProps({pressure:Object,tune:Object,gears:Array,baseline:Number,supported:Boolean,supportReason:String,disabled:Boolean,target:Number,active:Boolean})
const emit=defineEmits(['change','open-map'])
const modes=[{id:'caps',label:'Per gear'},{id:'map',label:'RPM map'}]
const value=computed(()=>props.tune?.boost)
const mode=computed(()=>value.value?.mode==='map' ? 'map' : 'caps')
const enabled=computed(()=>value.value?.enabled===true && value.value?.mode!=='original')
function setEnabled(on){if(props.disabled || (on && (!props.supported || mismatch.value)))return;const b=value.value?clone():gearBoost(props.tune,props.gears,props.baseline);b.enabled=on;if(b.mode==='original')b.mode='caps';emit('change',b)}
const mismatch=computed(()=>!!value.value && JSON.stringify(value.value.gears)!==JSON.stringify(props.gears))
const hasOffsets=computed(()=>!!value.value && ((value.value.offset||0)!==0 || (value.value.offsets||[]).some(n=>n)))
const offsetText=computed(()=>{const b=value.value;if(!b)return '';const parts=[];if(b.offset)parts.push(`${b.offset>0?'+':''}${props.pressure.text(b.offset)} all gears`);(b.offsets||[]).forEach((n,i)=>{if(n)parts.push(`G${b.gears[i]} ${n>0?'+':''}${props.pressure.text(n)}`)});return parts.join('; ')})
const clone=()=>JSON.parse(JSON.stringify(value.value))
// Keep uncommitted text through periodic vehicle snapshots and parent renders.
const editing=ref(null)
watch(()=>JSON.stringify(props.gears),()=>{editing.value=null})
function beginEdit(index,event){editing.value={index,text:event.target.value};event.target.select()}
function capValue(i){const c=value.value?.caps?.[i];return Number(props.pressure.toDisplay(Number.isFinite(c)?c:props.baseline).toFixed(2))}
function reconcile(){if(!props.disabled)emit('change',gearBoost(props.tune,props.gears,props.baseline))}
function setMode(next){if(props.disabled || mismatch.value || next===mode.value)return;const b=value.value?clone():gearBoost(props.tune,props.gears,props.baseline);b.mode=next;emit('change',b)}
function edit(i,event){const n=props.pressure.fromDisplay(event.target.value);if(props.disabled || mismatch.value || event.target.value==='' || !Number.isFinite(n) || n<0 || n>200){event.target.value=capValue(i);return}const b=value.value?clone():gearBoost(props.tune,props.gears,props.baseline);b.mode='caps';b.caps[i]=n;emit('change',b)}
</script>
<style scoped>
.boost-caps{display:grid;gap:.5em}
.caps-row{display:flex;align-items:center;justify-content:space-between;gap:.6em;flex-wrap:wrap}
.seg{display:inline-flex;gap:.2em;padding:.22em;background:rgba(255,255,255,.06);border-radius:.65em;font-size:.85em}
.seg button{appearance:none;flex:0 0 auto;border:0;background:transparent;color:rgba(255,255,255,.72);font:inherit;font-weight:700;padding:.55em 1em .42em;border-radius:.45em;line-height:1;white-space:nowrap;cursor:pointer}
.seg button.on{background:rgba(255,255,255,.16);color:#fff}
.seg button:disabled{opacity:.4;cursor:default}
.note{margin:0;color:rgba(255,255,255,.55);font-size:.82em;font-weight:600}
.note.warn{color:#fde68a}
.link{appearance:none;border:0;background:none;padding:0;font:inherit;font-weight:700;color:var(--bng-orange-b400,#ff6600);cursor:pointer}
.gears{display:flex;gap:.45em;overflow-x:auto;padding-bottom:.1em}
.gears.idle{opacity:.55}
.gear{display:grid;gap:.25em;justify-items:center;padding:.45em .3em .4em;border-radius:.4em;background:rgba(0,0,0,.25);min-width:3.6em;flex:1 0 3.6em}
.gear span{font-size:.68em;font-weight:700;letter-spacing:.08em;color:rgba(255,255,255,.55)}
.gear input{width:100%;text-align:center;font:inherit;font-weight:800;color:#fff;background:transparent;border:0;padding:0;font-size:1.05em}
.gear input::-webkit-inner-spin-button{display:none}
button.focus-visible,input.focus-visible{outline:none;box-shadow:0 0 0 2px #fff,0 0 0 4px rgba(255,102,0,.7)}
</style>
