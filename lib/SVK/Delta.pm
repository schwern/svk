# BEGIN BPS TAGGED BLOCK {{{
# COPYRIGHT:
# 
# This software is Copyright (c) 2003-2006 Best Practical Solutions, LLC
#                                          <clkao@bestpractical.com>
# 
# (Except where explicitly superseded by other copyright notices)
# 
# 
# LICENSE:
# 
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of either:
# 
#   a) Version 2 of the GNU General Public License.  You should have
#      received a copy of the GNU General Public License along with this
#      program.  If not, write to the Free Software Foundation, Inc., 51
#      Franklin Street, Fifth Floor, Boston, MA 02110-1301 or visit
#      their web page on the internet at
#      http://www.gnu.org/copyleft/gpl.html.
# 
#   b) Version 1 of Perl's "Artistic License".  You should have received
#      a copy of the Artistic License with this package, in the file
#      named "ARTISTIC".  The license is also available at
#      http://opensource.org/licenses/artistic-license.php.
# 
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# CONTRIBUTION SUBMISSION POLICY:
# 
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of the
# GNU General Public License and is only of importance to you if you
# choose to contribute your changes and enhancements to the community
# by submitting them to Best Practical Solutions, LLC.)
# 
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with SVK,
# to Best Practical Solutions, LLC, you confirm that you are the
# copyright holder for those contributions and you grant Best Practical
# Solutions, LLC a nonexclusive, worldwide, irrevocable, royalty-free,
# perpetual, license to use, copy, create derivative works based on
# those contributions, and sublicense and distribute those contributions
# and any derivatives thereof.
# 
# END BPS TAGGED BLOCK }}}
package SVK::Delta;
use strict;
use warnings;

use SVK::I18N;
use SVK::Util qw(HAS_SYMLINK is_symlink get_encoder from_native to_native
                 md5_fh splitpath splitdir catdir abs2rel);
use autouse 'File::Find' => qw(find);
use SVK::Logger;

use base 'SVK::DeltaOld';

__PACKAGE__->mk_accessors(qw(cb_conflict cb_ignored cb_unchanged cb_resolve_rev cb_unknown
                             _compat_xdroot cb_unknown_node_type
                        ));

*_node_type = *SVK::DeltaOld::_node_type;

=head1 NAME

SVK::Delta - 

=head1 SYNOPSIS



=head1 DESCRIPTION

Options:

=over

=item delete_verbose

Generate delete_entry calls for sub-entries within deleted entry.

=item absent_verbose

Generate absent_* calls for sub-entries within absent entry.

=item unknown_verbose

generate cb_unknown calls for sub-entries within absent entry.

=item absent_ignore

Don't generate absent_* calls.

=item expand_copy

Mimic the behavior like SVN::Repos::dir_delta, lose copy information
and treat all copied descendents as added too.

=item cb_ignored

Called for ignored items if defined.

=item cb_unchanged

Called for unchanged files if defined.

=back


=cut

sub run {
    my ($self, $t1, $t2) = @_;
}
sub checkout_delta2 {
    my ($self, $target, $editor, $opt) = @_;

    # objective: move behaviour-related info into $self, and pass around context only
    my $source = $target->source;
    my $xdroot = $target->create_xd_root; # XXX: shouldn't exist anymore
    my $base_root = $opt->{base_root} || $xdroot;
    my $base_kind = $base_root->check_path($source->path_anchor);

    $self->_compat_xdroot($xdroot);

    die "checkout_delta called with non-dir node"
	unless $base_kind == $SVN::Node::dir;

    my %arg = (
		base_root_is_xd => $opt->{base_root} ? 0 : 1,
		encoder => get_encoder,
		kind => $base_kind,
		base_kind => $base_kind,
		cb_resolve_rev => sub { $_[1] },
	        %$opt,
	   );

    $self->cb_conflict(delete $arg{cb_conflict});
    $self->cb_unchanged(delete $arg{cb_unchanged});
    $self->cb_ignored(delete $arg{cb_ignored});
    $self->cb_unknown(delete $arg{cb_unknown});
    $self->cb_unknown_node_type(delete $arg{cb_unknown_node_type});
    $self->cb_resolve_rev($arg{cb_resolve_rev});

    $arg{cb_copyfrom} ||= $arg{expand_copy} ? sub { (undef, -1) }
	: sub { my $path = $_[0]; $path =~ s/%/%25/g; ("file://".$source->repospath.$path, $_[1]) };

    $editor = SVK::Editor::Delay->new($editor)
	   unless $arg{nodelay};

    # XXX: translate $repospath to use '/'
    my ($cinfo) = $self->_compose_cinfo($target);
    my $rev = $self->cb_resolve_rev->($source->path_anchor, $cinfo->{revision});
    local $SIG{INT} = sub {
	$editor->abort_edit;
	die loc("Interrupted.\n");
    };

    my $baton = $editor->open_root($rev);
    $self->_delta_dir2(
        $base_root,
        $opt->{base_path} || $target->path_anchor,
        $target, $editor,
        {   targets => $source->{targets},
            %arg,
            baton => $baton,
            root  => 1,
            base  => 1,
            type  => 'directory',
            cinfo => $cinfo,
        }
    );
    $editor->close_directory($baton);
    $editor->close_edit();
}

sub _compose_cinfo {
    my ($self, $target) = @_;
    $self->xd->get_entry($target->copath, 1);
}


sub _compat_args {
    my ($self, $base_root, $base_path, $target, $editor, $ctx) = @_;

    my $source = $target->source;

    return (
        base_root => $base_root,

        copath    => $target->copath,
        path      => $source->path_anchor,
        base_path => $base_path,

        repos     => $source->repos,
        repospath => $source->repospath,
        report    => $target->report,

        cb_conflict => $self->cb_conflict,
        cb_unchanged => $self->cb_unchanged,
        cb_ignored => $self->cb_ignored,
        cb_unknown => $self->cb_unknown,

        # compat for now
        editor => $editor,
        xdroot => $self->_compat_xdroot,
    );

}

sub _delta_file2 {
    my ($self, $base_root, $base_path, $target, $editor, $ctx) = @_;

    my $source = $target->source;
    my %arg    = (
        %$ctx
    );
    my %compatarg = _compat_args(@_);

    $self->SUPER::_delta_file(%arg, %compatarg);
}

sub _delta_entry {
    my ($self, $base_root, $base_path, $target, $editor, $opt, $ctx) = @_;
    my $targets = $opt->{targets};
    my $entries = $opt->{entries};
    my $entry = $opt->{entry};
    my $baton = $opt->{baton};
    my $signature = $opt->{signature};
    my $ignore = $opt->{ignore};
    my %arg = %$ctx;

    my $entry_path = $base_path eq '/' ? "/$entry" : "$base_path/$entry";
    return if defined $targets && !exists $targets->{$entry};

    my $entry_target = $target->clone->descend($entry);
    my ($ccinfo, $sche) = $self->_compose_cinfo($entry_target);

    my %newpaths = ( entry => defined $arg{entry} ? "$arg{entry}/$entry" : $entry,
                     targets => defined $targets ? delete $targets->{$entry} : undef,
                     depth => defined $arg{depth} ? defined $targets ?
                                                    $arg{depth} : $arg{depth} - 1
                                                  : undef,
                     baton => $baton,
                     cinfo => $ccinfo,
                     root => 0, base => 0,
                 );

    $newpaths{base_kind} = $opt->{existing} ? $entries->{$entry}->kind : $SVN::Node::none;

    if ($sche eq 'replace' && $ccinfo->{'.copyfrom'}) {
        $newpaths{base_kind} = $SVN::Node::none;
    }

    $newpaths{kind} = $arg{base_root_is_xd} ? $newpaths{base_kind} :
        $self->_compat_xdroot->check_path($entry_target->path_anchor);
    $newpaths{add} = !$newpaths{base_kind} || $arg{in_copy};

    if (my $unchanged = ($newpaths{base_kind} == $SVN::Node::file &&
                         $signature && !$signature->changed($entry))) {
        # XXX: need to see prop-changed-ness to know if we can call cb_unchanged.
	if (!$ccinfo->{'.conflict'}) {
	    $self->cb_unchanged->($editor, $newpaths{entry}, $baton,
				 $self->_delta_rev2($target, $ccinfo)
				) if $self->cb_unchanged;
	    return;
	}
    }
    if (!$newpaths{base_kind}) {
	my $add = $sche || $arg{auto_add} || $newpaths{kind};
	# If we are not at intermediate path, process ignore
	# for unknowns, as well as the case of auto_add (import)
	if (!defined $targets) {
	    if ((!$add || $arg{auto_add}) && $entry =~ m/$ignore/) { 
		$self->cb_ignored->($editor, $newpaths{entry}, $arg{baton})
		    if $self->cb_ignored;
		return;
	    }
	}
	if ($ccinfo->{'.conflict'}) {
	    $self->cb_conflict->($editor, $newpaths{entry}, $arg{baton}, $ccinfo->{'.conflict'})
		if $self->cb_conflict;
	}
	unless ($add || $ccinfo->{'.conflict'}) {
	    if ($self->cb_unknown) {
		$self->cb_unknown->($editor, $newpaths{entry}, $arg{baton});
		$self->_unknown_verbose(%arg, %newpaths, %{$opt->{compatarg}},
					copath => $entry_target->copath,
					path => $target->path_anchor,
					base_path => $base_path eq '/' ? "/$entry" : "$base_path/$entry")
		    if $arg{unknown_verbose};
	    }
	    return;
	}
    }

    my ($type, $st) = _node_type($entry_target->copath) or return;
    # XXX: get this from new_entry hash directly once it's passed in
    my $pkind = $entry_target->root->check_path($entry_target->path_anchor);
    $pkind = $newpaths{base_kind} if $newpaths{base_kind} && (!$pkind || $pkind == $SVN::Node::unknown);

    if ($pkind == $SVN::Node::unknown && $self->cb_unknown_node_type) {
        $pkind = $self->cb_unknown_node_type->($editor, $newpaths{entry}, $arg{baton});
        return if $pkind == $SVN::Node::unknown;
    }

    my $delta = $pkind == $SVN::Node::dir  ? '_delta_dir2'
              :                              '_delta_file2';

    my $obs = $type ? ($newpaths{base_kind} == $SVN::Node::dir xor $pkind == $SVN::Node::dir) : 0;
    $newpaths{add} ||= ($obs && $arg{obstruct_as_replace});
    $newpaths{base} = $newpaths{base_kind} && !$obs;
    my $copyfrom = $ccinfo->{'.copyfrom'};
    my ($fromroot) = $copyfrom ? $base_root->get_revision_root($target->path_anchor, $ccinfo->{'.copyfrom_rev'}) : undef;
    # XXX: figure out why it needs to be in xdroot to work (see mirror/sync-crazy-replace.t)
    if ($copyfrom) {
        ($base_root, $entry_path) = ($fromroot, $copyfrom);
        $newpaths{base_root_is_xd} = 0;
        $newpaths{base_kind} = $fromroot->check_path ($copyfrom);
        $newpaths{in_copy} =  $arg{expand_copy};
        $newpaths{base} = 1;
        $newpaths{_really_in_copy} = 1;
    }

    $self->$delta($base_root, $entry_path, $entry_target, $editor,
                  { %arg, %newpaths,
                    type => $type,
                    st => $st,
                });
}

sub _delta_dir2 {
    my ($self, $base_root, $base_path, $target, $editor, $ctx) = @_;

    my $source = $target->source;
    my %arg    = (
        %$ctx
    );

    my %compatarg = _compat_args(@_);

    if ($arg{entry} && $arg{exclude} && exists $arg{exclude}{$arg{entry}}) {
	$arg{cb_exclude}->($target->path_anchor, $target->copath) if $arg{cb_exclude};
	return;
    }
    my $pool = SVN::Pool->new_default (undef);
    my $cinfo = $arg{cinfo};
    my $schedule = $cinfo->{'.schedule'} || '';
    $arg{add} = 1 if $arg{auto_add} && $arg{base_kind} == $SVN::Node::none ||
	$schedule eq 'replace';

    # compute targets for children
    my $targets;
    for (@{$arg{targets} || []}) {
	my ($volume, $directories, $file) = splitpath ($_);
	if ( my @dirs = splitdir($directories) ) {
	    my $path = $volume . shift(@dirs);
            $file = catdir(grep length, @dirs, $file);
	    push @{$targets->{$path}}, $file
	}
	else {
	    $targets->{$file} = undef;
	}
    }
    my $thisdir; # if we are performing delta on the this dir itself
    if ($targets) {
	if (exists $targets->{''}) {
	    delete $targets->{''};
	    $thisdir = 1;
	}
    }
    else {
	$thisdir = 1;
    }
    # if we are descending into children
    # don't use depth when we are still traversing through targets
    my $descend = defined $targets || !(defined $arg{depth} && $arg{depth} == 0);
    # XXX: the top level entry is undefined, which should be fixed.
    $self->cb_conflict->($editor, defined $arg{entry} ? $arg{entry} : '', $arg{baton}, $cinfo->{'.conflict'})
	if $thisdir && $self->cb_conflict && $cinfo->{'.conflict'};

    # XXX: later
    return 1 if $self->_node_deleted_or_absent(%compatarg, %arg, pool => $pool);
    # if a node is replaced, it has no base, unless it was replaced with history.
    $arg{base} = 0 if $schedule eq 'replace' && !$cinfo->{'.copyfrom'};
    my ($entries, $baton) = ({});
    if ($arg{add}) {
	$baton = $arg{root} ? $arg{baton} :
	    $editor->add_directory($arg{entry}, $arg{baton},
				   $cinfo->{'.copyfrom'}
				   ? ($arg{cb_copyfrom}->(@{$cinfo}{qw/.copyfrom .copyfrom_rev/}))
				   : (undef, -1), $pool);
    }

    $entries = $base_root->dir_entries($base_path)
	if $arg{base} && $arg{base_kind} == $SVN::Node::dir;

    $baton ||= $arg{root} ? $arg{baton}
	: $editor->open_directory($arg{entry}, $arg{baton},
				 $self->_delta_rev2($target, $cinfo), $pool);

    # check scheduled addition
    # XXX: does this work with copied directory?
    my ($newprops, $fullprops) = $self->_node_props2($base_root, $base_path, $target, $editor, \%arg);

    if ($descend) {

    my $signature;
    if ($self->{signature} && $arg{base_root_is_xd}) {
	$signature = $self->{signature}->load ($arg{copath});
	# if we are not iterating over all entries, keep the old signatures
	$signature->{keepold} = 1 if defined $targets
    }

    for my $entry (sort keys %$entries) {
	# if the sub-delta returns 1 it means the node is modified. invlidate
	# the signature cache
        my $ret = $self->_delta_entry( $base_root, $base_path, $target, $editor,
            { existing  => 1,
              targets   => $targets,
              entries   => $entries,
              entry     => $entry,
              baton     => $baton,
              signature => $signature,
              compatarg => \%compatarg,
            },
            \%arg );

	$ret and ($signature && $signature->invalidate ($entry));

    }

    if ($signature) {
	$signature->flush;
	undef $signature;
    }

    # if we are at somewhere arg{copath} not exist, $arg{type} is empty
    if ( $arg{type} ) {
        my $ignore = $self->xd->ignore($fullprops->{'svn:ignore'});
        my $new_entries = $target->root->dir_entries( $target->path_anchor, $pool );

        for my $entry ( sort grep { !exists $entries->{$_} } keys %$new_entries ) {
            $self->_delta_entry( $base_root, $base_path, $target, $editor,
                { targets   => $targets,
                  entries   => $new_entries,
                  entry     => $entry,
                  baton     => $baton,
                  ignore    => $ignore,
                  compatarg => \%compatarg,
                },
                \%arg );
        }
    }

    }

    if ($thisdir) {
	$editor->change_dir_prop ($baton, $_, ref ($newprops->{$_}) ? undef : $newprops->{$_}, $pool)
	    for sort keys %$newprops;
    }
    if (defined $targets) {
	$logger->warn(loc ("Unknown target: %1.", $_)) for sort keys %$targets;
    }

    $editor->close_directory ($baton, $pool)
	unless $arg{root};
    return 0;
}


sub _delta_rev2 {
    my ($self, $target, $cinfo) = @_;
    my $schedule = $cinfo->{'.schedule'} || '';
    # XXX: uncomment this as mutation coverage test
    # return  $entry->{revision};

    # Lookup the copy source rev for the case of open_directory inside
    # add_directotry with history.  But shouldn't do so for replaced
    # items, because the rev here is used for delete_entry
    my ($source_path, $source_rev) = $schedule ne 'replace' ?
	$self->xd->_copy_source($cinfo, $target->copath) : ();
    ($source_path, $source_rev) = ($target->path_anchor, $cinfo->{revision})
	unless defined $source_path;
    return $source_rev;

}

sub _node_props2 {
    my ( $self, $base_root, $base_path, $target, $editor, $ctx ) = @_;

    my $newprops;
    my $kind = $target->root->check_path($target->path_anchor); # XXX: in ctx already, or not calling this at all
    return ({}, {}) if $kind == $SVN::Node::unknown;
    my $fullprop
        = $kind ? $target->root->node_proplist( $target->path_anchor ) : {};
    if ( !$ctx->{base} or $ctx->{in_copy} ) {
        $newprops = $fullprop;
    }
    elsif ( !$ctx->{base_root_is_xd} && $ctx->{base} ) {
        $newprops = $self->can('_prop_delta')
            ->( $base_root->node_proplist($base_path), $fullprop )
            if $ctx->{kind}
            && $ctx->{base_kind}
            && $self->can('_prop_changed')->(
            $base_root, $base_path, $target->root,
            $target->path_anchor
            );
    }
    else { # XXX: this logic should not be here
	my $schedule = $ctx->{cinfo}{'.schedule'} || '';
	$newprops = (!$schedule && $ctx->{auto_add} && $ctx->{kind} == $SVN::Node::none && $ctx->{type} eq 'file')
	    ? $self->xd->auto_prop($target->copath) : $ctx->{cinfo}{'.newprop'};
    }
    return ( $newprops, $fullprop );
}


if ($ENV{_REFACTORING}) {

for my $method (qw/_delta_rev _delta_content _unknown_verbose _node_deleted _node_deleted_or_absent _prop_delta _prop_changed _node_props _delta_file _delta_dir _get_rev checkout_delta/) {
    no strict 'refs';
    *$method = sub {
	warn "===> old $method is being called from delta run";
	my $func = SVK::DeltaOld->can($method);
	goto $func;
    }
}

}
1;
