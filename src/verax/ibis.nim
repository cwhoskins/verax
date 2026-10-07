## IBIS: reading a vendor `.ibs` file into a typed model of a buffer (I/V
## curves, edge rates, die and package parasitics). Doesn't simulate or
## judge; it reads and hands back data.
##
## The parser (`parse` + `reader`) covers the IBIS 3.2 core; `attach` binds a
## model to a component and placement and checks pin names; `behave`
## interprets a model as a behaviour (absolute-voltage curves, `Ku`/`Kd`)
## for the SI engine. Toolchain-free,
## so the whole submodule is in this hub.

import verax/ibis/types
import verax/ibis/parse
import verax/ibis/reader
import verax/ibis/attach
import verax/ibis/behave

export types, parse, reader, attach, behave
