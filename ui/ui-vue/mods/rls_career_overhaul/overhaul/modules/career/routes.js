// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Career routes: the tree is declared in gameplay/overhaul/ui/coreUi.json and assembled by utils/coreUiRoutes.js.

// Side-effect import: installs the bridge fallbacks that career routes call Lua through.
import "./utils/installLuaBridgeFallbacks"
import { buildCoreRoutes } from "./utils/coreUiRoutes"

export default buildCoreRoutes()
