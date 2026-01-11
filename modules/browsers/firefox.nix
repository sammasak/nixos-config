# Firefox browser with privacy-focused settings
# Uses home-manager for per-user configuration

{ pkgs, ... }:
{
  programs.firefox = {
    enable = true;

    # Privacy-focused profile
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
      };
    };
  };
}
