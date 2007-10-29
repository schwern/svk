#!/usr/bin/perl -w
use strict;
use Test::More tests => 4;
use SVK::Test;
use File::Path;

#sub copath { SVK::Path::Checkout->copath($copath, @_) }

my ($xd, $svk) = build_test('test');
our $output;
$svk->mkdir(-m => 'trunk', '/test/trunk');
$svk->mkdir(-m => 'trunk', '/test/branches');
$svk->mkdir(-m => 'trunk', '/test/tags');
my $tree = create_basic_tree($xd, '/test/trunk');

my $depot = $xd->find_depot('test');
my $uri = uri($depot->repospath);

$svk->mirror('//mirror/MyProject', $uri);
$svk->sync('//mirror/MyProject');

my ($copath, $corpath) = get_copath ('MyProject');
$svk->checkout('//mirror/MyProject/trunk',$copath);
warn $output;
chdir($copath);

is_output_like ($svk, 'branch', ['--create', 'feature/foo','--switch-to'], qr'Project branch created: feature/foo');
append_file ('A/be', "\nsome more foobar\nzz\n");
$svk->propset ('someprop', 'propvalue', 'A/be');
$svk->diff();
$svk->commit ('-m', 'commit message here (r6)','');
is_output ($svk, 'merge',
    ['-C', '-rHEAD:7', '//mirror/MyProject/branches/feature/foo', '//mirror/MyProject/trunk'], 
    [ "Checking locally against mirror source $uri.", 'gg  A/be']);
is_output ($svk, 'branch', ['--merge', '-C', 'feature/foo', 'trunk'], 
    [ "Checking locally against mirror source $uri.", 'gg  A/be']);
