// Shared by EngineShopSupplyPickup.vue and PassiveBusinessSupplyPickup.vue.
// Keep genuine supplier pictures and switch missing or failed images to the short name card.
// Picture for a facility hero banner, or '' when the facility has no picture of its own.
// The facility loader falls back to the game's "no preview" placeholder for sites without a picture,
// and a path can still fail to load; screens then show a text header instead of an empty or stock box.
import { computed, ref } from 'vue'

// Keep the current world/facilities.lua preview contract here: its stock fallback is a valid image,
// so an image error alone cannot distinguish a missing facility picture.
const PLACEHOLDER_PICTURES = ['/ui/images/noPreview.jpg']

export function isRealFacilityPicture(src) {
  if (typeof src !== 'string' || !src.trim()) return false
  const path = src.trim().toLowerCase()
  return !PLACEHOLDER_PICTURES.some(placeholder => path.endsWith(placeholder.toLowerCase()))
}

// source: getter for the picture path. A path that failed to load stays hidden until the path changes.
export function useFacilityPicture(source) {
  const failedSrc = ref('')
  const picture = computed(() => {
    const src = source()
    return isRealFacilityPicture(src) && src !== failedSrc.value ? src : ''
  })
  const onPictureError = () => { failedSrc.value = source() || '' }
  return { picture, onPictureError }
}
