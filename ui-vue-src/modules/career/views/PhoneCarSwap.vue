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
      <Transition name="tab-fade" mode="out-in">
      <div v-if="activeTab === 'browse'" key="browse" class="tab-content">
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
        
        <Transition name="expand">
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
        </Transition>
        
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
      </Transition>
      
      <!-- Sell Tab -->
      <Transition name="tab-fade" mode="out-in">
      <div v-if="activeTab === 'sell'" key="sell" class="tab-content">
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
      </Transition>
      
      <!-- Messages Tab -->
      <Transition name="tab-fade" mode="out-in">
      <div v-if="activeTab === 'messages'" key="messages" class="tab-content">
        <div class="messages-subtabs">
          <button
            v-for="t in messageSubTabs"
            :key="t.id"
            class="sell-subtab-btn"
            :class="{ active: activeMessagesTab === t.id }"
            @click="activeMessagesTab = t.id"
          >
            {{ t.label }}
          </button>
        </div>

        <!-- Received -->
        <template v-if="activeMessagesTab === 'received'">
          <div v-if="messages.length === 0" class="empty-state">
            <span class="empty-icon">📥</span>
            <span>No received messages</span>
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
                <span class="msg-sender">From: {{ msg.sender_name }}</span>
                <span class="msg-time">{{ formatTimeAgo(msg.created_at) }}</span>
              </div>
              <div class="msg-preview">{{ msg.content.length > 50 ? msg.content.substring(0, 50) + '...' : msg.content }}</div>
            </div>
          </div>
        </template>

        <!-- Sent -->
        <template v-else>
          <div v-if="sentMessages.length === 0" class="empty-state">
            <span class="empty-icon">📤</span>
            <span>No sent messages</span>
            <span class="empty-sub">Messages you send to sellers will appear here</span>
          </div>
          <div v-else class="messages-list">
            <div
              v-for="msg in sentMessages"
              :key="msg.id"
              class="message-card sent"
              @click="openMessage(msg)"
            >
              <div class="msg-header">
                <span class="msg-sender">To: {{ msg.recipient_id ? String(msg.recipient_id).substring(0, 12) + '…' : '—' }}</span>
                <span class="msg-time">{{ formatTimeAgo(msg.created_at) }}</span>
              </div>
              <div class="msg-preview">{{ msg.content.length > 50 ? msg.content.substring(0, 50) + '...' : msg.content }}</div>
            </div>
          </div>
        </template>
      </div>
      </Transition>
      
      <!-- Profile Tab -->
      <Transition name="tab-fade" mode="out-in">
      <div v-if="activeTab === 'profile'" key="profile" class="tab-content">
        <div class="profile-header">
          <div class="profile-avatar">👤</div>
          <div class="profile-info">
            <div class="profile-name-row">
              <h3>{{ playerName }}</h3>
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
      </Transition>
      
      <!-- Listing Detail Modal -->
      <Teleport to="body">
        <Transition name="modal">
        <div v-if="selectedListing" class="modal-overlay" @click.self="selectedListing = null">
          <div class="listing-modal modal-panel">
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
        </Transition>
      </Teleport>
      
      <!-- Sell Modal -->
      <Teleport to="body">
        <Transition name="modal">
        <div v-if="sellModalVehicle" class="modal-overlay" @click.self="sellModalVehicle = null">
          <div class="sell-modal modal-panel">
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
        </Transition>
      </Teleport>

      <!-- Photo Picker Modal (phone camera photos for listing) -->
      <Teleport to="body">
        <Transition name="modal">
        <div v-if="showPhotoPicker" class="modal-overlay" @click.self="showPhotoPicker = false">
          <div class="photo-picker-modal modal-panel">
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
        </Transition>
      </Teleport>

      <!-- Contact Seller Modal -->
      <Teleport to="body">
        <Transition name="modal">
        <div v-if="messageListing" class="modal-overlay" @click.self="messageListing = null">
          <div class="sell-modal modal-panel">
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
        </Transition>
      </Teleport>

      <!-- First-time: Enter your name to use CarSwap (blocking) -->
      <Teleport to="body">
        <Transition name="modal">
        <div v-if="showNameRequiredModal" class="modal-overlay name-required-overlay">
          <div class="sell-modal modal-panel name-required-panel">
            <h2>Welcome to CarSwap</h2>
            <p class="name-required-sub">Enter your display name to use the app. This name will be shown on your listings.</p>

            <div class="sell-form">
              <div class="form-group">
                <label>Your name</label>
                <input
                  v-model="editableName"
                  type="text"
                  maxlength="50"
                  placeholder="e.g. Driver Mike"
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  v-bng-text-input
                />
              </div>

              <div class="sell-actions">
                <button @click="submitNameAndContinue" class="list-btn name-required-btn" :disabled="!editableName.trim()">
                  Continue
                </button>
              </div>
            </div>
          </div>
        </div>
        </Transition>
      </Teleport>

      <!-- Missing Vehicle Claim Modal -->
      <Teleport to="body">
        <Transition name="modal">
        <div v-if="missingClaimListing" class="modal-overlay" @click.self="missingClaimListing = null">
          <div class="sell-modal modal-panel">
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
        </Transition>
      </Teleport>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, Transition } from 'vue'
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
const sentMessages = ref([])
const unreadCount = ref(0)
const activeMessagesTab = ref('received')
const messageSubTabs = [
  { id: 'received', label: 'Received' },
  { id: 'sent', label: 'Sent' }
]
const playerId = ref('')
const playerName = ref('')
const profileStats = ref({})
const editableName = ref('')
const showNameRequiredModal = ref(false)
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
      editableName.value = data.playerName || ''
      listings.value = data.listings || []
      myListings.value = Array.isArray(data.myListings) ? data.myListings : []
      messages.value = Array.isArray(data.messages) ? data.messages : []
      sentMessages.value = Array.isArray(data.sentMessages) ? data.sentMessages : []
      unreadCount.value = data.unreadMessages || 0
      if (data.nameRequired) showNameRequiredModal.value = true
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

const submitNameAndContinue = async () => {
  if (!editableName.value.trim()) return
  try {
    await lua.gameplay_carswap.setProfileName(editableName.value.trim())
    playerName.value = editableName.value.trim()
    showNameRequiredModal.value = false
  } catch (e) {
    console.error('Failed to save display name:', e)
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
@use "sass:color";
// —— Theme (CarSwap) — BeamNG orange accent ——
$primary: #f37f2a;
$primary-dim: rgba(243, 127, 42, 0.2);
$primary-glow: rgba(243, 127, 42, 0.35);
$surface-0: #0c0e14;
$surface-1: #12151d;
$surface-2: #1a1e28;
$surface-3: #232830;
$text: #f0f2f5;
$text-muted: rgba(255, 255, 255, 0.55);
$text-dim: rgba(255, 255, 255, 0.4);
$border: rgba(255, 255, 255, 0.08);
$border-focus: rgba(243, 127, 42, 0.6);
$radius-sm: 10px;
$radius-md: 14px;
$radius-lg: 20px;
$radius-xl: 24px;
$shadow: 0 4px 24px rgba(0, 0, 0, 0.4);
$shadow-lg: 0 12px 48px rgba(0, 0, 0, 0.5);
$ease-out: cubic-bezier(0.22, 1, 0.36, 1);
$ease-spring: cubic-bezier(0.34, 1.56, 0.64, 1);
$danger: #f43f5e;
$success: #22c55e;

.carswap-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  padding-top: 52px;
  background: linear-gradient(180deg, $surface-0 0%, $surface-1 50%, #0f1219 100%);
  color: $text;
}

// —— Transitions (opacity only so tab content doesn’t jump) ——
.tab-fade-enter-active,
.tab-fade-leave-active {
  transition: opacity 0.2s $ease-out;
}
.tab-fade-enter-from,
.tab-fade-leave-to {
  opacity: 0;
}

.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.3s $ease-out;
  .modal-panel {
    transition: transform 0.35s $ease-spring, opacity 0.3s $ease-out;
  }
}
.modal-enter-from,
.modal-leave-to {
  opacity: 0;
  .modal-panel {
    transform: scale(0.92);
    opacity: 0;
  }
}

.expand-enter-active,
.expand-leave-active {
  transition: opacity 0.25s $ease-out, transform 0.25s $ease-out;
  transform-origin: top;
}
.expand-enter-from,
.expand-leave-to {
  opacity: 0;
  transform: scaleY(0.9);
}

.connection-error {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 10px;
  padding: 12px 16px;
  background: rgba($danger, 0.15);
  border-bottom: 1px solid rgba($danger, 0.35);
  font-size: 0.85em;
  animation: shake-in 0.4s $ease-out;
  .error-icon { font-size: 1.2em; }
  .retry-btn {
    padding: 6px 14px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid $border;
    border-radius: $radius-sm;
    color: $text;
    cursor: pointer;
    font-size: 0.9em;
    transition: all 0.2s $ease-out;
    &:hover {
      background: rgba(255, 255, 255, 0.15);
      transform: scale(1.02);
    }
    &:active { transform: scale(0.98); }
  }
}

@keyframes shake-in {
  0%, 100% { transform: translateX(0); }
  20% { transform: translateX(-4px); }
  40% { transform: translateX(4px); }
  60% { transform: translateX(-2px); }
  80% { transform: translateX(2px); }
}

.tabs {
  display: flex;
  padding: 10px;
  gap: 6px;
  background: rgba(0, 0, 0, 0.35);
  backdrop-filter: blur(12px);
  border-bottom: 1px solid $border;
}

.tab-btn {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  padding: 10px 6px;
  background: transparent;
  border: none;
  border-radius: $radius-md;
  color: $text-muted;
  cursor: pointer;
  position: relative;
  transition: color 0.25s $ease-out, background 0.25s $ease-out, transform 0.2s $ease-out;
  &:hover:not(.active) {
    background: rgba(255, 255, 255, 0.06);
    color: $text;
  }
  &:active { transform: scale(0.98); }
  &.active {
    background: $primary-dim;
    color: $primary;
    box-shadow: 0 0 0 1px rgba($primary, 0.25);
  }
  .tab-icon { font-size: 1.35em; }
  .tab-label { font-size: 0.7em; font-weight: 600; letter-spacing: 0.02em; }
  .tab-badge {
    position: absolute;
    top: 4px;
    right: 6px;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    background: $danger;
    border-radius: 10px;
    font-size: 0.65em;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    animation: pulse-badge 2s ease-in-out infinite;
  }
}

@keyframes pulse-badge {
  0%, 100% { opacity: 1; transform: scale(1); }
  50% { opacity: 0.9; transform: scale(1.05); }
}

.tab-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 14px;
}

.search-bar {
  display: flex;
  gap: 10px;
  margin-bottom: 14px;
  .search-input {
    flex: 1;
    padding: 12px 14px;
    background: $surface-2;
    border: 1px solid $border;
    border-radius: $radius-md;
    color: $text;
    font-size: 0.9em;
    transition: border-color 0.2s $ease-out, box-shadow 0.2s $ease-out;
    &::placeholder { color: $text-dim; }
    &:focus {
      outline: none;
      border-color: $border-focus;
      box-shadow: 0 0 0 3px $primary-glow;
    }
  }
  .filter-btn {
    padding: 12px 14px;
    background: $surface-2;
    border: 1px solid $border;
    border-radius: $radius-md;
    color: $text;
    cursor: pointer;
    font-size: 0.85em;
    transition: all 0.2s $ease-out;
    &:hover {
      background: $surface-3;
      border-color: rgba(255, 255, 255, 0.12);
      transform: scale(1.02);
    }
    &:active { transform: scale(0.98); }
  }
}

.filters-panel {
  padding: 16px;
  background: $surface-2;
  border: 1px solid $border;
  border-radius: $radius-md;
  margin-bottom: 14px;
  .filter-row {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
    label { width: 82px; font-size: 0.85em; color: $text-muted; }
    input {
      flex: 1;
      padding: 8px 12px;
      background: $surface-1;
      border: 1px solid $border;
      border-radius: $radius-sm;
      color: $text;
      transition: border-color 0.2s;
      &:focus { outline: none; border-color: $border-focus; }
    }
  }
  .apply-btn {
    width: 100%;
    padding: 12px;
    background: $primary;
    border: none;
    border-radius: $radius-sm;
    color: #0a0e12;
    font-weight: 700;
    cursor: pointer;
    margin-top: 4px;
    transition: all 0.2s $ease-out;
    &:hover {
      background: color.adjust($primary, $lightness: 6%);
      transform: translateY(-1px);
      box-shadow: 0 4px 12px $primary-glow;
    }
    &:active { transform: translateY(0); }
  }
}

.loading {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 48px;
  gap: 16px;
  color: $text-muted;
  .spinner {
    width: 36px;
    height: 36px;
    border: 3px solid $border;
    border-top-color: $primary;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
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
  padding: 48px 24px;
  text-align: center;
  .empty-icon {
    font-size: 3.5em;
    margin-bottom: 14px;
    opacity: 0.35;
    animation: float 3s ease-in-out infinite;
  }
  span { color: $text-muted; }
  .empty-sub { font-size: 0.85em; margin-top: 6px; color: $text-dim; }
}

@keyframes float {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-6px); }
}

.listings-grid {
  display: flex;
  flex-direction: column;
  gap: 14px;
}

// Sell Tab
.sell-header {
  margin-bottom: 20px;
  h3 { margin: 0 0 6px 0; color: $primary; font-weight: 700; }
  p { margin: 0; font-size: 0.85em; color: $text-muted; }
}

.sell-subtabs {
  display: flex;
  gap: 8px;
  margin-bottom: 16px;
}

.sell-subtab-btn {
  flex: 1;
  padding: 10px 14px;
  background: $surface-2;
  border: 1px solid $border;
  border-radius: $radius-md;
  color: $text-muted;
  cursor: pointer;
  font-size: 0.85em;
  font-weight: 500;
  transition: all 0.25s $ease-out;
  &:hover { color: $text; background: $surface-3; }
  &.active {
    color: $primary;
    border-color: rgba($primary, 0.4);
    background: $primary-dim;
  }
}

.inventory-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.inventory-card {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 14px;
  background: $surface-2;
  border: 1px solid $border;
  border-radius: $radius-md;
  cursor: pointer;
  transition: all 0.25s $ease-out;
  &:hover {
    border-color: rgba($primary, 0.4);
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.25);
    transform: translateY(-2px);
  }
  &:active { transform: translateY(0); }
  .inv-image {
    width: 64px;
    height: 64px;
    background: $surface-1;
    border-radius: $radius-sm;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    img { width: 100%; height: 100%; object-fit: cover; }
    span { font-size: 1.6em; opacity: 0.35; }
  }
  .inv-info {
    flex: 1;
    .inv-name { font-weight: 600; margin-bottom: 4px; }
    .inv-details { font-size: 0.8em; color: $text-muted; }
    .inv-value { font-size: 0.85em; color: $primary; margin-top: 6px; }
  }
  .sell-btn {
    padding: 10px 18px;
    background: $primary;
    border: none;
    border-radius: $radius-sm;
    color: #0a0e12;
    font-weight: 700;
    cursor: pointer;
    transition: all 0.2s $ease-out;
    &:hover {
      background: color.adjust($primary, $lightness: 6%);
      transform: scale(1.03);
      box-shadow: 0 4px 12px $primary-glow;
    }
    &:active { transform: scale(0.98); }
  }
}

.my-listings-section {
  margin-top: 28px;
  padding-top: 20px;
  border-top: 1px solid $border;
  h4 { margin: 0 0 14px 0; color: $text-muted; font-size: 0.9em; font-weight: 600; }
}

.my-listing-card {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 14px;
  background: $surface-2;
  border: 1px solid $border;
  border-radius: $radius-md;
  margin-bottom: 10px;
  transition: all 0.2s $ease-out;
  &:hover { border-color: rgba(255, 255, 255, 0.12); }
  .my-listing-info {
    flex: 1;
    .my-listing-title { display: block; font-weight: 600; font-size: 0.9em; }
    .my-listing-price { font-size: 0.85em; color: $primary; }
  }
  .my-listing-stats {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 4px;
    font-size: 0.75em;
    color: $text-muted;
    .status-available { color: $primary; }
    .status-sold { color: $danger; }
    .status-expired { color: $text-dim; }
  }
  .cancel-btn {
    padding: 8px 14px;
    background: rgba($danger, 0.15);
    border: 1px solid rgba($danger, 0.35);
    border-radius: $radius-sm;
    color: $danger;
    font-size: 0.8em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s $ease-out;
    &:hover { background: rgba($danger, 0.25); transform: scale(1.02); }
    &:active { transform: scale(0.98); }
  }
  .claim-btn {
    padding: 8px 14px;
    background: rgba($success, 0.2);
    border: 1px solid rgba($success, 0.4);
    border-radius: $radius-sm;
    color: $success;
    font-size: 0.8em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s $ease-out;
    &:hover:not(:disabled) { background: rgba($success, 0.3); transform: scale(1.02); }
    &:active { transform: scale(0.98); }
    &:disabled { opacity: 0.6; cursor: default; }
  }
}

// Messages Tab
.messages-subtabs {
  display: flex;
  gap: 8px;
  margin-bottom: 16px;
}

.messages-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.message-card {
  padding: 14px;
  background: $surface-2;
  border: 1px solid $border;
  border-radius: $radius-md;
  cursor: pointer;
  transition: all 0.25s $ease-out;
  &.unread {
    border-left: 4px solid $primary;
    background: $primary-dim;
  }
  &.sent {
    border-left-color: $text-dim;
  }
  &:hover {
    background: $surface-3;
    border-color: rgba(255, 255, 255, 0.1);
    transform: translateX(4px);
  }
  .msg-header {
    display: flex;
    justify-content: space-between;
    margin-bottom: 6px;
    .msg-sender { font-weight: 600; font-size: 0.9em; }
    .msg-time { font-size: 0.75em; color: $text-dim; }
  }
  .msg-preview { font-size: 0.85em; color: $text-muted; }
}

// Profile Tab
.profile-header {
  display: flex;
  align-items: center;
  gap: 18px;
  padding: 20px;
  background: $surface-2;
  border: 1px solid $border;
  border-radius: $radius-lg;
  margin-bottom: 20px;
  .profile-avatar {
    width: 64px;
    height: 64px;
    background: $primary-dim;
    border: 2px solid rgba($primary, 0.3);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 2.2em;
  }
  .profile-info h3 { margin: 0 0 6px 0; }
  .profile-id { font-size: 0.8em; color: $text-dim; font-family: monospace; }
}

.profile-name-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.name-required-overlay {
  pointer-events: auto;
}
.name-required-panel {
  .name-required-sub {
    margin: 0 0 20px 0;
    font-size: 0.9em;
    color: $text-muted;
    line-height: 1.4;
  }
  .name-required-btn { flex: none; width: 100%; }
}

.profile-stats {
  display: flex;
  gap: 12px;
  margin-bottom: 20px;
  .stat-card {
    flex: 1;
    padding: 16px;
    background: $surface-2;
    border: 1px solid $border;
    border-radius: $radius-md;
    text-align: center;
    transition: all 0.25s $ease-out;
    &:hover {
      border-color: rgba($primary, 0.25);
      transform: translateY(-2px);
      box-shadow: $shadow;
    }
    .stat-value { display: block; font-size: 1.4em; font-weight: 700; color: $primary; }
    .stat-label { font-size: 0.75em; color: $text-muted; margin-top: 4px; }
  }
}

.profile-actions {
  .action-btn {
    width: 100%;
    padding: 14px;
    background: $surface-2;
    border: 1px solid $border;
    border-radius: $radius-md;
    color: $text;
    cursor: pointer;
    font-weight: 500;
    transition: all 0.2s $ease-out;
    &:hover {
      background: $surface-3;
      border-color: rgba($primary, 0.3);
      color: $primary;
    }
    &:active { transform: scale(0.99); }
  }
}

// Modals
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.72);
  backdrop-filter: blur(8px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  padding: 24px;
}

.modal-panel {
  background: $surface-1;
  border: 1px solid $border;
  border-radius: $radius-xl;
  box-shadow: $shadow-lg;
  max-width: 420px;
  width: 100%;
  max-height: 85vh;
  overflow-y: auto;
  position: relative;
  color: $text;
}

.listing-modal.modal-panel {
  padding: 0;
}

.sell-modal.modal-panel {
  padding: 24px;
}

.modal-close {
  position: absolute;
  top: 14px;
  right: 14px;
  width: 36px;
  height: 36px;
  background: $surface-3;
  border: 1px solid $border;
  border-radius: 50%;
  color: $text;
  font-size: 1.15em;
  cursor: pointer;
  z-index: 2;
  transition: all 0.2s $ease-out;
  &:hover {
    background: $danger;
    border-color: $danger;
    color: #fff;
    transform: scale(1.08);
  }
  &:active { transform: scale(0.95); }
}

.modal-image-wrap { position: relative; }

.modal-image {
  position: relative;
  width: 100%;
  height: 220px;
  background: $surface-0;
  img { width: 100%; height: 100%; object-fit: cover; }
  .no-image {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 4em;
    opacity: 0.25;
  }
}

.modal-photo-arrow {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  width: 44px;
  height: 44px;
  border: none;
  border-radius: 50%;
  background: rgba(0, 0, 0, 0.55);
  color: #fff;
  font-size: 1.6rem;
  line-height: 1;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  z-index: 2;
  transition: all 0.25s $ease-out;
  &:hover {
    background: $primary;
    color: #0a0e12;
    transform: translateY(-50%) scale(1.1);
  }
  &:active { transform: translateY(-50%) scale(0.95); }
}

.modal-photo-prev { left: 10px; }
.modal-photo-next { right: 10px; }

.modal-photo-counter {
  position: absolute;
  bottom: 10px;
  left: 50%;
  transform: translateX(-50%);
  padding: 6px 12px;
  border-radius: $radius-sm;
  background: rgba(0, 0, 0, 0.6);
  font-size: 0.8rem;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.95);
  z-index: 2;
}

.modal-content {
  padding: 22px;
  color: $text;
  h2 { margin: 0 0 10px 0; font-size: 1.35em; color: $text; }
  .modal-price {
    font-size: 1.6em;
    font-weight: 700;
    color: $primary;
    margin-bottom: 18px;
  }
  .modal-details {
    margin-bottom: 18px;
    .detail-row {
      display: flex;
      justify-content: space-between;
      padding: 10px 0;
      border-bottom: 1px solid $border;
      font-size: 0.9em;
      color: $text;
      span:first-child { color: $text-muted; }
      span:last-child { color: $text; }
    }
  }
  .modal-description {
    font-size: 0.9em;
    color: $text-muted;
    line-height: 1.55;
    margin-bottom: 22px;
  }
  .modal-actions {
    display: flex;
    gap: 12px;
    button {
      flex: 1;
      padding: 14px;
      border: none;
      border-radius: $radius-md;
      font-weight: 700;
      cursor: pointer;
      transition: all 0.2s $ease-out;
      &.contact-btn {
        background: $surface-3;
        border: 1px solid $border;
        color: $text;
        &:hover {
          border-color: $primary;
          color: $primary;
          transform: translateY(-1px);
        }
      }
      &.buy-btn {
        background: $primary;
        color: #0a0e12;
        &:hover:not(:disabled) {
          background: color.adjust($primary, $lightness: 6%);
          transform: translateY(-2px);
          box-shadow: 0 6px 20px $primary-glow;
        }
        &:disabled { opacity: 0.5; cursor: not-allowed; }
      }
      &:active { transform: translateY(0); }
    }
  }
}

.sell-modal {
  padding: 24px;
  color: $text;
  h2 { margin: 0 0 18px 0; padding-right: 44px; font-weight: 700; color: $text; }
}

.sell-vehicle-preview {
  padding: 16px;
  background: $surface-2;
  border: 1px solid $border;
  border-radius: $radius-md;
  margin-bottom: 18px;
  .vehicle-name { display: block; font-weight: 600; margin-bottom: 6px; color: $text; }
  .vehicle-est { font-size: 0.85em; color: $primary; }
}

.listing-photo-row {
  margin-bottom: 18px;
  label { display: block; font-size: 0.85em; color: $text-muted; margin-bottom: 10px; font-weight: 500; }
}

.listing-photo-slots {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
}

.listing-photo-slot {
  width: 100%;
  aspect-ratio: 1;
  border-radius: $radius-md;
  border: 2px dashed $border;
  background: $surface-2;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  overflow: hidden;
  transition: all 0.25s $ease-out;
  &:hover {
    border-color: $primary;
    background: $primary-dim;
    transform: scale(1.02);
  }
  &:active { transform: scale(0.98); }
  &.filled {
    border-style: solid;
    border-color: rgba($primary, 0.4);
  }
  .listing-photo-plus { font-size: 2.2rem; color: $text-muted; line-height: 1; }
  .listing-photo-preview { width: 100%; height: 100%; object-fit: cover; display: block; }
}

.listing-photo-hint {
  display: block;
  font-size: 0.8em;
  color: $text-dim;
  margin-top: 8px;
}

.photo-picker-modal {
  padding: 24px;
  max-width: 340px;
  max-height: 82vh;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  h3 { margin: 0 0 6px 0; padding-right: 40px; font-weight: 700; }
}

.photo-picker-sub {
  font-size: 0.85em;
  color: $text-muted;
  margin: 0 0 18px 0;
}

.photo-picker-loading,
.photo-picker-empty {
  padding: 28px;
  text-align: center;
  color: $text-muted;
  font-size: 0.9em;
}

.photo-picker-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px;
  overflow-y: auto;
  flex: 1;
  min-height: 0;
}

.photo-picker-thumb {
  aspect-ratio: 1;
  border-radius: $radius-md;
  overflow: hidden;
  border: 2px solid transparent;
  background: $surface-2;
  padding: 0;
  cursor: pointer;
  transition: all 0.25s $ease-out;
  &:hover {
    border-color: $primary;
    transform: scale(1.05);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  }
  &:active { transform: scale(0.98); }
  img { width: 100%; height: 100%; object-fit: cover; display: block; }
}

.sell-form {
  .form-group {
    margin-bottom: 18px;
    label { display: block; font-size: 0.85em; color: $text-muted; margin-bottom: 8px; font-weight: 500; }
    input,
    textarea {
      width: 100%;
      padding: 12px 14px;
      background: $surface-2;
      border: 1px solid $border;
      border-radius: $radius-md;
      color: $text;
      font-size: 0.95em;
      transition: border-color 0.2s $ease-out, box-shadow 0.2s $ease-out;
      &:focus {
        outline: none;
        border-color: $border-focus;
        box-shadow: 0 0 0 3px $primary-glow;
      }
    }
    textarea { resize: vertical; min-height: 88px; }
  }
  .sell-actions {
    display: flex;
    gap: 12px;
    margin-top: 22px;
    button {
      flex: 1;
      padding: 14px;
      border: none;
      border-radius: $radius-md;
      font-weight: 700;
      cursor: pointer;
      transition: all 0.2s $ease-out;
      &.cancel-btn {
        background: $surface-3;
        border: 1px solid $border;
        color: $text;
        &:hover {
          border-color: $text-dim;
          background: rgba(255, 255, 255, 0.06);
        }
      }
      &.list-btn {
        background: $primary;
        color: #0a0e12;
        &:hover:not(:disabled) {
          background: color.adjust($primary, $lightness: 6%);
          transform: translateY(-2px);
          box-shadow: 0 6px 16px $primary-glow;
        }
        &:disabled { opacity: 0.5; cursor: not-allowed; }
      }
      &:active { transform: translateY(0); }
    }
  }
}
</style>

