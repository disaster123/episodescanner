package Backend::EpisodeSubst;

use Log;
use Exporter;
use Data::Dumper;

@ISA = qw(Exporter);

@EXPORT = qw( EpiseodeSubst );


sub EpiseodeSubst {
   my $str = shift;
   my %subst = @_;
   
   my $nstr = $str;
   foreach my $k (keys %subst) {
      $nstr =~ s#$k#$subst{$k}#ig;
   }
 
   Log::log("\tEpisodeSubst \"$str\" converted to \"$nstr\"", 0) if (defined $ENV{DEBUG} && $ENV{DEBUG} == 1);
 
 return $nstr;
}
