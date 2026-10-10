## Stimulus: a single edge or a bit string at a UI, turned into the
## `Ku(t)`/`Kd(t)` weights the engine drives the buffer with.
##
## A bit pattern **stitches** the extracted edges: each transition starts its
## edge's `Ku`/`Kd` series at the transition time. If the next transition
## arrives before the previous edge's table ends, the coefficients jump
## there (a discontinuity, so a breakpoint the engine restarts at) and a
## warning says the UI is shorter than the waveform table.

import std/[strutils, math]
import ../ibis/behave
import ./engine/pwl

export pwl

type
  StimulusKind* = enum
    skEdge, skPattern

  Stimulus* = object
    delay*: float
      ## When the first transition starts, seconds.
    case kind*: StimulusKind
    of skEdge:
      edge*: Edge
    of skPattern:
      bits*: string
      ui*: float

  DriveWaves* = object
    ku*, kd*: Pwl
    tr*: float
      ## Fastest 10-90 % coefficient transition used: the edge the time step
      ## must resolve.
    lastChange*: float
      ## When the coefficients stop moving.
    supported*: bool
    reason*: string
    issues*: seq[Issue]
    edgesUsed*: set[Edge]

proc edgeStimulus*(e: Edge, delay = 0.0): Stimulus =
  Stimulus(kind: skEdge, edge: e, delay: delay)

proc patternStimulus*(bits: string, ui: float, delay = 0.0): Stimulus =
  Stimulus(kind: skPattern, bits: bits, ui: ui, delay: delay)

proc complement*(s: Stimulus): Stimulus =
  ## The opposite drive: the other edge, or every bit inverted.
  case s.kind
  of skEdge:
    edgeStimulus((if s.edge == edRising: edFalling else: edRising), s.delay)
  of skPattern:
    var b = s.bits
    for c in b.mitems: c = (if c == '1': '0' else: '1')
    patternStimulus(b, s.ui, s.delay)

proc held*(high: bool): Stimulus =
  ## A driver that never switches: one bit, so it sits at the end of the
  ## edge into that level.
  patternStimulus((if high: "1" else: "0"), 1e-9)

proc delayed*(s: Stimulus, dt: float): Stimulus =
  result = s
  result.delay += dt

proc `$`*(s: Stimulus): string =
  case s.kind
  of skEdge: edgeName(s.edge) & " edge at " & $s.delay & " s"
  of skPattern: "pattern " & s.bits & " at UI " & $s.ui & " s"

proc transitions(s: Stimulus): tuple[initialHigh: bool, at: seq[tuple[t: float, e: Edge]]]

proc transitionsOf*(s: Stimulus): seq[tuple[t: float, e: Edge]] =
  ## Every transition the stimulus makes: when, and which edge.
  transitions(s).at

proc transitions(s: Stimulus): tuple[initialHigh: bool, at: seq[tuple[t: float, e: Edge]]] =
  case s.kind
  of skEdge:
    result.initialHigh = s.edge == edFalling
    result.at = @[(s.delay, s.edge)]
  of skPattern:
    result.initialHigh = s.bits[0] == '1'
    for i in 1 ..< s.bits.len:
      if s.bits[i] != s.bits[i - 1]:
        result.at.add (s.delay + i.float * s.ui,
                       (if s.bits[i] == '1': edRising else: edFalling))

proc driveWaves*(d: DriverBehaviour, s: Stimulus): DriveWaves =
  ## The weights for the whole run. Unsupported when a needed edge is
  ## unavailable for verdicts or the pattern is malformed.
  result.supported = true
  if s.kind == skPattern:
    if s.bits.len == 0 or not s.bits.allCharsInSet({'0', '1'}):
      result.supported = false
      result.reason = "bit pattern must be a non-empty string of 0/1, got '" & s.bits & "'"
      return
    if not (s.ui > 0.0):
      result.supported = false
      result.reason = "pattern UI must be positive"
      return
  let (initialHigh, trans) = transitions(s)
  var used: set[Edge]
  for (_, e) in trans: used.incl e
  # The held level before the first transition is the start of the first
  # edge (continuous), or with no transition the end of the edge into it.
  let holdFrom =
    if trans.len > 0: (d.edges[trans[0].e], true)
    else: (d.edges[if initialHigh: edRising else: edFalling], false)
  if trans.len == 0: used.incl (if initialHigh: edRising else: edFalling)
  for e in used:
    if not d.edges[e].available or d.edges[e].t.len == 0:
      result.supported = false
      result.reason = d.model & " " & edgeName(e) & " edge: " &
        (if d.edges[e].reason.len > 0: d.edges[e].reason else: "unavailable")
      return
  result.edgesUsed = used
  let (hs, atStart) = holdFrom
  result.ku.add 0.0, (if atStart: hs.ku[0] else: hs.ku[^1])
  result.kd.add 0.0, (if atStart: hs.kd[0] else: hs.kd[^1])
  result.tr = Inf
  var warned = false
  for idx, (t0, e) in trans:
    let ks = d.edges[e]
    result.tr = min(result.tr, ks.riseTime)
    # Truncate whatever the previous edge still had after t0.
    proc cut(p: var Pwl, t0: float) =
      if p.t[^1] <= t0: return
      let v = p.at(t0)
      var k = p.t.len
      while k > 0 and p.t[k - 1] > t0: dec k
      p.t.setLen k
      p.v.setLen k
      p.add t0, v
    if result.ku.t[^1] > t0 or result.kd.t[^1] > t0:
      if not warned:
        result.issues.add newIssue("si_ui_short", sevWarning,
          "UI " & $s.ui & " s is shorter than the " & d.model &
          " waveform table; edges are truncated where the next one starts")
        warned = true
      cut(result.ku, t0)
      cut(result.kd, t0)
    if result.ku.t[^1] < t0:
      result.ku.add t0, result.ku.v[^1]
      result.kd.add t0, result.kd.v[^1]
    for k in 0 ..< ks.t.len:
      result.ku.add t0 + ks.t[k], ks.ku[k]
      result.kd.add t0 + ks.t[k], ks.kd[k]
    result.lastChange = t0 + ks.t[^1]
  if result.tr == Inf or result.tr <= 0.0:
    result.tr = NaN
