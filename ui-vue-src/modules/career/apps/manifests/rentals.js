import { icons } from '@/common/components/base'

export default {
  id: 'rentals',
  name: 'Rentals',
  icon: icons.doorFrontCoins,
  route: '/career/phone-rentals',
  color: '#3b82f6',
  iconColor: '#ffffff',
  category: 'Finance',
  defaultPage: 0,
  defaultPosition: 10,
  unlockCondition: async (luaBridge) => {
    try {
      await luaBridge.extensions.load('ui_phone_layout')
      const fromLayout = await luaBridge.ui_phone_layout.getCareerActive()
      if (fromLayout) return true
    } catch {}
    try {
      return await luaBridge.career_career.isActive()
    } catch {
      return false
    }
  },
}
