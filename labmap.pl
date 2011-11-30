#! /usr/bin/perl -w

use strict;
use LWP::UserAgent;
use Mojo::DOM;
use Mojo::Log;
use Mojo::JSON;
use Mojolicious::Lite;
use DateTime;
use Net::OpenSSH;

sub terminate;
sub crash;
sub writeusers;

my $json = Mojo::JSON->new;
my $config = plugin Config => {file => 'labmap.conf'};
my $log = Mojo::Log->new( path => $config->{log_file} );
$log->level($config->{log_level});
$SIG{__DIE__} = \&crash;
#my $log = Mojo::Log->new();
if (!$config->{groups}) { $log->fatal('No groups specified.') }
$SIG{TERM} = \&terminate;
$SIG{INT} = \&terminate;

my @sshopts = ();
while ((my $opt, my $value) = each(%{$config->{ssh_opts}})) {
  push @sshopts, ('-o' => "$opt $value");
}

my %users;
my %image;

if (open JSON, '<', $config->{image_cache}) {
  $log->info("Loading image cache");
  my @lines = <JSON>;
  %image = Mojo::JSON->decode(@lines);
  close JSON;
}

$log->info('Starting scanning');
my @group_names = keys %{$config->{groups}};
for (my $i = 0; ; $i++) {
  if ($i == @group_names) {
    $i = 0;
  }

  my $group = $group_names[$i];

  for (my $j = 1; $j <= $config->{groups}->{$group}; $j++) {
    checkclosed();

    my $hostname = sprintf("%s%02d", $group, $j);

    if (my $hostuser = getuser($hostname)) {
      $log->debug("$hostname: $hostuser->{username}");
      if (my $photo = getphoto($hostuser->{username})) {
        $hostuser->{image} = $photo;
      }
      else {
        $log->debug("Failed to find photo");
      }
      $users{$hostname} = $hostuser;

    }
    else {
      $log->debug("$hostname: available");
      delete $users{$hostname};
    }

    writeusers;
  }
}

sub writeusers {
  writejson(\%users, $config->{users_file});
}

sub writejson {
  my ($struct, $file) = @_;

  open JSON, ">$file";
  print JSON $json->encode($struct);
  close JSON;
}

sub checkclosed {
  my $time = DateTime->now;
  if ($time->hour < $config->{open_hour} || $time->hour >= $config->{close_hour}) {
    my $waketime = $time->clone->set_hour($config->{open_hour})->truncate(to => 'hour');

    if ($time->hour >= $config->{close_hour}) {
      $waketime->add(days => 1);
    }

    %users = ( closed => Mojo::JSON->true );
    writeusers;

    while (($time = DateTime->now) < $waketime) {
      $log->info("Sleeping until $waketime");
      sleep $waketime->subtract_datetime_absolute($time)->in_units('seconds');
      $log->info("Woken up");
    }

    %users = ();
    writeusers;
  }
}

sub getuser {
  local *SSH;

  my $hostname = shift;
  my $hostuser = undef;

#  open SSH, "ssh $sshopts $hostname finger 2>/dev/null |";
  my $ssh = Net::OpenSSH->new($hostname,
    timeout => $config->{timeout},
    master_opts => \@sshopts,
    master_stderr_discard => 1);

  if ($ssh->error) { return undef; }
  my ($sshout, $pid) = $ssh->pipe_out('finger'); 

  readline $sshout;
  while (<$sshout>) {
    if ($_ =~ /(\w+)\s+(.+?)\s+tty[7-9]/) {
      $hostuser = { username => $1, fullname => $2 };
      last;
    }
  }
  close $sshout;

  return $hostuser;
}

sub getphoto {
  my $username = shift;
  
  if (!$image{$username}) {
    my $ua = LWP::UserAgent->new;
    my $response = $ua->get("https://www.doc.ic.ac.uk/internal/photosearch/^$username\$");
    if ($response->is_success) {
      my $dom = Mojo::DOM->new($response->content);

      if (my $header = $dom->find('div.studentphotoheader')->[0]) {
	$image{$username} = $header->a->img->{src};
      }
    }
  }

  return $image{$username};
}

sub terminate {
  $log->info('Signal received, saving image cache...');
  %users = ( stopped => Mojo::JSON->true );
  writejson(\%image, $config->{image_cache});
  $log->info('Shutting down');
  exit;
}

sub crash {
  $log->fatal("Something went wrong: @_");
  $log->fatal('Crashed.');
}
