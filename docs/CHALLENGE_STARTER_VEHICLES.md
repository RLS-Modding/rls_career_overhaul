# Challenge Starter Vehicles and No-Garage Starts

Challenges can gift the player a worn-out starter car and can start the career without any garage. Both are set per challenge, in its JSON file or in the in-game challenge editor, and both travel with the challenge seed.

## Challenge fields

| Field | Values | Default |
|---|---|---|
| `starterVehicles` | List of `"model/configKey"` strings. One is picked at random for a new career. | No starter car |
| `startingGarageMode` | `"default"` or `"none"` | `"default"` |

`"none"` starts the career without a garage: the default starter garage is not bought and the player has to buy their first one. It can't be combined with a non-empty `startingGarages` list.

See `challenges/ragsToRiches.json`:

```json
{
  "id": "ragsToRiches",
  "name": "Rags to Riches",
  "map": "rls_west_coast",
  "startingCapital": 0,
  "startingGarageMode": "none",
  "starterVehicles": [
    "covet/rls_hardcore_covet",
    "pessima/rls_hardcore_pessima",
    "pickup/rls_hardcore_dseries",
    "bluebuck/rls_hardcore_bluebuck",
    "autobello/rls_hardcore_piccolina"
  ],
  "winCondition": "ownSpecificGarage",
  "targetGarages": ["servicestationGarage", "commercialGarage"]
}
```

### Starter vehicle ids

An entry `"model/configKey"` names the config file `/vehicles/<model>/<configKey>.pc`. Entries that aren't in that shape fail validation. Entries whose file is missing (for example from a mod that isn't installed) are skipped with a warning when the car is granted; if none of them exist, the career starts without a starter car and tells the player.

The editor's **Starter Car** tab offers the same pool as the hardcore start (configs whose Config Type is `Hardcore`). A JSON challenge may name any config.

## In-game editor

In **Create New Story...** (or **Edit** on a story you created):

- **Starting Garages** tab: **Default** keeps the normal starter garage, **No garage** sets `startingGarageMode` to `"none"`, or pick specific garages.
- **Starter Car** tab: pick the cars to choose from at random.

Built-in challenges are read-only; their detail view shows the starting garages (`None` for no-garage starts) and the starter car pool.

## What the player gets

On a new career with a challenge that lists starter vehicles:

1. One listed config is picked at random and spawned with the ignition off, the name "Starter Car" and the plate "Starter".
2. It is aged to 900,000 miles at 50% visual condition, like the hardcore beater, so it's worth beater money (market value bottoms out past 500k miles; pre-1985 cars keep a classic floor).
3. It enters the inventory with the `starter` flag, takes no garage slot and has no insurance.
4. The player starts on foot next to it:
   - at the challenge's (or map's) starting garage, on a free parking spot; or
   - with no garage, at the map's `challenge` start spawns from its level start data, falling back to the `hardcore` spawns, then to the starter garage with the car just ahead of the player.

Hardcore mode takes precedence: a hardcore career gets the hardcore beater instead.

The grant is remembered for the current load only, so a setup retry before the first save doesn't hand out a second car. Loading an existing save never grants one.

## Implementation

- `lua/ge/extensions/overhaul/career/start/challengeStartRules.lua`: field validation, `model/configKey` parsing and the editor's starter car pool.
- `lua/ge/extensions/overhaul/career/garage/inventory/challengeStarter.lua`: picking, placing, spawning and granting the starter car.
- `lua/ge/extensions/overhaul/career/garage/inventory/setup.lua`: calls the grant when a new career is placed.
- `lua/ge/extensions/overhaul/career/garage/garageManager/ownership.lua`: no-garage challenges get no starting garage.
- `lua/ge/extensions/overhaul/career/challengeModes/seedStartSections.lua`: seed sections for both fields (the default garage mode is implied by a missing section).
- `ui/.../profiles/components/challengeCreate/ChallengeStarterVehiclesTab.vue` and `ChallengeCreateModal.vue`: editor tabs.
