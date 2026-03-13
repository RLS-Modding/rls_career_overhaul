import { icons } from '@/common/components/base'

export default {
  id: 'tuning-shop',
  name: 'Tuning Shop',
  icon: icons.cars,
  iconTile: 'tuning-shop.png',
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
      const purchased = await luaBridge.career_modules_business_businessManager.getPurchasedBusinesses('tuningShop')
      if (!purchased) return false
      for (const [id, owned] of Object.entries(purchased)) {
        if (owned) {
          const level = await luaBridge.career_modules_business_businessSkillTree.getNodeProgress(id, 'quality-of-life', 'shop-app')
          if (level && level > 0) return true
        }
      }
      return false
    } catch {
      return false
    }
  },
}