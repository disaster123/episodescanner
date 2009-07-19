package Log;

our $VERSION = '0.01';
my $LOGFH;


sub start {
    open($LOGFH, ">log.txt");
    close($LOGFH);
}


sub log {
    my $l = shift;
    my $noprint = shift;
    my $pre = "";
    
    print "$l\n" if (!defined $noprint);

    if ($l =~ m#^((\n|\r)*)#) {
      $pre = $1;
      $l =~ s#^$pre##;
    }
    open($LOGFH, ">>log.txt");
    print $LOGFH "$pre[".scalar(localtime(time()))."] $l\n";
    close($LOGFH);
}

1;