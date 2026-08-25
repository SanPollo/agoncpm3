# CP/M Plus for Agon Light



## About

This is a port of CP/M Plus (also known as CP/M 3) for the [Agon Light](https://www.olimex.com/Products/Retro-Computers/AgonLight2/open-source-hardware) open source modern retro computer.

It is styled after Amstrad CP/M Plus for the [CPC](https://en.wikipedia.org/wiki/Amstrad_CPC) and [PCW](https://en.wikipedia.org/wiki/Amstrad_PCW) range of computers.

The supervisor is based, in part, on the [Agon CP/M 2.2](https://github.com/nihirash/Agon-CPM2.2) port by Aleksandr Sharikhin (nihirash). If you like this project, then please check out his project, and maybe [buy him a coffee](https://ko-fi.com/D1D6JVS74). Personally, I'm a tea man.

### Features

* Bank switching between two eZ80 64K segments.
* Field Installable Device Drivers (FIDs) for additional hardware support.
* 60.76KB TPA.
* Up to 8x 8MB hard drive images, using the `nihirash` [CP/M Tools](https://github.com/lipro-cpm4l/cpmtools) [definition](./definition) to maintain compatibility with [CP/M 2.2](https://github.com/nihirash/Agon-CPM2.2).
* Time and date support.
* 304KB RAM drive.

[Top](#cp-m-plus-for-agon-light)

## Installation

1. Copy the contents of the `bin/` directory to a new subdirectory on your Agon Light's SD card e.g. `/cpm3`

2. Boot the Agon. If it automatically boots into BBC BASIC then enter: `*BYE*`

3. Change to the subdirectory you copied CP/M Plus to, and run `cpm3.bin` e.g.

