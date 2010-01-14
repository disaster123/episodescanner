package Backend::Wunschliste;

use warnings;
use strict;
use LWP::UserAgent;
use URI;
use URI::URL;
use URI::Escape;
use XML::Simple;
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

  Log::log("\tsearch on http://www.wunschliste.de/...");

  # http://www.wunschliste.de/index.pl?query_art=titel&query=90210
  my $page = _myget("http://www.wunschliste.de/index.pl", ( query_art => 'titel', query => $seriesname ));

  # test if it is directly a result page
  # <link rel="ALTERNATE" type="application/rss+xml" title="Mister Maker TV-Vorschau (RSS)" href="/xml/rss.pl?s=13103">
  # if ($page =~ m#<link[^\>]+?type="application/rss+xml"[^\>]+?\s+href="/xml/rss.pl\?s=(\d+)"#i) {
  if ($page =~ m#<link[^\>]*href="/xml/rss\.pl\?s=(\d+)"#i) {
     my $uri = $1;
     Log::log("\tGet xml/rss via ID $uri", 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
     $page = _myget("http://www.wunschliste.de/xml/rss.pl", (s => $uri, mp => '1'));
  } else {
        # Try to get all Series
        #<td class=r><p><a href="index.php?serie=10147"><b>Psych</b></a>
        my $t = $seriesname;
        # <a href="/12391"><strong><u>90210</u></strong></a>
        if ($page =~ m#<a\s+href="/(\d+)">(<strong><u>)*$t(</u></strong>)*#i) {
           my $uri = $1;
           Log::log("\tGet xml/rss via ID $uri", 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
           $page = _myget("http://www.wunschliste.de/xml/rss.pl", (s => $uri, mp => '1'));
	} else {
	   if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
		   my $FH;
		   open($FH, ">wunschliste_".++$self->{'debug_counter'}.".htm");
		   print $FH $page;
		   close($FH);
           Log::log("\tWriting debug page to: ".$self->{'debug_counter'}, 1);
	   }

       Log::log("\tWas not able to find series/seriesindexpage \"$t\" at Wunschliste");
	   return (0, 0);
	}
  }

  my $xs = XMLin($page, (KeepRoot => 1));

  my %staffeln = $self->get_staffel_hash($xs);

  my %fuzzy = ();
  $fuzzy{distance} = 99;
  $fuzzy{maxdistance} = 2;
  my $episodename_search = $self->staffeltitle_to_regtest($episodename);
  foreach my $fs_title (sort keys %staffeln) {
        my $regtest = $self->staffeltitle_to_regtest($fs_title);

		if (!defined $staffeln{$fs_title}{S}) {
            Log::log("\tSkipping $regtest - no episode or series information at wunschliste", 0);
			next;
        }
		
        $regtest = encode($encoding, $regtest);
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
  } elsif (defined $fuzzy{seasonnumber}) { # perhaps we have nothing found so then do not print anything seasonnumber
      Log::log("\tnearest fuzzy found: Name: $fuzzy{name} Dist: $fuzzy{distance} S$fuzzy{seasonnumber}E$fuzzy{episodenumber}", 0);
  }
   
   if ($seasonnumber eq "0" || $seasonnumber eq "") {
           Log::log("\tfound series but not episode \"$episodename\" at Wunschliste");
   }
	
 return ($seasonnumber, $episodenumber);
}


sub get_staffel_hash {
   my $self = shift;
   my $xs = shift;
   my %r;
	   
   foreach my $h (@{$xs->{epgliste}->{episode}}) {
        utf8::decode($h->{episodentitel});
        $r{$h->{episodentitel}}{E} = $h->{episodennummer};
        $r{$h->{episodentitel}}{S} = $h->{staffel};
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