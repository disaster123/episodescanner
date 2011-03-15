package Cmd;

use strict;
use warnings;
use POSIX ":sys_wait_h";

sub fork_and_wait(&) {
  my $pid = fork();
  if (!defined $pid) {
    die "Cannot fork\n"
  }
  if ($pid == 0) {
    ## this is the child
	print "$$ started\n";
    shift->();
	print "$$ done\n";
    exit;
  }
  my $start = time();
  for (;;) {
    my $r = waitpid(-1, &WNOHANG);
	print "$$ $pid $r\n";
	if ($r == $pid) {
	   last;
	}
	if (time()-30 > $start) {
	  Log::log("Child $pid tooked too long killing");
      kill POSIX::SIGINT, $pid;
	  last;
    }
	sleep(1);
  }
  print "Returned from fork_and_wait\n";
  
  return 1;
}

1;