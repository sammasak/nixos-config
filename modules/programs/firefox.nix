# Firefox browser 
{...}:
{
    programs.firefox = {
    enable = true;
    policies = {
        # General Debloating & Privacy
        DisableTelemetry = true; # Stops data collection
        DisableFirefoxStudies = true; # Disables background studies
        DisablePocket = true; # Removes Pocket integration

        # Firefox Suggest (ads/suggestions)
        FirefoxSuggest = {
            WebSuggestions = false;
            SponsoredSuggestions = false;
        };
    };
    # Set Firefox specific preferences
    # For more options, see about:config in Firefox
    preferences = {
        "privacy.resistFingerprinting" = true; # Makes you look more generic (e.g., basic US locale)
        "privacy.trackingprotection.enabled" = true; # Built-in tracker blocking
        "privacy.trackingprotection.socialtracking.enabled" = true; # Block social trackers
        "browser.search.suggest.enabled" = false; # Disable search suggestions
        "toolkit.telemetry.enabled" = false; # Another telemetry toggle
        "network.predictor.enabled" = false; # Disable network prediction
    };
    };
}
