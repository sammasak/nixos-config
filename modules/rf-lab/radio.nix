# The kit's wrappers and the HIL test both drive the one USB adapter, so they
# share how to find it and the lock that keeps their mode flips from colliding.
{
  lock = "/run/rf-lab.lock";
  # udev USB name (wlu*) is stable; the phy index flips with enumeration order.
  findUsb = "iw dev | awk '/Interface/{print $2}' | grep -m1 '^wlu' || true";
}
