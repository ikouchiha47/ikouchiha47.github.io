---
active: true
layout: post
title: "Lameboy"
subtitle: "Yet yet another gameboy emulator"
description: "An attempt at writing a gameboy emulator and running it on FPGA"
date: 2024-04-20 00:00:00
background: '/img/gameboycollage.jpg'
---


# Emulating the Gamebouy

I have never played with one, and maybe I don't want to either. While that
doesn't mean I don't like the engineering behind it.

After spending a good length of time with your keyboard, its probably
pre-destined for most developers to end up writing an emulator. I maybe a bit
late to the party. But I come in with the newest sick language in town. [Zig](https://ziglang.org/documentation/master/)

At the time of writing this, zig was yet to release their 0.12.0 version. This
version included the package manager. And I was using their master branch. It
just feel real *hip* to wait for a feature land into production in near real-time in opensource world.

Anywho.

I was inspired by the history of how came into being. From two youtube videos:

- [How the Game Boy ᵃˡᵐᵒˢᵗ ruined Nintendo](https://www.youtube.com/watch?v=9Ki-kH751_8)
- [The Ultimate Gameboy Talk](https://www.youtube.com/watch?v=HyzD8pNlpwI)


At this time, I was also, reading how memory and cpu works. And writing an
emulator felt like the right idea to understand this better.

The choice of zig is mostly because it was a better C. Without the package
manager thought, I would have gone back to `golang`

<br/>

## Chip 8

Its a customary step in the world emulator dev, to start with a CHIP-8 emulator,
before attempting a `NES`, or `GB` and then a `GBA`.

CHIP-8 is not like gameboy, it's more of a programming language, which came with its own VM, much like
java. This allowed people to write video games easier.

Gameboy on the other hand used a Silicon on Chip (LR35902) as its processor, RAM capable of 
fetching, decoding and executing instructions. 

One of the **main differences** is the clock cycle. CHIP-8 running on a VM, was
too simple. Most instructions now, are assumed to take the same clock cycle. The
clock those days wee too less, so, those era of machines took some time to
execute the equivalent CPU instruction, but overall 60Hz.

That's approximately 16 ticks. (1/60) * 1000. 

While the gameboy's processor took different number of clock cycles, for
different instructions. 

* Although some CHIP-8 emulations tries to follow the [Scheduling frequency](https://jackson-s.me/2019/07/13/Chip-8-Instruction-Scheduling-and-Frequency.html). But they do an equivalent of `time.sleep(ms)`, but it's not the correct way, because you are effectively robbing the cpu in the vm from execute any work inbetween. *

The best way to do this is to use a 
```
enum CpuState {
    Running
    IoWaiting
}
```
and, then use the `ticks` logic provided by the **UI library**. So for
`javascript` it would be `requestAnimationFrame`, for **cliers**, it would be
the ticks provided by the `SDL2` library. (or whatever your prefered is, just
don't sleep.). Every tick, the exectuor always renders, and runs the cpu cycle
as long as the `CpuState` is `Running`.

So, the CPU execution stops only when you are waiting for an user input, in
which case `CpuState` is `IoWaiting`.



The [Wikipedia](https://en.wikipedia.org/wiki/CHIP-8) link does a better job of explaning what it is. CHIP-8 emulators need to 
implement only 34 instructions, *and you can skip the sound implementation ;)*

Here is the docs from [https://web.archive.org/web/*/https://devernay.free.fr/hacks/chip8/C8TECH10.HTM](/posts/chip8.html), in a better format. Following the rules from [http://bettermotherfuckingwebsite.com/](http://bettermotherfuckingwebsite.com/)

And people have written in details on how it works, and how to implement one:

- [https://austinmorlan.com/posts/chip8_emulator/](https://austinmorlan.com/posts/chip8_emulator/)
- [https://tobiasvl.github.io/blog/write-a-chip-8-emulator/](https://tobiasvl.github.io/blog/write-a-chip-8-emulator/)

are the two popular ones. Wikipedia article is your best guide. In case you face
issues, the [r/EmuDev](https://www.reddit.com/r/EmuDev/) , reddit community is
pretty helpful and so is their discord channel.

In the end it should look like:

<img src="/img/invaders_screen_1.png" alt="invaders loading screen" width="400"/>



<img src="/img/invaders_screen_2.png" alt="game screen" width="400"/>


#### Some learnings from CHIP-8

- A memory, is formed using a gated latch or transistors. The first one is SRAM
  and the second is a DRAM. Both have their advantages and disadvantages.

- This latches have a data line and a write enabled line. So, a latch can store
  1 bit of memory (1 or 0). For 8 bits, we need 8 registers, addressing memory
  (2^8=)256bits

- As memory grew, these cells were arranged in matrices. The addressing is
  therefore must consists of which row and column the memory cell is in.
  Further memory is also arranged in banks and multiple banks are grouped
  together. This all leads you to `page`, `page frames`, `TLB`, `MMU`, and `OS
  Pages`

- A modern day DRAM consumes much less voltage to indicate a bit (1/0), than
  SRAM. While SRAMs don't suffer from data leakage, DRAMs have cacpitors as
  memory cells. So each read causes some voltage to leak while reading, and
  hence the data needs to be written back. Also a different module to make sure
  the data is not lost overtime.

- Given the above, DRAMs henceforth, needs electricity to keep running. And is
  much much much faster than SRAM. 

- CPU moves the data between the DRAM and the SSD. Here we can read in details
  about memory banks and how these days DRAMs, uses 32bit data lines and
  control wires works, further by splitting memory in 8bits of 4 groups. This
  memory banking will come in handy when building the gameboy emulator. For
  **CHIP-8** everything fits in memory.

- Although a chip-8 uses 8bit registers, instructions requires 16bits, and
  this is done, by accessing 2 words, using the **Program Counter**. And then
  using a 16bit register, to store the two 8bit values. `(lo << 8) as u16 | hi`

- Processing each opcode, it doesn't take much of a learning curve once you have
  figured out bit manipulation. One of the things to keep it mind, is to clamp
  the values for each registers, and program counter, so that memory access doesn't 
  go out of available space. 

- **Timing** is a bitch.

- **Overall**, its quite fun to watch how fast the cpu `Fetch`, `Decode` and
  `Execute` cycle works.

- The last thing was interupt handling. The way interrupts are handled is, when
  you press a key, the CPU state changes, and it takes the key pressed, is puts
  in a register. After which, the CPU state is changed to `Running`.
  The program (in this case the CHPI-8 game), is responsible for using an
  Instruction to read this registered key pressed from the `register`.
  This is called **Memory Mapped IO**



**Implementation Gotchas**

- For each stage, use the chip8 programs that are used to test the emulator,
  [here](https://github.com/Timendus/chip8-test-suite)
- The initial commit, should contain, initializing the empty memory, adding the
  sprites and then loading the game data into memory from the address 0x0200
- With each step, test the emulator with the **roms** in the `test suite`.
- Try to display the IBM Logo as the first step. (I know, IBM. What days).
- Get familiar with writing shit in hex. Like `0x1000` , for 4kb. (0-4095).


<br/>

## Gamebouy

*Turn down for what.*


There are a couple of things to be excited about, while making the emulator for
gameboy.

*I am skipping the sound for this one too, I only like trumpet music*

- The games sometimes, are much larger than then available memory a gameboy had
  to deal with. Which was somewhere around 64K address space. So, shit like
  `0xffff`

- You have only 32KB of ROM, where game is read from. And the rest 32KB is
  distributed amongs VRAM, ERAM, HRAM etc. The ROM is more of a switchable ROM.

- For games that don't fit in the address range (0x4000-0x7FFF) , they need to
  be loaded from disk, the memory in cartdige i guess.

- 16bits are used for addressing. Including peripherials.



**Sources**:

- [https://gbdev.gg8.se/wiki/articles/CPU_Registers_and_Flags](https://gbdev.gg8.se/wiki/articles/CPU_Registers_and_Flags)
- [https://mgba-emu.github.io/gbdoc/](https://mgba-emu.github.io/gbdoc/)
- [https://rylev.github.io/DMG-01/public/book/cpu/registers.html](https://rylev.github.io/DMG-01/public/book/cpu/registers.html)
- [https://blog.rekawek.eu/2017/02/09/coffee-gb/](https://blog.rekawek.eu/2017/02/09/coffee-gb/)


To be continued...
