#!/usr/bin/perl
# Usage: formal/glimit.pl <seconds> <cmd> [args...]
# Runs <cmd> in its own process group and kills the whole group (SIGTERM, then SIGKILL after
# 5 s) when the time limit expires or when this wrapper is terminated, so multi-process
# solvers (rIC3 portfolio) leave no engines behind. Exit status: the command's, or 124 on
# timeout.
use strict; use warnings; use POSIX ();
my $t = shift @ARGV; die "usage: glimit.pl <seconds> <cmd> ...\n" unless defined $t && @ARGV;
my $pid = fork(); die "fork: $!" unless defined $pid;
if ($pid == 0) { POSIX::setpgid(0, 0); exec @ARGV or die "exec: $!"; }
POSIX::setpgid($pid, $pid);
my $killgroup = sub { kill 'TERM', -$pid; sleep 5; kill 'KILL', -$pid; };
for my $sig (qw(TERM INT HUP)) { $SIG{$sig} = sub { $killgroup->(); exit 143; }; }
local $SIG{ALRM} = sub { $killgroup->(); exit 124; };
alarm $t;
waitpid($pid, 0); my $st = $?; alarm 0;
kill 'KILL', -$pid;   # stray children of a finished command
exit($st >> 8);
