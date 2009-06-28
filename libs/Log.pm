package Log;

our $VERSION = '0.01';
my $LOGFH;


sub start {
    open($LOGFH, ">log.txt");
    close($LOGFH);
}


sub log {
    my $l = shift;
    my $print = shift;
    $print = 1 if (!defined $print);
    
    print "$l\n" if ($print);
    open($LOGFH, ">>log.txt");
    print $LOGFH "[".scalar(localtime(time()))."] $l\n";
    close($LOGFH);
}

1;