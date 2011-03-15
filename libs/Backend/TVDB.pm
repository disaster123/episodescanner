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
use DBM::Deep::Engine::File;
use DBM::Deep::Iterator::File;
use Backend::EpisodeSubst;

my $w32encoding = Win32::Codepage::get_encoding();  # e.g. "cp1252"
my $encoding = $w32encoding ? Encode::resolve_alias($w32encoding) : '';
my $ss = chr(223);
my $progbasename = "";

sub new {
    my $type = shift;
    $progbasename = shift;
    my $apikey = shift;
	my $thetvdb_language = shift || 'en';
    my $self = {};

    # delete Cache if it is older than 2 days
    if (-e 'tmp/'.$progbasename.'.cache') {
        # in Tagen
        my $created = int((time() - (stat('tmp/'.$progbasename.'.cache'))[10])/60/60/24);
        if ($created > 2) {   # 2 Tage
          Log::log("deleted TVDB Cache - was $created days old");
          # delete TVDB Cache every 2 days
          unlink('tmp/'.$progbasename.'.cache');
        }
    }	
	
	if ($thetvdb_language =~ /\|/) {
      @{$self->{language}} = split(/\|/, $thetvdb_language);
    } else {
      push(@{$self->{language}}, $thetvdb_language);
	}

	foreach my $lang (@{$self->{language}}) {
      $self->{tvdb}->{$lang} = TVDB::API::new(
	                    {
	                       apikey    => $apikey,
                           lang      => $lang,
                           cache     => 'tmp/'.$progbasename.'_tvdb.cache',
                           banner    => 'tmp',
                           useragent => "TVDB::API/$TVDB::API::VERSION"
                        });
	}
    $self->{cache} = ();

  return bless $self, $type;
}


sub search() {
  my $self = shift;
  my $seriesname = shift;
  my $episodename = shift;
  my $subst = shift;
  my %subst = %{$subst};
  my $lang = shift;
  my $episodenumber = "";
  my $seasonnumber = "";
  my $hr;
  my $seriesid = 0;

  if (!defined $lang) {
    my $seriesnotfound = 0;
    foreach my $l (@{$self->{language}}) {
       my ($e, $s) = $self->search($seriesname, $episodename, \%subst, $l);
	   return ($e, $s) if (defined $e && defined $s && $e && $s && $e > 0 && $s > 0);
	   if ($e eq "-1") {
	     $seriesnotfound++;
	   }
	}
    return (-1, 0) if ($seriesnotfound == scalar(@{$self->{language}}));
	return (0, 0);
  }  
  
  Log::log("\tsearch on http://www.thetvdb.com/ Language: ".$lang."...");

  utf8::encode($seriesname);
  eval {
    $hr = $self->{tvdb}->{$lang}->getPossibleSeriesId($seriesname, [0]);
  };
  Log::log("\tError: $@", 0) if ($@);
  Log::log("\t".Dumper($hr), 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
  utf8::decode($seriesname);

  # sortiere aufsteigend - damit wir uns die neueste verfügbare ID holen (ACHTUNG Rückwärts siehe unten)
  my @possseries = sort {$b cmp $a} keys %{$hr};

  if (scalar(@possseries) == 0) {
      Log::log("\tSeries \"$seriesname\" not listed at TheTVDB");
      return (-1, 0);
  }

  my $test_seriesname = $seriesname;
  $test_seriesname =~ s#[^a-z0-9]##ig;
  foreach my $posserie (@possseries) {
	   $hr->{$posserie}->{'SeriesName'} =~ s#\s+$##g;
	   $hr->{$posserie}->{'SeriesName'} =~ s#^\s+##g;
	   # remove from series all special characters
	   my $t = $hr->{$posserie}->{'SeriesName'};
	   $t =~ s#[^a-z0-9]##ig;
	   next if ($hr->{$posserie}->{'language'} ne $lang);
	   next if (lc($t) ne lc($test_seriesname));
	   $seriesid = $hr->{$posserie}->{'seriesid'};
	   last;
  }
	
  if ($seriesid == 0) {
      Log::log("\tCannot find $seriesname at TheTVDB");
      return (-1, 0);
  }

  if (!defined $self->{cache}->{$lang}->{getSeriesAll}{$seriesid}) {
    ##############print "getSeriesAll Not in Cache\n";
    eval {
      $hr = $self->{tvdb}->{$lang}->getSeriesAll($seriesid, [0]);
    };
    Log::log("\tError: $@", 0) if ($@);
    $self->{cache}->{$lang}->{getSeriesAll}{$seriesid} = $hr;
  } else {
    ##############print "getSeriesAll In Cache\n";
    $hr = $self->{cache}->{$lang}->{getSeriesAll}{$seriesid};
  }
					
  my %fuzzy = ();
  $fuzzy{distance} = 99;
  $fuzzy{maxdistance} = 2;

  # Tatort Hack - can be implemented by local substitutions  
  if ($seriesname eq "Tatort") {
      # Kessin: / BLABLUB: 
      $episodename =~ s#^[a-z]+\:\s+##i;
  }
  my $episodename_search = $self->staffeltitle_to_regtest($episodename, %subst);
  $episodename_search = encode($encoding, $episodename_search) if (defined $encoding && $encoding ne '');;

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

		     if (!defined $self->{cache}->{$lang}->{getEpisodeId}{$episodes[$episodenr-1]}) {
                 eval {
                   $episodedata = $self->{tvdb}->{$lang}->getEpisodeId($episodes[$episodenr-1]);
                 };
                 Log::log("\tError: $@", 0) if ($@);
			     $self->{cache}->{$lang}->{getEpisodeId}{$episodes[$episodenr-1]} = $episodedata;
            } else {
                 $episodedata = $self->{cache}->{$lang}->{getEpisodeId}{$episodes[$episodenr-1]};
            }
             %episodedata = %{$episodedata};
             next if (!defined $episodedata{'EpisodeName'});
             $episodedata{'EpisodeName'} =~ s#\s+$##;
             $episodedata{'EpisodeName'} =~ s#^\s+##;

             if ($seriesname eq "Tatort") {
               # -Stoever - 36 -
               $episodedata{'EpisodeName'} =~ s#^\w+\s+-\s+\d+\s+\-\s+##i;
             }

             my $regtest = $self->staffeltitle_to_regtest($episodedata{'EpisodeName'}, %subst);
             $regtest = encode($encoding, $regtest) if (defined $encoding && $encoding ne '');
 
             if ($episodename_search eq $regtest) {
               Log::log("direct found $episodename_search => $regtest => S$episodedata{'SeasonNumber'} E$episodedata{'EpisodeNumber'}", 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
               return ($episodedata{'SeasonNumber'}, $episodedata{'EpisodeNumber'});
		     } else {
               my $distance = distance($episodename_search, $regtest);
               Log::log("\t-$episodename_search- =~ -$episodedata{'EpisodeName'}- =~ -$regtest- => ".$distance, 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);

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
   } elsif (defined $fuzzy{name}) {
       Log::log("\tnearest fuzzy found: Name: $fuzzy{name} Dist: $fuzzy{distance} S$fuzzy{seasonnumber}E$fuzzy{episodenumber}");
   }

 return ($seasonnumber, $episodenumber);
}

sub staffeltitle_to_regtest {
        my $self = shift;
        my $regtest = shift;
		my %subst = @_;
  
        $regtest = &EpiseodeSubst($regtest, %subst);
  
        $regtest =~ s#\s+$##;
        $regtest =~ s#^\s+##;
		# Bad IDEA - it removes valid names
        # $regtest =~ s#\s+\(\d+\)$##;
        $regtest =~ s#\.#\. #g;
        $regtest =~ s#\.# #g;
        $regtest =~ s#\-# #g;
        $regtest =~ s#:# #g;
        $regtest =~ s#&# #g;
        $regtest =~ s#(\.|\!|\?)##g;
        $regtest =~ s#$ss#ss#g;
        $regtest =~ s#\s+##g;

return lc($regtest);
}

1;