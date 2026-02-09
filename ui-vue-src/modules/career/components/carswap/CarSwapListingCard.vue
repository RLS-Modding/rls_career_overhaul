<template>
  <div class="listing-card" @click="$emit('click', listing)">
    <div class="listing-image">
      <img 
        v-if="firstPhotoUrl" 
        :src="firstPhotoUrl" 
        alt="Vehicle"
      />
      <div v-else class="no-image">
        <span>🚗</span>
      </div>
      <div class="listing-status" :class="listing.status">
        {{ listing.status }}
      </div>
    </div>
    
    <div class="listing-info">
      <div class="listing-header">
        <h3 class="listing-title">{{ listing.title }}</h3>
        <div class="listing-price">${{ formatPrice(listing.price) }}</div>
      </div>
      
      <div class="listing-meta">
        <span class="meta-item">
          <span class="meta-icon">📅</span>
          {{ listing.vehicle_year || 'N/A' }}
        </span>
        <span class="meta-item">
          <span class="meta-icon">🛣️</span>
          {{ formatMileage(listing.mileage) }}
        </span>
        <span class="meta-item">
          <span class="meta-icon">⚙️</span>
          {{ listing.condition }}%
        </span>
      </div>
      
      <div class="listing-seller">
        <span class="seller-name">{{ listing.seller_name }}</span>
        <span class="seller-rating" v-if="sellerRating">
          ⭐ {{ sellerRating.toFixed(1) }}
        </span>
      </div>
      
      <div class="listing-stats">
        <span class="views">👁️ {{ listing.views || 0 }}</span>
        <span class="time">{{ formatTimeAgo(listing.created_at) }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  listing: {
    type: Object,
    required: true
  },
  sellerRating: {
    type: Number,
    default: null
  }
})

defineEmits(['click'])

// First photo for card: thumbnail_base64 (single or first), or first from separate columns / legacy JSON.
const firstPhotoUrl = computed(() => {
  const listing = props.listing
  const t = listing?.thumbnail_base64 ?? listing?.thumbnailBase64
  if (t == null || t === '') return null
  if (typeof t === 'string') {
    const s = t.trim()
    if (!s) return null
    if (s.charAt(0) !== '[' && s.charAt(0) !== '{') return `data:image/jpeg;base64,${s}`
    try {
      const arr = JSON.parse(s)
      const first = Array.isArray(arr) ? (arr[0] ?? arr[1]) : null
      if (typeof first === 'string' && first) return `data:image/jpeg;base64,${first}`
    } catch {
      const dq = s.indexOf('"', 1)
      const sq = s.indexOf("'", 1)
      const start = d > 0 ? (sq > 0 ? Math.min(d, sq) : d) : sq
      if (start > 0) {
        const q = s[start]
        const end = s.indexOf(q, start + 1)
        if (end > start) {
          const b64 = s.slice(start + 1, end).replace(/\\"/g, '"')
          if (b64.length > 0) return `data:image/jpeg;base64,${b64}`
        }
      }
    }
    return null
  }
  if (Array.isArray(t) && (t[0] || t[1])) return `data:image/jpeg;base64,${t[0] || t[1]}`
  return null
})

const formatPrice = (price) => {
  if (price >= 1000000) return (price / 1000000).toFixed(1) + 'M'
  if (price >= 1000) return (price / 1000).toFixed(0) + 'K'
  return price.toLocaleString()
}

const formatMileage = (miles) => {
  if (!miles) return '0 mi'
  if (miles >= 1000000) return (miles / 1000000).toFixed(1) + 'M mi'
  if (miles >= 1000) return (miles / 1000).toFixed(0) + 'K mi'
  return miles.toLocaleString() + ' mi'
}

const formatTimeAgo = (dateStr) => {
  if (!dateStr) return ''
  const date = new Date(dateStr)
  const now = new Date()
  const diffMs = now - date
  const diffMins = Math.floor(diffMs / 60000)
  const diffHours = Math.floor(diffMins / 60)
  const diffDays = Math.floor(diffHours / 24)
  
  if (diffDays > 0) return `${diffDays}d ago`
  if (diffHours > 0) return `${diffHours}h ago`
  if (diffMins > 0) return `${diffMins}m ago`
  return 'Just now'
}
</script>

<style scoped lang="scss">
$primary: #f37f2a;
$primary-glow: rgba(243, 127, 42, 0.35);
$surface-1: #12151d;
$surface-2: #1a1e28;
$text: #f0f2f5;
$text-muted: rgba(255, 255, 255, 0.55);
$text-dim: rgba(255, 255, 255, 0.4);
$border: rgba(255, 255, 255, 0.08);
$radius-sm: 10px;
$radius-md: 14px;
$ease-out: cubic-bezier(0.22, 1, 0.36, 1);
$danger: #f43f5e;
$warn: #eab308;

.listing-card {
  background: $surface-2;
  border-radius: $radius-md;
  overflow: hidden;
  cursor: pointer;
  transition: transform 0.3s $ease-out, border-color 0.25s $ease-out, box-shadow 0.3s $ease-out;
  border: 1px solid $border;

  &:hover {
    transform: translateY(-4px);
    border-color: rgba($primary, 0.45);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35), 0 0 0 1px rgba($primary, 0.15);
  }
  &:active {
    transform: translateY(-2px);
  }
}

.listing-image {
  position: relative;
  width: 100%;
  height: 124px;
  background: $surface-1;
  overflow: hidden;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    transition: transform 0.4s $ease-out;
  }

  .listing-card:hover & img {
    transform: scale(1.04);
  }

  .no-image {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 2.6em;
    opacity: 0.32;
  }

  .listing-status {
    position: absolute;
    top: 10px;
    right: 10px;
    padding: 4px 10px;
    border-radius: $radius-sm;
    font-size: 0.68em;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    transition: transform 0.2s $ease-out;

    &.available {
      background: rgba($primary, 0.95);
      color: #0a0e12;
    }

    &.pending {
      background: rgba($warn, 0.95);
      color: #0a0e12;
    }

    &.sold {
      background: rgba($danger, 0.95);
      color: #fff;
    }
  }
}

.listing-info {
  padding: 14px;
}

.listing-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 10px;

  .listing-title {
    margin: 0;
    font-size: 1em;
    font-weight: 600;
    color: $text;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .listing-price {
    font-size: 1.12em;
    font-weight: 700;
    color: $primary;
    margin-left: 10px;
    flex-shrink: 0;
  }
}

.listing-meta {
  display: flex;
  gap: 14px;
  margin-bottom: 10px;

  .meta-item {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 0.8em;
    color: $text-muted;

    .meta-icon {
      font-size: 0.9em;
      opacity: 0.9;
    }
  }
}

.listing-seller {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 8px 0;
  border-top: 1px solid $border;
  margin-top: 10px;

  .seller-name {
    font-size: 0.85em;
    color: $text-muted;
  }

  .seller-rating {
    font-size: 0.8em;
    color: #fbbf24;
  }
}

.listing-stats {
  display: flex;
  justify-content: space-between;
  font-size: 0.75em;
  color: $text-dim;
  margin-top: 8px;
}
</style>

