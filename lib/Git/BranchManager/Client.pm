package Git::BranchManager::Client;
# ABSTRACT: API clients used by Git::BranchManager

use v5.26.0;
use warnings;

use JSON::MaybeXS;
use LWP::UserAgent;

our $JSON = JSON::MaybeXS->new;

sub for_project {
  my ($factory, $arg) = @_;

  my $new = {
    owner => $arg->{owner},
    repo  => $arg->{repo},
    host  => $arg->{host},
  };

  my $class = $new->{host} eq 'github.com'
            ? 'Git::BranchManager::Client::GitHub'
            : 'Git::BranchManager::Client::GitLab';

  my $self = $class->new($new);

  $self->token; # Be more eager to crash.

  return $self;
}

package Git::BranchManager::Role::Client {
  use Moose::Role;

  has [ qw( owner repo host ) ] => (is => 'ro', required => 1);

  has token => (
    is => 'ro',
    lazy => 1,
    builder => '_build_token',
  );

  requires '_build_token';
  requires 'requests_from_other';
  requires 'request_is_approved'; # request -> boolean

  no Moose::Role;
}

package Git::BranchManager::Client::GitHub {
  use Moose;
  with 'Git::BranchManager::Role::Client';

  sub _build_token {
    my ($self) = @_;

    my $token = $ENV{GITHUB_OAUTH_TOKEN};

    Carp::confess("no GitHub token available")
      unless $token;

    return $token;
  }

  has _lwp => (
    is => 'ro',
    lazy    => 1,
    default => sub {
      my ($self) = @_;
      my $lwp = LWP::UserAgent->new(keep_alive => 5);
      $lwp->default_header(Authorization => 'token ' . $self->token);

      return $lwp;
    },
  );

  sub _api_get {
    my ($self, $path) = @_;

    my $url = q{https://api.github.com} . $path;
    my $res = $self->_lwp->get($url);

    unless ($res->is_success) {
      die "Failed to get $path: " . $res->as_string;
    }

    my $data = eval {
      $JSON->decode($res->decoded_content(charset => undef));
    };

    if ($@) {
      die "Failed to decode JSON from GitHub $path: $@\n" . $res->as_string .  "\n";
    }

    return $data;
  }

  sub requests_from_other {
    my ($self, $other) = @_;

    Carp::confess("can't get requests from incompatible client")
      unless $other->isa('Git::BranchManager::Client::GitHub');

    my $path = join q{/}, '/repos', $self->owner, $self->repo, 'pulls';
    $path .= '?per_page=100&state=open';

    my $pulls = $self->_api_get($path);

    die "pagination not implemented but second page might exist!"
      if @$pulls == 100;

    my %reqs_for_branch;
    for my $pull (@$pulls) {
      my $user = $pull->{head}{user}{login};
      my $head = $pull->{head}{ref};

      next unless $user eq $other->owner;

      push @{ $reqs_for_branch{$head} }, {
        id => $pull->{number},
        labels => [ map {; $_->{name} } ($pull->{labels} // [])->@* ],
        title  => $pull->{title},

        is_draft => $pull->{draft},

        assignees => [
          map {; $_->{login} } ($pull->{assignees} // [])->@*
        ],

        _github_pull => $pull,
      }
    }

    return \%reqs_for_branch;
  }

  sub all_requests {
    my ($self) = @_;

    my $path = join q{/}, '/repos', $self->owner, $self->repo, 'pulls';
    $path .= '?per_page=100&state=open';

    my $pulls = $self->_api_get($path);

    die "pagination not implemented but second page might exist!"
      if @$pulls == 100;

    my %reqs_for_userbranch;
    for my $pull (@$pulls) {
      my $user = $pull->{head}{user}{login};
      my $head = $pull->{head}{ref};

      push @{ $reqs_for_userbranch{"$user/$head"} }, {
        id => $pull->{number},
        labels => [ map {; $_->{name} } ($pull->{labels} // [])->@* ],
        title  => $pull->{title},

        is_draft => $pull->{draft},

        assignees => [
          map {; $_->{login} } ($pull->{assignees} // [])->@*
        ],

        _github_pull => $pull,
      }
    }

    return \%reqs_for_userbranch;
  }

  sub request_is_approved {
    my ($self, $req) = @_;

    my $path = sprintf '/repos/%s/%s/pulls/%s/reviews',
      $self->owner, $self->repo, $req->{id};

    my $pulls = $self->_api_get($path);

    my @approvals = grep {; $_->{state} eq 'APPROVED' } @$pulls;

    return @approvals > 0;
  }

  no Moose;
}

package Git::BranchManager::Client::GitLab {
  use Moose;
  with 'Git::BranchManager::Role::Client';

  sub _build_token {
    my ($self) = @_;
    my $host = $self->host;
    my $var  = $self->host =~ s/\./__/gr;

    my $token = $ENV{"GITLAB_API_TOKEN__$var"};

    Carp::confess("no GitLab token available for host $host")
      unless $token;

    return $token;
  }

  has _lwp => (
    is => 'ro',
    lazy    => 1,
    default => sub {
      my ($self) = @_;
      my $lwp = LWP::UserAgent->new(keep_alive => 5);
      $lwp->default_header('Private-Token' => $self->token);

      return $lwp;
    },
  );

  sub _api_get {
    my ($self, $path) = @_;

    $path =~ s{^/*}{};

    my $url = "https://" . $self->host . "/api/v4/$path";

    my $res = $self->_lwp->get($url);
    unless ($res->is_success) {
      die "Failed to get $path: " . $res->as_string;
    }

    my $data = eval {
      $JSON->decode($res->decoded_content(charset => undef));
    };

    if ($@) {
      die "Failed to decode JSON from GitLab $path: $@\n" . $res->as_string .  "\n";
    }

    return $data;
  }

  has _project => (
    is   => 'ro',
    lazy => 1,
    default => sub {
      my ($self) = @_;
      $self->_api_get('/projects/' . $self->owner . '%2F' . $self->repo);
    },
  );

  sub requests_from_other {
    my ($self, $other) = @_;

    my %reqs_for_branch;

    Carp::confess("can't get requests from incompatible client")
      unless $other->isa('Git::BranchManager::Client::GitLab')
      &&     $other->host eq $self->host;

    my $target_id = $self->_project->{id};
    my $source_id = $other->_project->{id};

    # Look, if we have more than 500 open MRs, something is not great.  I just
    # don't want to futz around with the pagination logic. -- rjbs, 2020-06-07
    for my $page (1 .. 5) {
      Git::BranchManager::Logger::note("Getting page $page of merge requests...");
      my $reqs = $self->_api_get("/projects/$target_id/merge_requests?state=opened&per_page=100&page=$page");

      last unless @$reqs;

      for my $req (@$reqs) {
        next unless $req->{source_project_id} == $source_id;
        my $sb = $req->{source_branch};

        push @{ $reqs_for_branch{ $sb } }, {
          id     => $req->{iid},
          labels => $req->{labels},
          title  => $req->{title},

          is_draft => scalar($req->{title} =~ /\Adraft:/i),

          assignees => [
            map {; $_->{username} } ($req->{assignees} // [])->@*
          ],

        };
      }
    }

    return \%reqs_for_branch;
  }

  sub request_is_approved {
    my ($self, $req) = @_;

    my $target_id = $self->_project->{id};

    # /projects/:id/merge_requests/:merge_request_iid/approval_state
    my $req_approval = $self->_api_get("/projects/$target_id/merge_requests/$req->{id}/approvals");

    return $req_approval->{approved_by}->@* > 0;
  }

  no Moose;
}

1;
