#!/usr/bin/env bash
# Wall-clock limit: tlimit.sh <seconds> <cmd...>. SIGALRM terminates the command after
# <seconds>; exit status 142 then. (macOS has no coreutils `timeout`; perl is in the base OS.)
exec perl -e 'my $s = shift @ARGV; alarm $s; exec @ARGV or die "exec failed: $!"' "$@"
