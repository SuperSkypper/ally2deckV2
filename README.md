
# Ally2Deck V2
The original script from [4perture](https://github.com/4PERTURE/ally2deck) wasn’t working for me, so I used Claude to modify it. As far as I understood, the script had fixed names for the driver files, but it seems Asus changed these names, which broke the script, that’s what I fixed. I also tried to make it work even if the file names are different.

The installation instructions remain the same.

I tested it with two ROG Xbox Ally drivers:

V32.0.21043.3002 - the GPU video encoder didn’t work in OBS.

V32.0.21025.27003 - the GPU video encoder worked in OBS.

I also tried several ways to get this working with Secure Boot, but unfortunately I couldn’t. So it doesnt work with Valorant, Call of Duty, Fortnite and another games that uses anticheat.

# How To Use:
- 1 - Download AutoPatch.ps1 from this repository.
- 2 - Download AMD Graphics Driver from the [Xbox ROG Ally Driver Page](https://rog.asus.com/gaming-handhelds/rog-ally/rog-xbox-ally-2025/helpdesk_download/).
- 3 - Place both files in the same folder and rename the driver to AMDDriver.exe.
- 4 - Right-click AutoPatch.ps1: Run with Powershell.
  - The script will download and install all dependencies on its own (7zip, Windows SDK).
- 5 - Reboot the Deck to enter in driver test mode.
- 6 - Install Driver Manually
  - Open Device Manager > Display Drivers > Right Click > Update Driver > Browse my computer > Let me pick > Have disk > Browse > Go to inside the driver folder Packages/Drivers/Display/WT6A_iNF > Select u0420842.inf
- 7 - Restart

I cannot provide the driver as it is AMD's proprietary code. But with these instructions, you'll be able to do it yourself.

# Known Issues:
- Screen won't turn on after suspension
- EasyAC games will not work due to testsigning being off, so no Fortnite, Rocket League...
- No Secure Boot, so no Call of Duty, Battlefield or Valorant...
--- 

This script will extract, patch and sign the ROG XBOX ALLY AMD Graphics Driver so that it works on the Steam Deck.
It is highly experimental (and will always be, we are literally patching and installing a driver not designed for our device).
Use it at your own risk.
Tested on Windows 11 Enterprise LTSC, with the 25H2 update manually installed.
This script was built based on the work from [otti83](https://github.com/otti83/apu_driver_test).
It was made to simplify and automate the process so that any user can try this.

# Disclaimer:
I am NOT responsible for any issues caused by using this script.
It is provided as-is, and the user acknowledges and accepts the risks of using it.
This script enables testsigning as it is required for us to use self-signed drivers.
While this is a security risk, just make sure you aren't downloading any sus drivers from shady websites.
If you get a watermark on your desktop, you can remove it with [Universal Watermark Disabler](https://winaero.com/download-universal-watermark-disabler/).

Please report any issues you have, as I tested it on my system and it works fine, but that might not be the case for everyone.
