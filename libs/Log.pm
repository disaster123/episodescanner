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
    $noprint = 0 if (!defined $noprint);
    
    print "$l\n" if ($noprint == 0);
    open($LOGFH, ">>log.txt");
    print $LOGFH "[".scalar(localtime(time()))."] $l\n";
    close($LOGFH);
}

1;