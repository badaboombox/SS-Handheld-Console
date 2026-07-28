# Licensing

This project is dual-licensed by directory, because the gateware and the hardware
have different origins and obligations.

## rtl/ is GPL-3.0-or-later

The RTL is a derivative work of [RasterIX](https://github.com/ToNi3141/RasterIX),
which is licensed GPL-3.0. Strong copyleft propagates: any distributed work that
incorporates GPL-3.0 code must itself be GPL-3.0-compatible. So all the Verilog
under rtl/ is licensed GPL-3.0-or-later. The full text is in [LICENSE](LICENSE).

`SPDX-License-Identifier: GPL-3.0-or-later`

## hardware/ is CERN-OHL-P-2.0

The PCB and KiCad design under hardware/ is an independent work. It hosts the FPGA;
it is not a derivative of the GPL RTL. It is licensed under the CERN Open Hardware
Licence Version 2, Permissive (CERN-OHL-P-2.0), so the board can be used, modified,
and manufactured freely. The full text is in [hardware/LICENSE](hardware/LICENSE).

`SPDX-License-Identifier: CERN-OHL-P-2.0`

## Media

Render frames and documentation images (sim/proof-of-concept/ and the README
images) are licensed CC-BY-4.0.

`SPDX-License-Identifier: CC-BY-4.0`

## Third party

RasterIX (external/RasterIX, pulled in as a submodule) is copyright ToNi3141 and
licensed GPL-3.0. It is not redistributed in this repository. See its own
repository for its license and terms.