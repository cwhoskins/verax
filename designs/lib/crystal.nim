## A crystal sub-sheet, meant to nest inside an MCU sheet the way a real
## schematic nests a crystal network under its MCU sheet -- generic to any
## crystal spec, not any one board (`designs/datalogger/lib/mcu.nim` is the
## first caller).
##
## `loadCapEach` is the function the plan asked for: given a crystal's own
## specified load capacitance and the board's stray capacitance, it returns
## the value of *each* of the two load capacitors -- not modelled as a SPICE
## crystal (there is no crystal device model in this library, so the network
## is present and unmodelled, exactly as `designs/datalogger/datalogger.nim`'s
## own header records) but real enough to state the right value on the board.
##
## ## The arithmetic
##
## A Pierce oscillator's two load capacitors sit in series as the crystal
## sees them, so their series combination plus whatever stray capacitance
## the board and the MCU's own pins add must equal the crystal's specified
## `CL`:
##
##     CL = (Cx * Cx) / (Cx + Cx) + Cstray = Cx/2 + Cstray
##
## which inverts to `Cx = 2 * (CL - Cstray)` for equal load capacitors --
## the standard result (ST AN2867, and every other crystal application note
## that assumes C1 = C2). `Cstray` is a board fact this module cannot see
## any more than `pcb/tline.characterize`'s `roughness` can, so a caller who
## leaves it at the default here is trusting an estimate, not a measurement.

import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat

type
  CrystalSpec* = object
    freq*: Hertz
    cl*: Farads
      ## The crystal's own specified load capacitance -- a datasheet figure,
      ## not something this module invents.
    cStray*: Farads
      ## Board trace + MCU pin stray capacitance per side. 3 pF is the usual
      ## rule-of-thumb figure crystal application notes quote for a compact
      ## layout; state a real one when the board's own layout is known.
    esr*: Ohms
      ## Not used by `loadCapEach` -- carried here because it is the other
      ## number a crystal's datasheet states and a BoM line should carry, not
      ## because anything in this module reads it.

proc hse8MHz*(cl = 18.0.pF): CrystalSpec =
  ## A representative 8 MHz HSE crystal (NDK/Abracon-class, `CL` = 18 pF is
  ## the common spec at this frequency). `verify` HSE crystal against the
  ## part actually specified before trusting this as more than a stand-in.
  CrystalSpec(freq: 8.0.MHz, cl: cl, cStray: 3.0.pF, esr: 60.0.ohm)

proc loadCapEach*(spec: CrystalSpec): Farads =
  ## The value of *each* load capacitor -- see this module's own header for
  ## the derivation. Clamped at zero rather than allowed to go negative,
  ## which would otherwise happen silently for a `cStray` stated larger than
  ## `cl` and mean the crystal cannot be brought into spec with two equal
  ## caps at all.
  let want = 2.0 * (float(spec.cl) - float(spec.cStray))
  Farads(max(0.0, want))

proc crystalNetwork*(spec: CrystalSpec): Netlist =
  ## Ports: `XIN`, `XOUT`, `GND`. An MCU sheet instances this once, wired to
  ## the MCU's own OSC_IN/OSC_OUT pins -- `designs/datalogger/lib/mcu.nim` is
  ## the first.
  let cx = loadCapEach(spec)

  result = subckt("HSE_XTAL", [XIN, XOUT, GND]):
    net GND,  kind = ntGround, name = "0"
    net XIN,  kind = ntSignal
    net XOUT, kind = ntSignal

    component Y1, kind = "crystal", value = spiceValue(float(spec.freq)):
      pin "1", XIN,  kind = ptPassive
      pin "2", XOUT, kind = ptPassive
      spec:
        esr = spec.esr

    component CX1, kind = "capacitor", value = spiceValue(float(cx)):
      pin "1", XIN, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V
    component CX2, kind = "capacitor", value = spiceValue(float(cx)):
      pin "1", XOUT, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V
