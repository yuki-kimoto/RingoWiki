package Ringowiki::Api::Admin::Wiki;
use Mojo::Base 'Mojolicious::Controller';

sub add {
  my $self = shift;
  
  
  
  
  
  $self->render(json => {success => 1});
}

1;