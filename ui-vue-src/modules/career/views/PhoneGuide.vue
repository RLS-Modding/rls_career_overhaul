<template>
  <PhoneWrapper app-name="Guide" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="guide-container">
      <div class="guide-header">
        <div class="guide-title">📖 Guide</div>
        <div class="guide-subtitle">Everything you need to know</div>
      </div>

      <div class="guide-scroll">
        <div
          v-for="(cat, ci) in categories"
          :key="ci"
          class="guide-card"
          :class="{ expanded: expandedIndex === ci }"
        >
          <button class="guide-card-header" @click="toggle(ci)">
            <span class="card-icon">{{ cat.icon }}</span>
            <div class="card-text">
              <span class="card-title">{{ cat.title }}</span>
              <span class="card-subtitle">{{ cat.subtitle }}</span>
            </div>
            <span class="card-chevron">{{ expandedIndex === ci ? '▾' : '›' }}</span>
          </button>
          <transition name="expand">
            <div v-if="expandedIndex === ci" class="guide-card-body">
              <div v-for="(item, ii) in cat.items" :key="ii" class="guide-item">
                <span class="item-name">{{ item.name }}</span>
                <span class="item-desc">{{ item.desc }}</span>
              </div>
            </div>
          </transition>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'

const expandedIndex = ref(null)

function toggle(i) {
  expandedIndex.value = expandedIndex.value === i ? null : i
}

const categories = [
  {
    icon: '💼', title: 'Career Basics', subtitle: 'Getting started with your career',
    items: [
      { name: 'Getting Started', desc: 'Start a new career, choose difficulty, pick your first vehicle' },
      { name: 'Money & Economy', desc: 'Earn money through jobs, deliveries, and activities. Manage finances through the bank' },
      { name: 'Reputation', desc: 'Build rep with organizations to unlock better jobs and rewards' },
      { name: 'Hardcore Mode', desc: 'Permadeath mode with higher stakes and better payouts' },
    ]
  },
  {
    icon: '🚗', title: 'Vehicles', subtitle: 'Buy, maintain, and customize',
    items: [
      { name: 'Buying & Selling', desc: 'Purchase vehicles from dealerships or the marketplace. Sell to other players' },
      { name: 'Insurance', desc: 'Protect your vehicles with insurance policies. Covers repair costs' },
      { name: 'Repair & Damage', desc: 'Vehicles take realistic damage. Visit repair shops or fix at your garage' },
      { name: 'Tuning & Parts', desc: 'Upgrade performance parts, install tuning kits from the tuning shop' },
      { name: 'Painting', desc: "Customize your vehicle's appearance at paint shops" },
      { name: 'Garage', desc: 'Store and manage your vehicle collection. Purchase additional garages' },
    ]
  },
  {
    icon: '📦', title: 'Deliveries', subtitle: 'Cargo hauling and logistics',
    items: [
      { name: 'Cargo System', desc: 'Pick up and deliver packages, vehicles, and materials between facilities' },
      { name: 'Delivery Types', desc: 'Parcels (packages), vehicles (driveaway), and materials (bulk cargo)' },
      { name: 'Rewards', desc: 'Earn money based on distance, cargo type, weight, and time bonuses' },
      { name: 'Parcel Modifiers', desc: 'Special cargo conditions like fragile, urgent, oversized, hazmat' },
    ]
  },
  {
    icon: '💰', title: 'Jobs & Activities', subtitle: 'Ways to earn money',
    items: [
      { name: 'Taxi', desc: 'Pick up passengers and drive them to destinations. Build your rating' },
      { name: 'BeamEats', desc: 'Food delivery driver. Accept orders, pick up food, deliver to customers' },
      { name: 'Bus Routes', desc: 'Drive bus routes picking up and dropping off passengers at stops' },
      { name: 'Ambulance', desc: 'Emergency medical transport. Respond to calls, transport patients' },
      { name: 'Repo', desc: 'Repossess vehicles for organizations. Track and recover target vehicles' },
      { name: 'Quarry', desc: 'Haul materials at the quarry for steady income' },
      { name: 'Freeroam Events', desc: 'Races, time trials, and challenges scattered across the map' },
    ]
  },
  {
    icon: '🏢', title: 'Business', subtitle: 'Own and operate businesses',
    items: [
      { name: 'Starting a Business', desc: 'Purchase business properties and start your own company' },
      { name: 'Business Computer', desc: 'Manage inventory, view finances, and run operations' },
      { name: 'Skill Tree', desc: 'Unlock business upgrades and improvements' },
      { name: 'Tuning Shop', desc: 'Own and operate a tuning shop for other vehicles' },
    ]
  },
  {
    icon: '🏦', title: 'Finance', subtitle: 'Banking, loans, and trading',
    items: [
      { name: 'Bank Accounts', desc: 'Open checking and savings accounts. Transfer funds' },
      { name: 'Loans', desc: 'Borrow money from organizations. Compare interest rates and terms' },
      { name: 'Marketplace', desc: 'Buy and sell vehicles with other players/NPCs' },
    ]
  },
  {
    icon: '🗺️', title: 'World', subtitle: 'Explore and interact',
    items: [
      { name: 'Map Switching', desc: 'Travel between different maps. Your progress carries over' },
      { name: 'Quick Travel', desc: 'Fast travel between discovered locations for a fee' },
      { name: 'Sleep & Time', desc: 'Rest to advance time. Some activities are time-dependent' },
      { name: 'Car Meets', desc: 'Attend community car meets, show off your rides' },
      { name: 'Speed Traps', desc: 'Speed cameras that track your top speeds at specific locations' },
    ]
  },
  {
    icon: '⚙️', title: 'Settings & Tips', subtitle: 'Configuration and pro tips',
    items: [
      { name: 'Mod Settings', desc: "Configure the overhaul's features to your preference" },
      { name: 'Keybindings', desc: 'Phone toggle, quick actions, and custom bindings' },
      { name: 'Tips & Tricks', desc: 'Pro tips for making money fast and progressing efficiently' },
    ]
  },
]
</script>

<style scoped>
.guide-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  background: #1a1a1a;
  color: #e5e5e5;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}

.guide-header {
  padding: 20px 16px 12px;
  flex-shrink: 0;
}

.guide-title {
  font-size: 22px;
  font-weight: 700;
  color: #fff;
}

.guide-subtitle {
  font-size: 12px;
  color: #888;
  margin-top: 2px;
}

.guide-scroll {
  flex: 1;
  overflow-y: auto;
  padding: 0 12px 20px;
  scroll-behavior: smooth;
}

.guide-scroll::-webkit-scrollbar {
  width: 3px;
}

.guide-scroll::-webkit-scrollbar-track {
  background: transparent;
}

.guide-scroll::-webkit-scrollbar-thumb {
  background: #444;
  border-radius: 3px;
}

.guide-card {
  background: #222;
  border-radius: 10px;
  margin-bottom: 8px;
  border-left: 3px solid transparent;
  transition: border-color 0.3s ease;
  overflow: hidden;
}

.guide-card.expanded {
  border-left-color: #f97316;
}

.guide-card-header {
  display: flex;
  align-items: center;
  width: 100%;
  padding: 12px;
  background: none;
  border: none;
  color: #e5e5e5;
  cursor: pointer;
  text-align: left;
  gap: 10px;
  font-family: inherit;
}

.guide-card-header:hover {
  background: #2a2a2a;
}

.card-icon {
  font-size: 22px;
  flex-shrink: 0;
  width: 32px;
  text-align: center;
}

.card-text {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.card-title {
  font-size: 14px;
  font-weight: 600;
  color: #fff;
}

.card-subtitle {
  font-size: 11px;
  color: #777;
  margin-top: 1px;
}

.card-chevron {
  font-size: 16px;
  color: #f97316;
  flex-shrink: 0;
  transition: transform 0.2s ease;
}

.expand-enter-active,
.expand-leave-active {
  transition: all 0.3s ease;
  max-height: 500px;
  opacity: 1;
}

.expand-enter-from,
.expand-leave-to {
  max-height: 0;
  opacity: 0;
}

.guide-card-body {
  padding: 0 12px 10px 54px;
}

.guide-item {
  padding: 8px 0;
  border-bottom: 1px solid #2a2a2a;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.guide-item:last-child {
  border-bottom: none;
}

.item-name {
  font-size: 13px;
  font-weight: 600;
  color: #f97316;
}

.item-desc {
  font-size: 11px;
  color: #999;
  line-height: 1.4;
}
</style>
