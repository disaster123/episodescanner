#!/usr/bin/perl

$| = 1;

use lib 'lib';
use lib 'libs';
use lib '.';

use warnings;
use strict;
use Config::General;
use Log;
use thumbs;
use Backend::Wunschliste;
use Backend::Fernsehserien;
use Backend::TVDB;
use Data::Dumper;
use DBI;
use DBD::ODBC;
use DBD::mysql;
use DBD::SQLite;
use Storable qw(nstore retrieve);
use Text::LevenshteinXS qw(distance);
use URI::Escape;
use LWP::Simple;
use LWP::UserAgent;
use URI;
use XML::Simple;
use XML::Parser;
use HTML::Entities;
use Win32::Process qw(STILL_ACTIVE IDLE_PRIORITY_CLASS NORMAL_PRIORITY_CLASS CREATE_NEW_CONSOLE);
use Time::HiRes qw( usleep sleep );
use Cmd;
use Win32::Console;
use Win32::Codepage;
use Encode qw(encode decode resolve_alias);
use Encode::Byte;
use Try::Tiny;

my $currentProcess;
if (Win32::Process::Open($currentProcess, Win32::Process::GetCurrentProcessID(), 0)) {
  $currentProcess->SetPriorityClass(IDLE_PRIORITY_CLASS);
} else {
  die "Can not find myself ($^E)\n";
}
 
our $progbasename = basename($0, '.exe');
our $DEBUG = (defined $ARGV[0] && $ARGV[0] eq "-debug") ? 1 : 0;
$ENV{DEBUG} = $DEBUG;

BEGIN {
  $0 = $^X unless ($^X =~ m%(^|[/\\])(perl)|(perl.exe)$%i);
  my ($program_dir) = $0 =~ m%^(.*)[/\\]%;
  $program_dir ||= ".";
  if ($program_dir =~ m#^(.*)bin[\\/]{0,1}$#) {
    $program_dir = $1;
  }
  chdir($program_dir);
  binmode STDOUT, ':utf8';
  binmode STDERR, ':utf8';
  Win32::Console::OutputCP( 65001 );
}
# hey skip on cava
if ($^X =~ /(perl)|(perl\.exe)$/i) {
  eval("use Carp;\$SIG{__WARN__} = \\&Carp::cluck;\$SIG{__DIE__} = \\&Carp::confess;");
}

#new episodescanner
#my $conf = new Config::General(-ConfigFile => "episodescanner.settings", -ForceArray => 1, -AutoTrue => 1 );
#my %config = $conf->getall;
#print Dumper(\%config);
#exit;

our $tvdb_apikey;
our $cleanup_recordingdir;
our $dbuser;
our $dbpw;
our $dbname;
our $dbhost;
our $sleep;
our %recordingfilenames;
our %tvserien;
our %backendcache;
our %seriescache;
our $FH;
our $b_wl;
our $b_fs;
our $b_tvdb;
our $use_tvdb;
our $thetvdb_language = "de";
our $use_fernsehserien;
our $use_wunschliste;
our $cleanup_recordingdb;
our $cleanup_recordingfiles;
our @cleanup_recordingdir_ext = ('.ts', '.avi', '.mkv');
our $usemysql;
our $dbh;
our $dbh2;
our $db_backup = 0;
our $db_backup_interval = 2;
our $db_backup_delete = 48;
our $db_backup_sqlite_path;
our $db_backup_sqlite_backuppath;
our $optimizemysqltables = 0;
our @run_external_commans = ();
our $use4tr = 0;
our $dbname_4tr = 'fortherecord';
our $thumbs = 0;
our @thumb_dirs;
our @thumb_fileext;
our @thumb_progs;
our %thumb_blacklist;
our $cleanup_recordings_tvseries = 0;
our $cleanup_recordings_tvseries_db = '';
our $cleanup_recordings_tvseries_db_mainpath = '';
our $cleanup_recordings_tvseries_recordings_mainpath = '';
our %episode_stubstitutions;

die "cannot find config.txt\n\n" if (!-e "config.txt");
eval(q|push(@INC, '.'); require "config.txt";|);
die $@."\n\n" if ($@);

die "sleep value below 30 not allowed - we do not want to stress the websites too much!\n\n" if (!defined $sleep || $sleep < 30);

Log::start();

# Log::log("Started version #SVN 23.05.2011");

if ($use_tvdb && (!defined $tvdb_apikey || $tvdb_apikey eq "")) {
  Log::log("use global TVDB API Key");
  $tvdb_apikey = "24D235D27EFD8883";
} else {
  Log::log("using custom API Key");
}

# cp1252
our $w32encoding = Win32::Codepage::get_encoding() || '';  # e.g. "cp1252"
Log::log("got Win32 Codepage: ".$w32encoding, 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
our $encoding = ($w32encoding ? resolve_alias($w32encoding) : '')  || '';
Log::log("got resolved alias: ".$encoding, 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);

if ($use4tr) {
  Log::log("using 4TR Database", 0);
  $dbname = $dbname_4tr;
  Log::log("Using 4TR disabling some incompatible settings");   
  Log::log("cleanup_recordingdb = 0");   
  $cleanup_recordingdb = 0;
  Log::log("cleanup_recordingfiles = 0");   
  $cleanup_recordingfiles = 0;
}
if ($usemysql) {
  Log::log("using MySQL", 0);
  $dbh = DBI->connect( "dbi:mysql:database=$dbname:hostname=$dbhost",
                                                 $dbuser, $dbpw, {mysql_enable_utf8 => 1} ) or die "Can't connect to MYSQL: $DBI::errstr\n\n";
  $dbh2 = DBI->connect( "dbi:mysql:database=$dbname:hostname=$dbhost",
                                                 $dbuser, $dbpw, {mysql_enable_utf8 => 1} ) or die "Can't connect to MYSQL: $DBI::errstr\n\n";
  $dbh->{InactiveDestroy} = 1;$dbh->{mysql_auto_reconnect} = 1;
  $dbh2->{InactiveDestroy} = 1;$dbh2->{mysql_auto_reconnect} = 1;
} else {
  # Overwrite mysql setting when using MSSQL
  $optimizemysqltables = 0;
  Log::log("using MSSQL", 0);
  my $dsn = "dbi:ODBC:driver={SQL Server};Server=$dbhost;uid=$dbuser;pwd=$dbpw;Database=";
  my $db_options = {PrintError => 1,RaiseError => 1,AutoCommit => 1,odbc_utf8_on => 1};
  $dbh = DBI->connect($dsn.$dbname, $dbuser, $dbpw, $db_options) or die "Can't connect to MSSQL: $DBI::errstr\n\n";
  $dbh2 = DBI->connect($dsn.$dbname, $dbuser, $dbpw, $db_options) or die "Can't connect to MSSQL: $DBI::errstr\n\n";
  $dbh->{LongReadLen} = 20480;$dbh->{LongTruncOk} = 1;
  $dbh2->{LongReadLen} = 20480;$dbh2->{LongTruncOk} = 1;
}

Log::log("Recordingdir: $cleanup_recordingdir") if ($cleanup_recordingfiles);

# load series cache
load_and_clean_cache();

# Build search objects
$b_wl = new Backend::Wunschliste;
$b_fs = new Backend::Fernsehserien;
if ($use_tvdb) {
  # as thetvdb build up a connection immediatly it makes sense to do this ONLY if the user wants this
  eval {
     $b_tvdb = Backend::TVDB->new($progbasename, $tvdb_apikey, $thetvdb_language);
  };
  if ($@) {
    Log::log("TheTVDB Backend failed with unknown ERROR. Please run debug.bat and post your Log to forum.");
	Log::log($@, 1);
	exit;
  }
  if (!defined $b_tvdb) {
    $use_tvdb = 0;
  } else {
    Log::log("TVDB Backend successfully initialized.") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
  }
}

Log::log("START seriessearch");
# get all recordings
%tvserien = get_recordings($backendcache{'skip'});

# Go through all TV Series
foreach my $tv_serie (sort keys %tvserien)  {
 	# sleep so that there are not too much cpu seconds and speed keeps slow
	sleep(1);
	Log::log("\nSerie: $tv_serie");
	
	if (!((!$use_wunschliste || !defined $backendcache{wunschliste}{$tv_serie}) || (!$use_tvdb || !defined $backendcache{tvdb}{$tv_serie}) || 
	   (!$use_fernsehserien || !defined $backendcache{fernsehserien}{$tv_serie}))) {
	  $backendcache{'skip'}{$tv_serie} = time();
	  &Log::log("Skipping series - no backend knows it");
	  next;
	}
	delete($backendcache{'skip'}{$tv_serie});

	RESCAN:

    # GO through show in EPG DB for tv_serie
    my $abf_g;
    if ($use4tr) {
       $abf_g = $dbh->prepare("SELECT SubTitle as episodeName, Title as title, GuideProgramId as idProgram
	                               FROM guideprogram WHERE SubTitle IS NOT NULL AND (SeriesNumber IS NULL OR EpisodeNumber IS NULL) 
                                   AND title LIKE ?;");
	} else {
       $abf_g = $dbh->prepare("SELECT * FROM program WHERE episodeName!= '' AND seriesNum='' AND title LIKE ?;");
    }
    $abf_g->execute($tv_serie) or die $DBI::errstr;
	#print "STEFAN: Start Loop for $tv_serie\n";
    while (
	  ((!$use_wunschliste || !defined $backendcache{wunschliste}{$tv_serie}) || (!$use_tvdb || !defined $backendcache{tvdb}{$tv_serie}) || 
	   (!$use_fernsehserien || !defined $backendcache{fernsehserien}{$tv_serie})) &&
	   (my $akt_tv_serie_h = $abf_g->fetchrow_hashref()) ) {
		  
	    sleep(0.5);
        # print Dumper($akt_tv_serie_h)."\n\n";
    	     
        my $seriesname = $tv_serie;
        my $episodename = $akt_tv_serie_h->{'episodeName'};
        $seriesname =~ s#\s+$##;
        $seriesname =~ s#^\s+##;
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

        my ($episodenumber, $seasonnumber) = ("", "");
	    if ($use_fernsehserien && ($episodenumber eq "" || $episodenumber <= 0 || $seasonnumber eq "" || $seasonnumber <= 0)) {
          Log::log("Fernsehserien Backend search started $seriesname, $episodename") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
		  if (!defined $backendcache{fernsehserien}{$akt_tv_serie_h->{'title'}}) {
		    Cmd::fork_and_wait {
	          ($seasonnumber, $episodenumber) = $b_fs->search($seriesname, $episodename, \%episode_stubstitutions);
            };
			if ($@) {
			  Log::log("Fernsehserien Backend failed with unknown ERROR. Please run debug.bat and post your Log to forum.");
			  Log::log($@, 1);
			} elsif ($seasonnumber =~ /\d+/ && $seasonnumber == -1) {
              $backendcache{fernsehserien}{$akt_tv_serie_h->{'title'}} = time();
			}
	      } else {
		    Log::log("\tFernsehserien Backend skipped - series not known");
		  }
        }
        if ($use_wunschliste && ($episodenumber eq "" || $episodenumber <= 0 || $seasonnumber eq "" || $seasonnumber <= 0)) {
          Log::log("Wunschliste Backend search started $seriesname, $episodename") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
		  if (!defined $backendcache{wunschliste}{$akt_tv_serie_h->{'title'}}) {
		    Cmd::fork_and_wait {
              ($seasonnumber, $episodenumber) = $b_wl->search($seriesname, $episodename, \%episode_stubstitutions);	      
			};
			if ($@) {
			  Log::log("Wunschliste Backend failed with unknown ERROR. Please run debug.bat and post your Log to forum.");
			  Log::log($@, 1);
			} elsif ($seasonnumber =~ /\d+/ && $seasonnumber == -1) {
              $backendcache{wunschliste}{$akt_tv_serie_h->{'title'}} = time();
			}
		  } else {
		    Log::log("\tWunschliste Backend skipped - series not known");
		  }
        }
	    if ($use_tvdb && ($episodenumber eq "" || $episodenumber <= 0 || $seasonnumber eq "" || $seasonnumber <= 0)) {
          Log::log("TVDB Backend search started $seriesname, $episodename") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	      if (!defined $backendcache{tvdb}{$akt_tv_serie_h->{'title'}}) {
		    Cmd::fork_and_wait {
		      ($seasonnumber, $episodenumber) = $b_tvdb->search($seriesname, $episodename, \%episode_stubstitutions);
			};
			if ($@) {
			  Log::log("TheTVDB Backend failed with unknown ERROR. Please run debug.bat and post your Log to forum.");
			  Log::log($@, 1);
			} elsif ($seasonnumber =~ /\d+/ && $seasonnumber == -1) {
              $backendcache{tvdb}{$akt_tv_serie_h->{'title'}} = time();
			}
		  } else {
		    Log::log("\tTVDB Backend skipped - series not known");
		  }
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
nstore(\%backendcache, 'tmp/'.$progbasename.".backendcache"); 

Log::log("END seriessearch\n");



########################################### Clean RecordingsDB
if ($cleanup_recordingdb && -d $cleanup_recordingdir) {
  Log::log("\nCleanup RecordingsDB");

  my $abf_g = $dbh->prepare("SELECT * FROM recording;");
  $abf_g->execute() or die $DBI::errstr;
  while (my $aktrec = $abf_g->fetchrow_hashref()) {
	if (!-e Win32::GetANSIPathName($aktrec->{fileName})) {
		Log::log("$aktrec->{'fileName'} does not exist -> delete DB Entry");
	    $dbh2->do("DELETE FROM recording WHERE idRecording = ?", undef, $aktrec->{'idRecording'}) or die $DBI::errstr;
	}
  }
  $abf_g->finish();  

}

########################################### Clean tvseriescleanup
if ($cleanup_recordings_tvseries) {
  Log::log("\nCleanup tvseriescleanup");

  try {
    if (!-e $cleanup_recordings_tvseries_db) {
	    die "DB File $cleanup_recordings_tvseries_db does not exist!\n";
    }
	if (!open(my $EFH, "<", $cleanup_recordings_tvseries_db)) {
	   die "Cannot open $cleanup_recordings_tvseries_db $!\n";
	}

    my %tvseries_files;
    my $tvseries_dbh = DBI->connect("dbi:SQLite:dbname=".$cleanup_recordings_tvseries_db,"","") or die $DBI::errstr; 
    $tvseries_dbh->{sqlite_unicode} = 1;
    my $sth = $tvseries_dbh->prepare("select * from local_episodes WHERE SeriesID > 0;") or die "Query failed!: $DBI::errstr";
    $sth->execute() or die "Query failed!: $DBI::errstr";
    while (my $data = $sth->fetchrow_hashref()) {
      $data->{'EpisodeFilename'} =~ s#^\Q$cleanup_recordings_tvseries_db_mainpath\E##i;
	  
      $tvseries_files{$data->{'EpisodeFilename'}} = 1;

	  Log::log("SQLite: ".$data->{'EpisodeFilename'}, 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
    }
    $sth->finish();
    $tvseries_dbh->disconnect();  
 
    my $abf_g = $dbh->prepare("SELECT * FROM recording;") or die $DBI::errstr;
    $abf_g->execute() or die $DBI::errstr;
    while (my $aktrec = $abf_g->fetchrow_hashref()) {
      $aktrec->{fileName} =~ s#^\Q$cleanup_recordings_tvseries_recordings_mainpath\E##i;
	  if (defined $tvseries_files{$aktrec->{fileName}}) {
		Log::log("$aktrec->{'fileName'} also exist in tvseries -> delete DB Entry");
		$dbh2->do("DELETE FROM recording WHERE idRecording = ?", undef, $aktrec->{'idRecording'});
	  }

 	  Log::log("recording DB: ".$aktrec->{fileName}, 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
    }
    $abf_g->finish();  
  } catch {
    warn $_;
  };
}

########################################### Clean XML files...
if ($cleanup_recordingfiles && -d $cleanup_recordingdir && scalar(@cleanup_recordingdir_ext) > 0) {
   print "\nCleanup XML and other Files\n";
   
   &checkdir($cleanup_recordingdir, 1);
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
}

####################### Optimize MySQL DBs

if ($optimizemysqltables > 0) {
  my $creation = 0;
  $creation = int((time() - (stat("optimizemysqltables.txt"))[9])/60/60) if (-e "optimizemysqltables.txt");
  if (!-e "optimizemysqltables.txt" || $creation >= $optimizemysqltables) {
      Log::log("\nOptimize MySQL Tables last run $creation hours ago.");
	  
      unlink("optimizemysqltables.txt");
      my $FH;
      open($FH, ">optimizemysqltables.txt");
	  close($FH);

      my $abf = $dbh->prepare("SHOW databases;");
      $abf->execute();
      while (my $db = ($abf->fetchrow_array())[0]) {
	     next if ($db eq "information_schema" || $db eq "performance_schema");
         Log::log("optimize `$db`;");
         $dbh2->do("use `$db`;");

         my $abf2 = $dbh2->prepare("SHOW tables;");
         $abf2->execute();
         while (my $table = ($abf2->fetchrow_array())[0]) {
            Log::log("optimize `$table`;", 1);
            $dbh2->do("OPTIMIZE table `$table`;");
         }
         $abf2->finish();	 
      }
      $abf->finish();
  }
}

######################### run external commands

Log::log("\nRun external commands") if (scalar(@run_external_commans) > 0);
my $c = 0;
foreach my $l (@run_external_commans) {
   if ($l =~ /^(.*)\|(\d+)$/) {
       my $prog = $1;
	   my $hours = $2;

       if (!-e "run_ext_cmd_$c.txt" || int((time() - (stat("run_ext_cmd_$c.txt"))[9])/60/60) >= $hours) {
           my $FH;
           unlink("run_ext_cmd_$c.txt");
           open($FH, ">run_ext_cmd_$c.txt");
	       close($FH);
	       Log::log("Run command $l");
		   system("start /WAIT \"".$prog."\"");
	   } else {
	       Log::log("don't run command $l - last run was before $hours") if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
	   }
   } else {
       Log::log("$l is not a valid external commands line");
   }
   $c++;
}

######################### run THUMBS

if ($thumbs) {
  Log::log("\nRun thumbnail generation");
  foreach my $dir (@thumb_dirs) {
    if (!-e $dir || !-d $dir) {
	  Log::log("Dir $dir does not exist!");
	  next;
	}
    Log::log("run thumbnailprogs for $dir");
    &thumb_checkdir($dir, \@thumb_fileext, \@thumb_progs);
  }
}

$dbh->disconnect() if (defined $dbh);
$dbh2->disconnect() if (defined $dbh2);

Log::log("\nEND\n");

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
  my @vids = ();

  Log::log("Check dir $dir", 1);

  my $DIRH;
  opendir($DIRH, $dir);
  my @files = readdir($DIRH);
  closedir($DIRH);
  
  foreach my $ext (@cleanup_recordingdir_ext) {
    push(@vids, grep(/\Q$ext\E$/, @files));
  }
  #print "Found vids ", join(",", @vids), " in dir $dir\n";

  foreach my $f (@files) {
  	next if ($f eq "." || $f eq "..");

    if (-d "$dir\\$f") {
      &checkdir("$dir\\$f", $tiefe+1);

	} elsif (-f "$dir\\$f" && $f =~ /^(.*?)\.([^\.]+)$/) {
      my $f_name = $1;
	  my $f_ext = ".".$2;
	
      if (-f "$dir\\$f" && $f_ext eq ".log" && (int((time() - (stat("$dir\\$f"))[10])/60)) > 180) { # erstellt vor 180 minuten
        Log::log("Delete Logfile $f in $dir");
        unlink("$dir\\$f");
	  } elsif (-f "$dir\\$f" && !grep(/^\Q$f_name\E\.[^\.]+$/, @vids) && !grep( {$_ eq $f_ext} @cleanup_recordingdir_ext)) {
        Log::log("Delete $f in $dir");
        unlink("$dir\\$f");
	  }
	}
  }
  
  if (scalar(@vids) == 0 && $tiefe > 1) {
	  print "Delete DIR $dir\n";
	  &_rm_dir($dir);
  }
}

sub thumb_checkdir($$$) {
  my $dir = shift;
  my $thumb_fileext = shift;
  my $thumb_progs = shift;

  my $thumb_fileext_regex = join('|', map {quotemeta($_)} @$thumb_fileext);

  %thumb_blacklist = %{retrieve('tmp/'.$progbasename.".thumbblacklist")} if (-e 'tmp/'.$progbasename.".thumbblacklist");
  foreach my $file (keys %thumb_blacklist) {
    if (!-e $file) {
	  delete($thumb_blacklist{$file});
	}
  }
  
  Log::log("\tCheck dir $dir Fileext: $thumb_fileext_regex", 1);

  my $DIRH;
  opendir($DIRH, $dir);
  my @files = readdir($DIRH);
  closedir($DIRH);
  
  foreach my $f (@files) {
  	next if ($f eq "." || $f eq "..");

  	if (-d "$dir\\$f") {
		&thumb_checkdir("$dir\\$f", $thumb_fileext, $thumb_progs);
	} elsif (-f "$dir\\$f" && $f =~ /($thumb_fileext_regex)$/) {
	   my $basefile = $f;
       $basefile =~ s#\.[a-z]+$##;
       next if (-e "$dir\\$basefile.jpg" && !-z "$dir\\$basefile.jpg");
       # skip if the file is not at least 10 min old
	   next if (int((time() - (stat("$dir\\$f"))[9])/60) < 10); 
	   
	   if ($thumb_blacklist{"$dir\\$f"} > 3) {
	     Log::log("\tSkipping Thumb generation for: \"$dir\\$f\"");
	     next;
	   }
	   
       Log::log("\tCreating Thumb for "."$dir\\$f");     
	   my $filename = thumbs::processfile("$dir\\$f", @$thumb_progs);
       if (!defined $filename) {
          Log::log("\tThumb not created: \"$dir\\$f\"");
		  $thumb_blacklist{"$dir\\$f"}++;
       } else {
          Log::log("\tThumb created: ".$filename);
       }
    }
  }
  
  nstore(\%thumb_blacklist, 'tmp/'.$progbasename.".thumbblacklist"); 
}


sub load_and_clean_cache {
	%seriescache = %{retrieve('tmp/'.$progbasename.".seriescache")} if (-e 'tmp/'.$progbasename.".seriescache");
    %backendcache = %{retrieve('tmp/'.$progbasename.".backendcache")} if (-e 'tmp/'.$progbasename.".backendcache");
	
	### CLEAN Cache
	foreach my $serie (keys %seriescache) {
	  foreach my $title (keys %{$seriescache{$serie}}) {
		if ($seriescache{$serie}{$title}{seriesNum} eq "UNKNOWN" && $seriescache{$serie}{$title}{time} < (time()-(60*60*24*1))) {
			print "Delete $serie $title from cache with UNKNOWN\n";
			delete($seriescache{$serie}{$title});
			next;
		}
		if ($seriescache{$serie}{$title}{seriesNum} ne "UNKNOWN" && $seriescache{$serie}{$title}{time} < (time()-(60*60*24*14))) {
			print "Delete $serie $title from cache with $seriescache{$serie}{$title}{seriesNum}\n";
			delete($seriescache{$serie}{$title});
			next;
		}
	  }
	}
	### CLEAN Cache
	foreach my $backend (keys %backendcache) {
	  foreach my $series (keys %{$backendcache{$backend}}) {
		if ($backendcache{$backend}{$series} < (time()-(60*60*24*1))) {
			print "Delete $backend $series from cache\n";
			delete($backendcache{$backend}{$series});
			next;
		}
	  }
	}
}

sub get_recordings {
    my $skips = shift || {};
	my %recs;
		
	my $abf;
	if ($use4tr) {
	   # 4TR stores it recording rules in XML Style...
       $abf = $dbh->prepare("SELECT Name, RulesXml FROM schedule WHERE IsActive = 1 AND IsOneTime = 0 AND RulesXml LIKE '%TitleEquals%';");
	   $abf->execute() or die $DBI::errstr;
	} else {
       $abf = $dbh->prepare("SELECT s.* FROM schedule AS s, program AS p WHERE s.programName = p.title AND p.episodeName != '' AND p.seriesNum = ''".
                             ((keys %$skips) ? " AND s.programName NOT IN (".(join(", ", ("?") x scalar(keys %$skips))).")" : "") .  ";");
	   $abf->execute(keys %$skips) or die $DBI::errstr;
	}
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

   $dir =~ s#^.*\\##;
   $dir =~ s#^.*/##; # unix / cava style
   $dir =~ s#\Q$type\E$##i if ($type ne "");
   
return $dir;
}
