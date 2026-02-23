# Real Estate Negotiation UI - Implementation Summary

## Completed Work

### 1. Lua Function Signatures Registration

**File:** `ui-vue-src/bridge/LuaFunctionSignatures.js`

Added to `career_modules_garageManager`:
- `requestGarageListing: garageId => String`
- `startGarageNegotiation: garageId => String`
- `purchaseGarageAtListedPrice: garageId => String`
- `completePurchaseWithNegotiatedPrice: (garageId, finalPrice) => [String, Number]`

Added new section `career_modules_realEstateNegotiation`:
- `startNegotiateBuying: garageId => String`
- `makeOffer: price => Number`
- `takeTheirOffer: () => {}`
- `cancelNegotiation: () => {}`
- `getNegotiationState: () => {}`

### 2. Garage Listing View Component

**File:** `ui-vue-src/modules/career/views/GarageListing.vue`

**Features:**
- Property preview image display
- Property name and listed price (formatted with commas)
- Property details grid showing:
  - Capacity (number of vehicles)
  - Parking spots
  - Neighborhood
- Action buttons:
  - "Purchase at Listed Price" (green, primary accent)
  - "Negotiate" (yellow/orange, attention accent)
  - "Cancel" (secondary accent)
- Buttons disabled appropriately:
  - Purchase disabled if player can't afford
  - Both disabled for starter garages
- Info note for starter garages
- Listens for `openGarageListing` event from backend

**Styling:**
- Dark theme matching existing UI
- Card-based layout with overlay
- Responsive grid for property details
- Proper color coding for prices and actions

### 3. Real Estate Negotiation View Component

**File:** `ui-vue-src/modules/career/views/RealEstateNegotiation.vue`

**Features:**

**Property Info Header:**
- Property thumbnail preview
- Property name
- Original listed price

**Negotiation State Display:**
- Seller name and personality-based quote
- Offer comparison grid:
  - Their current offer (orange)
  - Your current offer (green, or "Not set")
- Visual patience meter with color gradient:
  - Green (>60% patience)
  - Orange (30-60% patience)
  - Red (<30% patience)

**Status Messages:**
- "Seller is considering your offer..." (thinking)
- "Seller is typing..." (typing)
- "⚠️ Final offer! Seller is losing patience." (counterOfferLastChance)
- "Negotiation failed. The seller has walked away." (failed)

**Offer Input System:**
- Number input field for player's offer
- "Make Offer" button
- Real-time validation:
  - Cannot offer more than their current offer
  - Cannot go backwards (increase from previous offer)
- Helpful hint messages for invalid offers

**Action Buttons:**
- "Accept Their Offer" (shown during counter-offers)
- "Walk Away" / "Cancel Negotiation"
- "Close" (after success or failure)

**Success Screen (status = "accepted"):**
- Large success icon (✓)
- "Deal Accepted!" title
- Savings calculation with amount and percentage
- Contextual feedback:
  - ≥8% savings: "🎉 Excellent negotiation!"
  - 5-7% savings: "👍 Good deal!"
  - 2-4% savings: "Fair price."
  - <2% savings: "You paid close to asking price."

**Data Binding:**
- Listens for `realEstateNegotiationData` event
- Requests initial state on mount
- Reactive updates for all negotiation state changes

### 4. Route Configuration

**File:** `ui-vue-src/modules/career/routes.js`

Added routes:
- `/career/garage-listing` → GarageListing component
- `/career/realEstateNegotiation` → RealEstateNegotiation component

## UI Flow

1. **Player approaches unowned garage** → Backend triggers `openGarageListing` event
2. **GarageListing view opens** → Shows property details with Purchase/Negotiate options
3. **Player clicks "Negotiate"** → Calls `startGarageNegotiation()` → Backend triggers state change
4. **RealEstateNegotiation view opens** → Shows negotiation interface
5. **Negotiation loop:**
   - Player makes offer → Status changes to "thinking" → "typing" → "counterOffer"
   - Patience meter decreases with each round
   - Player can accept counter-offer or make new offer
6. **Success:** Shows savings summary, purchase completes automatically
7. **Failure:** Shows failure message, returns to career menu

## Styling Approach

- Follows existing BeamNG.drive career mod UI patterns
- Dark theme with transparency overlays
- Card-based layouts with BngCard component
- Color coding:
  - Green for success/good deals
  - Orange/yellow for warnings/negotiations
  - Red for failures/low patience
  - Blue for seller information
- Responsive design with flex/grid layouts
- Smooth transitions for patience meter and status changes

## Integration Points

**Guihooks Events:**
- `openGarageListing` → Triggers listing view
- `realEstateNegotiationData` → Updates negotiation state
- `ChangeState` → Navigation between views

**Lua Function Calls:**
- `career_modules_garageManager.purchaseGarageAtListedPrice()`
- `career_modules_garageManager.startGarageNegotiation()`
- `career_modules_realEstateNegotiation.makeOffer(price)`
- `career_modules_realEstateNegotiation.takeTheirOffer()`
- `career_modules_realEstateNegotiation.cancelNegotiation()`
- `career_modules_realEstateNegotiation.getNegotiationState()`

## Testing Checklist

Once the UI is compiled and tested in-game:

- [ ] Approach unowned garage → Listing view appears
- [ ] Property details display correctly (name, price, capacity, parking spots)
- [ ] "Purchase" button works for instant purchase
- [ ] "Negotiate" button enters negotiation view
- [ ] Starter garages show disabled buttons with info note
- [ ] Seller name and quote display correctly
- [ ] Patience meter updates and changes color
- [ ] Offer input validation works (can't go backwards, can't exceed their offer)
- [ ] "thinking" and "typing" status messages appear with delays
- [ ] Counter-offers display correctly
- [ ] "Last chance" warning appears when patience is low
- [ ] Success screen shows correct savings calculation
- [ ] Feedback messages match savings percentage
- [ ] "Walk Away" cancels negotiation
- [ ] Failed negotiation shows appropriate message
- [ ] Purchase completes automatically on success

## Notes

- All components follow Vue 3 Composition API patterns (setup script)
- Uses existing BngButton, BngCard, and LayoutSingle components
- Compatible with existing bridge/lua integration system
- Responsive and accessible design
- Clean separation between listing and negotiation views
- Proper cleanup with onUnmounted event listeners

## Commit History

1. `- registered real estate negotiation Lua functions in LuaFunctionSignatures.js`
   - Added all necessary function signatures for garage manager and negotiation module

All implementation files are ready for compilation and in-game testing.
