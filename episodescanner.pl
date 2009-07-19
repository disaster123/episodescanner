#!/usr/bin/perl


BEGIN {
  $| = 1;
  
  $0 = $^X unless ($^X =~ m%(^|[/\\])(perl)|(perl.exe)$%i);
  my ($program_dir) = $0 =~ m%^(.*)[/\\]%;
  $program_dir ||= ".";
  chdir($program_dir);
}

END {
  $dbh->disconnect() if ($dbh);
  $dbh2->disconnect() if ($dbh2);
}

use lib 'libs';
use lib '.';
use warnings;
use strict;
use Log;
use Backend::Wunschliste;
use Backend::Fernsehserien;
use Backend::TVDB;
use Data::Dumper;
use Win32::Codepage;
use Encode qw(encode decode resolve_alias);
use Encode::Byte;
use DBI;
use DBD::ODBC;
use DBD::mysql;
use Storable qw(nstore retrieve);
use Text::LevenshteinXS qw(distance);
use Time::localtime;
use URI::Escape;
use LWP::Simple;
use LWP::UserAgent;
use URI;
use XML::Simple;

# cp1252
my $w32encoding = Win32::Codepage::get_encoding();  # e.g. "cp1252"
my $encoding = $w32encoding ? resolve_alias($w32encoding) : '';

our $progbasename = &basename($0, '.exe');
our $DEBUG = (defined $ARGV[0] && $ARGV[0] eq "-debug") ? 1 : 0;
$ENV{DEBUG} = $DEBUG;
our $tvdb_apikey;
our $cleanup_recordingdir;
our $dbuser;
our $dbpw;
our $dbname;
our $dbhost;
our $sleep;
our %recordingfilenames;
our %tvserien;
our %cache;
our %seriescache;
our $FH;
our $b_wl;
our $b_fs;
our $b_tvdb;
our $use_tv_tb;
our $use_fernsehserien;
our $use_wunschliste;
our $cleanup_recordingdb;
our $cleanup_recordingfiles;
our $usemysql;
our $dbh;
our $dbh2;

die "cannot find config.txt\n\n" if (!-e "config.txt");
eval('push(@INC, "."); do "config.txt";');
die $@."\n\n" if ($@);

die "sleep value below 30 not allowed - we do not want to stress the websites too much!\n\n" if ($sleep < 30);

Log::start();

if ($use_tv_tb && $tvdb_apikey eq "") {
  $tvdb_apikey = "24D235D27EFD8883";
  Log::log("use global TVDB API Key");
}


if ($usemysql) {
  Log::log("using MySQL", 1);
  $dbh = DBI->connect( "dbi:mysql:database=$dbname:hostname=$dbhost",
                                                   $dbuser, $dbpw) or die "Can't connect MYSQL: $DBI::errstr\n\n";
  $dbh2 = DBI->connect( "dbi:mysql:database=$dbname:hostname=$dbhost",
                                                   $dbuser, $dbpw) or die "Can't connect MYSQL: $DBI::errstr\n\n";
  $dbh->{InactiveDestroy} = 1;$dbh->{mysql_auto_reconnect} = 1;
  $dbh2->{InactiveDestroy} = 1;$dbh2->{mysql_auto_reconnect} = 1;
} else {
  Log::log("using MSSQL", 1);
  my $dsn = "dbi:ODBC:driver={SQL Server};Server=$dbhost;uid=$dbuser;pwd=$dbpw;Database=$dbname";
  my $db_options = {PrintError => 1,RaiseError => 1,AutoCommit => 1};
  $dbh = DBI->connect($dsn, $dbuser, $dbpw, $db_options) or die "Can't connect MSSQL: $DBI::errstr\n\n";
  $dbh2 = DBI->connect($dsn, $dbuser, $dbpw, $db_options) or die "Can't connect MSSQL: $DBI::errstr\n\n";
  $dbh->{LongReadLen} = 20480;$dbh->{LongTruncOk} = 1;$dbh2->{LongReadLen} = 20480;$dbh2->{LongTruncOk} = 1;
}

Log::log("Recordingdir: $cleanup_recordingdir");

# load series cache
&load_and_clean_cache();

# Build search objects
$b_wl = new Backend::Wunschliste;
$b_fs = new Backend::Fernsehserien;
$b_tvdb = new Backend::TVDB($progbasename, $tvdb_apikey);

# get all recordings
%tvserien = &get_recordings();

# Go through all TV Series
foreach my $tv_serie (sort keys %tvserien)  {
 	# sleep so that there are not too much cpu seconds and speed keeps slow
	sleep(3);
	Log::log("\nSerie: $tv_serie");

	RESCAN:

        # GO through show in EPG DB for tv_serie
        $tv_serie = encode($encoding, $tv_serie);
        my $abf_g;
#        if (!$DEBUG) {
          $abf_g = $dbh->prepare("SELECT * FROM program WHERE episodeName!= '' AND seriesNum='' AND title LIKE ?;");
#        } else {
#          $abf_g = $dbh->prepare("SELECT * FROM program WHERE episodeName!= '' AND title LIKE ?;");
#        }
        $abf_g->execute($tv_serie) or die $DBI::errstr;
        while (my $akt_tv_serie_h = $abf_g->fetchrow_hashref()) {
    	     # print Dumper($akt_tv_serie_h)."\n\n";
    	     
             my $seriesname = $tv_serie;
             $seriesname =~ s#\s+$##;
             $seriesname =~ s#^\s+##;
             my $episodename = $akt_tv_serie_h->{'episodeName'};
             $episodename =~ s#\s+$##;
             $episodename =~ s#^\s+##;
	     Log::log("\n\tEpisode: $episodename");

	     # check Cache
	     # defined and not UNKNOWN
	     if (defined $seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum} && 
	     					$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum} ne "UNKNOWN") {
		Log::log("\tSeries in Cache ".$akt_tv_serie_h->{'episodeName'}." S".$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum}."E".$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{episodeNum});

		my $abf = $dbh2->prepare("UPDATE program SET seriesNum=?,episodeNum=? WHERE idProgram=?;");
		my $a = $abf->execute($seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum}, 
					$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{episodeNum}, $akt_tv_serie_h->{'idProgram'}) or die $DBI::errstr;
		$abf->finish();

		next;
              # defined and UNKNOWN
      	      } elsif (defined $seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum} && 
				$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum} eq "UNKNOWN") {
		Log::log("\tSeries in Cache as unknown ".$akt_tv_serie_h->{'episodeName'});
		next;		
	      }

	      # start a new search on fernsehserien.de
	      my ($episodenumber, $seasonnumber) = ("", "");
	      
	      if ($use_wunschliste) {
	         ($seasonnumber, $episodenumber) = $b_wl->search($seriesname, $episodename);	      
              }
	      if ($use_fernsehserien && ($episodenumber eq "" || $episodenumber == 0 || $seasonnumber eq "" || $seasonnumber == 0)) {
	         ($seasonnumber, $episodenumber) = $b_fs->search($seriesname, $episodename);
              }
	      if ($use_tv_tb && ($episodenumber eq "" || $episodenumber == 0 || $seasonnumber eq "" || $seasonnumber == 0)) {
		 ($seasonnumber, $episodenumber) = $b_tvdb->search($seriesname, $episodename);
	      }
	      
	      if ($episodenumber ne "" && $episodenumber != 0 && $seasonnumber ne "" && $seasonnumber != 0) {
	       	$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum} = $seasonnumber;
	       	$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{episodeNum} = $episodenumber;
	       	$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{time} = time();
			
		my $abf = $dbh2->prepare("UPDATE program SET seriesNum=?,episodeNum=? WHERE idProgram=?;");
		my $a = $abf->execute($seasonnumber, $episodenumber, $akt_tv_serie_h->{'idProgram'}) or die $DBI::errstr;
		$abf->finish();

  	        Log::log("\tS${seasonnumber}E${episodenumber} => $episodename");
						
	      } else {
		$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum} = 'UNKNOWN';
		$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{episodeNum} = 'UNKNOWN';
		$seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{time} = time();

  	        Log::log("\tNOTHING FOUND => $seriesname $episodename");
	      }

  } # end episode of a series
  $abf_g->finish();

} # end series

nstore(\%seriescache, 'tmp/'.$progbasename.".seriescache"); 

Log::log("END seriessearch\n");



########################################### Clean RecordingsDB
Log::log("Cleanup RecordingsDB");

if ($cleanup_recordingdb && -d $cleanup_recordingdir) {
  my $abf_g = $dbh->prepare("SELECT * FROM recording;");
  $abf_g->execute() or die $DBI::errstr;
  while (my $aktrec = $abf_g->fetchrow_hashref()) {
	#print Dumper($aktrec)."\n\n";
	if (!-e $aktrec->{fileName}) {
		print "$aktrec->{'fileName'} does not exist -> delete DB Entry\n";
		my $abf = $dbh2->prepare("DELETE FROM recording WHERE idRecording = ?");
		my $a = $abf->execute($aktrec->{'idRecording'}) or die $DBI::errstr;
		$abf->finish();
	}
  }
  $abf_g->finish();  

} else {
   Log::log("Skipping recordingsdb cleanup");
}


########################################### Clean XML files...
print "Cleanup XML and other Files\n";

if ($cleanup_recordingfiles && -d $cleanup_recordingdir) {
   &checkdir($cleanup_recordingdir, 1);
} else {
   Log::log("Skipping recordingfiles cleanup");
}

print "END\n\n";



sleep($sleep);

## END
exit;


#### SUBS

sub _rm_dir($) {
  my $dir = shift;

  print "\tdelete dir $dir\n";

  my $DIRH;
  opendir($DIRH, $dir);
  my @files = readdir($DIRH);
  closedir($DIRH);
  
  foreach my $f (@files) {
  	next if ($f eq "." || $f eq "..");
  	if (-d "$dir\\$f") {
		&_rm_dir("$dir\\$f");
	}
  }

  opendir($DIRH, $dir);
  @files = readdir($DIRH);
  closedir($DIRH);
  
  foreach my $f (@files) {
  	next if ($f eq "." || $f eq "..");
  	print "\tDelete $f\n";
  	unlink("$dir\\$f");
  }
  
  rmdir($dir);
		
}

sub checkdir($$) {
  my $dir = shift;
  my $tiefe = shift;
  my $ts_found = 0;

  print "Check dir $dir\n";

  my $DIRH;
  opendir($DIRH, $dir);
  my @files = readdir($DIRH);
  closedir($DIRH);
  
  foreach my $f (@files) {
  	next if ($f eq "." || $f eq "..");
  	if ($f =~ /\.ts$/i) {
	   $ts_found = 1;
	}
  	if (-d "$dir\\$f") {
		&checkdir("$dir\\$f", $tiefe+1);
	} elsif (-e "$dir\\$f" && $f =~ /^(.*?)\.log$/ && (int((time() - (stat("$dir\\$f"))[10])/60)) > 180) { # erstellt vor 30 minuten
			print "Delete $f in $dir\n";
			unlink("$dir\\$f");
	} elsif (-e "$dir\\$f" && $f =~ /^(.*?)\.(logo\.txt|xml|txt|log|edl|jpg)$/) {
		my $f_name = $1;
		if ((!-e "$dir\\$f_name.ts") && (!-e "$dir\\$f_name.avi")) {
			print "Delete $f in $dir\n";
			unlink("$dir\\$f");
		}
	}
  }
  
  if ($ts_found == 0 && $tiefe > 1) {
	  print "Delete DIR $dir\n";
	  &_rm_dir($dir);
  }

}

sub load_and_clean_cache {
	%seriescache = %{retrieve('tmp/'.$progbasename.".seriescache")} if (-e 'tmp/'.$progbasename.".seriescache");
	
	### CLEAN Cache
	foreach my $serie (keys %seriescache) {
	   foreach my $title (keys %{$seriescache{$serie}}) {
		if ($seriescache{$serie}{$title}{seriesNum} eq "UNKNOWN" && $seriescache{$serie}{$title}{time} < (time()-(60*60*24*1))) {
			print "Delete $serie $title from cache with UNKNOWN\n";
			delete($seriescache{$serie}{$title});
		}
		if ($seriescache{$serie}{$title}{seriesNum} ne "UNKNOWN" && $seriescache{$serie}{$title}{time} < (time()-(60*60*24*14))) {
			print "Delete $serie $title from cache with $seriescache{$serie}{$title}{seriesNum}\n";
			delete($seriescache{$serie}{$title});
		}
	   }
	}
}

sub get_recordings() {
	my %recs;
	
	my $abf = $dbh->prepare("SELECT * FROM schedule;");
	$abf->execute() or die $DBI::errstr;
	while (my $aktrec = $abf->fetchrow_hashref()) {
	   $recs{$aktrec->{'programName'}} = 1;
	}
	$abf->finish();

return %recs;
}


sub basename {
   my $dir = shift;
   my $type = shift || "";

   $type = quotemeta($type);
   $dir =~ s#^.*\\##;
   $dir =~ s#$type$##i if ($type ne "");

return $dir;
}
