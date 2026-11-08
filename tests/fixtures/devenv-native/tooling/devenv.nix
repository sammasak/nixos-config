# This imported module is observable through Devenv eval and required by the
# configured check script. Removing the import makes the guest check fail.
{ ... }: {
  env.DEVENV_IMPORT_MARKER = "tooling-import-loaded";
}
