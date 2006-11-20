package SVK::Logger;
use strict;
use warnings;

use SVK::Version;  our $VERSION = $SVK::VERSION;

if (eval {
        require Log::Log4perl;
        Log::Log4perl->import(':levels');
        1;
    } ) {
    my $level = { map { $_ => uc $_ } qw( debug info warn error fatal ) }
        ->{ lc $ENV{SVKLOGLEVEL} } || 'INFO';

    my $conf = qq{
  log4perl.rootLogger=$level, Screen
  log4perl.appender.Screen = Log::Log4perl::Appender::Screen
  log4perl.appender.Screen.stderr = 0
  log4perl.appender.Screen.layout = PatternLayout
  log4perl.appender.Screen.layout.ConversionPattern = %m%n
  };

    # ... passed as a reference to init()
    Log::Log4perl::init( \$conf );
    *get_logger = sub { Log::Log4perl->get_logger(@_) };

}
else {
    *get_logger = sub { 'SVK::Logger::Compat' };
}

sub import {
  my $class = shift;
  my $var = shift || 'logger';
  
  # it's ok if people add a sigil; we can get rid of that.
  $var =~ s/^\$*//;
  
  # Find out which package we'll export into.
  my $caller = caller() . '';

  (my $name = $caller) =~ s/::/./g;
  my $logger = get_logger(lc($name));
  {
    # As long as we don't use a package variable, each module we export
    # into will get their own object. Also, this allows us to decide on 
    # the exported variable name. Hope it isn't too bad form...
    no strict 'refs';
    *{ $caller . "::$var" } = \$logger;
  }
}

package SVK::Logger::Compat;
require Carp;

my $current_level;
my $level;

BEGIN {
my $i;
$level = { map { $_ => ++$i } reverse qw( debug info warn error fatal ) };
$current_level = $level->{lc $ENV{SVKLOGLEVEL}} || $level->{info};

my $ignore  = sub { return };
my $warn = sub {
    $_[1] .= "\n" unless substr( $_[1], -1, 1 ) eq "\n";
    print $_[1];
};
my $die     = sub { shift; die $_[0]."\n"; };
my $carp    = sub { shift; goto \&Carp::carp };
my $confess = sub { shift; goto \&Carp::confess };
my $croak   = sub { shift; goto \&Carp::croak };

*debug      = $current_level >= $level->{debug} ? $warn : $ignore;
*info       = $current_level >= $level->{info}  ? $warn : $ignore;
*warn       = $current_level >= $level->{warn}  ? $warn : $ignore;
*error      = $current_level >= $level->{warn}  ? $warn : $ignore;
*fatal      = $die;
*logconfess = $confess;
*logdie     = $die;
*logcarp    = $carp;
*logcroak   = $croak;

}

sub is_debug { $current_level >= $level->{debug} }

1;

__END__

=head1 NAME

SVK::Logger - logging framework for SVK

=head1 SYNOPSIS

  use SVK::Logger;
  
  $logger->warn('foo');
  $logger->info('bar');
  
or 

  use SVK::Logger '$foo';
  
  $foo->error('bad thingimajig');

=head2 DESCRIPTION

SVK::Logger is a wrapper around Log::Log4perl. When using the module, it
imports into your namespace a variable called $logger (or you can pass a
variable name to import to decide what the variable should be) with a
category based on the name of the calling module.

=head1 MOTIVATION

Ideally, for support requests, if something is not going the way it
should be we should be able to tell people: "rerun the command with the
SVKLOGLEVEL environment variable set to DEBUG and mail the output to
$SUPPORTADDRESS". On Unix, this could be accomplished in one command like so:

  env SVKLOGLEVEL=DEBUG svk <command that failed> 2>&1 | mail $SUPPORTADDRESS

=head1 AUTHORS

Stig Brautaset E<lt>stig@brautaset.orgE<gt>

Chia-liang Kao E<lt>clkao@clkao.orgE<gt>

=head1 COPYRIGHT

Copyright 2003-2006 by Chia-liang Kao E<lt>clkao@clkao.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>


=cut
