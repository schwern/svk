#!/usr/bin/perl -w
use Test::More tests => 13;
use strict;
require 't/tree.pl';

our $output;
my ($xd, $svk) = build_test();
our ($copath, $corpath) = get_copath ('merge');
is_output_like ($svk, 'merge', [], qr'SYNOPSIS', 'merge - help');
is_output_like ($svk, 'merge', ['//foo', '//bar', '//foo'], qr'SYNOPSIS',
		'merge - too many args');
$svk->checkout ('//', $copath);
mkdir copath ('A');
overwrite_file (copath ("/A/foo"), "foobar\n");
overwrite_file (copath ("/A/bar"), "foobarbazzz\n");
$svk->add (copath ('A'));
$svk->ps ('svn:keywords', 'Rev', copath ("A/foo"));

$svk->commit ('-m', 'commit message here (r1)', $copath);

$svk->copy ('-m', 'branch', '//A', '//B');

append_file (copath ('/A/foo'), "\nsome more foobar\nzz\n");
$svk->propset ('someprop', 'propvalue', copath ("A/foo"));
$svk->commit ('-m', 'commit message here (r3)', $copath);

$svk->update ('-r', 1, $copath);
overwrite_file (copath ("A/foo"), "some local mods\nfoobar\n");

is_output ($svk, 'update', [$copath],
	   ["Syncing //(/) in $corpath to 3.",
	    status_native ($copath,
			   'GU ', 'A/foo',
			   'A  ', 'B',
			   'A  ', 'B/foo',
			   'A  ', 'B/bar')], 'merge via update');
is_file_content (copath ("A/foo"),
		 "some local mods\nfoobar\n\nsome more foobar\nzz\n",
		 'merge via update');

$svk->update ('-r', 1, $copath);
is_file_content (copath ("A/foo"), "some local mods\nfoobar\n",
		 'merge via update - backward');
overwrite_file (copath ("A/foo"),
		"some local mods\nfoobar\n\nsome more foobarzz\nyy\n");

$svk->update ($copath);
ok ($output =~ m/1 conflict found\./, 'conflict');

$svk->revert (copath ("A/foo"));
$svk->resolved (copath ("A/foo"));

overwrite_file (copath ("A/foo"), "late modification...\nfoobar\n\nsome more foobar\nzz\n");
$svk->status ($copath);
$svk->commit ('-m', 'commit message here (r4)', $copath);
$svk->update ($copath);
is_output ($svk, 'merge', ["-r", "3:2", '//', $copath],
	   [status_native ($copath, 'GU ', 'A/foo')]);

is_file_content (copath ("A/foo"), "late modification...\nfoobar\n",
		 'basic merge for revert');

$svk->merge (qw/-C -r 4:3/, '//A', '//B');
is_output ($svk, 'merge', ['-r4:3', '-m', 'merge from //A to //B', '//A', '//B'],
	   ['G   foo',
	    'Committed revision 5.']);
is_output ($svk, 'update', [$copath],
	   ["Syncing //(/) in $corpath to 5."]);

is_file_content (copath ("B/foo"), "foobar\n",
		 'merge via update');
$svk->revert ('-R', $copath);
is_output_like ($svk, 'merge', ["-r", "3:2", '//'],
		qr'not a checkout path');
chdir ($copath);
is_output ($svk, 'merge', ["-r", "3:2", '//'],
	   [status_native (undef, 'GU ', 'A/foo')]);
