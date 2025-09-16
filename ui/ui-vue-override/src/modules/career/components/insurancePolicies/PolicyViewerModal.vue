<template>
  <Teleport to="body">
    <div v-if="open" class="modal-overlay" @click="emit('close')">
      <div class="modal-content panel" @click.stop>
        <div class="viewer">
          <div class="viewer-left">
            <div class="hero-image" :style="{ backgroundImage: `url('${veh.thumbnail}')` }"></div>
            <div class="hero-overlay">
              <h3 class="veh-name">{{ veh.name }}</h3>
              <div class="badge">{{ policyName }}</div>
              <div class="premium">
                <span class="muted">{{ getRenewalLabel() }} Premium</span>
                <span class="value">{{ units.beamBucks(monthlyPremium) }}</span>
              </div>
            </div>
          </div>
          <div class="viewer-right">
            <div class="summary-row">
              <div class="stat">
                <span class="label">{{ getRenewalLabel() }} Cost</span>
                <span class="value">{{ units.beamBucks(monthlyPremium) }}</span>
              </div>
              <div class="stat">
                <span class="label">Repair Time</span>
                <span class="value">{{ displayValue('repairTime') }}</span>
              </div>
            </div>
            <div class="config-card">
              <div class="config-title">Policy Configuration</div>
              <div class="config-grid">
                <div class="config-item">
                  <div class="config-label">Quick Repair</div>
                  <div class="config-value">
                    <span v-if="boolValue('quickRepair')" class="chip included">Included</span>
                    <span v-else class="chip">Not Included</span>
                  </div>
                </div>
                <div class="config-item">
                  <div class="config-label">Total Loss Threshold</div>
                  <div class="config-value">{{ displayValue('totalPercentage') }}</div>
                </div>
                <div class="config-item">
                  <div class="config-label">Roadside Assistance</div>
                  <div class="config-value">{{ displayValue('roadsideAssistance') }}</div>
                </div>
                <div class="config-item">
                  <div class="config-label">Deductible</div>
                  <div class="config-value">{{ displayValue('deductible') }}</div>
                </div>
                <div class="config-item">
                  <div class="config-label">Paint Coverage</div>
                  <div class="config-value">
                    <span v-if="boolValue('paintRepair')" class="chip included">Included</span>
                    <span v-else class="chip">Not Included</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
        <div class="footer-actions">
          <button type="button" class="glass-button" @click="emit('close')">Close</button>
          <button type="button" class="glass-button-primary" @click="emit('edit')">Edit Policy</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { Teleport, computed } from 'vue'

const props = defineProps({
  open: { type: Boolean, default: false },
  veh: { type: Object, required: true },
  policiesData: { type: Array, default: () => [] },
  units: { type: Object, required: true },
  priceForPerk: { type: Function, required: true },
  monthlyPremium: { type: Number, default: 0 },
  annualPremium: { type: Number, default: 0 }
})

const emit = defineEmits(['close', 'edit'])

const policyName = computed(() => {
  const p = (props.policiesData || []).find(pp => pp.id === props.veh.policyId)
  return p ? p.name : 'Unknown'
})

function formatPerkValue(perk, value) {
  const unit = (perk && perk.unit ? String(perk.unit).toLowerCase() : '')
  if (value === true) return 'true'
  if (value === false) return 'false'
  if (unit === 'time') {
    const s = Number(value) || 0
    if (s < 60) return `${s} sec`
    const m = Math.round(s / 60)
    return `${m} minutes`
  }
  if (unit.includes('percentage')) {
    return `${value}%`
  }
  if (unit === 'money') {
    return props.units.beamBucks(Number(value) || 0)
  }
  return `${value} ${perk && perk.unit ? perk.unit : ''}`.trim()
}

function getPerk(perkName) {
  const p = (props.policiesData || []).find(pp => pp.id === props.veh.policyId)
  return p && p.perks ? p.perks[perkName] : null
}

function displayValue(perkName) {
  const perk = getPerk(perkName)
  const value = props.veh?.perks?.[perkName]?.value ?? (perk && perk.plValue) ?? (perk && perk.baseValue)
  return formatPerkValue(perk, value)
}

function getRenewalPeriodSeconds() {
  const renewalPerk = getPerk('renewal')
  const renewalValue = props.veh?.perks?.['renewal']?.value ?? (renewalPerk && renewalPerk.plValue) ?? (renewalPerk && renewalPerk.baseValue)
  return Number(renewalValue) || 1800 // Default to 30 minutes (1800 seconds) if not found
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



function boolValue(perkName) {
  const perk = getPerk(perkName)
  const value = props.veh?.perks?.[perkName]?.value ?? (perk && perk.plValue) ?? (perk && perk.baseValue)
  return value === true || String(value) === 'true'
}
</script>

<style scoped lang="scss">
/* Enhanced Modal Overlay */
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

/* Modern Modal Content with Flex Structure */
.modal-content {
  width: 70vw;
  max-width: 1300px;
  max-height: 95vh;
  overflow: hidden;
  padding: 0;
  border-radius: 20px;
  position: relative;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.05);
  display: flex;
  flex-direction: column;
}

/* Enhanced Scrollbar Styling */
.modal-content::-webkit-scrollbar {
  width: 12px;
}

.modal-content::-webkit-scrollbar-track {
  background: rgba(255, 255, 255, 0.02);
  border-radius: 10px;
}

.modal-content::-webkit-scrollbar-thumb {
  background: rgba(255, 255, 255, 0.15);
  border-radius: 10px;
  border: 3px solid transparent;
  background-clip: padding-box;
}

.modal-content::-webkit-scrollbar-thumb:hover {
  background: rgba(255, 255, 255, 0.25);
}

/* Glass Morphism Panel */
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

/* Subtle Top Accent */
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

/* Viewer Layout */
.viewer {
  display: grid;
  grid-template-columns: 48% 52%;
  gap: 2rem;
  padding: 2rem 3rem 2rem 2rem;
  flex: 1;
}

/* Left Side - Vehicle Image */
.viewer-left {
  position: relative;
  border-radius: 16px;
  overflow: hidden;
  min-height: 320px;
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.1), rgba(255, 102, 0, 0.05));
  border: 1px solid rgba(255, 102, 0, 0.15);
  backdrop-filter: blur(10px);
}

.hero-image {
  position: absolute;
  inset: 0;
  background-size: cover;
  background-position: center;
  filter: saturate(0.95);
  transition: transform 0.3s ease;
}

.hero-image:hover {
  transform: scale(1.02);
}

.hero-overlay {
  position: absolute;
  inset: 0;
  padding: 2rem;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  background: linear-gradient(180deg, rgba(0,0,0,0.2) 0%, rgba(0,0,0,0.6) 60%, rgba(0,0,0,0.9) 100%);
}

/* Vehicle Name */
.veh-name {
  color: var(--bng-off-white);
  font-weight: 800;
  font-size: 1.5rem;
  margin: 0 0 0.5rem 0;
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.5);
  letter-spacing: -0.025em;
  line-height: 1.2;
}

/* Policy Badge */
.badge {
  align-self: flex-start;
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.2), rgba(255, 102, 0, 0.1));
  border: 1px solid rgba(255, 102, 0, 0.3);
  color: var(--bng-off-white);
  padding: 0.5rem 1rem;
  border-radius: 20px;
  font-size: 0.875rem;
  font-weight: 600;
  margin-bottom: 1rem;
  backdrop-filter: blur(8px);
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
}

/* Premium Display */
.premium {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
}

.premium .muted {
  color: rgba(255, 255, 255, 0.7);
  font-size: 0.875rem;
  font-weight: 500;
}

.premium .value {
  color: var(--bng-orange);
  font-weight: 800;
  font-size: 1.25rem;
  text-shadow: 0 0 15px rgba(255, 102, 0, 0.4);
}

/* Right Side - Stats and Config */
.viewer-right {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

/* Summary Stats Row */
.summary-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
}

.stat {
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 14px;
  padding: 1.25rem;
  backdrop-filter: blur(8px);
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  position: relative;
  overflow: hidden;
}

.stat::before {
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

.stat:hover {
  background: rgba(255, 255, 255, 0.06);
  border-color: rgba(255, 102, 0, 0.2);
  transform: translateY(-2px);
}

.stat:hover::before {
  opacity: 1;
}

.stat .label {
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.8rem;
  display: block;
  margin-bottom: 0.5rem;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.stat .value {
  color: var(--bng-orange);
  font-weight: 800;
  font-size: 1.125rem;
  text-shadow: 0 0 10px rgba(255, 102, 0, 0.3);
}

/* Configuration Card */
.config-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 16px;
  padding: 1.5rem;
  backdrop-filter: blur(12px);
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}

.config-card:hover {
  background: rgba(255, 255, 255, 0.05);
  border-color: rgba(255, 102, 0, 0.15);
  transform: translateY(-1px);
}

.config-title {
  color: var(--bng-off-white);
  font-weight: 700;
  font-size: 1.125rem;
  margin-bottom: 1rem;
  letter-spacing: -0.01em;
}

.config-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0,1fr));
  gap: 0.75rem;
}

.config-item {
  background: rgba(255, 255, 255, 0.02);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 12px;
  padding: 1rem 1.25rem;
  display: flex;
  align-items: center;
  justify-content: space-between;
  transition: all 0.3s ease;
  backdrop-filter: blur(6px);
}

.config-item:hover {
  background: rgba(255, 255, 255, 0.04);
  border-color: rgba(255, 102, 0, 0.15);
}

.config-label {
  color: rgba(255, 255, 255, 0.75);
  font-weight: 600;
  font-size: 0.875rem;
}

.config-value {
  color: var(--bng-orange);
  font-weight: 800;
  font-size: 0.9rem;
  text-shadow: 0 0 8px rgba(255, 102, 0, 0.3);
}

/* Chip Styles */
.chip {
  background: rgba(255, 255, 255, 0.1);
  border: 1px solid rgba(255, 255, 255, 0.15);
  padding: 0.375rem 0.75rem;
  border-radius: 16px;
  font-size: 0.75rem;
  color: rgba(255, 255, 255, 0.8);
  font-weight: 600;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.2);
}

.chip.included {
  background: linear-gradient(135deg, rgba(16, 185, 129, 0.2), rgba(16, 185, 129, 0.1));
  border-color: rgba(16, 185, 129, 0.4);
  color: #10b981;
  text-shadow: 0 0 8px rgba(16, 185, 129, 0.3);
}

/* Footer Actions */
.footer-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 1rem;
  margin: 2rem;
  padding-top: 1.5rem;
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

/* Enhanced Button Styles */
.glass-button {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.12);
  color: rgba(255, 255, 255, 0.8);
  padding: 0.875rem 1.5rem;
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  backdrop-filter: blur(8px);
  font-weight: 600;
  font-size: 0.9rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  position: relative;
  overflow: hidden;
}

.glass-button::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: linear-gradient(135deg, rgba(255, 255, 255, 0.05), transparent);
  opacity: 0;
  transition: opacity 0.3s ease;
}

.glass-button:hover {
  background: rgba(255, 255, 255, 0.1);
  border-color: rgba(255, 255, 255, 0.2);
  transform: translateY(-2px);
}

.glass-button:hover::before {
  opacity: 1;
}

.glass-button-primary {
  background: linear-gradient(135deg, rgba(255, 102, 0, 0.9), rgba(255, 153, 51, 0.9));
  border: 1px solid rgba(255, 102, 0, 0.3);
  color: #ffffff;
  padding: 0.875rem 1.5rem;
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  font-weight: 600;
  font-size: 0.9rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  box-shadow: 0 4px 12px rgba(255, 102, 0, 0.35);
  position: relative;
  overflow: hidden;
}

.glass-button-primary::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: linear-gradient(135deg, rgba(255, 255, 255, 0.1), transparent);
  opacity: 0;
  transition: opacity 0.3s ease;
}

.glass-button-primary:hover {
  background: linear-gradient(135deg, #ff6600, #ff8533);
  transform: translateY(-2px);
  box-shadow: 0 6px 16px rgba(255, 102, 0, 0.45);
}

.glass-button-primary:hover::before {
  opacity: 1;
}

/* Responsive Design */
@media (max-width: 1200px) {
  .modal-content {
    width: 80vw;
    max-width: 1200px;
  }

  .viewer {
    grid-template-columns: 1fr;
    gap: 1.5rem;
  }

  .viewer-left {
    min-height: 280px;
  }

  .summary-row {
    grid-template-columns: 1fr;
  }

  .modal-title {
    font-size: 1.5rem;
  }
}

@media (max-width: 768px) {
  .modal-content {
    width: 95vw;
    margin: 0.5rem;
  }

  .viewer {
    padding: 1.5rem 2.5rem 1.5rem 1.5rem;
    gap: 1rem;
  }

  .hero-overlay {
    padding: 1.5rem;
  }

  .veh-name {
    font-size: 1.25rem;
  }

  .config-grid {
    grid-template-columns: 1fr;
  }

  .footer-actions {
    flex-direction: column;
    gap: 0.75rem;
    margin: 1.5rem;
  }
}

@media (max-width: 480px) {
  .viewer {
    padding: 1rem 2rem 1rem 1rem;
  }

  .hero-overlay {
    padding: 1rem;
  }

  .stat {
    padding: 1rem;
  }

  .config-card {
    padding: 1rem;
  }
}
</style>


