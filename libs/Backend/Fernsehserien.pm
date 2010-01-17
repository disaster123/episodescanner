package Backend::Fernsehserien;

use warnings;
use strict;
use LWP::UserAgent;
use URI;
use URI::URL;
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

  $self->{'debug_counter'} = 0;

  return $self;
}

sub search {
  my $self = shift;
  my $seriesname = shift;
  my $episodename = shift;
  my $episodenumber = "";
  my $seasonnumber = "";

  Log::log("\tsearch on http://www.fernsehserien.de/...");

  my $page = _myget("http://www.fernsehserien.de/index.php", ( suche => $seriesname ));

  # test if it is directly a result page
  if (($page =~ /bisher\s+\d+\s+Episoden/i || ($page =~ /\d+\s+Episoden/i && $page =~ /\d+\. Staffel/i)) && $page =~ /Episodenführer/i) {
  } else {
        # Try to get all Series
        #<td class=r><p><a href="index.php?serie=10147"><b>Psych</b></a>
        my $t = $seriesname;
        if ($page =~ m#<a href="([^"]+)">(<b>)*$t(</b>)*#i) {
           my $uri = $1;
	   Log::log("Found page $uri", 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	   my %par = ();
           if ($uri =~ m#\?(.*)$#i) {
	       foreach my $l (split(/&/, $1)) {
	          my ($name, $value) = split(/=/, $l, 2);
	          $par{$name} = $value;
	       }
	       $uri =~ s#\?.*$##;
	   }
	   $page = _myget("http://www.fernsehserien.de/".$uri, %par);
	} else {
	   if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
		   my $FH;
		   open($FH, ">fernsehserien_".++$self->{'debug_counter'}.".htm");
		   print $FH $page;
		   close($FH);
           Log::log("\tWriting debug page to: ".$self->{'debug_counter'}, 1)
	   }
	   
       Log::log("\tWas not able to find series/seriesindexpage \"$t\" at Fernsehserien");
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
  foreach my $fs_title (sort keys %staffeln) {
        my $regtest = $self->staffeltitle_to_regtest($fs_title);

        $regtest = encode($encoding, $regtest) if (defined $encoding && $encoding ne '');		     		     
        if (lc($episodename_search) eq lc($regtest)) {
	     Log::log("direct found $episodename_search => $regtest => S$staffeln{$fs_title}{S} E$staffeln{$fs_title}{E}", 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	     # found number so return
             return ($staffeln{$fs_title}{S}, $staffeln{$fs_title}{E});
	} else {
             my $distance = distance(lc($episodename_search), lc($regtest));
             Log::log("\t-$episodename_search- =~ -$fs_title- =~ -$regtest- => ".$distance, 1);

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
   
   if ($seasonnumber eq "0" || $seasonnumber eq "") {
       Log::log("\tfound series but not episode \"$episodename\" at Fernsehserien");
	   if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
		   my $FH;
		   open($FH, ">wunschliste_".++$self->{'debug_counter'}.".htm");
		   print $FH $page;
		   close($FH);
           Log::log("\tWriting debug page to: ".$self->{'debug_counter'}, 0)
	   }
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
   	        $aktstaffel = 1 if ($aktstaffel == 0);
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

sub _myget {
	my $url = shift;
	my %par = @_;

	my $ua = LWP::UserAgent->new();
	my $uri = URI::URL->new($url);
	$uri->query_form(%par);
	
	my $resp = $ua->get($uri);

return $resp->content();
}

1;