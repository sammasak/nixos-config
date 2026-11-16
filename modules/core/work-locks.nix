# The heavy-work and light-work lock lanes of this physical host. modules/workers/core.nix binds the directory read-only
# into every guest, so `flock -o /run/work-locks/<lane>.lock` on the host and in its guests takes one inode. The files
# exist beforehand because a guest cannot create one on its read-only bind; root-owned in a 0755 directory, no session
# can replace a lock's inode with its own.
let
  file = {
    mode = "0644";
    user = "root";
    group = "root";
  };
in
{
  systemd.tmpfiles.settings.work-locks = {
    "/run/work-locks".d = {
      mode = "0755";
      user = "root";
      group = "root";
    };
    "/run/work-locks/heavy-work.lock".f = file;
    "/run/work-locks/light-work.lock".f = file;
  };
}
