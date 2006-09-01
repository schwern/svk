#!/usr/bin/perl -w

use Test::More;
use File::Spec;
use File::Basename qw( dirname );

my $manifest = File::Spec->catdir( dirname(__FILE__), '..', 'MANIFEST' );
require SVN::Core;

diag "Subversion $SVN::Core::VERSION";
plan skip_all => 'MANIFEST not exists' unless -e $manifest;
open FH, $manifest;

my @pms = map { s|^lib/||; chomp; $_ } grep { m|^lib/.*pm$| } <FH>;

plan tests => scalar @pms;
for (@pms) {
    s|\.pm$||;
    s|/|::|g;
    use_ok ($_);
}
my $svk = SVK->new;
$svk->help;
