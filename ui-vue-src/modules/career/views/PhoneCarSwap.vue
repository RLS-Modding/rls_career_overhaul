<template>
  <PhoneWrapper app-name="CarSwap" status-font-color="#ffffff" status-blend-mode="non">
    <div class="carswap-container">
      <!-- Connection Status -->
      <div v-if="!isConnected" class="connection-error">
        <span class="error-icon">⚠️</span>
        <span>Not connected to CarSwap servers</span>
        <button @click="refreshData" class="retry-btn">Retry</button>
      </div>
      
      <!-- Tabs -->
      <div class="tabs">
        <button 
          v-for="tab in tabs" 
          :key="tab.id"
          class="tab-btn"
          :class="{ active: activeTab === tab.id }"
          @click="activeTab = tab.id"
        >
          <span class="tab-icon">{{ tab.icon }}</span>
          <span class="tab-label">{{ tab.label }}</span>
          <span v-if="tab.badge" class="tab-badge">{{ tab.badge }}</span>
        </button>
      </div>
      
      <!-- Browse Tab -->
      <div v-if="activeTab === 'browse'" class="tab-content">
        <div class="search-bar">
          <input 
            v-model="searchQuery" 
            type="text" 
            placeholder="Search vehicles..."
            class="search-input"
            @focus="onInputFocus"
            @blur="onInputBlur"
            v-bng-text-input
          />
          <button @click="toggleFilters" class="filter-btn">
            🔧 Filters
          </button>
        </div>
        
        <div v-if="showFilters" class="filters-panel">
          <div class="filter-row">
            <label>Min Price:</label>
            <input v-model.number="filters.minPrice" type="number" />
          </div>
          <div class="filter-row">
            <label>Max Price:</label>
            <input v-model.number="filters.maxPrice" type="number" />
          </div>
          <button @click="applyFilters" class="apply-btn">Apply</button>
        </div>
        
        <div v-if="isLoading" class="loading">
          <div class="spinner"></div>
          <span>Loading listings...</span>
        </div>
        
        <div v-else-if="filteredListings.length === 0" class="empty-state">
          <span class="empty-icon">🚗</span>
          <span>No vehicles listed</span>
          <span class="empty-sub">Be the first to list!</span>
        </div>
        
        <div v-else class="listings-grid">
          <CarSwapListingCard
            v-for="listing in filteredListings"
            :key="listing.id"
            :listing="listing"
            @click="openListing(listing)"
          />
        </div>
      </div>
      
      <!-- Sell Tab -->
      <div v-if="activeTab === 'sell'" class="tab-content">
        <div class="sell-header">
          <h3>List a Vehicle</h3>
          <p>Choose a vehicle from your inventory to sell</p>
        </div>

        <div class="sell-subtabs">
          <button
            v-for="tab in sellTabs"
            :key="tab.id"
            class="sell-subtab-btn"
            :class="{ active: activeSellTab === tab.id }"
            @click="activeSellTab = tab.id"
          >
            {{ tab.label }}
          </button>
        </div>
        
        <div v-if="activeSellTab === 'vehicles' && myInventory.length === 0" class="empty-state">
          <span class="empty-icon">🚙</span>
          <span>No vehicles to sell</span>
          <span class="empty-sub">Buy some vehicles first!</span>
        </div>
        
        <div v-else-if="activeSellTab === 'vehicles'" class="inventory-list">
          <div 
            v-for="vehicle in myInventory" 
            :key="vehicle.inventoryId"
            class="inventory-card"
            @click="openSellModal(vehicle)"
          >
            <div class="inv-image">
              <img v-if="vehicle.thumbnail" :src="vehicle.thumbnail" alt="" />
              <span v-else>🚗</span>
            </div>
            <div class="inv-info">
              <div class="inv-name">{{ vehicle.name }}</div>
              <div class="inv-details">
                {{ vehicle.year }} • {{ formatMileage(vehicle.mileage) }}
              </div>
              <div class="inv-value">
                Est. Value: ${{ formatPrice(vehicle.estimatedValue) }}
              </div>
            </div>
            <button class="sell-btn">Sell</button>
          </div>
        </div>
        
        <!-- My Active Listings -->
        <div v-else class="my-listings-section">
          <h4>Your Active Listings</h4>
          <div v-if="activeSellListings.length === 0" class="empty-state">
            <span class="empty-icon">📦</span>
            <span>No active listings</span>
            <span class="empty-sub">Your current listings will appear here</span>
          </div>
          <div 
            v-else
            v-for="listing in activeSellListings" 
            :key="listing.id"
            class="my-listing-card"
          >
            <div class="my-listing-info">
              <span class="my-listing-title">{{ listing.title }}</span>
              <span class="my-listing-price">${{ formatPrice(listing.price) }}</span>
            </div>
            <div class="my-listing-stats">
              <span>👁️ {{ listing.views || 0 }} views</span>
              <span :class="'status-' + listing.status">{{ listing.status }}</span>
            </div>
            <button 
              v-if="listing.status === 'available'"
              @click="cancelListing(listing.id)" 
              class="cancel-btn"
            >
              Cancel
            </button>
            <button
              v-else-if="listing.status === 'sold'"
              @click="claimListing(listing)"
              class="claim-btn"
              :disabled="claimLoadingId === listing.id"
            >
              {{ claimLoadingId === listing.id ? 'Claiming...' : 'Claim' }}
            </button>
          </div>
        </div>
      </div>
      
      <!-- Messages Tab -->
      <div v-if="activeTab === 'messages'" class="tab-content">
        <div v-if="messages.length === 0" class="empty-state">
          <span class="empty-icon">💬</span>
          <span>No messages</span>
          <span class="empty-sub">Messages from buyers will appear here</span>
        </div>
        
        <div v-else class="messages-list">
          <div 
            v-for="msg in messages" 
            :key="msg.id"
            class="message-card"
            :class="{ unread: !msg.read }"
            @click="openMessage(msg)"
          >
            <div class="msg-header">
              <span class="msg-sender">{{ msg.sender_name }}</span>
              <span class="msg-time">{{ formatTimeAgo(msg.created_at) }}</span>
            </div>
            <div class="msg-preview">{{ msg.content.substring(0, 50) }}...</div>
          </div>
        </div>
      </div>
      
      <!-- Profile Tab -->
      <div v-if="activeTab === 'profile'" class="tab-content">
        <div class="profile-header">
          <div class="profile-avatar">👤</div>
          <div class="profile-info">
            <div class="profile-name-row">
              <h3>{{ playerName }}</h3>
              <button class="edit-name-btn" @click="showNameModal = true">✏️</button>
            </div>
            <span class="profile-id">ID: {{ playerId?.substring(0, 12) }}...</span>
          </div>
        </div>
        
        <div class="profile-stats">
          <div class="stat-card">
            <span class="stat-value">{{ profileStats.totalSales || 0 }}</span>
            <span class="stat-label">Sales</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">${{ formatPrice(profileStats.totalEarned || 0) }}</span>
            <span class="stat-label">Earned</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">{{ profileStats.rating || 'N/A' }}</span>
            <span class="stat-label">Rating</span>
          </div>
        </div>
        
        <div class="profile-actions">
          <button @click="refreshData" class="action-btn">
            🔄 Refresh Data
          </button>
        </div>
      </div>
      
      <!-- Listing Detail Modal -->
      <Teleport to="body">
        <div v-if="selectedListing" class="modal-overlay" @click.self="selectedListing = null">
          <div class="listing-modal">
            <button class="modal-close" @click="selectedListing = null">✕</button>
            
            <div class="modal-image-wrap">
              <div class="modal-image">
                <template v-if="getListingPhotos(selectedListing).length">
                  <img :src="getListingPhotos(selectedListing)[listingModalPhotoIndex]" alt="" />
                  <button
                    v-if="getListingPhotos(selectedListing).length > 1"
                    type="button"
                    class="modal-photo-arrow modal-photo-prev"
                    aria-label="Previous photo"
                    @click.stop="listingModalPhotoIndex = (listingModalPhotoIndex - 1 + getListingPhotos(selectedListing).length) % getListingPhotos(selectedListing).length"
                  >
                    ‹
                  </button>
                  <button
                    v-if="getListingPhotos(selectedListing).length > 1"
                    type="button"
                    class="modal-photo-arrow modal-photo-next"
                    aria-label="Next photo"
                    @click.stop="listingModalPhotoIndex = (listingModalPhotoIndex + 1) % getListingPhotos(selectedListing).length"
                  >
                    ›
                  </button>
                  <span v-if="getListingPhotos(selectedListing).length > 1" class="modal-photo-counter">{{ listingModalPhotoIndex + 1 }} / {{ getListingPhotos(selectedListing).length }}</span>
                </template>
                <div v-else class="no-image">🚗</div>
              </div>
            </div>
            
            <div class="modal-content">
              <h2>{{ selectedListing.title }}</h2>
              <div class="modal-price">${{ formatPrice(selectedListing.price) }}</div>
              
              <div class="modal-details">
                <div class="detail-row">
                  <span>Year:</span>
                  <span>{{ selectedListing.vehicle_year || 'N/A' }}</span>
                </div>
                <div class="detail-row">
                  <span>Mileage:</span>
                  <span>{{ formatMileage(selectedListing.mileage) }}</span>
                </div>
                <div class="detail-row">
                  <span>Condition:</span>
                  <span>{{ selectedListing.condition }}%</span>
                </div>
                <div class="detail-row">
                  <span>Seller:</span>
                  <span>{{ selectedListing.seller_name }}</span>
                </div>
              </div>
              
              <p class="modal-description">{{ selectedListing.description || 'No description provided.' }}</p>
              
              <div class="modal-actions">
                <button @click="contactSeller(selectedListing)" class="contact-btn">
                  💬 Contact Seller
                </button>
                <button 
                  @click="buyVehicle(selectedListing)" 
                  class="buy-btn"
                  :disabled="isBuying || selectedListing.seller_id === playerId"
                >
                  {{ isBuying ? 'Processing...' : 'Buy Now' }}
                </button>
              </div>
            </div>
          </div>
        </div>
      </Teleport>
      
      <!-- Sell Modal -->
      <Teleport to="body">
        <div v-if="sellModalVehicle" class="modal-overlay" @click.self="sellModalVehicle = null">
          <div class="sell-modal">
            <button class="modal-close" @click="sellModalVehicle = null">✕</button>
            
            <h2>List for Sale</h2>
            <div class="sell-vehicle-preview">
              <span class="vehicle-name">{{ sellModalVehicle.name }}</span>
              <span class="vehicle-est">Est. Value: ${{ formatPrice(sellModalVehicle.estimatedValue) }}</span>
            </div>

            <div class="listing-photo-row">
              <label>Listing photos (max {{ MAX_LISTING_PHOTOS }})</label>
              <div class="listing-photo-slots">
                <div
                  v-for="(url, idx) in Array(MAX_LISTING_PHOTOS).fill(null)"
                  :key="idx"
                  class="listing-photo-slot"
                  :class="{ filled: (sellForm.photoDataUrls || [])[idx] }"
                  @click="(sellForm.photoDataUrls || [])[idx] ? removeListingPhoto(idx) : openPhotoPicker(idx)"
                >
                  <img v-if="(sellForm.photoDataUrls || [])[idx]" :src="(sellForm.photoDataUrls || [])[idx]" alt="" class="listing-photo-preview" />
                  <span v-else class="listing-photo-plus">+</span>
                </div>
              </div>
              <span class="listing-photo-hint">Tap + to add a photo from your Camera app (max {{ MAX_LISTING_PHOTOS }})</span>
            </div>
            
            <div class="sell-form">
              <div class="form-group">
                <label>Title</label>
                <input 
                  v-model="sellForm.title" 
                  type="text" 
                  :placeholder="sellModalVehicle.name"
                  maxlength="50"
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  v-bng-text-input
                />
              </div>
              
              <div class="form-group">
                <label>Price ($)</label>
                <input 
                  v-model.number="sellForm.price" 
                  type="number" 
                  :placeholder="sellModalVehicle.estimatedValue"
                  :min="100"
                  :max="50000000"
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  v-bng-text-input
                />
              </div>
              
              <div class="form-group">
                <label>Description</label>
                <textarea 
                  v-model="sellForm.description" 
                  placeholder="Describe your vehicle..."
                  maxlength="500"
                  rows="3"
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  v-bng-text-input
                ></textarea>
              </div>
              
              <div class="sell-actions">
                <button @click="sellModalVehicle = null" class="cancel-btn">Cancel</button>
                <button 
                  @click="createListing" 
                  class="list-btn"
                  :disabled="isCreatingListing"
                >
                  {{ isCreatingListing ? 'Listing...' : 'List for Sale' }}
                </button>
              </div>
            </div>
          </div>
        </div>
      </Teleport>

      <!-- Photo Picker Modal (phone camera photos for listing) -->
      <Teleport to="body">
        <div v-if="showPhotoPicker" class="modal-overlay" @click.self="showPhotoPicker = false">
          <div class="photo-picker-modal">
            <button class="modal-close" @click="showPhotoPicker = false">✕</button>
            <h3>Choose a photo</h3>
            <p class="photo-picker-sub">From your Camera app</p>
            <div v-if="loadingPhotoPicker" class="photo-picker-loading">Loading photos...</div>
            <div v-else-if="phonePhotosForPicker.length === 0" class="photo-picker-empty">
              No photos yet. Take some with the Camera app first.
            </div>
            <div v-else class="photo-picker-grid">
              <button
                v-for="photo in phonePhotosForPicker"
                :key="photo.filename"
                type="button"
                class="photo-picker-thumb"
                @click="selectListingPhoto(photo)"
              >
                <img v-if="photo.dataUrl" :src="photo.dataUrl" alt="" />
              </button>
            </div>
          </div>
        </div>
      </Teleport>

      <!-- Contact Seller Modal -->
      <Teleport to="body">
        <div v-if="messageListing" class="modal-overlay" @click.self="messageListing = null">
          <div class="sell-modal">
            <button class="modal-close" @click="messageListing = null">✕</button>

            <h2>Message Seller</h2>
            <div class="sell-vehicle-preview">
              <span class="vehicle-name">{{ messageListing.title }}</span>
              <span class="vehicle-est">Seller: {{ messageListing.seller_name }}</span>
            </div>

            <div class="sell-form">
              <div class="form-group">
                <label>Message</label>
                <textarea
                  v-model="messageText"
                  placeholder="Write a message..."
                  maxlength="500"
                  rows="4"
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  v-bng-text-input
                ></textarea>
              </div>

              <div class="sell-actions">
                <button @click="messageListing = null" class="cancel-btn">Cancel</button>
                <button
                  @click="sendMessageToSeller"
                  class="list-btn"
                  :disabled="isSendingMessage || !messageText.trim()"
                >
                  {{ isSendingMessage ? 'Sending...' : 'Send' }}
                </button>
              </div>
            </div>
          </div>
        </div>
      </Teleport>

      <!-- Edit Profile Name Modal -->
      <Teleport to="body">
        <div v-if="showNameModal" class="modal-overlay" @click.self="showNameModal = false">
          <div class="sell-modal">
            <button class="modal-close" @click="showNameModal = false">✕</button>

            <h2>Edit Display Name</h2>

            <div class="sell-form">
              <div class="form-group">
                <label>Name</label>
                <input
                  v-model="editableName"
                  type="text"
                  maxlength="50"
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  v-bng-text-input
                />
              </div>

              <div class="sell-actions">
                <button @click="showNameModal = false" class="cancel-btn">Cancel</button>
                <button @click="saveProfileName" class="list-btn" :disabled="!editableName.trim()">
                  Save
                </button>
              </div>
            </div>
          </div>
        </div>
      </Teleport>

      <!-- Missing Vehicle Claim Modal -->
      <Teleport to="body">
        <div v-if="missingClaimListing" class="modal-overlay" @click.self="missingClaimListing = null">
          <div class="sell-modal">
            <button class="modal-close" @click="missingClaimListing = null">✕</button>

            <h2>Vehicle Not Found</h2>
            <p class="modal-description">
              The vehicle for this listing is not available in your inventory.
            </p>

            <div class="sell-actions">
              <button @click="missingClaimListing = null" class="cancel-btn">Close</button>
              <button @click="removeListingFromMissing" class="list-btn">Remove Listing</button>
            </div>
          </div>
        </div>
      </Teleport>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { lua } from "@/bridge"
import { vBngTextInput } from '@/common/directives'
import PhoneWrapper from "./PhoneWrapper.vue"
import CarSwapListingCard from "../components/carswap/CarSwapListingCard.vue"
import { Teleport } from 'vue'

// State
const isConnected = ref(false)
const isLoading = ref(true)
const activeTab = ref('browse')
const searchQuery = ref('')
const showFilters = ref(false)
const listings = ref([])
const myListings = ref([])
const myInventory = ref([])
const messages = ref([])
const unreadCount = ref(0)
const playerId = ref('')
const playerName = ref('')
const profileStats = ref({})
const editableName = ref('')
const showNameModal = ref(false)
const activeSellTab = ref('vehicles')
const missingClaimListing = ref(null)
const claimLoadingId = ref(null)

const onInputFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onInputBlur = () => {
  try { lua.setCEFTyping(false) } catch (_) {}
}

// Filters
const filters = ref({
  minPrice: null,
  maxPrice: null,
  model: null
})

// Modals
const selectedListing = ref(null)
const sellModalVehicle = ref(null)
const isBuying = ref(false)
const isCreatingListing = ref(false)
const messageListing = ref(null)
const messageText = ref('')
const isSendingMessage = ref(false)

// Sell form (up to 4 photos)
const MAX_LISTING_PHOTOS = 4
const sellForm = ref({
  title: '',
  price: 0,
  description: '',
  photoDataUrls: []
})

// Photo picker (phone camera photos for listing)
const showPhotoPicker = ref(false)
const photoPickerTargetSlot = ref(0)
const phonePhotosForPicker = ref([])
const loadingPhotoPicker = ref(false)

// Tabs
const tabs = computed(() => [
  { id: 'browse', label: 'Browse', icon: '🔍', badge: null },
  { id: 'sell', label: 'Sell', icon: '💰', badge: activeSellListings.value.length || null },
  { id: 'messages', label: 'Messages', icon: '💬', badge: unreadCount.value || null },
  { id: 'profile', label: 'Profile', icon: '👤', badge: null }
])

const sellTabs = [
  { id: 'vehicles', label: 'My Vehicles' },
  { id: 'listings', label: 'My Listings' }
]

// Computed
const filteredListings = computed(() => {
  let result = listings.value
  
  if (searchQuery.value) {
    const query = searchQuery.value.toLowerCase()
    result = result.filter(l => 
      l.title?.toLowerCase().includes(query) ||
      l.vehicle_model?.toLowerCase().includes(query) ||
      l.seller_name?.toLowerCase().includes(query)
    )
  }
  
  if (filters.value.minPrice) {
    result = result.filter(l => l.price >= filters.value.minPrice)
  }
  
  if (filters.value.maxPrice) {
    result = result.filter(l => l.price <= filters.value.maxPrice)
  }
  
  return result
})

const activeSellListings = computed(() => {
  const raw = myListings.value
  const list = Array.isArray(raw) ? raw : []
  return list.filter(l => l.status !== 'cancelled' && l.status !== 'expired')
})

// Methods
const formatPrice = (price) => {
  if (!price) return '0'
  return Number(price).toLocaleString()
}

const formatMileage = (miles) => {
  if (!miles) return '0 mi'
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

const refreshData = async () => {
  isLoading.value = true
  try {
    if (!lua.gameplay_carswap) {
      console.warn('CarSwap extension (gameplay_carswap) not available')
      isConnected.value = false
      return
    }
    const data = await lua.gameplay_carswap.getUIData()
    if (data) {
      isConnected.value = data.isConnected
      playerId.value = data.playerId
      playerName.value = data.playerName
      editableName.value = data.playerName
      listings.value = data.listings || []
      myListings.value = Array.isArray(data.myListings) ? data.myListings : []
      unreadCount.value = data.unreadMessages || 0
    }
    
    // Get inventory for selling
    const inventory = await lua.gameplay_carswap.getInventoryForListing()
    myInventory.value = inventory || []
    
  } catch (e) {
    console.error('Failed to load CarSwap data:', e)
    isConnected.value = false
  } finally {
    isLoading.value = false
  }
}

const toggleFilters = () => {
  showFilters.value = !showFilters.value
}

const applyFilters = () => {
  showFilters.value = false
  refreshData()
}

const listingModalPhotoIndex = ref(0)

const openListing = (listing) => {
  selectedListing.value = listing
  listingModalPhotoIndex.value = 0
}

const openSellModal = (vehicle) => {
  sellModalVehicle.value = vehicle
  sellForm.value = {
    title: vehicle.name,
    price: vehicle.estimatedValue || 10000,
    description: '',
    photoDataUrls: []
  }
}

// Listing photos for modal. Prefer separate columns (no JSON) then legacy thumbnail_base64_full / JSON string.
function getListingPhotos(listing) {
  const t2 = listing?.thumbnail_2_base64 ?? listing?.thumbnail2Base64
  if (t2 != null && t2 !== '') {
    const parts = [
      listing?.thumbnail_base64 ?? listing?.thumbnailBase64,
      t2,
      listing?.thumbnail_3_base64 ?? listing?.thumbnail3Base64,
      listing?.thumbnail_4_base64 ?? listing?.thumbnail4Base64
    ].filter(b => typeof b === 'string' && b.trim())
    if (parts.length > 0) return parts.map(b => `data:image/jpeg;base64,${b.trim()}`)
  }
  const full = listing?.thumbnail_base64_full ?? listing?.thumbnailBase64Full
  if (full != null && full !== '') {
    if (Array.isArray(full)) {
      return full.filter(b => typeof b === 'string' && b).map(b => `data:image/jpeg;base64,${b}`)
    }
    if (typeof full === 'string' && full.startsWith('[')) {
      try {
        const arr = JSON.parse(full)
        return (Array.isArray(arr) ? arr : []).filter(Boolean).map(b => `data:image/jpeg;base64,${b}`)
      } catch {
        return []
      }
    }
  }
  const t = listing?.thumbnail_base64 ?? listing?.thumbnailBase64
  if (t == null || t === '') return []
  if (Array.isArray(t)) {
    return t.filter(b => typeof b === 'string' && b).map(b => `data:image/jpeg;base64,${b}`)
  }
  if (typeof t === 'string' && t.startsWith('[')) {
    try {
      const arr = JSON.parse(t)
      return (Array.isArray(arr) ? arr : []).filter(Boolean).map(b => `data:image/jpeg;base64,${b}`)
    } catch {
      return []
    }
  }
  if (typeof t === 'string') return [`data:image/jpeg;base64,${t}`]
  return []
}

const openPhotoPicker = async (slotIndex) => {
  photoPickerTargetSlot.value = slotIndex
  showPhotoPicker.value = true
  phonePhotosForPicker.value = []
  loadingPhotoPicker.value = true
  try {
    const list = (await lua.gameplay_phoneCamera?.getPhotoList()) || []
    const items = Array.isArray(list) ? list : []
    const withUrls = await Promise.all(
      items.map(async (item) => {
        const filename = item?.filename ?? item?.name ?? item
        if (typeof filename !== 'string') return null
        const dataUrl = await lua.gameplay_phoneCamera?.getPhotoAsDataUrl(filename)
        return { filename, dataUrl }
      })
    )
    phonePhotosForPicker.value = withUrls.filter(Boolean)
  } catch (e) {
    console.error('Failed to load phone photos', e)
  } finally {
    loadingPhotoPicker.value = false
  }
}

const selectListingPhoto = (photo) => {
  if (photo?.dataUrl) {
    const urls = [...(sellForm.value.photoDataUrls || [])]
    urls[photoPickerTargetSlot.value] = photo.dataUrl
    sellForm.value.photoDataUrls = urls.slice(0, MAX_LISTING_PHOTOS)
  }
  showPhotoPicker.value = false
}

const removeListingPhoto = (index) => {
  const urls = [...(sellForm.value.photoDataUrls || [])]
  urls.splice(index, 1)
  sellForm.value.photoDataUrls = urls
}

// Resize/compress image to smaller base64 so we can send multiple photos without freezing
const LISTING_PHOTO_MAX_SIZE = 480
const LISTING_PHOTO_JPEG_QUALITY = 0.65

function resizePhotoToBase64(dataUrl) {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => {
      const w = img.naturalWidth || img.width
      const h = img.naturalHeight || img.height
      const scale = Math.min(1, LISTING_PHOTO_MAX_SIZE / Math.max(w, h))
      const cw = Math.round(w * scale)
      const ch = Math.round(h * scale)
      const canvas = document.createElement('canvas')
      canvas.width = cw
      canvas.height = ch
      const ctx = canvas.getContext('2d')
      if (!ctx) { reject(new Error('No canvas context')); return }
      ctx.drawImage(img, 0, 0, cw, ch)
      const out = canvas.toDataURL('image/jpeg', LISTING_PHOTO_JPEG_QUALITY)
      const m = out.match(/^data:image\/jpeg;base64,(.+)$/)
      resolve(m ? m[1] : null)
    }
    img.onerror = () => reject(new Error('Image load failed'))
    img.src = dataUrl
  })
}

const createListing = async () => {
  if (!sellModalVehicle.value) return
  
  isCreatingListing.value = true
  try {
    const urls = (sellForm.value.photoDataUrls || []).slice(0, MAX_LISTING_PHOTOS).filter(Boolean)
    const thumbnailBase64Array = []
    for (const dataUrl of urls) {
      try {
        const b64 = await resizePhotoToBase64(dataUrl)
        if (b64) thumbnailBase64Array.push(b64)
      } catch (e) {
        console.warn('Resize failed for one photo, skipping', e)
      }
    }
    // Send as JSON string so the Lua bridge (5th arg typed String) passes all photos through
    const payload = thumbnailBase64Array.length ? JSON.stringify(thumbnailBase64Array) : null
    await lua.gameplay_carswap.createListing(
      sellModalVehicle.value.inventoryId,
      sellForm.value.price,
      sellForm.value.title,
      sellForm.value.description,
      payload
    )
    sellModalVehicle.value = null
    refreshData()
  } catch (e) {
    console.error('Failed to create listing:', e)
    alert('Failed to create listing')
  } finally {
    isCreatingListing.value = false
  }
}

const cancelListing = async (listingId) => {
  try {
    await lua.gameplay_carswap.cancelListing(listingId)
    refreshData()
  } catch (e) {
    console.error('Failed to cancel listing:', e)
  }
}

const claimListing = async (listing) => {
  if (!listing?.id) return
  claimLoadingId.value = listing.id
  try {
    const result = await lua.gameplay_carswap.claimListing(listing.id)
    if (result?.success) {
      refreshData()
    } else if (result?.reason === 'vehicle_missing') {
      missingClaimListing.value = listing
    } else {
      alert('Claim failed: ' + (result?.reason || 'Unknown error'))
    }
  } catch (e) {
    console.error('Failed to claim listing:', e)
    alert('Claim failed')
  } finally {
    claimLoadingId.value = null
  }
}

const removeListingFromMissing = async () => {
  if (!missingClaimListing.value) return
  try {
    await lua.gameplay_carswap.cancelListing(missingClaimListing.value.id)
    missingClaimListing.value = null
    refreshData()
  } catch (e) {
    console.error('Failed to remove listing:', e)
  }
}

const buyVehicle = async (listing) => {
  if (listing.seller_id === playerId.value) {
    alert("You can't buy your own listing!")
    return
  }
  
  isBuying.value = true
  try {
    const result = await lua.gameplay_carswap.purchaseVehicle(listing.id)
    if (result && result.success) {
      alert('Purchase successful! Vehicle added to your inventory.')
      selectedListing.value = null
      refreshData()
    } else {
      alert('Purchase failed: ' + (result?.error || 'Unknown error'))
    }
  } catch (e) {
    console.error('Failed to purchase:', e)
    alert('Purchase failed')
  } finally {
    isBuying.value = false
  }
}

const contactSeller = (listing) => {
  messageListing.value = listing
  messageText.value = ''
}

const sendMessageToSeller = async () => {
  if (!messageListing.value || !messageText.value.trim()) return
  isSendingMessage.value = true
  try {
    await lua.gameplay_carswap.sendMessage(messageListing.value.id, messageText.value.trim())
    messageListing.value = null
    messageText.value = ''
  } catch (e) {
    console.error('Failed to send message:', e)
    alert('Failed to send message')
  } finally {
    isSendingMessage.value = false
  }
}

const saveProfileName = async () => {
  if (!editableName.value.trim()) return
  try {
    await lua.gameplay_carswap.setProfileName(editableName.value.trim())
    playerName.value = editableName.value.trim()
    showNameModal.value = false
  } catch (e) {
    console.error('Failed to save profile name:', e)
  }
}

const openMessage = async (msg) => {
  if (!msg.read) {
    await lua.gameplay_carswap.markMessageRead(msg.id)
    msg.read = true
    unreadCount.value = Math.max(0, unreadCount.value - 1)
  }
  // TODO: Open full message view
}

// Lifecycle
let refreshInterval = null

onMounted(() => {
  refreshData()
  // Refresh every 30 seconds
  refreshInterval = setInterval(refreshData, 30000)
})

onUnmounted(() => {
  if (refreshInterval) {
    clearInterval(refreshInterval)
  }
})
</script>

<style scoped lang="scss">
.carswap-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  padding-top: 52px;
  background: linear-gradient(180deg, #0a0a0a 0%, #1a1a2e 100%);
  color: white;
}

.connection-error {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 10px;
  background: rgba(239, 68, 68, 0.2);
  border-bottom: 1px solid rgba(239, 68, 68, 0.4);
  font-size: 0.85em;
  
  .error-icon {
    font-size: 1.2em;
  }
  
  .retry-btn {
    padding: 4px 12px;
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 4px;
    color: white;
    cursor: pointer;
    font-size: 0.9em;
    
    &:hover {
      background: rgba(255, 255, 255, 0.2);
    }
  }
}

.tabs {
  display: flex;
  padding: 8px;
  gap: 4px;
  background: rgba(0, 0, 0, 0.3);
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.tab-btn {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 2px;
  padding: 8px 4px;
  background: transparent;
  border: none;
  border-radius: 8px;
  color: rgba(255, 255, 255, 0.5);
  cursor: pointer;
  position: relative;
  transition: all 0.2s;
  
  &.active {
    background: rgba(0, 212, 170, 0.2);
    color: #00d4aa;
  }
  
  &:hover:not(.active) {
    background: rgba(255, 255, 255, 0.05);
  }
  
  .tab-icon {
    font-size: 1.3em;
  }
  
  .tab-label {
    font-size: 0.7em;
    font-weight: 500;
  }
  
  .tab-badge {
    position: absolute;
    top: 4px;
    right: 4px;
    min-width: 16px;
    height: 16px;
    padding: 0 4px;
    background: #ef4444;
    border-radius: 8px;
    font-size: 0.65em;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
  }
}

.tab-content {
  flex: 1;
  overflow-y: auto;
  padding: 12px;
}

.search-bar {
  display: flex;
  gap: 8px;
  margin-bottom: 12px;
  
  .search-input {
    flex: 1;
    padding: 10px 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    color: white;
    font-size: 0.9em;
    
    &::placeholder {
      color: rgba(255, 255, 255, 0.3);
    }
    
    &:focus {
      outline: none;
      border-color: #00d4aa;
    }
  }
  
  .filter-btn {
    padding: 10px 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    color: white;
    cursor: pointer;
    font-size: 0.85em;
    
    &:hover {
      background: rgba(255, 255, 255, 0.1);
    }
  }
}

.filters-panel {
  padding: 12px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 8px;
  margin-bottom: 12px;
  
  .filter-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
    
    label {
      width: 80px;
      font-size: 0.85em;
      color: rgba(255, 255, 255, 0.7);
    }
    
    input {
      flex: 1;
      padding: 6px 10px;
      background: rgba(255, 255, 255, 0.05);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 4px;
      color: white;
    }
  }
  
  .apply-btn {
    width: 100%;
    padding: 8px;
    background: #00d4aa;
    border: none;
    border-radius: 4px;
    color: #000;
    font-weight: 600;
    cursor: pointer;
    
    &:hover {
      background: #00b894;
    }
  }
}

.loading {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 40px;
  gap: 12px;
  color: rgba(255, 255, 255, 0.5);
  
  .spinner {
    width: 32px;
    height: 32px;
    border: 3px solid rgba(255, 255, 255, 0.1);
    border-top-color: #00d4aa;
    border-radius: 50%;
    animation: spin 1s linear infinite;
  }
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 40px;
  text-align: center;
  
  .empty-icon {
    font-size: 3em;
    margin-bottom: 12px;
    opacity: 0.3;
  }
  
  span {
    color: rgba(255, 255, 255, 0.5);
  }
  
  .empty-sub {
    font-size: 0.85em;
    margin-top: 4px;
  }
}

.listings-grid {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

// Sell Tab
.sell-header {
  margin-bottom: 16px;
  
  h3 {
    margin: 0 0 4px 0;
    color: #00d4aa;
  }
  
  p {
    margin: 0;
    font-size: 0.85em;
    color: rgba(255, 255, 255, 0.5);
  }
}

.sell-subtabs {
  display: flex;
  gap: 6px;
  margin-bottom: 12px;
}

.sell-subtab-btn {
  flex: 1;
  padding: 6px 10px;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 6px;
  color: rgba(255, 255, 255, 0.7);
  cursor: pointer;
  font-size: 0.85em;

  &.active {
    color: #00d4aa;
    border-color: rgba(0, 212, 170, 0.5);
    background: rgba(0, 212, 170, 0.15);
  }
}

.inventory-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.inventory-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px;
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 8px;
  cursor: pointer;
  
  &:hover {
    border-color: #00d4aa;
  }
  
  .inv-image {
    width: 60px;
    height: 60px;
    background: #1a1a1a;
    border-radius: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    
    img {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }
    
    span {
      font-size: 1.5em;
      opacity: 0.3;
    }
  }
  
  .inv-info {
    flex: 1;
    
    .inv-name {
      font-weight: 600;
      margin-bottom: 2px;
    }
    
    .inv-details {
      font-size: 0.8em;
      color: rgba(255, 255, 255, 0.5);
    }
    
    .inv-value {
      font-size: 0.85em;
      color: #00d4aa;
      margin-top: 4px;
    }
  }
  
  .sell-btn {
    padding: 8px 16px;
    background: #00d4aa;
    border: none;
    border-radius: 4px;
    color: #000;
    font-weight: 600;
    cursor: pointer;
    
    &:hover {
      background: #00b894;
    }
  }
}

.my-listings-section {
  margin-top: 24px;
  padding-top: 16px;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  
  h4 {
    margin: 0 0 12px 0;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.9em;
  }
}

.my-listing-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 6px;
  margin-bottom: 8px;
  
  .my-listing-info {
    flex: 1;
    
    .my-listing-title {
      display: block;
      font-weight: 500;
      font-size: 0.9em;
    }
    
    .my-listing-price {
      font-size: 0.85em;
      color: #00d4aa;
    }
  }
  
  .my-listing-stats {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
    font-size: 0.75em;
    color: rgba(255, 255, 255, 0.5);
    
    .status-available {
      color: #00d4aa;
    }
    
    .status-sold {
      color: #ef4444;
    }

    .status-expired {
      color: rgba(255, 255, 255, 0.4);
    }
  }
  
  .cancel-btn {
    padding: 6px 12px;
    background: rgba(239, 68, 68, 0.2);
    border: 1px solid rgba(239, 68, 68, 0.4);
    border-radius: 4px;
    color: #ef4444;
    font-size: 0.8em;
    cursor: pointer;
    
    &:hover {
      background: rgba(239, 68, 68, 0.3);
    }
  }

  .claim-btn {
    padding: 6px 12px;
    background: rgba(34, 197, 94, 0.2);
    border: 1px solid rgba(34, 197, 94, 0.5);
    border-radius: 4px;
    color: #22c55e;
    font-size: 0.8em;
    cursor: pointer;

    &:hover {
      background: rgba(34, 197, 94, 0.3);
    }

    &:disabled {
      opacity: 0.6;
      cursor: default;
    }
  }
}

// Messages Tab
.messages-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.message-card {
  padding: 12px;
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 8px;
  cursor: pointer;
  
  &.unread {
    border-left: 3px solid #00d4aa;
    background: rgba(0, 212, 170, 0.05);
  }
  
  &:hover {
    background: rgba(255, 255, 255, 0.05);
  }
  
  .msg-header {
    display: flex;
    justify-content: space-between;
    margin-bottom: 4px;
    
    .msg-sender {
      font-weight: 600;
      font-size: 0.9em;
    }
    
    .msg-time {
      font-size: 0.75em;
      color: rgba(255, 255, 255, 0.4);
    }
  }
  
  .msg-preview {
    font-size: 0.85em;
    color: rgba(255, 255, 255, 0.6);
  }
}

// Profile Tab
.profile-header {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 16px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 12px;
  margin-bottom: 16px;
  
  .profile-avatar {
    width: 60px;
    height: 60px;
    background: rgba(0, 212, 170, 0.2);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 2em;
  }
  
  .profile-info {
    h3 {
      margin: 0 0 4px 0;
    }
    
    .profile-id {
      font-size: 0.8em;
      color: rgba(255, 255, 255, 0.4);
      font-family: monospace;
    }
  }
}

.profile-name-row {
  display: flex;
  align-items: center;
  gap: 6px;
}

.edit-name-btn {
  background: transparent;
  border: none;
  color: white;
  cursor: pointer;
  font-size: 0.9em;
  opacity: 0.7;

  &:hover {
    opacity: 1;
  }
}

.profile-stats {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
  
  .stat-card {
    flex: 1;
    padding: 12px;
    background: rgba(0, 0, 0, 0.3);
    border-radius: 8px;
    text-align: center;
    
    .stat-value {
      display: block;
      font-size: 1.3em;
      font-weight: 700;
      color: #00d4aa;
    }
    
    .stat-label {
      font-size: 0.75em;
      color: rgba(255, 255, 255, 0.5);
    }
  }
}

.profile-actions {
  .action-btn {
    width: 100%;
    padding: 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    color: white;
    cursor: pointer;
    
    &:hover {
      background: rgba(255, 255, 255, 0.1);
    }
  }
}

// Modals
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.8);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  padding: 20px;
}

.listing-modal,
.sell-modal {
  background: #1a1a2e;
  border-radius: 16px;
  max-width: 400px;
  width: 100%;
  max-height: 80vh;
  overflow-y: auto;
  position: relative;
}

.modal-close {
  position: absolute;
  top: 12px;
  right: 12px;
  width: 32px;
  height: 32px;
  background: rgba(255, 255, 255, 0.1);
  border: none;
  border-radius: 50%;
  color: white;
  font-size: 1.2em;
  cursor: pointer;
  z-index: 1;
  
  &:hover {
    background: rgba(255, 255, 255, 0.2);
  }
}

.modal-image-wrap {
  position: relative;
}

.modal-image {
  position: relative;
  width: 100%;
  height: 200px;
  background: #0a0a0a;
  
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
    font-size: 4em;
    opacity: 0.2;
  }
}

.modal-photo-arrow {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  width: 40px;
  height: 40px;
  border: none;
  border-radius: 50%;
  background: rgba(0, 0, 0, 0.6);
  color: #fff;
  font-size: 1.5rem;
  line-height: 1;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  z-index: 2;
  transition: background 0.2s;

  &:hover {
    background: rgba(0, 212, 170, 0.9);
    color: #000;
  }
}

.modal-photo-prev {
  left: 8px;
}

.modal-photo-next {
  right: 8px;
}

.modal-photo-counter {
  position: absolute;
  bottom: 8px;
  left: 50%;
  transform: translateX(-50%);
  padding: 4px 10px;
  border-radius: 6px;
  background: rgba(0, 0, 0, 0.6);
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.9);
  z-index: 2;
}

.modal-content {
  padding: 20px;
  
  h2 {
    margin: 0 0 8px 0;
    font-size: 1.3em;
  }
  
  .modal-price {
    font-size: 1.5em;
    font-weight: 700;
    color: #00d4aa;
    margin-bottom: 16px;
  }
  
  .modal-details {
    margin-bottom: 16px;
    
    .detail-row {
      display: flex;
      justify-content: space-between;
      padding: 8px 0;
      border-bottom: 1px solid rgba(255, 255, 255, 0.05);
      font-size: 0.9em;
      
      span:first-child {
        color: rgba(255, 255, 255, 0.5);
      }
    }
  }
  
  .modal-description {
    font-size: 0.9em;
    color: rgba(255, 255, 255, 0.7);
    line-height: 1.5;
    margin-bottom: 20px;
  }
  
  .modal-actions {
    display: flex;
    gap: 12px;
    
    button {
      flex: 1;
      padding: 12px;
      border: none;
      border-radius: 8px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s;
      
      &.contact-btn {
        background: rgba(255, 255, 255, 0.1);
        color: white;
        
        &:hover {
          background: rgba(255, 255, 255, 0.2);
        }
      }
      
      &.buy-btn {
        background: #00d4aa;
        color: #000;
        
        &:hover:not(:disabled) {
          background: #00b894;
        }
        
        &:disabled {
          opacity: 0.5;
          cursor: not-allowed;
        }
      }
    }
  }
}

// Sell Modal Specific
.sell-modal {
  padding: 20px;
  
  h2 {
    margin: 0 0 16px 0;
    padding-right: 40px;
  }
}

.sell-vehicle-preview {
  padding: 12px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 8px;
  margin-bottom: 16px;
  
  .vehicle-name {
    display: block;
    font-weight: 600;
    margin-bottom: 4px;
  }
  
  .vehicle-est {
    font-size: 0.85em;
    color: #00d4aa;
  }
}

.listing-photo-row {
  margin-bottom: 16px;

  label {
    display: block;
    font-size: 0.85em;
    color: rgba(255, 255, 255, 0.7);
    margin-bottom: 8px;
  }
}

.listing-photo-slots {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 10px;
}

.listing-photo-slot {
  width: 100%;
  aspect-ratio: 1;
  border-radius: 8px;
  border: 2px dashed rgba(255, 255, 255, 0.3);
  background: rgba(0, 0, 0, 0.3);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  overflow: hidden;
  transition: border-color 0.2s, background 0.2s;

  &:hover {
    border-color: #00d4aa;
    background: rgba(0, 212, 170, 0.1);
  }

  &.filled {
    border-style: solid;
    border-color: rgba(255, 255, 255, 0.2);
  }

  .listing-photo-plus {
    font-size: 2rem;
    color: rgba(255, 255, 255, 0.6);
    line-height: 1;
  }

  .listing-photo-preview {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.listing-photo-hint {
  display: block;
  font-size: 0.8em;
  color: rgba(255, 255, 255, 0.5);
  margin-top: 6px;
}

.photo-picker-modal {
  padding: 20px;
  max-width: 320px;
  max-height: 80vh;
  overflow: hidden;
  display: flex;
  flex-direction: column;

  h3 {
    margin: 0 0 4px 0;
    padding-right: 36px;
  }
}

.photo-picker-sub {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.6);
  margin: 0 0 16px 0;
}

.photo-picker-loading,
.photo-picker-empty {
  padding: 24px;
  text-align: center;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.9em;
}

.photo-picker-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 10px;
  overflow-y: auto;
  flex: 1;
  min-height: 0;
}

.photo-picker-thumb {
  aspect-ratio: 1;
  border-radius: 8px;
  overflow: hidden;
  border: 2px solid transparent;
  background: rgba(0, 0, 0, 0.3);
  padding: 0;
  cursor: pointer;
  transition: border-color 0.2s;

  &:hover {
    border-color: #00d4aa;
  }

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.sell-form {
  .form-group {
    margin-bottom: 16px;
    
    label {
      display: block;
      font-size: 0.85em;
      color: rgba(255, 255, 255, 0.7);
      margin-bottom: 6px;
    }
    
    input,
    textarea {
      width: 100%;
      padding: 10px 12px;
      background: rgba(255, 255, 255, 0.05);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 6px;
      color: white;
      font-size: 0.95em;
      
      &:focus {
        outline: none;
        border-color: #00d4aa;
      }
    }
    
    textarea {
      resize: vertical;
      min-height: 80px;
    }
  }
  
  .sell-actions {
    display: flex;
    gap: 12px;
    
    button {
      flex: 1;
      padding: 12px;
      border: none;
      border-radius: 8px;
      font-weight: 600;
      cursor: pointer;
      
      &.cancel-btn {
        background: rgba(255, 255, 255, 0.1);
        color: white;
      }
      
      &.list-btn {
        background: #00d4aa;
        color: #000;
        
        &:disabled {
          opacity: 0.5;
          cursor: not-allowed;
        }
      }
    }
  }
}
</style>

