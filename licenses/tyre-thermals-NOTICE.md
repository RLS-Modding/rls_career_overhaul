# Tyre Wear and Thermals Redux notice

The RLS tire thermal and wear provider is a modified integration derived from
**Tyre Wear and Thermals Redux** by ZestyMaple98 (source archive version 0.20,
resource version 64879). The original work and this modified provider are
distributed under the GNU Affero General Public License, version 3. The full
license is included in `tyre-thermals-AGPL-3.0.txt`.

RLS modifications include provider arbitration, Maintenance Mode and burnout
gating, part-bound persistent condition, towing/trailer exclusions, revised
load/friction/width wear calculations, persistent flats, replacement-service
integration, a namespaced telemetry app, and removal of brake-duct tuning.

The separately installed original mod is not overwritten. If detected, it has
priority; versions without the RLS provider API run in legacy compatibility
mode with the limitations shown in game.
