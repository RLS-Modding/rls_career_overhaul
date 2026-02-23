# Real Estate Negotiation UI Integration TODO

## Completed Backend Work

✅ **Core negotiation module** (`realEstateNegotiation.lua`)
- Negotiation state machine (idle → active → counter-offer → accepted/rejected)
- Seller personality system
- Patience meter with decay
- Counter-offer logic with STRICT discount caps (max 10%, good 5%, average 2.5%)
- Integration with garageManager for applying negotiated prices

✅ **Seller personality data** (`realEstatePersonalities.json`)
- 6 seller archetypes (private motivated/firm, bank foreclosure, estate sale, property management, investor flipper)
- 6 buyer archetypes for Phase 2 (future work)

✅ **Backend integration**
- `garageManager.lua` updated with new functions:
  - `completePurchaseWithNegotiatedPrice()` - called by negotiation module when deal closes
  - `requestGarageListing()` - provides data for listing view
  - `startGarageNegotiation()` - triggers negotiation flow
  - `purchaseGarageAtListedPrice()` - buy without negotiating
- `realEstate.lua` (phone app) updated with `canNegotiate` flag

---

## UI Work Needed

The UI for this mod is built with Vue and compiled into `ui/ui-vue/dist/`. The source files are not in this repository. Based on the spec, here's what needs to be implemented:

### 1. Garage Listing View

**Replace current "purchase-garage" state with "garage-listing" state:**

Current flow:
```
Player approaches garage → Opens computer → "Purchase" button → Payment screen
```

New flow:
```
Player approaches garage → Opens computer → LISTING VIEW with:
  - Property preview image
  - Name, location, price
  - Property details (capacity, parking spots, neighborhood)
  - TWO buttons: "Purchase" (full price) and "Negotiate"
```

**UI Components Needed:**
- New state/route: `garage-listing`
- Vue component showing:
  - Property card with hero image (from `garage.preview` or `computer.preview`)
  - Translated property name
  - Listed price (formatted with commas: "$573,000")
  - Property stats grid:
    - Capacity: X vehicles
    - Parking spots: X
    - Neighborhood: (from propertyMarket when available)
  - Action buttons:
    - "Purchase" button (green, calls `career_modules_garageManager.purchaseGarageAtListedPrice(garageId)`)
    - "Negotiate" button (yellow/orange, calls `career_modules_garageManager.startGarageNegotiation(garageId)`)
    - Button disabled if starter garage (free garages can't be negotiated)

**Data binding:**
- Listen for `openGarageListing` event from backend
- Receives object with: `{ garageId, name, preview, listedPrice, capacity, parkingSpots, neighborhood, canNegotiate, starterGarage }`

---

### 2. Negotiation View

**Reuse existing vehicle marketplace negotiation UI** (from marketplace.lua)

The negotiation UI already exists for vehicle negotiations. Need to:
1. Create new state: `realEstateNegotiation` 
2. Bind to `realEstateNegotiationData` event instead of `negotiationData`
3. Adapt data model (property info instead of vehicle info)

**UI Elements:**
- Property info header:
  - Property name
  - Preview thumbnail
  - Listed price (original asking)
- Negotiation state:
  - **Their current offer:** $573,000
  - **Your current offer:** $540,000 (or "Not set")
  - **Seller name:** John S.
  - **Seller quote:** "Let's see if we can work something out."
  - **Patience meter:** Visual bar (green → yellow → red)
  - **Status:** initial | thinking | typing | counterOffer | counterOfferLastChance | accepted | refused | failed
- Offer input:
  - Number input field (dollar amount)
  - "Make Offer" button (calls `career_modules_realEstateNegotiation.makeOffer(amount)`)
  - Validation: Offer must be between their offer and your last offer (can't go backwards)
- Action buttons:
  - "Accept Their Offer" (calls `career_modules_realEstateNegotiation.takeTheirOffer()`)
  - "Cancel Negotiation" (calls `career_modules_realEstateNegotiation.cancelNegotiation()`)

**Data binding:**
- Listen for `realEstateNegotiationData` event
- Receives object with negotiation state (see `getNegotiationState()` in realEstateNegotiation.lua)

**UI State Transitions:**
1. "initial" → Seller's opening quote, waiting for player's first offer
2. "thinking" → Player made offer, seller is processing (2–5 second delay)
3. "typing" → Seller is "typing" response (visual feedback)
4. "counterOffer" → Seller responds with counter-offer
5. "counterOfferLastChance" → Patience ≤ 0.05, seller gives final offer
6. "accepted" → Seller accepts (deal closed, shows savings summary)
7. "refused" → Seller refuses to counter
8. "failed" → Patience = 0, seller walks away

**Success Screen:**
When negotiation succeeds (status = "accepted"):
- Show deal summary: "Deal accepted! You saved $X (Y% off listed price)"
- Feedback based on savings:
  - ≥8%: "🎉 Excellent negotiation!"
  - 5–7%: "👍 Good deal!"
  - 2–4%: "Fair price."
  - <2%: "You paid close to asking price."
- Purchase completes automatically at negotiated price
- Return to garage list or career menu

---

### 3. Integration with Existing UI

**Modify `showPurchaseGaragePrompt()` trigger:**

The backend already calls `guihooks.trigger('openGarageListing', data)` when approaching a purchasable garage. The UI needs to:
1. Listen for this event
2. Show the listing view instead of going straight to purchase
3. Allow player to choose "Purchase" or "Negotiate"

**Current UI state:** `purchase-garage`
**New UI state:** `garage-listing` (listing view) → `realEstateNegotiation` (if player clicks Negotiate)

---

## Testing Checklist

Once UI is implemented:

- [ ] Approach unowned garage → See listing view with preview, details, and two buttons
- [ ] Click "Purchase" → Buy at full price (existing flow works)
- [ ] Click "Negotiate" → Enter negotiation view
- [ ] Make low offer → See seller reject or counter
- [ ] Make reasonable offer → See counter-offers with patience decreasing
- [ ] Make acceptable offer → See "accepted" message with savings summary
- [ ] Let patience run out → See "failed" message, return to listing view
- [ ] Complete negotiation → Property purchased at negotiated price
- [ ] Check that free/starter garages don't show "Negotiate" button
- [ ] Verify patience meter updates visually
- [ ] Verify seller personality affects behavior (some tough, some flexible)
- [ ] Check that discount caps work (max 10% off, most deals 2.5–5% off)

---

## Phase 2 (Future Work)

**Selling-side negotiation** is specced but not implemented:
- Player lists owned property for sale
- AI buyers generate offers over time
- Player can negotiate with buyers
- Market conditions affect offer amounts

See spec file for full Phase 2 details: `~/Documents/FelixBrain/Projects/RLS-Career/specs/real-estate-negotiation-spec.md`

---

## Notes

- The UI is Vue-based and compiled into `ui/ui-vue/dist/`
- Source files for the UI are not in this repo
- The vehicle marketplace negotiation UI exists and can be adapted
- Backend is complete and tested via Lua API
- All backend functions are exposed via `career_modules_realEstateNegotiation` and `career_modules_garageManager`
