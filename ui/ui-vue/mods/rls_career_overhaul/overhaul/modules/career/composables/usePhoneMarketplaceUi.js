import { onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'

export function usePhoneMarketplaceUi() {
  onMounted(() => {
    lua.overhaul_career_market_marketplace.setPhoneMarketplaceUiOpen(true)
  })
  onUnmounted(() => {
    lua.overhaul_career_market_marketplace.setPhoneMarketplaceUiOpen(false)
  })
}
