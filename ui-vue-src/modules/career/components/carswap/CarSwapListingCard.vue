<template>
  <div class="listing-card" @click="$emit('click', listing)">
    <div class="listing-image">
      <img 
        v-if="listing.thumbnail_base64" 
        :src="'data:image/jpeg;base64,' + listing.thumbnail_base64" 
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
.listing-card {
  background: rgba(30, 30, 30, 0.95);
  border-radius: 12px;
  overflow: hidden;
  cursor: pointer;
  transition: all 0.2s ease;
  border: 1px solid rgba(255, 255, 255, 0.1);
  
  &:hover {
    transform: translateY(-2px);
    border-color: #00d4aa;
    box-shadow: 0 4px 12px rgba(0, 212, 170, 0.2);
  }
}

.listing-image {
  position: relative;
  width: 100%;
  height: 120px;
  background: #1a1a1a;
  
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  
  .no-image {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 2.5em;
    opacity: 0.3;
  }
  
  .listing-status {
    position: absolute;
    top: 8px;
    right: 8px;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 0.7em;
    font-weight: 600;
    text-transform: uppercase;
    
    &.available {
      background: rgba(0, 212, 170, 0.9);
      color: #000;
    }
    
    &.pending {
      background: rgba(255, 193, 7, 0.9);
      color: #000;
    }
    
    &.sold {
      background: rgba(239, 68, 68, 0.9);
      color: #fff;
    }
  }
}

.listing-info {
  padding: 12px;
}

.listing-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 8px;
  
  .listing-title {
    margin: 0;
    font-size: 1em;
    font-weight: 600;
    color: #fff;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  
  .listing-price {
    font-size: 1.1em;
    font-weight: 700;
    color: #00d4aa;
    margin-left: 8px;
  }
}

.listing-meta {
  display: flex;
  gap: 12px;
  margin-bottom: 8px;
  
  .meta-item {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 0.8em;
    color: rgba(255, 255, 255, 0.7);
    
    .meta-icon {
      font-size: 0.9em;
    }
  }
}

.listing-seller {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 6px 0;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  margin-top: 8px;
  
  .seller-name {
    font-size: 0.85em;
    color: rgba(255, 255, 255, 0.6);
  }
  
  .seller-rating {
    font-size: 0.8em;
    color: #ffd700;
  }
}

.listing-stats {
  display: flex;
  justify-content: space-between;
  font-size: 0.75em;
  color: rgba(255, 255, 255, 0.4);
  margin-top: 6px;
}
</style>

