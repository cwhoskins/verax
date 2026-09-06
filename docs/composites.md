# Composite motif ideas beyond `parallel-stack`

**Shipped since this brainstorm was written:** `compositeKinds`
(`schematic/composites/composite.nim`) now registers four motifs —
`parallelStackKind` (`passive.nim`), plus `piKind` (`pi.nim`), `teeKind`
(`tee.nim`) and `seriesChainKind` (`passive.nim`). **pi** is idea 3 ("shunt
pair flanking any part"): a flat two-terminal series part with a
shunt-to-ground flat two-terminal part at each end, drawn series-horizontal
with a shunt dropping to ground from each pin. **tee** is idea 2 (series
chain with the midpoint tapped), tapped to ground: two flat two-terminal
series parts meeting at a *private* mid node that also carries one
shunt-to-ground part, drawn as a horizontal row with the shunt on the midline.
**series chain** is idea 1: flat two-terminal *passive* parts wired end to end
through private two-pin **link nets** (neither ground, rail, nor a declared
interface port) become one horizontal row, with one composite port per link
net and the two free ends left as ordinary router endpoints. A cycle in the
link graph is declined rather than cut; there is no length cap. All four stay
topology-only, all exclude a source as a member, and pi requires its two
external nets to reach beyond the composite so a real tee is not misread as a
pi around one of its series legs. `compositePlan` folds the kinds in
registration order (parallel, pi, tee, then series chain), dropping any group
whose members an earlier kind claimed — the non-nesting subset of
`composite_placement_stage2.md` §2.6. Registering the chain last means a
pi/tee series leg that also reads as a chain link keeps the canonical filter
drawing. A **series-of-parallels** (a chain whose members are themselves
parallel banks, or vice versa) still needs the arena-index nesting fold §2.6
does not yet do.

**Unit orientation (shipped):** each `CompositeKind` now carries an
`orientable` flag. `internalLayout` still authors a single *canonical* frame,
but for an orientable kind — the parallel stack and the series chain — the
`lsCompositeOrient` stage picks a rigid 0/90/180/270 turn of the whole unit
(`PlaceableItem.unitRot`), and the definitive orient pass revisits it once
centres are settled. The horizontal row / vertical stack the descriptions
below give is therefore the canonical frame, not the final one: a chain whose
endpoints sit above and below it will be drawn as a vertical column. The pi
and the tee are **not** orientable — their shunt legs run to ground and
ground-points-down is a real convention, not a wirelength trade — so idea 3
below stays pinned, but idea 2 (the vertical voltage-divider frame) is the
first idea this unblocks: it can be authored horizontal-canonical and left to
`lsCompositeOrient` to stand up. See `composite_placement_stage2.md` §2.7.

The rest of this file is the original brainstorm of what else fits the same
`CompositeKind` contract (a pure-topology `recognize` over `comps`/`syms`, plus
`internalLayout`/`externalPins`/`pickRepresentative`/`internalRoute`/
`rotationCandidates`/`footprint`), roughly ordered by how much new machinery
each would need. The remaining ideas are uncommitted; a nesting kind (one that
consumes an earlier composite as a member) still needs the arena-index fold
`compositePlan` does not yet do — see `composite_placement_stage2.md` §2.6.

**Ground rule carried through every idea below**: `recognize` must stay
topology-only, the same discipline `isTraversable` already documents. For a
multi-pin active part that means keying off **`Pin.kind`**
(`ptInput`/`ptOutput`/`ptPower`/`ptGround`) — the same field `portDirection`
already trusts — never off `Component.kind` spelling or a pin's *name*.
`Component.kind` for actives has no fixed vocabulary in this codebase: the
DSL doc comment uses `"regulator_ic"` while `designs/sensor_node.nim` actually
writes `"regulator"`, and `symbols.nim` only special-cases
`"bjt"/"mosfet"/"jfet"/"transistor"` (three *positional* slots — top/left/
right, not named base/gate/emitter) and `"diode"/"led"/"zener"`; `"opamp"` and
any regulator string fall through to the generic fallback box. So "which
string is in `kind`" is not a recognizer anyone should build on; "which
pin-kind sits on which net" is.

## Passive motifs

1. **Series chain** — *shipped* as `seriesChainKind` (`passive.nim`).
   Two-terminal passive parts wired end-to-end with no other branches at the
   shared node (R+C snubber, LED+resistor). `parallelRecognize` only catches
   parts sharing the *identical* net pair; this is the complementary case —
   chained, not paralleled. Lays out as a horizontal row; the two free ends
   stay ordinary router endpoints (a ground/rail end still draws its own
   glyph), each internal link net is a fully-internal composite port. Still
   non-nesting: a chain member is always a raw singleton, so a
   series-of-parallels needs the §2.6 arena-index fold.

2. **Voltage divider / termination pair** — two two-terminal parts in series
   between two fixed nets (rail/ground, or two signal rails) with the midpoint
   tapped to a third net. A 3-port composite: two ends plus the tap. Its
   textbook frame is vertical with the tap escaping sideways, but with
   `orientable` + `lsCompositeOrient` shipped it can be authored the same
   horizontal-canonical way the series chain is and left to the orient stage
   to stand upright where a rail sits above and ground below. Reused below as
   the bias-ladder shape for active stages.

3. **Crystal/resonator + load caps** (generalizes to: **shunt pair flanking
   any part**) — a part with two caps, each from one of its terminals to
   ground. Purely `isGround`-topology, no naming needed. Canonical fixed
   layout (centre part flanked by its two grounded caps) is closer to real
   convention than what force layout alone produces. Generalizes cleanly to
   any multi-pin part with a cap from each `ptPower` pin to ground (see
   active idea 4 below) — worth building once, not twice.

4. **Star/fan-out pack** — multiple two-terminal parts sharing one *common*
   net (a rail or bus enable) but each going to a *distinct* second net
   (I2C/SPI pull-up packs, bus terminators). `recognize` is still pure
   topology (group by the shared net), but `externalPins`/`internalLayout`
   need real work: N external ports instead of today's fixed 1–2, laid out as
   a comb aligned to the fanned nets.

5. **Ordered bus resistor network** — a bijection between two same-width net
   families (e.g. address-bus series terminators, `A[0..7]` to `A_BUF[0..7]`).
   The one idea on this list that would need a naming-pattern heuristic
   (common prefix + numeric suffix) to establish pairing order — the only
   place where `recognize` would depend on net *names*, breaking the
   topology-only discipline `isTraversable`'s doc comment states. Listed last
   for that reason.

## Active / mixed motifs

6. **Feedback bridge** — a two-terminal part (or a short series chain of
   them, idea 1) whose two ends land on one active part's `ptOutput` net and
   one of its `ptInput` nets. Covers inverting/non-inverting op-amp feedback,
   comparator hysteresis, and lag/lead compensation (R, C, or R+C in series)
   with one recognizer — "which input" falls out of which `ptInput` pin the
   far end lands on. Canonical layout: the bridge drawn arcing over the
   active part, not wherever force layout drops it.

7. **Bias ladder at a control terminal** — idea 2 (the voltage-divider
   composite), specifically recognized when its midpoint net is also an
   active part's `ptInput` pin. Not new hook shape, just idea 2 anchored to an
   active terminal — covers a BJT/MOSFET base/gate bias network and a
   regulator's FB divider with the same recognizer.

8. **Load / degeneration resistor at a terminal** — a single two-terminal
   part from one of an active part's pins straight to a rail (`ptPower`) or
   straight to ground. Covers a collector/drain pull-up and an
   emitter/source degeneration resistor on a transistor, and a regulator's
   bulk decoupling cap on its supply pin, with the same shape: "one hop from
   an active pin to a fixed net."

9. **IC bulk-decoupling pair** — idea 3 generalized off crystals: any
   multi-pin part with a cap from each `ptPower` pin to ground. Same
   recognizer and layout as idea 3, just not restricted to a crystal's
   `Component.kind`.

10. **Switch-node star (buck/boost cell)** — inductor + diode/sync-FET +
    output cap all meeting at one net that is also a regulator's switch pin.
    Structurally clean *if* the regulator marks its switch pin `ptOutput` (or
    a dedicated kind) — worth checking whether `designs/lt8640a_buck.nim`
    actually does this consistently before trusting the recognizer. Listed as
    plausible-not-solid for that reason.

11. **Current mirror / differential pair** — two same-kind transistors
    commoned on one terminal's net. Recognizable as "two 3-terminal actives
    sharing one pin's net" structurally, but telling a mirror apart from a
    diff pair apart from two transistors that merely share a ground return
    needs more than connectivity — likely `attrs["value"]`/model matching,
    a step beyond anything an existing recognizer does. Speculative; would
    want prototyping against a couple of real designs before committing to a
    hook shape.

## Single-transistor amplifier stages (CE/CB/CC, CS/CG/CD)

A textbook single-transistor stage is really ideas 7 + 8 + a coupling/bypass
detail applied together around one 3-terminal active part, so it is written
up as one composite family rather than three separate ones. All three BJT
configurations (and their FET analogues — common-source/-gate/-drain) share
one recognizer skeleton: find a 3-terminal active part, classify each of its
three pins by what is structurally hanging off it, and let *that* pattern —
never a `Component.kind` string, never a pin name like `"base"`/`"gate"` —
decide which configuration it is:

- **Common-emitter / common-source** — base/gate reached only through a bias
  ladder (idea 7); emitter/source has a degeneration resistor to ground
  (idea 8) with a bypass capacitor in parallel across that same resistor
  (same two nets, recognized the way `parallelRecognize` already recognizes a
  parallel pair); collector/drain has a load resistor up to a rail (idea 8).
  The bypass cap is the structural tell that this pin is the *AC* ground even
  though it is biased above ground DC-wise — without it, the same skeleton is
  just an unbypassed (lower-gain) CE/CS stage, still worth recognizing as the
  same motif.
- **Common-collector / common-drain (follower)** — same base/gate bias
  ladder; collector/drain ties *directly* to a rail net with no series part
  at all (the absence of idea 8's load resistor on that pin is itself the
  signal); output is taken from the emitter/source, which carries a load
  resistor to ground instead. No bypass cap anywhere — the emitter/source is
  the signal path, not an AC ground.
- **Common-base / common-gate** — base/gate reached through a bias ladder
  *and* a capacitor straight to ground (the AC-ground tell, on the control
  pin this time rather than the emitter/source); input is coupled into the
  emitter/source through a series capacitor (idea 1's chain shape, one link
  long); output is taken from the collector/drain through its load resistor.

Recognition confidence mirrors idea 6 above: everything here is expressible
as "which of the three pins has a bias ladder, which has a direct rail tie,
which has a bypass/coupling cap to ground or in series" — pure connectivity
over `Pin.kind` and existing two-terminal parts, no value comparison and no
name guessing. The genuinely new piece needed beyond ideas 1/7/8 is just the
bypass-cap detector (a cap sharing both nets with an already-recognized
degeneration or bias resistor) and the direct-rail-tie detector (a pin with
*no* intervening two-terminal part at all) — both small, both structural.
Layout-wise this is also where a fixed canonical drawing earns the most: the
textbook stage picture (bias divider upper-left, bypass cap tucked under the
degeneration resistor, load resistor straight up to the rail) is a large
legibility win over whatever the general force layout would produce for the
same five-to-seven-part cluster.

As with idea 11, the risk is over-recognition: a bias ladder plus a load
resistor plus *some* cap to ground near a transistor is common enough to
false-positive on circuits that are not actually a clean single-stage
amplifier (a transistor used as a switch with an unrelated nearby decoupling
cap, for instance). Any real implementation would want a corpus of actual
amplifier-stage designs to check the recognizer against before trusting it
the way `parallelRecognize` is trusted today.
