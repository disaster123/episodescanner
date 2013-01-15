#!/usr/bin/perl

BEGIN {
  $| = 1;
  
  $0 = $^X unless ($^X =~ m%(^|[/\\])(perl)|(perl.exe)$%i);
  my ($program_dir) = $0 =~ m%^(.*)[/\\]%;
  $program_dir ||= ".";
  chdir($program_dir);
}

use lib 'lib';
use lib 'libs';
use lib '.';

use Carp;
$SIG{__WARN__} = \&Carp::cluck;
$SIG{__DIE__} = \&Carp::confess;

use warnings;
use strict;
use thumbs;
use Log;
use Backend::Wunschliste;
use Backend::Fernsehserien;
use Backend::TVDB;
use Data::Dumper;
use Win32::Codepage;
use Encode qw(encode decode resolve_alias);
use Encode::Byte;
use Storable qw(nstore retrieve);
use Text::LevenshteinXS qw(distance);
use URI::Escape;
use LWP::Simple;
use LWP::UserAgent;
use URI;
use XML::Simple;
use DBI;
use DBD::ODBC;
use DBD::mysql;
use DBD::SQLite;
use Cmd;
use Win32::Console;
use Win32::Codepage;
use Encode qw(encode decode resolve_alias);
use Encode::Byte;
use Try::Tiny;

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

our $progbasename = &basename($0, '.exe');
our $DEBUG = 1; # Testing Unit is always DEBUG = 1
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
our $use_tvdb;
our $thetvdb_language = "de|en";
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
our $optimizemysqltables = 0;
our @run_external_commans = ();
our $use4tr = 0;
our $dbname_4tr = 'fortherecord';
our $mtn = 0;
our @mtn_dirs= ();
our @mtn_fileext = ('.ts');
our @mtn_options = ('-D 6 -B 420 -E 600 -c 1 -r 1 -s 300 -t -i -w 0 -n -P "$filename"',
                   '-D 8 -B   0 -E   0 -c 1 -r 1 -s  60 -t -i -w 0 -n -P "$filename"');
our $cleanup_recordings_tvseries = 0;
our $cleanup_recordings_tvseries_db = '';
our $cleanup_recordings_tvseries_db_mainpath = '';
our %episode_stubstitutions;

Log::start(1);

die "cannot find config.txt\n\n" if (!-e "config.txt");
eval('push(@INC, "."); do "config.txt";');
die $@."\n\n" if ($@);

die "$0 needs 3 options - wunschliste/fernsehserien/thetvdb/mtn/tvseriescleanup seriesname/filename [episodename]\n\n" if (scalar(@ARGV) == 0 || ($ARGV[0] eq "mtn" && scalar(@ARGV) != 2) || 
                                                                                                           ($ARGV[0] eq "tvseriescleanup" && scalar(@ARGV) != 1) || 
																										   ($ARGV[0] ne "mtn" && $ARGV[0] ne "tvseriescleanup" && scalar(@ARGV) != 3));

if ($ARGV[0] eq "mtn") {
   Log::log("Start: mtn");
   my $filename = mtn::processfile($ARGV[1], @mtn_options);
   if (!defined $filename) {
      Log::log("Thumb not created");  
   } else {
      Log::log("Thumb created: ".$filename);     
   }
   exit;
}

if ($ARGV[0] eq "tvseriescleanup") {
   Log::log("Start: tvseriescleanup");
   my $tvseries_dbh = DBI->connect("dbi:SQLite:dbname=".$cleanup_recordings_tvseries_db,"","");
   
   my %tvseries_files;
   my $sth = $tvseries_dbh->prepare("select * from local_episodes;");
   $sth->execute();
   while (my $data = $sth->fetchrow_hashref()) {
      $data->{'EpisodeFilename'} =~ s#^\Q$cleanup_recordings_tvseries_db_mainpath\E##i;
	  $tvseries_files{$data->{'EpisodeFilename'}} = 1;
      print $data->{'EpisodeFilename'}."\n";
   }
   $sth->finish();
   
   $tvseries_dbh->disconnect();
   exit;
}
																										   
$tvdb_apikey = "24D235D27EFD8883";
Log::log("use global TVDB API Key");

# Build search objects
$b_wl = new Backend::Wunschliste;
$b_fs = new Backend::Fernsehserien;
$b_tvdb = new Backend::TVDB($progbasename, $tvdb_apikey, $thetvdb_language);

# THIS IS IMPORTANT as ARGV is not UTF8 here - but the console OUTPUT may not match as the codepage setting does not work - no idea why
utf8::encode($_) for @ARGV;

my $seriesname = $ARGV[1];
my $episodename = $ARGV[2];

Log::log("\n\tEpisode: $episodename");

# start a new search on fernsehserien.de
my ($episodenumber, $seasonnumber) = ("", "");
	      
if ($ARGV[0] eq "wunschliste") {
   Log::log("Start wunschliste");
   Cmd::fork_and_wait {
     ($seasonnumber, $episodenumber) = $b_wl->search($seriesname, $episodename, \%episode_stubstitutions);	      
   };
} elsif ($ARGV[0] eq "fernsehserien") {
   Log::log("Start fernsehserien");
   Cmd::fork_and_wait {
     ($seasonnumber, $episodenumber) = $b_fs->search($seriesname, $episodename, \%episode_stubstitutions);
   };
} elsif ($ARGV[0] eq "thetvdb") {
   Log::log("Start: thetvdb");
   Cmd::fork_and_wait {
     ($seasonnumber, $episodenumber) = $b_tvdb->search($seriesname, $episodename, \%episode_stubstitutions);
   };
} else {
  Log::log("Do not know Engine $ARGV[0]");
}
print "S$seasonnumber, E$episodenumber\n";
Log::log("END\n");

## END
exit;


#### SUBS


sub basename {
   my $dir = shift;
   my $type = shift || "";

   $type = quotemeta($type);
   $dir =~ s#^.*\\##;
   $dir =~ s#$type$##i if ($type ne "");

return $dir;
}
