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

