// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Private finance walkthroughs retain the guide's topic order.
export const financeTopics = [
  {
    id: 'banking',
    category: 'finance',
    iconKey: 'bank',
    relatedAppId: 'bank',
    title: 'Banking',
    description: 'Career accounts: separate cash, business money, and transfers',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Bank" app on your phone. If you do not see it yet, install it from the "App Store" first.',
          'Review your existing accounts and balances on the main screen.',
          'Tap "+ New Account" if you want a separate place for personal money, business money, or savings.',
          'Use "⇄ Transfer" to move cash between accounts or pull money from an account when you need it.',
          'Tap an account to see its details, recent activity, and any pending transfers.',
        ],
      },
      {
        id: 'why-use-banks',
        title: 'Why use accounts',
        body: [
          'Bank accounts help you separate loose cash from money you are saving for a vehicle, property, or business.',
          'Some career systems can pull payments from bank accounts instead of only using cash on hand. Keeping the right funds in the right account makes loan payments, business expenses, and big purchases easier to plan.',
        ],
      },
      {
        id: 'transfers-and-waiting',
        title: 'Transfers and waiting',
        body: [
          'Transfers from business accounts can take a few minutes to finish. Check "Pending Transfers" on the "Bank" screen if money has not moved yet.',
          'You can cancel a pending transfer from the list if you changed your mind before it completes.',
        ],
      },
    ],
  },
  {
    id: 'loans',
    category: 'finance',
    iconKey: 'bank',
    relatedAppId: 'loans',
    title: 'Loans',
    description: 'Career borrowing: payments, credit, and mortgages',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Loans" app on your phone.',
          'Browse lenders and see which loan offers you qualify for.',
          'Check each offer for balance, interest rate, payment amount, and how often payments are due.',
          'Accept a loan when the terms fit your plan and you can cover the payments.',
          'Return to the "Loans" app anytime to track what you owe, upcoming payments, and your credit standing.',
        ],
      },
      {
        id: 'qualifying-and-credit',
        title: 'Qualifying and credit',
        body: [
          'Loan offers depend on the lender, your reputation with that organization, how much debt you already carry, and your credit score.',
          'Paying on time helps your credit and makes future borrowing easier. Missed payments can hurt your score, add interest, raise your rate, and shrink future offers.',
        ],
      },
      {
        id: 'paying-off-debt',
        title: 'Paying off debt',
        body: [
          'Payments are taken automatically when they are due, so keep enough money in the right account before the due date.',
          'If you get ahead, you can prepay part of a loan or pay the full remaining balance early to save on interest.',
          'Mortgages for property show up here too, so you can track home debt alongside regular loans in one place.',
        ],
      },
    ],
  },
  {
    id: 'market-watch',
    category: 'finance',
    iconKey: 'economy',
    relatedAppId: 'market-watch',
    title: 'Market Watch',
    description: 'Economy and market trends: timing buys, sales, and work',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Market Watch" app on your phone. It is preinstalled — no "App Store" download needed.',
          'Read the "Market Trends" charts for "Global Economy", "Job Market", "Housing", and "Vehicles".',
          'Scroll to "Latest News" for headlines about shifting pay and prices. The feed may be empty early in a career — reopen the app later to refresh.',
          'Before a big purchase or sale, open "Market Watch" again and compare trends to last time you looked.',
        ],
      },
      {
        id: 'what-each-market-means',
        title: 'What each market means',
        body: [
          '"Global Economy" affects many everyday costs — fuel, insurance, loans, quick travel, painting, recovery, and business purchases. A rising global index usually means higher costs; a falling one can ease pressure on your wallet.',
          '"Job Market" affects job and race payouts. "Housing" affects property buy, sell, and rent prices. "Vehicles" affects vehicle buy and sell values at dealers, on the marketplace, and in your garage inventory.',
          'Each market moves on its own. A weak global economy does not automatically mean cheaper cars or property — check the chart for the decision you are about to make.',
        ],
      },
      {
        id: 'using-it-for-decisions',
        title: 'Using it for decisions',
        body: [
          'Use "Market Watch" before buying property, listing a vehicle, taking on heavy debt, or stacking multiple big expenses at once.',
          'It will not tell you exactly what to do, but it helps you decide when to hold cash, when to buy, and when to push harder on jobs.',
        ],
      },
    ],
  },
]
