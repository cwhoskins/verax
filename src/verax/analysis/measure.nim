## Curve math shared by the simulation-backed analyses. The implementation
## moved down to `verax/waveform` so the SI engine (`si/`, below `analysis`)
## can share it; this module keeps the old import path working.

import ../waveform

export waveform
