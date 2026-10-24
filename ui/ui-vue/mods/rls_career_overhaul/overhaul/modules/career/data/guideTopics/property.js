// Private property walkthroughs retain the guide's topic order.
export const propertyTopics = [
  {
    id: 'real-estate',
    category: 'property',
    iconKey: 'building',
    relatedAppId: 'real-estate',
    title: 'Real Estate',
    description: 'Properties and garages: buy, rent, finance, and sell',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Real Estate" app on your phone. If the list is empty, that feature may not be available on your current map yet.',
          'Browse available properties, garages, and storage options near you.',
          'Tap a listing to see price, capacity, lease or purchase terms, and what you get for the money.',
          'Choose buy, rent, or claim when a starter option is offered and you are ready to commit.',
          'After you have a property, use the app to manage listings, review offers, or plan your next move.',
        ],
      },
      {
        id: 'buy-rent-or-finance',
        title: 'Buy, rent, or finance',
        body: [
          'Buying with cash costs more up front, but once owned the property is yours without recurring rent or mortgage payments.',
          'Renting gives temporary access without a big purchase. Fixed rentals have predictable payments; dynamic rentals can shift with the market; upfront rentals let you pay ahead for the lease.',
          'A mortgage lets you finance a property with scheduled payments instead of paying the full price at once. That helps you grow sooner, but missed payments create real debt pressure.',
        ],
      },
      {
        id: 'selling-and-offers',
        title: 'Selling and offers',
        body: [
          'Owned properties can be listed for sale when you want to move money out of real estate and back into vehicles or business plans.',
          'Review incoming offers on owned properties and accept or decline from the "Real Estate" app.',
          'Late rent or missed mortgage payments can lead to warnings or serious consequences, so treat property like any other bill.',
        ],
      },
    ],
  },
  {
    id: 'rentals',
    category: 'property',
    iconKey: 'building',
    relatedAppId: 'rentals',
    title: 'Rentals',
    description: 'Active leases: rent due, warnings, and ending a lease',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Rentals" app on your phone after you have signed at least one lease.',
          'If you have no active rentals, the app will tell you — you may need to rent through "Real Estate" first.',
          'Review each lease for rent amount, lease type, time remaining, and payments made so far.',
          'Check warning status before the due date so you are not caught off guard.',
          'Use the app to plan renewals, early endings, or moving vehicles before a lease expires.',
        ],
      },
      {
        id: 'why-rent',
        title: 'Why rent',
        body: [
          'Renting is useful when you need garage space before you can afford to buy, or when you want to test a location before committing to ownership.',
          'It is flexible, but you are still on the hook for payments on schedule.',
        ],
      },
      {
        id: 'late-payments-and-ending-early',
        title: 'Late payments and ending early',
        body: [
          'Late rent can escalate from a warning into eviction or lost access. Do not ignore warning messages.',
          'Ending a lease early may cost your deposit plus an extra fee, and vehicles stored there may be relocated.',
        ],
      },
    ],
  },
]
