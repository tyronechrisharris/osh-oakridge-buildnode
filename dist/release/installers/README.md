# Offline prerequisite bundle

The offline bundle builder places vendor-supplied, checksum-verified installers in these directories. Installer binaries are deliberately not stored in source control.

```text
installers/
  windows-x86_64/
    Docker Desktop Installer.exe
    wsl.<version>.x64.msi
  ubuntu-24.04-x86_64/
    *.deb
  macos-arm64/
    Docker.dmg
```

Run `tools/offline/build-offline-bundle.ps1 -BundleProfile Both -CreateArchive` on a connected build workstation to create both Windows production artifacts. `offline-full` contains the approved installers and container images; `offline-images` omits the installers for hosts with an existing Docker runtime. Component versions, official URLs, and SHA-256 values are pinned in `tools/offline/components.windows-x86_64.json`. The offline OSCAR CLI never downloads software or container images.

Only redistribute installers when the vendor license permits it. Docker Desktop requires a paid subscription for government entities; the OSCAR CLI does not accept that agreement on the administrator's behalf. Document the source URL, version, architecture, SHA-256 digest, download date, and license with every approved release bundle.
