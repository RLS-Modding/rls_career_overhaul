// Career routes: the tree is declared in gameplay/overhaul/ui/coreUi.json and assembled by utils/coreUiRoutes.js.

// Side-effect import: installs the bridge fallbacks that career routes call Lua through.
import "./utils/installLuaBridgeFallbacks"
import { buildCoreRoutes } from "./utils/coreUiRoutes"

export default buildCoreRoutes()
