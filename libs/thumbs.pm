package thumbs;

use Win32::Process qw(STILL_ACTIVE IDLE_PRIORITY_CLASS NORMAL_PRIORITY_CLASS CREATE_NEW_CONSOLE);
use Win32;
use Data::Dumper;
use strict;
use warnings;
our $VERSION = '0.01';

sub ErrorReport{
        print STDERR Win32::FormatMessage( Win32::GetLastError() );
}

sub processfile {
   my $filename = shift;
   my @progs = @_;

   my $basefile = $filename;
   $basefile =~ s#\.[a-z]+$##;
   $basefile =~ s#^.*\\##;
   my $basedir = $filename;
   $basedir =~ s#\\[^\\]+$##;
   
   if (-e "${basefile}.jpg" && !-z "${basefile}.jpg") {
      Log::log("Thumb ${basefile}.jpg already exists!");
	  return undef;
   }

   foreach my $prog_h (@progs) {
       my $prog = $prog_h->{'prog'};
       my $thumb_filename = $prog_h->{'thumb_filename'};
       my $timeout = $prog_h->{'timeout'};
       #  prog => '"C:\Program Files (x86)\VideoLAN\VLC\vlc.exe" --video-filter scene -V dummy --intf dummy --dummy-quiet --scene-width=420 --scene-format=jpg --scene-replace --scene-ratio 24 --start-time=600 --stop-time=601 --scene-replace --scene-prefix=thumb --scene-path="C:\\" "${filename}" "vlc://quit"',
       #  thumb_filename => 'C:\\thumb.jpg',
       #  timeout => 3,

	   my $cmd;
	   my $params;
	   $prog =~ s#\$\{filename\}#${filename}#ig;
	   $prog =~ s#\$\{basefile\}#${basefile}#ig;
	   $prog =~ s#\$\{basedir\}#${basedir}#ig;
	   $thumb_filename =~ s#\$\{filename\}#${filename}#ig;
	   $thumb_filename =~ s#\$\{basefile\}#${basefile}#ig;
	   $thumb_filename =~ s#\$\{basedir\}#${basedir}#ig;
	   $prog =~ s#\\#\\\\#ig;
	   unlink($thumb_filename) if (-e "$thumb_filename");
       if ($prog =~ /^"([^"]+)"\s+(.*)$/) {
	      $cmd = $1;
		  $params = $2;
	   } else {
    	  $prog =~ m#^(.*?)\s+(.*)$#;
    	  $cmd = $1;
		  $params = $2;
	   }

	   if (!-e $cmd) {
          Log::log("Command \"$cmd\" not found!");
		  next;
	   }
	   my $mtn_obj;
       Log::log("Run: ".Dumper($prog_h)) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	   Win32::Process::Create($mtn_obj,
                              $cmd,
                              $params,
                              0,
                              IDLE_PRIORITY_CLASS,
                              '.') || die ErrorReport();

       my $c = 0;
	   my $exitcode;
	   $mtn_obj->GetExitCode($exitcode);
	   while (++$c < $timeout && $exitcode == STILL_ACTIVE) {
		  sleep(1);
	      $mtn_obj->GetExitCode($exitcode);
	   }
	   if ($c == $timeout) {
	      Log::log("$cmd timed out try to kill PID: ".$mtn_obj->GetProcessID(), 1);
		  $mtn_obj->Kill($exitcode);
		  $exitcode = -1;
	   }
       Log::log("Exited with: $exitcode") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	   if (-e "$thumb_filename" && !-z "$thumb_filename") {
          Log::log("Thumb file found: $thumb_filename") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	      rename "$thumb_filename", "${basedir}\\${basefile}.jpg";
		  return "${basedir}\\${basefile}.jpg";
	   } else {
          Log::log("No Thumb file found: $thumb_filename") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	      unlink("$thumb_filename");
	   }
   }
  
  return undef;
}

1;