# import std/[algorithm, math, sets, strutils, tables]
# import ../netlist/types
# import ../netlist/kinds
# import ../netlist/annotations
# import ./scene
# import ./pipeline
#
# include ./geometry
# include ./symbols
# include ./router
# include ./labels
# include ./placement
# include ./constrained
# include ./state
# include ./routing
# include ./finish

type
  LayoutError = enum
    NO_ERROR = 0
    ERROR = -1

proc countbends(x: seq[SchematicWire]): int =
  return foldl(x,a+b.points.len()-2,0) + x.len()-1

proc translateRoutedComponent(state: var LayoutState) =
  discard

proc verifyLayout(state: LayoutState): LayoutError =
  return LayoutError.NO_ERROR
  

proc refineRouting(state: var LayoutState) =
  var wires = state.routing.wires.filterIt(it.kind == wkSignal)
  var netwires = initOrderedTable[string,seq[SchematicWire]]()
  const MovableComponents = ["resistor", "capacitor"]
  for w in mitems(wires):
    if w.points.len() >= 3:
      # Sometimes there is an additional point on a line, just filter them out for now
      for idx in countdown(len(w.points)-2,1):
        if (w.points[idx].x == w.points[idx+1].x and w.points[idx].x == w.points[idx-1].x) or
            (w.points[idx].y == w.points[idx+1].y and w.points[idx].y == w.points[idx-1].y):
          w.points.delete(idx)
          
    if w.net in netwires:
      netwires[w.net].add(w)
    else:
      netwires[w.net] = @[w]
  netwires.sort(proc (x, y: (string, seq[SchematicWire])): int =
    cmp(x[1].countbends(), y[1].countbends())
  )
  # Create an initial list of anchored parts that shouldn't be moved
  var anchors = newSeqOfCap[SchematicPart](state.routing.parts.len())
  for p in state.routing.parts:
    if p.kind notin MovableComponents:
      anchors.add(p)
  # Get the non-power/ground nets connected to the anchored parts
  # and add them to the list of nets to straighten
  for a in anchors:
    for p in a.pins:
      discard
  # Loop through the nets and try to straighten them
  # Regardless of the result add the moved components to the anchored list
  # and add their nets to the next iteration
      
  for n, w in netwires:
    echo n, ": ", w.countbends()
    echo w

