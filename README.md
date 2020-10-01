# hyperion-vero4k
Specific to the OSMC box "Vero4K".

Provides:
* Installer for Hyperion.ng (next gen) from binaries
* Custom build from source.
* Dialog based command-line GUI

---
# Usage

```
sudo apt-get install git
git clone https://github.com/hissingshark/hyperion-vero4k.git
cd hyperion-vero4k
sudo ./install.sh
```
To reinterate the build advice:
```
This software is intended for the Vero4K running OSMC, therefore options relating to:  

  1. The Raspberry Pi (dispmanx),
  2. An X environment,
  3. An Apple/OSX setup

are unsupported - likely failing to build.

**You are recommended at this time to: **
   ENABLE AMLOGIC
   ENABLE FB
   ENABLE V4L2

   DISABLE Tests
   and everything else to be honest.
```
---
# Post install
Edit the configuration using the built-in web GUI:  
\<your.server.ip.address:8090\>
* The official Android remote now appears to be working again for ng too!  
https://play.google.com/store/apps/details?id=nl.hyperion.hyperionfree
* The Android remote by BioHaZard1 (very alpha and not been updated in a long while)
https://github.com/BioHaZard1/hyperion-android

---
Plenty of forum advice for tech and configuration:
* https://hyperion-project.org/wiki/Main
* https://discourse.osmc.tv/t/osmc-and-hyperion/23293
