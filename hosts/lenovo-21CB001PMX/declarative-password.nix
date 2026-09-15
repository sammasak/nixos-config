# STAGED, NOT IMPORTED: lands in the tmpfs-switch generation, not before
# (plan §5.3 step 0a). Activation also needs a `lukas_password_hash` entry
# in modules/core/sops.nix (deferred — that tree is shared with acer-swift)
# and the real hash: `mkpasswd -m sha-512`, then
# `sops --config secrets/.sops.yaml -e --in-place secrets/core/lukas-password.yaml`.
# The committed value is a placeholder, not a real credential.
{ config, lib, ... }:
{
  users.mutableUsers = lib.mkForce false;
  users.users.lukas.hashedPasswordFile = config.sops.secrets."lukas_password_hash".path;

  # No root login path exists today (modules/core/services.nix
  # PermitRootLogin/AllowUsers) — matches that state explicitly.
  users.users.root.hashedPassword = "!";
}
