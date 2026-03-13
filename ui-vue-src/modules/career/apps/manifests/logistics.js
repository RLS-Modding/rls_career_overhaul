import { icons } from '@/common/components/base'

export default {
  id: 'logistics',
  name: 'Logistics',
  icon: icons.cogs,
  iconTile: 'logistics.png',
  route: '/career/phone-logistics',
  color: '#2b6cb0',
  iconColor: '#ffffff',
  category: 'Jobs',
  defaultPage: 0,
  defaultPosition: 11,
  defaultDock: 3,
  unlockCondition: async (luaBridge) => {
    try {
      await luaBridge.extensions.load('ui_phone_layout')
      const fromLayout = await luaBridge.ui_phone_layout.getCareerActive()
      if (fromLayout) return true
    } catch { }
    try {
      return await luaBridge.career_career.isActive()
    } catch {
      return false
    }
  },
}
