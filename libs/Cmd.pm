package Cmd;

use strict;
use warnings;
use Log;

use Data::Dumper;

sub fork_and_wait(&) {
  my $timeout = 300;
  
  eval {
    local $SIG{'ALRM'} = sub { 
	                           die "ALRM\n\n"; 
                           	 };
	alarm($timeout);
	shift->();
	alarm(0);
  };
  if ($@ && $@ =~ /^ALRM\n\n/) {
    &Log::log("Query timed out...");
	$@ = undef;
  } elsif ($@ && $@ =~ /DBM::Deep/) {
    &Log::log("DBM Error - Please delete all files in tmp folder");
	$@ = undef;
  } elsif ($@) {
    &Log::log($@);
  }
  
  return 1;
}

1;