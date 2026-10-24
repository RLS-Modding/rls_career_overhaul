// Private business walkthroughs retain the guide's topic order.
export const businessTopics = [
  {
    id: 'tuning-shop',
    category: 'business',
    iconKey: 'building',
    relatedAppId: 'tuning-shop',
    title: 'Tuning Shop',
    description: 'Tuning business: customer jobs, parts, kits, and shop automation',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Find an available tuning shop on the business map. Walk up to its facility marker to purchase the property and use the business computer.',
          'New customer jobs appear on the "Jobs" tab over time. You start with two active job slots — accept one, "Pull Out" the customer car in the garage, and work it on a lift.',
          'With a car on a lift, use the workshop "Parts" and "Tuning" views to build the job, then drive to the race named in the goal.',
          'Beat the target time on the job card ("Goal" vs "Current"), return to the computer, and tap "Complete" to collect payout into the shop account.',
        ],
      },
      {
        id: 'hq-computer-and-phone',
        title: 'HQ, computer, and phone',
        body: [
          'The facility is the business: garage lifts, customer fleet storage, shop bank account, and the business computer.',
          'Computer tabs are "Home", "Jobs", "Kits", "Inventory", "Techs", "Finances", and "Skill Trees". Accepting jobs, installing parts, saving kits, hiring techs, and spending upgrade XP all happen here.',
          'With a vehicle on a lift, the left sidebar shows "WORKSHOP" with "Parts" and "Tuning". Install work bills the shop account, not your personal wallet.',
          'The "Tuning Shop" phone app is optional — not the hub. Unlock it with the "Shop App" skill in Quality Of Life on "Skill Trees". Until then the app is locked and names that skill.',
          'Phone tabs cover a subset: "Home" (active jobs, idle techs, balance), "Jobs" (accept, complete, or abandon remotely), "Techs", and "Finances". You cannot install parts or tune from the phone.',
        ],
      },
      {
        id: 'the-job-loop',
        title: 'The job loop',
        body: [
          'Jobs list a target lap or run time at the event named on the card. "Current" shows the best time logged for that job car at that event.',
          'Flow: accept from "New Jobs" → "Pull Out" on "Active Jobs" (one car per lift; extra lifts come from shop upgrades) → modify the build → drive to the event and run it → "Complete" when Current meets or beats Goal.',
          'New offers generate on a timer (about two minutes between rolls by default; "Marketing" speeds this up). Unaccepted jobs expire after about five minutes.',
          'Completion locks to the build that set the time. If you change parts after a good run, the card may say "Build changed — re-run the event to complete" until you run again with the current setup.',
          'Keep the customer car intact — heavy damage can lock the job ("Vehicle Damaged") until you "Abandon" it. "That\'ll Buff Out" raises the damage tolerance. Abandoning costs half the job payout from the shop account ("No Hard Feelings" and "I Give Up" reduce or remove that fee).',
          'Use "Filters" on the "Jobs" tab to manage blacklists, job notifications, and (with a Manager) which offers auto-assign to techs.',
        ],
      },
      {
        id: 'parts-tuning-and-kits',
        title: 'Parts, tuning, and kits',
        body: [
          '"Inventory" holds removed parts from customer builds — sell individual pieces or "Sell All Parts" to recover value into the shop account.',
          '"Dyno" (Shop Upgrades skill) adds live power and weight stats while you work on a car in the shop.',
          '"Kits" lets you save a proven parts-and-tune setup from a job you can complete, then "Apply to Vehicle" on a matching model later. "Kit Storage" skills add save slots; "Quick Installs" shortens apply time.',
          'Part and tune costs respect shop skills — "Part Suppliers" and "Cheap Tunes" cut install bills. Towing (Shop Upgrades) lets you haul a pulled-out car back to the garage after driving to events.',
          '"Personal Use" (late Quality Of Life) lets your own garage cars use the lifts, discounts, and tools while you are in the shop zone.',
        ],
      },
      {
        id: 'techs-and-automation',
        title: 'Techs and automation',
        body: [
          '"Shop Techs" (Automation skill tree) hires workers who accept jobs, spend build budget, and run events for you. Each tech bills operating cost on a schedule.',
          'Assign techs on the "Techs" tab or from the phone. A tech on a job builds automatically — build cost is a slice of the payout, with success, rebuild, and failure rules tied to Automation upgrades.',
          '"Manager" auto-assigns idle techs to new offers on a timer. "Manager Blacklist" keeps chosen models for manual work. "General Manager" assigns as soon as a tech is free.',
          'You can still hand-build jobs yourself: leave a job unassigned, pull the car out, and tap "Complete" when you beat the goal. Techs and manager are throughput tools, not required to play.',
        ],
      },
      {
        id: 'finances-and-skills',
        title: 'Finances and skills',
        body: [
          'Shop money is separate from your wallet. Job rewards, part purchases, penalties, and operating costs flow through the business account on "Finances".',
          'Operating costs tick for lifts, hired techs, and managers — watch the ledger. "Solar Panels" (late Shop Upgrades) removes those bills.',
          '"Bigger Books" adds active job slots beyond the starting two. Extra lifts ("Lift #2" through "Lift #4") let more cars or techs work at once.',
          'Spend shop XP on three trees on "Skill Trees": Quality Of Life (phone app, blacklists, kits, harder jobs, damage tolerance, personal use), Automation (techs, manager, reliability), and Shop Upgrades (towing, dyno, part discounts, marketing, solar).',
          'Harder job tiers unlock with "More Complicated" skills; "Brand Recognition" and "Race Recognition" bias which vehicles and race types appear in the offer pool.',
        ],
      },
    ],
  },
  {
    id: 'skills',
    category: 'business',
    iconKey: 'flag',
    relatedAppId: 'skills',
    title: 'Skills',
    description: 'Career progression: unlocks, branches, and perks',
    sections: [
      {
        id: 'how-to-start',
        title: 'How to start',
        steps: [
          'Open the "Skills" app on your phone.',
          'Browse skill branches for driving, logistics, racing, business, public service, and other specialties.',
          'Tap a branch to see your level, perks already unlocked, and what comes next.',
          'Do the activities that grant XP in the branch you care about — jobs, races, deliveries, or business work as listed in each path.',
          'Return after sessions to review unlocks and pick your next focus.',
        ],
      },
      {
        id: 'what-skills-unlock',
        title: 'What skills unlock',
        body: [
          'Leveling skills can open better jobs, better rewards, new abilities, equipment access, or stronger career options.',
          'Some systems look at skill progress before offering advanced work, so your skill tree shapes what the career feeds you.',
        ],
      },
      {
        id: 'planning-your-path',
        title: 'Planning your path',
        body: [
          'Use "Skills" to decide what kind of career you are building instead of grinding random jobs.',
          'If a job type feels locked or low-paying, check whether the related skill branch needs another level first.',
        ],
      },
    ],
  },
]
