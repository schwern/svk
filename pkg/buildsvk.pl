#!perl

use strict;
use warnings;
use Cwd 'abs_path';
use File::Copy 'move';

use File::Spec;

=head1 NAME

buildsvk.pl - packaging svk

=head1 SYNOPSIS



=head1 DESCRIPTION

Put the dist files under src and C<buildsvk.pl> will create a build
directory with everything installed under it.

=cut

my $build = SVK::Build->new;
my $t = time();

$build->prepare_perl();
$build->prepare_svn_core();

$build->build_module('libwin32', 'Console') if $^O eq 'MSWin32';

$build->build_module($_) for qw(Scalar-List-Utils Class-Autouse version Sub-Uplevel Test-Simple Test-Exception Data-Hierarchy PerlIO-via-dynamic PerlIO-via-symlink SVN-Simple PerlIO-eol Algorithm-Diff Algorithm-Annotate Pod-Escapes Pod-Simple IO-Digest TimeDate Getopt-Long Encode PathTools YAML-Syck Locale-Maketext-Simple App-CLI List-MoreUtils Path-Class Class-Data-Inheritable Class-Accessor UNIVERSAL-require File-Temp Log-Log4perl);
$build->build_module($_) for qw(Locale-Maketext-Lexicon TermReadKey IO-Pager);
$build->build_module($_) for qw(File-chdir SVN-Mirror);
$build->build_module($_) for qw(FreezeThaw);

my $svkroot = shift;
if ($svkroot) {
    $build->perlmake_install($svkroot);
}
else {
    $build->build_module('SVK');
    $svkroot = glob($build->build_dir.'/SVK-*');
}

$build->prepare_dist($svkroot);

warn 'build finished - '.(time() - $t);

exit 0;

package SVK::Build;
use Archive::Extract;
use Env::Path;
use File::Path (qw(mkpath rmtree));
use File::chdir;
use File::Copy 'copy';

sub prepare_perl { 1 };
sub prepare_svn_core {
    my $self = shift;
    my $output = `ldd \`which svn\``;
    for ($output =~ m/^.*$/mg) {
	my ($lib, $file) = m/(\S.*?) => (\S.*?)\s/ or next;
	if ($lib =~ m/libsvn_*/) {
	warn "$lib $file";
	    copy($file, $self->build_dir);
	}
    }
}

sub build_dir {
    '/tmp/svk-build/dest';
}

sub build_base {
    '/tmp/svk-build';
}

sub prepare_build_dir {
    my $self = shift;
    mkpath [$self->build_dir];
}

sub new {
    my $class = shift;
    if ($^O eq 'MSWin32') {
	$class .= '::Win32';
    }

    my $self = bless {}, $class;
    $self->prepare_build_dir;
    return $self;
}


sub extract {
    my $self = shift;
    my $ae = Archive::Extract->new( archive => shift );

    $ae->extract( to => $self->build_base )
	or die $ae->error;
}

sub perl { [ $^X, '-I'.$_[0]->perldest ] }
sub make { 'make' }

sub build_module {
    my $self = shift;
    my $module = shift;
    my $subdir = shift;
    # XXX: try to match version number only for the glob here
    my ($dir) = glob($self->build_dir."/$module-*");
    rmtree [$dir] if $dir;

    my ($file) = glob("src/$module-*");
    $self->extract($file);

    ($dir) = glob($self->build_base."/$module-*");
    $dir .= "/$subdir" if $subdir;

    $self->perlmake_install( $subdir ? "$dir/$subdir" : $dir );
}

sub perlmake_install {
    my ($self, $dir) = @_;
    my $PERLDEST = $self->perldest;
    my $PERLDESTARCH = $PERLDEST;

    local $CWD = $dir;
    warn "$CWD\n";
    system @{$self->perl}, qw(Makefile.PL INSTALLDIRS=perl),
	    "INSTALLARCHLIB=$PERLDESTARCH",
	    "INSTALLPRIVLIB=$PERLDEST",
	    "INSTALLBIN=$PERLDEST/../bin",
      	    "INSTALLSCRIPT=$PERLDEST/../bin",
	    "INSTALLMAN1DIR=$PERLDEST/../man/man1",
	    "INSTALLMAN3DIR=$PERLDEST/../man/man3";

    $ENV{PERL_EXTUTILS_AUTOINSTALL} = '--skipdeps';
    system $self->make, qw( all install ) ;
}

sub perldest {
    my $self = shift;
    $self->build_dir.'/perl';
}

sub prepare_dist {
    my $self = shift;
    my $toplevel = shift;
    copy('svk-wrapper' => $self->build_dir."/svk");
    chmod 0755, $self->build_dir."/svk";

    open my $fh, "$toplevel/MANIFEST" or die $!;
    while (<$fh>) {
	chomp;
	next unless m{^t/};
	my $file = $_;
	my (undef, $dir, undef) = File::Spec->splitpath($file);
	mkpath [ $self->build_dir."/$dir" ];
	copy($toplevel.'/'.$file => $self->build_dir."/$file");
    }
    
    copy('maketest' => $self->build_dir."/maketest");
    chmod 0755, $self->build_dir."/maketest";

    my $version = eval {
	local @INC = @INC; unshift @INC, "$toplevel/lib"; require SVK::Version;
	SVK->VERSION;
    };

    rename($self->build_dir => $self->build_base.'/svk-'.$version);
}

package SVK::Build::Win32;
use base 'SVK::Build';
use Cwd 'abs_path';
use File::Spec;

sub build_dir {
    'c:/tmp/svk-build';
}

sub build_base {
    'c:/tmp/svk-build';
}

sub perl {
    my $self = shift;
    [abs_path(File::Spec->catfile($self->build_dir,
				  qw(strawberry-perl perl bin perl.exe))) ];
}

sub make { 'dmake' }

sub perldest {
    abs_path(File::Spec->catfile($_[0]->build_dir, qw(strawberry-perl perl lib)));
}

sub prepare_perl {
    my $self = shift;
    Env::Path->PATH->Assign( map { abs_path(File::Spec->catfile($self->build_dir, 'strawberry-perl', $_, 'bin')) } qw(perl dmake mingw));

    if (-d $self->perldest) {
	warn "found strawberry perl, remove ".$self->perldest." for clean build.\n";
	return 1;
    }
    $self->extract('strawberry-perl.zip');
}

sub prepare_svn_core {
    my $self = shift;
    return 1 if -e File::Spec->catfile($self->build_dir, 'strawberry-perl', 'perl', 'lib', 'SVN' );

    $self->extract('svn-win32-1.4.4.zip');
    $self->extract('svn-win32-1.4.4_pl.zip');

    my $svnperl = File::Spec->catfile($self->build_dir, 'svn-win32-1.4.4', 'perl', 'site', 'lib' );

    my $strperl = File::Spec->catfile($self->build_dir, 'strawberry-perl', 'perl', 'lib' );

    rename(File::Spec->catfile($svnperl, "SVN") =>
	   File::Spec->catfile($strperl, "SVN")) or die $!;

    rename(File::Spec->catfile($svnperl, "auto", "SVN") =>
	   File::Spec->catfile($strperl, "auto", "SVN")) or die $!;

    move($_ => File::Spec->catfile($self->build_dir, 'strawberry-perl', 'perl', 'bin'))
	for glob($self->build_dir."/svn-win32-1.4.4/bin/*.dll");
}

sub prepare_dist {
}
