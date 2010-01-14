package Log;

our $VERSION = '0.03';
my $LOGFH;


sub start {
   my $rot = shift || 0;
   
   # Rotate Log
   if ($rot || (-s "log.txt" > (1024*1024*5))) {
      rename "log.old.txt", "log.old.old.txt" if (!$rot);
      rename "log.txt", "log.old.txt" if (!$rot);
      open($LOGFH, ">log.txt");
      close($LOGFH);
      Log::log("\nLog rotated\n----------------------------------------------------------------------------------------");
   } else {
      Log::log("\n----------------------------------------------------------------------------------------");   
   }
}


sub log {
    my $l = shift;
    my $noprint = shift;
    my $pre = "";
    
    print "$l\n" if (!defined $noprint || $noprint == 0);

    if ($l =~ m#^((\n|\r)+)(.*)$#) {
      $pre = $1;
      $l = $3;
    }
    open($LOGFH, ">>log.txt");
    print $LOGFH $pre."[".scalar(localtime(time()))."] $l\n";
    close($LOGFH);
}

1;