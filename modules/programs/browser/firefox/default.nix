# Firefox browser with privacy-focused settings
{ ... }:
{
  stylix.targets.firefox.profileNames = [ "default" ];

  programs.firefox = {
    enable = true;

    profiles.default = {
      isDefault = true;
      settings = {
        # Privacy
        "privacy.resistFingerprinting" = true;
        "privacy.trackingprotection.enabled" = true;
        "privacy.trackingprotection.socialtracking.enabled" = true;

        # Disable telemetry
        "toolkit.telemetry.enabled" = false;
        "toolkit.telemetry.unified" = false;
        "datareporting.healthreport.uploadEnabled" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;

        # Disable search suggestions
        "browser.search.suggest.enabled" = false;

        # Disable network prediction
        "network.predictor.enabled" = false;

        # Disable Pocket
        "extensions.pocket.enabled" = false;

        # Disable Firefox Suggest sponsored content
        "browser.urlbar.suggest.quicksuggest.sponsored" = false;
        "browser.urlbar.suggest.quicksuggest.nonsponsored" = false;

        # Force dark mode
        "ui.systemUsesDarkTheme" = 1;
        "widget.content.preferred-color-scheme" = 0;
        "browser.theme.content-theme" = 0;
        "browser.theme.toolbar-theme" = 0;
      };
    };
  };
}
