package mtn;

our $VERSION = '0.01';

use Data::Dumper;
use POSIX;
use strict;
use warnings;

sub processfile {
   my $filename = shift;
   my @options = @_;

   my $basefile = $filename;
   $basefile =~ s#\.[a-z]+$##;
   
   if (-e "${basefile}.jpg" && !-z "${basefile}.jpg") {
      Log::log("Thumb ${basefile}.jpg already exists!");
	  return undef;
   }

   foreach my $opt (@options) {
       my $test_opt = $opt;
	   $test_opt =~ s#\$filename#${filename}#ig;
	   
	   my $childpid = fork();
	   if ($childpid == 0) {
          Log::log("Run mtn with: mtn.exe $test_opt") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
		  if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
	        system("mtn\\mtn.exe $test_opt");
	      } else {
	        system("mtn\\mtn.exe $test_opt >>log.txt 2>&1");
		  }
	      exit;
	   }
	   my $c = 0;
	   while (++$c < 20 && waitpid($childpid, WNOHANG) >= 0) {
		  sleep(1);
	   }
	   my $exitcode;
	   if ($c == 10) {
	      Log::log("mtn.exe timed out try to kill PID: $childpid\n");
		  # kill(9, $childpid); kill does not seem to work as $childpid is only virtual and exec spawns a new process
		  system("taskkill /F /IM mtn.exe");
          # just to be shure
          unlink("${basefile}_s.jpg") if (-e "${basefile}_s.jpg");
          unlink("${basefile}.jpg") if (-e "${basefile}.jpg");
		  $exitcode = -1;
	   }
       $exitcode ||= $?;
       Log::log("Exited with: $exitcode") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	   if ($exitcode == 0 && -e "${basefile}_s.jpg" && !-z "${basefile}_s.jpg") {
	      rename "${basefile}_s.jpg", "${basefile}.jpg";
		  return "${basefile}.jpg";
	   }
   }
   # just to be shure
   unlink("${basefile}_s.jpg") if (-e "${basefile}_s.jpg");
  
  return undef;
}

1;