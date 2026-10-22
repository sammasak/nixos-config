# nix-audit pilot

The Lenovo-only Home Manager package pins nix-audit `0.1.0` to source revision
`12d640a542957e31680646e9f25c9f6c63e2564e` with a fixed Nix hash. The build
retains that revision so `nix-audit --version` and JSON producer metadata
identify the source. This is an untagged upstream candidate for read-only use,
not an approved security gate.

```sh
command -v nix-audit
nix-audit --version
nix --version
command -v grype || true
command -v vulnix || true
nix-audit scan /run/current-system --no-scan
```

`--no-scan` inventories the already-built running closure; it does not assess
vulnerabilities and does not invoke Grype or Vulnix. It needs no root access.
Do not add `--gate` to rebuild, deploy, or CI workflows. Full scanner runs may
download databases, and Vulnix requires network access; use them only when
explicitly requested and report incomplete scanner coverage as unknown, not
clean.
