# ParrotOS-Steam-Native

Run **Steam** and its ~350 32-bit dependencies on a **pure 64-bit** Debian / Parrot
host — **without** enabling the `i386` architecture and **without** ever touching
the host `dpkg` database.

> The problem everyone gives up on: *"just use Flatpak"*. This project takes the
> hard road instead.

---

## The multiarch wall

Parrot OS (like Debian) ships **amd64-only**. Steam needs ~350 `i386` libraries.
The obvious move — `dpkg --add-architecture i386` + adding Debian 32-bit repos —
fails because the two architectures drift out of sync:

```
libexpat1:i386 Breaks libexpat1 (!= 2.8.3-1~deb13u1)
E: Unable to correct problems, you have held broken packages.
```

Package versions differ by a suffix (`+deb13u2` vs `+deb13u1`), `apt` refuses to
move, and the whole system is left in a broken state. This is the wall.

## How this project breaks it

Three mechanisms, each verified end-to-end on Debian 13 (trixie) / amd64:

| # | Exploit | What it does |
|---|---------|--------------|
| **1** | **Isolated apt state** | `apt` runs against a *private* `status`/`lists`/`cache` in the runtime dir. The `i386` architecture is declared **only there**. The host stays bit-for-bit pure `amd64` and `apt` can never be corrupted. |
| **2** | **Download, never install** | `apt-get install --download-only` resolves the full dependency closure (i386 **and** amd64) and fetches the `.deb`s. Nothing is registered in the host `dpkg`. |
| **3** | **Portable 32-bit runtime** | The `.deb`s are unpacked into a private prefix. The 32-bit loader `ld-linux.so.2` plus all `.so` files are assembled into `lib32/`. Steam runs through that loader with a scoped `LD_LIBRARY_PATH`. |

```
host (pure amd64)                    runtime (/opt/parrot-steam)
┌───────────────────────┐            ┌──────────────────────────────┐
│ dpkg: 0 i386 packages │            │ loader/ld-linux.so.2  (32-bit)│
│ apt : i386 NOT enabled│            │ lib32/  416 .so + shims       │
│                       │  download  │ lib64/  448 .so               │
│  apt (isolated state) │───────────▶│ .build/debs/  348 .deb        │
│  └─ private status    │            │ steam.sh  (wrapper)           │
└───────────────────────┘            └──────────────────────────────┘
        untouched                            self-contained
```

## Usage

```bash
sudo ./parrot-steam-native.sh install     # download + extract + assemble runtime
sudo ./parrot-steam-native.sh doctor      # host readiness + runtime state (read-only)
sudo ./parrot-steam-native.sh run         # launch Steam through the runtime
sudo ./parrot-steam-native.sh smoke       # headless validation under Xvfb
     ./parrot-steam-native.sh status      # show runtime contents
sudo ./parrot-steam-native.sh clean       # drop the build cache (keep the runtime)
sudo ./parrot-steam-native.sh uninstall   # remove everything
```

### Headless smoke test

`smoke` starts a throwaway Xvfb display and proves the runtime works before a
real launch:

1. a real i386 binary executes under the display;
2. the 32-bit GL stack loads (NVIDIA vendor lib or Mesa);
3. optionally, Steam's own bootstrap runs end to end.

```bash
sudo PARROT_STEAM_SMOKE_STEAM=1 PARROT_STEAM_SMOKE_TIMEOUT=180 \
  ./parrot-steam-native.sh smoke
```

Proven on Debian 13 / amd64: the smoke test **downloads the 19 MB Steam
bootstrap, runs `steam.sh`, and the real 32-bit client proceeds to download the
full client** — with the host `dpkg` still reporting **0** i386 packages.

### The `/lib/ld-linux.so.2` link

Steam's 32-bit client is built with `PT_INTERP=/lib/ld-linux.so.2`, and its
child processes (updater, helper UIs) are `exec`'d through that path. On a pure
amd64 host that path does not exist, so the children fail with
`cannot open shared object file`. `install` therefore creates **one tracked,
reversible symlink**:

```
/usr/lib/ld-linux.so.2 -> /opt/parrot-steam/loader/ld-linux.so.2
```

It is recorded in `.system-loader-link`, removed by `uninstall`, and never
overwrites an existing foreign file. Opt out with
`PARROT_STEAM_NO_SYSTEM_LINK=1`.


### Configuration (environment)

| Variable | Default | Meaning |
|----------|---------|---------|
| `PARROT_STEAM_DIR` | `/opt/parrot-steam` | runtime prefix |
| `PARROT_STEAM_SUITE` | `trixie` | Debian suite the runtime is pinned to |
| `PARROT_STEAM_MIRROR` | `http://deb.debian.org/debian` | main mirror |
| `PARROT_STEAM_SECURITY` | `http://deb.debian.org/debian-security` | security mirror |
| `PARROT_STEAM_BIN` | auto-detected | explicit path to the Steam binary |
| `PARROT_STEAM_SMOKE_STEAM` | `0` | `1` = also run Steam's bootstrap in `smoke` |
| `PARROT_STEAM_SMOKE_TIMEOUT` | `120` | max seconds for the Steam bootstrap |
| `PARROT_STEAM_NO_SYSTEM_LINK` | `0` | `1` = do not create `/usr/lib/ld-linux.so.2` |
| `PARROT_NVIDIA_PROC` | `/proc/driver/nvidia/version` | NVIDIA module version source |

## Why pin the runtime to its own suite

Steam's 32-bit blobs are old and expect the libraries they were built against.
If they link against the host's **newer** glibc/Mesa, you get the classic
`GLIBC_2.xx not found` / crash-on-launch. Pinning the runtime to one known-good
suite keeps the 32-bit set **self-consistent** and insulated from the host.

The script also installs the usual "old tech" compatibility shims inside the
runtime (e.g. the legacy `libudev.so.0` soname that Steam still requests).

## NVIDIA 32-bit GL/Vulkan mapping

The proprietary NVIDIA driver installs its user-space libraries for the **host**
architecture only (`amd64`). Steam is 32-bit and needs the 32-bit GL/Vulkan
stack — and the NVIDIA user-space libraries **must match the loaded kernel
module version exactly**, otherwise every GL/Vulkan call fails with
`Driver/library version mismatch`.

`install` therefore:

1. Reads the version of the **already loaded** kernel module from
   `/proc/driver/nvidia/version` (override with `PARROT_NVIDIA_PROC`).
2. Maps the matching 32-bit user-space libraries into `lib32/`, creating both
   the versioned soname (`libGLX_nvidia.so.550.120`) and the unversioned alias
   (`libGLX_nvidia.so`) the loader asks for.
3. **Rejects** any library whose version disagrees with the kernel module — the
   exact mismatch that breaks Steam.
4. If 32-bit objects are missing on the host, fetches them through the same
   **isolated apt state** (`nvidia-driver-libs:i386`) and unpacks them into the
   runtime — the host `dpkg` is still never touched.
5. Writes a 32-bit Vulkan ICD manifest (`vulkan/nvidia_icd.json`) pinned to the
   mapped driver version.

The launcher exports `VK_ICD_FILENAMES`, `VK_DRIVER_FILES`,
`__GLX_VENDOR_LIBRARY_NAME=nvidia` and `LIBGL_DRIVERS_PATH` so the 32-bit
GLVND/Vulkan loaders pick up the mapped libraries.

`doctor` reports the mapping status:

```
==> NVIDIA
  module noyau chargé  : oui
  version du module    : 550.120
  libs 32-bit trouvées : 6/11
  version concordante  : 5/11
```

```bash
sudo ./tests/test-nvidia.sh    # simulated driver — runs with no GPU present
```

## Requirements

- x86-64 host with kernel 32-bit compat (`CONFIG_IA32_EMULATION`, on by default).
- `dpkg-deb`, `apt-get`, `find` (all present on Debian/Parrot).
- root, or passwordless `sudo`, for writing the runtime prefix.

## Verification

```bash
sudo ./tests/test-runtime.sh   # runtime: 11 checks
sudo ./tests/test-nvidia.sh    # NVIDIA mapping, simulated driver: 8 checks
```

The runtime suite checks that the runtime resolves 32-bit dependencies with
**zero** missing libraries, actually **executes** a real i386 binary, and that
the system loader path is linked — while the host `dpkg` still reports **0**
i386 packages.

## Status

Core mechanism proven end to end on Debian 13 / amd64:

- 348 `.deb` fetched (195 i386) via isolated apt — host `dpkg` untouched.
- 416 `lib32` objects + 448 `lib64` objects assembled.
- 32-bit loader executes; `libgtk-3.so.0` resolves **63/63** dependencies.
- Real i386 binaries (`gio-querymodules`, `gdk-pixbuf-query-loaders`) run.
- **Steam itself runs**: the smoke test downloads the 19 MB bootstrap, launches
  `steam.sh`, and the real 32-bit client (`ubuntu12_32/steam`) proceeds to
  download the full client through the portable runtime.

Test suites: `test-runtime.sh` **11/11**, `test-nvidia.sh` **8/8**.

### Known limitations

- Validated on a headless server with a software GL stack. On a real machine,
  the NVIDIA path maps the vendor libraries (see above); Intel/AMD use the
  distribution Mesa libs already present in `lib32`.
- Steam's first launch downloads ~2.5 GB of client data — this is Steam's own
  bootstrap, independent of this project.


## License

MIT
