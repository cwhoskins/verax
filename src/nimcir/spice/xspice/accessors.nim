## Typed accessors over `mif.nim`, and the emission target for
## `xspice/dsl.nim`'s AST rewriter.
##
## These reproduce, in Nim, exactly what ngspice's `cmpp -mod` emits from
## `cfunc.mod`. `cmpp` is not a C preprocessor -- it is a lex/yacc translator
## (`src/xspice/cmpp/mod_yacc.y`) that rewrites `PARAM(gain)` into
## `mif_private->param[3]->element[0].rvalue`, choosing the index from
## declaration order in `ifspec.ifs` and the union member from the declared
## type. `PARAM`/`INPUT`/`OUTPUT`/`PARTIAL` therefore do **not** exist as C
## macros and cannot be imported; they have to be reproduced. Verified: for an
## identical model, the C emitted from these templates is byte-identical to
## `cmpp`'s own output.
##
## Every accessor is a `template` returning `untyped`, not a `proc`, so the
## expression stays lvalue-transparent and `mifOutputReal(mp, 1, 0) = x` is an
## ordinary assignment rather than needing a `var` return or a hidden `addr`.
##
## Callers pass *indices*, not names. Name resolution belongs to `dsl.nim`,
## which owns the `ModelSpec` and can report an unknown port against the
## offending AST node.

import ./mif
export mif

# --- circuit state -----------------------------------------------------------

template mifInit*(mp: ptr MifPrivate): bool = mp.circuit.init != 0
template mifTime*(mp: ptr MifPrivate): untyped = mp.circuit.time
template mifTstep*(mp: ptr MifPrivate): untyped = mp.circuit.tstep
template mifTstop*(mp: ptr MifPrivate): untyped = mp.circuit.tstop
template mifTemperature*(mp: ptr MifPrivate): untyped = mp.circuit.temperature
template mifRadFreq*(mp: ptr MifPrivate): untyped = mp.circuit.frequency
  ## `RAD_FREQ` in XSPICE. Note this reads the stored `circuit.frequency`
  ## field directly -- it is not a computed 2*pi*f.
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
  ## `PARTIAL(out, in)`. Both `oc` and `ic` are *connection* indices -- cmpp
  ## resolves each with `valid_subid(..., CONN)` over the full connection
  ## list, not over a filtered list of inputs.
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
# A digital port's value is a `Digital_t*` behind the union's `pvalue`; there
# is no digital member in `Mif_Value_t` itself. Reads go through templates;
# writes are procs because they convert a Nim enum back to ngspice's `int`,
# and a converting assignment cannot stay lvalue-transparent.

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
  ## `OUTPUT_CHANGED(port) = FALSE` suppresses the event ngspice would
  ## otherwise emit for this output. An event-driven model that decides its
  ## output did *not* change must say so, or it floods the event queue.
  mp.conn[c].port[p].changed = (if v: 1 else: 0)

# --- per-instance event state ------------------------------------------------
#
# ngspice rotates these buffers per accepted timepoint and rolls them back when
# it rejects one, which is what makes them the correct home for "the value at
# the previous timepoint". `stateVar` (STATIC_VAR) is *not* rolled back.
# Timepoint 0 is the current slot, 1 the previous.
#
# The buffer is ours: we allocate it and we are the only reader, so storing a
# Nim enum in it assumes nothing about ngspice's own enumerator values.

template eventAlloc*(tag: int, T: typedesc) =
  ## Reserve a per-instance slot big enough for a `T`. Call under `init`.
  cmEventAlloc(tag.cint, cint(sizeof(T)))

template eventVar*(tag, timepoint: int, T: typedesc): untyped =
  ## The `T` stored in slot `tag` at `timepoint` (0 = now, 1 = previous).
  ## Assignable.
  cast[ptr T](cmEventGetPtr(tag.cint, timepoint.cint))[]

# --- per-instance analog state ----------------------------------------------
#
# The analog counterpart of `eventAlloc`/`eventVar`, and it exists for the same
# reason: ngspice rotates these buffers per accepted timepoint and rolls them
# back when it rejects one, so they are the only correct home for "the value at
# the previous timepoint" in a continuous-time model. `stateVar` (STATIC_VAR)
# is *not* rolled back, which makes it right for something that genuinely does
# not unwind -- a latched enable -- and wrong for anything a rejected timestep
# must be able to undo.
#
# A switching converter needs both halves of this: state that survives a
# rejected step (which cycle we are in, when the switch turned off) and a real
# integrator for the compensation node.

template analogAlloc*(tag: int, T: typedesc) =
  ## Reserve a per-instance analog state slot big enough for a `T`. Call it
  ## under `init`, and only outside `.ac` -- ngspice allocates the state
  ## vectors for the analysis it is about to run.
  cmAnalogAlloc(tag.cint, cint(sizeof(T)))

template analogVar*(tag, timepoint: int, T: typedesc): untyped =
  ## The `T` stored in slot `tag` at `timepoint` (0 = now, 1 = previous).
  ## Assignable.
  cast[ptr T](cmAnalogGetPtr(tag.cint, timepoint.cint))[]

proc analogIntegrate*(tag: int, integrand: float, partial: var float): float
    {.inline, discardable.} =
  ## Integrate `integrand` into analog state slot `tag`, returning the new
  ## value of the integral and, in `partial`, d(integral)/d(integrand).
  ##
  ## The slot must have been reserved by `analogAlloc` and this must run in
  ## `.tran`: ngspice's own `cm_analog_integrate` refuses outside it, since
  ## there is no timestep to integrate over. The integration method is the
  ## simulator's current one, which is what makes this different from adding
  ## `integrand * tstep` by hand -- that would be forward Euler regardless of
  ## what the rest of the deck is being solved with.
  let slot = cast[ptr cdouble](cmAnalogGetPtr(tag.cint, 0))
  var pd: cdouble = 0.0
  discard cmAnalogIntegrate(integrand.cdouble, slot, addr pd)
  partial = pd.float
  slot[].float

template setPermBkpt*(t: float) =
  ## Force a timepoint at `t`, permanently. A model whose behaviour changes on
  ## a clock edge must place one on every edge: nothing else in the simulator
  ## knows the edge is coming, and local truncation error on a node that is
  ## flat between edges will happily step straight over one.
  discard cmAnalogSetPermBkpt(t.cdouble)

template setTempBkpt*(t: float) =
  ## Force a timepoint at `t`, for this step only. For an edge whose time is
  ## a prediction rather than a certainty -- it moves as the solution moves,
  ## and a permanent breakpoint at a wrong guess would never be withdrawn.
  discard cmAnalogSetTempBkpt(t.cdouble)
