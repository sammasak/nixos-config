# Keyboard-first TUI suite. Desktop-gated: the headless worker never runs an
# interactive dev session, and these grow its closure for nothing.
{ ... }:
{
  # yazi previews ride kitty's graphics protocol.
  programs.yazi.enable = true;
  programs.yazi.shellWrapperName = "y";
  programs.lazygit.enable = true;
  programs.zoxide.enable = true;
}
