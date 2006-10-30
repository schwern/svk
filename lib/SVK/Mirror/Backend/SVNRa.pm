package SVK::Mirror::Backend::SVNRa;
use strict;
use warnings;

use SVN::Core;
use SVN::Ra;
use SVN::Client ();
use SVK::I18N;
use SVK::Editor;
use Class::Autouse qw(SVK::Editor::SubTree SVK::Editor::CopyHandler);

use constant OK => $SVN::_Core::SVN_NO_ERROR;

## class SVK::Mirror::Backend::SVNRa;
## has $.mirror is weak;
## has ($!config, $!auth_baton, $!auth_ref);
## has ($.source_root, $.source_path, $.fromrev)

# We'll extract SVK::Mirror::Backend later.
# use base 'SVK::Mirror::Backend';
use base 'Class::Accessor::Fast';

# for this: things without _'s will probably move to base
# SVK::Mirror::Backend
__PACKAGE__->mk_accessors(qw(mirror _config _auth_baton _auth_ref _auth_baton source_root source_path fromrev _has_replay));

=head1 NAME

SVK::Mirror::Backend::SVNRa - 

=head1 SYNOPSIS


=head1 DESCRIPTION

=over

=item load

=cut

sub _do_load_fromrev {
    my $self = shift;
    my $fs = $self->mirror->repos->fs;
    my $root = $fs->revision_root($fs->youngest_rev);
    my $changed = $root->node_created_rev($self->mirror->path);
    return scalar $self->mirror->find_changeset($changed);
}

sub refresh {
    my $self = shift;
    $self->fromrev($self->_do_load_fromrev);
}

sub load {
    my ($class, $mirror) = @_;
    Carp::cluck unless ref($mirror) eq 'SVK::Mirror';
    my $self = $class->SUPER::new( { mirror => $mirror } );
    Carp::cluck unless $mirror->depot;
    my $t = SVK::Path->real_new( { depot => $mirror->depot, path => $mirror->path } )->refresh_revision;

    my $uuid = $t->root->node_prop($t->path, 'svm:uuid');
    my $ruuid = $t->root->node_prop($t->path, 'svm:ruuid') || $uuid;
    die loc("%1 is not a mirrored path.\n", $t->path) unless $uuid;
    my ( $root, $path ) = split('!',  $t->root->node_prop($t->path, 'svm:source'));

    $self->source_root( $root );
    $self->source_path( $path );

    $mirror->url( "$root$path" );
    $mirror->server_uuid( $ruuid );
    $mirror->source_uuid( $uuid );

    $self->refresh;

    die loc("%1 is not a mirrored path.\n", $t->path) unless defined $self->fromrev;

    return $self;
}

=item create

=cut

sub create {
    my ($class, $mirror) = @_;

    my $self = $class->SUPER::new({ mirror => $mirror });

    my $ra = $self->_new_ra;

    # init the svm:source and svm:uuid thing on $mirror->path
    my $uuid = $ra->get_uuid;
    my $source_root = $ra->get_repos_root;
    my $source_path = $self->mirror->url;
    # XXX: this shouldn't happen. kill this substr
    die "source url not under source root"
	if substr($source_path, 0, length($source_root), '') ne $source_root;

    $self->source_root( $source_root );
    $self->source_path( $source_path );

    $self->_check_overlap;

    # note that the ->source is splitted with '!' and put into source_root and source_path (or something)

    my $t = SVK::Path->real_new( { depot => $mirror->depot, path => '/' } )->refresh_revision;
    my ($editor, %cb) = $t->get_dynamic_editor(
        ignore_mirror => 1,
        author        => $ENV{USER},
    );
    $cb{txn}->change_prop( 'svm:headrev', "$uuid:0" );
    my $dir_baton = $editor->add_directory( substr($self->mirror->path, 1), 0, undef, -1 );
    $editor->change_dir_prop( $dir_baton, 'svm:uuid', $uuid);
    $editor->change_dir_prop( $dir_baton, 'svm:source', $source_root.'!'.$source_path );
    $editor->close_directory($dir_baton);
    $editor->adjust;
    $editor->close_edit;

    $mirror->server_uuid( $uuid );

    return $self;
}

sub _check_overlap {
    my ($self) = @_;
    my $depot = $self->mirror->depot;
    my $fs = $depot->repos->fs;
    my $root = $fs->revision_root($fs->youngest_rev);
    my $prop = $root->node_prop ('/', 'svm:mirror') or return;
    my @mirrors = $prop =~ m/^(.*)$/mg;

    for (@mirrors) {
	my $mirror = SVK::Mirror->load( { depot => $depot, path => $_ } );
#	warn $mirror;
	next if $self->source_root ne $mirror->_backend->source_root;
	# XXX: check overlap with svk::mirror objects.

	my ($me, $other) = map { Path::Class::Dir->new_foreign('Unix', $_) }
	    $self->source_path, $mirror->_backend->source_path;
	die "Mirroring overlapping paths not supported\n"
	    if $me->subsumes($other) || $other->subsumes($me);
    }
}

sub has_replay {
    my $self = shift;
    return $self->_has_replay if defined $self->_has_replay;

    return $self->_has_replay(0) unless _p_svn_ra_session_t->can('replay');

    if (eval { $self->_new_ra->replay(0, 0, 0, SVK::Editor->new); 1}) {
	return $self->_has_replay(1);
    }

    return $self->_has_replay(0)
        if $@ =~ m/not implemented/ || $@ =~ m/unsupported feature/;

    die $@;
}

sub _new_ra {
    my ($self, @args) = @_;

    $self->_initialize_svn;
    return SVN::Ra->new( url => $self->mirror->url,
                         auth => $self->_auth_baton,
                         config => $self->_config, @args );
}

sub _initialize_svn {
    my ($self) = @_;

    $self->_config( SVN::Core::config_get_config(undef, $self->mirror->pool) )
      unless $self->_config;
    $self->_initialize_auth
      unless $self->_auth_baton;
}

sub _initialize_auth {
    my ($self) = @_;

    # create a subpool that is not automatically destroyed
    my $auth_pool = SVN::Pool::create (${ $self->mirror->pool });
    $auth_pool->default;

    my ($baton, $ref) = SVN::Core::auth_open_helper([
        SVN::Client::get_simple_provider (),
        SVN::Client::get_ssl_server_trust_file_provider (),
        SVN::Client::get_username_provider (),
        SVN::Client::get_simple_prompt_provider( $self->can('_simple_prompt'), 2),
        SVN::Client::get_ssl_server_trust_prompt_provider( $self->can('_ssl_server_trust_prompt') ),
        SVN::Client::get_ssl_client_cert_prompt_provider( $self->can('_ssl_client_cert_prompt'), 2 ),
        SVN::Client::get_ssl_client_cert_pw_prompt_provider( $self->can('_ssl_client_cert_pw_prompt'), 2 ),
        SVN::Client::get_username_prompt_provider( $self->can('_username_prompt'), 2),
    ]);

    $self->_auth_baton($baton);
    $self->_auth_ref($ref);
}

# Implement auth callbacks
sub _simple_prompt {
    my ($cred, $realm, $default_username, $may_save, $pool) = @_;

    if (defined $default_username and length $default_username) {
        print "Authentication realm: $realm\n" if defined $realm and length $realm;
        $cred->username($default_username);
    }
    else {
        _username_prompt($cred, $realm, $may_save, $pool);
    }

    $cred->password(_read_password("Password for '" . $cred->username . "': "));
    $cred->may_save($may_save);

    return OK;
}

sub _ssl_server_trust_prompt {
    my ($cred, $realm, $failures, $cert_info, $may_save, $pool) = @_;

    print "Error validating server certificate for '$realm':\n";

    print " - The certificate is not issued by a trusted authority. Use the\n",
          "   fingerprint to validate the certificate manually!\n"
      if ($failures & $SVN::Auth::SSL::UNKNOWNCA);

    print " - The certificate hostname does not match.\n"
      if ($failures & $SVN::Auth::SSL::CNMISMATCH);

    print " - The certificate is not yet valid.\n"
      if ($failures & $SVN::Auth::SSL::NOTYETVALID);

    print " - The certificate has expired.\n"
      if ($failures & $SVN::Auth::SSL::EXPIRED);

    print " - The certificate has an unknown error.\n"
      if ($failures & $SVN::Auth::SSL::OTHER);

    printf(
        "Certificate information:\n".
        " - Hostname: %s\n".
        " - Valid: from %s until %s\n".
        " - Issuer: %s\n".
        " - Fingerprint: %s\n",
        map $cert_info->$_, qw(hostname valid_from valid_until issuer_dname fingerprint)
    );

    print(
        $may_save
            ? "(R)eject, accept (t)emporarily or accept (p)ermanently? "
            : "(R)eject or accept (t)emporarily? "
    );

    my $choice = lc(substr(<STDIN> || 'R', 0, 1));

    if ($choice eq 't') {
        $cred->may_save(0);
        $cred->accepted_failures($failures);
    }
    elsif ($may_save and $choice eq 'p') {
        $cred->may_save(1);
        $cred->accepted_failures($failures);
    }

    return OK;
}

sub _ssl_client_cert_prompt {
    my ($cred, $realm, $may_save, $pool) = @_;

    print "Client certificate filename: ";
    chomp(my $filename = <STDIN>);
    $cred->cert_file($filename);

    return OK;
}

sub _ssl_client_cert_pw_prompt {
    my ($cred, $realm, $may_save, $pool) = @_;

    $cred->password(_read_password("Passphrase for '%s': "));

    return OK;
}

sub _username_prompt {
    my ($cred, $realm, $may_save, $pool) = @_;

    print "Authentication realm: $realm\n" if defined $realm and length $realm;
    print "Username: ";
    chomp(my $username = <STDIN>);
    $username = '' unless defined $username;

    $cred->username($username);

    return OK;
}

sub _read_password {
    my ($prompt) = @_;

    print $prompt;

    require Term::ReadKey;
    Term::ReadKey::ReadMode('noecho');

    my $password = '';
    while (defined(my $key = Term::ReadKey::ReadKey(0))) {
        last if $key =~ /[\012\015]/;
        $password .= $key;
    }

    Term::ReadKey::ReadMode('restore');
    print "\n";

    return $password;
}

=back

=head2 METHODS

=over

=item find_rev_from_changeset($remote_identifier)

=cut

sub find_rev_from_changeset {
    my ($self, $changeset) = @_;
    my $t = SVK::Path->real_new({ depot => $self->mirror->depot, path => $self->mirror->path })
        ->refresh_revision;
    return $t->search_revision
	( cmp => sub {
	      my $rev = shift;
	      my $search = $t->mclone(revision => $rev);
              my $s_changeset = scalar $self->mirror->find_changeset($rev);
              return $s_changeset <=> $changeset;
          } );
}

=item traverse_new_changesets()

=cut

sub traverse_new_changesets {
    my ($self, $code, $torev) = @_;
    my $from = ($self->fromrev || 0)+1;
    my $to = $torev || -1;

    my $ra = $self->_new_ra;
    $to = $ra->get_latest_revnum() if $to == -1;
    return if $from > $to;
    print "Retrieving log information from $from to $to\n";
    eval {
    $ra->get_log([''], $from, $to, 0,
		  0, 1,
		  sub {
		      my ($paths, $rev, $author, $date, $msg, $pool) = @_;
		      $code->($rev, { author => $author, date => $date, message => $msg });
		  });
    };
}

sub sync_changeset {
    my ($self, $changeset, $metadata, $callback) = @_;
    my $t = SVK::Path->real_new({ depot => $self->mirror->depot, path => $self->mirror->path })
        ->refresh_revision;
    my ( $editor, undef, %opt ) = $t->get_editor(
        ignore_mirror => 1,
        message       => $metadata->{message},
        author        => $metadata->{author},
        callback      => sub {
            $t->repos->fs->change_rev_prop( $_[0], 'svn:date',
                $metadata->{date} );
            $self->fromrev( $_[0] );
            $callback->( $changeset, $_[0] ) if $callback;
        }
    );
    my $ra = $self->_new_ra;
    # XXX: sync relayed revmap as well
    $opt{txn}->change_prop('svm:headrev', $self->mirror->server_uuid.":$changeset\n");

    if ( my $revprop = $self->mirror->depot->mirror->revprop ) {
        my $prop = $ra->rev_proplist($changeset);
        for (@$revprop) {
            $opt{txn}->change_prop( $_, $prop->{$_} )
                if exists $prop->{$_};
        }
    }

    $editor = SVK::Editor::CopyHandler->new(
        _editor => $editor,
        cb_copy => sub {
            my ( $editor, $path, $rev ) = @_;
            return ( $path, $rev ) if $rev == -1;
            my $source_path = $self->source_path;
            $path =~ s/^\Q$self->{source_path}//;
            return $t->as_url(
                1,
                $self->mirror->path . $path,
                $self->find_rev_from_changeset($rev)
            );
        }
    );

    # ra->replay gives us editor calls based on repos root not
    # base uri, so we need to get the correct subtree.
    my $baton;
    if ( length $self->source_path ) {
        my $anchor = substr( $self->source_path, 1 );
        $baton  = $editor->open_root(-1);      # XXX: should use $t->revision
        $editor = SVK::Editor::SubTree->new(
            {   master_editor => $editor,
                anchor        => $anchor,
                anchor_baton  => $baton
            }
        );
    }

    $ra->replay( $changeset, 0, 1, $editor );
    if ( length $self->source_path ) {
        $editor->close_directory($baton);
        if ( $editor->needs_touch ) {
            $editor->change_dir_prop( $baton, 'svk:mirror' => undef );
        }
    }
    if ( $editor->isa('SVK::Editor::SubTree') && !$editor->changes ) {
        $editor->abort_edit;
    } else {
        $editor->close_edit;
    }
    return;

}

=item mirror_changesets

=cut

sub mirror_changesets {
    my ( $self, $torev, $callback ) = @_;

    $self->mirror->with_lock( 'mirror',
        sub {
            $self->traverse_new_changesets(
                sub { $self->sync_changeset( @_, $callback ) }, $torev );
        }
    );
}

=item get_commit_editor


=cut

sub _relayed {
    my $self = shift;
    $self->mirror->server_uuid ne $self->mirror->source_uuid;
}

sub get_commit_editor {
    my ($self, $path, $msg, $committed) = @_;
    die loc("relayed merge back not supported yet.\n") if $self->_relayed;
    $self->{commit_ra} = $self->_new_ra( url => $self->mirror->url.$path );

    my @lock = $SVN::Core::VERSION ge '1.2.0' ? (undef, 0) : ();

    return SVN::Delta::Editor->new($self->{commit_ra}->get_commit_editor($msg, $committed, @lock));
}

sub change_rev_prop {
    my $self = shift;
    $self->_new_ra->change_rev_prop(@_);
}

1;

