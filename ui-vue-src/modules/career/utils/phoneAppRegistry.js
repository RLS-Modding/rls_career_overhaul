import { ref } from 'vue'
import { icons } from '@/common/components/base'

const APP_DEFINITIONS = [
  {
    id: 'loans',
    name: 'Loans',
    icon: icons.beamCurrency,
    route: '/career/phone-loans',
    color: '#5a8dee',
    iconColor: '#ffffff',
    category: 'Finance',
    defaultPage: 0,
    defaultPosition: 0,
  },
  {
    id: 'bank',
    name: 'Bank',
    icon: icons.beamCurrency,
    route: '/career/phone-bank',
    color: '#10b981',
    iconColor: '#ffffff',
    category: 'Finance',
    defaultPage: 0,
    defaultPosition: 1,
    defaultDock: 1,
  },
  {
    id: 'marketplace',
    name: 'Marketplace',
    icon: icons.shoppingCart,
    route: '/career/phone-marketplace',
    color: '#228B22',
    iconColor: '#ffffff',
    category: 'Shopping',
    defaultPage: 0,
    defaultPosition: 2,
    defaultDock: 2,
  },
  {
    id: 'car-meet',
    name: 'Car Meet',
    icon: icons.cars,
    route: '/career/car-meets-phone',
    color: '#696969',
    iconColor: '#ffffff',
    category: 'Social',
    defaultPage: 0,
    defaultPosition: 3,
  },
  {
    id: 'repo',
    name: 'Repo',
    icon: icons.tow,
    route: '/career/phone-repo',
    color: '#1E90FF',
    iconColor: '#ffffff',
    category: 'Services',
    defaultPage: 0,
    defaultPosition: 4,
    defaultDock: 0,
  },
  {
    id: 'taxi',
    name: 'Taxi',
    icon: icons.taxiCar3,
    route: '/career/phone-taxi',
    color: '#ffd700',
    iconColor: '#000000',
    category: 'Transport',
    defaultPage: 0,
    defaultPosition: 5,
    defaultDock: 3,
  },
  {
    id: 'quarry',
    name: 'Quarry',
    icon: icons.cogs,
    route: '/career/phone-quarry',
    color: '#8B4513',
    iconColor: '#ffffff',
    category: 'Business',
    defaultPage: 0,
    defaultPosition: 6,
  },
  {
    id: 'beam-eats',
    name: 'BeamEats',
    icon: icons.cityOutline,
    route: '/career/phone-beam-eats',
    color: '#ff4757',
    iconColor: '#ffffff',
    category: 'Food',
    defaultPage: 0,
    defaultPosition: 7,
  },
  {
    id: 'tuning-shop',
    name: 'Tuning Shop',
    icon: icons.cars,
    route: '/career/phone-tuning-shop',
    color: '#F54900',
    iconColor: '#ffffff',
    category: 'Business',
    defaultPage: 0,
    defaultPosition: 8,
    unlockCondition: async (luaBridge) => {
      try {
        const isActive = await luaBridge.career_career.isActive()
        if (!isActive) return false
        const purchased = await luaBridge.career_modules_business_businessManager.getPurchasedBusinesses("tuningShop")
        if (!purchased) return false
        for (const [id, owned] of Object.entries(purchased)) {
          if (owned) {
            const level = await luaBridge.career_modules_business_businessSkillTree.getNodeProgress(id, "quality-of-life", "shop-app")
            if (level && level > 0) return true
          }
        }
        return false
      } catch {
        return false
      }
    },
  },
]

const APPS_PER_PAGE = 20
const GRID_COLS = 4
const GRID_ROWS = 5
const DEFAULT_DOCK_IDS = ['repo', 'bank', 'marketplace', 'taxi']

export function usePhoneApps() {
  const availableApps = ref([])

  async function refreshApps(luaBridge) {
    const apps = []
    for (const def of APP_DEFINITIONS) {
      if (def.unlockCondition) {
        const unlocked = await def.unlockCondition(luaBridge)
        if (!unlocked) continue
      }
      apps.push({ ...def })
    }
    availableApps.value = apps
  }

  return { availableApps, refreshApps, APP_DEFINITIONS, APPS_PER_PAGE, GRID_COLS, GRID_ROWS, DEFAULT_DOCK_IDS }
}
