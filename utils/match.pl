#!/usr/bin/perl -w
#
# Copyright 2014-2016, Intel Corporation
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in
#       the documentation and/or other materials provided with the
#       distribution.
#
#     * Neither the name of the copyright holder nor the names of its
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

#
# match -- compare an output file with expected results
#
# usage: match [-adoqv] [match-file]...
#
# this script compares the output from a test run, stored in a file, with
# the expected output.  comparison is done line-by-line until either all
# lines compare correctly (exit code 0) or a miscompare is found (exit
# code nonzero).
#
# expected output is stored in a ".match" file, which contains a copy of
# the expected output with embedded tokens for things that should not be
# exact matches.  the supported tokens are:
#
#	$(N)	an integer (i.e. one or more decimal digits)
#	$(FP)	a floating point number
#	$(S)	ascii string
#	$(X)	hex number
#	$(XX)	hex number prefixed with 0x
#	$(W)	whitespace
#	$(nW)	non-whitespace
#	$(*)	any string
#	$(DD)	output of a "dd" run
#	$(OPT)	line is optional (may be missing, matched if found)
#
# arguments are:
#
#	-a	find all files of the form "X.match" in the current
#		directory and match them again the corresponding file "X".
#
#	-o	custom output filename - only one match file can be given
#
#	-d	debug -- show lots of debug output
#
#	-q	don't print any output on mismatch (just exit with result code)
#
#	-v	verbose -- show every line as it is being matched
#

use strict;
use Getopt::Std;
select STDERR;

my $Me = $0;
$Me =~ s,.*/,,;

our ($opt_a, $opt_d, $opt_q, $opt_v, $opt_o);

$SIG{HUP} = $SIG{INT} = $SIG{TERM} = $SIG{__DIE__} = sub {
	die @_ if $^S;
	my $errstr = shift;
	die "FAIL: $Me: $errstr";
};

sub usage {
	my $msg = shift;

	warn "$Me: $msg\n" if $msg;
	warn "Usage: $Me [-adqv] [match-file]...\n";
	warn "   or: $Me [-dqv] -o output-file match-file...\n";
	exit 1;
}

getopts('adoqv') or usage;

my %match2file;

if ($opt_a) {
	usage("-a and filename arguments are mutually exclusive")
		if $#ARGV != -1;
	opendir(DIR, '.') or die "opendir: .: $!\n";
	my @matchfiles = grep { /(.*)\.match$/ && -f $1 } readdir(DIR);
	closedir(DIR);
	die "no files found to process\n" unless @matchfiles;
	foreach my $mfile (@matchfiles)  {
		die "$mfile: $!\n" unless open(F, $mfile);
		close(F);
		my $ofile = $mfile;
		$ofile =~ s/\.match$//;
		die "$mfile found but cannot open $ofile: $!\n"
			unless open(F, $ofile);
		close(F);
		$match2file{$mfile} = $ofile;
	}
} elsif ($opt_o) {
	usage("-o argument requires two paths") if $#ARGV != 1;

	$match2file{$ARGV[1]} = $ARGV[0];
} else {
	usage("no match-file arguments found") if $#ARGV == -1;

	# to improve the failure case, check all filename args exist and
	# are provided in pairs now, before going through and processing them
	foreach my $mfile (@ARGV) {
		my $ofile = $mfile;
		usage("$mfile: not a .match file") unless
			$ofile =~ s/\.match$//;
		usage("$mfile: $!") unless open(F, $mfile);
		close(F);
		usage("$ofile: $!") unless open(F, $ofile);
		close(F);
		$match2file{$mfile} = $ofile;
	}
}

my $mfile;
my $ofile;
print "Files to be processed:\n" if $opt_v;
foreach $mfile (sort keys %match2file) {
	$ofile = $match2file{$mfile};
	print "        match-file \"$mfile\" output-file \"$ofile\"\n"
		if $opt_v;
	match($mfile, $ofile);
}

exit 0;

#
# match -- process a match-file, output-file pair
#
sub match {
	my ($mfile, $ofile) = @_;
	my $pat;
	my $output = snarf($ofile);
	my $all_lines = $output;
	my $line_pat = 0;
	my $line_out = 0;
	my $opt = 0;

	open(F, $mfile) or die "$mfile: $!\n";
	while (<F>) {
		$pat = $_;
		$line_pat++;
		$line_out++;
		s/([*+?|{}.\\^\$\[()])/\\$1/g;
		s/\\\$\\\(FP\\\)/[-+]?\\d*\\.?\\d+([eE][-+]?\\d+)?/g;
		s/\\\$\\\(N\\\)/\\d+/g;
		s/\\\$\\\(\\\*\\\)/.*/g;
		s/\\\$\\\(S\\\)/\\P{IsC}+/g;
		s/\\\$\\\(X\\\)/\\p{IsXDigit}+/g;
		s/\\\$\\\(XX\\\)/0x\\p{IsXDigit}+/g;
		s/\\\$\\\(W\\\)/\\s*[^\n]/g;
		s/\\\$\\\(nW\\\)/\\S*/g;
		s/\\\$\\\(DD\\\)/\\d+\\+\\d+ records in\n\\d+\\+\\d+ records out\n\\d+ bytes \\\(\\d+ .B\\\) copied, [.0-9e-]+[^,]*, [.0-9]+ .B.s/g;
		if (s/\\\$\\\(OPT\\\)//) {
			$opt = 1;
		}

		if ($opt_v) {
			my @lines = split /\n/, $output;
			my $line;
			if (@lines) {
				$line = $lines[0];
			} else {
				$line = "[EOF]";
			}

			printf("%s:%-3d %s%s:%-3d       %s\n", $mfile, $line_pat, $pat, $ofile, $line_out, $line);
		}

		print " => /$_/\n" if $opt_d;
		print " [$output]\n" if $opt_d;
		unless ($output =~ s/^$_//) {
			if ($opt) {
				printf("%s:%-3d      [skipping optional line]\n", $ofile, $line_out) if $opt_v;
				$line_out--;
				$opt = 0;
			} else {
				if (!$opt_v) {
					print "[MATCHING FAILED, COMPLETE FILE ($ofile) BELOW]\n$all_lines\n[EOF]\n";
					$opt_v = 1;
					match($mfile, $ofile);
				}

				die "$mfile:$line_pat did not match pattern\n";
			}
		}
	}

	if ($output ne '') {
		if (!$opt_v) {
			print "[MATCHING FAILED, COMPLETE FILE ($ofile) BELOW]\n$all_lines\n[EOF]\n";
		}

		# make it a little more print-friendly...
		$output =~ s/\n/\\n/g;
		die "line $line_pat: unexpected output: \"$output\"\n";
	}
}


#
# snarf -- slurp an entire file into memory
#
sub snarf {
	my ($fname) = @_;
	local $/;
	my $contents;

	open(R, $fname) or die "$fname: $!\n";
	$contents = <R>;
	close(R);

	return $contents;
}
