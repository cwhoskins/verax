## Two boards and the cable between them.
##
##   verax check designs/system_sensor_rig.nim
##
## A USB-powered carrier board regulating 3.3 V, and a small sensor head on
## the end of a 300 mm cable. Both boards live in `designs/lib/` as ordinary
## netlists; `spice/boundary.asSubcircuit` turns each one's connectors into
## its ports, and this file wires the ports together.
##
## **Both, not either.** `designs/carrier.nim` and `designs/sensor_head.nim`
## are checked on their own too -- each is a module when imported and a
## program when checked, split by `when isMainModule`, so a board states what
## is plugged into it for the bench and this file supplies the real other end
## instead. `asSubcircuit` drops the connectors, and the bench drives go with
## them, so the standalone assumptions cannot leak in here.
##
## **Why a system design as well as two board designs.** A board checked on
## its own is checked against an *assumed* other end. Measured, on exactly
## these two: the carrier alone reports its output at 4.89 V, 4.78 V or
## 4.56 V depending only on the sink you assumed, and none of those is an
## answer about the product. Wired to the real sensor head it reports what the
## sensor head actually draws. The same is true in the other direction -- the
## sensor head alone is fed by an assumed ideal-ish supply, and in the system
## it is fed through 80 mohm of regulator output impedance and a cable.
##
## **What this design is really asking.** The 22 uF of bulk sits on the
## carrier, which is where it is convenient to put it, and the sensor head has
## 1.1 uF. At DC that arrangement is fine -- the cable is 40 mohm and the drop
## is arithmetic. It stops being fine somewhere above a few hundred kilohertz,
## because 300 mm of two-wire cable is a few hundred nanohenries and above
## that frequency the bulk capacitor is on the wrong side of an inductor. The
## PDN claim below is made at the **sensor head's** rail, not at the
## carrier's, for exactly that reason: they are not the same rail once the
## cable is in between, and measuring the convenient one would report the
## decoupling as better than the sensor sees it.
##
## The cable is modelled explicitly, as components in this file. A netlist
## carries no length, so nothing else can know it is there -- and joining the
## two boards port-to-port would silently assert a perfect connection.
##
## ## What it found
##
## The first version of the sensor head carried only 1 uF and 100 n of
## ceramic, on the reasoning that the carrier's 22 uF was "the" bulk. Checked
## on its own that board passed comfortably; checked here it failed by an
## order of magnitude:
##
##     designs/sensor_head.nim, on a bench supply    10.00 mohm    exit 0
##     the same board here, on the real cable         8.71 ohm     exit 1
##
## That is not the cable's resistance and it is not a modelling artefact: it
## is the anti-resonance between 300 nH of cable and 886 nF of local ceramic,
## which lands near 1 MHz and peaks at L/(R*C) -- about 8.5 ohm damped by
## nothing but the cable's own 40 mohm. **Neither board could have found it.**
## The carrier's own rail is fine, the sensor head's own decoupling is fine,
## and the defect exists only in the pair.
##
## The fix is one 22 uF tantalum at the head, and a tantalum specifically:
## its 200 mohm of ESR is what damps the peak, where a third ceramic would
## have added charge and left the ringing where it was. Measured after:
## **211 mohm** here, against 9.56 mohm on the bench -- still a factor of 22
## between the two contexts, which is the cable and is real.

import verax/contract/dsl
import verax/verify
import verax/spice/boundary

import ./carrier
import ./sensor_head

let d = design("system_sensor_rig"):
  # `global = true` so both boards sit on one reference. Without it each
  # instance clones a private "0" and every cross-board measurement is
  # meaningless.
  net gnd, kind = ntGround, name = "0", global = true

  net usb, kind = ntPower:                   # host VBUS at the receptacle
    spec:
      voltage = 5.0.V
  net rail_carrier, kind = ntPower:          # the LDO's output, on the carrier
    spec:
      voltage = 3.3.V
  net rail_head, kind = ntPower:             # the same rail, a cable later
    spec:
      voltage = 3.3.V

  # The system's own edge: the host cable plugging into the carrier. What is
  # on the other side of it is stated at the bottom of this file.
  component J0, kind = "connector", partNumber = "USB-C host cable":
    pin "VBUS", usb, kind = ptPower
    pin "GND",  gnd, kind = ptGround

  # --- the two boards ---------------------------------------------------
  # Wired **by name**. Both boards would expose a port called `vin` if they
  # were named alike, and a positional bracket lets two same-shaped nets be
  # swapped with nothing raised and the deck simulating happily.
  instance XC, asSubcircuit(carrierBoard(), "CARRIER"),
           {"vbus": usb, "vout": rail_carrier}
  instance XS, asSubcircuit(sensorHead(), "SENSOR_HEAD"),
           {"vin": rail_head}

  # --- the cable --------------------------------------------------------
  # 300 mm of 28 AWG twisted pair, there and back: about 40 mohm and about
  # 300 nH. The inductance is the interesting half. At 100 kHz it is 190
  # mohm, already comparable with the carrier's bulk ESR; by a megahertz it
  # is 1.9 ohm and the 22 uF might as well not be fitted.
  component RCAB, kind = "resistor", value = "0.04":
    pin "1", rail_carrier, kind = ptPassive
    pin "2", rail_head, kind = ptPassive
  component LCAB, kind = "inductor", value = "300n":
    pin "1", rail_carrier, kind = ptPassive
    pin "2", rail_head, kind = ptPassive

  # --- claims -----------------------------------------------------------

  role "power_rail", host, rail = usb, voltage = 5.0.V, band = 5.pct

  # The carrier's output. 100 mA through 80 mohm of regulator output
  # impedance is 8 mV, so 2% is generous and would still catch a regulator
  # that had lost regulation.
  role "power_rail", carrier_out, rail = rail_carrier,
       voltage = 3.3.V, band = 2.pct

  # The sensor head's rail, which is the one that matters and the one no
  # board-level check could make: it depends on the carrier's regulator, the
  # cable, and the sensor head's own decoupling at once.
  #
  # `targetZ` is claimed here rather than at the carrier deliberately. The
  # band starts at 100 kHz because below that the regulator's own loop is
  # what holds the rail up and this fragment has cut it away.
  role "power_rail", head_rail, rail = rail_head,
       voltage = 3.3.V, band = 3.pct,
       targetZ = 900.mohm, targetFrom = 100.kHz, targetTo = 10.MHz,
       maxDerating = 0.6

  # The DC drop across the cable is arithmetic and worth pinning anyway: it
  # is the half of the problem that does *not* need a simulator, and if it
  # ever fails the topology has changed rather than a model.
  require dc_voltage(rail_head) == 3.29.V, band = 1.pct,
          id = "REQ-RIG-DROP-001",
          because = "100 mA through 40 mohm of cable is 4 mV; a bigger drop " &
                    "means the cable, the connector or the load is not what " &
                    "this system was designed around"

# What is on the other side of the host cable. A host port is not a bench
# supply: 100 mohm and 2 uH is a metre of bus-powered cable, and it is why the
# carrier carries input bulk at all.
driveConnector(findComponent(d.netlist, "J0"),
               {"VBUS": driveSource(5.0.V, rout = 100.mohm, lout = 2.uH)})

quit(verifyMain(d))
