<template>
  <Teleport to="body">
    <div v-if="open" class="modal-overlay" @click="emit('close')">
      <div class="modal-content panel" @click.stop>
        <!-- Close Button -->
        <button class="close-button" @click="emit('close')">
          <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
          </svg>
        </button>

        <!-- Header -->
        <div class="editor-header">
          <div class="header-left">
            <div class="header-icon">
              <svg class="w-6 h-6 text-orange-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.827 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.827 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.827-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.827-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path>
              </svg>
            </div>
            <div class="header-text">
              <h3 class="modal-title">Edit Policy - {{ veh.name }}</h3>
              <p class="modal-subtitle">Customize your coverage options</p>
            </div>
          </div>
          <div class="header-right">
            <div class="premium-tag">
              <span class="tag-label">{{ getRenewalLabel() }} Premium</span>
              <span class="tag-amount text-glow">{{ units.beamBucks(selectedPolicyPremium) }}</span>
            </div>
          </div>
        </div>

        <!-- Policy Type Selection -->
        <div class="policy-type-section glass-card">
          <div class="section-header">
            <span class="section-title">Select Policy Type</span>
          </div>
          <div class="policy-types-grid">
            <button
              v-for="policyType in availablePolicyTypes"
              :key="policyType.id"
              @click="selectPolicyType(policyType.id)"
              :class="['policy-type-button', {
                active: selectedPolicyType === policyType.id,
                disabled: !applicablePolicyIds.includes(policyType.id)
              }]"
              :disabled="!applicablePolicyIds.includes(policyType.id)"
            >
              <span class="type-name">{{ policyType.name }}</span>
              <span class="type-description">{{ policyType.description }}</span>
              <span v-if="policyType.id === 0" class="type-cost">$0/month</span>
              <span v-else class="type-cost">{{ units.beamBucks(policyType.premium || 0) }}/mo</span>
            </button>
          </div>
        </div>

        <!-- Dedicated Cards for Repair Time and Renewal Period -->
        <div v-if="selectedPolicyType !== 0 && currentPolicy" class="dedicated-cards">
          <!-- Repair Time Card -->
          <div v-if="currentPolicy.perks?.repairTime?.changeability?.changeable" class="dedicated-card glass-card">
            <div class="section-header">
              <div class="section-title-cost">
                <span class="section-title">Repair Time</span>
                <span class="section-cost">{{ priceForPerk(veh, currentPolicy, 'repairTime') }}</span>
              </div>
            </div>
            
            <div v-if="currentPolicy.perks.repairTime.changeability?.changeParams?.choices" class="choices-grid">
              <button
                v-for="(choice, idx) in currentPolicy.perks.repairTime.changeability.changeParams.choices"
                :key="idx"
                @click="() => onVehPerkChange(veh, currentPolicy, 'repairTime', idx, choice)"
                :class="['choice-button', { selected: currentIndex0(veh, currentPolicy, 'repairTime') === idx }]"
              >
                <span class="choice-label">{{ formatRepairTime(choice) }}</span>
                <span class="choice-cost">{{ getChoiceCost(currentPolicy.perks.repairTime, idx) }}</span>
                <span v-if="isOriginal('repairTime', idx) && selectedPolicyType === veh.policyId" class="current-badge">Current</span>
              </button>
            </div>
          </div>

          <!-- Renewal Period Card -->
          <div v-if="currentPolicy.perks?.renewal?.changeability?.changeable" class="dedicated-card glass-card">
            <div class="section-header">
              <div class="section-title-cost">
                <span class="section-title">Renewal Period</span>
                <span class="section-cost">{{ priceForPerk(veh, currentPolicy, 'renewal') }}</span>
              </div>
            </div>
            
            <div v-if="currentPolicy.perks.renewal.changeability?.changeParams?.choices" class="choices-grid">
              <button
                v-for="(choice, idx) in currentPolicy.perks.renewal.changeability.changeParams.choices"
                :key="idx"
                @click="() => onVehPerkChange(veh, currentPolicy, 'renewal', idx, choice)"
                :class="['choice-button', { selected: currentIndex0(veh, currentPolicy, 'renewal') === idx }]"
              >
                <span class="choice-label">{{ formatRenewalTime(choice) }}</span>
                <span class="choice-cost">{{ getChoiceCost(currentPolicy.perks.renewal, idx) }}</span>
                <span v-if="isOriginal('renewal', idx) && selectedPolicyType === veh.policyId" class="current-badge">Current</span>
              </button>
            </div>
          </div>
        </div>

        <!-- Configuration Sections - Only show if not "No Insurance" -->
        <div v-if="selectedPolicyType !== 0" class="config-sections">
          <div class="config-grid">
            <!-- Left Column -->
            <div class="config-column">
              <template v-for="(perk, perkName) in leftColumnPerks" :key="perkName">
                <div v-if="perk.changeability?.changeable" class="config-section glass-card">
                  <div class="section-header">
                    <div class="section-title-cost">
                      <span class="section-title">{{ perk.niceName }}</span>
                      <span class="section-cost">{{ priceForPerk(veh, currentPolicy, perkName) }}</span>
                    </div>
                  </div>
                  <div v-if="isBooleanPerk(perk)" class="switch-container">
                    <div class="switch-info">
                      <p class="switch-label">{{ perk.niceName }}</p>
                      <p class="switch-description">{{ getBoolValue(perkName) ? 'Enabled' : 'Disabled' }}</p>
                    </div>
                    <div class="switch-toggle" :class="{ active: getBoolValue(perkName) }" @click="toggleBoolPerk(perkName)" :key="'switch-' + perkName + '-' + getBoolValue(perkName)">
                      <div class="switch-thumb"></div>
                    </div>
                  </div>
                  <div v-else-if="perk.changeability?.changeParams?.choices" class="choices-grid">
                    <button
                      v-for="(choice, idx) in perk.changeability.changeParams.choices"
                      :key="idx"
                      @click="() => onVehPerkChange(veh, currentPolicy, perkName, idx, choice)"
                      :class="['choice-button', { selected: currentIndex0(veh, currentPolicy, perkName) === idx }]"
                    >
                      <span class="choice-label">{{ formatChoice(perk, choice) }}</span>
                      <span class="choice-cost">{{ getChoiceCost(perk, idx) }}</span>
                      <span v-if="isOriginal(perkName, idx) && selectedPolicyType === veh.policyId" class="current-badge">Current</span>
                    </button>
                  </div>
                </div>
              </template>
            </div>

            <!-- Right Column -->
            <div class="config-column">
              <template v-for="(perk, perkName) in rightColumnPerks" :key="perkName">
                <div v-if="perk.changeability?.changeable" class="config-section glass-card">
                  <div class="section-header">
                    <div class="section-title-cost">
                      <span class="section-title">{{ perk.niceName }}</span>
                      <span class="section-cost">{{ priceForPerk(veh, currentPolicy, perkName) }}</span>
                    </div>
                  </div>
                  <div v-if="isBooleanPerk(perk)" class="switch-container">
                    <div class="switch-info">
                      <p class="switch-label">{{ perk.niceName }}</p>
                      <p class="switch-description">{{ getBoolValue(perkName) ? 'Enabled' : 'Disabled' }}</p>
                    </div>
                    <div class="switch-toggle" :class="{ active: getBoolValue(perkName) }" @click="toggleBoolPerk(perkName)" :key="'switch-' + perkName + '-' + getBoolValue(perkName)">
                      <div class="switch-thumb"></div>
                    </div>
                  </div>
                  <div v-else-if="perk.changeability?.changeParams?.choices" class="choices-grid">
                    <button
                      v-for="(choice, idx) in perk.changeability.changeParams.choices"
                      :key="idx"
                      @click="() => onVehPerkChange(veh, currentPolicy, perkName, idx, choice)"
                      :class="['choice-button', { selected: currentIndex0(veh, currentPolicy, perkName) === idx }]"
                    >
                      <span class="choice-label">{{ formatChoice(perk, choice) }}</span>
                      <span class="choice-cost">{{ getChoiceCost(perk, idx) }}</span>
                      <span v-if="isOriginal(perkName, idx) && selectedPolicyType === veh.policyId" class="current-badge">Current</span>
                    </button>
                  </div>
                </div>
              </template>
            </div>
          </div>
        </div>

        <!-- Action Buttons -->
        <div class="action-buttons">
          <button
            @click="handleApply"
            :class="['action-button', selectedPolicyType === 0 ? 'remove-insurance' : 'glass-button-primary']"
          >
            {{ selectedPolicyType === 0 ? 'Remove Insurance' : 'Apply Changes' }}
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { Teleport, computed, ref, onMounted, watch } from 'vue'
import { lua } from '@/bridge'

const props = defineProps({
  open: { type: Boolean, default: false },
  veh: { type: Object, required: true },
  policiesData: { type: Array, default: () => [] },
  vehPremium: { type: Number, default: 0 },
  currentPolicyId: { type: Function, required: true },
  currentIndex0: { type: Function, required: true },
  formatChoice: { type: Function, required: true },
  priceForPerk: { type: Function, required: true },
  onVehPerkChange: { type: Function, required: true },
  tempOverrides: { type: Object, default: () => ({}) },
  onPolicyChange: { type: Function, default: null },
  units: { type: Object, required: true }
})

const emit = defineEmits(['close', 'apply'])

// Initialize with the current policy ID of the vehicle
const selectedPolicyType = ref(props.veh.policyId || 0)

// Reactive state for applicable policies
const applicablePolicyIds = ref([])

// Get applicable policies for this vehicle
const getApplicablePolicies = async () => {
  try {
    console.log('Getting applicable policies for vehicle:', props.veh.id, props.veh)
    const ids = await lua.career_modules_insurance.getApplicablePoliciesForVehicle(props.veh.id)
    console.log('Applicable policy IDs returned:', ids)

    if (Array.isArray(ids) && ids.length > 0) {
      applicablePolicyIds.value = ids
      console.log('Using returned applicable policy IDs:', applicablePolicyIds.value)
    } else {
      // If no policies returned, default to basic policies
      console.warn('No applicable policies returned, using defaults')
      applicablePolicyIds.value = [0, 1] // Always include no insurance and basic insurance
    }

    // Always include the current policy if it's already assigned
    if (props.veh.policyId && !applicablePolicyIds.value.includes(props.veh.policyId)) {
      console.log('Adding current policy ID:', props.veh.policyId)
      applicablePolicyIds.value.push(props.veh.policyId)
    }
    console.log('Final applicable policy IDs:', applicablePolicyIds.value)
  } catch (error) {
    console.error('Failed to get applicable policies:', error)
    // Better fallback: only show no insurance and basic insurance, not ALL policies
    applicablePolicyIds.value = [0, 1]
    console.log('Using fallback applicable policy IDs:', applicablePolicyIds.value)
  }
}

// Calculate premium for selected policy (reactive to policy selection and perk changes)
const selectedPolicyPremium = computed(() => {
  if (!currentPolicy.value) return 0

  // If we have vehPremium prop (calculated by parent), use it for the current/selected policy
  // Otherwise fall back to the policy's base premium
  if (props.vehPremium && selectedPolicyType.value === props.veh.policyId) {
    return props.vehPremium
  }

  // Use the base premium from the policy data
  return currentPolicy.value.premium || 0
})

// Filter policies to only show applicable ones
const availablePolicyTypes = computed(() => {
  const allPolicies = props.policiesData || []
  console.log('Filtering policies - All policies:', allPolicies.length, 'Applicable IDs:', applicablePolicyIds.value)

  if (applicablePolicyIds.value.length === 0) {
    console.log('No applicable policies loaded yet, showing current policy')
    // If we don't have applicable policies yet, show loading or current policy only
    const currentPolicy = allPolicies.find(p => p.id === props.veh.policyId)
    return currentPolicy ? [currentPolicy] : []
  }

  const filteredPolicies = allPolicies
    .filter(policy => {
      const isApplicable = applicablePolicyIds.value.includes(policy.id)
      console.log(`Policy ${policy.id} (${policy.name}): ${isApplicable ? 'APPLICABLE' : 'NOT APPLICABLE'}`)
      return isApplicable
    })
    .map(policy => ({
      id: policy.id,
      name: policy.name,
      description: policy.description,
      premium: policy.premium
    }))

  console.log('Final filtered policies:', filteredPolicies.length, filteredPolicies.map(p => p.id))
  return filteredPolicies
})

const currentPolicy = computed(() => {
  return (props.policiesData || []).find(p => p.id === selectedPolicyType.value)
})

// Dynamically get all perks and split them into two columns
// Exclude perks that have their own dedicated cards (repairTime, renewal)
const leftColumnPerks = computed(() => {
  if (!currentPolicy.value || !currentPolicy.value.perks) return {}

  const perks = currentPolicy.value.perks
  // Exclude perks that have their own dedicated sections
  const excludedPerks = ['repairTime', 'renewal']
  const perkNames = Object.keys(perks).filter(name => !excludedPerks.includes(name))
  const mid = Math.ceil(perkNames.length / 2)
  const leftPerks = {}

  for (let i = 0; i < mid; i++) {
    const perkName = perkNames[i]
    leftPerks[perkName] = perks[perkName]
  }

  return leftPerks
})

const rightColumnPerks = computed(() => {
  if (!currentPolicy.value || !currentPolicy.value.perks) return {}

  const perks = currentPolicy.value.perks
  // Exclude perks that have their own dedicated sections
  const excludedPerks = ['repairTime', 'renewal']
  const perkNames = Object.keys(perks).filter(name => !excludedPerks.includes(name))
  const mid = Math.ceil(perkNames.length / 2)
  const rightPerks = {}

  for (let i = mid; i < perkNames.length; i++) {
    const perkName = perkNames[i]
    rightPerks[perkName] = perks[perkName]
  }

  return rightPerks
})

function selectPolicyType(policyId) {
  console.log('Selecting policy:', policyId, 'for vehicle:', props.veh.id)
  selectedPolicyType.value = policyId

  // Notify parent component to recalculate premium for the new policy
  if (props.onPolicyChange) {
    const newPolicy = (props.policiesData || []).find(p => p.id === policyId)
    if (newPolicy) {
      console.log('Notifying parent of policy change:', newPolicy.name)
      props.onPolicyChange(props.veh, newPolicy)
    }
  }
}



function getChoiceCost(perk, idx) {
  const ca = perk?.changeability?.changeParams
  if (!ca) return ''
  const infl = ca.premiumInfluence
  const cost = Array.isArray(infl) ? (infl[idx] ?? 0) : (infl || 0)
  return props.units.beamBucks(cost)
}

// Get current repair time value
const currentRepairTime = computed(() => {
  if (!currentPolicy.value?.perks?.repairTime) return 0
  const repairTime = currentPolicy.value.perks.repairTime
  const currentIdx = props.currentIndex0(props.veh, currentPolicy.value, 'repairTime')
  if (repairTime.changeability?.changeParams?.choices && currentIdx >= 0) {
    return repairTime.changeability.changeParams.choices[currentIdx] || 0
  }
  return repairTime.plValue || repairTime.baseValue || 0
})

// Format repair time from seconds to readable format
function formatRepairTime(seconds) {
  const secs = Number(seconds) || 0
  const minutes = Math.round(secs / 60)

  if (minutes < 60) {
    return `${minutes} min`
  } else {
    const hours = Math.round(minutes / 60)
    return `${hours} hour${hours > 1 ? 's' : ''}`
  }
}

// Format renewal time from seconds to readable format
function formatRenewalTime(seconds) {
  const secs = Number(seconds) || 0
  const minutes = Math.round(secs / 60)

  if (minutes < 60) {
    return `${minutes} min`
  } else if (minutes === 60) {
    return '1 hour'
  } else {
    const hours = Math.round(minutes / 60)
    return `${hours} hour${hours > 1 ? 's' : ''}`
  }
}

// Original/current selection helpers (before editing)
function originalIndex(perkName) {
  try {
    const policy = (props.policiesData || []).find(p => p.id === props.veh.policyId)
    const perk = policy?.perks?.[perkName]
    const choices = perk?.changeability?.changeParams?.choices || []
    if (props.veh?.perks?.[perkName]?.index !== undefined) {
      return Number(props.veh.perks[perkName].index) || 0
    }
    const baseVal = perk?.plValue ?? perk?.baseValue
    const idx = choices.indexOf(baseVal)
    return idx >= 0 ? idx : 0
  } catch (_) { return 0 }
}

function isOriginal(perkName, idx) {
  if (selectedPolicyType.value !== props.veh.policyId) return false
  return originalIndex(perkName) === Number(idx)
}

function isBooleanPerk(perk) {
  if (!perk?.changeability?.changeParams?.choices) return false
  const choices = perk.changeability.changeParams.choices
  return choices.length === 2 &&
         ((choices[0] === true && choices[1] === false) ||
          (choices[0] === false && choices[1] === true))
}

function getBoolValue(perkName) {
  console.log('Getting bool value for perk:', perkName)

  // First check for temporary overrides
  if (props.veh && props.tempOverrides[props.veh.id] && props.tempOverrides[props.veh.id][selectedPolicyType.value] && props.tempOverrides[props.veh.id][selectedPolicyType.value][perkName] !== undefined) {
    const tempOverrideIdx = props.tempOverrides[props.veh.id][selectedPolicyType.value][perkName]
    const perk = currentPolicy.value?.perks?.[perkName]
    if (perk?.changeability?.changeParams?.choices) {
      const choices = perk.changeability.changeParams.choices
      const tempValue = choices[tempOverrideIdx]
      console.log('  Using temp override value:', tempValue, 'from index:', tempOverrideIdx)
      return tempValue === true || String(tempValue) === 'true'
    }
  }

  const perk = currentPolicy.value?.perks?.[perkName]
  const vehicleValue = props.veh?.perks?.[perkName]?.value
  const defaultValue = perk?.plValue ?? perk?.baseValue
  const finalValue = vehicleValue ?? defaultValue
  console.log('  Vehicle value:', vehicleValue)
  console.log('  Default value:', defaultValue)
  console.log('  Final value:', finalValue)
  return finalValue === true || String(finalValue) === 'true'
}

function toggleBoolPerk(perkName) {
  console.log('Toggling boolean perk:', perkName)
  const currentValue = getBoolValue(perkName)
  const newValue = !currentValue
  console.log('  Current value:', currentValue, 'New value:', newValue)

  // Find the index of the new value in the choices
  const perk = currentPolicy.value?.perks?.[perkName]
  console.log('  Perk data:', perk)
  if (perk?.changeability?.changeParams?.choices) {
    const choices = perk.changeability.changeParams.choices
    console.log('  Choices:', choices)
    const idx = choices.findIndex(choice => choice === newValue)
    console.log('  Index of new value:', idx)
    if (idx >= 0) {
      console.log('  Calling onVehPerkChange with:', props.veh.id, currentPolicy.value.id, perkName, idx, newValue)
      props.onVehPerkChange(props.veh, currentPolicy.value, perkName, idx, newValue)
    } else {
      console.error('  Could not find index for value:', newValue)
    }
  } else {
    console.error('  No choices found for perk:', perkName)
  }
}

function getRenewalPeriodSeconds() {
  const currentPolicy = (props.policiesData || []).find(p => p.id === selectedPolicyType.value)
  if (!currentPolicy || !currentPolicy.perks || !currentPolicy.perks.renewal) {
    return 1800 // Default to 30 minutes (1800 seconds)
  }

  // Check for temp overrides first
  if (props.veh && props.tempOverrides[props.veh.id] &&
      props.tempOverrides[props.veh.id][selectedPolicyType.value] &&
      props.tempOverrides[props.veh.id][selectedPolicyType.value].renewal !== undefined) {
    const tempOverrideIdx = props.tempOverrides[props.veh.id][selectedPolicyType.value].renewal
    if (currentPolicy.perks.renewal.changeability?.changeParams?.choices) {
      const choices = currentPolicy.perks.renewal.changeability.changeParams.choices
      return Number(choices[tempOverrideIdx]) || 1800
    }
  }

  const renewalValue = props.veh?.perks?.['renewal']?.value ??
                      (currentPolicy.perks.renewal.plValue) ??
                      (currentPolicy.perks.renewal.baseValue)
  return Number(renewalValue) || 1800
}

function getRenewalLabel() {
  const seconds = getRenewalPeriodSeconds()
  const minutes = Math.round(seconds / 60)

  if (minutes < 60) {
    return `${minutes} Min`
  } else if (minutes === 60) {
    return '1 Hour'
  } else {
    const hours = Math.round(minutes / 60)
    return `${hours} Hour${hours > 1 ? 's' : ''}`
  }
}

function handleApply() {
  console.log('Attempting to apply policy:', selectedPolicyType.value, 'to vehicle:', props.veh.id)
  console.log('Applicable policies:', applicablePolicyIds.value)
  console.log('Is selected policy applicable?', applicablePolicyIds.value.includes(selectedPolicyType.value))

  // Only allow applying if the policy is applicable
  if (!applicablePolicyIds.value.includes(selectedPolicyType.value)) {
    console.error('Cannot apply policy - not applicable for this vehicle')
    return
  }

  // Emit the selected policy data
  emit('apply', {
    selectedPolicyId: selectedPolicyType.value,
    vehicleId: props.veh.id
  })
}

// Call getApplicablePolicies when component mounts or when modal opens
onMounted(() => {
  if (props.open) {
    console.log('Modal opened on mount, getting applicable policies')
    getApplicablePolicies()
  }
})

// Watch for modal opening to refresh applicable policies
watch(() => props.open, (newOpen) => {
  if (newOpen) {
    console.log('Modal opened via watch, getting applicable policies')
    // Reset applicable policies when modal opens
    applicablePolicyIds.value = []
    getApplicablePolicies()
  } else {
    console.log('Modal closed, clearing applicable policies')
    // Clear applicable policies when modal closes
    applicablePolicyIds.value = []
  }
})

// Watch for vehicle changes to refresh policies
watch(() => props.veh?.id, (newVehId) => {
  if (newVehId && props.open) {
    console.log('Vehicle changed, refreshing applicable policies for:', newVehId)
    applicablePolicyIds.value = []
    getApplicablePolicies()
  }
})


</script>

<style scoped lang="scss">
.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.8);
  backdrop-filter: blur(8px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
  padding: 1rem;
}

.modal-content {
  width: 60vw;
  max-width: 1100px;
  max-height: 95vh;
  overflow: hidden;
  padding: 0;
  border-radius: 20px;
  position: relative;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.05);
  display: flex;
  flex-direction: column;
}

/* Enhanced scrollbar styling for modal content */
/* Enhanced scrollbar styling for panel */
.panel::-webkit-scrollbar {
  width: 12px;
}
.panel::-webkit-scrollbar-track {
  background: rgba(255, 255, 255, 0.02);
  border-radius: 10px;
}
.panel::-webkit-scrollbar-thumb {
  background: rgba(255, 255, 255, 0.15);
  border-radius: 10px;
  border: 3px solid transparent;
  background-clip: padding-box;
}
.panel::-webkit-scrollbar-thumb:hover {
  background: rgba(255, 255, 255, 0.25);
}

.panel {
  background: linear-gradient(
    135deg,
    rgba(23, 23, 23, 0.98) 0%,
    rgba(15, 15, 15, 0.98) 50%,
    rgba(8, 8, 8, 0.98) 100%
  );
  border: 1px solid rgba(255, 102, 0, 0.2);
  border-radius: 20px;
  backdrop-filter: blur(20px);
  position: relative;
  overflow-y: auto;
  overflow-x: hidden;
  flex: 1;
  display: flex;
  flex-direction: column;
  padding: 0;
}

.panel::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 2px;
  background: linear-gradient(90deg, transparent, rgba(255, 102, 0, 0.4), transparent);
  z-index: 1;
}

.close-button {
  position: absolute;
  top: 1.5rem;
  right: 1.5rem;
  z-index: 15;
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 12px;
  width: 44px;
  height: 44px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--bng-off-white);
  cursor: pointer;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  backdrop-filter: blur(10px);
}

.close-button:hover {
  background: rgba(239, 68, 68, 0.15);
  border-color: rgba(239, 68, 68, 0.3);
}

.editor-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 2rem 3rem 1.5rem 2rem;
  border-bottom: 1px solid rgba(255, 102, 0, 0.15);
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.02), transparent);
  position: sticky;
  top: 0;
  z-index: 5;
  backdrop-filter: blur(10px);
}

.header-left {
  display: flex;
  align-items: center;
  gap: 1.25rem;
}

.header-icon {
  width: 3.5rem;
  height: 3.5rem;
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.15), rgba(255, 102, 0, 0.08));
  border: 1px solid rgba(255, 102, 0, 0.25);
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  backdrop-filter: blur(10px);
}

.header-text {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.modal-title {
  font-size: 1.75rem;
  font-weight: 800;
  color: var(--bng-off-white);
  margin: 0;
  text-shadow: 0 2px 4px rgba(0, 0, 0, 0.3);
  letter-spacing: -0.025em;
}

.modal-subtitle {
  font-size: 0.95rem;
  color: rgba(255, 255, 255, 0.7);
  margin: 0;
  font-weight: 500;
}

.header-right {
  display: flex;
  align-items: center;
}

.premium-tag {
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.15), rgba(255, 102, 0, 0.08));
  border: 1px solid rgba(255, 102, 0, 0.25);
  border-radius: 14px;
  padding: 1rem 1.25rem;
  text-align: right;
  min-width: 160px;
  backdrop-filter: blur(10px);
}

.tag-label {
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.6);
  display: block;
  margin-bottom: 0.375rem;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.tag-amount {
  font-size: 1.25rem;
  font-weight: 800;
  color: var(--bng-orange);
  text-shadow: 0 0 15px rgba(255, 102, 0, 0.4);
}

.text-glow {
  text-shadow: 0 0 15px rgba(255, 102, 0, 0.6);
}

.policy-type-section {
  margin: 2rem 3rem 2rem 2rem;
  padding: 1.5rem;
  background: rgba(255, 255, 255, 0.02);
  border-radius: 16px;
  border: 1px solid rgba(255, 255, 255, 0.05);
}

.dedicated-cards {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1.5rem;
  margin: 2rem 3rem 2rem 2rem;
}

.dedicated-card {
  padding: 1.5rem;
  border-radius: 16px;
  background: rgba(255, 255, 255, 0.02);
  border: 1px solid rgba(255, 255, 255, 0.05);
  backdrop-filter: blur(8px);
  transition: all 0.3s ease;
}

.dedicated-card:hover {
  background: rgba(255, 255, 255, 0.04);
  border-color: rgba(255, 102, 0, 0.15);
  transform: translateY(-1px);
}

.repair-time-display, .renewal-display {
  text-align: center;
  margin: 1rem 0;
}

.current-time, .current-renewal {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.25rem;
}

.time-value, .renewal-value {
  font-size: 1.25rem;
  font-weight: 800;
  color: var(--bng-orange);
  text-shadow: 0 0 15px rgba(255, 102, 0, 0.4);
}

.time-label, .renewal-label {
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.6);
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.section-header {
  display: flex;
  align-items: center;
  gap: 1rem;
  margin-bottom: 1.5rem;
}



.section-title {
  font-size: 1.125rem;
  font-weight: 700;
  color: var(--bng-off-white);
  letter-spacing: -0.01em;
}

.section-title-cost {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex: 1;
}

.section-cost {
  font-size: 1.125rem;
  font-weight: 800;
  color: var(--bng-orange);
  text-shadow: 0 0 10px rgba(255, 102, 0, 0.3);
}

.policy-types-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 1.25rem;
  align-items: start;
}

.policy-type-button {
  min-height: 6rem;
  border-radius: 14px;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  text-align: center;
  padding: 1.25rem 1rem;
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  color: var(--bng-off-white);
  cursor: pointer;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  backdrop-filter: blur(8px);
  position: relative;
  overflow: hidden;
  justify-content: center;
}

.policy-type-button::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.05), transparent);
  opacity: 0;
  transition: opacity 0.3s ease;
}

.policy-type-button:hover {
  background: rgba(255, 102, 0, 0.08);
  border-color: rgba(255, 102, 0, 0.3);
  transform: translateY(-2px);
}

.policy-type-button:hover::before {
  opacity: 1;
}

.policy-type-button.active {
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.2), rgba(255, 102, 0, 0.1));
  border: 2px solid rgba(255, 102, 0, 0.6);
  transform: translateY(-1px);
}

.policy-type-button.active::before {
  opacity: 1;
}

.policy-type-button.disabled {
  background: rgba(255, 255, 255, 0.02);
  border-color: rgba(255, 255, 255, 0.04);
  opacity: 0.5;
  cursor: not-allowed;
  transform: none;
}

.policy-type-button.disabled:hover {
  background: rgba(255, 255, 255, 0.02);
  border-color: rgba(255, 255, 255, 0.04);
  transform: none;
}

.policy-type-button.disabled .type-name,
.policy-type-button.disabled .type-description,
.policy-type-button.disabled .type-cost {
  opacity: 0.6;
}

.type-name {
  font-weight: 800;
  font-size: 1rem;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.2);
  line-height: 1.2;
  margin-bottom: 0.25rem;
}

.type-description {
  font-size: 0.85rem;
  color: rgba(255, 255, 255, 0.8);
  line-height: 1.4;
  flex: 1;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  margin-bottom: 0.5rem;
}

.type-cost {
  font-size: 0.9rem;
  font-weight: 800;
  text-shadow: 0 1px 2px rgba(239, 68, 68, 0.2);
  margin-top: auto;
}

.config-sections {
  margin: 0 3rem 2rem 2rem;
}

.config-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1.5rem;
}

.config-column {
  display: flex;
  flex-direction: column;
  gap: 1.25rem;
}

.config-section {
  padding: 1.5rem;
  border-radius: 16px;
  background: rgba(255, 255, 255, 0.02);
  border: 1px solid rgba(255, 255, 255, 0.05);
  backdrop-filter: blur(8px);
  transition: all 0.3s ease;
}

.config-section:hover {
  background: rgba(255, 255, 255, 0.04);
  border-color: rgba(255, 102, 0, 0.15);
  transform: translateY(-1px);
}

.choices-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
  gap: 0.75rem;
}

.choice-button {
  height: 4.5rem;
  border-radius: 12px;
  display: flex;
  flex-direction: column;
  gap: 0.375rem;
  text-align: center;
  padding: 1rem;
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  color: var(--bng-off-white);
  cursor: pointer;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  backdrop-filter: blur(6px);
  position: relative;
  overflow: hidden;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.03);
}

.choice-button::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.05), transparent);
  opacity: 0;
  transition: opacity 0.3s ease;
}

.choice-button:hover {
  background: rgba(255, 102, 0, 0.08);
  border-color: rgba(255, 102, 0, 0.3);
  transform: translateY(-1px);
}

.choice-button:hover::before {
  opacity: 1;
}

.choice-button.selected {
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.22), rgba(255, 102, 0, 0.12));
  border: 2px solid rgba(255, 102, 0, 0.9);
  box-shadow: 0 8px 28px rgba(255, 102, 0, 0.25), 0 0 0 3px rgba(255, 102, 0, 0.15);
  transform: translateY(-1px);
}

.choice-button.selected::before {
  opacity: 1;
}

.current-badge {
  content: 'Current';
  position: absolute;
  top: 8px;
  right: 10px;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 0.7rem;
  font-weight: 800;
  letter-spacing: 0.02em;
  color: #111;
  background: #ffb37a;
  box-shadow: 0 2px 8px rgba(255, 102, 0, 0.35);
}

.choice-button.selected .choice-label { color: #111; }
.choice-button.selected .choice-cost { color: #1a1a1a; opacity: 0.9; }

.choice-label {
  font-weight: 700;
  font-size: 0.9rem;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.2);
}

.choice-cost {
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.7);
  font-weight: 600;
}

.switch-container {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1.25rem;
  background: rgba(255, 255, 255, 0.02);
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.06);
  backdrop-filter: blur(6px);
  transition: all 0.3s ease;
}

.switch-container:hover {
  background: rgba(255, 255, 255, 0.04);
  border-color: rgba(255, 102, 0, 0.15);
}

.switch-info {
  flex: 1;
}

.switch-label {
  font-weight: 700;
  color: var(--bng-off-white);
  margin: 0 0 0.25rem 0;
  font-size: 0.95rem;
}

.switch-description {
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.75);
  margin: 0;
}

.switch-toggle {
  width: 3.25rem;
  height: 1.625rem;
  background: rgba(255, 255, 255, 0.15);
  border-radius: 13px;
  position: relative;
  cursor: pointer;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  border: 1px solid rgba(255, 255, 255, 0.1);
}

.switch-toggle.active {
  background: linear-gradient(135deg, #ff6600, #ff8533);
  border-color: rgba(255, 102, 0, 0.3);
}

.switch-thumb {
  width: 1.375rem;
  height: 1.375rem;
  background: #ffffff;
  border-radius: 50%;
  position: absolute;
  top: 0.125rem;
  left: 0.125rem;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}

.switch-toggle.active .switch-thumb {
  transform: translateX(1.625rem);
}

.action-buttons {
  display: flex;
  justify-content: center;
  gap: 1.25rem;
  margin: 2rem 3rem 2rem 2rem;
  padding: 1.5rem;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  background: linear-gradient(
    135deg,
    rgba(23, 23, 23, 0.98) 0%,
    rgba(15, 15, 15, 0.98) 50%,
    rgba(8, 8, 8, 0.98) 100%
  );
  position: sticky;
  bottom: 0;
  backdrop-filter: blur(10px);
}

.action-button {
  padding: 1rem 2.5rem;
  border-radius: 14px;
  font-size: 1rem;
  font-weight: 700;
  cursor: pointer;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  border: none;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  position: relative;
  overflow: hidden;
}

.glass-button-primary {
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.9), rgba(255, 153, 51, 0.9));
  color: #ffffff;
  border: 1px solid rgba(255, 102, 0, 0.3);
}

.glass-button-primary:hover {
  background: linear-gradient(135deg, #ff6600, #ff8533);
  transform: translateY(-2px);
}

.remove-insurance {
  background: linear-gradient(135deg, #ef4444, #dc2626);
  color: #fff;
  border: 1px solid rgba(239, 68, 68, 0.3);
}

.remove-insurance:hover {
  background: linear-gradient(135deg, #dc2626, #b91c1c);
  transform: translateY(-2px);
}

.glass-card {
  background: rgba(255, 255, 255, 0.03);
  backdrop-filter: blur(12px);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 16px;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}

.glass-card:hover {
  background: rgba(255, 255, 255, 0.05);
  border-color: rgba(255, 102, 0, 0.2);
  transform: translateY(-2px);
}

/* Responsive Design */
@media (max-width: 1200px) {
  .policy-types-grid {
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1rem;
  }

  .policy-type-button {
    min-height: 5.5rem;
    padding: 1rem;
  }

  .type-name {
    font-size: 0.9rem;
  }

  .type-description {
    font-size: 0.8rem;
    -webkit-line-clamp: 2;
  }

  .type-cost {
    font-size: 0.85rem;
  }

  .dedicated-cards {
    grid-template-columns: 1fr;
    gap: 1rem;
  }

  .modal-title {
    font-size: 1.5rem;
  }

  .header-icon {
    width: 3rem;
    height: 3rem;
  }
}

@media (max-width: 768px) {
  .modal-content {
    width: 90vw;
    margin: 0.5rem;
  }

  .editor-header {
    padding: 1.5rem 2.5rem 1.5rem 1.5rem;
    flex-direction: column;
    gap: 1rem;
    text-align: center;
  }

  .policy-types-grid {
    grid-template-columns: 1fr;
    gap: 0.75rem;
  }

  .policy-type-button {
    min-height: 5rem;
    padding: 0.875rem;
  }

  .type-name {
    font-size: 0.85rem;
  }

  .type-description {
    font-size: 0.75rem;
    -webkit-line-clamp: 3;
  }

  .type-cost {
    font-size: 0.8rem;
  }

  .config-grid {
    grid-template-columns: 1fr;
  }

  .action-buttons {
    flex-direction: column;
    gap: 0.75rem;
    margin: 1.5rem 2.5rem 1.5rem 1.5rem;
  }

  .action-button {
    width: 100%;
  }
}
</style>