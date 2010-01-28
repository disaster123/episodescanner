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
use mtn;
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

# cp1252
my $w32encoding = Win32::Codepage::get_encoding();  # e.g. "cp1252"
my $encoding = $w32encoding ? resolve_alias($w32encoding) : '';

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
our $optimizemysqltables = 0;
our @run_external_commans = ();
our $use4tr = 0;
our $dbname_4tr = 'fortherecord';
our $mtn = 0;
our @mtn_dirs= ();
our @mtn_fileext = ('.ts');
our @mtn_options = ('-D 6 -B 420 -E 600 -c 1 -r 1 -s 300 -t -i -w 0 -n -P "$filename"',
                   '-D 8 -B   0 -E   0 -c 1 -r 1 -s  60 -t -i -w 0 -n -P "$filename"');

Log::start(1);

die "cannot find config.txt\n\n" if (!-e "config.txt");
eval('push(@INC, "."); do "config.txt";');
die $@."\n\n" if ($@);

die "$0 needs 3 options - wunschliste/fernsehserien/thetvdb/mtn seriesname/filename [episodename]\n\n" if (scalar(@ARGV) == 0 || ($ARGV[0] eq "mtn" && scalar(@ARGV) != 2) || 
																										   ($ARGV[0] ne "mtn" && scalar(@ARGV) != 3));


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
																										   
$tvdb_apikey = "24D235D27EFD8883";
Log::log("use global TVDB API Key");

# Build search objects
$b_wl = new Backend::Wunschliste;
$b_fs = new Backend::Fernsehserien;
$b_tvdb = new Backend::TVDB($progbasename, $tvdb_apikey, $thetvdb_language);

my $seriesname = $ARGV[1];
my $episodename = $ARGV[2];

Log::log("\n\tEpisode: $episodename") if (defined );

# start a new search on fernsehserien.de
my ($episodenumber, $seasonnumber) = ("", "");
	      
if ($ARGV[0] eq "wunschliste") {
   Log::log("Start wunschliste");
   ($seasonnumber, $episodenumber) = $b_wl->search($seriesname, $episodename);	      
} elsif ($ARGV[0] eq "fernsehserien") {
   Log::log("Start fernsehserien");
  ($seasonnumber, $episodenumber) = $b_fs->search($seriesname, $episodename);
} elsif ($ARGV[0] eq "thetvdb") {
   Log::log("Start: thetvdb");
  ($seasonnumber, $episodenumber) = $b_tvdb->search($seriesname, $episodename);
} else {
  Log::log("Do not know Engine $ARGV[0]");
}
	      
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
