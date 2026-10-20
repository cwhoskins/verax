## Pin-capability table for the STM32H563ZIT6 (LQFP-144).
##
## Importing this module registers the table, the same way importing
## `designs/lib/opamps.nim` registers a package definition.  `validatePinmux`
## then checks every `port ..., peripheral = "SPIn"` and every
## `pin ..., function = "..."` in a design that uses this part against it.
##
## **This table is complete** (`complete = true`): it lists every one of the
## 112 I/O pins the LQFP-144 package bonds out, so a design that touches a pin
## this table does not name -- `PE1`, say, which this package does *not* bring
## out (pin 141 is `PE0`, then `VCAP`) -- is a hard error, not a warning.
##
## What each pin carries: `GPIO`, every **serial-bus** alternate function --
## SPI1-6, I2C1-4, I3C1, USART1/2/3/6/10/11, UART4/5/7/8/9/12, LPUART1 -- plus
## **ADC1/ADC2** (bare, non-interface channels: `pinmux.PeripheralDef.iface`
## is `""` for exactly this case) and **USB** (the one full-speed OTG
## peripheral this part has, bound to `usb2Interface()`'s `p`/`n` signals --
## `"USB.p"` is `USB_DP`, `"USB.n"` is `USB_DM`, the datasheet's own D+/D-
## naming) and **JTAG** (the debug port, bound to `jtagInterface()`'s
## `tck`/`tms`/`tdi`/`tdo`/`ntrst`). The timer, SAI, FMC, OCTOSPI, SDMMC,
## DCMI and Ethernet functions stay out on purpose: the pinmux vocabulary is
## interface signal names or a bare peripheral like `ADC1`, and there is no
## equivalent for those yet. A design that wires one names it explicitly
## (`function = "TIM2.ch1"`) and gets `pinmux_incapable` until it is added
## here -- that path does not depend on `complete`.
##
## Signal names are the **interface** names (`sclk`/`mosi`/`miso`/`cs` from
## `spiInterface`, `scl`/`sda` from `i2cInterface`, `txd`/`rxd` from
## `uartInterface`, `p`/`n` from `usb2Interface`, `tck`/`tms`/`tdi`/`tdo`/
## `ntrst` from `jtagInterface`), not the datasheet's pin-function names
## (`SPI1_SCK`, `SPI1_NSS`, `USART1_TX`): the check compares against what a
## `port` wired against an interface def, so the table has to speak the same
## vocabulary. `USART`/`UART` `CK`/`CTS`/`RTS`/`NSS`/`DE` and `SPIn_RDY` have
## no interface signal and are dropped; datasheet `NSS` maps to `cs` only
## for `SPI`. **`ADC1`/`ADC2` are the one exception**: nothing registers an
## interface for a multi-channel ADC, so their signal names (`in0`..`in19`)
## are this table's own vocabulary rather than an existing `InterfaceDef`'s,
## the same way `docs/authoring.md`'s `function = "ADC1.in3"` example
## anticipates. Only each channel's positive input (`ADCn_INPx`) is listed;
## the differential negative inputs (`ADCn_INNx`, mostly the neighbouring
## even-numbered channel's pin) are dropped, on the same "one signal per
## real, ordinary use" reasoning as the UART lines above -- a design driving
## true differential ADC mode names the pin it needs directly and gets
## `pinmux_incapable` until it is added. `JTAG.ntrst` is `PB4`/`NJTRST`, the
## dedicated TAP-reset pin -- distinct from the board's own system reset
## (`NRST`), and not to be confused with it: asserting one resets the debug
## port, the other the whole MCU.
##
## `resetPulls` carries the debug port's reset-state pulls (PA13/PA15/PB4 up,
## PA14 down, 40 k): the one part of the reset state the DC checks and the
## simulator read (`pinmux.pinPull`).
##
## Source: ST's `STM32_open_pin_data` (`mcu/STM32H563ZITx.xml`) -- the pin
## database STM32CubeMX itself reads -- cross-checked against the DS14258
## datasheet alternate-function table.  The `...ZIT6Q` part (internal SMPS) has a
## *different* LQFP-144 pinout -- three GPIOs give way to
## `VLXSMPS`/`VDDSMPS`/`VSSSMPS` and `PE1` returns at pin 141 -- and would need
## its own entry.

import verax/netlist/pinmux
import verax/units
export pinmux

registerPartPinmux(newPartPinmux("STM32H563",
  partNumbers = ["STM32H563ZIT6"],
  doc = "Arm Cortex-M33 MCU, LQFP-144 (full I/O map: GPIO + serial buses + ADC1/ADC2 + USB)",
  complete = true,
  peripherals = [
    # spi
    (name: "SPI1", iface: "spi"), (name: "SPI2", iface: "spi"), (name: "SPI3", iface: "spi"), (name: "SPI4", iface: "spi"),
    (name: "SPI5", iface: "spi"), (name: "SPI6", iface: "spi"),
    # i2c (I3C1 presents an I2C-compatible SCL/SDA)
    (name: "I2C1", iface: "i2c"), (name: "I2C2", iface: "i2c"), (name: "I2C3", iface: "i2c"), (name: "I2C4", iface: "i2c"),
    (name: "I3C1", iface: "i2c"),
    # adc (bare -- no InterfaceDef presents a multi-channel ADC)
    (name: "ADC1", iface: ""), (name: "ADC2", iface: ""),
    # usb (the part's one full-speed OTG peripheral; datasheet InstanceName is "USB")
    (name: "USB", iface: "usb2"),
    # jtag (the debug port; also SWD via the same physical pins)
    (name: "JTAG", iface: "jtag"),
    # uart
    (name: "LPUART1", iface: "uart"), (name: "UART4", iface: "uart"), (name: "UART5", iface: "uart"), (name: "UART7", iface: "uart"),
    (name: "UART8", iface: "uart"), (name: "UART9", iface: "uart"), (name: "UART12", iface: "uart"), (name: "USART1", iface: "uart"),
    (name: "USART2", iface: "uart"), (name: "USART3", iface: "uart"), (name: "USART6", iface: "uart"), (name: "USART10", iface: "uart"),
    (name: "USART11", iface: "uart")
  ],
  pins = [
    # --- Port A --------------------------------------------------------------
    (pin: "PA0", function: "GPIO"), (pin: "PA0", function: "SPI6.cs"), (pin: "PA0", function: "UART4.txd"), (pin: "PA0", function: "ADC1.in0"), (pin: "PA0", function: "ADC2.in0"),
    (pin: "PA1", function: "GPIO"), (pin: "PA1", function: "UART4.rxd"), (pin: "PA1", function: "ADC1.in1"), (pin: "PA1", function: "ADC2.in1"),
    (pin: "PA2", function: "GPIO"), (pin: "PA2", function: "USART2.txd"), (pin: "PA2", function: "ADC1.in14"), (pin: "PA2", function: "ADC2.in14"),
    (pin: "PA3", function: "GPIO"), (pin: "PA3", function: "SPI2.cs"), (pin: "PA3", function: "USART2.rxd"), (pin: "PA3", function: "ADC1.in15"), (pin: "PA3", function: "ADC2.in15"),
    (pin: "PA4", function: "GPIO"), (pin: "PA4", function: "SPI1.cs"), (pin: "PA4", function: "SPI3.cs"), (pin: "PA4", function: "SPI6.cs"), (pin: "PA4", function: "ADC1.in18"), (pin: "PA4", function: "ADC2.in18"),
    (pin: "PA5", function: "GPIO"), (pin: "PA5", function: "SPI1.sclk"), (pin: "PA5", function: "SPI6.sclk"), (pin: "PA5", function: "ADC1.in19"), (pin: "PA5", function: "ADC2.in19"),
    (pin: "PA6", function: "GPIO"), (pin: "PA6", function: "SPI1.miso"), (pin: "PA6", function: "SPI6.miso"), (pin: "PA6", function: "USART11.txd"), (pin: "PA6", function: "ADC1.in3"), (pin: "PA6", function: "ADC2.in3"),
    (pin: "PA7", function: "GPIO"), (pin: "PA7", function: "SPI1.mosi"), (pin: "PA7", function: "SPI6.mosi"), (pin: "PA7", function: "USART11.rxd"), (pin: "PA7", function: "ADC1.in7"), (pin: "PA7", function: "ADC2.in7"),
    (pin: "PA8", function: "GPIO"), (pin: "PA8", function: "I2C3.scl"), (pin: "PA8", function: "UART7.rxd"),
    (pin: "PA9", function: "GPIO"), (pin: "PA9", function: "LPUART1.txd"), (pin: "PA9", function: "SPI2.sclk"), (pin: "PA9", function: "USART1.txd"),
    (pin: "PA10", function: "GPIO"), (pin: "PA10", function: "LPUART1.rxd"), (pin: "PA10", function: "USART1.rxd"),
    (pin: "PA11", function: "GPIO"), (pin: "PA11", function: "SPI2.cs"), (pin: "PA11", function: "UART4.rxd"), (pin: "PA11", function: "USB.n"),
    (pin: "PA12", function: "GPIO"), (pin: "PA12", function: "SPI2.sclk"), (pin: "PA12", function: "UART4.txd"), (pin: "PA12", function: "USB.p"),
    (pin: "PA13", function: "GPIO"), (pin: "PA13", function: "JTAG.tms"),
    (pin: "PA14", function: "GPIO"), (pin: "PA14", function: "JTAG.tck"),
    (pin: "PA15", function: "GPIO"), (pin: "PA15", function: "SPI1.cs"), (pin: "PA15", function: "SPI3.cs"), (pin: "PA15", function: "SPI6.cs"), (pin: "PA15", function: "UART7.txd"), (pin: "PA15", function: "JTAG.tdi"),
    # --- Port B --------------------------------------------------------------
    (pin: "PB0", function: "GPIO"), (pin: "PB0", function: "ADC1.in9"), (pin: "PB0", function: "ADC2.in9"),
    (pin: "PB1", function: "GPIO"), (pin: "PB1", function: "ADC1.in5"), (pin: "PB1", function: "ADC2.in5"),
    (pin: "PB2", function: "GPIO"), (pin: "PB2", function: "SPI3.mosi"),
    (pin: "PB3", function: "GPIO"), (pin: "PB3", function: "I2C2.sda"), (pin: "PB3", function: "SPI1.sclk"), (pin: "PB3", function: "SPI3.sclk"), (pin: "PB3", function: "SPI6.sclk"), (pin: "PB3", function: "UART7.rxd"), (pin: "PB3", function: "JTAG.tdo"),
    (pin: "PB4", function: "GPIO"), (pin: "PB4", function: "SPI1.miso"), (pin: "PB4", function: "SPI2.cs"), (pin: "PB4", function: "SPI3.miso"), (pin: "PB4", function: "SPI6.miso"), (pin: "PB4", function: "UART7.txd"), (pin: "PB4", function: "JTAG.ntrst"),
    (pin: "PB5", function: "GPIO"), (pin: "PB5", function: "SPI1.mosi"), (pin: "PB5", function: "SPI3.mosi"), (pin: "PB5", function: "SPI6.mosi"), (pin: "PB5", function: "UART5.rxd"),
    (pin: "PB6", function: "GPIO"), (pin: "PB6", function: "I2C1.scl"), (pin: "PB6", function: "I2C4.scl"), (pin: "PB6", function: "I3C1.scl"), (pin: "PB6", function: "LPUART1.txd"), (pin: "PB6", function: "UART5.txd"), (pin: "PB6", function: "USART1.txd"),
    (pin: "PB7", function: "GPIO"), (pin: "PB7", function: "I2C1.sda"), (pin: "PB7", function: "I2C4.sda"), (pin: "PB7", function: "I3C1.sda"), (pin: "PB7", function: "LPUART1.rxd"), (pin: "PB7", function: "USART1.rxd"),
    (pin: "PB8", function: "GPIO"), (pin: "PB8", function: "I2C1.scl"), (pin: "PB8", function: "I2C4.scl"), (pin: "PB8", function: "I3C1.scl"), (pin: "PB8", function: "UART4.rxd"),
    (pin: "PB9", function: "GPIO"), (pin: "PB9", function: "I2C1.sda"), (pin: "PB9", function: "I2C4.sda"), (pin: "PB9", function: "I3C1.sda"), (pin: "PB9", function: "SPI2.cs"), (pin: "PB9", function: "UART4.txd"),
    (pin: "PB10", function: "GPIO"), (pin: "PB10", function: "I2C2.scl"), (pin: "PB10", function: "SPI2.sclk"), (pin: "PB10", function: "USART3.txd"),
    (pin: "PB12", function: "GPIO"), (pin: "PB12", function: "I2C2.sda"), (pin: "PB12", function: "SPI2.cs"), (pin: "PB12", function: "UART5.rxd"),
    (pin: "PB13", function: "GPIO"), (pin: "PB13", function: "SPI2.sclk"), (pin: "PB13", function: "UART5.txd"),
    (pin: "PB14", function: "GPIO"), (pin: "PB14", function: "SPI2.miso"), (pin: "PB14", function: "USART1.txd"),
    (pin: "PB15", function: "GPIO"), (pin: "PB15", function: "SPI2.mosi"), (pin: "PB15", function: "UART5.rxd"), (pin: "PB15", function: "USART1.rxd"),
    # --- Port C --------------------------------------------------------------
    (pin: "PC0", function: "GPIO"), (pin: "PC0", function: "ADC1.in10"), (pin: "PC0", function: "ADC2.in10"),
    (pin: "PC1", function: "GPIO"), (pin: "PC1", function: "SPI2.mosi"), (pin: "PC1", function: "ADC1.in11"), (pin: "PC1", function: "ADC2.in11"),
    (pin: "PC2", function: "GPIO"), (pin: "PC2", function: "SPI2.miso"), (pin: "PC2", function: "ADC1.in12"), (pin: "PC2", function: "ADC2.in12"),
    (pin: "PC3", function: "GPIO"), (pin: "PC3", function: "SPI2.mosi"), (pin: "PC3", function: "ADC1.in13"), (pin: "PC3", function: "ADC2.in13"),
    (pin: "PC4", function: "GPIO"), (pin: "PC4", function: "USART3.rxd"), (pin: "PC4", function: "ADC1.in4"), (pin: "PC4", function: "ADC2.in4"),
    (pin: "PC5", function: "GPIO"), (pin: "PC5", function: "ADC1.in8"), (pin: "PC5", function: "ADC2.in8"),
    (pin: "PC6", function: "GPIO"), (pin: "PC6", function: "USART6.txd"),
    (pin: "PC7", function: "GPIO"), (pin: "PC7", function: "USART6.rxd"),
    (pin: "PC8", function: "GPIO"),
    (pin: "PC9", function: "GPIO"), (pin: "PC9", function: "I2C3.sda"),
    (pin: "PC10", function: "GPIO"), (pin: "PC10", function: "SPI3.sclk"), (pin: "PC10", function: "UART4.txd"), (pin: "PC10", function: "USART3.txd"),
    (pin: "PC11", function: "GPIO"), (pin: "PC11", function: "SPI3.miso"), (pin: "PC11", function: "UART4.rxd"), (pin: "PC11", function: "USART3.rxd"),
    (pin: "PC12", function: "GPIO"), (pin: "PC12", function: "SPI3.mosi"), (pin: "PC12", function: "SPI6.sclk"), (pin: "PC12", function: "UART5.txd"),
    (pin: "PC13", function: "GPIO"),
    (pin: "PC14", function: "GPIO"),
    (pin: "PC15", function: "GPIO"),
    # --- Port D --------------------------------------------------------------
    (pin: "PD0", function: "GPIO"), (pin: "PD0", function: "UART4.rxd"),
    (pin: "PD1", function: "GPIO"), (pin: "PD1", function: "UART4.txd"),
    (pin: "PD2", function: "GPIO"), (pin: "PD2", function: "UART5.rxd"),
    (pin: "PD3", function: "GPIO"), (pin: "PD3", function: "SPI2.sclk"),
    (pin: "PD4", function: "GPIO"),
    (pin: "PD5", function: "GPIO"), (pin: "PD5", function: "USART2.txd"),
    (pin: "PD6", function: "GPIO"), (pin: "PD6", function: "SPI3.mosi"), (pin: "PD6", function: "USART2.rxd"),
    (pin: "PD7", function: "GPIO"), (pin: "PD7", function: "SPI1.mosi"),
    (pin: "PD8", function: "GPIO"), (pin: "PD8", function: "USART3.txd"),
    (pin: "PD9", function: "GPIO"), (pin: "PD9", function: "USART3.rxd"),
    (pin: "PD10", function: "GPIO"),
    (pin: "PD11", function: "GPIO"), (pin: "PD11", function: "UART4.rxd"),
    (pin: "PD12", function: "GPIO"), (pin: "PD12", function: "I2C4.scl"), (pin: "PD12", function: "I3C1.scl"), (pin: "PD12", function: "UART4.txd"),
    (pin: "PD13", function: "GPIO"), (pin: "PD13", function: "I2C4.sda"), (pin: "PD13", function: "I3C1.sda"),
    (pin: "PD14", function: "GPIO"), (pin: "PD14", function: "UART9.rxd"),
    (pin: "PD15", function: "GPIO"), (pin: "PD15", function: "UART9.txd"),
    # --- Port E (LQFP-144 non-Q: PE1 is not bonded out) ---------------------
    (pin: "PE0", function: "GPIO"), (pin: "PE0", function: "UART8.rxd"),
    (pin: "PE2", function: "GPIO"), (pin: "PE2", function: "SPI4.sclk"), (pin: "PE2", function: "UART8.txd"), (pin: "PE2", function: "USART10.rxd"),
    (pin: "PE3", function: "GPIO"), (pin: "PE3", function: "USART10.txd"),
    (pin: "PE4", function: "GPIO"), (pin: "PE4", function: "SPI4.cs"),
    (pin: "PE5", function: "GPIO"), (pin: "PE5", function: "SPI4.miso"),
    (pin: "PE6", function: "GPIO"), (pin: "PE6", function: "SPI4.mosi"),
    (pin: "PE7", function: "GPIO"), (pin: "PE7", function: "UART7.rxd"),
    (pin: "PE8", function: "GPIO"), (pin: "PE8", function: "UART7.txd"),
    (pin: "PE9", function: "GPIO"), (pin: "PE9", function: "UART12.rxd"),
    (pin: "PE10", function: "GPIO"), (pin: "PE10", function: "UART12.txd"),
    (pin: "PE11", function: "GPIO"), (pin: "PE11", function: "SPI4.cs"),
    (pin: "PE12", function: "GPIO"), (pin: "PE12", function: "SPI4.sclk"),
    (pin: "PE13", function: "GPIO"), (pin: "PE13", function: "SPI4.miso"),
    (pin: "PE14", function: "GPIO"), (pin: "PE14", function: "SPI4.mosi"),
    (pin: "PE15", function: "GPIO"),
    # --- Port F --------------------------------------------------------------
    (pin: "PF0", function: "GPIO"), (pin: "PF0", function: "I2C2.sda"),
    (pin: "PF1", function: "GPIO"), (pin: "PF1", function: "I2C2.scl"),
    (pin: "PF2", function: "GPIO"), (pin: "PF2", function: "UART12.txd"),
    (pin: "PF3", function: "GPIO"), (pin: "PF3", function: "USART11.txd"),
    (pin: "PF4", function: "GPIO"), (pin: "PF4", function: "USART11.rxd"),
    (pin: "PF5", function: "GPIO"), (pin: "PF5", function: "I2C4.scl"), (pin: "PF5", function: "I3C1.scl"), (pin: "PF5", function: "UART12.rxd"),
    (pin: "PF6", function: "GPIO"), (pin: "PF6", function: "SPI5.cs"), (pin: "PF6", function: "UART7.rxd"),
    (pin: "PF7", function: "GPIO"), (pin: "PF7", function: "SPI5.sclk"), (pin: "PF7", function: "UART7.txd"),
    (pin: "PF8", function: "GPIO"), (pin: "PF8", function: "SPI5.miso"),
    (pin: "PF9", function: "GPIO"), (pin: "PF9", function: "SPI5.mosi"),
    (pin: "PF10", function: "GPIO"),
    (pin: "PF11", function: "GPIO"), (pin: "PF11", function: "SPI5.mosi"), (pin: "PF11", function: "ADC1.in2"),
    (pin: "PF12", function: "GPIO"), (pin: "PF12", function: "ADC1.in6"),
    (pin: "PF13", function: "GPIO"), (pin: "PF13", function: "ADC2.in2"),
    (pin: "PF14", function: "GPIO"), (pin: "PF14", function: "ADC2.in6"),
    (pin: "PF15", function: "GPIO"), (pin: "PF15", function: "I2C4.sda"), (pin: "PF15", function: "I3C1.sda"),
    # --- Port G --------------------------------------------------------------
    (pin: "PG0", function: "GPIO"), (pin: "PG0", function: "UART9.rxd"),
    (pin: "PG1", function: "GPIO"), (pin: "PG1", function: "SPI2.mosi"), (pin: "PG1", function: "UART9.txd"),
    (pin: "PG2", function: "GPIO"), (pin: "PG2", function: "UART12.rxd"),
    (pin: "PG3", function: "GPIO"), (pin: "PG3", function: "UART12.txd"),
    (pin: "PG4", function: "GPIO"),
    (pin: "PG5", function: "GPIO"),
    (pin: "PG6", function: "GPIO"), (pin: "PG6", function: "I2C4.sda"), (pin: "PG6", function: "I3C1.sda"),
    (pin: "PG7", function: "GPIO"), (pin: "PG7", function: "I2C4.scl"), (pin: "PG7", function: "I3C1.scl"),
    (pin: "PG8", function: "GPIO"), (pin: "PG8", function: "SPI6.cs"),
    (pin: "PG9", function: "GPIO"), (pin: "PG9", function: "SPI1.miso"), (pin: "PG9", function: "USART6.rxd"),
    (pin: "PG10", function: "GPIO"), (pin: "PG10", function: "SPI1.cs"),
    (pin: "PG11", function: "GPIO"), (pin: "PG11", function: "SPI1.sclk"), (pin: "PG11", function: "USART10.rxd"),
    (pin: "PG12", function: "GPIO"), (pin: "PG12", function: "SPI6.miso"), (pin: "PG12", function: "USART10.txd"),
    (pin: "PG13", function: "GPIO"), (pin: "PG13", function: "SPI6.sclk"),
    (pin: "PG14", function: "GPIO"), (pin: "PG14", function: "SPI6.mosi"), (pin: "PG14", function: "USART6.txd"),
    (pin: "PG15", function: "GPIO"),
    # --- Port H --------------------------------------------------------------
    (pin: "PH0", function: "GPIO"),
    (pin: "PH1", function: "GPIO")
  ],
  # The debug port's reset state (RM0481, "SWJ debug port pins"): out of
  # reset these are already the JTAG alternate function, with JTDI, JTMS and
  # NJTRST pulled up and JTCK pulled down (JTDO/PB3 floats). The pulls are
  # the I/O's weak RPU/RPD, 40 k typical (30-50 k) in DS14258's I/O static
  # characteristics. They are what holds a TAP whose header is unfitted, so
  # every design using this part inherits them (`pinmux.pinPull`); a pin's
  # own `pull_up`/`pull_down` overrides one.
  resetPulls = [
    (pin: "PA13", kind: pkUp,   ohms: 40.kohm),   # JTMS/SWDIO
    (pin: "PA14", kind: pkDown, ohms: 40.kohm),   # JTCK/SWCLK
    (pin: "PA15", kind: pkUp,   ohms: 40.kohm),   # JTDI
    (pin: "PB4",  kind: pkUp,   ohms: 40.kohm),   # NJTRST
  ]))
