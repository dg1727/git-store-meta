#!/usr/bin/perl -w
#
# =============================================================================
# Usage:  git-store-meta.pl ACTION [OPTION...]
# Store, update, or apply metadata for files revisioned by Git.  Switch CWD to
# the top level of a Git working tree before running this script.
#
# ACTION is one of:
#   -s, --store        Store the metadata for all files.  
#                      (Run --store on first use to initialize the metadata 
#                      store file.)
#   -u, --update       Update the metadata for changed files.  
#   -a, --apply        Apply the metadata stored in the data file to CWD.  
#   -h, --help         Print this help and exit (not subject to -q option).  
#
# Available OPTIONs are:
#   -f, --field FIELDS Fields to store or apply (see FIELDS list, below).  
#                      Default is to pick all fields that are in the current 
#                      store file.  When initializing the store file (first run 
#                      of --store), the default is to use all fields that are 
#                      in the FIELDS list below.  
#   -d, --directory    (!) Also store, update, or apply for directories; on by 
#                      default.  
#       --noexec       Same as "--dry-run", below.  "--noexec" is deprecated 
#                      and may be removed in the future.  
#   -n, --dry-run      (!) Run a test and print the output, without real 
#                      action.  
#   -v, --verbose      (!) Verbose output (currently for the --apply action 
#                      only).  
#   -q, --quiet        (!) Don't print anything on STDOUT.  Given twice [such 
#                      as -qq] = no STDERR either.  If both -v and -q are 
#                      given, the one given last takes precedence.  Options -n 
#                      and -q can both be given, which might be used for 
#                      testing.  
#   -t, --target FILE  Set another data file path.  
#
# Long OPTIONs marked with (!) may be negated with --no or --no- (for example, 
# --nodirectory), but there isn't a one-letter (short) version to negate them.  
# Negating --verbose or --quiet resets the output to default verbosity.  
#
# FIELDS is a comma-separated string consisting of values from this list:
#   mtime   last modified time
#   atime   last access time
#   mode    Unix permissions
#   user    user name
#   group   group name
#   uid     user id (if user is also set, attempt to apply user first, and then
#           fallback to uid)
#   gid     group id (if group is also set, attempt to apply group first, and
#           then fallback to gid)
#   acl     access control lists for setfacl/getfacl
#
# git-store-meta 1.2.1
# Copyright (c) 2015-2017, Danny Lin
# Released under MIT License
# Project home: http://github.com/danny0838/git-store-meta
#
# =============================================================================

use utf8;
use strict;
# use diagnostics;  # useful for debugging syntax errors 

use Getopt::Long;
Getopt::Long::Configure qw(gnu_getopt);
use POSIX qw( strftime );
use Time::Local;

# define constants
my $GIT_STORE_META_PREFIX    = "# generated by";
my $GIT_STORE_META_APP       = "git-store-meta";
my $GIT_STORE_META_VERSION   = "1.2.1";
# if updating $GIT_STORE_META_VERSION, please update in comment header also 
my $GIT_STORE_META_FILE      = ".git_store_meta";
my $GIT                      = "git";

# environment variables
my $topdir = qx[$GIT rev-parse --show-cdup 2>/dev/null] || undef;
chomp($topdir) if defined($topdir);
my $git_store_meta_file = $GIT_STORE_META_FILE;
my $git_store_meta_header = join("\t", $GIT_STORE_META_PREFIX,
                                 $GIT_STORE_META_APP, $GIT_STORE_META_VERSION) . "\n";
my $script = __FILE__;
my $temp_file = $git_store_meta_file . ".tmp" . time;

# parse arguments
my %argv = (
    "store"      => 0,
    "update"     => 0,
    "apply"      => 0,
    "help"       => 0,
    "field"      => "",
    "directory"  => 1,
    "dry-run"    => 0,
    "verbose"    => 0,
    "quiet"      => 0,
    "target"     => "",
);
GetOptions(
    "store|s",      \$argv{'store'},
    "update|u",     \$argv{'update'},
    "apply|a",      \$argv{'apply'},
    "help|h",       \$argv{'help'},
    "field|f=s",    \$argv{'field'},
    "directory|d!", \$argv{'directory'},
    "noexec",       \$argv{'dry-run'}, # disallow --nonoexec, --no-noexec 
    "dry-run|n!",   \$argv{'dry-run'},
    "verbose|v",    sub{ $argv{'verbose'} = 1; $argv{'quiet'} = 0; },
    "quiet|q",      sub{ if($argv{'quiet'} < 2) {$argv{'quiet'}++};
                         $argv{'verbose'} = 0; },
    "noverbose|no-verbose|noquiet|no-quiet",
                    sub{ $argv{'verbose'} = 0; $argv{'quiet'} = 0; },
    "target|t=s",   \$argv{'target'},
);

# -----------------------------------------------------------------------------

sub my_exit {
  if ($argv{'quiet'} >= 2) {
    exit 1;
  }
  else {
    die @_;
  }
}

sub get_file_type {
    my ($file) = @_;
    if (-l $file) {
        return "l";
    }
    elsif (-f $file) {
        return "f";
    }
    elsif (-d $file) {
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
    $gmtime =~ m!^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$!;
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
    $str =~ s!([\x00-\x1F\x5C\x7F])!'\x'.sprintf("%02X", ord($1))!eg;
    return $str;
}

# reverse of escape_filename
# "\\" should never happen, but is supported for backward compatibility
sub unescape_filename {
    my ($str) = @_;
    $str =~ s!\\(?:x([0-9A-Fa-f]{2})|\\)!$1?chr(hex($1)):"\\"!eg;
    return $str;
}

# Print the initial comment block, from first to second "# ==",
# with "# " removed
sub usage {
    my $start = 0;
    # qx[chmod -r $script];  # for testing the following error message 
    open(GIT_STORE_META, "<", $script) or my_exit(
      "Unable to read the script file itself to extract help text:\n$script\n");
    while (my $line = <GIT_STORE_META>) {
        if ($line =~ m!^# ={2,}!) {
            if (!$start) { $start = 1; next; }
            else { last; }
        }
        if ($start) {
            $line =~ s/^# ?//;
            print $line;
        }
    }
    close(GIT_STORE_META);
}

# return the header and fields info of a file
sub get_cache_header_info {
    my ($file) = @_;

    my $cache_file_exist = 0;
    my $cache_file_accessible = 0;
    my $cache_header_valid = 0;
    my $app = "<?app?>";
    my $version = "<?version?>";
    my @fields;
    check: {
        -f $file || last;
        $cache_file_exist = 1;
        open(GIT_STORE_META_FILE, "<", $git_store_meta_file) || last check;
        $cache_file_accessible = 1;
        # first line: retrieve the header
        my $line = <GIT_STORE_META_FILE>;
        $line || last check;
        chomp($line);
        my @parts = split("\t", $line);
        $parts[0] eq $GIT_STORE_META_PREFIX || last check;
        $app = $parts[1];
        $version = $parts[2];
        # seconds line: retrieve the fields
        $line = <GIT_STORE_META_FILE>;
        $line || last check;
        chomp($line);
        @parts = split("\t", $line);
        for (my $i=0; $i<=$#parts; $i++) {
            $parts[$i] =~ m!^<(.*)>$! && push(@fields, $1) || last check;
        }
        (grep { $_ eq 'file' } @fields) || last check;
        (grep { $_ eq 'type' } @fields) || last check;
        close(GIT_STORE_META_FILE);
        $cache_header_valid = 1;
    };
    return ($cache_file_exist, $cache_file_accessible, $cache_header_valid,
            $app, $version, \@fields);
}

sub get_file_metadata {
    my ($file, $fields) = @_;
    my @fields = @{$fields};

    my @rec;
    my $type = get_file_type($file);
    return @rec if !$type;  # skip unsupported "file" types
    my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, 
        $ctime, $blksize, $blocks) = lstat($file);
    my ($user) = getpwuid($uid);
    my ($group) = getgrgid($gid);
    $mtime = timestamp_to_gmtime($mtime);
    $atime = timestamp_to_gmtime($atime);
    $mode = sprintf("%04o", $mode & 07777);

    $mode = "0664" if $type eq "l";
    # symlinks do not apply mode, but use 0664 if checked out as a plain file

    my $cmd = join(" ", ("getfacl", "-cE", escapeshellarg("./$file")));
    my $acl = qx[$cmd]; $acl =~ s/\n+$//; $acl =~ s/\n/,/g;
    my %data = (
        "file"  => escape_filename($file),
        "type"  => $type,
        "mtime" => $mtime,
        "atime" => $atime,
        "mode"  => $mode,
        "uid"   => $uid,
        "gid"   => $gid,
        "user"  => $user,
        "group" => $group,
        "acl"   => $acl,
    );
    # output formatted data
    for (my $i=0; $i<=$#fields; $i++) {
        push(@rec, $data{$fields[$i]});
    }
    return @rec;
}

sub store {
    my ($fields) = @_;
    my @fields = @{$fields};

    # read the file list and write retrieved metadata to a temp file
    open(TEMP_FILE, ">", $temp_file) or my_exit(
      "Unable to open temporary file '${temp_file}' for writing for --store.\n");
    list: {
        local $/ = "\0";
        open(CMD, "$GIT ls-files -z |") or my_exit("'git ls-files' failed.\n");
        while(<CMD>) { chomp;
                       my $s = join("\t", get_file_metadata($_, \@fields));
                       print TEMP_FILE "$s\n" if $s; }
        close(CMD);
        if ($argv{'directory'}) {
            open(CMD, "$GIT ls-tree -rd --name-only -z \$($GIT write-tree) |") or my_exit(
              "'git ls-tree' failed when script was reading directory metadata.\n");
            while(<CMD>) { chomp;
                           my $s = join("\t", get_file_metadata($_, \@fields));
                           print TEMP_FILE "$s\n" if $s; }
            close(CMD);
        }
    }
    close(TEMP_FILE);

    # output sorted entries
    #   The caller uses Perl's select() to direct the output from this to a 
    # file.  
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    open(CMD, "LC_COLLATE=C sort <'$temp_file' |") or my_exit(
      "Sorting of temporary file '${temp_file}' for '--store' failed.\n");
    while (<CMD>) { print; }
    close(CMD);

    # clean up
    my $clear = unlink($temp_file);
}

sub update {
    my ($fields) = @_;
    my @fields = @{$fields};

    # append new entries to the temp file
    open(TEMP_FILE, ">>", $temp_file) or my_exit(
      "Appending to temporary file '${temp_file}' failed.\n");
    list: {
        local $/ = "\0";
        # go through the diff list and append entries
        open(CMD, "$GIT diff --name-status --cached -z |") or my_exit(
          "'git diff' failed.\n");
        while(my $stat = <CMD>) {
            chomp($stat);
            my $file = <CMD>;
            chomp($file);
            if ($stat ne "D") {
                # a modified (including added) file
                print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                # parent directories also mark as modified
                if ($argv{'directory'}) {
                    my @parts = split("/", $file);
                    pop(@parts);
                    while ($#parts >= 0) {
                        $file = join("/", @parts);
                        print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                        pop(@parts);
                    }
                }
            }
            else {
                # a deleted file
                print TEMP_FILE escape_filename($file)."\0\0D\0\n";
                # parent directories also mark as deleted 
                # (temp and could be cancelled) 
                if ($argv{'directory'}) {
                    my @parts = split("/", $file);
                    pop(@parts);
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
            open(CMD, "$GIT ls-tree -rd --name-only -z \$($GIT write-tree) |") or my_exit(
              "'git ls-tree' failed when script was adding directories as a placeholder.\n");
            while(<CMD>) { chomp; print TEMP_FILE "$_\0\1H\0\n"; }
            close(CMD);
        }
        # update $git_store_meta_file if it's in the git working tree
        check_meta_file: {
            my $cmd = join(" ", ($GIT, "ls-files", "--error-unmatch", "-z",
                                 "--", escapeshellarg($git_store_meta_file),
                                 "2>&1"));
            my $file = qx[$cmd];
            if ($? == 0) {
                chomp($file);
                print TEMP_FILE escape_filename($file)."\0\2M\0\n";
            }
        }
    }
    close(TEMP_FILE);

    # output sorted entries
    #   The caller uses Perl's select() to direct the output from this to a 
    # file.  
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    my $cur_line = "";
    my $cur_file = "";
    my $cur_stat = "";
    my $last_file = "";
    open(CMD, "LC_COLLATE=C sort <'$temp_file' |") or my_exit(
      "Sorting of temporary file '${temp_file}' for '--update' failed.\n");
    # Since sorted, same paths are grouped together, with the changed entries
    # sorted prior.
    #   We print the first seen entry and skip subsequent entries that have the 
    # same path, so that the original entry is overwritten.  
    while ($cur_line = <CMD>) {
        chomp($cur_line);
        if ($cur_line =~ m!\x00[\x00-\x02]+(\w+)\x00!) {
            # has mark: a changed entry line
            $cur_stat = $1;
            $cur_line =~ s!\x00[\x00-\x02]+\w+\x00!!;
            $cur_file = $cur_line;
            if ($cur_stat eq "D") {
                # a delete => clear $cur_line so that this path is not printed
                $cur_line = "";
            }
            elsif ($cur_stat eq "H") {
                # a placeholder => recover previous "delete"
                # This is after a delete (optionally) and before a modify or
                # normal line (must). We clear $last_file so the next line will
                # see a "path change" and be printed.
                $last_file = "";
                next;
            }
        }
        else {
            # a normal line
            $cur_stat = "";
            ($cur_file) = split("\t", $cur_line);
            $cur_line .= "\n";
        }
        if ($cur_file ne $last_file) {
            if ($cur_stat eq "M") {
                # a modify => retrieve file metadata to print
                my $s = join("\t",
                             get_file_metadata(unescape_filename($cur_file),
                                               \@fields));
                $cur_line = $s ? "$s\n" : "";
            }
            print $cur_line;
            $last_file = $cur_file;
        }
    }
    close(CMD);
}

sub apply {
  my ($fields_used, $cache_fields, $version) = @_;
  my %fields_used = %{$fields_used};
  my @cache_fields = @{$cache_fields};

  # 1.2.*, 1.1.*, and 1.0.* share same apply procedure
  # (files with a bad file name recorded in 1.0.* will be skipped)
  if (!($version =~ m!^1\.2\..+$! ||
        $version =~ m!^1\.1\..+$! ||
        $version =~ m!^1\.0\..+$!)) {
    my_exit "Error:  current cache uses an unsupported schema, version $version\n";
  }
  else {
    my $count = 0;
    open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or my_exit(
      "Unable to open file '${git_store_meta_file}' for reading for --apply.\n");
    while (my $line = <GIT_STORE_META_FILE>) {
      ++$count <= 2 && next;  # skip first 2 lines (header)
      $line =~ s/^\s+//; $line =~ s/\s+$//;
      next if $line eq "";

      # for each line, parse the record
      my @rec = split("\t", $line);
      my %data;
      for (my $i=0; $i<=$#cache_fields; $i++) {
        $data{$cache_fields[$i]} = $rec[$i];
      }

      # check for existence and type
      my $File = $data{'file'};  # Escaped version, for printing.  
      my $file = unescape_filename($File);  # Unescaped version, for using.  
      if (! -e $file && ! -l $file) {
      # -e tests symlink target instead of the symlink itself
        warn "warn: '${File}' does not exist, skip applying metadata\n";
        next;
      }
      my $type = $data{'type'};
      # a symlink in git could be checked out as a plain file, ...
      # ... simply see them as equal
      if ($type eq "f" || $type eq "l" ) {
        if (! -f $file && ! -l $file) {
          warn "warn: '${File}' is not a file, skip applying metadata\n";
          next;
        }
      }
      elsif ($type eq "d") {
        if (! -d $file) {
          warn "warn: '${File}' is not a directory, skip applying metadata\n";
          next;
        }
        if (!$argv{'directory'}) {
          next;
        }
      }
      else {
        warn "warn: '${File}' is recorded as an unknown type, skip applying metadata\n";
        next;
      }

      # apply metadata
      my $check = 0;
      set_user: {
        if ($fields_used{'user'} && $data{'user'} ne "") {
          my $uid = (getpwnam($data{'user'}))[2];
          my $gid = (lstat($file))[5];
          if ($argv{'verbose'}) {
            print "'${File}' set user to '$data{'user'}'\n" ;
          }
          if ($uid) {
            if (!$argv{'dry-run'}) {
              if (! -l $file) {
                $check = chown($uid, $gid, $file);
              }
              else {
                my $cmd =
                  join(" ", ("chown", "-h", escapeshellarg($data{'user'}),
                             escapeshellarg("./$file"), "2>&1"));
                qx[$cmd]; $check = ($? == 0);
              }
            }
            else { $check = 1; }
            if (!$check) {
              warn "warn: '${File}' cannot set user to '$data{'user'}'\n";
            }
            last set_user if $check;
          }
          else {
            warn "warn: $data{'user'} is not a valid user.\n";
          }
        }
        if ($fields_used{'uid'} && $data{'uid'} ne "") {
          my $uid = $data{'uid'};
          my $gid = (lstat($file))[5];
          print "'${File}' set uid to '$uid'\n" if $argv{'verbose'};
          if (!$argv{'dry-run'}) {
            if (! -l $file) { $check = chown($uid, $gid, $file); }
            else {
              my $cmd =
                join(" ", ("chown", "-h", escapeshellarg($uid),
                           escapeshellarg("./$file"), "2>&1"));
              qx[$cmd]; $check = ($? == 0);
            }
          }
          else { $check = 1; }
            warn "warn: '${File}' cannot set uid to '$uid'\n" if !$check;
        }
      }
      set_group: {
        if ($fields_used{'group'} && $data{'group'} ne "") {
          my $uid = (lstat($file))[4];
          my $gid = (getgrnam($data{'group'}))[2];
          print "'${File}' set group to '$data{'group'}'\n" if $argv{'verbose'};
          if ($gid) {
            if (!$argv{'dry-run'}) {
              if (! -l $file) { $check = chown($uid, $gid, $file); }
              else {
                my $cmd =
                  join(" ", ("chgrp", "-h", escapeshellarg($data{'group'}),
                             escapeshellarg("./$file"), "2>&1"));
                qx[$cmd]; $check = ($? == 0);
              }
            }
            else { $check = 1; }
            if (!$check) {
              warn "warn: '${File}' cannot set group to '$data{'group'}'\n";
            }
            last set_group if $check;
          }
          else { warn "warn: $data{'group'} is not a valid user group.\n"; }
        }
        if ($fields_used{'gid'} && $data{'gid'} ne "") {
          my $uid = (lstat($file))[4];
          my $gid = $data{'gid'};
          print "'${File}' set gid to '$gid'\n" if $argv{'verbose'};
          if (!$argv{'dry-run'}) {
            if (! -l $file) { $check = chown($uid, $gid, $file); }
            else {
              my $cmd =
                join(" ", ("chgrp", "-h", escapeshellarg($gid),
                           escapeshellarg("./$file"), "2>&1"));
              qx[$cmd]; $check = ($? == 0);
            }
          }
          else { $check = 1; }
            warn "warn: '${File}' cannot set gid to '$gid'\n" if !$check;
        }
      }
      if ($fields_used{'mode'} && $data{'mode'} ne "" && ! -l $file) {
        my $mode = oct($data{'mode'}) & 07777;
        print "'${File}' set mode to '$data{'mode'}'\n" if $argv{'verbose'};
        $check = !$argv{'dry-run'} ? chmod($mode, $file) : 1;
        warn "warn: '${File}' cannot set mode to '$data{'mode'}'\n" if !$check;
      }
      if ($fields_used{'acl'} && $data{'acl'} ne "") {
        print "'${File}' set acl to '$data{'acl'}'\n" if $argv{'verbose'};
        if (!$argv{'dry-run'}) {
          my $cmd =
            join(" ", ("setfacl", "-bm", escapeshellarg($data{'acl'}),
                       escapeshellarg("./$file"), "2>&1"));
          qx[$cmd]; $check = ($? == 0);
        }
        else { $check = 1; }
        warn "warn: '${File}' cannot set acl to '$data{'acl'}'\n" if !$check;
      }
      if ($fields_used{'mtime'} && $data{'mtime'} ne "") {
        my $mtime = gmtime_to_timestamp($data{'mtime'});
        my $atime = (lstat($file))[8];
        print "'${File}' set mtime to '$data{'mtime'}'\n" if $argv{'verbose'};
        if (!$argv{'dry-run'}) {
          if (! -l $file) { $check = utime($atime, $mtime, $file); }
          else {
            my $cmd =
              join(" ", ("touch", "-hcmd", escapeshellarg($data{'mtime'}),
                         escapeshellarg("./$file"), "2>&1"));
            qx[$cmd]; $check = ($? == 0);
          }
        }
        else { $check = 1; }
        if (!$check) {
          warn "warn: '${File}' cannot set mtime to '$data{'mtime'}'\n";
        }
      }
      if ($fields_used{'atime'} && $data{'atime'} ne "") {
        my $mtime = (lstat($file))[9];
        my $atime = gmtime_to_timestamp($data{'atime'});
        print "'${File}' set atime to '$data{'atime'}'\n" if $argv{'verbose'};
        if (!$argv{'dry-run'}) {
          if (! -l $file) { $check = utime($atime, $mtime, $file); }
          else {
            my $cmd =
              join(" ", ("touch", "-hcad", escapeshellarg($data{'atime'}),
                         escapeshellarg("./$file"), "2>&1"));
            qx[$cmd]; $check = ($? == 0);
          }
        }
        else { $check = 1; }
        if (!$check) {
          warn "warn: '${File}' cannot set atime to '$data{'atime'}'\n";
        }
      }
    }
    close(GIT_STORE_META_FILE);
  }
}

# -----------------------------------------------------------------------------

sub main {
    # reset cache file if requested
    $git_store_meta_file = $argv{'target'} if ($argv{'target'} ne "");

    # parse header
    my ($cache_file_exist, $cache_file_accessible, $cache_header_valid, $app,
        $version, $cache_fields) = get_cache_header_info($git_store_meta_file);
    my @cache_fields = @{$cache_fields};

    # parse fields list
    my %fields_used = (
        "file"  => 0,
        "type"  => 0,
        "mtime" => 0,
        "atime" => 0,
        "mode"  => 0,
        "uid"   => 0,
        "gid"   => 0,
        "user"  => 0,
        "group" => 0,
        "acl"   => 0,
    );
    my @fields;
    # my @parts;  # See FIXME (below) for why this is commented out 
    # First, put field names into @fields
    #   Use $argv{'field'} if defined, or use fields in the cache file.  
    # Special handling for --update, which must use fields in the cache file.  
    # If none of those 3 cases, then select a default set of fields.  
    # (The logic below isn't written in that order.)  
    if ((!$argv{'field'} && $cache_header_valid) || $argv{'update'}) {
      @fields = @cache_fields;
    }
    else {
      push(@fields, ("file", "type"));
      if (!$argv{'field'}) {
        # runs when $cache_header_valid is false (see enclosing "if")
        for my $a_field ( keys %fields_used ) {
          # Default to all fields.  
          push(@fields, $a_field);
        }
      }
      else {
        push(@fields, split(/,\s*/, $argv{'field'}));
      }
    }
    # Next, use @fields to update %fields_used 
    for my $field (@fields) {
        if (exists($fields_used{$field})) {  # && !$fields_used{$fields[$i]}){
        # FIXME:  Apparently "&& !$fields_used{$fields[$i]}" isn't needed.  
        # If it is needed, hopefully a comment can be added to explain it.  
            $fields_used{$field} = 1;
            # push(@fields, $parts[$i]);
            # FIXME:  Originally there was a separate array called @parts.  
            # But this push() just set @fields equal to @parts, and this @parts 
            # wasn't used after this.  (There is a *local* @parts in some of 
            # the subroutines.)  So this main() now uses @fields for 
            # everything.  Please re-instate @parts if needed!  
        }
    }
    my $field_info = "fields: " . join(", ", @fields) . "; directories: " .
                     ($argv{'directory'} ? "yes" : "no") . "\n";

    # run action
    # priority if multiple assigned:  help > update > store > apply 
    # update must go before store etc. since there's a special assign before
    my $action = "";
    for ('help', 'update', 'store', 'apply') {
      if ($argv{$_}) { $action = $_; last; }
    }
    if ($action eq "help") {
        usage();
    }
    elsif ($action eq "store") {
        if (!$argv{'quiet'}) {
          print "Storing metadata to ${git_store_meta_file} ...\n";
        }
        # validate
        if (!defined($topdir) || $topdir) {
          my_exit "Error:  please switch current working directory to the top level of a Git working tree.\n";
        }
        # do the store
        print $field_info if (!$argv{'quiet'});
        if (!$argv{'dry-run'}) {
            open(GIT_STORE_META_FILE, '>', $git_store_meta_file) or my_exit(
              "Unable to open file '${git_store_meta_file}' for writing for --store.\n");
            select(GIT_STORE_META_FILE);
            store(\@fields);
            close(GIT_STORE_META_FILE);
            select(STDOUT);
        }
        elsif ($argv{'quiet'}) {
          # If control gets here, then both 'quiet' and 'dry-run' are true 
          open(DEV_NULL, ">", "/dev/null") or my_exit(
            "Unable to write to /dev/null.\n");
          select(DEV_NULL);
          store(\@fields);
          close(DEV_NULL);
          select(STDOUT);
        }
        else {
            # 'quiet' is false, but 'dry-run' is true 
            store(\@fields);
        }
    }
    elsif ($action eq "update") {
      if (!$argv{'quiet'}) {
        print "Updating metadata to '${git_store_meta_file}' ...\n";
      }
      # validate
      if (!defined($topdir) || $topdir) {
        my_exit "Error:  please switch current working directory to the top level of a Git working tree.\n";
      }
      if (!$cache_file_exist) {
        my_exit "Error:  '${git_store_meta_file}' doesn't exist.
Run --store to create new.\n";
      }
      if (!$cache_file_accessible) {
        my_exit "Error:  unable to access '${git_store_meta_file}'.\n";
      }
      if ($app ne $GIT_STORE_META_APP) {
        my_exit "Error:  '${git_store_meta_file}' is using another schema: $app $version
Run --store to create new.\n";
      }
      if (!($version =~ m!^1\.2\..+$! || $version =~ m!^1\.1\..+$!)) {
        my_exit "Error:  current cache uses an unsupported schema, version $version\n";
      }
      if (!$cache_header_valid) {
        my_exit "Error:  '${git_store_meta_file}' is malformatted.
Fix it or run --store to create new.\n";
      }
      # do the update
      print $field_info if (!$argv{'quiet'});
      # copy the cache file to the temp file
      # to prevent a conflict in further operation
      open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or my_exit(
        "Unable to open file '${git_store_meta_file}' for reading
when copying to temporary file.\n");
      open(TEMP_FILE, ">", $temp_file) or my_exit(
        "Unable to open temporary file '${temp_file}' for writing for --update.\n");
      my $count = 0;
      while (<GIT_STORE_META_FILE>) {
        if (++$count <= 2) { next; }  # discard first 2 lines
        print TEMP_FILE;
      }
      close(TEMP_FILE);
      close(GIT_STORE_META_FILE);
      # update cache
      if (!$argv{'dry-run'}) {
        open(GIT_STORE_META_FILE, '>', $git_store_meta_file) or my_exit(
          "Unable to open file '${git_store_meta_file}' for writing for --update.\n");
        select(GIT_STORE_META_FILE);
        update(\@fields);
        close(GIT_STORE_META_FILE);
        select(STDOUT);
      }
      else {
        update(\@fields);
      }
      # clean up
      my $clear = unlink($temp_file);
    }
    elsif ($action eq "apply") {
      if (!argv{'quiet'}) {
        print "Applying metadata from '${git_store_meta_file}' ...\n";
      }
      # validate
      if (!$cache_file_exist) {
        if (!argv{'quiet'}) {
          print "'${git_store_meta_file}' doesn't exist, skipped.\n";
        }
        exit;
      }
      if (!$cache_file_accessible) {
        my_exit "Error:  unable to access '${git_store_meta_file}'.\n";
      }
      if ($app ne $GIT_STORE_META_APP) {
        my_exit "Error:  unable to apply metadata using the schema: ${app} ${version}\n";
      }
      if (!$cache_header_valid) {
        my_exit "Error:  $'{git_store_meta_file}' is malformatted.\n";
      }
      # do the apply
      print $field_info if (!argv{'quiet'});
      apply(\%fields_used, \@cache_fields, $version);
    }
    else {
        usage();
        exit 1;
    }
}

main();
