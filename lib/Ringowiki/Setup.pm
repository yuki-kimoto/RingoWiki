package Ringowiki::Admin;
use Mojo::Base 'Mojolicious::Controller';

sub add {
  my $self = shift;
  
  $self->render;
}

1;