## The typed Touchstone model: the S-parameter matrix a `.sNp` file states,
## plus the scalar conversions reading one requires.
##
## This is a *transcription*, not an interpretation, the same line
## `verax/ibis/types` draws: the reader (`verax/touchstone/reader`) fills
## `SParams` from the file and checks little beyond "the file is
## well-formed"; deciding whether a return loss is *acceptable* is a
## consumer's job, not this module's.
##
## **The scalar conversions live here, with the type, rather than in
## `verax/analysis/measure`.** That module's ~20 procs are uniformly
## vectorised curve math over a swept axis (`corner3dB`, `interpCrossing`,
## `unityGainFreq`) with no scalar, no-axis case among them -- `gammaOf` and
## `vswrOf` take one complex or real number and return one, which is a
## different shape of problem, and forcing it into `measure` would be the
## first entry there answering a question `measure`'s own doc never poses.
##
## **One naming decision worth stating explicitly, because this codebase
## already treats exactly this kind of ambiguity as a defect elsewhere** (the
## SPICE magnitude-suffix rejection in `netlist/annotations.parseAnnFloat` is
## the precedent, and `netlist/formats/spice.parseSpiceMagnitude`'s RKM
## refusal is the same shape again): a "convert this ratio to dB" proc means
## two different things depending on whether the ratio is a *power* ratio or
## a *voltage/amplitude* ratio. An S-parameter is a ratio of voltage
## *waves* (20*log10), while `gain_db`/Friis/cascade arithmetic is a ratio of
## *powers* (10*log10). Folding both into one `dbToLinear`/`linearToDb` pair
## would work right up until someone fed an S21 magnitude into the power-ratio
## half and read a return loss twice as generous as the real one -- a silent
## factor-of-2 error in dB, buried inside a "convenience". So this module
## exports two distinctly-named pairs and never a generic one.

import std/[complex, math]

type
  TouchstoneError* = object of CatchableError
    ## Raised by the reader on malformed input. `msg` carries line context
    ## wherever the reader can supply it, matching `IbisError`.

  SParams* = object
    ## One frequency-swept S-parameter matrix, as read from a `.sNp` file.
    nPorts*: int
    z0*: float
      ## The reference impedance, ohms -- one value for the whole file.
      ## Touchstone version 2 allows a distinct impedance per port; that is
      ## a v2 feature this reader does not implement, so every port here
      ## shares `z0`.
    freqs*: seq[float]
      ## Hz, ascending -- the option line's frequency unit is applied here so
      ## every consumer downstream of this type sees Hz regardless of
      ## whether the file said `GHZ` or `MHZ`.
    points*: seq[seq[Complex64]]
      ## `points[k]` is the matrix at `freqs[k]`, `nPorts*nPorts` entries in
      ## row-major order (`i*nPorts + j` is Sij). This is **not** how a
      ## 2-port file stores its own columns on disk (that order is
      ## S11/S21/S12/S22, column-major for a 2x2) -- normalising both the
      ## 2-port historical order and the general N-port row-major order into
      ## one convention here is `reader.nim`'s job, so nothing downstream of
      ## this type has to know which file shape produced it.

proc sAt*(sp: SParams, k, i, j: int): Complex64 =
  ## Sij at sample `k` (both `i`/`j` 0-based). The row-major index arithmetic
  ## lives in exactly one place so no caller re-derives it and gets the
  ## 2-port column order backwards.
  sp.points[k][i * sp.nPorts + j]

# --- dB <-> linear, kept as two pairs never one -------------------------

proc powerRatioToDb*(x: float): float {.inline.} =
  ## `10 * log10(x)` -- the *power*-ratio dB used everywhere a gain, a noise
  ## figure or an intercept point is stated (`gain_db`, Friis, cascade
  ## arithmetic). Not what an S-parameter uses -- see the module doc.
  10.0 * log10(x)

proc dbToPowerRatio*(db: float): float {.inline.} =
  pow(10.0, db / 10.0)

proc voltageRatioToDb*(x: float): float {.inline.} =
  ## `20 * log10(x)` -- the *voltage/amplitude*-ratio dB an S-parameter is
  ## stated in, because S11/S21/... are ratios of voltage *waves*, not of
  ## power. Using this on a power ratio overstates it by exactly 2x in dB;
  ## see the module doc for why that mistake gets two proc names instead of
  ## one ambiguous one.
  20.0 * log10(x)

proc dbToVoltageRatio*(db: float): float {.inline.} =
  pow(10.0, db / 20.0)

proc dbmToWatts*(dbm: float): float {.inline.} =
  ## `1e-3 * 10^(dbm/10)`. 0 dBm is 1 mW by definition, so this and
  ## `wattsToDbm` are exact at that point, not merely close.
  1e-3 * pow(10.0, dbm / 10.0)

proc wattsToDbm*(w: float): float {.inline.} =
  10.0 * log10(w / 1e-3)

# --- reflection and mismatch --------------------------------------------

proc gammaOf*(z, z0: Complex64): Complex64 {.inline.} =
  ## The reflection coefficient of an impedance `z` against a reference
  ## `z0`: `(z - z0) / (z + z0)`. `z == z0` gives exactly `0` (a perfect
  ## match); `z` purely reactive against a real `z0` gives `|Gamma| == 1` (an
  ## open or a short reflects everything).
  (z - z0) / (z + z0)

proc vswrOf*(gammaMag: float): float {.inline.} =
  ## `(1 + |Gamma|) / (1 - |Gamma|)`. Returns `Inf` at `gammaMag == 1.0`
  ## (an open or a short: infinite standing-wave ratio, not an error) rather
  ## than raising or clamping -- the same "the mathematical limit is a real
  ## answer" convention `spice/backend.db` already follows for an
  ## exactly-zero magnitude. A `gammaMag` above 1 (a mismatch with gain, from
  ## an active device) is not refused either: this proc only does the
  ## arithmetic, and whether that is a legitimate reading is the caller's
  ## question, not this one's.
  (1.0 + gammaMag) / (1.0 - gammaMag)

proc returnLossDb*(gammaMag: float): float {.inline.} =
  ## `-voltageRatioToDb(gammaMag)`, so a *better* match reads as a *larger*
  ## number -- the conventional RF sign, and the opposite sign from a raw
  ## S11 dB reading (`voltageRatioToDb(gammaMag)` directly, which is
  ## negative for anything better than a dead short). `gammaMag == 0.0`
  ## (a perfect match) gives `+Inf`, not an error: there is no finite number
  ## of dB by which zero reflection exceeds itself.
  -voltageRatioToDb(gammaMag)

proc insertionLossDb*(s21Mag: float): float {.inline.} =
  ## `-voltageRatioToDb(s21Mag)`. `0 dB` for a lossless through path
  ## (`s21Mag == 1.0`); positive for anything lossy, same sign convention as
  ## `returnLossDb` for the same reason -- a bigger number is a worse path
  ## for insertion loss and a better port for return loss, and both read
  ## that way because "more loss/less reflection is good" is what an RF
  ## datasheet's headline figure means either way.
  -voltageRatioToDb(s21Mag)
