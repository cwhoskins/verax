## What each pin of a part is *allowed* to be: `PA5` on an STM32H563 can be
## `SPI1_SCK`, `TIM2_CH1`, `ADC1_IN5` or GPIO, never `SPI3_SCK`. Routing a
## signal to a pin that can't mux it is a board respin; this lets `verax
## check` catch it.
##
## **Stored as namespaced `attrs`**, so assignments survive clone, flatten
## and isolation. **Tables are a registry of pure data with no built-ins**
## (like `PackageDef`); designs supply the catalogue from datasheets.
##
## Decisions:
##
## 1. *Explicit declaration, not inference*: a `port` states
##    `peripheral = "SPI1"`, so a bad pin can be named and two ports can't
##    silently both claim SPI1.
## 2. *A `nil` table checks nothing* -- parts without a pinmux are
##    unaffected.
## 3. *`functions =` on a wide signal*: SPI1 has one hardware NSS; extra CS
##    lines are GPIO (`functions = {"cs_1": "GPIO"}`).
##
## A SPICE round trip loses all of this.

import std/[strutils, tables]

import ./types
import ./graph
import ./issue

export issue

# --- the model ------------------------------------------------------------

type
  PinCapability* = object
    ## One thing a pin can be. `peripheral` is "" for a function not tied to
    ## a peripheral instance (`GPIO`, bare analog).
    peripheral*: string       ## "SPI1"
    signal*: string           ## "sclk", "in3", "GPIO"

  PeripheralDef* = object
    name*: string             ## "SPI1"
    iface*: string            ## InterfaceDef name ("spi"); "" when not an
                              ## interface (a bare ADC)

  PartPinmux* = ref object
    name*: string                                  ## registry key, "STM32H563"
    partNumbers*: seq[string]                      ## part numbers it covers
    doc*: string
    complete*: bool
      ## When true, a used pin missing from the table is an error, not a
      ## warning: the table claims the whole pinout.
    peripherals*: OrderedTable[string, PeripheralDef]
    pins*: OrderedTable[string, seq[PinCapability]]
    attrs*: OrderedTable[string, string]

const
  pinmuxPrefix* = "pinmux."
  keyPinmuxDef* = "pinmux.def"            ## overrides part-number resolution
  keyPinmuxPeripheral* = "pinmux.peripheral"  ## the peripheral a pin was wired as
  keyPinmuxSignal* = "pinmux.signal"          ## the signal it carries

proc parseFunction*(s: string): PinCapability =
  ## `"SPI1.sclk"` -> `(peripheral: "SPI1", signal: "sclk")`; no `.` means a
  ## peripheral-less function (`"GPIO"`). Splits on the **last** dot.
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
  ## Build a table from a datasheet: one `(name, iface)` per peripheral,
  ## one `(pin, "PERIPH.sig")` per capability; repeated pins accumulate.
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
  ## Raises on an empty or duplicate name, a duplicate or claimed part
  ## number, a capability naming an undeclared peripheral, or a duplicate
  ## capability on one pin.
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
  ## The table governing `c`: its `pinmux.def`, else the table claiming
  ## `c.partNumber`, else `nil`.
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
  ## Record pin `p`'s function (`"ADC1.in3"`, `"GPIO"`); the runtime side of
  ## `pin "PA3", net, function = "..."`.
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
  ## Problems with how the design uses its parts' pins, as `pinmux_*`
  ## `Issue`s.
  for c in walkComponents(root(nl)):
    let def = pinmuxFor(c)
    if def == nil: continue

    # Bookkeeping for the two "claimed twice" checks.
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
