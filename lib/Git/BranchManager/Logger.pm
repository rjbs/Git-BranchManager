package Git::BranchManager::Logger;
# ABSTRACT: logging routines for Git::BranchManager

use v5.26.0;
use warnings;

use Term::ANSIColor ();

use Sub::Exporter -setup => [ qw(
  drat note okay noop
) ];

sub drat { say join q{}, Term::ANSIColor::colored([ 'ansi214'      ], 'DRAT: '), $_[0] }
sub note { say join q{}, Term::ANSIColor::colored([ 'ansi200'      ], 'NOTE: '), $_[0] }
sub okay { say join q{}, Term::ANSIColor::colored([ 'bright_green' ], 'OKAY: '), $_[0] }
sub noop { say join q{}, Term::ANSIColor::colored([ 'ansi105'      ], 'NOOP: '), $_[0] }

# Possibly this one has a dreadful name. -- rjbs, 2021-06-12
sub exec { say join q{}, Term::ANSIColor::colored([ 'ansi51'       ], 'EXEC: '), $_[0] }

1;
