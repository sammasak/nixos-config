# karta's live web root, 441b800: its source is not on GitHub, so the site is the nginx html root archived from the
# pod's image. requireFile fetches nothing: a host builds this only with the tarball added to its store by hand. The
# unpacked tree is fixed-output too, so its store path survives nixpkgs bumps and other hosts substitute it from acer.
{ requireFile, runCommand }:
let
  site = requireFile {
    name = "karta-web-441b800-site.tar.gz";
    sha256 = "07d5179276dae6c05e3dbdbf254994a6a2a4b8f81ab8e1461394bd348d6cc345";
    message = ''
      karta's archived site is not in the store. On a host with ~/archive/karta-441b800, run:
        nix-store --add-fixed sha256 ~/archive/karta-441b800/karta-web-441b800-site.tar.gz
    '';
  };
in
runCommand "karta-web-441b800"
  {
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-R4il1qJQmkVi1Myau53JDHu/CZ99B00GgaAL/h76iiw=";
  }
  ''
    mkdir $out
    tar -xzf ${site} -C $out --no-same-owner --no-same-permissions
  ''
