<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template><!-- Shared Broker screen styles load with the first work view. --></template>

<script>
export default {}
</script>

<style>

/* House style shared with EmployeeShift: dark gray, orange accent, Overpass, soft corners, no stripes. */

/* ---- buttons and fields */
.text-btn[data-broker-scope] { background: none !important; padding: 0.3em 0 !important; color: var(--accent) !important; font-weight: 700;
}
.text-btn[data-broker-scope]:hover:not(:disabled) { background: none !important; color: #ff9a4d !important;
}
.block-head[data-broker-scope] { display: flex; align-items: center; gap: 0.45em;
}
.tip-btn[data-broker-scope] { position: relative; display: grid; place-items: center; width: 1.75em; height: 1.75em; padding: 0 !important; border-radius: 50%; background: transparent !important; color: var(--faint) !important; transition: color 0.12s, background-color 0.12s;
}
.tip-btn svg[data-broker-scope] { width: 1em; height: 1em; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round;
}
.tip-btn[data-broker-scope]:hover:not(:disabled) { color: #fff !important; background: var(--panel-2) !important;
}
.tip-btn[data-broker-scope]:disabled { opacity: 0.6;
}
.tip-btn.spinning svg[data-broker-scope] { animation: tip-spin-broker-scope 0.9s linear infinite;
}
.tip-btn[data-broker-scope]::after { content: attr(data-tip); position: absolute; left: calc(100% + 0.45em); top: 50%; transform: translate(-0.3em, -50%); padding: 0.42em 0.65em 0.28em; border-radius: 0.35em; background: #2b2c30; color: #fff; font-size: 0.72em; font-weight: 700; letter-spacing: 0.02em; white-space: nowrap; box-shadow: 0 4px 14px rgba(0, 0, 0, 0.55); opacity: 0; pointer-events: none; transition: opacity 0.12s ease-out, transform 0.12s ease-out; z-index: 5;
}
.tip-btn[data-broker-scope]:hover::after { opacity: 1; transform: translate(0, -50%);
}
.kicker[data-broker-scope] { font-size: 0.75em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--accent);
}
.hint[data-broker-scope] { color: var(--muted);
}
.money[data-broker-scope] { color: var(--money);
}

/* ---- header */

/* ---- markets */

/* ---- bottom nav */

/* ---- loads: toolbar, list, rows */
.toolbar[data-broker-scope] { padding: 0 1em 0.5em; flex-shrink: 0; display: grid; gap: 0.45em;
}
.breadcrumb[data-broker-scope] { display: flex; justify-content: space-between; align-items: center;
}
.toolbar input[data-broker-scope] { width: 100%;
}
.toolbar-row[data-broker-scope] { display: flex; gap: 0.3em; align-items: center;
}
.toolbar-row input[data-broker-scope] { flex: 1; width: 0; min-width: 0;
}
.toolbar-row .icon-btn[data-broker-scope] { flex: 0 0 auto;
}
.filter-toggle[data-broker-scope] { position: relative;
}
.filter-toggle .count[data-broker-scope] { position: absolute; top: -0.3em; right: -0.2em; margin: 0; min-width: 1.3em; justify-content: center; background: var(--accent); color: #fff;
}
.broker-sort[data-broker-scope] { position: absolute; inset: 4.2em 0 0; z-index: 20; display: grid; align-items: start; padding: 0.5em 1em; background: rgba(0, 0, 0, 0.65); overflow: auto;
}
.sort-panel[data-broker-scope] { display: grid; gap: 0.5em; width: 100%; max-width: 30em; margin: 0 auto; padding: 1em; border-radius: 0.6em; background: #26262a;
}
.sort-panel h3[data-broker-scope] { margin: 0 0 0.3em;
}
.sort-options[data-broker-scope] { display: grid; gap: 0.3em;
}
.sort-options button[data-broker-scope] { text-align: left; white-space: normal;
}
.sort-options button.active[data-broker-scope] { background: rgba(255, 102, 0, 0.25); color: #ffb27a;
}
.jobs-tabs[data-broker-scope] { display: flex; gap: 0.4em; padding: 0 1em 0.5em;
}
.jobs-tabs button[data-broker-scope] { flex: 1; background: var(--panel);
}
.jobs-tabs .header-expand[data-broker-scope], .view-bar .header-expand[data-broker-scope] { flex: 0 0 auto;
}
.view-bar .depot-strip[data-broker-scope] { flex: 1; min-width: 0;
}
.scope-clear[data-broker-scope] { margin: 0 0 0.4em;
}
.jobs-tabs button.active[data-broker-scope] { background: var(--panel-2); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.55);
}
.workarea[data-broker-scope] { flex: 1; min-height: 0; display: flex;
}
.load-list[data-broker-scope] { padding: 0 1em 0.75em;
}
.list-caption[data-broker-scope] { display: flex; justify-content: space-between; margin: 0.2em 0 0.5em; font-size: 0.78em; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--faint);
}
.row-thumb[data-broker-scope] { flex: 0 0 auto; width: 4.6em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35); display: grid; place-items: center; color: rgba(255, 255, 255, 0.45);
}
.row-thumb img[data-broker-scope] { display: block; width: 100%; height: 100%; object-fit: cover;
}
.row-thumb[data-broker-scope] .bng-icon { font-size: 1.6em;
}
.broker .load-row[data-broker-scope] { display: flex; align-items: center; gap: 0.7em; width: 100%; min-width: 0; text-align: left; margin: 0 0 0.4em; padding: 0.75em !important; border-radius: 0.5em !important; background: var(--panel) !important; font-weight: 400; white-space: normal;
}
.load-row[data-broker-scope]:hover:not(:disabled) { background: var(--panel-2) !important;
}
.load-row.selected[data-broker-scope] { box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.6); background: rgba(255, 102, 0, 0.1) !important;
}
/* Row: what and pay, then where and haul, then one status line. */
.row-summary[data-broker-scope] { flex: 1 1 auto; min-width: 0; display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: baseline; gap: 0.35em 0.6em;
}
.row-summary > *[data-broker-scope]:not(.row-title):not(.compact-pay):not(.route):not(.row-haul) { grid-column: 1 / -1;
}
.row-title[data-broker-scope] { min-width: 0; margin: 0; font-size: 1.05em; font-weight: 700; line-height: 1.25; overflow-wrap: anywhere; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden;
}
.row-haul[data-broker-scope] { display: inline-flex; align-items: center; justify-self: end; gap: 0.25em; font-size: 0.85em; font-weight: 700; color: var(--muted); white-space: nowrap;
}
.row-haul[data-broker-scope] .bng-icon { font-size: 1.15em; color: var(--faint);
}
.card-top[data-broker-scope] { display: flex; justify-content: space-between; align-items: baseline; gap: 0.6em;
}
.group-mult[data-broker-scope] { margin-right: 0.35em; color: #ffb27a; font-weight: 800; letter-spacing: 0.02em;
}
.detail-hero-copy h2 .group-mult[data-broker-scope] { margin-right: 0.25em;
}
.pay[data-broker-scope] { flex-shrink: 0; color: var(--money); font-weight: 700; white-space: nowrap;
}
.route[data-broker-scope] { min-width: 0; color: var(--muted); font-size: 0.92em; white-space: normal; overflow-wrap: anywhere; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden;
}
.row-status[data-broker-scope] { display: flex; align-items: center; gap: 0.6em; min-width: 0; min-height: 1.6em; font-size: 0.85em; color: var(--faint);
}
.row-meta[data-broker-scope] { display: inline-flex; gap: 0.8em;
}
.row-meta > span[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.25em; color: var(--muted); font-weight: 700;
}
.row-meta[data-broker-scope] .bng-icon { font-size: 1.15em; color: var(--faint);
}
.load-row .status[data-broker-scope] { margin-top: 0.35em;
}
.list-columns[data-broker-scope], .wide-cell[data-broker-scope], .detail-placeholder[data-broker-scope] { display: none;
}

/* ---- detail */
.detail-pane[data-broker-scope] { display: flex; flex: 1; min-width: 0; flex-direction: column;
}
.detail-scroll[data-broker-scope] { padding: 0 1em 1em;
}
.detail-hero[data-broker-scope] { position: relative; margin: 0.5em 0 0; border-radius: 0.5em; overflow: hidden; aspect-ratio: 16 / 8; background: rgba(0, 0, 0, 0.35);
}
.detail-hero.no-photo[data-broker-scope] { aspect-ratio: auto; min-height: 5.5em;
}
.detail-hero img[data-broker-scope] { display: block; width: 100%; height: 100%; object-fit: cover;
}
.detail-hero[data-broker-scope]::after { content: ""; position: absolute; inset: 0; background: linear-gradient(to top, rgba(21, 21, 23, 1) 0%, rgba(21, 21, 23, 0.55) 40%, rgba(21, 21, 23, 0) 75%); pointer-events: none;
}
.detail-hero-copy[data-broker-scope] { position: absolute; left: 0.8em; right: 8em; bottom: 0.55em; z-index: 1;
}
.detail-hero-pay[data-broker-scope] { position: absolute; right: 0.8em; bottom: 0.7em; z-index: 1; display: grid; justify-items: end; gap: 0.3em;
}
.detail-hero-pay .detail-pay[data-broker-scope] { font-size: 1.6em; text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9);
}
.detail-hero-copy .eyebrow[data-broker-scope] { margin: 0; text-shadow: 0 1px 2px rgba(0, 0, 0, 0.9);
}
.detail-hero-copy h2[data-broker-scope] { margin: 0.1em 0 0; text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9);
}
.detail-close[data-broker-scope] { position: absolute; top: 0.6em; right: 0.6em; z-index: 2; background: rgba(0, 0, 0, 0.55) !important;
}
.detail-close[data-broker-scope]:hover:not(:disabled) { background: rgba(0, 0, 0, 0.75) !important;
}
.facts[data-broker-scope] { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(7em, 100%), 1fr)); gap: 0.4em 0.9em; margin-top: 0.6em; padding: 0.6em 0.75em; border-radius: 0.5em; background: var(--panel);
}
.fact[data-broker-scope] { display: grid; gap: 0.15em; min-width: 0;
}
.fact-key[data-broker-scope] { font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint);
}
.fact-value[data-broker-scope] { font-weight: 700; line-height: 1.25; display: inline-flex; align-items: center; gap: 0.3em; overflow-wrap: anywhere;
}
.fact-value.accent[data-broker-scope] { color: #ffb27a;
}
.count[data-broker-scope] { margin-left: 0.45em; font-size: 0.72em;
}
.pay-note[data-broker-scope] { margin: 0.5em 0 0; font-size: 0.8em; font-weight: 600; line-height: 1.35; color: var(--faint);
}
.fact-value[data-broker-scope] .bng-icon { font-size: 1.15em;
}
.detail-map-slot[data-broker-scope] { flex: 1 1 8em; min-height: 8em; padding: 0.5em 1em 0; display: flex;
}
.detail-map-slot .detail-map[data-broker-scope] { flex: 1 1 auto; aspect-ratio: auto; height: auto; min-height: 7em;
}
.detail-scroll[data-broker-scope] { flex: 1 1 auto;
}
.expanded .detail-scroll[data-broker-scope] { flex: 0 1 auto;
}
.detail-map.inline[data-broker-scope] { margin-top: 0.8em; aspect-ratio: 16 / 9;
}
.eyebrow[data-broker-scope] { margin: 0.8em 0 0; font-size: 0.75em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--accent);
}
.detail-scroll h2[data-broker-scope] { margin: 0.2em 0 0.4em; font-size: 1.5em; font-weight: 800; line-height: 1.15; overflow-wrap: anywhere;
}
.detail-head[data-broker-scope] { display: grid; gap: 0.1em;
}
.detail-pay[data-broker-scope] { font-size: 1.8em; font-weight: 800; color: var(--money); line-height: 1.1;
}
.detail-scroll small[data-broker-scope] { display: block; color: var(--muted); font-size: 0.85em;
}
.route-row[data-broker-scope] { margin-top: 0.6em; display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); align-items: center; gap: 0.5em; padding: 0.6em 0.75em; border-radius: 0.5em; background: var(--panel);
}
.route-cell[data-broker-scope] { display: grid; gap: 0.1em; min-width: 0;
}
.route-cell small[data-broker-scope] { font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint);
}
.route-cell strong[data-broker-scope] { line-height: 1.2; overflow-wrap: anywhere;
}
.route-cell[data-broker-scope]:last-child { text-align: right; justify-items: end;
}
.route-arrow[data-broker-scope] { display: grid; justify-items: center; gap: 0.15em; color: var(--accent);
}
.route-arrow svg[data-broker-scope] { width: 1.6em; height: 1.6em; fill: none; stroke: currentColor; stroke-width: 2.6; stroke-linecap: round; stroke-linejoin: round;
}
.route-arrow em[data-broker-scope] { font-style: normal; font-size: 0.72em; font-weight: 700; color: var(--faint); white-space: nowrap;
}
.stop-copy[data-broker-scope] { flex: 1 1 auto;
}
.stop-photo[data-broker-scope] { flex: 0 0 auto; width: 4.4em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35);
}
.stop-photo img[data-broker-scope] { display: block; width: 100%; height: 100%; object-fit: cover;
}
.stop-dot[data-broker-scope] { position: relative; z-index: 1; flex: 0 0 auto; width: 0.8em; height: 0.8em; margin: 0 0.35em; border-radius: 50%; background: var(--accent); border: 2px solid #1a1a1c; box-sizing: content-box;
}
.stop-dot.end[data-broker-scope] { background: #151517; border-color: #fff;
}
.stop-copy[data-broker-scope] { display: grid; gap: 0.05em; min-width: 0;
}
.stop-copy small[data-broker-scope] { font-size: 0.7em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint);
}
.stop-copy strong[data-broker-scope] { font-size: 1.05em; line-height: 1.2; overflow-wrap: anywhere;
}
.progress[data-broker-scope] { margin-top: 1em; display: grid; gap: 0.4em;
}
.progress .bar[data-broker-scope] { display: flex; height: 0.55em; border-radius: 1em; overflow: hidden; background: rgba(255, 255, 255, 0.12);
}
.progress .done[data-broker-scope] { background: var(--ok);
}
.progress .transit[data-broker-scope] { background: var(--accent);
}
.progress .legend[data-broker-scope] { display: flex; justify-content: space-between; gap: 0.6em; font-size: 0.82em; color: var(--muted);
}
.progress .legend b[data-broker-scope] { color: #fff;
}
.progress .legend span:nth-child(1) b[data-broker-scope] { color: var(--ok);
}
.progress .legend span:nth-child(2) b[data-broker-scope] { color: #ffb27a;
}
.detail-actions[data-broker-scope] { padding: 0.75em 1em; border-top: 1px solid var(--line); display: flex; flex-wrap: wrap; gap: 0.4em;
}
.next-step[data-broker-scope] { flex-basis: 100%; display: flex; align-items: baseline; gap: 0.6em; min-width: 0; padding-bottom: 0.15em;
}
.next-step .kicker[data-broker-scope] { flex: 0 0 auto;
}
.next-step-text[data-broker-scope] { min-width: 0; font-size: 0.9em; font-weight: 600; color: rgba(255, 255, 255, 0.8); line-height: 1.25;
}
.detail-actions button[data-broker-scope] { flex: 1 1 40%;
}
.detail-actions .primary[data-broker-scope] { flex-basis: 100%;
}
.reserve-amount[data-broker-scope] { flex-basis: 100%; display: flex; align-items: center; gap: 0.7em; min-width: 0;
}
.reserve-amount .kicker[data-broker-scope] { flex: 0 0 auto;
}
.reserve-note[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.5em; min-width: 0; color: var(--muted); font-size: 0.88em; font-weight: 600; white-space: nowrap; font-variant-numeric: tabular-nums;
}
.reserve-pay[data-broker-scope] { margin-left: auto; color: var(--money); font-weight: 800; font-variant-numeric: tabular-nums;
}
.detail-actions .count button[data-broker-scope] { flex: 0 0 auto;
}
.detail-actions small[data-broker-scope] { flex-basis: 100%; color: var(--muted); font-size: 0.85em;
}
.pickup-form[data-broker-scope] { margin-top: 1em; display: grid; gap: 0.5em;
}
.loader[data-broker-scope] { margin-top: 1em; display: grid; gap: 0.6em;
}
.loader .block-head .split-btn[data-broker-scope] { margin-left: auto; font-size: 0.85em;
}
.loader > .muted[data-broker-scope] { margin: 0; font-size: 0.88em; line-height: 1.4;
}
.load-veh[data-broker-scope] { margin: -0.25em 0 0; color: var(--faint); font-size: 0.82em;
}
.parcel-copy small > span + span[data-broker-scope]::before { content: '·'; margin: 0 0.4em;
}
.bins[data-broker-scope] { list-style: none; margin: 0; padding: 0; display: grid; gap: 0.35em;
}
.bin[data-broker-scope] { display: grid; grid-template-columns: auto minmax(0, max-content) minmax(3em, 1fr) auto; grid-template-areas: "no copy bar left"; align-items: center; column-gap: 0.65em; padding: 0.5em 0.7em; border-radius: 0.5em; background: var(--panel);
}
.bin .bin-no[data-broker-scope] { grid-area: no;
}
.bin-no[data-broker-scope] { display: inline-grid; place-items: center; flex: 0 0 auto; width: 1.45em; height: 1.45em; padding-top: 0.12em; border-radius: 0.3em; background: var(--panel-2); color: rgba(255, 255, 255, 0.85); font-size: 0.78em; font-weight: 800; line-height: 1; font-variant-numeric: tabular-nums;
}
.bin.planned .bin-no[data-broker-scope] { background: rgba(255, 102, 0, 0.25); color: #ffb27a;
}
.bin-copy[data-broker-scope] { grid-area: copy; min-width: 0; display: flex; align-items: baseline; gap: 0.45em;
}
.bin-copy strong[data-broker-scope] { flex: 0 0 auto; font-size: 0.92em; line-height: 1.2;
}
.bin-copy small[data-broker-scope] { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--faint); font-size: 0.8em;
}
.bin-left[data-broker-scope] { grid-area: left; color: var(--faint); font-size: 0.8em; white-space: nowrap; font-variant-numeric: tabular-nums;
}
.bin-left b[data-broker-scope] { color: #fff; font-size: 1.1em;
}
.bin-bar[data-broker-scope] { grid-area: bar; display: flex; height: 0.4em; border-radius: 99em; overflow: hidden; background: rgba(0, 0, 0, 0.35);
}
.bin-bar span[data-broker-scope] { flex: 0 0 0; min-width: 0;
}
.bin-bar .held[data-broker-scope] { background: rgba(255, 255, 255, 0.28);
}
.bin-bar .plan[data-broker-scope] { background: var(--accent);
}
.parcels[data-broker-scope] { display: grid; gap: 0.35em;
}
.parcel[data-broker-scope] { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; column-gap: 0.65em; row-gap: 0.4em; padding: 0.5em 0.5em 0.5em 0.55em; border-radius: 0.5em; background: var(--panel); transition: opacity 0.15s ease;
}
.parcel.off[data-broker-scope] { opacity: 0.5;
}
.parcel .tick[data-broker-scope] { flex: 0 0 auto; display: grid; place-items: center; width: 1.7em; height: 1.7em; padding: 0 !important; border-radius: 0.4em !important; background: var(--accent) !important; transition: background-color 0.12s ease;
}
.parcel .tick svg[data-broker-scope] { width: 1.1em; height: 1.1em; fill: none; stroke: #fff; stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; transition: opacity 0.12s ease;
}
.parcel.off .tick[data-broker-scope] { background: transparent !important; box-shadow: inset 0 0 0 2px rgba(255, 255, 255, 0.35);
}
.parcel.off .tick svg[data-broker-scope] { opacity: 0;
}
.parcel .tick[data-broker-scope]:active { transform: scale(0.94);
}
.parcel-copy[data-broker-scope] { flex: 1 1 auto; min-width: 0; display: grid; gap: 0.12em;
}
.parcel-copy strong[data-broker-scope] { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.92em; line-height: 1.2;
}
.parcel-copy small[data-broker-scope] { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--faint); font-size: 0.8em; font-variant-numeric: tabular-nums;
}
.box-pick[data-broker-scope] { flex: 0 1 auto; display: inline-flex; align-items: center; gap: 0.45em; min-width: 0; max-width: 55%; padding: 0.45em 0.6em 0.4em 0.45em !important; border-radius: 0.45em !important; background: var(--panel-2) !important; font-size: 0.85em; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; transition: background-color 0.12s ease;
}
.box-pick .bin-no[data-broker-scope] { background: rgba(255, 102, 0, 0.25); color: #ffb27a; font-size: 0.85em;
}
.box-pick svg[data-broker-scope] { flex: 0 0 auto; width: 0.95em; height: 0.95em; fill: none; stroke: var(--faint); stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; transform: rotate(90deg);
}
.broker .box-pick[data-broker-scope]:disabled { opacity: 1; cursor: default;
}
.box-pick[data-broker-scope]:hover:not(:disabled) { background: rgba(255, 255, 255, 0.16) !important;
}
.box-pick[data-broker-scope]:active:not(:disabled) { transform: scale(0.97);
}
.parcel.off .parcel-copy[data-broker-scope] { opacity: 0.55;
}
.parcel .tick.part[data-broker-scope] { background: rgba(255, 102, 0, 0.45) !important;
}
.parcel-copy .group-mult[data-broker-scope] { margin-right: 0.3em;
}
.count[data-broker-scope] { display: inline-flex; font-size: 1.05em; align-items: center; border-radius: 0.45em; background: rgba(0, 0, 0, 0.3); font-variant-numeric: tabular-nums;
}
.count button[data-broker-scope] { width: 2.2em; height: 2.2em; padding: 0 !important; background: transparent !important; color: var(--muted); font-size: 1em; font-weight: 800; border-radius: 0.45em !important;
}
.count button[data-broker-scope]:hover:not(:disabled) { color: #fff; background: var(--panel-2) !important;
}
.count button[data-broker-scope]:disabled { opacity: 0.35;
}
.count b[data-broker-scope] { min-width: 1.5em; text-align: center; font-size: 1em;
}
.splits[data-broker-scope] { grid-column: 2 / -1; display: flex; flex-wrap: wrap; gap: 0.35em;
}
.splits .box-pick[data-broker-scope] { max-width: 100%;
}
.box-pick em[data-broker-scope] { font-style: normal; color: #ffb27a; font-variant-numeric: tabular-nums;
}
.box-pick.nope[data-broker-scope] { background: transparent !important; color: #ffb27a; box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.45); padding: 0.45em 0.6em 0.4em !important; cursor: default;
}
.pickup-form .chips button[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.5em;
}
.pickup-form .chips button .pill[data-broker-scope] { font-size: 0.72em;
}
.pickup-form label[data-broker-scope] { display: grid; gap: 0.4em; font-size: 0.85em; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--faint);
}
.pickup-form label input[data-broker-scope] { font-weight: 400; letter-spacing: 0; text-transform: none;
}
.car-choices[data-broker-scope] { margin-top: 1em; display: grid; gap: 0.45em;
}
.car[data-broker-scope] { position: relative; display: flex; align-items: center; gap: 0.7em; width: 100%; padding: 0.45em 0.7em 0.45em 0.45em !important; border: 0; border-radius: 0.5em !important; background: var(--panel) !important; color: inherit; font: inherit; font-weight: 400; text-align: left; white-space: normal; cursor: pointer; transition: background-color 0.18s ease, box-shadow 0.22s ease, transform 0.18s ease;
}
.car[data-broker-scope]:hover:not(:disabled) { background: var(--panel-2) !important; transform: translateY(-1px);
}
.car[data-broker-scope]:active:not(:disabled) { transform: translateY(0) scale(0.995);
}
.car.picked[data-broker-scope] { background: rgba(255, 102, 0, 0.07) !important; box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.45); animation: car-pick-broker-scope 0.28s ease-out;
}
.car.picked[data-broker-scope]:hover:not(:disabled) { background: rgba(255, 102, 0, 0.11) !important;
}
.car.picked .car-copy strong[data-broker-scope] { color: #fff;
}
.car[data-broker-scope]:disabled { cursor: default; opacity: 0.55; transform: none;
}
.car.done .car-img img[data-broker-scope] { filter: grayscale(0.8) brightness(0.6);
}
.car-img[data-broker-scope] { position: relative; flex: 0 0 auto; width: 5.4em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35); display: grid; place-items: center; color: rgba(255, 255, 255, 0.4);
}
.car-img img[data-broker-scope] { display: block; width: 100%; height: 100%; object-fit: cover;
}
.car-state[data-broker-scope] { position: absolute; top: 0.55em; right: 0.75em; font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint);
}
.car-state.ok[data-broker-scope] { color: rgba(74, 222, 128, 0.75);
}
.car-state.busy[data-broker-scope] { color: #ffb27a;
}
.car-copy[data-broker-scope] { padding-right: 4.5em;
}
.car-copy[data-broker-scope] { flex: 1 1 auto; min-width: 0; display: grid; gap: 0.1em;
}
.car-copy strong[data-broker-scope] { line-height: 1.2; transition: color 0.18s ease;
}
.car-copy small[data-broker-scope] { color: var(--faint); font-size: 0.85em;
}

/* ---- filters */
.filter-page[data-broker-scope] { gap: 0.9em;
}
.filter-group h3[data-broker-scope] { margin: 0 0 0.5em; font-size: 0.85em; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--faint);
}
.filter-note[data-broker-scope] { margin: 0.35em 0 0; font-size: 0.82em; font-weight: 600; color: var(--faint); line-height: 1.35;
}
.market-chips[data-broker-scope] { display: flex; flex-wrap: wrap; gap: 0.35em;
}
.market-chips button[data-broker-scope] { font-size: 0.78em; padding: 0.45em 0.65em 0.35em;
}
.chips[data-broker-scope] { display: flex; flex-wrap: wrap; gap: 0.4em;
}
.chips button[data-broker-scope] { background: var(--panel); padding: 0.5em 0.8em 0.4em; border-radius: 0.4em;
}
.chips button.active[data-broker-scope] { background: rgba(255, 102, 0, 0.25); color: #ffb27a; box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.5);
}
.filter-actions[data-broker-scope] { display: flex; gap: 0.5em; margin-top: 0.5em;
}
.filter-actions .primary[data-broker-scope] { flex: 1;
}
.picker-field[data-broker-scope] { display: grid; grid-template-columns: minmax(0, 1fr) auto auto; align-items: center; gap: 0.6em; width: 100%; text-align: left; padding: 0.7em 0.8em 0.6em; border-radius: 0.45em; background: var(--panel); font-weight: 400;
}
.picker-label[data-broker-scope] { font-size: 0.85em; font-weight: 700; color: var(--muted);
}
.picker-value[data-broker-scope] { max-width: 12em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 700; color: #fff;
}
.picker-chev[data-broker-scope] { color: var(--accent); font-weight: 700;
}

/* ---- route plan */
.route-plan[data-broker-scope] { padding: 0 1em 1em; display: flex; flex-direction: column; gap: 0.7em;
}
.route-plan[data-broker-scope] > * { flex: 0 0 auto;
}
.plan-map[data-broker-scope] { aspect-ratio: 16 / 7;
}
.route-summary[data-broker-scope] { display: grid; gap: 0.6em; padding: 0.7em 0.8em; border-radius: 0.5em; background: var(--panel);
}
.route-stats[data-broker-scope] { display: flex; flex-wrap: wrap; gap: 0.4em 1.6em;
}
.route-stats .stat[data-broker-scope] { display: grid; gap: 0.1em;
}
.stat-key[data-broker-scope] { font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint);
}
.stat-value[data-broker-scope] { font-weight: 700; font-size: 1.1em; line-height: 1.2;
}
.stat-value small[data-broker-scope] { font-size: 0.75em; color: var(--faint); font-weight: 600;
}
.route-actions[data-broker-scope] { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4em;
}
.route-actions .primary[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.4em;
}
.stop-list[data-broker-scope] { display: grid; gap: 0.4em;
}
.plan-stop[data-broker-scope] { position: relative; display: flex; gap: 0.6em; align-items: center; padding: 0.5em 0.6em; border-radius: 0.5em; background: var(--panel);
}
.plan-index[data-broker-scope] { flex: 0 0 auto; min-width: 1.9em; padding: 0.45em 0.45em 0.2em; display: grid; place-items: center; border-radius: 0.3em; background: rgba(255, 102, 0, 0.25); color: #ffb27a; font-size: 0.85em; font-weight: 700; line-height: 1;
}
.plan-stop.delivery .plan-index[data-broker-scope] { background: rgba(255, 255, 255, 0.1); color: rgba(255, 255, 255, 0.85);
}
.stop-main[data-broker-scope] { flex: 1; min-width: 0; text-align: left; background: none !important; padding: 0 !important; font-weight: 400; white-space: normal; display: grid; gap: 0.15em; justify-items: start;
}
.stop-kind[data-broker-scope] { margin-bottom: 0.1em;
}
.stop-main strong[data-broker-scope] { font-size: 1em; line-height: 1.2;
}
.stop-main small[data-broker-scope] { color: var(--muted); font-size: 0.85em;
}
.leg[data-broker-scope] { flex: 0 0 auto; display: grid; justify-items: end; gap: 0.15em; text-align: right;
}
.leg-dist[data-broker-scope] { font-weight: 700; font-variant-numeric: tabular-nums;
}
.leg-status[data-broker-scope] { font-size: 0.78em; color: var(--faint);
}
.plan-move[data-broker-scope] { display: flex; flex-direction: column; gap: 0.2em;
}
.plan-move button[data-broker-scope] { padding: 0.15em 0.35em; display: grid; place-items: center;
}
.plan-move button[data-broker-scope] .bng-icon { font-size: 1.1em;
}
.expanded .route-plan[data-broker-scope] { width: 100%; max-width: 60em; margin: 0 auto;
}

/* ---- loaners */
.loaners[data-broker-scope] { padding: 0 1em 1em;
}
.loaners h3[data-broker-scope] { margin: 1em 0 0.5em; font-size: 0.75em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--accent);
}
.depot-strip[data-broker-scope] { padding: 0.7em 0.8em; border-radius: 0.5em; background: var(--panel); display: flex; justify-content: space-between; align-items: center; gap: 0.6em; flex-wrap: wrap;
}
.loaner-card[data-broker-scope] { padding: 0; border-radius: 0.5em; background: var(--panel); margin: 0 0 0.45em; display: flex; flex-direction: column; gap: 0.35em; overflow: hidden;
}
.loaner-card[data-broker-scope] > * { flex: 0 0 auto;
}
.loaner-card[data-broker-scope] > :not(.loaner-img) { margin-left: 0.8em; margin-right: 0.8em;
}
.loaner-card > .card-top[data-broker-scope] { margin-top: 0.6em;
}
.loaner-card > .rental-actions[data-broker-scope] { margin-bottom: 0.7em;
}
.loaner-img[data-broker-scope] { position: relative; aspect-ratio: 16 / 7; background: rgba(0, 0, 0, 0.35);
}
.loaner-img img[data-broker-scope] { display: block; width: 100%; height: 100%; object-fit: cover;
}
.loaner-img[data-broker-scope]::after { content: ""; position: absolute; inset: 0; background: linear-gradient(to top, rgba(20, 20, 22, 0.7), rgba(20, 20, 22, 0) 55%); pointer-events: none;
}
.loaner-card p[data-broker-scope] { margin: 0; color: var(--muted); font-size: 0.9em;
}
.rental-actions[data-broker-scope] { display: flex; justify-content: flex-end; align-items: center; gap: 0.4em; margin-top: 0.2em;
}
.rental-actions .text-btn[data-broker-scope] { margin-right: auto;
}
/* Primary card actions sit bottom-right, a size up, as Start here does on loads. */
.rental-actions .primary[data-broker-scope] { padding: 0.5em 1.1em 0.4em; border-radius: 1.2em; font-size: 1em;
}
.card-line .pill[data-broker-scope] { margin-right: 0.5em;
}
/* Loaner cards show each value on its own with a small label, never dot-joined. */
.card-facts[data-broker-scope] { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.2em 0.9em;
}
.card-facts .pill[data-broker-scope] { margin-right: 0;
}
.card-fact-key[data-broker-scope] { margin-right: 0.4em; font-size: 0.75em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint);
}
.loaner-card[data-broker-scope]:hover, .plan-stop[data-broker-scope]:hover { background: var(--panel-2);
}
.loaner-card.at-pickup[data-broker-scope] { border-left: 0.2em solid var(--ok);
}
.loaners > .muted[data-broker-scope] { margin: 0.8em 0 0; font-size: 0.85em; line-height: 1.45;
}

/* ---- toast */

/* ---- expanded: full-screen board */
.expanded .toolbar[data-broker-scope] { padding: 0 1.5em 0.6em;
}
.expanded .load-list[data-broker-scope] { padding: 0 1.5em 0.8em;
}
.expanded .detail-scroll[data-broker-scope] { padding: 0.75em 1.25em 1.25em;
}
.expanded .loaners[data-broker-scope], .expanded .route-plan[data-broker-scope] { padding-left: 1.5em; padding-right: 1.5em;
}
.expanded .jobs-tabs[data-broker-scope] { justify-content: center;
}
.expanded .jobs-tabs button[data-broker-scope] { flex: 0 1 14em;
}
.expanded .loaners[data-broker-scope] { width: 100%; max-width: 70em; margin: 0 auto;
}
.expanded .loaner-list[data-broker-scope] { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(22em, 100%), 1fr)); gap: 0.6em;
}
.expanded .loaner-card[data-broker-scope] { margin: 0;
}
.expanded .rental-actions button[data-broker-scope] { min-width: 7em;
}
@media (min-width: 1100px) {
.expanded .toolbar[data-broker-scope], .expanded .workarea[data-broker-scope], .expanded .jobs-tabs[data-broker-scope] { width: 100%; max-width: 100em; margin-left: auto; margin-right: auto;
}
.expanded .toolbar[data-broker-scope] { grid-template-columns: minmax(0, 1fr); gap: 0.5em 0.8em; align-items: center;
}
.expanded .breadcrumb[data-broker-scope] { grid-column: 1 / -1; margin: 0;
}
.expanded .toolbar input[data-broker-scope] { margin: 0;
}
.expanded .workarea[data-broker-scope] { display: grid; grid-template-columns: minmax(0, 7fr) minmax(20em, 3fr); grid-template-rows: minmax(0, 1fr); padding: 0 1.5em 1em; gap: 1em;
}
.expanded .load-list[data-broker-scope] {
    padding: 0 0 0.6em;
    --broker-grid: 4.6em minmax(13em, 1.4fr) minmax(7em, 0.65fr) minmax(5.5em, 0.5fr) minmax(7em, 1fr) minmax(5.5em, 0.55fr);
}
.expanded .list-caption[data-broker-scope] { margin: 0.2em 0.75em 0.6em;
}
.expanded .list-columns[data-broker-scope], .expanded .load-row[data-broker-scope] {
    display: grid;
    grid-template-columns: var(--broker-grid);
    column-gap: 0.65em;
    align-items: center;
    padding-left: 0.75em;
    padding-right: 0.75em;
    box-sizing: border-box;
}
.expanded .list-columns[data-broker-scope] {
    position: sticky;
    top: 0;
    z-index: 1;
    padding-top: 0.35em;
    padding-bottom: 0.4em;
    margin-bottom: 0.25em;
    background: linear-gradient(180deg, rgba(0, 0, 0, 0.35) 0%, rgba(0, 0, 0, 0.12) 100%);
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
}
.expanded .col-head[data-broker-scope] {
    display: flex;
    flex-direction: row;
    flex-wrap: nowrap;
    align-items: center;
    justify-content: flex-end;
    gap: 0.4em;
    min-width: 0;
    font-size: 0.72em;
    font-weight: 600;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.45);
}
.expanded .col-head.span-2[data-broker-scope] { grid-column: span 2;
}
.expanded .col-head.start[data-broker-scope] { justify-content: flex-start;
}
.expanded .col-label[data-broker-scope] {
    flex: 0 1 auto;
    min-width: 0;
    white-space: nowrap;
    line-height: 1.2;
}
.expanded .col-chevs[data-broker-scope] {
    display: inline-flex;
    flex-direction: row;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    gap: 0.1em;
    padding: 0.15em 0.18em;
    border-radius: 0.35em;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.06);
    box-sizing: border-box;
}
.expanded .col-chevs .chev-btn[data-broker-scope] {
    display: grid;
    place-items: center;
    width: 1.45em;
    height: 1.45em;
    padding: 0 !important;
    margin: 0;
    border-radius: 0.25em;
    background: transparent !important;
    color: rgba(255, 255, 255, 0.32);
    line-height: 1 !important;
    font-weight: 400;
    white-space: normal;
    transform: none;
}
.expanded .col-chevs .chev-btn svg[data-broker-scope] {
    display: block;
    width: 0.95em;
    height: 0.95em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
}
.expanded .col-chevs .chev-btn[data-broker-scope]:hover:not(:disabled) { color: rgba(255, 255, 255, 0.85) !important; background: rgba(255, 255, 255, 0.1) !important; transform: none;
}
.expanded .col-chevs .chev-btn.active[data-broker-scope] { color: var(--accent) !important; background: rgba(255, 140, 0, 0.12) !important;
}
.expanded .load-row > .row-thumb[data-broker-scope] { grid-column: 1;
}
.expanded .load-row > .row-summary[data-broker-scope] { grid-column: 2; min-width: 0; grid-template-columns: minmax(0, 1fr);
}
.expanded .wide-cell[data-broker-scope] { display: block; min-width: 0; text-align: right; color: var(--muted); font-variant-numeric: tabular-nums;
}
.expanded .cargo-cell[data-broker-scope] { overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.expanded .wide-cell.pay[data-broker-scope] { color: var(--money); font-size: 1.05em;
}
.expanded .load-row .compact-pay[data-broker-scope], .expanded .load-row .row-meta[data-broker-scope], .expanded .load-row .row-haul[data-broker-scope] { display: none;
}
.expanded .detail-pane[data-broker-scope], .expanded .detail-placeholder[data-broker-scope] { min-height: 0; border-radius: 0.6em; background: var(--panel); overflow: hidden;
}
.expanded .detail-placeholder[data-broker-scope] { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 2em; text-align: center; color: var(--muted);
}
.expanded .detail-placeholder[data-broker-scope] .bng-icon { font-size: 4em; color: rgba(255, 255, 255, 0.35); margin-bottom: 0.3em;
}
.expanded .detail-placeholder h3[data-broker-scope] { margin: 0 0 0.4em; color: #fff; font-size: 1.2em;
}
.expanded .detail-placeholder p[data-broker-scope] { margin: 0 0 0.5em; max-width: 20em;
}
.expanded .detail-scroll h2[data-broker-scope] { font-size: 1.6em;
}
.expanded .detail-actions[data-broker-scope] { background: rgba(0, 0, 0, 0.2);
}
}
@media (max-width: 1099px) {
.expanded .has-detail .load-list[data-broker-scope] { display: none;
}
}

/* ---- expanded market home: centred */

/* Availability stays compact inside the existing phone list. */
.load-entry[data-broker-scope] { margin-bottom: 0.5em; border-radius: 0.5em; background: var(--panel); overflow: hidden; }
.load-entry.at-pickup[data-broker-scope] { border-left: 0.2em solid var(--ok); }
.load-entry .load-row[data-broker-scope] { margin: 0; background: transparent !important; }
/* The whole card lights on hover, Start column included; the row inside
   stays clear so the two never stack. */
.load-entry[data-broker-scope]:hover { background: var(--panel-2); }
.load-entry .load-row[data-broker-scope]:hover:not(:disabled) { background: transparent !important; }
/* A timed offer's countdown rides on its thumbnail, out of the status line. */
.row-thumb[data-broker-scope] { position: relative; }
.row-expiry[data-broker-scope] { position: absolute; left: 50%; bottom: 0.2em; transform: translateX(-50%); display: inline-flex; align-items: center; gap: 0.2em; padding: 0.05em 0.35em; border-radius: 0.6em; background: rgba(0, 0, 0, 0.7); color: #ffd09f; font-size: 0.68em; font-weight: 700; line-height: 1.3; white-space: nowrap; }
.row-expiry[data-broker-scope] .bng-icon { font-size: 1.1em; }
.row-expiry.ended[data-broker-scope] { color: var(--muted); }
.start-here[data-broker-scope] { margin: 0 0.75em 0.6em; }
/* At a pickup, the pay and Start form their own right column beside the row
   button, so Start sits under the pay and the pad reaches it with Right. The
   haul moves to the status line; the row keeps its height. */
.start-col[data-broker-scope] { display: contents; }
.start-col .pay[data-broker-scope] { display: none; }
.broker:not(.expanded) .load-entry.startable[data-broker-scope] { display: flex; align-items: stretch; }
.broker:not(.expanded) .load-entry.startable .load-row[data-broker-scope] { flex: 1 1 auto; padding-right: 0.4em !important; }
.broker:not(.expanded) .load-entry.startable .row-summary[data-broker-scope] { grid-template-columns: minmax(0, 1fr); }
.row-meta > span[data-broker-scope] { white-space: nowrap; }
.broker:not(.expanded) .load-entry.startable .row-haul[data-broker-scope],
.broker:not(.expanded) .load-entry.startable .compact-pay[data-broker-scope] { display: none; }
.broker:not(.expanded) .start-col[data-broker-scope] { display: flex; flex-direction: column; align-items: flex-end; justify-content: space-between; gap: 0.5em; flex: 0 0 auto; padding: 0.75em 0.75em 0.75em 0; }
.broker:not(.expanded) .start-col .pay[data-broker-scope] { display: block; line-height: 1.25; font-size: 1.05em; }
.broker:not(.expanded) .start-here[data-broker-scope] { margin: 0; padding: 0.5em 1.1em 0.4em; border-radius: 1.2em; font-size: 1em; }
.row-haul-inline[data-broker-scope] { display: none; }
.expanded .start-col[data-broker-scope] { display: flex; justify-content: flex-end; padding: 0 0.75em 0.6em; }
.expanded .start-here[data-broker-scope] { margin: 0; padding: 0.5em 1.1em 0.4em; border-radius: 1.2em; font-size: 1em; }
.broker:not(.expanded) .load-entry.startable .row-haul-inline[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.25em; margin-left: 0.6em; font-size: 0.92em; font-weight: 700; white-space: nowrap; vertical-align: baseline; }
.row-haul-inline[data-broker-scope] .bng-icon { font-size: 1.15em; color: var(--faint); }
.access-summary[data-broker-scope] { display: grid; gap: 0.3em; font-size: 0.9em; font-weight: 400; }
.access-summary .pills[data-broker-scope] { margin: 0.25em 0 0; display: flex; flex-wrap: wrap; gap: 0.3em; }
.access-line[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.3em; min-width: 0; overflow: hidden; font-weight: 400; }
.access-line .pill[data-broker-scope] { flex: 0 0 auto; }
.access-line .fit-reason[data-broker-scope] { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.fit-reason[data-broker-scope] { color: var(--muted); white-space: normal; line-height: 1.3; }
.pill.here[data-broker-scope], .pill.ok[data-broker-scope] { color: #a7edbb; background: rgba(74, 222, 128, 0.14); }
.access-summary .pill[data-broker-scope] { max-width: 100%; white-space: normal; overflow-wrap: anywhere; line-height: 1.2; }
.pickup-distance[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.25em; }
.pickup-distance.here[data-broker-scope] { color: #a7edbb; }
.pill.warn[data-broker-scope] { color: #ffd09f; background: rgba(255, 170, 60, 0.14); }
.requirement[data-broker-scope] { display: grid; gap: 0.25em; color: #ffd09f; white-space: normal; }
.requirement progress[data-broker-scope] { width: 100%; height: 0.25em; accent-color: var(--accent); }
.requirement small[data-broker-scope] { color: var(--muted); }
.list-heading[data-broker-scope] { margin: 0.9em 0.2em 0.45em; font-size: 0.95em; font-weight: 700; color: var(--muted); }
.list-columns + .list-heading[data-broker-scope] { margin-top: 0.2em; }
.unlock-heading[data-broker-scope] { display: grid; gap: 0.35em; }
.unlock-heading h3[data-broker-scope] { margin: 0; font-size: 1em; color: #ffb27a; }
.unlock-heading progress[data-broker-scope] { width: 100%; height: 0.25em; accent-color: var(--accent); }
.badge-line[data-broker-scope] { display: flex; flex-wrap: wrap; gap: 0.3em; color: var(--muted); font-size: 0.9em; }
.badge-tag[data-broker-scope] { padding: 0.25em 0.5em 0.15em; border-radius: 0.3em; background: var(--panel); line-height: 1.2; }
.pickup-heading[data-broker-scope] { display: flex; align-items: baseline; gap: 0.8em; }
.pickup-name[data-broker-scope] { flex: 1 1 auto; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.pickup-heading .pickup-distance[data-broker-scope] { flex: 0 0 auto; font-size: 0.9em; white-space: nowrap; }
.pickup-heading .pickup-distance[data-broker-scope] .bng-icon { color: var(--faint); }
.pickup-heading .pickup-distance.here[data-broker-scope] .bng-icon { color: inherit; }
.job-timeline[data-broker-scope] { display: flex; gap: 0.4em; font-size: 0.85em; color: var(--faint); margin: 0.35em 0; }
.job-timeline > span[data-broker-scope] { flex: 1; border-top: 0.15em solid var(--line); padding-top: 0.3em; }
.job-timeline .done[data-broker-scope] { color: var(--ok); border-color: var(--ok); }
.broker button[aria-disabled="true"][data-broker-scope] { opacity: 0.55; cursor: wait; }
</style>
