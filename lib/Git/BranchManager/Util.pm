package Git::BranchManager::Util;
# ABSTRACT: helper routines for Git::BranchManager

use v5.36.0;

use Config::INI::Reader;
use List::Util qw(max);
use JSON::MaybeXS qw(decode_json);
use Process::Status;

our $VERBOSE = 0;
our $REALLY  = 0;

use Sub::Exporter -setup => [ qw(
  run get_branches ref_sha ref_tree

  compute_changes
  print_change_plan
  describe_commit
) ];

sub get_config {
  my $path = ".git/config";

  my $loaded = -r $path
             ? Config::INI::Reader->read_file($path)->{'branch-manager'}
             : {};

  unless (keys %$loaded) {
    return guess_config();
  }

  my %config;

  $config{my} = {
    remote => $loaded->{'my-remote'}
           // $ENV{USER}
           // die q{can't determine remote branch},
  };

  $config{primary} = {
    remote => $loaded->{'primary-remote'} // 'origin',
    branch => $loaded->{'primary-branch'} // 'master' # detect main/master?
  };

  $config{branches} = {
    mirrored => [
      grep {; length }
      split /\s+/, ($loaded->{'mirrored-branches'} // "")
    ],
    immortal => [
      grep {; length }
      split /\s+/, ($loaded->{'immortal-branches'} // "")
    ],
  };

  return \%config;
}

sub guess_config {
  my $username = $ENV{USER};

  unless (length $username) {
    die qq{Without knowing a username (\$USER), can't guess branch config.\n};
  }

  my @lines = `git config --get-regexp 'remote\.[a-z0-9]+.url'`;
  Process::Status->assert_ok("getting list of remote URLs");

  chomp @lines;
  my %remote_url = map {; split /\s/, $_ } @lines;

  my %config;

  {
    # guess at my.remote
    my @good;
    for my $remote (sort keys %remote_url) {
      next unless $remote_url{$remote} =~ qr{:\Q$username\E/};
      push @good, $remote;
    }

    unless (@good) {
      die qq{Without an ssh remote for $username, can't guess branch config.\n};
    }

    if (@good > 1) {
      die qq{There's more than one ssh remote for $username: @good\n};
    }

    $good[0] =~ /\Aremote\.([a-z0-9]+)\.url\z/;
    $config{my} = { remote => $1 };
  }

  {
    # guess at primary.remote
    #
    # "What's gitbox?" you ask.  It's the name that I have traditionally used
    # for work's primary remote repository. -- rjbs, 2021-06-17
    my @candidates = qw(github gitbox origin);
    my @has = grep {; exists $remote_url{"remote.$_.url"} }
              @candidates;

    unless (@has) {
      die qq{No candidates for primary remote.  Expected one of: @candidates\n};
    }

    if (@has > 1) {
      die qq{There's more than one possible primary remote: @has\n};
    }

    $config{primary}{remote} = $has[0];
  }

  {
    # guess at primary branch
    my @lines = `git ls-remote --symref $config{primary}{remote} HEAD`;
    Process::Status->assert_ok("getting primary remote HEAD");

    chomp @lines;
    my @matches = map {; m{^ref: refs/heads/(\S+)\tHEAD$}m ? $1 : () } @lines;

    unless (@matches) {
      die "No candidate for primary branch on remote\n";
    }

    if (@matches > 1) {
      die "There's more than one remote head?  This seems impossible.\n";
    }

    $config{primary}{branch} = $matches[0];
  }

  $config{branches}{immortal} = [ $config{primary}{branch} ];

  return \%config;
}

sub get_client_for_remote {
  my ($self, $remote) = @_;

  my $url = `git config remote.$remote.url`;
  Process::Status->assert_ok("getting URL for remote $remote");
  chomp $url;

  my ($host, $user, $project);

  if ($url =~ m{\Agit\@([^:]+):([^/]+)/(.+)\.git\z}) {
    ($host, $user, $project) = ($1, $2, $3);
  } else {
    die "couldn't determine project data for remote $remote at $url";
  }

  require Git::BranchManager::Client;
  return Git::BranchManager::Client->for_project({
    owner => $user,
    repo  => $project,
    host  => $host,
  });
}

sub run {
  my ($cmd, $arg) = @_;
  $cmd .= " >/dev/null 2>&1" unless $VERBOSE;

  if ($arg->{if_really} && ! $REALLY) {
    Git::BranchManager::Logger::exec($cmd);
    return 1;
  }

  system $cmd;
  Process::Status->assert_ok($cmd) if $arg->{or_die};
  return ! $?;
}

sub get_branches {
  die "can't run git: $!"
    unless open my $prog, '-|',
      ('git', 'branch', '--format', '%(refname:short)', @_);

  my @branches = <$prog>;
  close $prog or die "errors reading from git: $!";

  chomp @branches;

  return @branches;
}

sub ref_sha {
  my ($ref) = @_;
  my ($line) = `git rev-parse $ref`;
  chomp $line;
  my ($sha) = split /\s/, $line;
  die "no sha for $ref\n" unless $sha;

  return $sha;
}

sub ref_tree {
  my ($ref) = @_;
  my ($line) = `git rev-parse '$ref^{tree}'`;
  chomp $line;
  my ($sha) = split /\s/, $line;
  die "no sha for tree for $ref\n" unless $sha;

  return $sha;
}

sub compute_changes {
  # We're going to replace the target branch's commits with those on the source
  # branch.  What's the effective set of changes?
  my ($to_push, $to_replace, $main) = @_;

  # to_push     is the source, so "src" variables
  # to_replace  is the target, so "trg" variables

  Carp::croak("no main branch supplied") unless $main;

  my $base = `git merge-base $to_replace $to_push`;
  Process::Status->assert_ok("computing merge base");
  chomp $base;

  my @src_commits = `git log --format='%H' --reverse $main..$to_push`;
  Process::Status->assert_ok("computing commits on $to_push");
  chomp @src_commits;

  my @trg_commits = `git log --format='%H' --reverse $base..$to_replace`;
  Process::Status->assert_ok("computing commits on $to_replace");
  chomp @trg_commits;

  my @plan = (
    [ BASE => $base ],
  );

  for my $i (0 .. (max(0+@trg_commits, 0+@src_commits) - 1)) {
    unless ($trg_commits[$i]) {
      push @plan, [ PLUS => $trg_commits[$i] ];
      next;
    }

    unless ($src_commits[$i]) {
      push @plan, [ DROP => $trg_commits[$i] ];
      next;
    }

    my $trg_patch_id = `git show $trg_commits[$i] | git patch-id --stable`;
    Process::Status->assert_ok("computing patch-id of $trg_commits[$i]");

    my $src_patch_id = `git show $src_commits[$i] | git patch-id --stable`;
    Process::Status->assert_ok("computing patch-id of $src_commits[$i]");

    ($trg_patch_id) = split /\s/, $trg_patch_id;
    ($src_patch_id) = split /\s/, $src_patch_id;

    if ($trg_patch_id eq $src_patch_id) {
      push @plan, [ KEEP => $src_commits[$i] ];
      next;
    }

    push @plan, [ DROP => $trg_commits[$_] ] for $i .. $#trg_commits;
    push @plan, [ PLUS => $src_commits[$_] ] for $i .. $#src_commits;
    last;
  }

  return \@plan;
}

sub describe_commit {
  my ($sha) = @_;

  my ($desc) = split /\v/, scalar(`git show --format='[%h] %s' $sha`);
  Process::Status->assert_ok("describing commit $sha");

  return $desc;
}

my %color;
BEGIN {
  %color = (
    BASE => 'ansi226',
    PLUS => 'bright_green',
    DROP => 'ansi214',
    KEEP => 'ansi141',
  );
}

sub print_change_plan {
  my ($plan) = @_;

  require Term::ANSIColor;

  for my $item (@$plan) {
    my $desc = describe_commit($item->[1]);

    if ($item->[0] eq 'KEEP') {
      $desc =~ s/\A\[([0-9a-f]+)\]/'[' . ('~' x length($1)) . ']'/e;
    }

    my $color = $color{ $item->[0] };
    my $str   = join q{ },
      ($color ? Term::ANSIColor::colored([$color], $item->[0]) : $item->[0]),
      $desc;

    say $str;
  }
}

1;
