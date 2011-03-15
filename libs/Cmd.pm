package Cmd;

use strict;
use warnings;
use Log;

use Data::Dumper;

sub fork_and_wait(&) {
  my $timeout = 30;
  
  eval {
    local $SIG{'ALRM'} = sub { die "ALRM\n\n"; };
	alarm($timeout);
	shift->();
	alarm(0);
  };
  if ($@ && $@ eq "ALRM\n\n") {
    &Log::log("Query timed out...");
	$@ = undef;
  } elsif ($@) {
    &Log::log($@);
  }
  
  return 1;
}

1;