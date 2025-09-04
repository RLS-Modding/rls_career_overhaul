<!--
  Redesigned insurance policies dashboard with modern glass-card aesthetic
 -->

<template>
  <div class="insurance-dashboard-container" v-bng-blur>
    <!-- Overview Cards -->
    <div class="overview-section">
      <div class="overview-grid">
        <!-- Policy Summary Tiles -->
        <div v-for="plan in insurancePoliciesStore.activePlans" :key="plan.id" class="policy-card glass-card glass-card-hover" :class="{ uninsured: plan.id === 0 }">
          <div class="tile-top">
            <div v-if="plan.id === 0" class="tile-caption">
              <span class="status-badge danger">No Insurance</span>
            </div>
            <div v-else class="tile-caption">{{ plan.name }}</div>
            <div class="tile-icon" :class="{ danger: plan.id === 0 }">
              <svg v-if="plan.id !== 0" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M12 22s8-4 8-10V6l-8-4-8 4v6c0 6 8 10 8 10z"></path>
                <path d="M9.5 12.5l1.5 1.5 3.5-3.5"></path>
              </svg>
              <svg v-else viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"></path>
                <line x1="12" y1="9" x2="12" y2="13"></line>
                <line x1="12" y1="17" x2="12.01" y2="17"></line>
              </svg>
            </div>
          </div>
          <div class="tile-main">
            <div class="tile-count">{{ plan.vehiclesInsured }} vehicle{{ plan.vehiclesInsured !== 1 ? 's' : '' }}</div>
            <div v-if="plan.id !== 0" class="tile-premium">{{ units.beamBucks(plan.totalPremium || 0) }}/{{ getPlanRenewalLabel(plan.id) }}</div>
            <div v-else class="tile-uninsured">Uninsured</div>
          </div>
          <div v-if="plan.id !== 0" class="tile-sep"></div>
          <div v-if="plan.id !== 0" class="tile-bottom">
            <span class="dot"></span>
            <div class="tile-score">Insurance Score: <span class="score">{{ Number(plan.bonus).toFixed(2) }}</span></div>
          </div>
        </div>
      </div>
    </div>

    <!-- Main Content Tabs -->
    <div class="main-content">
      <div class="tabs-container">
        <div class="tabs-header pill">
          <button
            v-for="tab in tabs"
            :key="tab.id"
            @click="activeTab = tab.id"
            :class="['tab-button', { active: activeTab === tab.id }]"
            class="glass-button"
          >
            {{ tab.label }}
          </button>
        </div>

        <!-- Vehicles Tab -->
        <div v-if="activeTab === 'vehicles'" class="tab-content">
          <div class="vehicles-grid">
            <!-- Vehicle Cards -->
            <div v-for="veh in insurancePoliciesStore.vehicles" :key="veh.id" class="vehicle-card glass-card glass-card-hover">
              <div class="vehicle-hero" :style="{ backgroundImage: `url('${veh.thumbnail}')` }">
                <div class="hero-overlay">
                  <div class="card-top">
                    <div class="veh-title">
                      <div class="veh-name">{{ veh.name }}</div>
                      <div class="veh-sub">{{ getPolicyName(veh.policyId) }}</div>
                    </div>
                    <div class="chip-group" @click.stop>
                      <button type="button" class="chip" @click="openViewer(veh.id)">View</button>
                      <button type="button" class="chip" @click="openEditor(veh.id)">Edit</button>
                    </div>
                  </div>
                  <div class="card-bottom">
                    <div class="renewal-col">
                      <div class="label">Renewal Cost</div>
                      <div class="value">{{ units.beamBucks((vehPremiums[veh.id] && vehPremiums[veh.id].finalPremium) || 0) }}</div>
                    </div>
                    <div class="renewal-col" v-if="renewalLabelForVeh(veh)">
                      <div class="label">Renewal</div>
                      <div class="value">{{ renewalLabelForVeh(veh) }}</div>
                    </div>
                  </div>
                </div>
              </div>

              <!-- removed bottom policy-selection container -->

              <!-- Editor Modal -->
              <PolicyEditorModal
                :open="showEditorForVeh === veh.id"
                :veh="veh"
                :policiesData="insurancePoliciesStore.policiesData"
                :vehPremium="(vehPremiums[veh.id] && vehPremiums[veh.id].finalPremium) || 0"
                :currentPolicyId="currentDisplayPolicyId"
                :currentIndex0="currentIndex0"
                :formatChoice="formatChoice"
                :priceForPerk="priceForPerk"
                :onVehPerkChange="onVehPerkChange"
                :onPolicyChange="onPolicyChange"
                :tempOverrides="tempOverrides"
                :units="units"
                @close="closeModals"
                @apply="(data) => { handlePolicyChange(data); closeModals(); }"
              />

              <!-- Viewer Modal -->
              <PolicyViewerModal
                :open="showViewerForVeh === veh.id"
                :veh="veh"
                :policiesData="insurancePoliciesStore.policiesData"
                :units="units"
                :priceForPerk="priceForPerk"
                :monthlyPremium="(vehPremiums[veh.id] && vehPremiums[veh.id].finalPremium) || 0"
                @close="closeModals"
                @edit="() => { openEditor(veh.id) }"
              />
            </div>
          </div>
        </div>

        <!-- History Tab -->
        <div v-if="activeTab === 'history'" class="tab-content">
          <div class="history-section">
            <div class="history-container">
              <div class="history-header main">
                <div class="left">
                  <div class="icon">
                    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <circle cx="12" cy="12" r="10" />
                      <polyline points="12 6 12 12 16 14" />
                    </svg>
                  </div>
                  <div>
                    <h3>Insurance History</h3>
                    <p>Track your policy events and changes</p>
                  </div>
                </div>
              </div>
              <div class="history-list">
                <div v-for="(event, key) in insurancePoliciesStore.policyHistory" :key="key" class="history-item">
                  <div class="history-timeline"><div class="timeline-dot"></div></div>
                  <div class="history-content">
                    <div class="history-header row">
                      <h4>{{ event.policyName }}</h4>
                      <div class="history-meta">
                        <div class="history-amount" :class="{ positive: historyMoney(event) > 0, negative: historyMoney(event) < 0 }">
                          {{ historyMoney(event) > 0 ? '+' : '' }}{{ units.beamBucks(Math.abs(historyMoney(event))) }}
                        </div>
                        <span class="history-time">{{ event.time }}</span>
                      </div>
                    </div>
                    <p class="history-event">{{ event.event }}</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Analytics Tab -->
        <div v-if="activeTab === 'analytics'" class="tab-content">
          <div class="analytics-section">
            <div class="coming-soon">
              <div class="analytics-icon">
                <svg class="w-20 h-20 text-orange-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"></path>
                </svg>
              </div>
              <h3>Analytics Coming Soon</h3>
              <p>Advanced insights and comprehensive reports will be available here.</p>
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
import { useInsurancePoliciesStore } from "../../stores/insurancePoliciesStore"
import { vBngBlur } from "@/common/directives"
import PolicyEditorModal from "./PolicyEditorModal.vue"
import PolicyViewerModal from "./PolicyViewerModal.vue"

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
// dropdown and modal state
const openDropdown = ref(null)
const showEditorForVeh = ref(null)
const showViewerForVeh = ref(null)

const selectedPolicy = reactive({})
const tempOverrides = reactive({})

// Tab management
const activeTab = ref('vehicles')
const tabs = [
  {
    id: 'vehicles',
    label: 'Vehicles',
    icon: 'CarIcon'
  },
  {
    id: 'history',
    label: 'History',
    icon: 'HistoryIcon'
  },
  {
    id: 'analytics',
    label: 'Analytics',
    icon: 'AnalyticsIcon'
  }
]

// renewal label placeholder (if backend exposes renewal seconds per-vehicle, wire here)
const renewalLabelForVeh = (veh) => {
  return ''
}

// icons not used (visually styled tabs)
const CarIcon = { template: `<span/>` }
const HistoryIcon = { template: `<span/>` }
const AnalyticsIcon = { template: `<span/>` }

// old inline svg icons removed (see small stubs above)

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
  closeDropdown()
}

const toggleDropdown = (vehId) => {
  openDropdown.value = openDropdown.value === vehId ? null : vehId
}
const closeDropdown = () => {
  openDropdown.value = null
}
const openEditor = (vehId) => {
  showViewerForVeh.value = null
  showEditorForVeh.value = vehId
}
const openViewer = (vehId) => {
  showEditorForVeh.value = null
  showViewerForVeh.value = vehId
}
const closeModals = () => {
  showEditorForVeh.value = null
  showViewerForVeh.value = null
}

const changeButtonLabel = (veh) => {
  return veh.policyId === 0 ? 'Insure' : 'Change Policy'
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

const onPolicyChange = (veh, newPolicy) => {
  console.log('Policy changed for vehicle:', veh.id, 'to policy:', newPolicy.name, newPolicy.id)
  // Recalculate premium for the newly selected policy
  updateVehPremium(veh, newPolicy)
}

const handlePolicyChange = (data) => {
  const { selectedPolicyId, vehicleId } = data
  // Update the selected policy for this vehicle
  selectedPolicy[vehicleId] = selectedPolicyId
  // Apply the policy change
  applyPolicyChange(vehicleId)
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

const getPlanRenewalLabel = (policyId) => {
  if (policyId === 0) return 'mo' // No insurance doesn't have renewal

  const policy = insurancePoliciesStore.policiesData.find(p => p.id === policyId)
  if (!policy || !policy.perks || !policy.perks.renewal) {
    return 'mo' // fallback
  }

  const renewalValue = policy.perks.renewal.plValue ??
                      policy.perks.renewal.baseValue ??
                      1800 // default to 30 minutes (1800 seconds)

  const seconds = Number(renewalValue) || 1800
  const minutes = Math.round(seconds / 60)

  if (minutes < 60) {
    return `${minutes}min`
  } else if (minutes === 60) {
    return '1hr'
  } else {
    const hours = Math.round(minutes / 60)
    return `${hours}hr`
  }
}

// sum Money values in event.effect if present, otherwise 0
const historyMoney = (event) => {
  try {
    const eff = event && event.effect
    if (!Array.isArray(eff)) return 0
    const moneyRow = eff.find(e => (e.label || '').toLowerCase() === 'money')
    const val = moneyRow && (Number(moneyRow.value) || 0)
    return val
  } catch (_) { return 0 }
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
.insurance-dashboard-container {
  height: 100%;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  border: 0;
  color: var(--bng-off-white);
}

/* Overview Section */
.overview-section {
  margin-bottom: 0.75rem;
}

.overview-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, 240px);
  gap: 1rem;
}

.policy-card { padding: 0.8rem 0.8rem 0.65rem 0.8rem; position: relative; overflow: hidden; background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(20px); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: var(--bng-corners-1); box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3); transition: all 0.3s ease; }

.policy-card .tile-top { display: flex; align-items: center; justify-content: space-between; }
.tile-caption { color: var(--bng-cool-gray-300); font-size: 0.8rem; }

.status-badge {
  display: inline-flex;
  align-items: center;
  padding: 4px 8px;
  border-radius: 12px;
  font-size: 0.75rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.status-badge.danger {
  background: linear-gradient(135deg, #ff4757, #ff3838);
  color: white;
  box-shadow: 0 2px 8px rgba(255, 71, 87, 0.3);
  border: 1px solid rgba(255, 71, 87, 0.5);
}
.tile-icon { width: 40px; height: 40px; padding: 6px; border-radius: var(--bng-corners-2); display: flex; align-items: center; justify-content: center; color: var(--bng-orange); background: rgba(var(--bng-orange-rgb), 0.08); border: 1px solid rgba(var(--bng-orange-rgb), 0.25); box-shadow: inset 0 0 0 1px rgba(var(--bng-orange-rgb), 0.15); }
.tile-icon svg { width: 20px; height: 20px; }
.tile-icon.danger { color: #ff6b6b; background: rgba(255,0,0,0.07); border-color: rgba(255,0,0,0.25); }

.tile-main { margin-top: 6px; }
.tile-count { font-size: 1.1rem; font-weight: 800; color: var(--bng-off-white); }
.tile-premium { margin-top: 4px; color: var(--bng-orange); font-weight: 700; font-size: 0.9rem; }
.tile-uninsured { margin-top: 4px; color: #ff6b6b; font-weight: 700; font-size: 0.9rem; }

.tile-sep { height: 1px; margin: 8px 0; background: linear-gradient(90deg, rgba(var(--bng-orange-rgb), 0.15), rgba(var(--bng-orange-rgb), 0.05)); }
.tile-bottom { display: flex; align-items: center; gap: 6px; color: var(--bng-cool-gray-300); font-size: 0.85rem; }
.tile-bottom .dot { width: 6px; height: 6px; border-radius: 999px; background: var(--bng-orange); box-shadow: 0 0 0 3px rgba(var(--bng-orange-rgb), 0.15); }
.tile-bottom .score { color: var(--bng-off-white); font-weight: 700; }

.policy-header {
  display: flex;
  align-items: center;
  gap: 1rem;
  margin-bottom: 1rem;
}

.policy-icon {
  width: 3rem;
  height: 3rem;
  background: rgba(255, 102, 0, 0.1);
  border: 1px solid rgba(255, 102, 0, 0.2);
  border-radius: 0.75rem;
  display: flex;
  align-items: center;
  justify-content: center;
  backdrop-filter: blur(10px);
}

.policy-info {
  flex: 1;
}

.policy-name {
  font-size: 1.25rem;
  font-weight: 700;
  color: #ffffff;
  margin: 0 0 0.25rem 0;
}

.policy-stats {
  font-size: 0.875rem;
  color: rgba(255, 255, 255, 0.7);
  margin: 0;
}

.policy-details {
  border-top: 1px solid rgba(255, 102, 0, 0.1);
  padding-top: 1rem;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.5rem 0;
}

.detail-label {
  font-size: 0.875rem;
  color: rgba(255, 255, 255, 0.7);
}

.detail-value {
  font-size: 1rem;
  font-weight: 600;
  color: #ff6600;
}

/* Main Content */
.main-content {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
  background: transparent;
  border: 0;
}

.tabs-container {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.tabs-header {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.25rem;
  margin-bottom: 1rem;
  padding: 0.5rem;
  background: rgba(255, 255, 255, 0.02);
  border-radius: var(--bng-corners-1);
  backdrop-filter: blur(10px);
  border: 1px solid rgba(255, 255, 255, 0.05);
}

.tabs-header.pill {
  justify-content: center;
  border: 1px solid rgba(var(--bng-orange-rgb), 0.45);
  background: radial-gradient(120% 120% at 50% 0%, rgba(var(--bng-orange-rgb), 0.10) 0%, rgba(0,0,0,0.25) 60%, rgba(0,0,0,0.35) 100%);
  border-radius: 999px;
  padding: 6px;
  max-width: 520px;
  margin: 0 auto 24px auto;
}

.tab-button {
  position: relative;
  padding: 10px 18px;
  background: rgba(255,255,255,0.06);
  border: 1px solid rgba(255,255,255,0.12);
  border-radius: 18px;
  color: var(--bng-cool-gray-400);
  font-weight: 600;
  font-size: 0.95rem;
  cursor: pointer;
  transition: all 0.3s ease;
  opacity: 0.7;
}

.tab-button:hover {
  opacity: 1;
  background: rgba(255,255,255,0.08);
  transform: translateY(-1px);
}

.tab-button.active {
  padding: 10px 18px;
  background: rgba(255,255,255,0.15);
  color: var(--bng-off-white);
  border: 2px solid var(--bng-orange);
  box-shadow: 0 4px 16px rgba(var(--bng-orange-rgb), 0.4);
  opacity: 1;
  font-weight: 700;
  text-shadow: 0 1px 2px rgba(0,0,0,0.3);
  transform: translateY(-1px);
}

.tab-content {
  flex: 1;
  min-height: 0;
}

/* Vehicles Tab */
.vehicles-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(400px, 1fr));
  gap: 1.5rem;
}

.vehicle-card { padding: 0; overflow: hidden; transition: all 0.3s ease; background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(20px); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: var(--bng-corners-1); box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3); }

.vehicle-hero { position: relative; height: 210px; background-size: cover; background-position: center; border-radius: var(--bng-corners-1); }
.hero-overlay { position: absolute; inset: 0; display: flex; flex-direction: column; justify-content: space-between; padding: 12px; background: linear-gradient(180deg, rgba(0,0,0,0.35) 0%, rgba(0,0,0,0.55) 60%, rgba(0,0,0,0.75) 100%); }
.card-top { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.veh-title { display: flex; flex-direction: column; }
.veh-name { color: var(--bng-off-white); font-weight: 800; text-shadow: 0 2px 4px rgba(0,0,0,0.5); }
.veh-sub { color: var(--bng-orange); font-size: 0.9rem; }
.chip-group { display: flex; gap: 6px; }
.chip { padding: 5px 9px; border-radius: 14px; background: rgba(255,255,255,0.18); color: var(--bng-cool-gray-200); border: 1px solid rgba(255,255,255,0.28); cursor: pointer; font-size: 0.85rem; }
.chip.primary { background: var(--bng-orange); color: var(--bng-off-black); border-color: var(--bng-orange); border-radius: 16px; }
.card-bottom { display: flex; justify-content: space-between; align-items: center; }
.renewal-col .label { color: var(--bng-cool-gray-400); font-size: 0.8rem; }
.renewal-col .value { color: var(--bng-orange); font-weight: 800; font-size: 1.1rem; }

.policy-selection {
  padding: 1rem 1.5rem;
  border-top: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: flex-start;
  align-items: center;
}

.policy-picker {
  min-width: 320px;
}

.policy-option {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1rem;
  cursor: pointer;
  border-radius: 0.5rem;
  transition: all 0.2s ease;
}

.policy-option:hover {
  background: rgba(255, 255, 255, 0.05);
}

.policy-name {
  font-weight: 600;
  color: #ffffff;
}

.policy-price {
  color: rgba(255, 255, 255, 0.7);
}

.policy-option.disabled {
  opacity: 0.5;
  pointer-events: none;
}

/* Policy Editor */
.policy-editor {
  margin-top: 1rem;
  padding: 1.5rem;
  animation: slideDown 0.3s ease;
}

/* Modal */
.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0,0,0,0.6);
  backdrop-filter: blur(3px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.modal-content {
  width: min(90vw, 1200px);
  max-height: 90vh;
  overflow: auto;
  padding: 1.25rem;
  border-radius: 0.75rem;
}
.modal-content .editor-header { display: flex; align-items: center; justify-content: space-between; }
.modal-content .editor-header h4 { font-size: 1.3rem; font-weight: 800; }
.modal-content .editor-header::after { content: attr(data-premium); color: #ffb380; font-weight: 800; }

.dropdown {
  position: relative;
}

.dropdown-menu {
  position: absolute;
  top: 110%;
  left: 0;
  min-width: 320px;
  padding: 0.5rem;
  border-radius: 0.5rem;
  border: 1px solid rgba(255,255,255,0.08);
  z-index: 20;
}

/* removed extra action buttons */

.footer-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 0.5rem;
}

@keyframes slideDown {
  from {
    opacity: 0;
    transform: translateY(-10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

.editor-header {
  margin-bottom: 1.5rem;
}

.editor-header h4 {
  font-size: 1.125rem;
  font-weight: 700;
  color: #ffffff;
  margin: 0 0 0.25rem 0;
}

.editor-header p {
  font-size: 0.875rem;
  color: rgba(255, 255, 255, 0.7);
  margin: 0;
}

.perks-grid {
  display: grid;
  gap: 1rem;
  margin-bottom: 1.5rem;
}

.perk-item {
  display: grid;
  grid-template-columns: 1fr auto auto;
  gap: 1rem;
  padding: 1rem;
  background: rgba(255, 255, 255, 0.02);
  border-radius: 0.5rem;
  border: 1px solid rgba(255, 255, 255, 0.05);
}

.perk-info {
  min-width: 0;
}

.perk-name {
  font-size: 1rem;
  font-weight: 600;
  color: #ffffff;
  margin: 0 0 0.25rem 0;
}

.perk-description {
  font-size: 0.875rem;
  color: rgba(255, 255, 255, 0.6);
  margin: 0;
}

.perk-controls {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.choice-selector {
  display: flex;
  gap: 0.25rem;
}

.choice-button {
  padding: 0.375rem 0.75rem;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.375rem;
  color: rgba(255, 255, 255, 0.8);
  font-size: 0.875rem;
  cursor: pointer;
  transition: all 0.2s ease;
}

.choice-button:hover {
  background: rgba(255, 102, 0, 0.1);
  border-color: rgba(255, 102, 0, 0.2);
}

.choice-button.selected {
  background: rgba(255, 102, 0, 0.2);
  border-color: #ff6600;
  color: #ff6600;
}

.perk-value-display {
  font-size: 0.875rem;
  color: rgba(255, 255, 255, 0.8);
  font-weight: 500;
}

.perk-cost {
  font-size: 0.875rem;
  font-weight: 600;
  color: #ff6600;
  text-align: right;
}

.editor-footer {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding-top: 1rem;
  border-top: 1px solid rgba(255, 255, 255, 0.05);
}

.total-cost {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.total-label {
  font-size: 0.875rem;
  color: rgba(255, 255, 255, 0.7);
}

.total-amount {
  font-size: 1.25rem;
  font-weight: 700;
  color: #ff6600;
}

/* No Insurance Notice */
.no-insurance-notice {
  text-align: center;
  padding: 2rem;
}

.notice-icon {
  margin-bottom: 1rem;
  display: flex;
  justify-content: center;
}

.no-insurance-notice h4 {
  font-size: 1.125rem;
  font-weight: 700;
  color: #ffffff;
  margin: 0 0 0.5rem 0;
}

.no-insurance-notice p {
  color: rgba(255, 255, 255, 0.7);
  margin: 0 0 1.5rem 0;
  line-height: 1.5;
}

/* History Tab */
.history-section {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.history-container { border: 1px solid rgba(255,102,0,0.35); border-radius: 12px; padding: 8px 10px 10px 10px; background: rgba(0,0,0,0.25); }
.history-header.main { display: flex; justify-content: space-between; align-items: center; padding: 6px 8px 10px 8px; border-bottom: 1px solid rgba(255,102,0,0.18); margin-bottom: 6px; }
.history-header.main .left { display: flex; gap: 10px; align-items: center; }
.history-header.main .icon { width: 40px; height: 40px; padding: 6px; border-radius: 12px; border: 1px solid rgba(255,102,0,0.35); display: flex; align-items: center; justify-content: center; color: #ff6600; background: rgba(255,102,0,0.08); }
.history-header.main .icon svg { width: 20px; height: 20px; }

.history-header {
  margin-bottom: 2rem;
}

.history-header h3 {
  font-size: 1.5rem;
  font-weight: 700;
  color: #ffffff;
  margin: 0 0 0.5rem 0;
}

.history-header p {
  color: rgba(255, 255, 255, 0.7);
  margin: 0;
}

.history-list {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 12px;
}
/* Scrollbar style (match VehicleList.vue) */
.history-list::-webkit-scrollbar { width: 8px; }
.history-list::-webkit-scrollbar-track { background: rgba(0, 0, 0, 0.2); border-radius: 4px; }
.history-list::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.1); border-radius: 4px; }
.history-list::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.15); }

.history-item { display: flex; gap: 10px; padding: 10px 12px; border: 1px solid rgba(255,102,0,0.15); border-radius: 10px; background: rgba(255,255,255,0.03); }

.history-timeline { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 0; }

.timeline-dot {
  width: 0.75rem;
  height: 0.75rem;
  background: #ff6600;
  border-radius: 50%;
  box-shadow: 0 0 0 3px rgba(255, 102, 0, 0.2);
}

.history-content {
  flex: 1;
}

.history-content .history-header.row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
.history-meta { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; }
.history-amount { font-weight: 800; color: #ffb37a; }
.history-amount.positive { color: #10b981; }
.history-amount.negative { color: #ef4444; }
.history-time { color: rgba(255,255,255,0.65); font-size: 0.85rem; }

.history-content .history-header h4 {
  font-size: 1rem;
  font-weight: 600;
  color: #ffffff;
  margin: 0;
}

.history-time {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.6);
}

.history-event { font-size: 0.85rem; color: rgba(255, 255, 255, 0.8); margin: 0; line-height: 1.3; }

.history-effects {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
}

.effect-item {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.375rem 0.75rem;
  background: rgba(255, 255, 255, 0.05);
  border-radius: 0.375rem;
  font-size: 0.875rem;
}

.effect-label {
  color: rgba(255, 255, 255, 0.7);
}

.effect-value {
  font-weight: 600;
}

.effect-value.positive {
  color: #10b981;
}

.effect-value.negative {
  color: #ef4444;
}

/* Analytics Tab */
.analytics-section {
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
}

.coming-soon {
  text-align: center;
  max-width: 400px;
}

.analytics-icon {
  margin-bottom: 2rem;
  display: flex;
  justify-content: center;
}

.coming-soon h3 {
  font-size: 1.5rem;
  font-weight: 700;
  color: #ffffff;
  margin: 0 0 0.5rem 0;
}

.coming-soon p {
  color: rgba(255, 255, 255, 0.7);
  margin: 0;
  line-height: 1.5;
}

/* Responsive Design */
@media (max-width: 768px) {
  .overview-grid {
    grid-template-columns: 1fr;
  }

  .vehicles-grid {
    grid-template-columns: 1fr;
  }

  .tabs-header {
    flex-direction: column;
  }

  .tab-button {
    padding: 0.5rem 0.75rem;
    font-size: 0.8rem;
  }

  .vehicle-header {
    padding: 1rem;
  }

  .policy-selection {
    padding: 0.75rem 1rem;
    flex-direction: column;
    gap: 1rem;
    align-items: stretch;
  }

  .perk-item {
    grid-template-columns: 1fr;
    gap: 0.75rem;
  }

  .editor-footer {
    flex-direction: column;
    gap: 1rem;
    align-items: stretch;
  }
}

/* Glass Card Hover Effects */
.glass-card-hover:hover {
  background: rgba(255, 255, 255, 0.08);
  border-color: rgba(255, 102, 0, 0.2);
  transform: translateY(-2px);
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.4);
}

.glass-card {
  background: rgba(255, 255, 255, 0.05);
  backdrop-filter: blur(20px);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.75rem;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3);
  transition: all 0.3s ease;
}
/* End of modern styles */

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
