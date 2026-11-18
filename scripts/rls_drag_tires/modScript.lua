-- The tire fit is required in freeroam as well as career, before vehicle spawn.
-- Loads lua/common/extensions/jbeam/rlsDragTireFit.lua; see that file for the fit.
setExtensionUnloadMode('jbeam_rlsDragTireFit', 'manual')
extensions.load('jbeam_rlsDragTireFit')
