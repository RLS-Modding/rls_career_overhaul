<template>
  <PhoneWrapper app-name="Guide" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="guide-container">
      <div class="guide-page">
        <div class="section-top">
          <div class="section-head">
            <span class="section-icon" v-html="getIcon(activeSection.iconKey)"></span>
            <div class="section-title">{{ activeSection.title }}</div>
          </div>
          <div class="section-nav" ref="navRef" @wheel.prevent="onTabWheel">
            <button
              v-for="sec in sections"
              :key="sec.id"
              :class="['nav-chip', { active: sec.id === currentPage }]"
              :ref="el => { if (sec.id === currentPage) activeChipRef = el }"
              @click="goToSection(sec.id)"
            >
              {{ sec.title }}
            </button>
          </div>
        </div>
        <div class="guide-scroll">
          <div v-for="(item, i) in activeSection.items" :key="i" class="guide-item">
            <div class="item-top">
              <span class="item-name">{{ item.name }}</span>
              <button v-if="item.route" class="try-btn" @click="tryItOut(item.route)">Try it out</button>
            </div>
            <div class="item-desc">{{ item.desc }}</div>
            <div v-if="item.links && item.links.length" class="item-links">
              <button
                v-for="link in item.links"
                :key="link.page"
                class="link-chip"
                @click="goToSection(link.page)"
              >
                {{ link.label }} &#x2192;
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, nextTick } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import PhoneWrapper from './PhoneWrapper.vue'

const router = useRouter()
const currentPage = ref('start')
const navRef = ref(null)
let activeChipRef = null

const iconMap = {
  flag: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M14.4 6L14 4H5v17h2v-7h5.6l.4 2h7V6h-5.6z"/></svg>',
  briefcase: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20 6h-4V4c0-1.11-.89-2-2-2h-4c-1.11 0-2 .89-2 2v2H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-6 0h-4V4h4v2z"/></svg>',
  car: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z"/></svg>',
  box: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20 6h-2.18c.11-.31.18-.65.18-1a2.996 2.996 0 0 0-5.5-1.65l-.5.67-.5-.68C10.96 2.54 10 2 9 2 7.34 2 6 3.34 6 5c0 .35.07.69.18 1H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-5-2c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zM9 4c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zm11 15H4v-2h16v2zm0-5H4V8h5.08L7 10.83 8.62 12 11 8.76l1-1.36 1 1.36L15.38 12 17 10.83 14.92 8H20v6z"/></svg>',
  building: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 7V3H2v18h20V7H12zM6 19H4v-2h2v2zm0-4H4v-2h2v2zm0-4H4V9h2v2zm0-4H4V5h2v2zm4 12H8v-2h2v2zm0-4H8v-2h2v2zm0-4H8V9h2v2zm0-4H8V5h2v2zm10 12h-8v-2h2v-2h-2v-2h2v-2h-2V9h8v10zm-2-8h-2v2h2v-2zm0 4h-2v2h2v-2z"/></svg>',
  bank: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11.8 10.9c-2.27-.59-3-1.2-3-2.15 0-1.09 1.01-1.85 2.7-1.85 1.78 0 2.44.85 2.5 2.1h2.21c-.07-1.72-1.12-3.3-3.21-3.81V3h-3v2.16c-1.94.42-3.5 1.68-3.5 3.61 0 2.31 1.91 3.46 4.7 4.13 2.5.6 3 1.48 3 2.41 0 .69-.49 1.79-2.7 1.79-2.06 0-2.87-.92-2.98-2.1h-2.2c.12 2.19 1.76 3.42 3.68 3.83V21h3v-2.15c1.95-.37 3.5-1.5 3.5-3.55 0-2.84-2.43-3.81-4.7-4.4z"/></svg>',
  map: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20.5 3l-.16.03L15 5.1 9 3 3.36 4.9c-.21.07-.36.25-.36.48V20.5c0 .28.22.5.5.5l.16-.03L9 18.9l6 2.1 5.64-1.9c.21-.07.36-.25.36-.48V3.5c0-.28-.22-.5-.5-.5zM15 19l-6-2.11V5l6 2.11V19z"/></svg>',
  settings: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94L14.4 2.81c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.07.62-.07.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>'
}

function getIcon(key) {
  return iconMap[key] || ''
}

const sections = [
  {
    id: 'start',
    iconKey: 'flag',
    title: 'Get Started',
    subtitle: 'Career basics and first steps',
    items: [
      {
        name: 'Starting Your Career',
        desc: 'You begin with some starting cash and a free starter garage. Buy your first vehicle at Trusted Auto to get on the road.',
        links: [
          { label: 'Garages', page: 'vehicles' }
        ]
      },
      {
        name: 'What to Explore',
        desc: 'Your garage stores vehicles and lets you buy more. The phone has apps for jobs (Taxi, BeamEats, Repo), Marketplace for buying cars, Bank and Loans, and more. Tap any section below to learn more.',
        links: [
          { label: 'Garages', page: 'vehicles' },
          { label: 'Jobs', page: 'jobs' },
          { label: 'Marketplace', page: 'vehicles' },
          { label: 'Bank & Loans', page: 'finance' }
        ]
      },
      {
        name: 'Earning Money',
        desc: 'Take on jobs like Taxi or BeamEats, deliver cargo between facilities, or run your own business. Pay scales with your performance, reputation, and the economy adjuster.',
        links: [
          { label: 'Jobs', page: 'jobs' },
          { label: 'Deliveries', page: 'deliveries' },
          { label: 'Business', page: 'business' }
        ]
      },
      {
        name: 'Reputation',
        desc: 'Build rep with organizations through jobs and deliveries. Higher reputation unlocks better delivery contracts, improved loan terms, and reduces loaner vehicle fees.',
        links: [
          { label: 'Finance', page: 'finance' },
          { label: 'Jobs', page: 'jobs' }
        ]
      },
      {
        name: 'Hardcore Mode',
        desc: 'Start with a beater vehicle, no money, smaller garage capacity, 50% payouts, and higher speed trap fines. For experienced players looking for a real challenge.'
      }
    ]
  },
  {
    id: 'jobs',
    iconKey: 'briefcase',
    title: 'Jobs & Activities',
    subtitle: 'Ways to earn money',
    items: [
      {
        name: 'Taxi',
        desc: 'Pick up passengers and drive them to destinations. Fares are calculated from distance, passenger count, vehicle value, and your speed factor. Build your driver rating over time for higher earnings.',
        route: '/career/phone-taxi'
      },
      {
        name: 'BeamEats',
        desc: 'Accept food delivery orders from restaurants. Tips depend on smooth driving and on-time delivery. Your rating grows with each order, unlocking better-paying jobs and streak bonuses for consecutive deliveries.',
        route: '/career/phone-beam-eats'
      },
      {
        name: 'Bus Routes',
        desc: 'Drive scheduled routes, picking up and dropping off passengers at stops. Earn a base fare plus consecutive stop bonuses and smooth driving tips. Requires a bus vehicle with passenger capacity.'
      },
      {
        name: 'Ambulance',
        desc: 'Emergency medical transport activated by driving an ambulance vehicle. Rewards based on distance and time, with penalties for rough driving. Builds paramedic work reputation.'
      },
      {
        name: 'Repo',
        desc: 'Repossess vehicles for organizations. Find randomly-generated target vehicles at parking spots and deliver them to the dealership. Pay based on vehicle value and completion time.',
        route: '/career/phone-repo'
      },
      {
        name: 'Quarry',
        desc: 'Load material onto dump trucks and other vehicles using loaders at the quarry. Accept tiered contracts that unlock with organization reputation. Stock regenerates over time at loading zones.',
        route: '/career/phone-quarry'
      },
      {
        name: 'Freeroam Events',
        desc: 'Races, time trials, and challenges scattered across the map. Check the big map for nearby event markers.'
      }
    ]
  },
  {
    id: 'vehicles',
    iconKey: 'car',
    title: 'Vehicles',
    subtitle: 'Buy, maintain, and customize',
    items: [
      {
        name: 'Buying & Selling',
        desc: 'Purchase new vehicles from dealerships or browse the Marketplace for used listings with varying condition and mileage.',
        route: '/career/phone-marketplace'
      },
      {
        name: 'Insurance',
        desc: 'Multiple providers offer configurable coverage: deductible level, repair time, roadside assistance, and paint repair. Your driver score (0-100) affects premiums. Score improves every 50km of safe driving and drops with claims. Loyalty and group discounts apply.'
      },
      {
        name: 'Repair & Damage',
        desc: 'Vehicles take realistic damage. Repair at shops with or without insurance. Time options: Instant ($1000 extra), 2 min, 5 min, or 10 min. Insurance covers the cost minus your deductible.'
      },
      {
        name: 'Tuning & Parts',
        desc: 'Upgrade performance parts at tuning facilities with a cart-based shopping system. Tax is applied at checkout. Your vehicle must be fully repaired before tuning is available.',
        links: [
          { label: 'Business', page: 'business' }
        ]
      },
      {
        name: 'Painting',
        desc: 'Customize your paint and clear coat at paint shops. Multiple paint types with different metallic and roughness finishes. Vehicle must be undamaged before painting.'
      },
      {
        name: 'Garages & Houses',
        desc: 'In normal mode you start with one free starter garage. Visit other garages on the map to buy them and expand your vehicle storage. Each garage adds slots for your collection. You can sell purchased garages at 75% of their value from the garage computer, but the starter garage cannot be sold. Garage capacity is halved in Hardcore Mode.',
        links: [
          { label: 'Get Started', page: 'start' }
        ]
      }
    ]
  },
  {
    id: 'deliveries',
    iconKey: 'box',
    title: 'Deliveries',
    subtitle: 'Cargo hauling and logistics',
    items: [
      {
        name: 'Cargo System',
        desc: 'Pick up and deliver cargo between facilities. Vehicles have cargo containers with weight and volume limits. Cargo within 25 meters is automatically detected for loading.'
      },
      {
        name: 'Cargo Types',
        desc: 'Parcels, fluids, dry bulk, cement, and cash. Each type has different handling requirements and compatible vehicle containers.'
      },
      {
        name: 'Contracts & Tiers',
        desc: 'Accept delivery contracts tiered by your organization reputation. Higher tiers offer better payouts but stricter requirements. Contracts have expiration timers -- miss them and you lose the job.',
        links: [
          { label: 'Jobs', page: 'jobs' }
        ]
      },
      {
        name: 'Penalties & Damage',
        desc: 'Abandoning cargo incurs a 10% value penalty. Item damage is tracked throughout transport and directly reduces your final payout. Handle with care.'
      }
    ]
  },
  {
    id: 'business',
    iconKey: 'building',
    title: 'Business',
    subtitle: 'Own and operate businesses',
    items: [
      {
        name: 'Starting a Business',
        desc: 'Purchase business properties with a down payment. The remaining balance is automatically financed through a loan. A dedicated business bank account is created for you.',
        links: [
          { label: 'Finance', page: 'finance' }
        ]
      },
      {
        name: 'Tuning Shop',
        desc: 'Own a tuning shop that generates customer jobs roughly every 2 minutes. Marketing upgrades speed up job flow. Skill tree unlocks include personal vehicle tuning, quality tools for higher damage thresholds, and XP multipliers.',
        route: '/career/phone-tuning-shop'
      },
      {
        name: 'Skill Tree',
        desc: 'Unlock business upgrades: marketing (faster job generation), quality tools (higher damage threshold on jobs), and personal vehicle use. Each branch improves a different aspect of your business.'
      },
      {
        name: 'Business Computer',
        desc: 'Central hub at your business location to manage inventory, view finances, run daily operations, and sleep to advance time.'
      }
    ]
  },
  {
    id: 'finance',
    iconKey: 'bank',
    title: 'Finance',
    subtitle: 'Banking, loans, and money',
    items: [
      {
        name: 'Bank Accounts',
        desc: 'Open personal and business accounts. Deposit, withdraw, and transfer funds between them. Business account transfers take 5 minutes to process. View full transaction history.',
        route: '/career/phone-bank'
      },
      {
        name: 'Loans',
        desc: 'Borrow from organizations based on your reputation and current outstanding principal. Payments are due every 5 minutes. Missing a payment raises your interest rate and hurts your reputation. Prepayment is available to pay down principal early.',
        route: '/career/phone-loans'
      }
    ]
  },
  {
    id: 'world',
    iconKey: 'map',
    title: 'World',
    subtitle: 'Explore and interact',
    items: [
      {
        name: 'Map Switching',
        desc: 'Travel between maps via switcher locations marked on the big map. All career progress, vehicles, and money carry over between maps.'
      },
      {
        name: 'Quick Travel',
        desc: 'Fast travel to discovered locations or owned garages. Cost is based on realistic route distance with a base fee plus per-meter charge.'
      },
      {
        name: 'Sleep & Time',
        desc: 'Rest at garages or business computers to advance game time. You are teleported to the closest garage when sleeping. Some activities and events are time-dependent.'
      },
      {
        name: 'Car Meets',
        desc: 'Attend Showcase and Street Cruise events across the map. Earn reputation based on attendance and participation. AI vehicles spawn at meets, and some include cruise routes to follow.',
        route: '/career/car-meets-phone'
      },
      {
        name: 'Speed Traps',
        desc: 'Speed cameras and red-light cameras issue fines based on your speed over the limit. Fines are higher in Hardcore Mode. Ambulances and police vehicles are exempt during active pursuits.'
      }
    ]
  },
  {
    id: 'settings',
    iconKey: 'settings',
    title: 'Settings',
    subtitle: 'Configuration and controls',
    items: [
      {
        name: 'Mod Settings',
        desc: 'Configure the overhaul from the in-game settings menu. The Overhaul Manager includes: Police on/off to enable or disable police presence; Map Def Mode for map developers only; and No Parked Mode for low-performance PCs or players who prefer no parked cars on the long map.',
        route: 'overhaul-manager'
      },
      {
        name: 'Keybindings',
        desc: 'Customize phone toggle, quick actions, and other key bindings. Check the controls menu for the full list of configurable inputs.'
      }
    ]
  }
]

const activeSection = computed(() => sections.find(s => s.id === currentPage.value) || sections[0])

function goToSection(id) {
  currentPage.value = id
  nextTick(() => {
    if (activeChipRef && navRef.value) {
      activeChipRef.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' })
    }
  })
}

function onTabWheel(e) {
  const el = navRef.value
  if (!el) return
  el.scrollLeft += e.deltaY
}

function tryItOut(route) {
  if (route === 'overhaul-manager') {
    const bngVue = window.bngVue || {}
    bngVue.gotoGameState?.('menu.overhaulManager', { tryAngularJS: true, blankAngularJS: false })
  } else {
    router.push(route)
  }
}
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

.guide-page {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
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

/* Section pages */
.section-top {
  flex-shrink: 0;
  padding-top: 48px;
  background: #1a1a1a;
}

.section-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 16px 8px;
}

.section-icon {
  flex-shrink: 0;
  width: 28px;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #f97316;
}

.section-icon svg {
  width: 20px;
  height: 20px;
}

.section-title {
  font-size: 18px;
  font-weight: 700;
  color: #fff;
}

.section-nav {
  display: flex;
  flex-wrap: nowrap;
  gap: 6px;
  padding: 4px 12px 10px;
  overflow-x: auto;
  overflow-y: hidden;
  scroll-behavior: smooth;
  -webkit-overflow-scrolling: touch;
  scrollbar-width: none;
  -ms-overflow-style: none;
}

.section-nav::-webkit-scrollbar {
  display: none;
}

.nav-chip {
  flex-shrink: 0;
  padding: 5px 12px;
  border-radius: 14px;
  border: 1px solid #333;
  background: #222;
  color: #999;
  font-size: 11px;
  font-weight: 500;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;
  transition: all 0.15s ease;
}

.nav-chip:hover {
  background: #2a2a2a;
  color: #ccc;
}

.nav-chip.active {
  background: #f97316;
  border-color: #f97316;
  color: #fff;
  font-weight: 600;
}

/* Guide items */
.guide-item {
  padding: 12px;
  margin-bottom: 8px;
  background: #222;
  border-radius: 10px;
}

.item-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 4px;
}

.item-name {
  font-size: 13px;
  font-weight: 600;
  color: #f97316;
}

.item-desc {
  font-size: 11px;
  color: #999;
  line-height: 1.5;
}

.try-btn {
  flex-shrink: 0;
  padding: 4px 12px;
  border-radius: 12px;
  border: none;
  background: rgba(249, 115, 22, 0.15);
  color: #f97316;
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;
  transition: background 0.15s ease;
}

.try-btn:hover {
  background: rgba(249, 115, 22, 0.3);
}

.try-btn:active {
  background: rgba(249, 115, 22, 0.45);
}

.item-links {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 8px;
}

.link-chip {
  padding: 3px 10px;
  border-radius: 10px;
  border: 1px solid #333;
  background: transparent;
  color: #aaa;
  font-size: 10px;
  font-weight: 500;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;
  transition: all 0.15s ease;
}

.link-chip:hover {
  border-color: #f97316;
  color: #f97316;
  background: rgba(249, 115, 22, 0.08);
}
</style>
