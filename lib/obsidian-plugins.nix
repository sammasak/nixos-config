{ pkgs, lib }:

rec {
  # Helper to build Obsidian community plugins from GitHub releases
  buildObsidianPlugin = {
    pname,
    version,
    owner,
    repo,
    sha256,
  }: pkgs.stdenv.mkDerivation {
    inherit pname version;

    src = pkgs.fetchzip {
      url = "https://github.com/${owner}/${repo}/releases/download/${version}/${pname}.zip";
      inherit sha256;
      stripRoot = false;
    };

    dontBuild = true;

    installPhase = ''
      mkdir -p $out
      cp -r * $out/
    '';

    meta = with lib; {
      homepage = "https://github.com/${owner}/${repo}";
      platforms = platforms.all;
    };
  };

  # Pre-packaged essential plugins
  dataview = buildObsidianPlugin {
    pname = "dataview";
    version = "0.5.67";
    owner = "blacksmithgu";
    repo = "obsidian-dataview";
    sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # TODO: Update with actual hash
  };

  templater = buildObsidianPlugin {
    pname = "templater-obsidian";
    version = "2.7.1";
    owner = "SilentVoid13";
    repo = "Templater";
    sha256 = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="; # TODO: Update with actual hash
  };

  obsidian-git = buildObsidianPlugin {
    pname = "obsidian-git";
    version = "2.30.1";
    owner = "denolehov";
    repo = "obsidian-git";
    sha256 = "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="; # TODO: Update with actual hash
  };
}
