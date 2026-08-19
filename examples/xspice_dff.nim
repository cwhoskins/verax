## An event-driven XSPICE code model -- a rising-edge D flip-flop -- in Nim.
##
## The digital counterpart to `xspice_gain.nim`, and a different execution
## model: no `partial`, no matrix loading. Instead the model is called when an
## input *event* arrives, reads `inputState`, and schedules an output event
## with `outputState` + `outputDelay`.
##
## Two things an event-driven model must do that an analog one need not:
##
## * **Say when nothing changed.** `outputChanged(q) = false` suppresses the
##   event ngspice would otherwise emit. Without it, every input event
##   produces an output event and the queue fills with no-ops.
## * **Keep previous-timepoint state in event storage**, via `eventAlloc` /
##   `eventVar`, never in a Nim global. ngspice rotates these buffers per
##   accepted timepoint and rolls them back when it rejects one; a Nim global
##   would also be shared across every instance of the model in the deck.
##
## `LOAD` is declared once under `init`: it is the input capacitance ngspice
## uses to work out drive strength on the node.

import nimcir/spice/xspice/dsl

codeModel "nimdff":
  description "rising-edge D flip-flop, written in nim"

  port d,   dir = xdIn,  default = xpD, allowed = [xpD], description = "data in"
  port clk, dir = xdIn,  default = xpD, allowed = [xpD], description = "clock"
  port q,   dir = xdOut, default = xpD, allowed = [xpD], description = "data out"

  param clk_delay, float, default = 1.0e-9, description = "delay from clk"
  param ic,        int,   default = 0,      description = "initial output state"
  param d_load,    float, default = 1.0e-12, description = "data load (F)"
  param clk_load,  float, default = 1.0e-12, description = "clk load (F)"

  eval:
    if init:
      eventAlloc(0, DigitalState)      # previous clk state
      load(d) = param(d_load)
      load(clk) = param(clk_load)

    let clkNow = inputState(clk)

    if time == 0.0:
      # Initial conditions are driven without any delay.
      eventVar(0, 0, DigitalState) = clkNow
      outputState(q) = (if param(ic) == 1: dsOne else: dsZero)
    else:
      let clkWas = eventVar(0, 1, DigitalState)
      eventVar(0, 0, DigitalState) = clkNow
      if clkNow == dsOne and clkWas != dsOne:
        outputState(q) = inputState(d)
        outputDelay(q) = param(clk_delay)
      else:
        outputChanged(q) = false
