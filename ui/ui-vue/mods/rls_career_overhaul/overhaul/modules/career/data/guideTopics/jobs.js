// Private jobs walkthroughs retain the guide's topic order.
export const jobsTopics = [
  {
    id: 'logistics',
    category: 'jobs',
    iconKey: 'box',
    relatedAppId: 'logistics',
    title: 'Logistics',
    description: 'Walk-up facility work and owner-operator contracts',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Logistics" app. "Places" lists every facility with walk-up work and what it is offering — parcels, materials, vehicles, and trailers.',
          'Filter or sort the list, tap "View" to see destinations and pay, then "Route" to set GPS. Take that work at the facility inspect spot with "Inspect Cargo" — the phone does not accept those jobs for you.',
          'The "Contracts" tab is owner-operator hub work you accept from the phone. Those contracts unlock at Logistics level 30. If this career has no company employment, the board is open without that wait.',
          'On "Contracts", tap a hub, then "Accept". Use your own truck, or rent equipment at the yard if the contract needs a hauler, tanker, or trailer you do not own.',
          'Follow the marked pickups and drop-offs. Contract pay lands when the run finishes — it is not held wages like a company shift.',
          'You cannot accept an owner-operator contract while clocked in on company time. End the day in "Employment" first.',
        ],
      },
      {
        id: 'contract-types',
        title: 'Contract types',
        body: [
          'Hub contracts fill or distribute from that yard. A→B contracts send you from an origin to a destination.',
          'Parcel strings are multi-stop hub runs. Pay stays pending until the last stop is done.',
          'Car-haul contracts at distributor yards move new cars to dealerships. Accept, then use "Plan trip" to pick which cars to stage this run. Each car goes to the dealer matching its tier. Rent distributor gear if you need a truck and trailer.',
          'Finish an active owner-operator contract before taking walk-up "Inspect Cargo" jobs — those per-diem offers stay blocked until the contract is done.',
        ],
      },
      {
        id: 'owner-op-vs-other',
        title: 'Owner-op, company work, and inspect cargo',
        body: [
          'Owner-operator work is independent: you pick the contract, bring or rent the equipment, and keep the pay.',
          'Company driving is a different path. Apply in the "Employment" app, clock in at a yard, and take assigned loads in issued trucks. The company takes a share; your cut is held until you end the day.',
          'Walk-up "Inspect Cargo" at a facility is still there for one-off parcels, trailers, materials, and vehicle moves. The "Places" tab shows those offers. Some small pickup spots never post phone contracts or company jobs, but they still have that board.',
        ],
      },
    ],
  },
  {
    id: 'employment',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'employment',
    title: 'Employment',
    description: 'Company driving jobs: apply, clock in, assigned loads, held wages',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Employment" app on your phone. If it says company employment is off, this career is set to independent logistics only — use the "Logistics" app for owner-operator contracts, or "Inspect Cargo" at a facility.',
          'On "Hiring now", browse the open yards. Each card is a specific yard, not just a company name. Locked cards show the logistics level you still need.',
          'Tap a yard you qualify for, review the available assignments, then tap "Apply". You can only have one application at a time.',
          'After you are hired, go to that yard\'s inspect spot and clock in. The dispatcher assigns the load and issues a company truck — you do not pick owner-operator contracts or "Inspect Cargo" freight.',
          'Deliver the assignment, then return to the yard when the shift says to. Use "End day" at the company yard to collect held wages and return company vehicles.',
        ],
      },
      {
        id: 'company-vs-freelance',
        title: 'Company work vs freelance',
        body: [
          'Freelance logistics is owner-operator work: browse "Places" in the "Logistics" app for walk-up facility offers, take contracts on the "Contracts" tab, or pick one-off parcels, trailers, materials, and vehicle moves from a facility "Inspect Cargo" board, in your own (or rented) equipment.',
          'Employment puts you on one company\'s payroll at one home yard. The company chooses the job, issues the truck, and takes a share of the pay. You keep the rest as today\'s held wages until you end the day.',
          'A company can have more than one yard. Each yard is a separate job even when the yards share a company.',
          'Company work can let you haul some cargo types a few logistics levels earlier than freelance. Listings only show yards with work you can actually be issued today, plus locked yards that tell you what to unlock next.',
        ],
      },
      {
        id: 'pay-damage-end-day',
        title: 'Pay, damage, and ending the day',
        body: [
          'Drop-off pay goes into held wages, not cash on the spot. Finish an assignment loop and end the day at the yard to collect it and return the company vehicles.',
          'Damaged delivery vehicles and trailers use the same care rules as freelance jockey and trailer work. "Slight Damage" and "Excessive Damage" come out of that job\'s held wages. You keep the job — it is a pay dock, not a firing.',
          'The company truck is separate. Equipment damage on that shift starts with warnings, then withholds held pay, and can get you fired if it keeps happening before you clock out. The next shift starts clean.',
          'Leaving the job from the "Employment" app, or getting fired, can block rehire at that company for several sim days. Going too long without company work can also end the job.',
        ],
      },
      {
        id: 'switching-jobs',
        title: 'Switching jobs',
        body: [
          'Quit your current job before applying somewhere else. Openings rotate over time, so check "Hiring now" again later if the yard you want is not listed.',
          'Unlocking a new logistics skill can trigger a headhunter offer on the "Current" tab. Accepting switches you immediately to a yard that does that work — no extra apply wait.',
          'Police, bus, and paramedic stations are not hiring-board jobs. Clock in at those facilities when you want that work; you do not apply through "Employment".',
        ],
      },
    ],
  },
  {
    id: 'facility-work',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'facility-work',
    title: 'Facility Work',
    description: 'Forklift shifts: warehouse material moving',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Facility Work" app on your phone. If no facilities show up, this job type may not be available on your current map.',
          'Select a supported facility from the list.',
          'Tap "Start shift". A forklift will spawn for you.',
          'Use the forklift to move material props from the loading area into the marked drop zone.',
          'When a truck arrives, load the marked materials onto it from the pickup zone — finish your current batch first if one is still active. When the truck is full, open the "Facility Work" app and tap "Complete loading".',
          'Tap "End shift" when you are done for the session, or "Repair forklift" if the equipment is too damaged to keep working safely.',
        ],
      },
      {
        id: 'what-good-shifts-look-like',
        title: 'What good shifts look like',
        body: [
          'Facility Work is yard work: position the forklift, lift loads cleanly, stack or place materials, and finish batches without smashing the equipment.',
          'Some shifts include truck loading after materials are staged in a drop zone. The task list shows how many to load; tap "Complete loading" in the "Facility Work" app once the truck is full.',
          'Clean handling earns money and reputation more efficiently than rushing and breaking the forklift.',
        ],
      },
      {
        id: 'when-things-go-wrong',
        title: 'When things go wrong',
        body: [
          'Forklift damage can reduce your session pay. Slow down on tight turns and drops instead of slamming loads.',
          'If "Start shift" is greyed out or missing, the map may not support facility work yet — check back after moving to another location or when the app shows facilities again.',
        ],
      },
    ],
  },
  {
    id: 'beam-eats',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'beam-eats',
    title: 'BeamEats',
    description: 'Food delivery: shift offers, tips, rating, and streak pay',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "BeamEats" app on your phone while you are in a vehicle. If the app shows "Unavailable", BeamEats may not run on your current map or you may need to get back in a car.',
          'Tap "Start Shift" and wait for an incoming offer — orders come to you while you are on shift, not from a browse list.',
          'Review the restaurant, destination, base pay, distance, and expected time, then tap "Accept" or "Decline".',
          'Drive to the restaurant, stop near the pickup point, and wait a few seconds for the order to load — do not open logistics "Inspect Cargo" here; BeamEats pickup is automatic once you stop. Follow navigation to the customer, stop again, and wait to complete the drop-off.',
          'Check the earnings summary — base fare, tips, streak bonus, and logistics XP — then tap "Continue" for the next offer or "End Shift" when you are done.',
        ],
      },
      {
        id: 'earnings-and-rating',
        title: 'Earnings and rating',
        body: [
          'Your phone tracks "Rating", "Today\'s Earnings", and "Streak" while you work. Higher rating improves base pay on future orders.',
          'Tips reward smooth driving — rough bumps and harsh G-forces during delivery cut tips and can lower your rating. On-time delivery adds a small bonus; being late mainly reduces tips, not your base fare.',
          'The expected time on an offer is a guide, not a hard deadline — you still get paid base fare and streak bonus if you finish late. Rush only when it is safe; smooth driving usually beats speeding.',
          'Each completed order adds to your streak. Streaks pay a bonus on top of base fare and feed into logistics delivery XP shown on the summary screen.',
          'Logistics delivery skill level adds a pay bonus over time. Courier promotions — Bronze through Elite — unlock at higher logistics levels for extra pay and XP multipliers.',
        ],
      },
      {
        id: 'offers-radius-and-frequency',
        title: 'Offers, radius, and frequency',
        body: [
          'While on shift, new offers arrive on a timer. At low rating, expect a new offer roughly every 40–60 seconds. As your rating climbs toward 5.0, offers come much faster — down to about every 1–3 seconds at the top.',
          'Delivery distance grows with rating too. New drivers start with about 1 km max route length from restaurant to customer. Every 0.3 stars on your rating adds about 100 m to that cap, so higher-rated drivers can take longer, higher-paying runs.',
          'Incoming offers show distance and expected time before you accept — use those to decide whether a run fits your vehicle and route. A long expected time is fine to accept; you are not timed out if you arrive after it.',
        ],
      },
      {
        id: 'vehicles-and-driving',
        title: 'Vehicles and driving',
        body: [
          'Smaller, easy-to-drive vehicles work well for tight pickup spots and quick stops. You must come to a full stop at pickup and drop-off for the timer to complete.',
          'Nicer or higher-value vehicles can improve pay through the vehicle multiplier — but smooth handling matters more than speed for tips and rating.',
        ],
      },
    ],
  },
  {
    id: 'vehicle-transfer',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'vehicle-transfer',
    title: 'CarGo',
    description: 'Car Jockey gigs: nearest lot-to-lot drive-offs, pay on drop-off',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open "CarGo" on your phone home screen. It is preinstalled gig work — you do not apply through "Employment", and a CarGo day does not replace or block a company job.',
          'Open "CarGo" and tap "Start day". The dispatcher stages the nearest available vehicle offer you qualify for.',
          'Drive to the pickup, take the staged vehicle, and deliver it to the listed drop-off. Pay settles on drop-off like other vehicle deliveries.',
          'The next nearby transfer starts automatically. Tap "End day" anytime to stop.',
        ],
      },
      {
        id: 'how-it-differs',
        title: 'How it differs from Employment',
        body: [
          'Company employment clocks you in at a home yard with issued trucks and cargo loops. CarGo is a phone gig: you drive off vehicles between partner lots using your own route and the CarGo day controls.',
          'You can keep an Employment job and still run CarGo when you want extra drive-off work. Logistics owner-operator contracts stay separate as well.',
        ],
      },
      {
        id: 'pay-and-assignments',
        title: 'Pay and assignments',
        body: [
          'Tickets are assigned — there is no offer shopping list inside CarGo. The dispatcher prefers the nearest unlocked vehicle offer to where you are.',
          'Damage, detours, and timing use the same vehicle-delivery care rules as freelance jockey work. End day cancels an unmoved, undamaged transfer for free; otherwise it ends your day after the current delivery. If the assigned vehicle cannot make the trip, use Report undeliverable in CarGo or the vehicle radial menu to request another.',
        ],
      },
    ],
  },
  {
    id: 'taxi',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'taxi',
    title: 'Taxi',
    description: 'Passenger fares: tips, ratings, and rider types',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Taxi" app on your phone. If the service is unavailable, taxi work may not be offered on your current map.',
          'Choose a vehicle with enough seats for the riders you want to attract.',
          'Tap "Drive Now" to go available for fares.',
          'Accept a rider when an offer appears, drive to pickup, then drop them off at the destination.',
          'Review base fare, tips, and your rating after each trip, then keep accepting fares or tap "Stop Driving" when you are done.',
        ],
      },
      {
        id: 'earnings-and-rating',
        title: 'Earnings and rating',
        body: [
          'Your phone shows rider type, passenger count, fare rate, driver rating, vehicle multiplier, and fare streak while you are working.',
          'Better vehicles can qualify for higher-value riders. Your driver rating helps you reach better clients over time.',
          'Fare streaks improve earnings while you keep accepting trips without long gaps.',
        ],
      },
      {
        id: 'rider-types-and-tips',
        title: 'Rider types & tips',
        body: [
          'Standard riders want speed and efficiency. Deliver quickly while avoiding rough driving — they mostly reward a "Speed Bonus".',
          'Commuters want punctual, steady driving. Arrive a little ahead of pace, keep comfort high, and avoid harsh G-forces for "On-Time Bonus" and "Comfort".',
          'Students are budget riders. Keep the route efficient and reasonably quick; they reward "Efficient Trip" more than luxury.',
          'Business riders are time-critical. Drive assertively and arrive fast, but do not stack too many aggressive events. They can pay "Efficiency Bonus" and "Assertive Driving".',
          'Executives expect quiet premium service. Keep the ride extremely smooth and controlled, avoid speeding, and aim for "White-Glove Service" or "Discreet Comfort".',
          'Luxury riders care about comfort over speed. Use a nicer vehicle, drive smooth and calm, and avoid aggressive inputs. "Immaculate Ride" and "Premium Comfort" are the big payouts.',
          'Tourists enjoy the journey. Take it slower, keep the ride scenic and smooth, and avoid rushing. "Scenic Bonus", "Perfect Pace", and "Wonderful Tour" reward that style.',
          'Families need seats and safety. Use a vehicle with enough capacity, drive slower, and keep the ride smooth for "Safe Driving" and "Smooth Ride".',
          'Party Groups need large-capacity vehicles and gentle driving. Avoid sudden movements, high G, and speeding. "Safety Bonus", "Gentle Driving", and "No Sudden Movements" are the goal.',
          'Thrill Seekers are the exception: they want speed and controlled excitement. Drive fast, create controlled G-force moments, but do not overdo it into chaos. "Speed Rush", "Adrenaline Bonus", and "Peak Thrill" pay out.',
        ],
      },
    ],
  },
  {
    id: 'repo',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'repo',
    title: 'Repo',
    description: 'Vehicle recovery: generate missions, haul targets, deliver to dealers',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Repo" app on your phone while you are in a vehicle. The minimap shows your area — there is no job list to browse.',
          'If you are on foot, the app shows "Need Vehicle" and repo is disabled. Get back in a car or truck first.',
          'Tap "Generate Mission" to roll a new recovery. The app briefly shows "Loading Mission..." while the target is placed.',
          'Follow navigation to the spawned vehicle shown in the panel ("Find and collect this vehicle"). Position your repo rig to load it — keep the truck nearby through the whole haul.',
          'If repo is unavailable, a "Repo Unavailable" overlay explains why — common causes are walking on foot, a challenge that disables repo pay, or a repo economy multiplier set to zero.',
        ],
      },
      {
        id: 'pickup-and-delivery',
        title: 'Pickup, haul, and delivery',
        steps: [
          'During pickup, bring your repo rig within about 20 m of the target vehicle. That starts the haul phase — load it onto your rollback bed, tiltdeck, or tow setup.',
          'Haul the target to the dealership named on screen ("Deliver to: …"). Stay in your repo rig; the panel tracks distance to the drop-off.',
          'Position the target within about 3 m of the dealership marker at low speed to finish — roll it off the bed or uncouple if you need to. Pay appears in the reward bubble and on the completion screen.',
          'Tap "Complete" on the completion overlay to collect and clear the mission. Use the X on the mission panel to abandon an active job.',
          'Stay close during each phase: during pickup, keep your repo rig within about 100 m of the target; during the haul, keep the target within about 100 m of your repo rig. Wander farther and a 10-second return countdown starts — let it expire and the job fails.',
        ],
      },
      {
        id: 'pay-tiers-and-skill',
        title: 'Pay, tiers, and Repo skill',
        body: [
          'The reward bubble at the top of the app estimates payout while you work. Final pay depends on the vehicle value, route distance, time, job tier, Repo skill bonus, and any active economy multipliers.',
          'Each mission rolls a tier chip such as "Joe\'s Junk Repo", "Budget Repo", "Standard Repo", "Luxury Repo", "Exotic Repo", or "Heavy Repo". Higher tiers pay more but unlock as your Repo skill level rises.',
          'Repo skill XP is awarded on completion. Each level above 1 adds +2% payout — the mission panel shows this as "Repo Lv N • +X%" when the bonus applies.',
          'Do not delete or despawn your repo rig mid-job. If it is removed, the mission ends immediately. Switching to a different vehicle before pickup starts regenerates a new mission.',
        ],
      },
      {
        id: 'equipment-plates-and-routing',
        title: 'Equipment, plates, and routing',
        body: [
          'Any vehicle can tap "Generate Mission", but a dedicated repo rig makes hauls much easier. Dealership "Repo Ready" configs — rollback pickups and tiltdeck trucks — come set up for recovery work.',
          'License plate text is not checked when you generate a mission, but a "repo" plate is strongly recommended on your recovery truck. Repo Ready vehicles ship with plate text "repo"; you can also set it later with "Personalize license plate" in your garage inventory when that option is available.',
          'Vehicles with a "repo" plate are treated as repo work trucks in traffic — they are not handled like undercover police during pursuit events, which helps avoid unwanted attention while you are loading or hauling.',
          'Scout the route before you commit. Tight lots, damage, and long backroads can turn a short map distance into a slow haul. Keep your repo rig parked where you can reach the target and the dealership without breaking the 100 m leash.',
        ],
      },
    ],
  },
  {
    id: 'quarry',
    category: 'jobs',
    iconKey: 'work',
    relatedAppId: 'quarry',
    title: 'Quarry',
    description: 'Loader contracts: rock and marble loading',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Quarry" app on your phone. If contracts are empty, quarry work may not be offered on your current map.',
          'Review available rock or marble contracts and what each one requires.',
          'Travel to the quarry loading zone shown for the contract.',
          'Use the front loader to move the required material into the target area or delivery point.',
          'Complete the weight or block count shown on the job before time runs out or the contract expires.',
        ],
      },
      {
        id: 'rock-vs-marble',
        title: 'Rock vs marble',
        body: [
          'Rock contracts use loose rock piles and usually track progress by weight. Steady bucket work beats rushed scoops that spill material.',
          'Marble contracts use blocks where supported. Handle blocks carefully — damaged blocks may not count toward the contract.',
        ],
      },
      {
        id: 'loader-control',
        title: 'Loader control',
        body: [
          'Line up the bucket or forks, keep the load stable, and avoid dropping or crushing the product.',
          'Quarry jobs pay best when you work steadily and keep material intact, not when you race and lose half the load.',
          'Different locations may offer different materials. If marble jobs never appear, your current map may only support rock work.',
        ],
      },
    ],
  },
]
