package Backend::Fernsehserien;

use warnings;
use strict;
use LWP::Simple;
use LWP::UserAgent;
use URI;
use URI::Escape;
use Data::Dumper;
use Win32::Codepage;
use Encode qw(encode decode);
use Encode::Alias;
use Encode::Encoding;
use Encode::Encoder;
use Encode::Symbol;
use Encode::Byte;
use Text::LevenshteinXS qw(distance);
use Log;

my $w32encoding = Win32::Codepage::get_encoding();  # e.g. "cp1252"
my $encoding = $w32encoding ? Encode::resolve_alias($w32encoding) : '';
my $ss = chr(223);

sub new {
    my $self = bless {};

  return $self;
}

sub search {
  my $self = shift;
  my $seriesname = shift;
  my $episodename = shift;
  my $episodenumber = "";
  my $seasonnumber = "";

  Log::log("Search for \"".$seriesname."\" \"".$episodename."\" on http://www.fernsehserien.de/...");

  my $page = get("http://www.fernsehserien.de/index.php?suche=".uri_escape($seriesname));

print "-$page-\n";

exit;

  # test if it is directly a result page
  if (($page =~ /bisher\s+\d+\s+Episoden/i || ($page =~ /\d+\s+Episoden/i && $page =~ /\d+\. Staffel/i)) && $page =~ /Episodenf[.]hrer/i) {
  } else {
        # Try to get all Series
        #<td class=r><p><a href="index.php?serie=10147"><b>Psych</b></a>
        my $t = $seriesname;
        if ($page =~ m#<a href="([^"]+)">(<b>)*$t(</b>)*#i) {
	   Log::log("Found page $1");
	   $page = get("http://www.fernsehserien.de/".$1);
	} else {
	   Log::log("No Seriesindexpage found for $t");
	   return (0, 0);
	}
  }

  # remove HTML Code and so on from $page
  $page =~ s#<!--((\n|\r|.)*?)-->#\n#ig;
  $page =~ s#\r#\n#ig;
  $page =~ s#<br>#\n#ig;
  $page =~ s#<p>#\n#ig;
  $page =~ s#</p>#\n#ig;
  $page =~ s#<[^>]+>##ig;
  $page =~ s#\n\n#\n#ig;

  my %staffeln = $self->get_staffel_hash($page);

  my %fuzzy = ();
  $fuzzy{distance} = 99;
  $fuzzy{maxdistance} = 2;
  my $episodename_search = $self->staffeltitle_to_regtest($episodename);
  foreach my $fs_title (keys %staffeln) {
        my $regtest = $self->staffeltitle_to_regtest($fs_title);

        $regtest = encode($encoding, $regtest);		     		     
        if (lc($episodename_search) eq lc($regtest)) {
	     # found number so return
             return ($staffeln{$fs_title}{S}, $staffeln{$fs_title}{E});
	} else {
             my $distance = distance(lc($episodename_search), lc($regtest));
             Log::log("\t-$episodename_search- =~ -$fs_title- =~ -$regtest- => ".$distance, 0);

             if ($distance < $fuzzy{distance}) {
                $fuzzy{distance} = $distance;
                $fuzzy{episodenumber} = $staffeln{$fs_title}{E};
                $fuzzy{seasonnumber} = $staffeln{$fs_title}{S};
                $fuzzy{name} = $fs_title;
                $fuzzy{regtest} = $regtest;
             }
        }
		     
  } # END foreach staffeln from resultpage

  if ($fuzzy{distance} <= $fuzzy{maxdistance} && $fuzzy{episodenumber} ne "" && $fuzzy{seasonnumber} ne "" && $episodenumber eq "" and $seasonnumber eq "") {
       $episodenumber = $fuzzy{episodenumber};
       $seasonnumber = $fuzzy{seasonnumber};
       Log::log("\tfound result via fuzzy search distance: $fuzzy{distance} Name: $fuzzy{name} Regtest: $fuzzy{regtest}");
   } else {
       Log::log("\tnearest fuzzy found: Name: $fuzzy{name} Dist: $fuzzy{distance} S$fuzzy{seasonnumber}E$fuzzy{episodenumber}", 0);
   }
	
 return ($seasonnumber, $episodenumber);
}


sub get_staffel_hash {
   my $self = shift;
   my $p = shift;
   my %r;

   my $aktstaffel = 0;
   my $start = 0;
   my $aktseries_in_staffel = 0;
   foreach my $line (split(/\n/, $p)) {
   	if ($line =~ /bisher\s+\d+\s+(Episoden|Folgen)/i) {
		# print "Start found == 1\n";
   		$start = 1;
   		next;
   	}

   	if ($start == 0 && $line =~ /(\d+)\. Staffel/i) {
		# print "Start found == 1\n";
   		$start = 1;
   	}

   	next if ($start == 0);
   	next if ($line !~ /\d+\./);
   	
   	if ($line =~ /(\d+)\. Staffel/i) {
		$aktstaffel = $1;
		$aktseries_in_staffel = 0;
   		next;
   	}
   	next if (!defined $aktstaffel);
   	if ($line =~ /(\d+)\. (.*)$/i) {
   		$r{$2}{E} = ++$aktseries_in_staffel;
   		$r{$2}{S} = $aktstaffel;
   		next;
   	}
   	
   }
   

return %r;
}

sub staffeltitle_to_regtest {
        my $self = shift;
        my $regtest = shift;
  
        $regtest =~ s#\s+$##;
        $regtest =~ s#^\s+##;
        $regtest =~ s#\s+\(\d+\)$##;
        $regtest =~ s#\.#\. #g;
        $regtest =~ s#\.# #g;
        $regtest =~ s#\-# #g;
        $regtest =~ s#:# #g;
        $regtest =~ s#&# #g;
        $regtest =~ s#(\.|\!|\?)##g;
        $regtest =~ s#$ss#ss#g;
        $regtest =~ s#\s+##g;

return $regtest;
}

1;