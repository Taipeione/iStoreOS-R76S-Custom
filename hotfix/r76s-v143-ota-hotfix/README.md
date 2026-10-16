# R76S-V1.4.3 OTA channel hotfix

This package changes only `/usr/libexec/r76s/r76s-ota` on an existing
R76S-V1.4.3 system. It changes the stable metadata source from the pinned
`R76S-V1.4.3` Release to the `R76S-stable` metadata Release. The signed
metadata still supplies the actual V1.4.4 firmware URL, SHA256, device and
target checks.

`install.sh` refuses to run unless the device revision and original client
SHA256 match the published V1.4.3 artifact. It backs up the original file,
performs a syntax check, and never downloads firmware or calls `sysupgrade`.

`rollback.sh` restores the recorded original client. The package does not
touch network, PPPoE, DNS, PassWall, passwords, `/tmp/firmware.img`, or user
configuration.
