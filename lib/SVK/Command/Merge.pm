package SVK::Command::Merge;
use strict;
our $VERSION = '0.14';

use base qw( SVK::Command::Commit );
use SVK::XD;
use SVK::I18N;
use SVK::DelayEditor;
use SVK::Command::Log;
use SVK::Util qw (get_buffer_from_editor find_svm_source svn_mirror);

sub options {
    ($_[0]->SUPER::options,
     'a|auto'		=> 'auto',
     'l|log'		=> 'log',
     'no-ticket'	=> 'no_ticket',
     'r|revision=s'	=> 'revspec');
}

sub parse_arg {
    my ($self, @arg) = @_;
    $self->usage if $#arg < 0 || $#arg > 1;
    return ($self->arg_depotpath ($arg[0]), $self->arg_co_maybe ($arg[1] || ''));
}

sub lock {
    my $self = shift;
    $_[1]->{copath} ? $self->lock_target ($_[1]) : $self->lock_none;
}

sub run {
    my ($self, $src, $dst) = @_;
    my ($fromrev, $torev, $baserev, $cb_merged, $cb_closed);

    die loc("repos paths mismatch") unless $src->{repospath} eq $dst->{repospath};
    my $repos = $src->{repos};
    unless ($self->{auto}) {
	die loc("revision required") unless $self->{revspec};
	($baserev, $torev) = $self->{revspec} =~ m/^(\d+):(\d+)$/
	    or die loc("revision must be N:M");
    }

    my $base_path = $src->{path};
    if ($self->{auto}) {
	($base_path, $baserev, $fromrev, $torev) =
	    ($self->find_merge_base ($repos, $src->{path}, $dst->{path}), $repos->fs->youngest_rev);
	print loc("Auto-merging (%1, %2) %3 to %4 (base %5).\n", $fromrev, $torev, $src->{path}, $dst->{path}, $base_path);
	$cb_merged = sub { my ($editor, $baton, $pool) = @_;
			   $editor->change_dir_prop
			       ($baton, 'svk:merge',
				$self->get_new_ticket ($repos, $src->{path}, $dst->{path}));
		       } unless $self->{no_ticket};
    }

    unless ($dst->{copath} || defined $self->{message} || $self->{check_only}) {
	$self->{message} = get_buffer_from_editor
	    ('log message', $self->target_prompt,
	     ($self->{log} ?
	      $self->log_for_merge ($repos, $src->{path}, $fromrev+1, $torev) : '').
	     "\n".$self->target_prompt."\n", "svk-commitXXXXX");
    }

    # editor for the target
    my ($storage, %cb) = $self->get_editor ($dst);

    my $fs = $repos->fs;
    $storage = SVK::DelayEditor->new ($storage);
    my $editor = SVK::MergeEditor->new
	( anchor => $src->{path},
	  base_anchor => $base_path,
	  base_root => $fs->revision_root ($baserev),
	  target => '',
	  send_fulltext => $cb{mirror} ? 0 : 1,
	  cb_merged => $cb_merged,
	  storage => $storage,
	  %cb,
	);
    SVN::Repos::dir_delta ($fs->revision_root ($baserev),
			   $base_path, '',
			   $fs->revision_root ($torev), $src->{path},
			   $editor, undef,
			   1, 1, 0, 1);


    print loc("%*(%1,conflict) found.\n", $editor->{conflicts}) if $editor->{conflicts};

    return;
}

sub log_for_merge {
    my $self = shift;
    open my $buf, '>', \(my $tmp);
    SVK::Command::Log::do_log (@_, 0, 0, 0, 1, $buf);
    $tmp =~ s/^/ /mg;
    return $tmp;
}


sub find_merge_base {
    my ($self, $repos, $src, $dst) = @_;
    my $srcinfo = $self->find_merge_sources ($repos, $src);
    my $dstinfo = $self->find_merge_sources ($repos, $dst);
    my ($basepath, $baserev);

    for (
	grep {exists $srcinfo->{$_} && exists $dstinfo->{$_}}
	(sort keys %{ { %$srcinfo, %$dstinfo } })
    ) {
	my ($path) = m/:(.*)$/;
	my $rev = $srcinfo->{$_} < $dstinfo->{$_} ? $srcinfo->{$_} : $dstinfo->{$_};
	# XXX: shuold compare revprop svn:date instead, for old dead branch being newly synced back
	if (!$basepath || $rev > $baserev) {
	    ($basepath, $baserev) = ($path, $rev);
	}
    }

    if (!$basepath) {
	die loc("Can't find merge base for %1 and %2\n", $src, $dst)
	  unless $self->{baseless} or $self->{base};

	my $fs = $repos->fs;
	my ($from_rev, $to_rev) = ($self->{base}, $fs->youngest_rev);

	if (!$from_rev) {
	    # baseless merge
	    my $pool = SVN::Pool->new_default;
	    my $hist = $fs->revision_root($to_rev)->node_history($src);
	    do {
		$pool->clear;
		$from_rev = ($hist->location)[1];
	    } while $hist = $hist->prev(0);
	}

	return ($src, $from_rev, $to_rev);
    };

    return ($basepath, $baserev, $dstinfo->{$repos->fs->get_uuid.':'.$src} || $baserev);
}

sub find_merge_sources {
    my ($self, $repos, $path, $verbatim, $noself) = @_;
    my $pool = SVN::Pool->new_default;

    my $fs = $repos->fs;
    my $root = $fs->revision_root ($fs->youngest_rev);
    my $minfo = $root->node_prop ($path, 'svk:merge');
    my $myuuid = $fs->get_uuid ();
    if ($minfo) {
	$minfo = { map {my ($uuid, $path, $rev) = split ':', $_;
			my $m;
			($verbatim || ($uuid eq $myuuid)) ? ("$uuid:$path" => $rev) :
			    (svn_mirror && ($m = SVN::Mirror::has_local ($repos, "$uuid:$path"))) ?
				("$myuuid:$m->{target_path}" => $m->find_local_rev ($rev)) : ()
			    } split ("\n", $minfo) };
    }
    if ($verbatim) {
	my ($uuid, $path, $rev) = find_svm_source ($repos, $path);
	$minfo->{join(':', $uuid, $path)} = $rev
	    unless $noself;
	return $minfo;
    }
    else {
	$minfo->{join(':', $myuuid, $path)} = $fs->youngest_rev
	    unless $noself;
    }

    my %ancestors = $self->copy_ancestors ($repos, $path, $fs->youngest_rev, 1);
    for (sort keys %ancestors) {
	my $rev = $ancestors{$_};
	$minfo->{$_} = $rev
	    unless $minfo->{$_} && $minfo->{$_} > $rev;
    }

    return $minfo;
}

sub copy_ancestors {
    my ($self, $repos, $path, $rev, $nokeep) = @_;
    my $fs = $repos->fs;
    my $root = $fs->revision_root ($rev);
    $rev = $root->node_created_rev ($path);

    my $spool = SVN::Pool->new_default_sub;
    my ($found, $hitrev, $source) = (0, 0, '');
    my $myuuid = $fs->get_uuid ();
    my $hist = $root->node_history ($path);
    my ($hpath, $hrev);

    while ($hist = $hist->prev (1)) {
	$spool->clear;
	($hpath, $hrev) = $hist->location ();
	if ($hpath ne $path) {
	    $found = 1;
	}
	elsif (defined ($source = $fs->revision_prop ($hrev, "svk:copied_from:$path"))) {
	    $hitrev = $hrev;
	    last unless $source;
	    my $uuid;
	    ($uuid, $hpath, $hrev) = split ':', $source;
	    if ($uuid ne $myuuid) {
		my ($m, $mpath);
		if (svn_mirror &&
		    (($m, $mpath) = SVN::Mirror::has_local ($repos, "$uuid:$path"))) {
		    ($hpath, $hrev) = ($m->{target_path}, $m->find_local_rev ($hrev));
		    # XXX: WTF? need test suite for this
		    $hpath =~ s/\Q$mpath\E$//;
		}
		else {
		    return ();
		}
	    }
	    $found = 1;
	}
	last if $found;
    }

    $source = '' unless $found;
    if (!$found || $hitrev != $hrev) {
	$fs->change_rev_prop ($hitrev, "svk:copied_from:$path", undef)
	    unless $hitrev || $fs->revision_prop ($hitrev, "svk:copied_from_keep:$path");
	$source ||= join (':', $myuuid, $hpath, $hrev) if $found;
	if ($hitrev != $rev) {
	    $fs->change_rev_prop ($rev, "svk:copied_from:$path", $source);
	    $fs->change_rev_prop ($rev, "svk:copied_from_keep:$path", 'yes')
		unless $nokeep;
	}
    }
    return () unless $found;
    return ("$myuuid:$hpath" => $hrev, $self->copy_ancestors ($repos, $hpath, $hrev));
}

sub get_new_ticket {
    my ($self, $repos, $src, $dst) = @_;

    my $srcinfo = $self->find_merge_sources ($repos, $src, 1);
    my $dstinfo = $self->find_merge_sources ($repos, $dst, 1);
    my ($uuid, $newinfo);

    # bring merge history up to date as from source
    ($uuid, $dst) = find_svm_source ($repos, $dst);

    for (sort keys %{ { %$srcinfo, %$dstinfo } }) {
	next if $_ eq "$uuid:$dst";
	no warnings 'uninitialized';
	$newinfo->{$_} = $srcinfo->{$_} > $dstinfo->{$_} ? $srcinfo->{$_} : $dstinfo->{$_};
	print loc("New merge ticket: %1:%2\n", $_, $newinfo->{$_})
	    if !$dstinfo->{$_} || $newinfo->{$_} > $dstinfo->{$_};
    }

    return join ("\n", map {"$_:$newinfo->{$_}"} sort keys %$newinfo);
}

1;

__DATA__

=head1 NAME

SVK::Command::Merge - Apply differences between two sources

=head1 SYNOPSIS

    merge -r N:M DEPOTPATH [PATH]
    merge -r N:M DEPOTPATH1 DEPOTPATH2

=head1 OPTIONS

    -r [--revision] rev:    revision
    -m [--message] message: commit message
    -C [--check-only]:      don't perform actual writes
    -a [--auto]:            automatically find merge points
    -l [--log]:             brings the logs of merged revs to the message buffer
    --no-ticket:            don't associate the ticket tracking merge history
    --force:		    Needs description
    -s [--sign]:	    Needs description

=head1 AUTHORS

Chia-liang Kao E<lt>clkao@clkao.orgE<gt>

=head1 COPYRIGHT

Copyright 2003-2004 by Chia-liang Kao E<lt>clkao@clkao.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
