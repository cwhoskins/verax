## IBIS buffers as engine devices. A driver is the decision-2 equation:
## four curves weighted `Ku(t)`, `Kd(t)`, `1`, `1` at the die node, plus
## `C_comp` as a capacitor to ground. A receiver is its clamps (weight 1)
## plus `C_comp`. The weights come from `si/drive`.

import ./mna
import ../../ibis/behave

proc driverDevice*(d: DriverBehaviour, die: int, ku, kd: Pwl, label: string): NlDevice =
  result = NlDevice(node: die, label: label)
  if d.hasPullup and not d.pullup.isEmpty:
    result.curves.add d.pullup
    result.weights.add ku
  if d.hasPulldown and not d.pulldown.isEmpty:
    result.curves.add d.pulldown
    result.weights.add kd
  for c in [d.gndClamp, d.powerClamp]:
    if not c.isEmpty:
      result.curves.add c
      result.weights.add Pwl()

proc receiverDevice*(r: ReceiverBehaviour, die: int, label: string): NlDevice =
  result = NlDevice(node: die, label: label)
  for c in [r.gndClamp, r.powerClamp]:
    if not c.isEmpty:
      result.curves.add c
      result.weights.add Pwl()
