package Cmd;

use strict;
use warnings;
use Log;

use threads;
use threads::shared;
use Data::Dumper;

# remember to share each var before you do this ;-)
sub fork_and_wait(&) {
  my $timeout = 30;

  my $t = threads->create('Cmd::start_thread',
						  shift);
  
  my $start = time();
  my $c = 0;
  while ($t->is_running()) {
	 &Log::log("Thread is running ". ++$c, 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	 if ($start+$timeout < time()) {
	   &Log::log("Kill subthread...");
	   $t->kill('KILL');
	   print "Last\n";
	   last;
	 }
	 sleep(1);
  }

  return 1;
}

sub start_thread {
  $SIG{'KILL'} = sub { print "Thread got KILL\n"; threads->exit(); };
sleep(35);
  &Log::log("Thread started") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
  shift->();
  &Log::log("Thread Ended") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);

  threads->exit();
}

1;