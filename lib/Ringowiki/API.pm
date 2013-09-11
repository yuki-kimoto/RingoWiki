package Ringowiki::API;
use Mojo::Base 'Mojolicious::Controller';
use utf8;
use Text::Diff 'diff';
use Text::Markdown 'markdown';
use Ringowiki::HTMLFilter;

use Digest::MD5 'md5_hex';

has 'cntl';

our $TABLE_INFOS = {
  setup => [],
  wiki => [
    'id not null unique',
    "title not null default ''",
    "main not null default 0"
  ],
  user => [
    'id not null unique',
    'password not null',
    'admin not null',
    'salt not null'
  ],
  page => [
    'wiki_id not null',
    'name not null',
    "content not null default ''",
    'main not null default 0',
    "ctime not null default ''",
    "mtime not null default ''",
    'unique (wiki_id, name)'
  ],
  page_history => [
    "wiki_id not null default ''",
    "page_name not null default ''",
    "version not null default ''",
    "content_diff not null default ''",
    "user not null default ''",
    "message not null default ''",
    "ctime not null default ''",
    "unique (wiki_id, page_name, version)"
  ]
};

sub app { shift->cntl->app }

sub encrypt_password {
  my ($self, $password) = @_;
  
  my $salt;
  $salt .= int(rand 10) for (1 .. 40);
  my $password_encryped = md5_hex md5_hex "$salt$password";
  
  return ($password_encryped, $salt);
}

sub check_password {
  my ($self, $password, $salt, $password_encrypted) = @_;
  
  return unless defined $password && $salt && $password_encrypted;
  
  return md5_hex(md5_hex "$salt$password") eq $password_encrypted;
}

sub new {
  my ($class, $cntl) = @_;

  my $self = $class->SUPER::new(cntl => $cntl);
  
  return $self;
}

sub logined_admin {
  my $self = shift;

  # Controler
  my $c = $self->cntl;
  
  # Check logined as admin
  my $user = $c->session('user');
  
  return $self->app->manager->is_admin($user) && $self->logined($user);
}

sub logined {
  my ($self, $user) = @_;
  
  my $c = $self->cntl;
  
  my $dbi = $c->app->dbi;
  
  my $current_user = $c->session('user');
  my $password = $c->session('password');
  return unless defined $password;
  
  my $correct_password
    = $dbi->model('user')->select('password', id => $current_user)->value;
  return unless defined $correct_password;
  
  my $logined;
  
  if (defined $user) {
    $logined = $user eq $current_user && $password eq $correct_password;
  }
  else {
    $logined = $password eq $correct_password
  }
  
  return $logined;
}

sub params {
  my $self = shift;
  
  my $c = $self->cntl;
  
  my %params;
  for my $name ($c->param) {
    my @values = $c->param($name);
    if (@values > 1) {
      $params{$name} = \@values;
    }
    elsif (@values) {
      $params{$name} = $values[0];
    }
  }
  
  return \%params;
}

sub _init_page {
  my $self = shift;
  
  # DBI
  my $dbi = $self->app->dbi;
  
  # Create home page
  $dbi->connector->txn(sub {
    my $wiki_id = $dbi->model('wiki')->select('id', where => {main => 1})->value;
    
    my $page_name = 'Home';
    $dbi->model('page')->insert(
      {
        wiki_id => $wiki_id,
        name => $page_name,
        content => 'Wikiをはじめよう',
        main => 1
      }
    );
    $dbi->model('page_history')->insert(
      {
        wiki_id => $wiki_id,
        page_name => $page_name,
        version => 1
      }
    );
  });
}

sub create_wiki {
  my $self = shift;
  
  # Validation
  my $raw_params = {map { $_ => $self->param($_) } $self->param};
  my $rule = [
    id => ['word'],
    title => ['any']
  ];
  my $vresult = $self->app->validator->validate($raw_params, $rule);
  return $self->render(json => {success => 0, validation => $vresult->to_hash})
    unless $vresult->is_ok;
  my $params = $vresult->data;
  $params->{title} = '未設定' unless length $params->{title};
  
  # DBI
  my $dbi = $self->app->dbi;
  
  # Transaction
  $dbi->connector->txn(sub {
  
    # Create wiki
    my $mwiki = $dbi->model('wiki');
    $params->{main} = 1 unless $mwiki->select->one;
    $mwiki->insert($params);
    
    # Initialize page
    $self->_init_page;
  });
  
  $self->render(json => {success => 1});
}

sub edit_page {
  my $self = shift;
  
  # Validation
  my $raw_params = {map { $_ => $self->param($_) } $self->param};
  my $rule = [
    wiki_id => ['not_blank'],
    page_name => {require => ''} => ['not_blank'],
    content => ['any']
  ];
  my $vresult = $self->app->validator->validate($raw_params, $rule);
  return $self->render(json => {success => 0, validation => $vresult->to_hash})
    unless $vresult->is_ok;
  my $params = $vresult->data;
  my $wiki_id = $params->{wiki_id};
  my $page_name = $params->{page_name};
  
  # DBI
  my $dbi = $self->app->dbi;
  
  # Transaction
  my $mpage = $dbi->model('page');
  my $mpage_history = $dbi->model('page_history');
  $dbi->connector->txn(sub {

    # Page exists?
    my $page_history = $mpage_history->select(
      id => [$wiki_id, $page_name])->one;
    my $page_exists = $page_history ? 1 : 0;
    
    # Edit page
    if ($page_exists) {
      # Content
      my $page = $mpage->select(id => [$wiki_id, $page_name])->one;
      my $content = $page->{content};
      my $content_new = $params->{content};
    
      # No change
      return $self->render_json({success => 1})
        if $content eq $content_new;
      
      # Content diff
      my $content_diff = diff(\$content, \$content_new, {STYLE => 'Unified'});
      my $max_version = $mpage_history->select(
        'max(version) as max',
        id => [$wiki_id, $page_name]
      )->value;
      
      # Create page history
      $mpage_history->insert(
        {content_diff => $content_diff, version => $max_version + 1},
        id => [$wiki_id, $page_name]
      );
      
      # Update page
      $mpage->update(
        {content => $content_new},
        id => [$wiki_id, $page_name]
      );
    }
    # Create page
    else {
      my $content_new = $params->{content};
      my $empty = '';

      my $content_diff = diff \$empty, \$content_new, {STYLE => 'Unified'};
      $mpage_history->insert(
        {wiki_id => $wiki_id, page_name => $page_name, version => 1});
      $mpage->insert(
        {wiki_id => $wiki_id, name => $page_name, content => $content_new});
    }
  });
  if ($@) {
    $self->app->log->error($@);
    return $self->render(json => {success => 0});
  }
  
  # Render
  $self->render(json => {success => 1});
}

sub init {
  my $self = shift;
  
  my $dbi = $self->app->dbi;
  
  my $table_infos = $dbi->select(
    column => 'name',
    table => 'main.sqlite_master',
    where => "type = 'table' and name <> 'sqlite_sequence'"
  )->all;
  
  eval {
    $dbi->connector->txn(sub {
      for my $table_info (@$table_infos) {
        my $table = $table_info->{name};
        $self->app->dbi->execute("drop table $table");
      }
    });
  };
  
  my $success = !$@ ? 1 : 0;
  return $self->render_json({success => $success});
}

sub init_pages {
  my $self = shift;
  
  # DBI
  my $dbi = $self->app->dbi;
  
  eval {
    # Remove all page
    $dbi->connector->txn(sub {
      
      # Remove pages
      $dbi->model('page')->delete_all;
      
      # Remove page histories
      $dbi->model('page_history')->delete_all;
      
      # Initialize page
      $self->_init_page;
    });
  };
  
  if ($@) {
    $self->app->log->error($@);
    return $self->render(json => {success => 0});
  }
  
  return $self->render(json => {success => 1});
}

sub setup {
  my $self = shift;
  
  # Validation
  my $params = {map { $_ => $self->param($_) } $self->param};
  my $rule = [
    admin_user
      => {message => '管理者IDが入力されていません。'}
      => ['not_blank'],
    admin_password1
      => {message => '管理者パスワードが入力されていません。'}
      => ['ascii'],
    {admin_password => [qw/admin_password1 admin_password2/]}
       => {message => 'パスワードが一致しません。'}
       => ['duplication']
  ];
  my $vresult = $self->app->validator->validate($params, $rule);
  return $self->render_json({success => 0, validation => $vresult->to_hash})
    unless $vresult->is_ok;
  
  # DBI
  my $dbi = $self->app->dbi;
  
  # Create tables
  $dbi->connector->txn(sub {
    $self->_create_table($_, $TABLE_INFOS->{$_}) for keys %$TABLE_INFOS;
  });
  
  $self->render(json => {success => 1});
}

sub _create_table {
  my ($self, $table, $columns) = @_;
  
  # DBI
  my $dbi = $self->app->dbi;
  
  # Check table existance
  my $table_exist = 
    eval { $dbi->select(table => $table, where => '1 <> 1'); 1};
  
  # Create table
  $columns = ['rowid integer primary key autoincrement', @$columns];
  unless ($table_exist) {
    my $sql = "create table $table (";
    $sql .= join ', ', @$columns;
    $sql .= ')';
    $dbi->execute($sql);
  }
}

sub _get_default_page {
  my ($self, $wiki_id, $page_name) = @_;
  
  #DBI
  my $dbi = $self->app->dbi;
  
  # Wiki id
  unless (defined $wiki_id) {
    $wiki_id = $dbi->model('wiki')->select('id', append => 'order by main desc')->value;
  }
  
  # Page name
  unless (defined $page_name) {
    $page_name = $dbi->model('page')->select(
      'name',
      where => {wiki_id => $wiki_id},
      append => 'order by main desc'
    )->value;
  }
  
  return ($wiki_id, $page_name);
}

sub admin_user {
  my $self = shift;
  
  # Admin user
  my $admin_user = $self->app->dbi->model('user')
    ->select(where => {admin => 1})->one;
  
  return $admin_user;
}

sub is_admin {
  my ($self, $user) = @_;
  
  # Check admin
  my $is_admin = $self->app->dbi->model('user')
    ->select('admin', id => $user)->value;
  
  return $is_admin;
}

sub users {
  my $self = shift;
  
  # Users
  my $users = $self->app->dbi->model('user')->select(
    where => [':admin{<>}',{admin => 1}],
    append => 'order by id'
  )->all;
  
  return $users;
}

sub exists_user {
  my ($self, $user) = @_;
  
  # Exists project
  my $row = $self->app->dbi->model('user')->select(id => $user)->one;
  
  return $row ? 1 : 0;
}

1;
