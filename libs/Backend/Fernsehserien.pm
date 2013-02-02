package Backend::Fernsehserien;

use warnings;
use strict;
use LWP::UserAgent;
use URI;
use URI::URL;
use URI::Escape;
use Data::Dumper;
use Text::LevenshteinXS qw(distance);
use Log;
use Backend::EpisodeSubst;

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

  my $searchname = $self->searchname($seriesname);
  my $page = _myget("http://www.fernsehserien.de/index.php", ( suche => $searchname ));
  
  FS_RECHECK:
  # test if it is directly a result page
  if ($page =~ m#<a href="([^"]{2,}/episodenguide)">Episodenguide</a>#) {
        $page = _myget("http://www.fernsehserien.de/$1");
  } else {
    # Try to get all Series
	# <span class="suchergebnis-titel">New Girl</span>
	my $seriesname_html = $self->fs_html_entitiy($seriesname);
	# we need to make this one greedy by starting with ^.* otherwise the match doesn't work as perl starts to put as much
	# in .*? which results in incorrect links => right to left match
    if ($page =~ m#^.*( href="([^"]+)".*?class="suchergebnis-titel">\Q$seriesname_html\E</span>)#is) {
      my $uri = $2;
      Log::log("Found new / remapped page $uri by $1", 1) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
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
  $page =~ s#<head>((\n|\r|.)*?)</head>#\n#ig;
  $page =~ s#<script>((\n|\r|.)*?)</script>#\n#ig;
  $page =~ s#\r#\n#ig;
  $page =~ s#<br(>|\s*/>)#\n#ig;
  $page =~ s#<li>#\n#ig;
  $page =~ s#<p>#\n#ig;
  $page =~ s#</p>#\n#ig;
  $page =~ s#<[^>]+?>##ig;
  $page =~ s#\n\n#\n#ig;

  my %staffeln = $self->get_staffel_hash($page);
  
  my %fuzzy = ();
  $fuzzy{distance} = 99;
  $fuzzy{maxdistance} = 2;
  my $episodename_search = $self->staffeltitle_to_regtest($episodename, %subst);
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
		   print $FH "-" x 120 , "\n";
		   print $FH Dumper(\%staffeln);
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

   my $aktseason = 0;
   my $start = 0;
   my $aktepisode = 0;
   my @lines = split(/\n/, $p);
   # foreach my $i (0..$#lines) {
   for (my $i = 0; $i <= $#lines; $i++) {
     my $line = $lines[$i];
	 chomp($line);
   
   	 if ($line =~ /^\s*bisher\s+\d+\s+(Episoden|Folgen)/i || $line =~ /^\s*(\d+)\. Staffel/i || $line =~ /^\s*Staffel (\d+)/i) {
   		$start = 1;
   	 }

   	 next if ($start == 0);
   	
   	 if ($line =~ /^\s*(\d+)\. Staffel/i || $line =~ /^\s*Staffel (\d+)$/i) {
		$aktseason = $1;
		$aktepisode = 0;
   		next;
   	 }
   	 next if (!$aktseason);

     #20[20]Die älteste GeschichteAll That Glitters29.04.2011
	 #2[2]Schüsse vom Samariter14.08.2012Samaritan01.10.2010

  	 if (($line =~ /^(\d+)\[\d+\](.*?)\d{2}\.\d{2}\.\d{4}.*?\d{2}\.\d{2}\.\d{4}$/) ||
  	    ($line =~ /^(\d+)\[\d+\](.*?)\d{2}\.\d{2}\.\d{4}$/)) {
	 	 
	   $aktepisode = $1;
	   my $episodename = $2;
   	   $aktseason = 1 if ($aktseason == 0);
	   
   	   $r{$episodename}{E} = $aktepisode;
   	   $r{$episodename}{S} = $aktseason;
   	   next;
   	 }
#6
#[98]
#Entwischt
#01.02.2006

   	 if ($line =~ /^(\d+)$/ && $lines[$i+1] =~ /^\[\d+\]$/ && $lines[$i+3] =~ /^\d{2}\.\d{2}\.\d{4}$/) {
	   $aktepisode = $line;
   	   $aktseason = 1 if ($aktseason == 0);
	   
	   my $episodename = $lines[$i+2];
   	   $r{$episodename}{E} = $aktepisode;
   	   $r{$episodename}{S} = $aktseason;
	   $i += 3;
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

		return lc($regtest);
}

sub searchname {
   shift; # this is $self
   my $r = shift;
   
   # they use buggy encoding like in html_entitiy we need to strip every &
   $r =~ s/&//g;
   
   return $r;
}

sub fs_html_entitiy {
   shift; # this is $self
   my $r = shift;
   
   # they use buggy encoding (just encode & to &amp;) that's why we need our own entity method
   $r =~ s/&/&amp;/g;
   
   return $r;
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
	my $r = $resp->content();
	
return $r;
}

1;