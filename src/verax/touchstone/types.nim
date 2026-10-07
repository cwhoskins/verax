## The typed Touchstone model: the S-parameter matrix a `.sNp` file states,
## plus the scalar conversions reading one requires. A transcription, not an
## interpretation (as `verax/ibis/types`).
##
## Scalar conversions live here, not in `analysis/measure` (which is swept
## curve math).
##
## **dB conversions come in two named pairs, never one generic one**: an
## S-parameter is a voltage-wave ratio (20*log10), while gain/Friis/cascade
## math uses power ratios (10*log10). A shared helper invites a silent 2x
## error in dB.

import std/[complex, math]

type
  TouchstoneError* = object of CatchableError
    ## Raised on malformed input; `msg` carries line context where possible.

  SParams* = object
    ## One frequency-swept S-parameter matrix, as read from a `.sNp` file.
    nPorts*: int
    z0*: float
      ## The reference impedance, ohms, shared by every port (Touchstone v2
      ## per-port impedances aren't supported).
    freqs*: seq[float]
      ## Hz, ascending; the file's frequency unit is already applied.
    points*: seq[seq[Complex64]]
      ## `points[k]` is the matrix at `freqs[k]`, row-major (`i*nPorts + j`
      ## is Sij). The reader normalises the 2-port file order (S11/S21/S12/S22)
      ## into this.

proc sAt*(sp: SParams, k, i, j: int): Complex64 =
  ## Sij at sample `k` (0-based); the one place the index arithmetic lives.
  sp.points[k][i * sp.nPorts + j]

# --- dB <-> linear, kept as two pairs never one -------------------------

proc powerRatioToDb*(x: float): float {.inline.} =
  ## `10 * log10(x)`: power-ratio dB (gain, noise figure, intercepts). Not
  ## for S-parameters.
  10.0 * log10(x)

proc dbToPowerRatio*(db: float): float {.inline.} =
  pow(10.0, db / 10.0)

proc voltageRatioToDb*(x: float): float {.inline.} =
  ## `20 * log10(x)`: voltage/amplitude-ratio dB, as S-parameters use.
  20.0 * log10(x)

proc dbToVoltageRatio*(db: float): float {.inline.} =
  pow(10.0, db / 20.0)

proc dbmToWatts*(dbm: float): float {.inline.} =
  ## `1e-3 * 10^(dbm/10)`; exact at 0 dBm = 1 mW.
  1e-3 * pow(10.0, dbm / 10.0)

proc wattsToDbm*(w: float): float {.inline.} =
  10.0 * log10(w / 1e-3)

# --- reflection and mismatch --------------------------------------------

proc gammaOf*(z, z0: Complex64): Complex64 {.inline.} =
  ## Reflection coefficient `(z - z0) / (z + z0)`: 0 for a match, `|Gamma|
  ## == 1` for a reactive load.
  (z - z0) / (z + z0)

proc vswrOf*(gammaMag: float): float {.inline.} =
  ## `(1 + |Gamma|) / (1 - |Gamma|)`; `Inf` at `gammaMag == 1.0` (a real
  ## limit, not an error). `gammaMag > 1` isn't refused.
  (1.0 + gammaMag) / (1.0 - gammaMag)

proc returnLossDb*(gammaMag: float): float {.inline.} =
  ## `-voltageRatioToDb(gammaMag)`: a better match reads larger (the RF
  ## convention, opposite to raw S11 dB). `+Inf` for a perfect match.
  -voltageRatioToDb(gammaMag)

proc insertionLossDb*(s21Mag: float): float {.inline.} =
  ## `-voltageRatioToDb(s21Mag)`: 0 dB for a lossless path, positive when
  ## lossy.
  -voltageRatioToDb(s21Mag)
