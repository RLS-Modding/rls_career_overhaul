<!--
  I really don't know how this all works anymore
 -->

<template>
  <div class="twoPaneLayout">
    <div class="leftPane">
      <h2>Insurance history</h2>
      <!-- FIXME: please don't use inline styles unless absolutely necessary -->
      <div class="historyScroll">
        <table class="historyTable">
          <tr>
            <th>Policy</th>
            <th>Event</th>
            <th>Effect</th>
            <th>Time</th>
          </tr>
          <tr v-for="(event, key) in insurancePoliciesStore.policyHistory" :key="key">
            <td>{{ event.policyName }}</td>
            <td>{{ event.event }}</td>
            <td>
              <div v-for="(effectData, t) in event.effect" :key="t">
                <span><b>{{ effectData.label }} : {{ effectData.value }}</b></span>
              </div>
            </td>
            <td>
              {{ event.time }}
            </td>
          </tr>
        </table>
      </div>
    </div>

    <!-- Right pane: Vehicles & policies -->
    <div class="rightPane">
      <h2>Vehicles & policies</h2>
      <div class="plansSummary" v-if="(insurancePoliciesStore.activePlans || []).length">
        <div class="planCard" v-for="p in insurancePoliciesStore.activePlans" :key="p.id">
          <div class="planHeader">{{ p.name }}</div>
          <template v-if="p.id === 0">
            <div class="planLine"><span>Vehicles Uninsured:</span><span>{{ p.vehiclesInsured }}</span></div>
          </template>
          <template v-else>
            <div class="planLine"><span>Insurance Score:</span><span>{{ Number(p.bonus).toFixed(2) }}</span></div>
            <div class="planLine"><span>Vehicles Insured:</span><span>{{ p.vehiclesInsured }}</span></div>
            <div class="planLine"><span>Premium:</span><span>{{ units.beamBucks(p.totalPremium || 0) }} / {{
              formatRenewal(p.renewalSeconds) }}</span></div>
          </template>
        </div>
      </div>
      <div class="vehColumn" bng-nav-scroll-force>
        <div class="vehRow" v-for="veh in insurancePoliciesStore.vehicles" :key="veh.id">
          <div class="vehMain" @click="toggleExpanded(veh.id)">
            <div class="thumb" :style="{ backgroundImage: `url('${veh.thumbnail}')` }" />
            <div class="meta">
              <div class="name">{{ veh.name }}</div>
              <div class="policy">{{ getPolicyName(veh.policyId) }}</div>
            </div>
            <div class="spacer" />
            <div class="assign">
              <BngPopoverMenu :name="'polsel_' + veh.id" @hide="() => { }">
                <div class="policyPicker">
                  <div class="policyItem" v-for="p in filterApplicable(veh.id, insurancePoliciesStore.policiesData)"
                    :key="p.id" :class="{ disabled: !isPolicySelectable(p) }" @click="onPickPolicy(veh.id, p)">
                    <div class="pName">{{ p.id === 0 ? 'No Insurance' : p.name }}</div>
                    <div class="pPrice">{{ units.beamBucks(p.id === 0 ? 0 : (p.premium || 0)) }}</div>
                  </div>
                </div>
              </BngPopoverMenu>
              <BngButton size="small" :accent="ACCENTS.menu" v-bng-popover:bottom-start.click="'polsel_' + veh.id"
                @click.stop>View
                Other Policies</BngButton>
            </div>
            <div class="miniPremium">{{ units.beamBucks((vehPremiums[veh.id] && vehPremiums[veh.id].finalPremium) || 0) }}</div>
            <div class="chevron" :class="{ open: isExpanded(veh.id) }" aria-hidden>▸</div>
          </div>

          <!-- Expanded policy details editor -->
          <div class="policyEditor" v-if="isExpanded(veh.id) && currentDisplayPolicyId(veh) > 0">
            <div class="policyGrid">
              <div class="gridHeaderLeft">Policy details</div>
              <div class="gridHeaderRight">Cost breakdown</div>
              <template v-for="p in insurancePoliciesStore.policiesData" :key="p.id">
                <template v-if="p.id === currentDisplayPolicyId(veh)">
                  <div class="perkRow" v-for="(perk, perkName) in p.perks" :key="perkName">
                    <div class="perkName">{{ perk.niceName }}</div>
                    <div class="perkControl"
                      v-if="perk.changeability?.changeable && perk.changeability.changeParams?.choices">
                      <div class="radioRow">
                        <div class="optionsGrid"
                          :style="{ '--choice-count': (perk.changeability?.changeParams?.choices?.length || 1) }">
                          <button v-for="(choice, idx) in perk.changeability.changeParams.choices" :key="idx"
                            type="button" class="choiceButton"
                            :class="{ selected: currentIndex0(veh, p, perkName) === idx }"
                            @click="() => onVehPerkChange(veh, p, perkName, idx, choice)">
                            {{ formatChoice(perk, choice) }}
                          </button>
                        </div>
                      </div>
                    </div>
                    <div class="perkValue" v-else>{{ veh.perks?.[perkName]?.value ?? perk.baseValue }}</div>
                    <div class="priceCell">{{ priceForPerk(veh, p, perkName) }}</div>
                  </div>
                </template>
              </template>

              <div class="footerRow" v-if="vehPremiums[veh.id]">
                <div class="footerContent">
                  <span class="totalLabel">Total premium (sum of perks)</span>
                  <span class="totalValue">{{ units.beamBucks(vehPremiums[veh.id].finalPremium || 0) }}</span>
                </div>
                <div class="footerContent">
                  <BngButton size="small" :accent="ACCENTS.primary" @click="applyPolicyChange(veh.id)">Change policy
                  </BngButton>
                </div>
              </div>
            </div>
          </div>
          <div class="policyEditor" v-else-if="isExpanded(veh.id)">
            <div class="editorHeader">No Insurance</div>
            <div class="policyLayout">
              <div class="editorLeft">
                <div class="noInsMsg">You will not pay a premium. Repairs can only be done privately (no insurance
                  coverage).
                </div>
              </div>
              <div class="editorRight">
                <div class="costBreakdown">
                  <div class="costHeader">Cost breakdown</div>
                  <div class="costRow">
                    <span class="cbName">Premium</span>
                    <span class="cbValue">{{ units.beamBucks(0) }}</span>
                  </div>
                  <div class="costTotal">
                    <span>Total premium</span>
                    <span>{{ units.beamBucks(0) }}</span>
                  </div>
                  <div class="actions" style="margin-top:8px">
                    <BngButton size="small" :accent="ACCENTS.primary" @click="applyPolicyChange(veh.id)">
                      Edit policy
                    </BngButton>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, reactive, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngButton, ACCENTS, BngPopoverMenu } from "@/common/components/base"
import { vBngPopover } from "@/common/directives"
import { usePopover } from "@/services/popover"
import { useInsurancePoliciesStore } from "../../stores/insurancePoliciesStore"
const { units } = useBridge()
const formatRenewal = (sec) => {
  const s = Number(sec) || 0
  if (s < 60) return `${s} sec`
  const m = Math.round(s / 60)
  return `${m} min`
}

const insurancePoliciesStore = useInsurancePoliciesStore()
const vehPremiums = reactive({})
const expanded = reactive({})
const popover = usePopover?.() // optional if available

const selectedPolicy = reactive({})
const tempOverrides = reactive({})

const getPolicyById = (id) => (insurancePoliciesStore.policiesData || []).find(p => p.id === id)

const currentDisplayPolicyId = (veh) => selectedPolicy[veh.id] ?? veh.policyId

const isExpanded = (vehId) => expanded[vehId] === true
const toggleExpanded = (vehId) => { expanded[vehId] = !isExpanded(vehId) }

const isPolicySelectable = p => true

const onPickPolicy = (vehId, p) => {
  if (!isPolicySelectable(p)) return
  selectedPolicy[vehId] = p.id
  const veh = insurancePoliciesStore.vehicles.find(v => v.id === vehId)
  if (veh) updateVehPremium(veh, p)
  // close popover if service exists
  try { popover && popover.hide?.('polsel_' + vehId) } catch (_) { }
}

const getChoiceValue = (policy, perkName, idx) => {
  const perk = policy.perks[perkName]
  const choices = perk?.changeability?.changeParams?.choices || []
  return choices[idx] ?? perk?.baseValue
}

const formatChoice = (perk, value) => {
  if ((perk.unit || '').toLowerCase() === 'time') {
    const sec = Number(value) || 0
    if (sec < 60) return `${sec} sec`
    const min = Math.round(sec / 60)
    return `${min} min`
  }
  if ((perk.unit || '').toLowerCase().includes('percentage')) {
    return `${value}%`
  }
  return `${value} ${perk.unit || ''}`.trim()
}

const estimateChoicePrice = (policy, perkName, value) => {
  const perk = policy.perks[perkName]
  const ca = perk && perk.changeability && perk.changeability.changeParams
  if (!ca) return ''
  const idx = (ca.choices || []).indexOf(value)
  if (idx < 0) return ''
  const infl = ca.premiumInfluence
  const price = Array.isArray(infl) ? infl[idx] : infl || 0
  return units.beamBucks(price)
}

const currentIndex0 = (veh, policy, perkName) => {
  const vehOv = tempOverrides?.[veh.id]
  const polOv = vehOv && vehOv[policy.id]
  if (polOv && polOv[perkName] !== undefined) return Number(polOv[perkName]) || 0
  if (policy.id === veh.policyId) return Number(veh?.perks?.[perkName]?.index ?? 0)
  const perk = policy.perks?.[perkName]
  const ca = perk && perk.changeability && perk.changeability.changeParams
  const choices = (ca && ca.choices) || []
  const idx = choices.indexOf(perk?.plValue)
  return idx >= 0 ? idx : 0
}

const costRows = (veh, policy) => {
  if (!veh || !policy) return []
  const rows = []
  let additive = 0
  let renewalFactor = 1
  for (const [perkName, perk] of Object.entries(policy.perks || {})) {
    const ca = perk && perk.changeability && perk.changeability.changeParams
    if (!ca || !Array.isArray(ca.choices)) continue
    const idx = Math.min(Math.max(currentIndex0(veh, policy, perkName), 0), ca.choices.length - 1)
    const infl = ca.premiumInfluence
    const price = Array.isArray(infl) ? (infl[idx] ?? 0) : (infl || 0)
    if (perkName === 'renewal') {
      renewalFactor = Number(price) || 1
    } else {
      additive += Number(price) || 0
      rows.push({ name: perk.niceName || perkName, price: Number(price) || 0 })
    }
  }
  // Append a synthetic row to indicate the renewal additive delta for transparency
  const renewalDelta = Math.max(0, renewalFactor - 1) * additive
  rows.push({ name: 'Renewal Period', price: Math.floor(renewalDelta * 100) / 100 })
  return rows
}

const priceForPerk = (veh, policy, perkName) => {
  if (!veh || !policy) return ''
  const perk = policy.perks?.[perkName]
  const ca = perk && perk.changeability && perk.changeability.changeParams
  if (!ca) return ''
  // Special handling for renewal: display additive delta = (factor-1) * sum(other perks)
  if (perkName === 'renewal') {
    let additive = 0
    for (const [name, prk] of Object.entries(policy.perks || {})) {
      if (name === 'renewal') continue
      const ca2 = prk && prk.changeability && prk.changeability.changeParams
      if (!ca2) continue
      const idx2 = Math.min(Math.max(currentIndex0(veh, policy, name), 0), (ca2.choices?.length || 1) - 1)
      const infl2 = ca2.premiumInfluence
      const price2 = Array.isArray(infl2) ? (infl2[idx2] ?? 0) : (infl2 || 0)
      additive += Number(price2) || 0
    }
    const idxR = Math.min(Math.max(currentIndex0(veh, policy, 'renewal'), 0), (ca.choices?.length || 1) - 1)
    const inflR = ca.premiumInfluence
    const factor = Array.isArray(inflR) ? (inflR[idxR] ?? 1) : (inflR || 1)
    const delta = Math.max(0, Number(factor) - 1) * additive
    return units.beamBucks(Math.floor(delta * 100) / 100)
  }
  const idx = Math.min(Math.max(currentIndex0(veh, policy, perkName), 0), (ca.choices?.length || 1) - 1)
  const infl = ca.premiumInfluence
  const price = Array.isArray(infl) ? (infl[idx] ?? 0) : (infl || 0)
  return units.beamBucks(Number(price) || 0)
}

const sumPerkRow = (policy, perkName) => {
  const perk = policy.perks[perkName]
  const ca = perk && perk.changeability && perk.changeability.changeParams
  if (!ca) return ''
  // price of currently selected index for this perk
  const idx = (ca.choices || []).indexOf(ca.choices[(policy.perks[perkName].plValue ? (ca.choices || []).indexOf(policy.perks[perkName].plValue) : 0)])
  const infl = ca.premiumInfluence
  const price = Array.isArray(infl) ? infl[idx] : infl || 0
  return units.beamBucks(price)
}

const buildTempPerks = (veh, policy) => {
  const res = {}
  for (const [perkName, perk] of Object.entries(policy.perks)) {
    if (perk.changeability?.changeable && perk.changeability.changeParams?.choices) {
      const idx = (veh.perks?.[perkName]?.index) ?? 0
      res[perkName] = getChoiceValue(policy, perkName, idx)
    }
  }
  return res
}

const updateVehPremium = (veh, policy) => {
  if (!veh || !policy) return
  // UI-side estimate mirrors backend: (sum non-renewal) * renewalFactor
  const rows = costRows(veh, policy)
  // additive = sum of non-renewal; renewalRow.price already equals (factor-1)*additive from current selections
  const additive = rows
    .filter(r => r.name !== 'Renewal Period')
    .reduce((s, r) => s + (Number(r.price) || 0), 0)
  const renewalRow = rows.find(r => r.name === 'Renewal Period')
  const renewalDelta = renewalRow ? Number(renewalRow.price) || 0 : 0
  const total = additive + renewalDelta
  vehPremiums[veh.id] = { finalPremium: Math.floor(total * 100) / 100 }
}

const onVehPerkChange = (veh, policy, perkName, idx, choice) => {
  if (!tempOverrides[veh.id]) tempOverrides[veh.id] = {}
  if (!tempOverrides[veh.id][policy.id]) tempOverrides[veh.id][policy.id] = {}
  tempOverrides[veh.id][policy.id][perkName] = idx
  updateVehPremium(veh, policy)
}

const applyPolicyChange = (vehId) => {
  const veh = insurancePoliciesStore.vehicles.find(v => v.id === vehId)
  if (!veh) return
  const toPolicyId = selectedPolicy[vehId] ?? veh.policyId
  const overridesIdx0 = { ...(tempOverrides?.[veh.id]?.[toPolicyId] || {}) }

  const policy = getPolicyById(toPolicyId)
  const applyRenewalIfAny = async () => {
    if (!policy) return
    if (overridesIdx0.renewal === undefined) return
    const idx = Number(overridesIdx0.renewal) || 0
    const value = getChoiceValue(policy, 'renewal', idx)
    await lua.career_modules_insurance.changePolicyPerks(toPolicyId, { renewal: value })
    delete overridesIdx0.renewal
  }

  if (toPolicyId !== veh.policyId) {
    applyRenewalIfAny()
    lua.career_modules_insurance.applyVehPolicyChange(vehId, toPolicyId, overridesIdx0)
  } else {
    // apply per-vehicle overrides to current policy (excluding renewal)
    for (const [perkName, idx] of Object.entries(overridesIdx0)) {
      if (perkName === 'renewal') continue
      lua.career_modules_insurance.setVehPerkOverride(veh.id, perkName, idx)
    }
    applyRenewalIfAny()
  }

  delete selectedPolicy[vehId]
  if (tempOverrides?.[veh.id]) delete tempOverrides[veh.id][toPolicyId]
}

const applicableCache = reactive({})
const filterApplicable = (vehId, policies) => {
  if (!applicableCache[vehId]) {
    lua.career_modules_insurance.getApplicablePoliciesForVehicle(vehId).then(ids => {
      applicableCache[vehId] = Array.isArray(ids) ? ids : []
    })
    return []
  }
  const allow = applicableCache[vehId]
  return (policies || []).filter(p => allow.includes(p.id))
}

const getPolicyName = policyId => {
  if (policyId === 0) return 'No Insurance'
  const p = insurancePoliciesStore.policiesData.find(p => p.id === policyId)
  return p ? p.name : 'Unknown'
}

onMounted(() => {
  for (const veh of insurancePoliciesStore.vehicles) {
    filterApplicable(veh.id, insurancePoliciesStore.policiesData)
    const pol = getPolicyById(veh.policyId)
    if (pol) updateVehPremium(veh, pol)
    // ensure premiums exist even before interaction
    if (!vehPremiums[veh.id]) {
      const p2 = pol || insurancePoliciesStore.policiesData.find(p => p.id === veh.policyId)
      if (p2) updateVehPremium(veh, p2)
    }
    if (expanded[veh.id] === undefined) expanded[veh.id] = false
  }
})

// keep premiums up to date when backend pushes new data
watch([
  () => insurancePoliciesStore.vehicles,
  () => insurancePoliciesStore.policiesData,
], () => {
  for (const veh of insurancePoliciesStore.vehicles) {
    const pol = getPolicyById(veh.policyId)
    if (pol) updateVehPremium(veh, pol)
  }
}, { deep: true })

onUnmounted(() => {
  for (const k of Object.keys(selectedPolicy)) delete selectedPolicy[k]
  for (const k of Object.keys(tempOverrides)) delete tempOverrides[k]
})
</script>

<style scoped lang="scss">
.twoPaneLayout {
  display: grid;
  grid-template-columns: 42.5% 55%;
  gap: 30px;
  height: 100%;
}

.leftPane {
  min-width: 0;
  overflow: hidden;
}

.rightPane {
  min-width: 0;
  overflow-y: auto;
}

.historyScroll {
  height: 97%;
  overflow-y: auto;
}

.policiesDiv {
  height: 100%;
  scroll-behavior: auto;
  overflow-y: auto;
}

.vehiclesList {
  height: 100%;
  overflow-y: auto;
}

.vehiclesInline {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-bottom: 10px;
}

.vehCard {
  width: 12em;
  padding: 8px;
  background: rgba(83, 83, 83, .465);
  border-radius: var(--bng-corners-2);
  cursor: pointer;
}

.vehColumn {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.policySelect {
  min-width: 220px;
}

.policyEditor {
  margin-top: 8px;
  padding: 10px;
  padding-right: 20px;
  background: rgba(55, 55, 55, .65);
  border-radius: 8px;
  box-sizing: border-box;
  overflow: hidden;
}

.policyLayout {
  display: grid;
  grid-template-columns: 1fr minmax(240px, 30.7%);
  gap: 16px;
}

.policyGrid {
  display: grid;
  padding: 10px;
  grid-template-columns: 1fr minmax(240px, 30.7%);
  grid-auto-rows: auto;
  column-gap: 16px;
}

.plansSummary {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 10px;
  margin-bottom: 12px;
  margin-right: 10px;
}

.planCard {
  background: rgba(55, 55, 55, .65);
  border-radius: 8px;
  padding: 10px;
}

.planHeader {
  font-weight: 700;
  margin-bottom: 6px;
}

.planLine {
  display: flex;
  justify-content: space-between;
  padding: 2px 0;
}

.gridHeaderLeft {
  grid-column: 1 / 2;
  padding-bottom: 8px;
  font-weight: 700;
}

.gridHeaderRight {
  grid-column: 2 / 3;
  padding-left: 16px;
  padding-bottom: 8px;
  font-weight: 700;
}

.perkRow {
  grid-column: 1 / 3;
  display: grid;
  grid-template-columns: 69.3% 30.7%;
  row-gap: 8px;
  padding: 8px 0;
  /* separators removed */
}

.perkName {
  grid-column: 1 / 2;
}

.perkControl,
.perkValue {
  grid-column: 1 / 2;
}

.priceCell {
  grid-column: 2 / 3;
  padding-left: 16px;
  min-width: 0;
  display: flex;
  align-items: center;
  justify-content: flex-end;
}

.footerRow {
  grid-column: 1 / 3;
  padding-top: 10px;
}

.footerContent {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 10px;
}

.editorLeft {
  flex: 2 1 65%;
  min-width: 0;
}

.editorRight {
  min-width: 240px;
  border-left: 1px solid rgba(255, 255, 255, 0.12);
  padding-left: 16px;
  box-sizing: border-box;
  overflow: hidden;
}

.editorHeader {
  font-weight: 700;
  margin-bottom: 6px;
  padding-bottom: 8px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.12);
}

.editorGrid {
  display: block;
  gap: 10px 12px;
}

.perkRow {
  display: grid;
  grid-template-columns: 1fr;
  row-gap: 8px;
  padding: 8px 0;
  border-top: 1px solid rgba(255, 255, 255, 0.12);
}

.perkName {
  color: #eee;
  font-weight: 700;
  font-size: 1.2em;
}

.perkControl select {
  width: 100%;
}

.perkValue {
  color: #ddd;
}


.radioRow {
  display: flex;
  align-items: center;
  gap: 10px;
}

.radioRow .optionsGrid {
  display: grid !important;
  grid-template-columns: repeat(var(--choice-count, 2), minmax(0, 1fr));
  gap: 8px;
  width: 100%;
  flex: 1 1 auto;
  align-items: stretch;
}

.choiceButton {
  display: block !important;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto !important;
  min-width: 0;
  width: 100% !important;
  padding: 6px 8px;
  background: rgba(255, 255, 255, 0.06);
  color: #eee;
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 9px;
  cursor: pointer;
  text-align: center;
  white-space: nowrap;
  font-size: 0.9em;
}

.choiceButton.selected {
  background: rgb(255, 102, 0);
  border-color: rgb(255, 102, 0);
  color: #111;
}



.rowSum {
  margin-left: auto;
  color: #ddd;
  font-weight: 600;
}



.policyPicker {
  min-width: 320px;
  display: flex;
  flex-direction: column;
}

.policyItem {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px 10px;
  cursor: pointer;
}

.policyItem:hover {
  background: rgba(255, 255, 255, 0.08);
}

.policyItem.disabled {
  opacity: 0.5;
  pointer-events: none;
}

.policyItem .pName {
  font-weight: 700;
}

.policyItem .pPrice {
  color: #ccc;
}

.costBreakdown {
  margin-top: 0;
  padding-top: 0;
  width: 100%;
}

.costHeader {
  font-weight: 700;
  margin-bottom: 6px;
}

.costRow {
  display: flex;
  justify-content: space-between;
  padding: 2px 0;
  gap: 8px;
}

.costRow .cbName {
  flex: 1 1 auto;
  min-width: 0;
}

.costRow .cbValue {
  flex: 0 0 auto;
  text-align: right;
  white-space: nowrap;
}

.costTotal {
  display: flex;
  justify-content: space-between;
  margin-top: 6px;
  font-weight: 700;
  gap: 8px;
}

.costTotal span:first-child {
  flex: 1 1 auto;
  min-width: 0;
}

.costTotal span:last-child {
  flex: 0 0 auto;
  text-align: right;
  white-space: nowrap;
}

.vehCard.selected {
  outline: 2px solid #f60;
}

.vehCard .thumb {
  width: 100%;
  height: 64px;
  background-size: cover;
  background-position: center;
  border-radius: 4px;
}

.vehCard .name {
  font-weight: 600;
  margin-top: 6px;
}

.vehCard .policy {
  font-size: .9em;
  color: #ddd;
}

.vehCard.noIns {
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: 600;
}

.vehRow {
  display: flex;
  flex-direction: column;
  background: rgba(83, 83, 83, 0.465);
  border-radius: var(--bng-corners-2);
  margin-bottom: 5px;
  margin-right: 10px;
  padding: 8px;
  cursor: pointer;
}

.vehRow.selected {
  outline: 2px solid #f60;
}

.vehRow .vehMain {
  display: flex;
  gap: 5px;
  align-items: center;
  cursor: pointer;
}

.vehRow .vehMain .spacer { flex: 1 1 auto; }

.miniPremium {
  margin-left: auto;
  color: #ddd;
  font-weight: 600;
}

.chevron {
  margin-left: 8px;
  transform: rotate(0deg);
  transition: transform .15s ease;
  opacity: .8;
}

.chevron.open {
  transform: rotate(90deg);
}

.vehRow .thumb {
  width: 64px;
  height: 40px;
  background-size: cover;
  background-position: center;
  border-radius: 4px;
}

.vehRow .meta .name {
  font-weight: 600;
}

.vehRow .meta .policy {
  font-size: 0.9em;
  color: #ddd;
}

.vehRow .assign {
  margin-top: 0;
  display: flex;
  align-items: center;
  justify-content: flex-end;
}

.noInsMsg {
  color: #ddd;
}

.justifyContentLeft {
  justify-content: left;
}

tr:nth-child(even) {
  background-color: #383838;
}

.historyTable td {
  padding: 3px 20px 3px 20px;
}

.details {
  margin-left: 20px;
}

</style>
