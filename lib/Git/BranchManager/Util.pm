package Git::BranchManager::Util;
# ABSTRACT: helper routines for Git::BranchManager

use v5.26.0;
use warnings;

use Config::INI::Reader;
use JSON::MaybeXS qw(decode_json);

our $VERBOSE = 0;
our $REALLY  = 0;

use Sub::Exporter -setup => [ qw(
  run get_branches ref_sha ref_tree
) ];

sub get_config {
  my $path = ".git/config";

  my $loaded = -r $path
             ? Config::INI::Reader->read_file($path)->{'branch-manager'}
             : {};

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
  my ($line) = `git show-ref $ref`;
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

1;
