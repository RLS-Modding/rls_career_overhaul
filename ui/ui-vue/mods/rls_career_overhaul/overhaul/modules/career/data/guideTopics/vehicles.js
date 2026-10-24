// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Private vehicles walkthroughs retain the guide's topic order.
export const vehiclesTopics = [
  {
    id: 'marketplace',
    category: 'vehicles',
    iconKey: 'car',
    title: 'Marketplace',
    description: 'Garage computer: dealers, private sellers, and your listings',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Use a garage computer and open "vehicle shopping".',
          'On the "Buy Vehicles" tab, pick a dealer or private seller from the list to browse what they have for sale.',
          'Open a listing to check price, condition, and fit before you purchase.',
          'To sell your own vehicle, switch to the "Sell Vehicles" tab, add a listing, and manage incoming offers there.',
        ],
        body: [
          'Phone shortcut: install the "Marketplace" app from the "App Store" if you want a quick option on the go. It is not the full experience — use the garage computer for dealers, reputation, and the complete buy and sell flow.',
          'On the phone, "Marketplace" shows a "private-listings" feed and a "Have one to sell?" link. From there you can browse NPC private sellers, list a vehicle, and accept, decline, or counter offers on your active listings.',
          'You cannot shop dealership inventory from the phone app. Dealer stock, org reputation, and taxi to lots are only on the garage computer "Buy Vehicles" tab.',
        ],
      },
      {
        id: 'listing-types',
        title: 'Listing types',
        body: [
          'Dealerships sell new and used stock tied to dealer organizations. Browse and buy from online dealers on the "Buy Vehicles" tab, or visit a lot in person.',
          'Private listings are used vehicles sold by NPC private sellers — each listing shows a seller name. Find them on the "Buy Vehicles" tab when you select a private seller.',
          'Personal listings are your own vehicles listed for sale — use the "Sell Vehicles" tab to post from your garage and receive offers you can accept or counter.',
        ],
      },
      {
        id: 'dealership-reputation',
        title: 'Dealer discovery and delivery',
        body: [
          'Physical dealerships appear on the shopping computer after you visit their lot once. Discovery is saved separately for each map.',
          'After discovery you can browse from home, but remote checkout and paid garage delivery unlock at dealer reputation level 2. Level 3 gives a 25% delivery discount.',
          'Factory and remanufacturing stores are always online. Early orders go to the map freight terminal; garage delivery unlocks with that individual seller at level 2.',
        ],
      },
      {
        id: 'market-watch-timing',
        title: 'Market Watch timing',
        body: [
          'Before listing a vehicle or buying on the garage computer, open "Market Watch" and check the "Vehicles" trend — buy and sell values follow that index, not the global economy alone.',
        ],
      },
    ],
  },
]
