package SVN::StatusEditor;
use strict;
require SVN::Delta;
our $VERSION = '0.05';
our @ISA = qw(SVN::Delta::Editor);

sub set_target_revision {
    my ($self, $revision) = @_;
}

sub open_root {
    my ($self, $baserev) = @_;
    $self->{info}{$self->{copath}}{status} = ['', ''];
    return $self->{copath};
}

sub add_file {
    my ($self, $path, $pdir, @arg) = @_;
    my $opath = $path;
    $path = "$self->{copath}/$opath";
    $self->{info}{$path}{dpath} = "$self->{dpath}/$opath";
    $self->{info}{$path}{status} = [$self->{conflict}{$opath} || 'A', ''];
    return $path;
}

sub open_file {
    my ($self, $path, $pdir, $rev, $pool) = @_;
    my $opath = $path;
    $path = "$self->{copath}/$opath";
    $self->{info}{$path}{dpath} = "$self->{dpath}/$opath";
    $self->{info}{$path}{status} = [$self->{conflict}{$opath} || '', ''];
    return $path;
}

sub apply_textdelta {
    my ($self, $path) = @_;
    $self->{info}{$path}{status}[0] ||= 'M';
    return undef;
}

sub change_file_prop {
    my ($self, $path, $name, $value) = @_;
    $self->{info}{$path}{status}[1] = 'M'
	unless $self->{info}{$path}{status}[0] eq 'A';
}

sub close_file {
    my ($self, $path) = @_;
    my $rpath = $path;
    $rpath =~ s|^$self->{copath}/|$self->{rpath}|;
    print sprintf ("%1s%1s \%s\n", $self->{info}{$path}{status}[0],
		   $self->{info}{$path}{status}[1],
		   $rpath);
}

sub absent_file {
    my ($self, $path) = @_;
    print "!  $self->{rpath}$path\n";
}

sub delete_entry {
    my ($self, $path) = @_;
    print "D  $self->{rpath}$path\n";
}

sub add_directory {
    my ($self, $path, $pdir, @arg) = @_;
    my $opath = $path;
    $path = "$self->{copath}/$opath";
    $self->{info}{$path}{dpath} = "$self->{dpath}/$opath";
    $self->{info}{$path}{status} = ['A', ''];
    return $path;
}

sub open_directory {
    my ($self, $path, $pdir, $rev, $pool) = @_;
    my $opath = $path;
    $path = "$self->{copath}/$opath";
    $self->{info}{$path}{dpath} = "$self->{dpath}/$opath";
    $self->{info}{$path}{status} = ['', ''];
    return $path;
}

sub change_dir_prop {
    my ($self, $path, $name, $value) = @_;
    $self->{info}{$path}{status}[1] = 'M';
}

sub close_directory {
    my ($self, $path) = @_;
    my $rpath = $path;
    $rpath =~ s|^$self->{copath}/|$self->{rpath}|;
    if ($rpath eq $self->{copath}) {
	$rpath = $self->{rpath};
	chop $rpath;
    }
    print sprintf ("%1s%1s \%s\n", $self->{info}{$path}{status}[0] || '',
		   $self->{info}{$path}{status}[1] || '',
		   $rpath)
	if $self->{info}{$path}{status}[0] || $self->{info}{$path}{status}[1];
}

sub absent_directory {
    my ($self, $path) = @_;
    print "!  $self->{rpath}$path\n";
}

sub conflict {
    my ($self, $path) = @_;
    $self->{conflict}{$path} = 'C';
}

1;
