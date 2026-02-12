import { icons } from '@/common/components/base'

export default {
  id: 'freeroam-events',
  name: 'Events',
  icon: icons.missionCupTriangle,
  route: '/career/phone-events',
  color: '#e63946',
  iconColor: '#ffffff',
  category: 'Activities',
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
