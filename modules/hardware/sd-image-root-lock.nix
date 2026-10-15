# The stock aarch64 SD image ships root with an empty password. With
# mutableUsers = true, users.users.root.hashedPassword is applied only when the
# user is first created, so it never reaches root (the image already made it) —
# leaving console/serial root login open. Lock it idempotently at activation,
# but only while still empty, so a deliberately set password is left alone.
{ pkgs, ... }:
{
  system.activationScripts.lockEmptyRootPassword = {
    deps = [ "users" ];
    text = ''
      if [ -z "$(${pkgs.getent}/bin/getent shadow root | cut -d: -f2)" ]; then
        ${pkgs.shadow}/bin/usermod -p '!' root
      fi
    '';
  };
}
