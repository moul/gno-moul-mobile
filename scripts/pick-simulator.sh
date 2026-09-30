#!/usr/bin/env bash
# Prints an iPhone simulator this machine actually has.
#
# Hardcoding a name ties the Makefile to one Xcode: "iPhone 17" does not exist
# on a runner shipping Xcode 16, and the failure reads as a broken destination
# rather than a missing device. Override with SIMULATOR=... when you want a
# specific one.
set -euo pipefail

xcrun simctl list devices available \
  | sed -n 's/^ *\(iPhone [^(]*\) (.*/\1/p' \
  | sed 's/ *$//' \
  | head -1
