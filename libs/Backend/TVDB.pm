package Backend::TVDB;

use warnings;
use strict;
use DBM::Deep;
use TVDB::API;
use LWP::Simple;
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
use DBM::Deep;
use DBM::Deep::Hash;
use DBM::Deep::Array;

my $w32encoding = Win32::Codepage::get_encoding();  # e.g. "cp1252"
my $encoding = $w32encoding ? Encode::resolve_alias($w32encoding) : '';
my $ss = chr(223);
my $progbasename = "";

sub new {
    my $type = shift;
    $progbasename = shift;
    my $apikey = shift;
    my $self = {};

    $self->{tvdb} = TVDB::API::new($apikey);
    $self->{tvdb}->setApiKey($apikey);
    $self->{tvdb}->setLang('de');
    $self->{tvdb}->setUserAgent("TVDB::API/$TVDB::API::VERSION");
    $self->{tvdb}->setBannerPath("tmp");
    $self->{tvdb}->setCacheDB('tmp/'.$progbasename.'_tvdb.cache');
    
    $self->{cache} = ();

    # delete Cache if it is older than 2 days
    if (-e 'tmp/'.$progbasename.'.cache') {
	# in Tagen
	my $creation = int((time() - (stat('tmp/'.$progbasename.'.cache'))[10])/60/60/24);
	if ($creation > 2) {   # 2 Tage
                Log::log("deleted TVDB Cache - was $creation days old");
		# delete TVDB Cache every 2 days
		unlink('tmp/'.$progbasename.'.cache');
	}
    }

  return bless $self, $type;
}


sub search() {
  my $self = shift;
  my $seriesname = shift;
  my $episodename = shift;
  my $episodenumber = "";
  my $seasonnumber = "";
  my $hr;
  my $seriesid = 0;

  Log::log("\tsearch on http://www.thetvdb.com/...");

  utf8::encode($seriesname);
  eval {
    $hr = $self->{tvdb}->getPossibleSeriesId($seriesname, [0]);
  };
  utf8::decode($seriesname);

  # sortiere aufsteigend - damit wir uns die neueste verfügbare ID holen (ACHTUNG Rückwärts siehe unten)
  my @possseries = sort {$b cmp $a} keys %{$hr};

  if (scalar(@possseries) == 0) {
      Log::log("\tWas not able to find series \"$seriesname\" at TheTVDB");
      return (0, 0);
  }

  for my $posserie (@possseries) {
	   $hr->{$posserie}->{'SeriesName'} =~ s#\s+$##g;
	   $hr->{$posserie}->{'SeriesName'} =~ s#^\s+##g;
	   # for series like samantha who?
	   $hr->{$posserie}->{'SeriesName'} =~ s#\?$##g;
	   next if ($hr->{$posserie}->{'language'} ne "de");
	   next if ($hr->{$posserie}->{'SeriesName'} ne $seriesname);
	   $seriesid = $hr->{$posserie}->{'seriesid'};
	   last;
  }
	
  if ($seriesid == 0) {
      Log::log("\tCannot find $seriesname at TheTVDB");
      return (0, 0);
  }

  if (!defined $self->{cache}{getSeriesAll}{$seriesid}) {
     ##############print "getSeriesAll Not in Cache\n";
     eval {
	$hr = $self->{tvdb}->getSeriesAll($seriesid, [0]);
     };
     $self->{cache}{getSeriesAll}{$seriesid} = $hr;
   } else {
     ##############print "getSeriesAll In Cache\n";
     $hr = $self->{cache}{getSeriesAll}{$seriesid};
   }
					
  my %fuzzy = ();
  $fuzzy{distance} = 99;
  $fuzzy{maxdistance} = 2;

  if ($seriesname eq "Tatort") {
      # Kessin: / BLABLUB: 
      $episodename =~ s#^[a-z]+\:\s+##i;
  }
  my $episodename_search = $self->staffeltitle_to_regtest($episodename);
  $episodename_search = encode($encoding, $episodename_search);

  # Rückwärts so kommen erst neuere
  my @seasons = @{$hr->{Seasons}};
  foreach my $seasonnr (1..scalar(@seasons)) {
		  next if (ref($seasons[$seasonnr-1]) ne "ARRAY" && ref($seasons[$seasonnr-1]) ne "DBM::Deep::Array");
		  my @episodes = @{$seasons[$seasonnr-1]};

		  foreach my $episodenr (1..scalar(@episodes)) {
		     next if (!defined($episodes[$episodenr-1]));
		     next if ($episodes[$episodenr-1] !~ /^\d+$/);
		     my $episodedata;
		     my %episodedata;

		     if (!defined $self->{cache}{getEpisodeId}{$episodes[$episodenr-1]}) {
			     eval {
	     		        $episodedata = $self->{tvdb}->getEpisodeId($episodes[$episodenr-1]);
	     		     };
			     $self->{cache}{getEpisodeId}{$episodes[$episodenr-1]} = $episodedata;
	             } else {
    		             $episodedata = $self->{cache}{getEpisodeId}{$episodes[$episodenr-1]};
	             }
	             %episodedata = %{$episodedata};
	             next if (!defined $episodedata{'EpisodeName'});
     		     $episodedata{'EpisodeName'} =~ s#\s+$##;
     		     $episodedata{'EpisodeName'} =~ s#^\s+##;

     		     if ($seriesname eq "Tatort") {
     		     	# -Stoever - 36 -
     		     	$episodedata{'EpisodeName'} =~ s#^\w+\s+-\s+\d+\s+\-\s+##i;
     		     }

		     my $regtest = encode($encoding, $self->staffeltitle_to_regtest($episodedata{'EpisodeName'}));

     		     if (lc($episodename_search) eq lc($regtest)) {   # NEVER /o as option
			     return ($episodedata{'SeasonNumber'}, $episodedata{'EpisodeNumber'});
		     } else {
		            my $distance = distance(lc($episodename_search), lc($regtest));
		            Log::log("\t-$episodename_search- =~ -$episodedata{'EpisodeName'}- =~ -$regtest- => ".$distance, 0);
		     
		            if ($distance < $fuzzy{distance}) {
		              $fuzzy{distance} = $distance;
             	              $fuzzy{episodenumber} = $episodedata{'EpisodeNumber'};
			      $fuzzy{seasonnumber} = $episodedata{'SeasonNumber'};
		              $fuzzy{name} = $episodedata{'EpisodeName'};
		              $fuzzy{regtest} = $regtest;
		            }
		     }
		  } #foreach my $episodenr (1..scalar(@episodes)) {
  } # foreach my $seasonnr (1..scalar(@seasons)) {
  
  if ($fuzzy{distance} <= $fuzzy{maxdistance} && $fuzzy{episodenumber} ne "" && $fuzzy{seasonnumber} ne "" && $episodenumber eq "" and $seasonnumber eq "") {
       $episodenumber = $fuzzy{episodenumber};
       $seasonnumber = $fuzzy{seasonnumber};
       Log::log("\tfound result via fuzzy search distance: $fuzzy{distance} Name: $fuzzy{name} Regtest: $fuzzy{regtest}");
   } else {
       Log::log("\tnearest fuzzy found: Name: $fuzzy{name} Dist: $fuzzy{distance} S$fuzzy{seasonnumber}E$fuzzy{episodenumber}", 0);
   }

 return ($seasonnumber, $episodenumber);
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