# Not in nixpkgs. Virtual-radio medium simulator for mac80211_hwsim: mediates
# frames between simulated radios so the rf-lab sim has a real data plane and can
# model loss/delay for chaos tests. No physical RF. Upstream has no releases, so
# a commit is pinned.
{
  lib,
  stdenv,
  fetchFromGitHub,
  pkg-config,
  libnl,
  libconfig,
}:
stdenv.mkDerivation {
  pname = "wmediumd";
  version = "0-unstable-2024-05-16";

  src = fetchFromGitHub {
    owner = "bcopeland";
    repo = "wmediumd";
    rev = "717e5d7fcc23eecbc8e32bd897a8fd4b1e3ba640";
    hash = "sha256-P1UCuQxTo70oJ/w3iIdnNY+EygqDvOyr1qJrCuyCnx0=";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libnl libconfig ];

  makeFlags = [ "PREFIX=$(out)" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 wmediumd/wmediumd $out/bin/wmediumd
    runHook postInstall
  '';

  meta = {
    description = "Wireless medium simulator for mac80211_hwsim";
    homepage = "https://github.com/bcopeland/wmediumd";
    license = lib.licenses.gpl2Plus;
    mainProgram = "wmediumd";
    platforms = lib.platforms.linux;
  };
}
