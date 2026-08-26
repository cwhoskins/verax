# `parts` submodule

`src/nimcir/parts/` answers a question the netlist layer deliberately does not:
given that a circuit needs 22.5 nF *here*, which capacitor is that. It depends on
`nimcir/units` and `nimcir/netlist`; neither depends back on it, and no analysis
requires it — a design annotating its parts by hand never imports it.

**The asymmetry it exists for.** A parameterized module (`sallenKeyLP(fc, r, q)`)
computes that it needs 22.5 nF and cannot compute what part that is: the choice
depends on rail voltage, temperature range, space and cost, none of which the
module can see. But the *board* cannot choose either, because it cannot see which
of the module's capacitors sets a corner and which is a bypass — and that
distinction is decisive, since a timing capacitor must be Class 1 (a Class 2
dielectric loses capacitance to DC bias and temperature, moving the corner) while
a decoupling capacitor should be Class 2, which is where the density is. **The
module knows the part's function, the board knows its environment, and neither can
choose the part alone.** So the module states a `CapRequest`/`ResRequest`/
`IndRequest` carrying a value and a *use*, and the board supplies a `PartPolicy`
that returns a `Choice`. Both rejected alternatives fail concretely: per-component
builder parameters (`c1Package`, `c1Dielectric`, …) multiply out with every part
*and* still leave the board guessing at function, while a pass that annotates
afterwards loses `spec:`'s compile-time checking and must address parts by
generated name.

`PartPolicy` holds **procs on a data object**, like `RoleDef`, so a policy built at
runtime from a preferred-parts database behaves identically to the built-in one; a
`nil` member means the policy has nothing to say about that kind of part and the
caller leaves the component unannotated rather than inventing something.
**`parts/series.nim` is the other half of the same question** -- not which *kind* of part, but which of the values that part is sold in. It holds the preferred-value ladders (`seriesE12`/`seriesE24`/`seriesE96`), `nearest` (by *ratio*, since the ladder is geometric and the tolerance a part is bought at is a percentage, with the next decade's first value as a candidate so a mantissa just under ten rounds up), and the `PreferredSeries` proc-valued hook a builder takes -- `exactSeries` (the default: rounds nothing, the position `designs/lib/filters.nim` states) plus `e12`/`e24`/`e96`. **The tables are written out, not computed**: seven of E24's twenty-four values deviate from `10^(n/24)` through the middle of the decade, so a computed ladder is a plausible list of numbers nobody sells. Two things a test pins that the names do not say -- 240 R is an E24 value and *not* an E96 one, so rounding a resistance the designer stated moves it to 243 R and takes a divider's ratio with it; and E96's worst gap is 1.33 -> 1.37, a 3.01% step, so rounding costs up to **1.49%** rather than the 1.2% `10^(1/96)` suggests.

`policy.defaultPolicy()` draws the same line `spice/models` draws for stand-in
values — **guess where the guess is forced, refuse where it is a choice**: C0G for
a timing part is physics and is defaulted silently; X7R for a decoupling part is a
judgement and is defaulted *and noted every time*; a voltage rating is derived from
the working voltage when the module states one and **left unset when it does not**,
because a coupling capacitor in an unbiased stage genuinely has no known working
voltage and inventing one would invent the circuit. `annotate.applyChoice` writes a
`Choice` as ordinary **registered** annotations with `annDerived` provenance — what
a policy decided is visible exactly as a hand-typed `spec:` block would be, and a
mechanism whose output could only be understood by re-reading the mechanism would
be worse than typing the values out.

Note what the builder does **not** pass for its bypass capacitors: `working`. It
does not know the supply, and does not need to — `spice/models` computes the DC
across each capacitor from the netlist at simulation time, when rail voltages are
stated. The policy answers "what kind of part", the netlist answers "what is across
it", and neither has to know the other's business.
