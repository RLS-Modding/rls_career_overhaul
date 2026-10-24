# Third-party notices

This is a provisional inventory of identified components, not a complete rights clearance. Preserve original file notices and component licenses. Metadata attributions are leads for provenance review, not a grant to relicense the named work. See [LICENSING.md](LICENSING.md).

## BeamNG source and assets

Some source files retain the **BeamNG Common Development and Distribution License (bCDDL), version 1.1** notice. The full text is included at [licenses/bCDDL-1.1.txt](licenses/bCDDL-1.1.txt), sourced from https://www.beamng.com/bCDDL-1.1.txt.

Covered files and modifications retain bCDDL requirements, including source availability, contributor identification and preservation of upstream notices. This is not a blanket license for all BeamNG material or a finding that integrated AGPL/bCDDL code is compatible. Other BeamNG code and assets require their applicable terms.

## BeamNG UI

The identified [stock UI adaptations](licenses/BeamNG-UI-SCOPE.md) retain
the [BeamNG UI copyright and MIT permission text](licenses/BeamNG-UI-MIT.txt).
Existing bCDDL source notices remain in effect where present; the UI
directory license is not used to erase those notices.

## Tyre Wear and Thermals Redux

**ZestyMaple98** — Tyre Wear and Thermals Redux, source archive version 0.20, resource version 64879.

The modified RLS tire provider is attributed in `lua/vehicle/extensions/overhaulTires.lua`. Preserve the existing [integration notice](licenses/tyre-thermals-NOTICE.md) and [AGPLv3 text](licenses/tyre-thermals-AGPL-3.0.txt). Those notices describe the integration and RLS changes.

The exact upstream version election and scope of any separately supplied permission remain to be documented. The RLS choice of AGPL-3.0-only does not replace the upstream grant. Related helpers and calling code require their own scope review; interaction alone does not establish the license of every caller.

## Forklift and forkable loads

`vehicles/TPUMedForklift/` and `vehicles/TPUForkableLoads/` contain attribution to **TrackpadUser** and, in some sections, **BeamNG**. Preserve those attributions. Applicable vehicle/load permission remains to be recorded in this inventory; the font license below does not license the surrounding vehicle.

## DSEG font

`vehicles/TPUMedForklift/dash/DSEG14Classic-Bold.ttf`

Copyright (c) 2017, **keshikan**, with Reserved Font Name **DSEG**. Licensed under the **SIL Open Font License 1.1**. Preserve the full [DSEG license notice](vehicles/TPUMedForklift/dash/DSEG-LICENSE.txt) with the font.

## Other attribution leads

- **Necronomic:** hub dyno JBeam files under `vehicles/common/rls_dyno/`.
- **RamRod / Ramrod:** cargo and livery-related files containing `rlsupull` and `rlsusps`.
- **RaceTab Team:** dump cargo definitions for `md_series` and `us_semi`.
- **Diamondback:** junk ABS/DSE definitions for several vehicle models.
- **BeamNG, Nzyne:** mixer load definitions in `vehicles/common/mixer/`.

These attributions may overlap with BeamNG contributions. Preserve existing names and notices while confirming exact sources and applicable terms. Remaining images, textures, models and audio also need recorded provenance; this inventory does not put them under a new RLS license.
