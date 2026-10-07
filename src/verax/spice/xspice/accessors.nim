## Typed accessors over `mif.nim`, and the emission target for
## `xspice/dsl.nim`'s rewriter.
##
## They reproduce what ngspice's `cmpp -mod` emits: `cmpp` is a lex/yacc
## translator that rewrites `PARAM(gain)` into
## `mif_private->param[3]->element[0].rvalue` (index from `.ifs`
## declaration order), so `PARAM`/`INPUT`/`OUTPUT`/`PARTIAL` aren't C macros
## and must be reproduced. The emitted C is byte-identical to `cmpp`'s.
##
## Accessors are `template`s returning `untyped`, so they stay
## lvalue-transparent (`mifOutputReal(mp, 1, 0) = x`). Callers pass
## indices; `dsl.nim` resolves names.

import ./mif
export mif

# --- circuit state -----------------------------------------------------------

template mifInit*(mp: ptr MifPrivate): bool = mp.circuit.init != 0
template mifTime*(mp: ptr MifPrivate): untyped = mp.circuit.time
template mifTstep*(mp: ptr MifPrivate): untyped = mp.circuit.tstep
template mifTstop*(mp: ptr MifPrivate): untyped = mp.circuit.tstop
template mifTemperature*(mp: ptr MifPrivate): untyped = mp.circuit.temperature
template mifRadFreq*(mp: ptr MifPrivate): untyped = mp.circuit.frequency
  ## `RAD_FREQ`: the stored `circuit.frequency`, not a computed 2*pi*f.
template mifNewTimepoint*(mp: ptr MifPrivate): bool = mp.circuit.anal_init != 0
template mifT*(mp: ptr MifPrivate, n: int): untyped = mp.circuit.t[n]

template mifAnalysis*(mp: ptr MifPrivate): Analysis = toAnalysis(mp.circuit.anal_type)
template mifCallType*(mp: ptr MifPrivate): CallType = toCallType(mp.circuit.call_type)

# --- parameters --------------------------------------------------------------

template mifParamBool*(mp: ptr MifPrivate, i, s: int): untyped = mp.param[i].element[s].bvalue
template mifParamInt*(mp: ptr MifPrivate, i, s: int): untyped = mp.param[i].element[s].ivalue
template mifParamReal*(mp: ptr MifPrivate, i, s: int): untyped = mp.param[i].element[s].rvalue
template mifParamComplex*(mp: ptr MifPrivate, i, s: int): untyped = mp.param[i].element[s].cvalue
template mifParamStr*(mp: ptr MifPrivate, i, s: int): untyped = mp.param[i].element[s].svalue
template mifParamSize*(mp: ptr MifPrivate, i: int): untyped = mp.param[i].size
template mifParamNull*(mp: ptr MifPrivate, i: int): bool = mp.param[i].is_null != 0

# --- static (per-instance) variables ----------------------------------------

template mifStateBool*(mp: ptr MifPrivate, i, s: int): untyped = mp.inst_var[i].element[s].bvalue
template mifStateInt*(mp: ptr MifPrivate, i, s: int): untyped = mp.inst_var[i].element[s].ivalue
template mifStateReal*(mp: ptr MifPrivate, i, s: int): untyped = mp.inst_var[i].element[s].rvalue
template mifStateComplex*(mp: ptr MifPrivate, i, s: int): untyped = mp.inst_var[i].element[s].cvalue
template mifStateStr*(mp: ptr MifPrivate, i, s: int): untyped = mp.inst_var[i].element[s].svalue
template mifStateSize*(mp: ptr MifPrivate, i: int): untyped = mp.inst_var[i].size

# --- analog ports ------------------------------------------------------------

template mifInputReal*(mp: ptr MifPrivate, c, p: int): untyped = mp.conn[c].port[p].input.rvalue
template mifOutputReal*(mp: ptr MifPrivate, c, p: int): untyped = mp.conn[c].port[p].output.rvalue

template mifPartial*(mp: ptr MifPrivate, oc, op, ic, ip: int): untyped =
  ## `PARTIAL(out, in)`. Both `oc` and `ic` are *connection* indices over the
  ## full connection list.
  mp.conn[oc].port[op].partial[ic].port[ip]

template mifAcGain*(mp: ptr MifPrivate, oc, op, ic, ip: int): untyped =
  mp.conn[oc].port[op].ac_gain[ic].port[ip]

# --- port metadata -----------------------------------------------------------

template mifPortSize*(mp: ptr MifPrivate, c: int): untyped = mp.conn[c].size
template mifPortNull*(mp: ptr MifPrivate, c: int): bool = mp.conn[c].is_null != 0
template mifOutputDelay*(mp: ptr MifPrivate, c, p: int): untyped = mp.conn[c].port[p].delay
template mifChanged*(mp: ptr MifPrivate, c, p: int): bool = mp.conn[c].port[p].changed != 0
template mifLoad*(mp: ptr MifPrivate, c, p: int): untyped = mp.conn[c].port[p].load
template mifTotalLoad*(mp: ptr MifPrivate, c, p: int): untyped = mp.conn[c].port[p].total_load

# --- digital ports -----------------------------------------------------------
#
# A digital value is a `Digital_t*` behind `pvalue`. Reads are templates;
# writes are procs (they convert a Nim enum to ngspice's `int`).

template mifInputDigitalPtr*(mp: ptr MifPrivate, c, p: int): ptr Digital =
  cast[ptr Digital](mp.conn[c].port[p].input.pvalue)
template mifOutputDigitalPtr*(mp: ptr MifPrivate, c, p: int): ptr Digital =
  cast[ptr Digital](mp.conn[c].port[p].output.pvalue)

proc mifInputState*(mp: ptr MifPrivate, c, p: int): DigitalState {.inline.} =
  toDigitalState(mifInputDigitalPtr(mp, c, p).state)
proc mifInputStrength*(mp: ptr MifPrivate, c, p: int): DigitalStrength {.inline.} =
  toDigitalStrength(mifInputDigitalPtr(mp, c, p).strength)
proc mifOutputState*(mp: ptr MifPrivate, c, p: int): DigitalState {.inline.} =
  toDigitalState(mifOutputDigitalPtr(mp, c, p).state)
proc mifOutputStrength*(mp: ptr MifPrivate, c, p: int): DigitalStrength {.inline.} =
  toDigitalStrength(mifOutputDigitalPtr(mp, c, p).strength)

proc setOutputState*(mp: ptr MifPrivate, c, p: int, s: DigitalState) {.inline.} =
  mifOutputDigitalPtr(mp, c, p).state = fromDigitalState(s)
proc setOutputStrength*(mp: ptr MifPrivate, c, p: int, s: DigitalStrength) {.inline.} =
  mifOutputDigitalPtr(mp, c, p).strength = fromDigitalStrength(s)
proc setOutputDigital*(mp: ptr MifPrivate, c, p: int,
                       state: DigitalState,
                       strength = dgStrong) {.inline.} =
  let d = mifOutputDigitalPtr(mp, c, p)
  d.state = fromDigitalState(state)
  d.strength = fromDigitalStrength(strength)

proc setOutputChanged*(mp: ptr MifPrivate, c, p: int, v: bool) {.inline.} =
  ## `OUTPUT_CHANGED(port) = FALSE` suppresses the output event; an
  ## event-driven model must say so or it floods the event queue.
  mp.conn[c].port[p].changed = (if v: 1 else: 0)

# --- per-instance event state ------------------------------------------------
#
# ngspice rotates these per accepted timepoint and rolls them back on
# rejection, so they hold "the previous timepoint's value" correctly
# (`stateVar` is *not* rolled back). Timepoint 0 is now, 1 previous. We own
# the buffer, so storing a Nim enum is safe.

template eventAlloc*(tag: int, T: typedesc) =
  ## Reserve a per-instance slot big enough for a `T`. Call under `init`.
  cmEventAlloc(tag.cint, cint(sizeof(T)))

template eventVar*(tag, timepoint: int, T: typedesc): untyped =
  ## The `T` in slot `tag` at `timepoint` (0 = now, 1 = previous).
  ## Assignable.
  cast[ptr T](cmEventGetPtr(tag.cint, timepoint.cint))[]

# --- per-instance analog state ----------------------------------------------
#
# The analog counterpart of `eventAlloc`/`eventVar`: rotated and rolled back
# per timepoint, so the right home for anything a rejected step must undo.
# `stateVar` suits things that never unwind (a latched enable). A switching
# converter needs both, plus a real integrator.

template analogAlloc*(tag: int, T: typedesc) =
  ## Reserve an analog state slot for a `T`. Call under `init`, and not in
  ## `.ac` (ngspice allocates state for the coming analysis).
  cmAnalogAlloc(tag.cint, cint(sizeof(T)))

template analogVar*(tag, timepoint: int, T: typedesc): untyped =
  ## The `T` in slot `tag` at `timepoint` (0 = now, 1 = previous).
  ## Assignable.
  cast[ptr T](cmAnalogGetPtr(tag.cint, timepoint.cint))[]

proc analogIntegrate*(tag: int, integrand: float, partial: var float): float
    {.inline, discardable.} =
  ## Integrate `integrand` into analog slot `tag`, returning the integral and,
  ## in `partial`, d(integral)/d(integrand). Requires `analogAlloc` and
  ## `.tran`. Uses the simulator's integration method (adding
  ## `integrand * tstep` by hand would be forward Euler).
  let slot = cast[ptr cdouble](cmAnalogGetPtr(tag.cint, 0))
  var pd: cdouble = 0.0
  discard cmAnalogIntegrate(integrand.cdouble, slot, addr pd)
  partial = pd.float
  slot[].float

template setPermBkpt*(t: float) =
  ## Force a permanent timepoint at `t`. Place one on every clock edge, or
  ## truncation-error control can step straight over it.
  discard cmAnalogSetPermBkpt(t.cdouble)

template setTempBkpt*(t: float) =
  ## Force a timepoint at `t` for this step only -- for a predicted edge
  ## that may move.
  discard cmAnalogSetTempBkpt(t.cdouble)
