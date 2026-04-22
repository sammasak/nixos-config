# Custom packages overlay
{ claude-ctl-src }:
final: prev: {
  claude-ctl = final.callPackage ./claude-ctl.nix { src = claude-ctl-src; };
  codex = final.callPackage ./codex.nix { };

  # Patch CRIU 4.1.1 for kernel 6.16+ compatibility.
  # SO_PASSCRED/SO_PASSSEC on non-Unix sockets returns EOPNOTSUPP on
  # kernel 6.16+ (was ENOPROTOOPT). CRIU only skips ENOPROTOOPT, crashing
  # on any checkpoint attempt. Backport of upstream commit 4b73985.
  criu = prev.criu.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/criu-so-passcred-kernel-6.16.patch
    ];
  });

  # crun links against libcriu.so.2 at build time. Override to use the
  # patched criu above so CRIU checkpoints succeed on kernel 6.16+.
  crun = prev.crun.override { criu = final.criu; };
}
