#!/usr/bin/perl

BEGIN {
  $| = 1;
  
  $0 = $^X unless ($^X =~ m%(^|[/\\])(perl)|(perl.exe)$%i);
  my ($program_dir) = $0 =~ m%^(.*)[/\\]%;
  $program_dir ||= ".";
  chdir($program_dir);
}

END {
  $dbh->disconnect() if (defined $dbh);
  $dbh2->disconnect() if (defined $dbh2);
}

use lib 'lib';
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
use URI::Escape;
use LWP::Simple;
use LWP::UserAgent;
use URI;
use XML::Simple;
use HTML::Entities;
 
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
our $thetvdb_language = "de";
our $use_fernsehserien;
our $use_wunschliste;
our $cleanup_recordingdb;
our $cleanup_recordingfiles;
our $usemysql;
our $dbh;
our $dbh2;
our $db_backup = 0;
our $db_backup_interval = 2;
our $db_backup_delete = 48;
our $db_backup_sqlite_path;
our $db_backup_sqlite_backuppath;
our $use4tr = 0;
our $dbname_4tr = 'fortherecord';

die "cannot find config.txt\n\n" if (!-e "config.txt");
eval('push(@INC, "."); do "config.txt";');
die $@."\n\n" if ($@);

die "sleep value below 30 not allowed - we do not want to stress the websites too much!\n\n" if ($sleep < 30);

Log::start();

if ($use_tv_tb && $tvdb_apikey eq "") {
  $tvdb_apikey = "24D235D27EFD8883";
  Log::log("use global TVDB API Key");
}
# cp1252
our $w32encoding = Win32::Codepage::get_encoding() || '';  # e.g. "cp1252"
Log::log("got Win32 Codepage: ".$w32encoding, 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
our $encoding = ($w32encoding ? res4TR has an ownolve_alias($w32encoding) : '')  || '';
Log::log("got resolved alias: ".$encoding, 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);

if ($usemysql) {
  Log::log("using MySQL", 0);
  if ($use4tr) {
    Log::log("using 4TR Database", 0);
    $dbh = DBI->connect( "dbi:mysql:database=$dbname_4tr:hostname=$dbhost",
                                                   $dbuser, $dbpw) or die "Can't connect to MYSQL: $DBI::errstr\n\n";
    $dbh2 = DBI->connect( "dbi:mysql:database=$dbname_4tr:hostname=$dbhost",
                                                   $dbuser, $dbpw) or die "Can't connect to MYSQL: $DBI::errstr\n\n";
    $dbh->{InactiveDestroy} = 1;$dbh->{mysql_auto_reconnect} = 1;
    $dbh2->{InactiveDestroy} = 1;$dbh2->{mysql_auto_reconnect} = 1;
  } else {
    $dbh = DBI->connect( "dbi:mysql:database=$dbname:hostname=$dbhost",
                                                   $dbuser, $dbpw) or die "Can't connect to MYSQL: $DBI::errstr\n\n";
    $dbh2 = DBI->connect( "dbi:mysql:database=$dbname:hostname=$dbhost",
                                                   $dbuser, $dbpw) or die "Can't connect to MYSQL: $DBI::errstr\n\n";
    $dbh->{InactiveDestroy} = 1;$dbh->{mysql_auto_reconnect} = 1;
    $dbh2->{InactiveDestroy} = 1;$dbh2->{mysql_auto_reconnect} = 1;
  }
} else {
  Log::log("using MSSQL", 0);
  my $dsn = "dbi:ODBC:driver={SQL Server};Server=$dbhost;uid=$dbuser;pwd=$dbpw;Database=";
  my $db_options = {PrintError => 1,RaiseError => 1,AutoCommit => 1};
  if ($use4tr) {
    Log::log("using 4TR Database", 0);
    $dbh = DBI->connect($dsn.$dbname_4tr, $dbuser, $dbpw, $db_options) or die "Can't connect to MSSQL: $DBI::errstr\n\n";
    $dbh2 = DBI->connect($dsn.$dbname_4tr, $dbuser, $dbpw, $db_options) or die "Can't connect to MSSQL: $DBI::errstr\n\n";
    $dbh->{LongReadLen} = 20480;$dbh->{LongTruncOk} = 1;
    $dbh2->{LongReadLen} = 20480;$dbh2->{LongTruncOk} = 1;
  } else {
    $dbh = DBI->connect($dsn.$dbname, $dbuser, $dbpw, $db_options) or die "Can't connect to MSSQL: $DBI::errstr\n\n";
    $dbh2 = DBI->connect($dsn.$dbname, $dbuser, $dbpw, $db_options) or die "Can't connect to MSSQL: $DBI::errstr\n\n";
    $dbh->{LongReadLen} = 20480;$dbh->{LongTruncOk} = 1;
	$dbh2->{LongReadLen} = 20480;$dbh2->{LongTruncOk} = 1;
  }
}

if ($use4tr) {
    Log::log("Using 4TR disabling some incompatible settings");   
    Log::log("cleanup_recordingdb = 0");   
	$cleanup_recordingdb = 0;
    Log::log("cleanup_recordingfiles = 0");   
	$cleanup_recordingfiles = 0;
}

Log::log("Recordingdir: $cleanup_recordingdir") if ($cleanup_recordingfiles);

# load series cache
&load_and_clean_cache();

# Build search objects
$b_wl = new Backend::Wunschliste;
$b_fs = new Backend::Fernsehserien;
$b_tvdb = new Backend::TVDB($progbasename, $tvdb_apikey, $thetvdb_language);

# get all recordings
%tvserien = &get_recordings();

# Go through all TV Series
foreach my $tv_serie (sort keys %tvserien)  {
 	# sleep so that there are not too much cpu seconds and speed keeps slow
	sleep(3);
	Log::log("\nSerie: $tv_serie");

	RESCAN:

    # GO through show in EPG DB for tv_serie
    $tv_serie = encode($encoding, $tv_serie) if (defined $encoding && $encoding ne '');
    my $abf_g;
    if ($use4tr) {
       $abf_g = $dbh->prepare("SELECT SubTitle as episodeName, Title as title, GuideProgramId as idProgram
	                               FROM guideprogram WHERE SubTitle IS NOT NULL AND (SeriesNumber IS NULL OR EpisodeNumber IS NULL) 
                                   AND title LIKE ?;");
	} else {
       $abf_g = $dbh->prepare("SELECT * FROM program WHERE episodeName!= '' AND seriesNum='' AND title LIKE ?;");
    }
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
			my $abf;
			if ($use4tr) {
		       $abf = $dbh2->prepare("UPDATE guideprogram SET SeriesNumber=?,EpisodeNumber=? WHERE GuideProgramId=?;");
			} else {
		       $abf = $dbh2->prepare("UPDATE program SET seriesNum=?,episodeNum=? WHERE idProgram=?;");
			}
		    my $a = $abf->execute($seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{seriesNum}, 
					            $seriescache{$akt_tv_serie_h->{'title'}}{$akt_tv_serie_h->{'episodeName'}}{episodeNum}, 
								$akt_tv_serie_h->{'idProgram'}) or die $DBI::errstr;
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
			
			my $abf;
			if ($use4tr) {
		       $abf = $dbh2->prepare("UPDATE guideprogram SET SeriesNumber=?,EpisodeNumber=? WHERE GuideProgramId=?;");
			} else {
		       $abf = $dbh2->prepare("UPDATE program SET seriesNum=?,episodeNum=? WHERE idProgram=?;");
			}
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
if ($cleanup_recordingdb && -d $cleanup_recordingdir) {
  Log::log("Cleanup RecordingsDB");

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
if ($cleanup_recordingfiles && -d $cleanup_recordingdir) {
   print "\nCleanup XML and other Files\n";
   
   &checkdir($cleanup_recordingdir, 1);
} else {
   Log::log("Skipping recordingfiles cleanup");
}

########################################## DB Backup

if ($db_backup) {
    print "\nDB Backup\n";
	
	if (!-d $db_backup_sqlite_backuppath) {
		mkdir $db_backup_sqlite_backuppath;
	}

        my $newest = 99999999999999;	
        my @files = glob("$db_backup_sqlite_backuppath\\*");
        foreach my $dir (@files) {
		next if (!-d $dir || $dir =~ /^\./);
      	        # in Stunden
	        my $creation = int((time() - (stat($dir))[10])/60/60);
		if ($creation > $db_backup_delete) {
                   Log::log("delete $dir - was created $creation hours ago");
                   _rm_dir($dir);
	        }
	        $newest = $creation if ($newest > $creation);
	}
	if ($newest > $db_backup_interval) {
		Log::log("Last Backup is $newest hours old ($newest > $db_backup_interval)");
		my ($sec,$min,$hour,$heutetag,$heutemonat,$heutejahr,$wday,$yday,$isdst) = localtime(time());
		$heutemonat++;$heutejahr+=1900;
		$hour = sprintf "%02d",$hour;
		$min = sprintf "%02d",$min;
		$sec = sprintf "%02d",$sec;
		$heutemonat = sprintf "%02d",$heutemonat;
		$heutetag = sprintf "%02d",$heutetag;
		Log::log("Create new Backup $db_backup_sqlite_backuppath\\$heutejahr-$heutemonat-$heutetag-$hour");
        if (!-d "$db_backup_sqlite_backuppath\\$heutejahr-$heutemonat-$heutetag-$hour") {
          mkdir "$db_backup_sqlite_backuppath\\$heutejahr-$heutemonat-$heutetag-$hour";
          system("xcopy /Y $db_backup_sqlite_path $db_backup_sqlite_backuppath\\$heutejahr-$heutemonat-$heutetag-$hour\\");
        }
    }
} else {
   Log::log("Skipping DBBackup");
}


Log::log("END\n");

sleep($sleep);

## END
exit;


#### SUBS

sub _rm_dir {
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
			delete($seriescache{$serie}{$title});How
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
	
	my $abf;
	if ($use4tr) {
	   # 4TR stores it recording rules in XML Style...
       $abf = $dbh->prepare("SELECT Name, RulesXml FROM schedule WHERE IsActive = 1 AND IsOneTime = 0 AND RulesXml LIKE '%TitleEquals%';");
	} else {
       $abf = $dbh->prepare("SELECT * FROM schedule;");
	}
	$abf->execute() or die $DBI::errstr;
	while (my $aktrec = $abf->fetchrow_hashref()) {
	   if (defined $aktrec->{'RulesXml'}) {
	       # extract title from RulesXML
		   Log::log("\t".Dumper($aktrec), 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
		   if ($aktrec->{'RulesXml'} =~ m#<rule type="TitleEquals"><args><anyType xsi:type="xsd:string">([^\<]+)</anyType></args></rule>#i) {
		      my $programName = $1;
			  
		      $aktrec->{'programName'} = decode_entities($programName);
              Log::log("\t Extracted and decoded ".$aktrec->{'programName'}." from 4TR XML-Rule", 1);
		   } else {
              Log::log("\tSkip ".$aktrec->{'Name'}." cannot find programName in 4TR XML-Rule", 1);
              next;
		   }
	   }
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
