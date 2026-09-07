## What each pin of a part is *allowed* to be.
##
## An MCU pin is not a blank terminal. `PA5` on an STM32H563 can be `SPI1_SCK`
## or `SPI2_SCK` or `TIM2_CH1` or `ADC1_IN5` or a plain GPIO -- and it can never
## be `SPI3_SCK`. Nothing in the netlist said so, so a design that wired
## `{"sclk": "SPI1_SCK"}` was believed whatever string the author typed. Routing
## a clock to a pin the silicon cannot mux it onto is a board respin; this is
## the statement that lets `verax check` catch it before the gerbers ship.
##
## **It stores its data in namespaced `attrs` and adds nothing to `types.nim`**,
## the choice `packages.nim` and `environment.nim` make and for the same reason:
## `graph.clone` copies `attrs` verbatim at every hierarchy level, so a pin's
## assigned function survives `clone`/`instantiate`/`flatten`/`isolate` with no
## new code, whereas a registry of direct `Pin` references would need remapping
## written and tested across every one of those transforms.
##
## **The table is a definition registry keyed by name, with no built-ins.**
## Same shape as `PackageDef`: a runtime `OrderedTable` of pure data (a pinmux
## computes nothing, so it holds no procs and could later be read from a file),
## and `designs/lib/` owns the catalogue because every real capability table is a
## specific part number transcribed from a specific datasheet.
##
## **Three decisions worth stating rather than discovering.**
##
## 1. *Explicit declaration, not inference.* A `port` states
##    `peripheral = "SPI1"`. Intersecting the candidate peripheral sets of every
##    pin in a port would often work, but an empty intersection cannot name
##    which pin is the offender, and it silently accepts two independent ports
##    that both resolve to SPI1. A direct table lookup does both.
## 2. *A `nil` table means "check nothing", never "nothing is allowed".* A part
##    with no registered pinmux -- which is every part in every existing design
##    -- is completely unaffected.
## 3. *`functions =` on a wide signal exists because a hardware NSS is one pin.*
##    An MCU's SPI1 has a single hardware chip select; a second or third CS line
##    is a software GPIO, genuinely not an SPI1 function, and must not be checked
##    as one. `functions = {"cs_1": "GPIO"}` on the `port` says which members are
##    which.
##
## A SPICE round trip loses all of this, as it loses `package.*` -- `attrs`
## never reach a deck. A consumer that needs the capability data keeps the Nim
## source.

import std/[strutils, tables]

import ./types
import ./graph
import ./issue

export issue

# --- the model ------------------------------------------------------------

type
  PinCapability* = object
    ## One thing a pin can be. `peripheral` is "" for a function that is not
    ## tied to a numbered peripheral instance (`GPIO`, and by convention a bare
    ## analog function).
    peripheral*: string       ## "SPI1"
    signal*: string           ## "sclk", "in3", "GPIO"

  PeripheralDef* = object
    name*: string             ## "SPI1"
    iface*: string            ## InterfaceDef name it presents ("spi"); "" when
                              ## the peripheral is not an interface (a bare ADC)

  PartPinmux* = ref object
    name*: string                                  ## registry key, "STM32H563"
    partNumbers*: seq[string]                      ## part numbers it covers
    doc*: string
    complete*: bool
      ## When true, a pin the design uses that this table does not list is an
      ## error rather than a warning: the table claims to be the whole pinout.
    peripherals*: OrderedTable[string, PeripheralDef]
    pins*: OrderedTable[string, seq[PinCapability]]
    attrs*: OrderedTable[string, string]

const
  pinmuxPrefix* = "pinmux."
  keyPinmuxDef* = "pinmux.def"            ## overrides part-number resolution
  keyPinmuxPeripheral* = "pinmux.peripheral"  ## the peripheral a pin was wired as
  keyPinmuxSignal* = "pinmux.signal"          ## the signal it carries

proc parseFunction*(s: string): PinCapability =
  ## `"SPI1.sclk"` -> `(peripheral: "SPI1", signal: "sclk")`; a string with no
  ## `.` is a peripheral-less function (`"GPIO"`). Split on the **last** dot, so
  ## a signal name may itself contain one.
  let idx = s.rfind('.')
  if idx < 0: PinCapability(peripheral: "", signal: s)
  else: PinCapability(peripheral: s[0 ..< idx], signal: s[idx + 1 .. ^1])

proc `$`*(cap: PinCapability): string =
  if cap.peripheral.len == 0: cap.signal
  else: cap.peripheral & "." & cap.signal

proc newPartPinmux*(name: string,
                    peripherals: openArray[tuple[name, iface: string]],
                    pins: openArray[tuple[pin, function: string]],
                    partNumbers: openArray[string] = [],
                    doc = "", complete = false): PartPinmux =
  ## Build a table from a datasheet transcription: one `(name, iface)` per
  ## peripheral instance, one `(pin, "PERIPH.sig")` per capability. Repeated
  ## `pin` entries accumulate, so a pin with five alternate functions is five
  ## lines.
  result = PartPinmux(name: name, doc: doc, complete: complete,
                      partNumbers: @partNumbers)
  for (pName, iface) in peripherals:
    result.peripherals[pName] = PeripheralDef(name: pName, iface: iface)
  for (pin, function) in pins:
    let cap = parseFunction(function)
    if not result.pins.hasKey(pin): result.pins[pin] = @[]
    result.pins[pin].add cap

# --- registry ------------------------------------------------------------

var
  pinmuxRegistry: OrderedTable[string, PartPinmux]
  pinmuxByPartNumber: OrderedTable[string, string]   ## part number -> registry key

proc validateDef(def: PartPinmux) =
  if def.pins.len == 0:
    raise newException(NetlistError,
      "pinmux '" & def.name & "' lists no pins")
  var seenPn: OrderedTable[string, int]
  for pn in def.partNumbers:
    seenPn[pn] = seenPn.getOrDefault(pn, 0) + 1
    if seenPn[pn] > 1:
      raise newException(NetlistError,
        "pinmux '" & def.name & "' lists part number '" & pn & "' twice")
    if pinmuxByPartNumber.hasKey(pn):
      raise newException(NetlistError,
        "pinmux '" & def.name & "' claims part number '" & pn &
        "', already covered by pinmux '" & pinmuxByPartNumber[pn] & "'")
  for pin, caps in def.pins:
    var seen: OrderedTable[string, int]
    for cap in caps:
      if cap.peripheral.len > 0 and not def.peripherals.hasKey(cap.peripheral):
        raise newException(NetlistError,
          "pinmux '" & def.name & "' pin '" & pin & "' names peripheral '" &
          cap.peripheral & "', which the table does not declare")
      let k = $cap
      seen[k] = seen.getOrDefault(k, 0) + 1
      if seen[k] > 1:
        raise newException(NetlistError,
          "pinmux '" & def.name & "' pin '" & pin & "' lists capability '" &
          k & "' twice")

proc knownPinmuxes*(): seq[string] =
  for k in pinmuxRegistry.keys: result.add k

proc registerPartPinmux*(def: PartPinmux) =
  ## Raises on an empty or duplicate name, a duplicate or already-claimed part
  ## number, a capability naming an undeclared peripheral, or a capability
  ## listed twice on one pin.
  if def == nil or def.name.len == 0:
    raise newException(NetlistError, "pinmux definition must have a name")
  if pinmuxRegistry.hasKey(def.name):
    raise newException(NetlistError,
      "pinmux '" & def.name & "' is already registered")
  validateDef(def)
  pinmuxRegistry[def.name] = def
  for pn in def.partNumbers: pinmuxByPartNumber[pn] = def.name

proc isPinmuxRegistered*(name: string): bool = pinmuxRegistry.hasKey(name)

proc pinmuxDef*(name: string): PartPinmux =
  if not pinmuxRegistry.hasKey(name):
    raise newException(NetlistError,
      "no such pinmux: " & name &
      (if knownPinmuxes().len > 0: " (known: " & knownPinmuxes().join(", ") & ")"
       else: " (none registered)"))
  pinmuxRegistry[name]

proc pinmuxFor*(c: Component): PartPinmux =
  ## The capability table that governs `c`: `pinmux.def` on the component if it
  ## names one, else the table that claims `c.partNumber`, else `nil`.
  if c == nil: return nil
  if c.attrs.hasKey(keyPinmuxDef):
    let n = c.attrs[keyPinmuxDef]
    if pinmuxRegistry.hasKey(n): return pinmuxRegistry[n]
    return nil
  if c.partNumber.len > 0 and pinmuxByPartNumber.hasKey(c.partNumber):
    return pinmuxRegistry[pinmuxByPartNumber[c.partNumber]]
  nil

# --- authoring helpers ---------------------------------------------------

proc setPinFunction*(p: Pin, function: string) =
  ## Record that pin `p` is being used as `function` (`"ADC1.in3"`, `"GPIO"`).
  ## The runtime side of the DSL's `pin "PA3", net, function = "..."`.
  let cap = parseFunction(function)
  if cap.peripheral.len > 0: p.attrs[keyPinmuxPeripheral] = cap.peripheral
  p.attrs[keyPinmuxSignal] = cap.signal

# --- validation --------------------------------------------------------

iterator walkComponents(nl: Netlist): Component =
  var stack = @[nl]
  while stack.len > 0:
    let cur = stack.pop()
    for _, c in cur.components: yield c
    for _, child in cur.children: stack.add child

proc partLabel(c: Component): string =
  if c.partNumber.len > 0: c.designator & " (" & c.partNumber & ")"
  else: c.designator

proc offeredList(caps: seq[PinCapability]): string =
  var xs: seq[string]
  for cap in caps: xs.add $cap
  if xs.len == 0: "nothing" else: xs.join(", ")

proc validatePinmux*(nl: Netlist): seq[Issue] =
  ## What the capability tables say is wrong with how the design uses its parts'
  ## pins. An `Issue` per finding, never a raise; kinds are prefixed `pinmux_`.
  for c in walkComponents(root(nl)):
    let def = pinmuxFor(c)
    if def == nil: continue

    # Per-component bookkeeping for the two "same thing claimed twice" checks.
    var ownersOf: OrderedTable[string, seq[string]]   ## peripheral -> iface instances
    var pinsFor: OrderedTable[string, seq[string]]    ## "SPI1.sclk" -> pin names

    for pinName, p in c.pins:
      if not p.attrs.hasKey(keyPinmuxSignal): continue
      let signal = p.attrs[keyPinmuxSignal]
      let peripheral = p.attrs.getOrDefault(keyPinmuxPeripheral)
      let ifaceInst = p.attrs.getOrDefault("iface.instance")
      let ifaceDef = p.attrs.getOrDefault("iface.def")

      if peripheral.len > 0:
        if ownersOf.hasKey(peripheral):
          if ifaceInst notin ownersOf[peripheral]: ownersOf[peripheral].add ifaceInst
        else:
          ownersOf[peripheral] = @[ifaceInst]
        let fk = peripheral & "." & signal
        if pinsFor.hasKey(fk):
          if pinName notin pinsFor[fk]: pinsFor[fk].add pinName
        else:
          pinsFor[fk] = @[pinName]

      if not def.pins.hasKey(pinName):
        result.add newIssue("pinmux_pin_unknown",
          (if def.complete: sevError else: sevWarning),
          partLabel(c) & " pin '" & pinName & "' is not in the '" & def.name &
          "' capability table" &
          (if def.complete: "" else: " (table is partial)"),
          pins = @[p], components = @[c])
        continue

      if peripheral.len > 0 and not def.peripherals.hasKey(peripheral):
        var have: seq[string]
        for k in def.peripherals.keys: have.add k
        result.add newIssue("pinmux_peripheral_unknown", sevError,
          partLabel(c) & " pin '" & pinName & "' is wired as peripheral '" &
          peripheral & "', which '" & def.name & "' does not declare" &
          (if have.len > 0: " (it has: " & have.join(", ") & ")" else: ""),
          pins = @[p], components = @[c])
        continue

      if peripheral.len > 0 and ifaceDef.len > 0 and
         def.peripherals[peripheral].iface != ifaceDef:
        let pi = def.peripherals[peripheral].iface
        result.add newIssue("pinmux_peripheral_kind_mismatch", sevError,
          partLabel(c) & " pin '" & pinName & "' is on interface '" & ifaceDef &
          "' but peripheral '" & peripheral & "' is " &
          (if pi.len == 0: "not an interface" else: "interface '" & pi & "'"),
          pins = @[p], components = @[c])
        continue

      var offers = false
      for cap in def.pins[pinName]:
        if cap.peripheral == peripheral and cap.signal == signal:
          offers = true; break
      if not offers:
        let want = (if peripheral.len == 0: signal else: peripheral & "." & signal)
        result.add newIssue("pinmux_incapable", sevError,
          partLabel(c) & " pin '" & pinName & "' cannot be " & want &
          "; it offers: " & offeredList(def.pins[pinName]),
          pins = @[p], components = @[c])

    for peripheral, owners in ownersOf:
      if owners.len > 1:
        var named: seq[string]
        for o in owners: named.add (if o.len == 0: "(standalone)" else: o)
        result.add newIssue("pinmux_peripheral_double_booked", sevError,
          partLabel(c) & " peripheral '" & peripheral &
          "' is claimed by more than one port: " & named.join(", "),
          components = @[c])

    for fk, pinNames in pinsFor:
      if pinNames.len > 1:
        result.add newIssue("pinmux_function_duplicated", sevError,
          partLabel(c) & " function '" & fk &
          "' is assigned to more than one pin: " & pinNames.join(", "),
          components = @[c])
