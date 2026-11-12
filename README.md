# efiosswitch

This is a repository that I dedicate for this tiny but helpfull tools for switching OS seamlessly from the active OS terminal. This tools designed specifically for UEFI schemes. It also equipped with safety in mind so you don't need to worry somethings broke.

## Motivations

There are a lot of projects out there aimming for OS switching to. The one approach is by making an EFI bootloader entry that specifically handles the OS decision right on the boot time. While this is the fanciest solutions, but it needs to install something to your EFI partition which potentially could go wrong.

So here is the point where I come from; a simple and portable tools to switch to another OS that totally safe and begineer friendly. Although this wasn't the straightforward solutions as like the earliest but it's way safer.

Alternatively, you still can summon the built-in UEFI boot menu by spamming Fn keys (F1-F12). The key you should spam is different across the board manufacturer.

## Download Guides
Windows user, choose efiosswitch.ps1 from this repository

## Running
For windows :
1. Right click the .ps1 scripts and press **Run with PowerShell**
2. Wait for the program to scan the EFI entry
3. Type the destined OS entry number presented
4. If you want to set the choosen OS entry as main boot priority then type y. If you just want to boot once type n
5. Please wait 12-15s as the program doing the job and running safety mechanism