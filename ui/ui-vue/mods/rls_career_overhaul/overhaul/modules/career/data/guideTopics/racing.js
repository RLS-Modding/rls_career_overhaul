// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Private racing walkthroughs retain the guide's topic order.
export const racingTopics = [
  {
    id: 'fre-contracts',
    category: 'racing',
    iconKey: 'racing',
    relatedAppId: 'fre-contracts',
    title: 'FRE Contracts',
    description: 'Racing contracts: sponsors, goals, and commitments',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "FRE Contracts" app on your phone. If nothing is listed, FRE racing may not be active on your current map yet.',
          'Review open contracts, sponsors, and sanctioned race offers.',
          'Pick a contract whose objectives match the events and disciplines you can actually enter.',
          'Accept the contract and note deadlines, target results, and required vehicle types.',
          'Enter the listed races, track progress in the app, and collect rewards when objectives are met.',
        ],
      },
      {
        id: 'contracts-and-sponsors',
        title: 'Contracts and sponsors',
        body: [
          'Contracts ask you to finish specific races, hit target results, run certain disciplines, or use required vehicle types.',
          'Sponsors may expect valid event participation or discipline-specific performance. Keeping sponsor commitments supports longer-term motorsport income.',
        ],
      },
      {
        id: 'sanctioned-races',
        title: 'Sanctioned races',
        body: [
          'Sanctioned race offers let you commit to an upcoming race, navigate to it, or reschedule when needed.',
          'This loop is for FRE racing opportunities — not general delivery contracts or ordinary work orders.',
          'As your FRE discipline skills improve, more contract slots and harder offers can open up.',
        ],
      },
    ],
  },
  {
    id: 'freeroam-events',
    category: 'racing',
    iconKey: 'racing',
    relatedAppId: 'freeroam-events',
    title: 'Events',
    description: 'Freeroam competitions: races, challenges, and activities',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Events" app on your phone. If the list is empty, there may be no freeroam events on your current map right now.',
          'Browse upcoming activities — races, challenges, derby-style events, or special competitions.',
          'Tap an event to read entry requirements, vehicle rules, and rewards.',
          'Travel to the start point or follow the in-app navigation when you are ready to enter.',
          'Finish the event and check "Events" again for the next opportunity.',
        ],
      },
      {
        id: 'what-events-are-for',
        title: 'What events are for',
        body: [
          'Free Roam Events are activities outside normal job boards. They are a good way to test vehicles, earn rewards, and break up routine work.',
          'Some events require specific vehicles, entry modes, or performance levels — read details before you drive across town with the wrong build.',
        ],
      },
      {
        id: 'planning-ahead',
        title: 'Planning ahead',
        body: [
          'Pair "Events" with "FRE Contracts" when you are building a racing career. A contract may point you at events you would otherwise skip.',
          'If an event keeps rejecting your entry, check vehicle class, damage state, and whether you meet any skill or reputation requirement shown in the details.',
        ],
      },
    ],
  },
  {
    id: 'car-meet',
    category: 'racing',
    iconKey: 'car',
    relatedAppId: 'car-meet',
    title: 'Car Meet',
    description: 'Car meets: clubs, showcases, offers, and reputation',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Car Meet" app on your phone. If invites are quiet, meets may not be scheduled on your current map yet.',
          'Read incoming invites and note the meet type before you RSVP.',
          'Drive a vehicle that fits the theme or club when one is required.',
          'Travel to the meet location and follow on-screen prompts to park, showcase, cruise, or walk the lot.',
          'Build your Reputation by showing up to meets, finishing cruises, and buying or selling at meets.',
        ],
      },
      {
        id: 'meet-types',
        title: 'Meet types',
        body: [
          'Showcase (any Reputation): bring a vehicle that fits the scene and build attention around it.',
          'Street Cruise (10 Reputation): adds a driving phase where the group cruises to another spot. Reaching the destination with the group earns bonus Reputation.',
          'Club (30 Reputation): tied to a club you have joined — brands, models, styles, or themes. You need to be in at least one active club to get these invites.',
          'Bazaar (70 Reputation, Car Bazaar Club): a selling meet. Bring a vehicle and work buyer offers before the event ends.',
          'Elite (90 Reputation, Elite Cars Club): high-end meets that need a vehicle worth $200,000 or more.',
        ],
      },
      {
        id: 'clubs',
        title: 'Clubs',
        body: [
          'Clubs are joined from the Clubs tab in the "Car Meet" app. Each club needs a minimum Reputation, a matching vehicle in your garage, and sometimes a joining fee.',
          'Clubs expect you to show up. Skipping too many of a club\'s meets lowers your standing with that club, and if standing hits zero you are removed from it.',
          'Missing club meets never costs Reputation — only club standing.',
        ],
      },
      {
        id: 'making-offers',
        title: 'Making offers on meet cars',
        body: [
          'While a meet is active, other vehicles spawn around the lot. They are not listed with a buy-now price — walk up on foot, inspect one you like, and tap "Make an Offer" to start negotiation.',
          'You can make offers at showcase, cruise, club, bazaar, and elite meets. The "Car Meet" app shows how many meet cars are nearby while the event is running.',
          'If your offer is accepted and you have garage space and funds, the purchase completes like a normal vehicle buy.',
          'Lowball offers do not cost Reputation. The only risk is the seller countering or refusing.',
          'Paying above market value for a meet car earns Reputation — the more generous the deal (up to 30% over), the more you earn.',
        ],
      },
      {
        id: 'selling-and-rep',
        title: 'Selling your car and reputation',
        body: [
          'To sell at a meet, bring your vehicle during the showcase phase and park it at the lot. Your car is not listed with a buy-now price — meet buyers make offers to you, the same way you make offers on cars you want to buy.',
          'Offers can arrive while the event runs. Open "View Offers" or "Offers on Your Car" in the "Car Meet" app to accept, decline, or negotiate.',
          'The offers screen lets you optionally tune your asking expectation, which can influence what buyers offer — you do not need to set anything before offers start.',
          'Bazaar meets are built for selling, but ending one without a sale has no penalty.',
          'You have one Reputation score, from 0 to 100. Arriving at meets, finishing cruises, local buzz, and buying or selling at meets all add to it.',
          'Reputation unlocks more meet types and clubs, and raises the value of every car you have taken to a meet (up to +15% at max Reputation).',
          'The only way to lose Reputation is backing out of a Bazaar you accepted — cancelling it or never showing up costs 2 Reputation.',
          'Use meets to show off builds, find themed communities, scout cars to offer on, or sell with real foot traffic around your parked car.',
        ],
      },
    ],
  },
  {
    id: 'racing-team',
    category: 'racing',
    iconKey: 'racing',
    relatedAppId: 'racing-team',
    title: 'Racing Team',
    description: 'Team HQ career: leagues, goals, fleet, proxy races, and sponsors',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Find an available racing-team property on the business map. Buy it, then use its Racing Computer to run the team.',
          'Open the "Goals" tab on the computer to see your current league and work through its goals; only the current goal is active.',
          'Buy a team car on the "Vehicles" tab (team account, not personal cash), pull it out in the garage bay, and drive the activities named in your goals.',
          'The "Goals" tab shows the requirements to unlock the sanctioned race board on the "Race" tab. Complete those goals if "Available Races" is empty.',
          'Complete every goal in a league to earn a league invite. Accept from the splash or later on "Goals" — registration is paid from the team account.',
        ],
      },
      {
        id: 'hq-computer-and-phone',
        title: 'HQ, computer, and phone',
        body: [
          'Your headquarters is the business: Racing Computer, vehicle bay, team bank account, fleet garage, and sanctioned races tied to the facility.',
          'Computer tabs are "Home", "Goals", "Vehicles", "Inventory", "Race", "Drivers", and "Finances". Goals, skill trees, parts work, and full race booking live on the computer.',
          'The "Racing Team" phone app is optional — not the hub. Unlock it with the "Shop App" skill in Team Ops (after "Laptop"). Until then the app is locked and names that skill.',
          'Phone tabs cover a subset: "Home" (scheduled races, sponsorship, finances widgets), "Races", "Drivers", and "Vehicles". Handy for a quick check or to spectate away from the desk; most management stays on the computer.',
          '"Laptop" adds a second Racing Computer in the vehicle bay. "Pit Fuel" lets you refuel fleet cars from the shop and bill the team account.',
        ],
      },
      {
        id: 'leagues-and-goals',
        title: 'Leagues and goals',
        body: [
          'The Racing Computer shows the leagues available in this location and your progression through them.',
          'Each league is a chain of goals — buy cars, set lap times, earn money, win races, build class, hire drivers, hit team value targets, and more. Check "Goals" for the current target and progress.',
          'League invitations and the "Drivers" and "Race" tabs show when driver hires, proxy races, and sponsors become available.',
          'Later goals can ask for more drivers, stronger cars, more races, and larger financial milestones. Follow the "Goals" tab through the final league.',
        ],
      },
      {
        id: 'fleet-class-and-brackets',
        title: 'Fleet, class, and brackets',
        body: [
          'Fleet cars are bought on the "Vehicles" tab and stored in the team garage. Factory configs only; purchases debit the team account.',
          'Sanctioned class follows effective power-to-weight: Stock, Modified, Super, and Open. Installed parts matter — a factory build can stay Stock even if raw numbers look higher.',
          'Race offers on the board use hp/kg brackets (for example Modified club low or mid). Your car must fit the bracket; overpowered builds are blocked.',
          'The board refreshes over time and rolls races that match your fleet plus aspirational classes above it. Keep cars in repair — heavy damage can lock a fleet car out of use.',
          '"Garage Slots" (QOL skill) adds roster capacity and lets you pull more than one team car out at once, up to the physical bay size.',
        ],
      },
      {
        id: 'league-1-racing',
        title: 'Driving team races',
        body: [
          'While driver hires are locked, you drive the races yourself. Pick an offer from "Available Races", choose a fleet car, pay the entry fee from the team account, and go to the grid yourself.',
          'Sanctioned races pay into team finances and count toward goals. Entry fees scale with class and league tier.',
          'Goal races can include lap challenges, podium targets, win counts, and class targets. Read each goal on the "Goals" tab so you are working on the right activity.',
        ],
      },
      {
        id: 'proxy-races-and-drivers',
        title: 'Proxy races and drivers',
        body: [
          'Once driver hires unlock, use the "Drivers" tab — "Hire Driver", assign a fleet car, and book sanctioned races they run while you spectate.',
          'On "Available Races", pick an offer and "Assign driver" (or "Race myself" to drive yourself for a reduced team payout). Entry fee bills the team account; the offer moves to "Scheduled Races".',
          'After a short countdown the race is ready. Open "Scheduled Races" and tap "Spectate" to watch your driver\'s proxy run, or "Drop out" to cancel the booking.',
          'Drivers need a matching fleet car, idle status, and no recovery cooldown. After a race, fleet cars and drivers cool down before the next booking — "Reduced Cooldown" skill shortens that.',
          '"Manager" automation (Team Ops skill) toggles "Auto-assign sanctioned offers" on the "Race" tab to book idle drivers on a timer. Level 2 Manager picks interval and matches car bracket. "Shop App" enables lock-screen alerts when a booked race is ready to spectate.',
        ],
      },
      {
        id: 'sponsors-finances-and-skills',
        title: 'Sponsors, finances, and skills',
        body: [
          'Team money is separate from your wallet. Race payouts, entry fees, driver cuts, operating costs, paint, fuel, and league registration all flow through the team account on "Finances".',
          'The "Home" tab shows when sponsor contracts unlock. "Home" shows active deals and available offers — money and XP bonuses with a stacking cap. Slots are limited; contracts expire if you wait too long.',
          'Drivers take a cut of gross race payout based on experience tier. Operating costs tick on a schedule — bays, drivers, manager, dyno overhead — so keep an eye on the ledger.',
          'Spend team skill XP in three trees: Team Ops (laptop, phone app, pit fuel, manager), QOL (dyno, garage slots, towing, taxi to HQ), and Driver (roster size, cooldown reduction, podium XP bonus).',
          'Proxy race results feed team and driver XP. "Podium Analytics" boosts XP when your drivers podium.',
        ],
      },
    ],
  },
]
