## A starting point.
##
##   nimcir check <this file>
##
## Discover what you can claim:
##   nimcir roles            what bundles of claims exist
##   nimcir role <name>      one role's parts, params and the claims it makes
##   nimcir quantities       every quantity a `require` can name
##   nimcir annotations      every key a `spec:` block accepts

import nimcir/contract/dsl
import nimcir/verify

let d = design("untitled"):
  # Where the board has to work, if you know: an `environment:` block states
  # the ambient range every temperature-dependent answer must hold across.
  # Commented out rather than filled in, because a range nobody chose is a
  # specification invented on your behalf.
  #
  #   environment:
  #     t_ambient_min = 0.degC
  #     t_ambient_max = 70.degC
  #
  # A part that runs hotter than the air says so itself, in its own `spec:`
  # block -- `delta_t = 16.degC`. Everything else defaults to a rise of 0.

  net gnd, kind = ntGround, name = "0"
  # A power net states its nominal voltage. Leave it out and STRUCTURE says
  # so: an analysis that cuts a fragment out around an unstated rail leaves
  # it *floating* rather than driving it, which changes the circuit rather
  # than substituting a number.
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V

  component R1, kind = "resistor", value = "10k":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # A role is a bundle of claims. A `require` is one claim of your own:
  #
  #   role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct
  #
  #   require z_max_in_band(vdd) <= 100.mohm,
  #           f_from = 100.kHz, f_to = 100.MHz,
  #           id = "REQ-001",
  #           because = "why this limit and not another"

quit(verifyMain(d))
