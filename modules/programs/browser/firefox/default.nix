{ ... }:
{
  stylix.targets.firefox.profileNames = [ "default" ];

  programs.firefox = {
    enable = true;
    configPath = ".mozilla/firefox";

    profiles.default = {
      isDefault = true;
      settings = {
        # fingerprintingProtection, not resistFingerprinting: RFP spoofs
        # timezone, screen size and canvas to join an anonymity set this
        # machine is never in (a logged-in daily driver). The cost is real —
        # broken canvas rendering, wrong local times — for no gain. FPP blocks
        # known fingerprinting scripts without the breakage.
        "privacy.fingerprintingProtection" = true;
        "privacy.trackingprotection.enabled" = true;
        "privacy.trackingprotection.socialtracking.enabled" = true;

        "toolkit.telemetry.enabled" = false;
        "toolkit.telemetry.unified" = false;
        "datareporting.healthreport.uploadEnabled" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;

        "browser.search.suggest.enabled" = false;

        "network.predictor.enabled" = false;

        "extensions.pocket.enabled" = false;

        "browser.urlbar.suggest.quicksuggest.sponsored" = false;
        "browser.urlbar.suggest.quicksuggest.nonsponsored" = false;

        "ui.systemUsesDarkTheme" = 1;
        "layout.css.prefers-color-scheme.content-override" = 0; # 0 = dark, 1 = light, 2 = system
        "browser.theme.content-theme" = 0; # Dark
        "browser.theme.toolbar-theme" = 0; # Dark
        "browser.in-content.dark-mode" = true;
        "extensions.activeThemeID" = "firefox-compact-dark@mozilla.org";
      };
    };
  };
}
