{
  imports = [ ./valid-herman.nix ];
  grants.notes = (import ./valid-service.nix).grants.notes;
  apps.notes = removeAttrs (import ./notes.nix) [ "owner" ];
}
