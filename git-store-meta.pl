#!/usr/bin/perl -w
# =============================================================================
# Usage: git-store-meta.pl ACTION [OPTION...]
# Store, update, or apply metadata for files revisioned by Git.
#
# ACTION is one of:
#   -s|--store         Store the metadata for all files revisioned by Git.
#   -u|--update        Update the metadata for changed files.
#   -a|--apply         Apply the stored metadata to files in the working tree.
#   -i|--install       Install hooks in this repo for automated update/apply.
#                      (pre-commit, post-checkout, and post-merge)
#   -h|--help          Print this help and exit.
#   --version          Show current version and exit.
#
# Available OPTIONs are:
#   -f|--fields FIELDs Fields to handle (see below). If omitted, fields in the
#                      current metadata store file are picked when possible;
#                      otherwise, "mtime" is picked as the default.
#                      (available for: --store, --apply)
#   -d|--directory     Also store, update, or apply for directories.
#                      (available for: --store, --apply)
#   --no-directory     Do not store, update, or apply for directories.
#                      (available for: --store, --apply)
#   --topdir           Also store, update, or apply for the top directory.
#                      (available for: --store, --apply)
#   --no-topdir        Do not store, update, or apply for the top directory.
#                      (available for: --store, --apply)
#   -n|--dry-run       Run a test and print the output, without real action.
#                      (available for: --store, --update, --apply)
#   -v|--verbose       Apply with verbose output.
#                      (available for: --apply)
#   --force            Force an apply even if the working tree is not clean. Or
#                      install hooks and overwrite existing ones.
#                      (available for: --apply, --install)
#   -t|--target FILE   Specify another filename to store metadata. Defaults to
#                      ".git_store_meta" in the root of the working tree.
#                      (available for: --store, --update, --apply, --install)
#
# FIELDs is a comma-separated string consisting of the following values:
#   mtime   last modified time
#   atime   last access time
#   mode    Unix permissions
#   user    user name
#   group   group name
#   uid     user ID (if user is also set, prefer user and fallback to uid)
#   gid     group ID (if group is also set, prefer group and fallback to gid)
#   acl     access control lists for POSIX setfacl/getfacl
#
# git-store-meta 2.2.0
# Copyright (c) 2015-2020, Danny Lin
# Released under MIT License
# Project home: https://github.com/danny0838/git-store-meta
# =============================================================================

use utf8;
use strict;

use version; our $VERSION = version->declare("v2.2.0");
use Getopt::Long;
Getopt::Long::Configure qw(gnu_getopt);
use File::Basename;
use File::Path qw(make_path);
use File::Spec::Functions qw(rel2abs abs2rel catfile);
use POSIX qw(strftime);
use Time::Local;

# define constants
my $GIT_STORE_META_PREFIX    = "# generated by";
my $GIT_STORE_META_APP       = "git-store-meta";
my $GIT_STORE_META_FILENAME  = ".git_store_meta";
my $GIT                      = "git";
my @ACTIONS = ('help', 'version', 'install', 'update', 'store', 'apply');
my @FIELDS = ('file', 'type', 'mtime', 'atime', 'mode', 'uid', 'gid', 'user', 'group', 'acl');
my %CONFIGS = (
    directory => undef,
    topdir => undef,
);

# runtime variables
my $script = rel2abs(__FILE__);
my $action;
my $gitdir;
my $topdir;

my $git_store_meta_filename;
my $git_store_meta_file;
my $git_store_meta_header;
my $temp_file;

my $cache_file_exist = 0;
my $cache_file_accessible = 0;
my $cache_header_valid = 0;
my $cache_app;
my $cache_version;
my %cache_configs;
my @cache_fields;

my $touch;
my $chown;
my $getfacl;
my $setfacl;

my $configs;

# parse arguments
my %argv = (
    "store"      => 0,
    "update"     => 0,
    "apply"      => 0,
    "install"    => 0,
    "help"       => 0,
    "version"    => 0,
    "target"     => undef,
    "fields"     => undef,
    "directory"  => undef,
    "topdir"     => undef,
    "force"      => 0,
    "dry-run"    => 0,
    "verbose"    => 0,
);
GetOptions(
    "store|s"      => \$argv{'store'},
    "update|u"     => \$argv{'update'},
    "apply|a"      => \$argv{'apply'},
    "install|i"    => \$argv{'install'},
    "help|h"       => \$argv{'help'},
    "version"      => \$argv{'version'},
    "fields|f=s"   => \@{$argv{'fields'}},
    "directory|d!" => \$argv{'directory'},
    "topdir!"      => \$argv{'topdir'},
    "force"        => \$argv{'force'},
    "dry-run|n"    => \$argv{'dry-run'},
    "verbose|v"    => \$argv{'verbose'},
    "target|t=s"   => \$argv{'target'},
) or die;

# determine action
foreach (@ACTIONS) {
    if ($argv{$_}) { $action = $_; last; }
}

# handle action: help, version, and unknown
if (!defined($action)) {
    usage();
    exit 1;
} elsif ($action eq "help") {
    usage();
    exit 0;
} elsif ($action eq "version") {
    print $VERSION . "\n";
    exit 0;
}

# init and validate gitdir
$gitdir = `$GIT rev-parse --git-dir 2>/dev/null`
    or die "error: unknown git repository.\n";
chomp($gitdir);

# handle action: install
if ($action eq "install") {
    print "installing hooks...\n";
    install_hooks();
    exit 0;
}

# init and validate topdir
$topdir = `$GIT rev-parse --show-cdup 2>/dev/null`
    or die "error: current working directory is not in a git working tree.\n";
chomp($topdir);

# cd to the top level directory of current git repo
chdir($topdir) if $topdir;

# init paths and header info
$git_store_meta_filename = defined($argv{'target'}) ? $argv{'target'} : $GIT_STORE_META_FILENAME;
$git_store_meta_file = rel2abs($git_store_meta_filename);
$temp_file = catfile($gitdir, $GIT_STORE_META_FILENAME . ".tmp");
get_cache_header_info();

# handle action: store, update, apply

# validate
if ($action eq "store") {
    print "storing metadata to `$git_store_meta_file' ...\n";
} elsif ($action eq "update") {
    print "updating metadata to `$git_store_meta_file' ...\n";

    if (!$cache_file_exist) {
        die "error: `$git_store_meta_file' doesn't exist.\nRun --store to create new.\n";
    }
    if (!$cache_file_accessible) {
        die "error: `$git_store_meta_file' is not an accessible file.\n";
    }
    if (!$cache_header_valid) {
        die "error: `$git_store_meta_file' is malformatted.\nFix it or run --store to create new.\n";
    }
    if ($cache_app ne $GIT_STORE_META_APP) {
        die "error: `$git_store_meta_file' is using an unknown schema: $cache_app $cache_version\nFix it or run --store to create new.\n";
    }
    if (!(2.2.0 <= $cache_version && $cache_version < 2.3.0)) {
        die "error: `$git_store_meta_file' is using an unsupported version: $cache_version\n";
    }
} elsif ($action eq "apply") {
    print "applying metadata from `$git_store_meta_file' ...\n";

    if (!$cache_file_exist) {
        print "`$git_store_meta_file' doesn't exist, skipped.\n";
        exit;
    }
    if (!$argv{'force'} && `$GIT status --porcelain -uno --ignore-submodules=all -z 2>/dev/null` ne "") {
      die "error: git working tree is not clean.\nCommit, stash, or revert changes before running this, or add --force.\n";
    }
    if (!$cache_file_accessible) {
        die "error: `$git_store_meta_file' is not an accessible file.\n";
    }
    if (!$cache_header_valid) {
        die "error: `$git_store_meta_file' is malformatted.\n";
    }
    if ($cache_app ne $GIT_STORE_META_APP) {
        die "error: `$git_store_meta_file' is using an unknown schema: $cache_app $cache_version\n";
    }
}

# adjust fields, configs and output header
fix_fields: {
    # use $argv{'fields'} if provided, or use fields in the cache file
    # special handling for --update, which must take fields in the cache file
    if (@{$argv{'fields'}} > 0 && $action ne "update") {
        @{$argv{'fields'}} = split(/\s*,\s*/, join(",", @{$argv{'fields'}}));
        unshift(@{$argv{'fields'}}, "file", "type");
    } elsif ($cache_header_valid) {
        @{$argv{'fields'}} = @cache_fields;
    } else {
        @{$argv{'fields'}} = ("file", "type", "mtime");
    }

    # filter fields
    my %FIELDS = map { $_ => 1 } @FIELDS;
    my @fields;
    foreach (@{$argv{'fields'}}) {
        if ($FIELDS{$_}) {
            $FIELDS{$_} = 0;
            push (@fields, $_);
        }
    }
    @{$argv{'fields'}} = @fields;
}

fix_configs: {
    # use value in the cache file for unspecified configs
    while (my ($key, $value) = each(%cache_configs)) {
        if (!defined($argv{$key}) || $action eq 'update') {
            $argv{$key} = $value;
        }
    }

    # Versions < 2 don't record --directory
    # Add "--directory" if a directory entry exists.
    if (defined($cache_version) && $cache_version < 2) {
        if (has_directory_entry()) {
            $argv{'directory'} = 1;
        }
    }

    # set default configs and header to write
    my @configs;
    foreach my $key (sort keys %CONFIGS) {
        my $value = $CONFIGS{$key};
        $argv{$key} = $value if !defined($argv{$key});
        if (!defined($value)) {
            # boolean style
            push(@configs, "--$key") if $argv{$key};
        } else {
            push(@configs, "--$key=$argv{$key}");
        }
    }

    $configs = join(' ', @configs);
    $git_store_meta_header = join("\t", $GIT_STORE_META_PREFIX, $GIT_STORE_META_APP, substr($VERSION, 1), $configs) . "\n";
}

prepare_subroutines: {
    if (eval { require File::lchown; }) {
        $touch = \&touch_internal;
        $chown = \&chown_internal;
    } else {
        $touch = \&touch_external;
        $chown = \&chown_external;
    }
    if (eval { require Linux::ACL; }) {
        $getfacl = \&getfacl_internal;

        # Linux::ACL::setfacl (0.05) has an issue of adding "mask" field even
        # when not specified, which breaks compatibility with setfacl. Disable
        # it temporarily until it's fixed.
        # https://github.com/nazarov-yuriy/Linux--ACL/issues/2
        #
        # $setfacl = \&setfacl_internal;
        $setfacl = \&setfacl_external;
    } else {
        $getfacl = \&getfacl_external;
        $setfacl = \&setfacl_external;
    }
}

# show settings
print "fields: " . join(", ", @{$argv{'fields'}}) . "\n";
print "flags: " . $configs . "\n" if $configs;

# do the action
if ($action eq "store") {
    if (!$argv{'dry-run'}) {
        make_path(dirname($git_store_meta_file));
        open(GIT_STORE_META_FILE, '>', $git_store_meta_file)
            or die "error: failed to write to `$git_store_meta_file': $!\n";
        select(GIT_STORE_META_FILE);
        store();
        close(GIT_STORE_META_FILE);
        select(STDOUT);
    } else {
        store();
    }
} elsif ($action eq "update") {
    # copy the cache file to the temp file
    # to prevent a conflict in further operation
    open(GIT_STORE_META_FILE, "<", $git_store_meta_file)
        or die "error: failed to access `$git_store_meta_file': $!\n";
    open(TEMP_FILE, ">", $temp_file) or die;

    # discard first 2 lines (header)
    <GIT_STORE_META_FILE>;
    <GIT_STORE_META_FILE>;

    while (<GIT_STORE_META_FILE>) {
        print TEMP_FILE;
    }
    close(TEMP_FILE);
    close(GIT_STORE_META_FILE);

    # update cache
    if (!$argv{'dry-run'}) {
        open(GIT_STORE_META_FILE, '>', $git_store_meta_file)
            or die "error: failed to write to `$git_store_meta_file': $!\n";
        select(GIT_STORE_META_FILE);
        update();
        close(GIT_STORE_META_FILE);
        select(STDOUT);
    } else {
        update();
    }

    # clean up
    unlink($temp_file);
} elsif ($action eq "apply") {
    apply();
}

# -----------------------------------------------------------------------------

sub get_file_type {
    my ($file) = @_;
    if (-l $file) {
        return "l";
    } elsif (-f $file) {
        return "f";
    } elsif (-d $file) {
        return "d";
    }
    return undef;
}

sub timestamp_to_gmtime {
    my ($timestamp) = @_;
    my @t = gmtime($timestamp);
    return strftime("%Y-%m-%dT%H:%M:%SZ", @t);
}

sub gmtime_to_timestamp {
    my ($gmtime) = @_;
    $gmtime =~ m/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    return timegm($6, $5, $4, $3, $2 - 1, $1);
}

# escape a string to be safe to use as a shell script argument
sub escapeshellarg {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

# escape special chars in a filename to be safe to stay in the data file
sub escape_filename {
    my ($str) = @_;
    $str =~ s/([\x00-\x1F\x5C\x7F])/'\x'.sprintf("%02X", ord($1))/eg;
    return $str;
}

# reverse of escape_filename
# "\\" is left for backward compatibility with versions < 1.1.4
sub unescape_filename {
    my ($str) = @_;
    $str =~ s/\\(?:x([0-9A-Fa-f]{2})|\\)/$1?chr(hex($1)):"\\"/eg;
    return $str;
}

sub touch_internal {
    my ($atime, $mtime, $file) = @_;
    $atime = $atime ? gmtime_to_timestamp($atime) : (lstat($file))[8];
    $mtime = $mtime ? gmtime_to_timestamp($mtime) : (lstat($file))[9];
    return File::lchown::lutimes($atime, $mtime, $file);
}

sub touch_external {
    my ($atime, $mtime, $file) = @_;
    if (-l $file) {
        my @cmds;
        if ($atime) {
            push(@cmds, join(" ", ("touch", "-hcad", escapeshellarg($atime), escapeshellarg("./$file"), "2>&1")));
        }
        if ($mtime) {
            push(@cmds, join(" ", ("touch", "-hcmd", escapeshellarg($mtime), escapeshellarg("./$file"), "2>&1")));
        }
        my $cmd = join(' && ', @cmds);
        `$cmd`;
        return ($? == 0);
    }
    $atime = $atime ? gmtime_to_timestamp($atime) : (lstat($file))[8];
    $mtime = $mtime ? gmtime_to_timestamp($mtime) : (lstat($file))[9];
    return utime($atime, $mtime, $file);
}

sub chown_internal {
    my ($uid, $gid, $file) = @_;
    $uid = defined($uid) ? $uid : (lstat($file))[4];
    $gid = defined($gid) ? $gid : (lstat($file))[5];
    return File::lchown::lchown($uid, $gid, $file);
}

sub chown_external {
    my ($uid, $gid, $file) = @_;
    if (-l $file) {
        my $cmd = join(" ", ("chown", "-h", escapeshellarg($uid).':'.escapeshellarg($gid), escapeshellarg("./$file"), "2>&1"));
        `$cmd`;
        return ($? == 0);
    }
    $uid = defined($uid) ? $uid : (lstat($file))[4];
    $gid = defined($gid) ? $gid : (lstat($file))[5];
    return chown($uid, $gid, $file);
}

# Serialization: join lines with ","
sub getfacl_internal {
    my ($file) = @_;
    if (-l $file) {
        return "";
    }
    my @results;
    my ($acl, $default_acl) = Linux::ACL::getfacl($file);
    if (defined $acl) {
        my %acl = %{$acl};
        if (defined $acl{'uperm'}) {
            push(@results, "user::" . getfacl_internal_getperms(\%{$acl{'uperm'}}));
        }
        if (defined $acl{'user'}) {
            foreach my $uid (keys %{$acl{'user'}}) {
                my $user = getpwuid($uid);
                $user = defined($user) ? $user : $uid;
                push(@results, "user:$user:" . getfacl_internal_getperms(\%{$acl{'user'}{$uid}}));
            }
        }
        if (defined $acl{'gperm'}) {
            push(@results, "group::" . getfacl_internal_getperms(\%{$acl{'gperm'}}));
        }
        if (defined $acl{'group'}) {
            foreach my $gid (keys %{$acl{'group'}}) {
                my $group = getgrgid($gid);
                $group = defined($group) ? $group : $gid;
                push(@results, "group:$group:" . getfacl_internal_getperms(\%{$acl{'group'}{$gid}}));
            }
        }
        if (defined $acl{'mask'}) {
            push(@results, "mask::" . getfacl_internal_getperms(\%{$acl{'mask'}}));
        }
        if (defined $acl{'other'}) {
            push(@results, "other::" . getfacl_internal_getperms(\%{$acl{'other'}}));
        }
    }
    if (defined $default_acl) {
        my %acl = %{$default_acl};
        if (defined $acl{'uperm'}) {
            push(@results, "default:user::" . getfacl_internal_getperms(\%{$acl{'uperm'}}));
        }
        if (defined $acl{'gperm'}) {
            push(@results, "default:group::" . getfacl_internal_getperms(\%{$acl{'gperm'}}));
        }
        if (defined $acl{'mask'}) {
            push(@results, "default:mask::" . getfacl_internal_getperms(\%{$acl{'mask'}}));
        }
        if (defined $acl{'other'}) {
            push(@results, "default:other::" . getfacl_internal_getperms(\%{$acl{'other'}}));
        }
    }
    return join(",", @results);
}

sub getfacl_internal_getperms {
    my ($perms) = @_;
    my %perms = %{$perms};
    return ($perms{'r'} ? 'r' : '-') . ($perms{'w'} ? 'w' : '-') . ($perms{'x'} ? 'x' : '-');
}

sub getfacl_external {
    my ($file) = @_;
    my $cmd = join(" ", ("getfacl", "-PcE", escapeshellarg("./$file"), "2>/dev/null"));
    my $acl = `$cmd`; $acl =~ s/\n+$//; $acl =~ s/\n/,/g;
    return $acl;
}

sub setfacl_internal {
    my ($acl, $file) = @_;
    if (-l $file) {
        return 1;
    }
    my @acl;
    foreach my $line (split(",", $acl)) {
        my @parts = split(":", $line);
        my $index;
        my $field;
        my $id;
        my $perms;

        if ($#parts == 2) {
            ($field, $id, $perms) = @parts;
            $index = 0;
        } else {
            ($_, $field, $id, $perms) = @parts;
            $index = 1;
        }

        if ($id eq '') {
            if ($field eq 'user') {
                $field = 'uperm';
            } elsif ($field eq 'group') {
                $field = 'gperm';
            }
            $acl[$index]{$field}{'r'} = substr($perms, 0, 1) ne '-' ? 1 : 0;
            $acl[$index]{$field}{'w'} = substr($perms, 1, 1) ne '-' ? 1 : 0;
            $acl[$index]{$field}{'x'} = substr($perms, 2, 1) ne '-' ? 1 : 0;
        } else {
            if ($id =~ m/^\D/) {
                $id = (getpwnam($id))[2];
            }
            $acl[$index]{$field}{$id}{'r'} = substr($perms, 0, 1) ne '-' ? 1 : 0;
            $acl[$index]{$field}{$id}{'w'} = substr($perms, 1, 1) ne '-' ? 1 : 0;
            $acl[$index]{$field}{$id}{'x'} = substr($perms, 2, 1) ne '-' ? 1 : 0;
        }
    }
    return Linux::ACL::setfacl($file, @acl);
}

sub setfacl_external {
    my ($acl, $file) = @_;
    my $cmd = join(" ", ("setfacl", "-Pbm", escapeshellarg($acl), escapeshellarg("./$file"), "2>&1"));
    `$cmd`;
    return ($? == 0);
}

# Print the initial comment block, from first to second "# ==",
# with "# " removed
sub usage {
    my $start = 0;
    open(GIT_STORE_META, "<", $script)
        or die "error: failed to access `$script': $!\n";
    while (<GIT_STORE_META>) {
        if (m/^# ={2,}/) {
            if (!$start) { $start = 1; next; }
            else { last; }
        }
        next if !$start;
        s/^# ?//;
        print;
    }
    close(GIT_STORE_META);
}

sub install_hooks {
    # Ensure hook files don't exist unless --force
    if (!$argv{'force'}) {
        my $err = '';
        foreach my $n ("pre-commit", "post-checkout", "post-merge") {
            my $f = "$gitdir/hooks/$n";
            if (-e "$f") {
                $err .= "error: hook file `$f' already exists.\n";
            }
        }
        if ($err) { die $err . "Add --force to overwrite current hook files.\n"; }
    }

    # Install the hooks
    my $mask = umask; if (!defined($mask)) { $mask = 0022; }
    my $mode = 0777 & ~$mask;
    my $t;
    my $s = escapeshellarg($GIT_STORE_META_APP . ".pl");
    my $f = defined($argv{'target'}) ? " -t " . escapeshellarg($argv{'target'}) : "";
    my $f2 = escapeshellarg(defined($argv{'target'}) ? $argv{'target'} : $GIT_STORE_META_FILENAME);

    $t = "$gitdir/hooks/pre-commit";
    open(FILE, '>', $t) or die "error: failed to write to `$t': $!\n";
    printf FILE <<'EOF', $s, $f, $f2;
#!/bin/sh
# when running the hook, cwd is the top level of working tree

script=$(dirname "$0")/%1$s
[ ! -x "$script" ] && script=%1$s

# update (or store as fallback) the cache file if it exists
if [ -f %3$s ]; then
    "$script" --update%2$s ||
    "$script" --store%2$s ||
    exit 1

    # remember to add the updated cache file
    git add %3$s
fi
EOF
    close(FILE);
    chmod($mode, $t) == 1 or die "error: failed to set permissions on `$t': $!\n";
    print "created `$t'\n";

    $t = "$gitdir/hooks/post-checkout";
    open(FILE, '>', $t) or die "error: failed to write to `$t': $!\n";
    printf FILE <<'EOF', $s, $f;
#!/bin/sh
# when running the hook, cwd is the top level of working tree

script=$(dirname "$0")/%1$s
[ ! -x "$script" ] && script=%1$s

sha_old=$1
sha_new=$2
change_br=$3

# apply metadata only when HEAD is changed
if [ ${sha_new} != ${sha_old} ]; then
    "$script" --apply%2$s
fi
EOF
    close(FILE);
    chmod($mode, $t) == 1 or die "error: failed to set permissions on `$t': $!\n";
    print "created `$t'\n";

    $t = "$gitdir/hooks/post-merge";
    open(FILE, '>', $t) or die "error: failed to write to `$t': $!\n";
    printf FILE <<'EOF', $s, $f;
#!/bin/sh
# when running the hook, cwd is the top level of working tree

script=$(dirname "$0")/%1$s
[ ! -x "$script" ] && script=%1$s

is_squash=$1

# apply metadata after a successful non-squash merge
if [ $is_squash -eq 0 ]; then
    "$script" --apply%2$s
fi
EOF
    close(FILE);
    chmod($mode, $t) == 1 or die "error: failed to set permissions on `$t': $!\n";
    print "created `$t'\n";
}

sub get_cache_header_info {
    -e $git_store_meta_file or return;
    $cache_file_exist = 1;

    -f $git_store_meta_file and open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or return;
    $cache_file_accessible = 1;

    # first line: retrieve the header
    my $line = <GIT_STORE_META_FILE>;
    $line or return;
    chomp($line);
    my ($prefix, $app, $version, $configs) = split("\t", $line);
    $prefix eq $GIT_STORE_META_PREFIX or return;
    $cache_app = $app;
    eval { $cache_version = version->parse("v" . $version); } or return;

    if (defined($configs)) {
        foreach (split(/\s+/, $configs)) {
            if (m/^--([^=\s]+)=([^=\s]+)$/) {
                $cache_configs{$1} = $2;
            } elsif (m/^--([^=\s]+)$/) {
                $cache_configs{$1} = 1;
            }
        }
    }

    # second line: retrieve the fields
    $line = <GIT_STORE_META_FILE>;
    $line or return;
    chomp($line);
    foreach (split("\t", $line)) {
        m/^<(.*)>$/ and push(@cache_fields, $1) or return;
    }

    # check for existence of "file" and "type" fields
    grep { $_ eq 'file' } @cache_fields or return;
    grep { $_ eq 'type' } @cache_fields or return;

    close(GIT_STORE_META_FILE);
    $cache_header_valid = 1;
}

sub has_directory_entry {
    open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or die;
    my $count = 0;
    while (<GIT_STORE_META_FILE>) {
        next if ++$count <= 2;  # skip first 2 lines
        s/^\s+//; s/\s+$//;
        next if $_ eq "";
        return 1 if (split "\t")[1] eq "d";
    }
    return 0;
}

sub get_file_metadata {
    my ($file, $fields) = @_;
    my @fields = @{$fields};

    my @rec;
    my $type = get_file_type($file);
    return @rec if !$type;  # skip unsupported "file" types

    # evaluate stat, which is almost always used
    my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks) = lstat($file);

    # output formatted data
    # @TODO: further optimization to prevent a possible long condition checking?
    foreach (@fields) {
        if ($_ eq "file") {
            push(@rec, escape_filename($file));
        } elsif ($_ eq "type") {
            push(@rec, $type);
        } elsif ($_ eq "mtime") {
            push(@rec, timestamp_to_gmtime($mtime));
        } elsif ($_ eq "atime") {
            push(@rec, timestamp_to_gmtime($atime));
        } elsif ($_ eq "mode") {
            $mode = sprintf("%04o", $mode & 07777);
            $mode = "0664" if $type eq "l";  # symlinks do not apply mode, but use 0664 if checked out as a plain file
            push(@rec, $mode);
        } elsif ($_ eq "uid") {
            push(@rec, $uid);
        } elsif ($_ eq "gid") {
            push(@rec, $gid);
        } elsif ($_ eq "user") {
            my $user = getpwuid($uid);
            push(@rec, $user || "");
        } elsif ($_ eq "group") {
            my $group = getgrgid($gid);
            push(@rec, $group || "");
        } elsif ($_ eq "acl") {
            push(@rec, &$getfacl($file));
        }
    }
    return @rec;
}

sub store {
    my @fields = @{$argv{'fields'}};
    my %fields_used = map { $_ => 1 } @fields;

    # read the file list and write retrieved metadata to a temp file
    open(TEMP_FILE, ">", $temp_file) or die;
    list: {
        # set input record separator for chomp
        local $/ = "\0";
        open(CMD, "$GIT ls-files -s -z |") or die;
        while(<CMD>) {
            chomp;
            next if m/^160000 /;  # skip submodules
            s/^.*?\t//;  # remove fields other than filename
            next if $_ eq $git_store_meta_filename;  # skip data file
            $_ = join("\t", get_file_metadata($_, \@fields));
            print TEMP_FILE "$_\n" if $_;
        }
        close(CMD);
        if ($argv{'directory'}) {
            open(CMD, "$GIT ls-tree -rd -z \$($GIT write-tree) |") or die;
            while(<CMD>) {
                chomp;
                next if m/^160000 /;  # skip submodules
                s/^.*?\t//;  # remove fields other than filename
                $_ = join("\t", get_file_metadata($_, \@fields));
                print TEMP_FILE "$_\n" if $_;
            }
            close(CMD);
            if ($argv{'topdir'}) {
                $_ = join("\t", get_file_metadata(".", \@fields));
                print TEMP_FILE "$_\n" if $_;
            }
        }
    }
    close(TEMP_FILE);

    # output sorted entries
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    open(CMD, "LC_ALL=C sort <".escapeshellarg($temp_file)." |") or die;
    while (<CMD>) { print; }
    close(CMD);

    # clean up
    unlink($temp_file);
}

sub update {
    my @fields = @{$argv{'fields'}};
    my %fields_used = map { $_ => 1 } @fields;

    # append new entries to the temp file
    open(TEMP_FILE, ">>", $temp_file) or die;
    list: {
        # set input record separator for chomp
        local $/ = "\0";
        # go through the diff list and append entries
        open(CMD, "$GIT diff --name-status --cached --no-renames --ignore-submodules=all -z |") or die;
        while(my $stat = <CMD>) {
            chomp($stat);
            my $file = <CMD>;
            chomp($file);
            if ($stat eq "M") {
                # a modified file
                print TEMP_FILE escape_filename($file)."\0\2M\0\n";
            } elsif ($stat eq "A") {
                # an added file
                print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                # mark ancestor directories as modified
                if ($argv{'directory'}) {
                    my @parts = split("/", $file);
                    pop(@parts);
                    while ($#parts >= 0) {
                        $file = join("/", @parts);
                        print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                        pop(@parts);
                    }
                }
            } elsif ($stat eq "D") {
                # a deleted file
                print TEMP_FILE escape_filename($file)."\0\0D\0\n";
                # mark ancestor directories as deleted (temp and revertable)
                # mark parent directory as modified
                if ($argv{'directory'}) {
                    my @parts = split("/", $file);
                    pop(@parts);
                    if ($#parts >= 0) {
                        $file = join("/", @parts);
                        print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                    }
                    while ($#parts >= 0) {
                        $file = join("/", @parts);
                        print TEMP_FILE escape_filename($file)."\0\0D\0\n";
                        pop(@parts);
                    }
                }
            }
        }
        close(CMD);
        # add all directories as a placeholder, which prevents deletion
        if ($argv{'directory'}) {
            open(CMD, "$GIT ls-tree -rd --name-only -z \$($GIT write-tree) |") or die;
            while(<CMD>) { chomp; print TEMP_FILE "$_\0\1H\0\n"; }
            close(CMD);

            # update topdir
            if ($argv{'topdir'}) {
                print TEMP_FILE ".\0\2M\0\n";
            }
        }
    }
    close(TEMP_FILE);

    # output sorted entries
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    my $cur_line = "";
    my $cur_file = "";
    my $cur_stat = "";
    my $last_file = "";
    open(CMD, "LC_ALL=C sort <".escapeshellarg($temp_file)." |") or die;
    # Since sorted, same paths are grouped together, with the changed entries
    # sorted prior.
    # We print the first seen entry and skip subsequent entries with a same
    # path, so that the original entry is overwritten.
    while ($cur_line = <CMD>) {
        chomp($cur_line);
        if ($cur_line =~ m/\x00[\x00-\x02]+(\w+)\x00/) {
            # has mark: a changed entry line
            $cur_stat = $1;
            $cur_line =~ s/\x00[\x00-\x02]+\w+\x00//;
            $cur_file = $cur_line;
            if ($cur_stat eq "D") {
                # a delete => clear $cur_line so that this path is not printed
                $cur_line = "";
            } elsif ($cur_stat eq "H") {
                # a placeholder => revert previous "delete"
                # This is after a delete (optionally) and before a modify or
                # no-op line (must). We clear $last_file so the next line will
                # see a "path change" and be printed.
                $last_file = "";
                next;
            }
        } else {
            # a no-op line
            $cur_stat = "";
            ($cur_file) = split("\t", $cur_line);
            $cur_line .= "\n";
        }

        # print for a new file
        if ($cur_file ne $last_file) {
            if ($cur_stat eq "M") {
                # a modify => retrieve file metadata to print
                if ($cur_file eq $git_store_meta_filename) {
                    # skip data file
                    $cur_line = "";
                } else {
                    $_ = join("\t", get_file_metadata(unescape_filename($cur_file), \@fields));
                    $cur_line = $_ ? "$_\n" : "";
                }
            }
            print $cur_line;
            $last_file = $cur_file;
        }
    }
    close(CMD);
}

sub apply {
    my @fields = @{$argv{'fields'}};
    my %fields_used = map { $_ => 1 } @fields;

    # v1.0.0 ~ v2.2.* share same apply procedure
    # (files with a bad file name recorded in 1.0.* will be skipped)
    # (files with a bad group name recorded in < 2.2.0 will be used)
    if (1.0.0 <= $cache_version && $cache_version < 2.3.0) {
        open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or die;

        # skip first 2 lines (header)
        <GIT_STORE_META_FILE>;
        <GIT_STORE_META_FILE>;

        while (<GIT_STORE_META_FILE>) {
            chomp;
            next if m/^\s*$/;

            # for each line, parse the record
            my @rec = split("\t", $_, -1);
            my %data;
            for (my $i=0; $i<=$#cache_fields; $i++) {
                $data{$cache_fields[$i]} = $rec[$i];
            }

            # check for existence and type
            my $File = $data{'file'};  # escaped version, for printing
            my $file = unescape_filename($File);  # unescaped version, for using
            next if $file eq $git_store_meta_filename;  # skip data file
            if (! -e $file && ! -l $file) {  # -e tests symlink target instead of the symlink itself
                warn "warn: `$File' does not exist, skip applying metadata\n";
                next;
            }
            my $type = $data{'type'};
            # a symbolic link could be checked out as a plain file, simply see them as equal
            if ($type eq "f" || $type eq "l" ) {
                if (! -f $file && ! -l $file) {
                    warn "warn: `$File' is not a file, skip applying metadata\n";
                    next;
                }
            } elsif ($type eq "d") {
                if (! -d $file) {
                    warn "warn: `$File' is not a directory, skip applying metadata\n";
                    next;
                }
                if (!$argv{'directory'}) {
                    next;
                }
                if ($file eq "." && !$argv{'topdir'}) {
                    next;
                }
            } else {
                warn "warn: `$File' is recorded as an unknown type, skip applying metadata\n";
                next;
            }

            # apply metadata
            my $check = 0;
            if (($fields_used{'user'} && $data{'user'} ne "") || 
                    ($fields_used{'uid'} && $data{'uid'} ne "") || 
                    ($fields_used{'group'} && $data{'group'} ne "") || 
                    ($fields_used{'gid'} && $data{'gid'} ne "")) {
                my $uid;
                my $user; # for display
                if ($fields_used{'user'} && $data{'user'} ne "") {
                    $user = $data{'user'};
                    $uid = (getpwnam($data{'user'}))[2];
                }
                if (!defined($uid) && ($fields_used{'uid'} && $data{'uid'} ne "")) {
                    $user = $data{'uid'};
                    $uid = $data{'uid'};
                }
                $user = defined($uid) ? $user : "-";

                my $gid;
                my $group; # for display
                if ($fields_used{'group'} && $data{'group'} ne "") {
                    $group = $data{'group'};
                    $gid = (getgrnam($data{'group'}))[2];
                }
                if (!defined($gid) && ($fields_used{'gid'} && $data{'gid'} ne "")) {
                    $group = $data{'gid'};
                    $gid = $data{'gid'};
                }
                $group = defined($gid) ? $group : "-";

                print "`$File' set user/group to $user/$group\n" if $argv{'verbose'};
                if (!$argv{'dry-run'}) {
                    $check = (defined($uid) || defined($gid)) ? &$chown($uid, $gid, $file) : 1;
                } else {
                    $check = 1;
                }
                warn "warn: `$File' cannot set user/group to $user/$group\n" if !$check;
            }
            if ($fields_used{'mode'} && $data{'mode'} ne "" && ! -l $file) {
                my $mode = oct($data{'mode'}) & 07777;
                print "`$File' set mode to $data{'mode'}\n" if $argv{'verbose'};
                $check = !$argv{'dry-run'} ? chmod($mode, $file) : 1;
                warn "warn: `$File' cannot set mode to $data{'mode'}\n" if !$check;
            }
            if ($fields_used{'acl'} && $data{'acl'} ne "") {
                print "`$File' set acl to $data{'acl'}\n" if $argv{'verbose'};
                if (!$argv{'dry-run'}) {
                    $check = &$setfacl($data{'acl'}, $file);
                } else {
                    $check = 1;
                }
                warn "warn: `$File' cannot set acl to $data{'acl'}\n" if !$check;
            }
            if (($fields_used{'mtime'} && $data{'mtime'} ne "") || 
                    ($fields_used{'atime'} && $data{'atime'} ne "")) {
                my $atime = $data{'atime'};
                my $mtime = $data{'mtime'};
                my $atime_ = $atime || '-';
                my $mtime_ = $mtime || '-';
                print "`$File' set atime/mtime to $atime_/$mtime_\n" if $argv{'verbose'};
                if (!$argv{'dry-run'}) {
                    $check = &$touch($atime, $mtime, $file);
                } else {
                    $check = 1;
                }
                warn "warn: `$File' cannot set atime/mtime to $atime_/$mtime_\n" if !$check;
            }
        }
        close(GIT_STORE_META_FILE);
    } else {
        die "error: `$git_store_meta_file' is using an unsupported version: $cache_version\n";
    }
}
