// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// The stages of an export that leaves the garage, in the order the player sees them,
// named for what the game is doing.
// The panel lists them; the away overlay counts them. Keys match the job's `stage`.
export function exportSteps({ runTests, showroomPhoto }) {
  return [
    { key: 'prepare', label: 'Saving your career' },
    ...(runTests ? [{ key: 'tests', label: 'Running performance tests' }] : []),
    ...(showroomPhoto ? [{ key: 'thumbnail', label: 'Taking the showroom photo' }] : []),
    { key: 'return', label: 'Returning to your career' },
    { key: 'write', label: 'Saving the export' },
  ]
}
