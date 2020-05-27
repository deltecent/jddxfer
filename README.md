# PC2Flop and Flop2PC
## (for JADE Double D Controller in an Altair)

`PC2Flop` writes a SSSD soft-sectored 8" floppy with a disk image transmitted from a PC. The image is transmitted through a MITS 2SIO port at I/O address 10h or 12h, or an SIO port at address 00h, using the XMODEM protocol.  `Flop2PC` does the opposite and transmits an image of a SSSD soft-sectored 8" floppy to a PC.

These programs talk directly to the Jade Double D controller and do not require CP/M or an OS to function, but they do require that the Disk Control Module ("DCM") is running on the controller. If CP/M or other OS for the JADE Double D is not being used, `jddutil` can be used to inject DCM and initialize the controller.

Since this is a soft sectored controller, `PC2Flop` requires the destination disk to have been formatted at some point. Again, `jddutil` can be used to format a SSSD 8" disk.

These programs run standalone at 0x100 or under CP/M. Any type of disk can be read or written even if running under CP/M.  Disk images are available in this repository.

Standalone operation may be required to create a bootable disk when no other bootable disk is available. There are a couple of ways to load `PC2Flop` into a cold machine:

1) Use the front panel or Turnkey monitor to enter the octal bytes of the program listed in `LOADER.PRN`. Execute the loader by running from zero (no feedback is given), then send the file `PC2FLOP.COM` through the first 2SIO port. After transmission is complete, reset the computer and run `PC2Flop` at address 100h.

2) If you have an Intel hex file loader in PROM, load the file `PC2FLOP.HEX` and then run from 100h. A stand alone Intel hex loader that can be run from PROM is available at http://deramp.com/downloads/altair/software/roms/updated_roms.

When copying a disk image to the PC using `Flop2PC`, the program attempts several retries, including restoring the track both from zero and from past the current track. If the read still fails, the error is noted and the copy process continues so that the remainder of the disk can still be recovered. 

## Loading on CP/M
Following is a way to get `Flop2PC` onto a CP/M system for the first time using `PIP` and `LOAD` on the CP/M system. This requires a terminal emulator or file transfer program that can insert a delay between each character sent.  First, `PIP` is used to copy the Intel Hex version of `Flop2PC` to the CP/M system and save it as `FLOP2PC.HEX`, then `LOAD` is used to create the executable `FLOP2PC.COM`

```
A>PIP FLOP2PC.HEX=CON:[H]
```
Press `RETURN` and wait for CP/M to load `PIP` at which time you’ll see a line-feed. (There is no space between `:` and `[H]`)

Assuming Tera-Term, use the `Setup->Serial Port...` menu option to set the transmit delay for `msec/char` to `10`. Then send the file `FLOP2PC.HEX` using simple ASCII transfer. You will see the hex file displayed as it is transfers. It is OK if some lines don’t display at the left edge of the screen. File transfer will continue for a while after the file transfer dialog box closes. This is normal.

When file transfer is complete, type Ctrl-Z to signal end-of-file. `PIP` will exit to the `A>` prompt after a short delay for CP/M to warm start.
```
A>LOAD FLOP2PC
FIRST ADDRESS 0100
LAST  ADDRESS 03FB
BYTES READ 02FC
RECORDS WRITTEN 06
```
The numbers displayed by `LOAD` in the output above are only examples. Your numbers may vary.
