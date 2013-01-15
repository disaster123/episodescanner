package Backend::Wunschliste;

use warnings;
use strict;
use LWP::UserAgent;
use URI;
use URI::URL;
use URI::Escape;
use XML::Simple;
use XML::Parser;
use Data::Dumper;
use Text::LevenshteinXS qw(distance);
use Log;
use Backend::EpisodeSubst;
use Encode;

BEGIN {
  $ENV{XML_SIMPLE_PREFERRED_PARSER} = 'XML::Parser'; 
}

sub new {
  my $self = bless {};

  $self->{'debug_counter'} = 0;
  
  return $self;
}

sub search {
  my $self = shift;
  my $seriesname = shift;
  my $episodename = shift;
  my $subst = shift;
  my %subst = %{$subst};
  my $episodenumber = "";
  my $seasonnumber = "";
  my $id;

  Log::log("\tsearch on http://www.wunschliste.de/...");

  # http://www.wunschliste.de/index.pl?query_art=titel&query=90210
  my ($page, $redirect_url) = _myget("http://www.wunschliste.de/index.pl", ( query_art => 'titel', query => $seriesname ));

  # remove all underline marks - as it marks our searchwords
  $page =~ s#<strong><u>(.*?)</u></strong>#$1#igs;
  
  # test if it is directly a result page
  if ($redirect_url =~ /\/(\d+)$/) {
     $id = $1;
  } elsif ($page =~ m#<link[^\>]*href="/xml/rss\.pl\?s=(\d+)"#i) {
     # <link rel="ALTERNATE" type="application/rss+xml" title="Mister Maker TV-Vorschau (RSS)" href="/xml/rss.pl?s=13103">
     $id = $1;
  } elsif ($page =~ m#<a\s+href="/(\d+)">\Q$seriesname\E</a>#i) {
     # Try to get all Series
	 # <a href="/3125"><strong><u>Tatort</u></strong></a>
     # <a href="/12391"><strong><u>90210</u></strong></a>
     $id = $1;
  }

  if (defined $id && $id =~ /^\d+$/) {
    # get ID page to check if it has Episodes
    $page = _myget("http://www.wunschliste.de/$id", ());
	# /serie/csi/episoden
	if ($page !~ m#"/serie/.*?/episoden"#i) {
      Log::log("\tGot series ID $id but there are not episodes listed", 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	  $id = undef;
	} else {
      Log::log("\tGot series ID $id", 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	}
  }

  if (!defined $id) {
	   if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
		   my $FH;
		   open($FH, ">wunschliste_".++$self->{'debug_counter'}.".htm");
		   print $FH $page;
		   close($FH);
           Log::log("\tWriting debug page to: ".$self->{'debug_counter'}, 1);
	   }

       Log::log("\tWas not able to find series/seriesindexpage \"$seriesname\" at Wunschliste");
	   return (-1, 0);
  }

  $page = _myget("http://www.wunschliste.de/xml/rss.pl", (s => $id, mp => '1'));
  my $xs = XMLin($page, (KeepRoot => 1));
  
  if (!ref($xs) || !ref($xs->{epgliste}) || !ref($xs->{epgliste}->{episode})) {
     Log::log("\tRSS Feed does not contain valid EPG Info - more details logged");
     Log::log(Dumper($xs), 1);
     return (0,0);
  }
  
  # @{[$string =~ /$match/g]}; 
  my $nr = @{[$page =~ /<episode>/mg]};
  $page =~ m/<datum_start>(.*?)<\/datum_start>/is;
  my $startd = $1;
  $page =~ m/.*<datum_start>(.*?)<\/datum_start>/is;
  my $endd = $1;
  Log::log("\tgot $nr episodes of $seriesname shown from $startd to $endd");

  my %staffeln;
  eval {
     %staffeln = $self->get_staffel_hash($xs);
  };
  # ignore any error here - ONLY print it in DEBUG Mode
  if ($@ && defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
	 Log::log("ERROR: $@\n", 1);
  }
  
  my %fuzzy = ();
  $fuzzy{distance} = 99;
  $fuzzy{maxdistance} = 2;
  my $episodename_search = $self->staffeltitle_to_regtest($episodename, %subst);

  # do it this way - sometimes we have only some not known series
  my $found = 0;  
  foreach my $fs_title (sort keys %staffeln) {
    if (defined $staffeln{$fs_title}{S}) {
	  $found++;
    }
  }
  if (!$found) {
    Log::log("\tSkipping - no episode or series information at Wunschliste - this is probably a TV Show not a series", 0);
    return (-1, 0);
  }
  
  foreach my $fs_title (sort keys %staffeln) {
        my $regtest = $self->staffeltitle_to_regtest($fs_title, %subst);
        if ($episodename_search eq $regtest) {
	         Log::log("direct found $episodename_search => $regtest => S$staffeln{$fs_title}{S} E$staffeln{$fs_title}{E}", 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
			 
	         # found number so return
             return ($staffeln{$fs_title}{S}, $staffeln{$fs_title}{E});
        } else {
             my $distance = distance($episodename_search, $regtest);
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
		
		# if we have a episodenummer but no staffel set staffel to 1
		# for example tatort
		if (!defined $h->{staffel} && defined $h->{episodennummer} && $h->{episodennummer} > 0) {
  		  $h->{staffel} = 1;
		}
        $r{$h->{episodentitel}}{E} = $h->{episodennummer};
        $r{$h->{episodentitel}}{S} = $h->{staffel};
   }   

return %r;
}

sub staffeltitle_to_regtest {
        my $self = shift;
        my $regtest = shift;
		my %subst = @_;
  
        $regtest = EpisodeSubst($regtest, %subst);

return lc($regtest);
}

sub _myget {
	my $url = shift;
	my %par = @_;

	my $ua = LWP::UserAgent->new();
	$ua->agent("Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)");
	my $uri = URI::URL->new($url);
	$uri->query_form(%par);
	
	Log::log("\tuse $url?" . join("&", map { "$_=$par{$_}" } keys %par), 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	my $resp = $ua->get($uri);
	my $re_url = "";
	eval {
       $re_url = $resp->{_request}->{_uri}->as_string;
	};

	# wunschliste.de is still iso also the rss feed
	my $r = encode('UTF-8', decode('ISO-8859-1', $resp->content() ) );

return wantarray ? ($r, $re_url) : $r;
}

1;