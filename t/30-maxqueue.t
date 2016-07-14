use strict;
use warnings;

use FindBin qw/ $Bin /;
use Gearman::Client;
use Storable qw( freeze );
use Test::More;

use lib "$Bin/lib";
use Test::Gearman;

# This is testing the MAXQUEUE feature of gearmand. There's no direct
# support for it in Gearman::Worker yet, so we connect directly to
# gearmand to configure it for the test.

my $tg = Test::Gearman->new(
    ip     => "127.0.0.1",
    daemon => $ENV{GEARMAND_PATH} || undef
);

$tg->start_servers() || plan skip_all => "Can't find server to test with";

foreach (@{ $tg->job_servers }) {
    unless ($tg->check_server_connection($_)) {
        plan skip_all => "connection check $_ failed";
        last;
    }
} ## end foreach (@{ $tg->job_servers...})

plan tests => 6;

ok(
    my $sock = IO::Socket::INET->new(
        PeerAddr => @{ $tg->job_servers }[0],
    ),
    "connect to jobserver"
);

$sock->write("MAXQUEUE long 1\n");
my $input = $sock->getline();
ok($input =~ m/^OK\b/i);

my $pid = $tg->start_worker();

my $client = new_ok("Gearman::Client", [job_servers => $tg->job_servers]);

my $tasks = $client->new_task_set;
isa_ok($tasks, 'Gearman::Taskset');

my $failed    = 0;
my $completed = 0;

foreach my $iter (1 .. 5) {
    my $handle = $tasks->add_task(
        'long', $iter,
        {
            on_complete => sub { $completed++ },
            on_fail     => sub { $failed++ }
        }
    );
} ## end foreach my $iter (1 .. 5)

$tasks->wait;

# One in the queue, plus one that may start immediately
ok($completed == 2 || $completed == 1, 'number of success');

# All the rest
ok($failed == 3 || $failed == 4, 'number of failure');

