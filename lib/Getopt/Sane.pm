package Getopt::Sane;

use v5.18;
use Carp ();
use List::MoreUtils qw/all/;
use Mouse::Util::TypeConstraints;

sub new {
    my ($class, %descriptions) = @_;

    my $self = bless +{
        aliases => +{},
        descriptions => +{},
        required_option_names => [],
    } => $class;

    $self->options(%descriptions) if keys %descriptions != 0;

    return $self;
}

sub aliases { $_[0]->{aliases} }

sub descriptions { $_[0]->{descriptions} }

sub options {
    my ($self, %descriptions) = @_;

    for my $option_name (keys %descriptions) {
        if ($self->resolve_option_name($option_name)) {
            Carp::croak("Duplicated option description: $option_name");
        }

        my $description = $descriptions{$option_name};

        my $aliases = delete $description->{alias} // [];
        for my $alias (ref $aliases ? @$aliases : ($aliases)) {
            if ($self->resolve_option_name($alias)) {
                Carp::croak("Duplicated option description: $alias");
            }
            $self->aliases->{$alias} = $option_name;
        }

        my $type = delete $description->{isa} // 'Any';
        $self->descriptions->{$option_name} = +{
            default_value => delete $description->{default},
            type_constraint => find_type_constraint($type)
                // Carp::croak("Unsupported type: $type"),
        };

        if (delete $description->{required}) {
            push @{ $self->required_option_names }, $option_name;
        }
    }
}

sub parse {
    my ($self, $argv) = @_;

    $argv //= \@ARGV;

    my %parsed;

    while (@$argv) {
        last if $argv->[0] !~ /^-/;

        my $arg = shift @$argv;
        last if $arg eq '--';

        my ($option_name, $value);
        if ($arg =~ /^--no-(.+)$/) {
            ($option_name, $value) = ($1 => 0);
        } elsif ($arg =~ /^--([^=]+)=(.+)$/) {
            ($option_name, $value) = ($1 => $2);
        } elsif ($arg =~ /^--(.+)$/ or $arg =~ /^-(.)$/) {
            $option_name = $1;
            my $type_constraint_name =
                $self->type_constraint_for($option_name)->name;
            if ($type_constraint_name eq 'Bool') {
                $value = 1;
            } elsif (@$argv) {
                $value = shift @$argv;
            } else {
                Carp::croak("Given no value for: $1");
            }
        } elsif ($arg =~ /^-.{2,}$/) {
            my $looks_like_clustered_switches = all {
                my $canonical_name = $self->resolve_option_name($_);
                defined $canonical_name
                    and $self->type_constraint_for($_)->name eq 'Bool';
            } split //, substr($arg, 1);
            if ($looks_like_clustered_switches) {
                unshift @$argv, map { "-$_" } split //, substr($arg, 1);
                redo;
            }

            ($option_name, $value) = $arg =~ /^-(.)(.+)$/;
        } else {
            Carp::croak("Unrecognized option format: $arg");
        }

        $option_name = $self->resolve_option_name($option_name);
        my $type_constraint = $self->type_constraint_for($option_name);
        if ($type_constraint->is_a_type_of('ArrayRef')) {
            push @{ $parsed{$option_name} //= [] }, $value;
        } elsif (exists $parsed{$option_name}) {
            Carp::croak("Option given twice: $option_name");
        } else {
            $parsed{$option_name} = $value;
        }
    }

    for my $option_name (keys %{ $self->descriptions }) {
        my $default_value = $self->descriptions->{$option_name}{default_value};
        next unless defined $default_value;
        $parsed{$option_name} //= $default_value;
    }

    my @missing_mandatory_option_names = sort grep {
        not exists $parsed{$_};
    } @{ $self->required_option_names };
    if (@missing_mandatory_option_names) {
        Carp::croak(
            'Missing mandatory option(s): ',
            join(', ', @missing_mandatory_option_names,),
        );
    }

    for my $option_name (keys %parsed) {
        my $value = $parsed{$option_name};
        my $type_constraint = $self->type_constraint_for($option_name);
        unless ($type_constraint->check($value)) {
            my $type = $type_constraint->name;
            Carp::croak("Type check failed; $value is not a $type.");
        }
    }

    return \%parsed;
}

sub resolve_option_name {
    my ($self, $option_name) = @_;

    return $option_name if exists $self->descriptions->{$option_name};
    return $self->aliases->{$option_name};
}

sub required_option_names { $_[0]->{required_option_names} }

sub type_constraint_for {
    my ($self, $option_name) = @_;

    $option_name = $self->resolve_option_name($option_name);
    $self->descriptions->{$option_name}{type_constraint};
}

1;
