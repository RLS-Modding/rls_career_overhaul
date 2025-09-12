<template>
  <div style="height: 100%;">
    <BngCard style="max-height: 100%;" class="marketplace-card" v-bng-blur>
      <template v-if="listings.length && !helpPopup">
        <div class="header">
          <h2>Vehicles Listed</h2>
          <div class="header-right">
            <BngSwitch v-model="notifications"> Notifications </BngSwitch>
            <button class="help-button" @click="toggleHelp">?</button>
          </div>
        </div>
        <hr class="custom-hr">
        
        <div class="vehicle-listings-container">
          <div v-for="listing in listings" :key="listing.id" class="vehicle-listing">
            <div class="vehicle-card" :class="{ active: showOffers === listing.id }">
              <img :src="listing.thumbnail ? listing.thumbnail : defaultImage" alt="" class="vehicle-image">
              <div class="vehicle-info">
                <div class="vehicle-header">
                  <div>
                    <div class="year">{{ listing.vehicleData?.year || 'N/A' }}</div>
                    <div class="model">{{ listing.niceName }}</div>
                    <div class="mileage">{{ formatMileage(listing.vehicleData?.mileage || 0) }}</div>
                  </div>
                  <div class="header-buttons">
                    <button class="remove-listing-btn" @click="confirmRemoveListingScreen(listing.inventoryId)" title="Remove Listing">
                      <BngIcon :type="icons.xmark" />
                    </button>
                    <button class="messages-badge" @click="toggleOffers(listing.inventoryId)">
                      <BngIcon :type="icons.dialogOutline" />
                      <span class="badge" v-if="listing.offers.length">{{ listing.offers.length }}</span>
                    </button>
                  </div>
                </div>
                <div class="vehicle-specs">
                  <div class="specs">
                    <div>{{ listing.vehicleData?.power || 0 }} PS</div>
                    <div>{{ listing.vehicleData?.torque || 0 }} NM</div>
                    <div>{{ listing.vehicleData?.weight || 0 }} KG</div>
                    <div>{{ listing.vehicleData?.powerPerWeight || 0 }} PS/KG</div>
                  </div>
                  <div>
                    <button class="event-times" :class="{ active: showEventTimes === listing.inventoryId }"
                        @click="toggleEventTimes(listing.inventoryId)">
                        Free-roam event times
                        <BngIcon
                            :type="showEventTimes === listing.inventoryId ? icons.arrowLargeUp : icons.arrowLargeDown" />
                    </button>
                    <div class="price-info">
                      <div class="repIncrease">
                        <BngIcon :type="icons.arrowsUp" :color="'#4caf50'" />
                        {{ listing.vehicleData?.rep || 0 }}%
                      </div>
                      <div class="price">
                        <BngUnit :money="listing.value" :icon-color="'#4caf50'" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div v-if="showEventTimes === listing.inventoryId" class="event-times-dropdown">
              <template v-if="listing.vehicleData?.FRETimes && Object.keys(listing.vehicleData.FRETimes).length">
                <div v-for="(time, name) in listing.vehicleData.FRETimes" :key="name" class="time-entry">
                  <span>{{ name }}:</span>
                  <span>{{ formatTime(time) }}</span>
                </div>
              </template>
              <div v-else class="no-times-message">
                No stored times
              </div>
            </div>

            <div v-if="showOffers === listing.inventoryId" class="offers-container">
              <template v-if="listing.offers.length">
                <div v-for="(offer, index) in listing.offers" :key="index" class="offer-row" 
                     :style="{ opacity: offer.expiredViewCounter ? '0.5' : '1' }"
                     @mouseover="onOfferHovered(offer)" 
                     @mouseleave="onOfferUnhovered(offer)" 
                     @activate="onActivated(offer)" 
                     @deactivate="onDeactivated(offer)">
                  <span class="dealer-name">{{ offer.customer || 'Anonymous Buyer' }}</span>
                  <div class="offer-actions">
                    <div class="offer-amount">
                      <BngUnit :money="offer.value" />
                      <span :style="{
                        color: offer.value > listing.value ? 'var(--bng-add-green-400)' : 'var(--bng-add-red-400)',
                        '--bng-icon-color': offer.value > listing.value ? 'var(--bng-add-green-400)' : 'var(--bng-add-red-400)',
                        marginLeft: '8px'
                      }">
                        ( {{ offer.value > listing.value ? '+' : '-' }}<BngUnit :money="Math.abs(offer.value - listing.value)" />)
                        <span v-if="offer.expiredViewCounter" style="color: var(--bng-add-red-400); margin-left: 8px;">
                          EXPIRED
                        </span>
                      </span>
                    </div>
                    <div class="action-buttons" :style="{visibility: offer.hovered || offer.active ? 'visible' : 'hidden'}">
                      <BngButton
                        v-if="!offer.expiredViewCounter"
                        class="accept-btn"
                        @click="acceptOffer(listing.inventoryId, index)"
                        :disabled="listing.disabled || offer.disabled || listing.vehicleData?.needsRepair"
                        :icon="icons.checkmark"
                        :accent="ACCENTS.main"
                      />
                      <BngButton
                        class="decline-btn"
                        @click="declineOffer(listing.inventoryId, index)"
                        :icon="icons.xmark"
                        :accent="ACCENTS.attention"
                      />
                    </div>
                  </div>
                </div>
              </template>
              <div v-else class="no-times-message">
                No active offers
              </div>
            </div>
          </div>
        </div>
      </template>

      <div v-else-if="helpPopup" class="help-screen">
        <h1>Marketplace Overview</h1>
        <p>
          Your vehicle's appeal in the marketplace is determined by a range of criteria.
          The more activities and customizations you complete, the higher the interest
          from potential customers—and higher offers you'll receive (although offers come
          in offline and at a longer interval).
        </p>
        <p>
          To get started, list your vehicle for sale by going into your vehicle inventory and selecting
          "List for Sale".
        </p>
        <p>
          Note: If you make changes to your vehicle after listing, you may lose current offers.
        </p>

        <h2>Vehicle Performance & Event Stats</h2>
        <ul>
          <li>
            <strong>Performance Values:</strong>
            These values represent your vehicle's performance in free roam events.
            The better you perform, the higher this score will be.
          </li>
          <li>
            <strong>Completions:</strong>
            Tracks how many free roam events you have participated in and your streak of consecutive
            completions. Consistency here boosts your vehicle's appeal.
          </li>
          <li>
            <strong>Arrests, Tickets, & Evades:</strong>
            <ul>
              <li><em>Arrests:</em> Number of times you've been caught by the police.</li>
              <li><em>Tickets:</em> Times you've received fines.</li>
              <li><em>Evades:</em> How often you've successfully evaded the police.</li>
            </ul>
          </li>
          <li>
            <strong>Accidents:</strong>
            Counts the number of repairs made via insurance. Fewer accidents might indicate a more
            reliable vehicle.
          </li>
        </ul>

        <h2>Customization & Upgrades</h2>
        <ul>
          <li>
            <strong>Number of Added Parts:</strong>
            How many upgrades or new parts have been added to your vehicle.
            More upgrades often lead to higher performance and appeal.
          </li>
          <li>
            <strong>Number of Removed Parts:</strong>
            Indicates modifications or removals from the original setup, which can reflect a vehicle's
            customization journey.
          </li>
        </ul>

        <h2>Increasing Marketplace Interest</h2>
        <ul>
          <li>
            <strong>Multi-Faceted Appeal:</strong>
            Each of the criteria (performance, event stats, and customizations) plays a role in
            attracting customers.
          </li>
          <li>
            <strong>Specialization:</strong>
            If you focus on excelling in specific areas (like evading the police or delivering items),
            you might attract high-paying customers interested in that niche.
          </li>
          <li>
            <strong>Offer Timing:</strong>
            Offers are generated while you play the game and the interval depends on your interest.
            More interest means you'll receive these offers more quickly.
          </li>
        </ul>
      </div>

      <div v-else class="no-vehicles-message">
        <p>No Vehicles Listed</p>
        <p>List your vehicles for sale through the vehicle inventory to start receiving offers.</p>
      </div>

      <BngButton
        class="add-listing-button"
        @click="listVehicle"
        :accent="ACCENTS.custom"
      >
        <span class="add-listing-button-icon">+</span> Add Listing
      </BngButton>
    </BngCard>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick, watch } from "vue"
import { lua } from "@/bridge"
import { Accordion, AccordionItem } from "@/common/components/utility"
import { BngCard, BngUnit, BngPropVal, BngButton, BngIcon, ACCENTS, icons, BngInput, BngSwitch } from "@/common/components/base"
import { vBngBlur, vBngScopedNav } from "@/common/directives"
import { useComputerStore } from "../../stores/computerStore"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"

const computerStore = useComputerStore()

const listings = ref([])
const notifications = ref(true)
const helpPopup = ref(false)
const showEventTimes = ref(null)
const showOffers = ref(null)
const defaultImage = ref("/settings/cloud/saves/Profile 17/autosave3/career/vehicles/5.png")

const toggleHelp = () => {
  helpPopup.value = !helpPopup.value
}

const toggleEventTimes = (listingId) => {
  showEventTimes.value = showEventTimes.value === listingId ? null : listingId
}

const toggleOffers = (listingId) => {
  showOffers.value = showOffers.value === listingId ? null : listingId
}

const formatMileage = (mileage) => {
  if (!mileage) return '0 mi'
  return `${mileage.toFixed(0)} mi`
}

const formatTime = (seconds) => {
  const mins = Math.floor(seconds / 60)
  const secs = (seconds % 60).toFixed(2).padStart(5, '0')
  return `${mins}:${secs}`
}

const confirmRemoveListingScreen = async listingId => {
  const res = await openConfirmation("", "Do you want to remove this listing?", [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])

  if (res) {
    removeVehicleListing(listingId)
  }
}

const onActivated = (offer) => { offer.active = true }

const onDeactivated = (offer) => { offer.active = false }

const onOfferHovered = (offer) => { offer.hovered = true }

const onOfferUnhovered = (offer) => { offer.hovered = false }

const handleListings = (data) => { 
  listings.value = data
  // console.log('Received listings:', data) // Commented out to prevent log spam
}

const getNewData = () => {
  lua.career_modules_marketplace.getListings().then(handleListings)
}

const acceptOffer = async (inventoryId, offerIndex) => {
  const listing = listings.value.find(l => l.inventoryId === inventoryId)
  const offer = listing.offers[offerIndex]
  
  const res = await openConfirmation("", 
    `Do you want to accept this offer for $${offer.value.toFixed(2)} from ${offer.customer || 'Anonymous Buyer'}?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])

  if (res) {
    lua.career_modules_marketplace.acceptOffer(inventoryId, offerIndex + 1).then(getNewData)
  }
}

const declineOffer = async (inventoryId, offerIndex) => {
  const listing = listings.value.find(l => l.inventoryId === inventoryId)
  const offer = listing.offers[offerIndex]
  
  const res = await openConfirmation("", 
    `Do you want to decline this offer for $${offer.value.toFixed(2)} from ${offer.customer || 'Anonymous Buyer'}?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])

  if (res) {
    lua.career_modules_marketplace.declineOffer(inventoryId, offerIndex + 1).then(getNewData)
  }
}

const removeVehicleListing = (inventoryId) => {
  lua.career_modules_marketplace.removeVehicleListing(inventoryId).then(getNewData)
}

const listVehicle = () => {
  lua.career_modules_inventory.openMenuFromComputer(computerStore.computerData.computerId)
}

watch(notifications, (newValue) => {
  lua.career_modules_marketplace.toggleNotifications(newValue)
})

const start = () => {
  getNewData()
  lua.career_modules_marketplace.menuOpened(true)
}

const stop = () => {
  lua.career_modules_marketplace.menuOpened(false)
}

onMounted(start)
onUnmounted(stop)

</script>

<style scoped lang="scss">
.marketplace-card {
  color: white;
  width: 100%;
  height: 100%;
  background-color: rgba(var(--bng-cool-gray-900-rgb), 0.5);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 20px 20px 0 20px;

  h2 {
    font-size: 24px;
    margin: 0;
  }
}

.header-right {
  display: flex;
  align-items: center;
  gap: 10px;
}

.help-button {
  background-color: rgb(67, 70, 80);
  width: 30px;
  height: 30px;
  color: white;
  border-radius: 20px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 18px;
  font-weight: 700;
  border: none;
  cursor: pointer;
  font-family: "Overpass", sans-serif;
}

.custom-hr {
  border: 0;
  height: 2px;
  background: #4B4B4B;
  margin: 10px 20px;
}

.vehicle-listings-container {
  flex: 1;
  overflow-y: auto;
  padding: 0 20px;
}

.vehicle-listing {
  position: relative;
  margin-bottom: 20px;
}

.vehicle-card {
  background-color: #293037;
  border-radius: 15px;
  overflow: hidden;
  display: flex;
  border: none;
  margin-bottom: 0;
  position: relative;
}

.vehicle-image {
  margin: 10px;
  width: 300px;
  height: 174px;
  border-radius: 15px;
  background-color: #3b3b3b;
  object-fit: cover;
}

.vehicle-info {
  padding: 10px;
  flex-grow: 1;
  display: grid;
  grid-template-rows: repeat(2, auto);
}

.vehicle-header {
  display: flex;
  justify-content: space-between;
  margin-bottom: 0px;
}

.vehicle-specs {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 100px;
}

.year {
  font-size: 12px;
  color: #888;
}

.model {
  font-size: 24px;
  font-weight: bold;
}

.mileage {
  color: #888;
  font-size: 12px;
}

.header-buttons {
  display: flex;
  align-items: center;
  gap: 10px;
}

.remove-listing-btn {
  background-color: transparent;
  border: none;
  cursor: pointer;
  font-size: 26px;
  color: white;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-top: -32px;
  transition: color 0.2s ease;
  
  &:hover {
    color: #ff4444;
  }
}

.messages-badge {
  position: relative;
  font-size: 26px;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  margin-top: -32px;
  background-color: transparent;
  border: none;
  color: white;
  font-family: "Overpass", sans-serif;
  cursor: pointer;

  .badge {
    background-color: #ff4444;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    width: 15px;
    height: 15px;
    font-size: 12px;
    margin-left: -15px;
    margin-top: -15px;
    font-weight: 650;
  }
}

.specs {
  display: grid;
  grid-template-rows: repeat(4, auto);
  gap: 5px;
  margin-bottom: 0px;
}

.event-times {
  background-color: #3D3D3D;
  font-size: 14px;
  font-weight: 650;
  color: white;
  padding: 4px 12px 4px 16px;
  border: none;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-right: 12px;
  border-radius: 10px;
  width: 230px;

  &.active {
    border-bottom-left-radius: 0;
    border-bottom-right-radius: 0;
  }
}

.price-info {
  text-align: right;
}

.repIncrease {
  color: #4caf50;
  font-size: 16px;
  display: flex;
  align-items: center;
  justify-content: flex-end;
  margin-top: 25px;
  margin-bottom: -5px;
}

.price {
  font-size: 24px;
  font-weight: bold;
  color: #4caf50;
  display: flex;
  align-items: center;
  justify-content: flex-end;
}

.event-times-dropdown {
  position: absolute;
  max-height: 150px;
  overflow-y: auto;
  top: 100px;
  right: 22px;
  z-index: 100;
  background-color: #3D3D3D;
  padding: 10px;
  width: 230px;
  border-radius: 0 0 10px 10px;
}

.time-entry {
  display: flex;
  justify-content: space-between;
  padding: 5px 0;

  span:first-child {
    color: #888;
  }

  span:last-child {
    font-weight: 600;
  }
}

.offers-container {
  background-color: #1A1818;
  border-radius: 0 0 15px 15px;
  margin-top: -10px;
  padding: 5px;
  position: relative;
  z-index: 1;
}

.offer-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px 16px;
  background-color: #2B2C28;
  margin: 10px;
  border-radius: 8px;
}

.dealer-name {
  font-weight: 500;
  color: white;
  flex: 0 0 200px;
}

.offer-actions {
  display: flex;
  align-items: center;
  gap: 20px;
  flex: 1;
  justify-content: space-between;
}

.offer-amount {
  color: white;
  display: flex;
  align-items: center;
  flex: 1;
}

.action-buttons {
  display: flex;
  gap: 10px;
  visibility: hidden;
}

.accept-btn,
.decline-btn {
  flex: 0 0 auto;
}

.accept-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.help-screen {
  padding: 20px;
  font-family: Arial, sans-serif;
  line-height: 1.6;
  overflow-y: auto;
  flex: 1;
}

.help-screen h1,
.help-screen h2 {
  color: #fff;
  margin-bottom: 10px;
}

.help-screen ul {
  margin: 10px 0 20px 20px;
}

.help-screen li {
  margin-bottom: 8px;
}

.help-screen strong {
  color: #ccc;
}

.no-vehicles-message {
  text-align: center;
  color: #888;
  padding: 40px 20px;
  font-size: 1.2em;
  flex: 1;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  
  p:first-child {
    font-size: 1.5em;
    margin-bottom: 10px;
  }
}

.no-times-message {
  text-align: center;
  color: #888;
  padding: 20px;
  font-style: italic;
}

.add-listing-button {
  display: flex;
  max-width: none !important;
  padding: 0.5em;
  font-size: 1.5em;
  line-height: 1.5em;
  color: var(--bng-off-white);
  align-items: center !important;
  justify-content: center;
  margin: 20px;
  margin-bottom: 10px;

  --bng-button-custom-enabled: var(--bng-cool-gray-750);
  --bng-button-custom-hover: var(--bng-cool-gray-700);
  --bng-button-custom-active: var(--bng-cool-gray-900);
  --bng-button-custom-disabled: var(--bng-cool-gray-700);
  --bng-button-custom-enabled-opacity: 0.2;
  --bng-button-custom-hover-opacity: 0.5;
  --bng-button-custom-active-opacity: 1;
  --bng-button-custom-disabled-opacity: 0.2;

  border: 0.125rem dashed rgba(var(--bng-off-white-rgb), 0.25);

  .add-listing-button-icon {
    font-size: 1.5em;
    margin-right: 0.25em;
    font-weight: 700;
  }
}
</style>