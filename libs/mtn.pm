package mtn;

use Win32::Process qw(STILL_ACTIVE IDLE_PRIORITY_CLASS NORMAL_PRIORITY_CLASS CREATE_NEW_CONSOLE);
use Win32;
use Data::Dumper;
use strict;
use warnings;
our $VERSION = '0.01';

sub ErrorReport{
        print Win32::FormatMessage( Win32::GetLastError() );
}

sub processfile {
   my $filename = shift;
   my @options = @_;

   my $basefile = $filename;
   $basefile =~ s#\.[a-z]+$##;
   $basefile =~ s#^.*\/##;
   my $basedir = $filename;
   $basedir =~ s#\/[^\/]+$##;
   
   if (-e "${basefile}.jpg" && !-z "${basefile}.jpg") {
      Log::log("Thumb ${basefile}.jpg already exists!");
	  return undef;
   }

   foreach my $opt (@options) {
	   my $mtn_obj;
	   my $cmd;
       my $test_opt = $opt;
	   $test_opt =~ s#\$\{filename\}#${filename}#ig;
	   $test_opt =~ s#\$\{basefile\}#${basefile}#ig;
	   $test_opt =~ s#\$\{basedir\}#${basedir}#ig;
       if ($test_opt =~ /^"([^"]+)"/) {
	      $cmd = $1;
	   } else {
    	  $test_opt =~ m#^(.*?)\s+#;
    	  $cmd = $1;
	   }

	   if (!-e $cmd) {
          Log::log("Command \"$cmd\" not found!");
		  next:
	   }
	   
       Log::log("Run: $test_opt") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	   Win32::Process::Create($mtn_obj,
                                "$cmd",
                                "$test_opt".((defined $ENV{DEBUG} && $ENV{DEBUG} == 1) ? "" : " >>log.txt 2>&1"),
                                0,
                                (IDLE_PRIORITY_CLASS),
                                '.') || die ErrorReport();

       my $c = 0;
	   my $exitcode;
	   $mtn_obj->GetExitCode($exitcode);
	   while (++$c < 10 && $exitcode == STILL_ACTIVE) {
		  sleep(1);
	      $mtn_obj->GetExitCode($exitcode);
	   }
	   if ($c == 10) {
	      Log::log("$cmd timed out try to kill PID: ".$mtn_obj->GetProcessID()."\n");
		  $mtn_obj->Kill($exitcode);
		  $exitcode = -1;
          # just to be shure _s is from mtn
          unlink("${basedir}\\${basefile}_s.jpg") if (-e "${basedir}\\${basefile}_s.jpg");
          unlink("${basedir}\\${basefile}.jpg") if (-e "${basedir}\\${basefile}.jpg");
	   }
       Log::log("Exited with: $exitcode") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	   if ($exitcode == 0 && -e "${basedir}\\${basefile}_s.jpg" && !-z "${basedir}\\${basefile}_s.jpg") {
	      rename "${basedir}\\${basefile}_s.jpg", "${basedir}\\${basefile}.jpg";
		  return "${basedir}\\${basefile}.jpg";
	   }
   }
   # just to be shure
   # just to be shure _s is from mtn
   unlink("${basedir}\\${basefile}_s.jpg") if (-e "${basedir}\\${basefile}_s.jpg");
  
  return undef;
}

1;