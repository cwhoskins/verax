## IBIS buffers as engine devices. A driver is the decision-2 equation:
## four curves weighted `Ku(t)`, `Kd(t)`, `1`, `1` at the die node, plus
## `C_comp` as a capacitor to ground. A receiver is its clamps (weight 1)
## plus `C_comp`. The weights come from `si/drive`.

import ./mna
import ../../ibis/behave

proc driverDevice*(d: DriverBehaviour, die: int, ku, kd: Pwl, label: string,
                   vccDie = 0, gndDie = 0): NlDevice =
  ## With `vccDie`/`gndDie` (power-aware), the pullup and POWER clamp hang
  ## from the die's power node and the pulldown and GND clamp from its
  ## ground node, each at its own reference voltage, and `[ISSO PU/PD]`
  ## scale the pullup/pulldown.
  result = NlDevice(node: die, label: label)
  let aware = vccDie > 0 or gndDie > 0
  template add(c: IvCurve, w: Pwl, rail: int, nominal: float, k: IvCurve, sign: float) =
    result.curves.add c
    result.weights.add w
    if aware:
      result.refs.add rail
      result.refNominal.add nominal
      result.ksso.add k
      result.kssoSign.add sign
  if d.hasPullup and not d.pullup.isEmpty:
    add(d.pullup, ku, vccDie, d.rails.pullup, d.kssoPu, -1.0)
  if d.hasPulldown and not d.pulldown.isEmpty:
    add(d.pulldown, kd, gndDie, d.rails.pulldown, d.kssoPd, 1.0)
  if not d.gndClamp.isEmpty:
    add(d.gndClamp, Pwl(), gndDie, d.rails.gndClamp, IvCurve(), 1.0)
  if not d.powerClamp.isEmpty:
    add(d.powerClamp, Pwl(), vccDie, d.rails.powerClamp, IvCurve(), -1.0)
  if aware:
    var any = false
    for k in result.ksso:
      if not k.isEmpty: any = true
    if not any: result.ksso.setLen 0

proc receiverDevice*(r: ReceiverBehaviour, die: int, label: string): NlDevice =
  result = NlDevice(node: die, label: label)
  for c in [r.gndClamp, r.powerClamp]:
    if not c.isEmpty:
      result.curves.add c
      result.weights.add Pwl()
