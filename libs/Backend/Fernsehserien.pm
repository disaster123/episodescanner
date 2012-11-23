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
use Backend::EpisodeSubst;

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
  my $subst = shift;
  my %subst = %{$subst};
  my $episodenumber = "";
  my $seasonnumber = "";

  Log::log("\tsearch on http://www.fernsehserien.de/...");

  my $page = _myget("http://www.fernsehserien.de/index.php", ( suche => $seriesname ));
  
  FS_RECHECK:
  # test if it is directly a result page
  if ($page =~ m#<a href="([^"]{2,}/episodenguide)">Episodenguide</a>#) {
        $page = _myget("http://www.fernsehserien.de/$1");
  } else {
    # Try to get all Series
	# <span class="suchergebnis-titel">New Girl</span>
	my $seriesname_html = $self->html_entitiy($seriesname);
    if ($page =~ m#href="([^"]+)".*?<span class="suchergebnis-titel">\Q$seriesname_html\E</span>#i) {
      my $uri = $1;
      Log::log("Found new / remapped page $uri", 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
      my %par = ();
      if ($uri =~ m#\?(.*)$#i) {
	    foreach my $l (split(/&/, $1)) {
	      my ($name, $value) = split(/=/, $l, 2);
	      $par{$name} = $value;
	    }
	    $uri =~ s#\?.*$##;
	  }
	  $page = _myget("http://www.fernsehserien.de/".$uri, %par);
	  goto FS_RECHECK;
	} else {
	   if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
		   my $FH;
		   open($FH, ">fernsehserien_".++$self->{'debug_counter'}.".htm");
		   print $FH $page;
		   close($FH);
           Log::log("\tWriting debug page to: ".$self->{'debug_counter'}, 1);
	   }

       Log::log("\tWas not able to find series/seriesindexpage \"$seriesname\" at Fernsehserien");
	   return (-1, 0);
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
  my $episodename_search = $self->staffeltitle_to_regtest($episodename, %subst);
  foreach my $fs_title (sort keys %staffeln) {
        my $regtest = $self->staffeltitle_to_regtest($fs_title, %subst);

        $regtest = encode($encoding, $regtest) if (defined $encoding && $encoding ne '');		     		     
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
   # check if there were detected one via fuzzy at all
   } elsif (defined $fuzzy{name}) {
       Log::log("\tnearest fuzzy found: Name: $fuzzy{name} Dist: $fuzzy{distance} S$fuzzy{seasonnumber}E$fuzzy{episodenumber}", 0);
   }
   
   if ($seasonnumber eq "0" || $seasonnumber eq "") {
       Log::log("\tfound series but not episode \"$episodename\" at Fernsehserien");
	   if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1) {
		   my $FH;
		   open($FH, ">fernsehserien_".++$self->{'debug_counter'}.".htm");
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
   my @lines = split(/\n/, $p);
   # foreach my $i (0..$#lines) {
   for (my $i = 0; $i <= $#lines; $i++) {
     my $line = $lines[$i];
	 chomp($line);
   
   	 if ($line =~ /^\s*bisher\s+\d+\s+(Episoden|Folgen)/i) {
		# print "Start found == 1\n";
   		$start = 1;
   		next;
   	 }

   	 if ($start == 0 && ($line =~ /^\s*(\d+)\. Staffel/i || $line =~ /^\s*Staffel (\d+)/i)) {
		# print "Start found == 1\n";
   		$start = 1;
   	 }

   	 next if ($start == 0);
   	
   	 if ($line =~ /^\s*(\d+)\. Staffel/i|| $line =~ /^\s*Staffel (\d+)$/i) {
		$aktstaffel = $1;
		$aktseries_in_staffel = 0;
   		next;
   	 }
   	 next if (!$aktstaffel);

#6
#[98]
#Entwischt
#01.02.2006

   	 if ($line =~ /^(\d+)$/ && $lines[$i+1] =~ /^\[\d+\]$/ && $lines[$i+3] =~ /^\d{2}\.\d{2}\.\d{4}$/) {
	   $aktseries_in_staffel = $line;
   	   $aktstaffel = 1 if ($aktstaffel == 0);
	   
	   my $episodename = $lines[$i+2];
   	   $r{$episodename}{E} = $aktseries_in_staffel;
   	   $r{$episodename}{S} = $aktstaffel;
	   $i += 4;
   	   next;
   	 }
   }

return %r;
}

sub staffeltitle_to_regtest {
        my $self = shift;
        my $regtest = shift;
  		my %subst = @_;
  
        $regtest = EpisodeSubst($regtest, %subst);
# TODO CLEAN??
return lc($regtest);

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

sub html_entitiy {
   shift; # this is $self
   my $r = shift;
   
   $r =~ s/&/&amp;/g;
   
   return $r;
}

sub _myget {
	my $url = shift;
	my %par = @_;

	my $ua = LWP::UserAgent->new();
	my $uri = URI::URL->new($url);
	$uri->query_form(%par);
	
	my $resp = $ua->get($uri);
	my $r = $resp->content();
	
	# fernsehserien is UTF-8
    $r = encode($encoding, decode('utf-8', $r));

return $r;
}

1;