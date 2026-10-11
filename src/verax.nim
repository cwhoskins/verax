## verax: state what a circuit must do, and check it.
##
## **Deliberately empty.** This is not a re-export hub: importing everything
## would drag the simulator, `osproc` and the whole analysis tree into any
## program that writes `import verax`. Import submodules by path instead --
## `import verax/netlist`, `import verax/contract`, `import verax/verify` --
## so what a program pulls in is what it asked for. The binary is built from
## `verax/cli.nim` (see `verax.nimble`). `docs/architecture.md` maps the
## submodules.
