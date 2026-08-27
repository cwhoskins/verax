## Example: what does this amplifier stage actually do?
##
## The same non-inverting stage measured three ways -- structurally (is there
## feedback at all), closed-loop (gain and bandwidth), and loop gain (phase
## margin) -- with no op-amp model on hand, so an ideal single-pole
## macromodel stands in.
##
## Run with:
##   nim c -r --path:./src examples/opamp_bode.nim

import std/tables

import nimcir/netlist/dsl
import nimcir/analysis/analyses/opamp

proc stage(cLoad: string): Netlist =
  ## Gain of 1 + 100k/10k = 11. `cLoad` on the feedback node adds a second
  ## pole inside the loop.
  result = netlist("preamp"):
    net vcc, kind = ntPower, voltage = "5.0"
    net gnd, kind = ntGround, name = "0"
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net vfb, kind = ntSignal

    component U1, kind = "opamp", partNumber = "OPA333":
      pin "IN+", vin, kind = ptInput
      pin "IN-", vfb, kind = ptInput
      pin "OUT", vout, kind = ptOutput
      pin "V+", vcc, kind = ptPower
      pin "V-", gnd, kind = ptGround

    component RF, kind = "resistor", value = "100k":
      pin "1", vout, kind = ptPassive
      pin "2", vfb, kind = ptPassive
    component RG, kind = "resistor", value = "10k":
      pin "1", vfb, kind = ptPassive
      pin "2", gnd, kind = ptPassive

  if cLoad.len > 0:
    let c = addComponent(result, newComponent("CF", kind = "capacitor"))
    discard connect(c, "1", result.nets["vfb"], ptPassive)
    discard connect(c, "2", result.nets["0"], ptPassive)
    c.attrs["value"] = cLoad

var spec = defaultOpAmpSpec()
spec.idealAol = 1.0e5
spec.idealGbw = 1.0e6

for label, cf in {"clean": "", "with 10nF on the feedback node": "10n"}.toOrderedTable:
  let nl = stage(cf)
  echo "########## ", label, " ##########"

  let fb = checkFeedback(nl, "U1")
  echo "feedback check: ", (if fb.len == 0: "ok" else: $fb[0])

  echo ""
  echo analyzeOpAmpResponse(nl, "U1", "vin", "vout", spec)
  echo ""
  echo analyzeLoopGain(nl, "U1", "vin", "vout", spec)
  echo ""

echo "Note the split: the closed-loop response reports *peaking*, the loop"
echo "gain reports *phase margin*. They are different measurements of the"
echo "same instability -- reading a phase margin off the closed-loop curve"
echo "would give a number that looks right and is not one."
