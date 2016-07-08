use strict;
use warnings;

use Gearman::Client;
use Storable qw( freeze );
use Test::More;
use Test::Exception;
use Test::Timer;
use lib 't';
use TestGearman;

my @job_servers;
{
    my $la = "127.0.0.1";
    my @ports = free_ports($la, 3);
    start_server($ENV{GEARMAND_PATH}, $ports[0])
        || plan skip_all => "Can't find server to test with";

    @job_servers = map { join ':', $la, $_ } @ports;

    for (1 .. $#ports) {
        start_server($ENV{GEARMAND_PATH}, $ports[$_]);
    }

    foreach (@job_servers) {
        check_server_connection($_);
    }
}

my $client = new_ok("Gearman::Client",
    [exceptions => 1, job_servers => [@job_servers]]);

## Start two workers, look for job servers
start_worker([@job_servers]);
start_worker([@job_servers]);

subtest "taskset 1", sub {
    throws_ok { $client->do_task(sum => []) }
    qr/Function argument must be scalar or scalarref/,
        'do_task does not accept arrayref argument';

    my $out = $client->do_task(sum => freeze([3, 5]));
    is($$out, 8, 'do_task returned 8 for sum');

    my $tasks = $client->new_task_set;
    isa_ok($tasks, 'Gearman::Taskset');
    my $sum;
    my $failed    = 0;
    my $completed = 0;
    my $handle    = $tasks->add_task(
        sum => freeze([3, 5]),
        {
            on_complete => sub { $sum    = ${ $_[0] } },
            on_fail     => sub { $failed = 1 }
        }
    );

    $tasks->wait;

    is($sum,    8, 'add_task/wait returned 8 for sum');
    is($failed, 0, 'on_fail not called on a successful result');
};

## Now try a task set with 2 tasks, and make sure they are both completed.
subtest "taskset 2", sub {
    my $tasks = $client->new_task_set;
    my @sums;
    $tasks->add_task(
        sum => freeze([1, 1]),
        { on_complete => sub { $sums[0] = ${ $_[0] } }, }
    );
    $tasks->add_task(
        sum => freeze([2, 2]),
        { on_complete => sub { $sums[1] = ${ $_[0] } }, }
    );
    $tasks->wait;
    is($sums[0], 2, 'First task completed (sum is 2)');
    is($sums[1], 4, 'Second task completed (sum is 4)');
};

## Test some failure conditions:
## Normal failure (worker returns undef or dies within eval).
subtest "failures", sub {
    is($client->do_task('fail'),
        undef, 'Job that failed naturally returned undef');

    # the die message is available in the on_fail sub
    my $msg   = undef;
    my $tasks = $client->new_task_set;
    $tasks->add_task('fail_die', undef,
        { on_exception => sub { $msg = shift }, });
    $tasks->wait;
    like(
        $msg,
        qr/test reason/,
        'the die message is available in the on_fail sub'
    );
};

## Worker process exits.
subtest "Worker process exits", sub {
    is($client->do_task('fail_exit'),
        undef, 'Job that failed via exit returned undef');
    pid_is_dead(wait(), [@job_servers]);
};

## Worker process times out (takes longer than timeout seconds).
subtest "timeout", sub {
    plan skip_all => "timout subtest is in TODO";
    my $to = 3;
    time_ok(sub { $client->do_task('sleep', 5, { timeout => $to }) },
        $to, 'Job that timed out after 3 seconds returns failure');
};

# Test sleeping less than the timeout
subtest "sleeping", sub {
    is(${ $client->do_task('sleep_three', '1:less') },
        'less', 'We took less time than the worker timeout');

    # Do it three more times to check that 'uniq' (implied '-')
    # works okay. 3 more because we need to go past the timeout.
    is(${ $client->do_task('sleep_three', '1:one') },
        'one', 'We took less time than the worker timeout, again');

    is(${ $client->do_task('sleep_three', '1:two') },
        'two', 'We took less time than the worker timeout, again');

    is(${ $client->do_task('sleep_three', '1:three') },
        'three', 'We took less time than the worker timeout, again');

    # Now test if we sleep longer than the timeout
    is($client->do_task('sleep_three', 5),
        undef, 'We took more time than the worker timeout');

    # This task and the next one would be hashed with uniq onto the
    # previous task, except it failed, so make sure it doesn't happen.
    is($client->do_task('sleep_three', 5),
        undef, 'We took more time than the worker timeout, again');

    is($client->do_task('sleep_three', 5),
        undef, 'We took more time than the worker timeout, again, again');
};

# Check hashing on success, first job sends in 'a' for argument, second job
# should complete and return 'a' to the callback.
subtest "taskset a", sub {
    my $tasks = $client->new_task_set;
    $tasks->add_task(
        'sleep_three',
        '2:a',
        {
            uniq        => 'something',
            on_complete => sub { is(${ $_[0] }, 'a', "'a' received") },
            on_fail => sub { fail() },
        }
    );

    sleep 1;

    $tasks->add_task(
        'sleep_three',
        '2:b',
        {
            uniq        => 'something',
            on_complete => sub {
                is(${ $_[0] }, 'a', "'a' received, we were hashed properly");
            },
            on_fail => sub { fail() },
        }
    );

    $tasks->wait;
};

# Check to make sure there are no hashing glitches with an explicit
# 'uniq' field. Both should fail.
subtest "fail", sub {
    my $tasks = $client->new_task_set;
    $tasks->add_task(
        'sleep_three',
        '10:a',
        {
            uniq        => 'something',
            on_complete => sub { fail("This can't happen!") },
            on_fail     => sub { pass("We failed properly!") },
        }
    );

    sleep 5;

    $tasks->add_task(
        'sleep_three',
        '10:b',
        {
            uniq        => 'something',
            on_complete => sub { fail("This can't happen!") },
            on_fail     => sub { pass("We failed properly again!") },
        }
    );

    $tasks->wait;

    $tasks = $client->new_task_set;
    my ($completed, $failed) = (0, 0);
    $failed = 0;
    $tasks->add_task(
        fail => '',
        {
            on_complete => sub { $completed = 1 },
            on_fail     => sub { $failed    = 1 },
        }
    );
    $tasks->wait;
    is($completed, 0, 'on_complete not called on failed result');
    is($failed,    1, 'on_fail called on failed result');
};

## Test retry_count.
subtest "retry", sub {
    my $retried = 0;
    is(
        $client->do_task(
            'fail' => '',
            {
                on_retry    => sub { $retried++ },
                retry_count => 3,
            }
        ),
        undef,
        'Failure response is still failure, even after retrying'
    );
    is($retried, 3, 'Retried 3 times');
};

## Test high_priority.
## Create a taskset with 4 tasks, and have the 3rd fail.
## In on_fail, add a new task with high priority set, and make sure it
## gets executed before task 4. To make this reliable, we need to first
## kill off all but one of the worker processes.

subtest "hight priority", sub {
    my @worker_pids = grep { $Children{$_} eq 'W' } keys %Children;
    kill INT => @worker_pids[1 .. $#worker_pids];

    my $tasks = $client->new_task_set;
    my $out   = '';
    $tasks->add_task(
        echo_ws => 1,
        {
            on_complete => sub { $out .= ${ $_[0] } }
        }
    );

    $tasks->add_task(
        echo_ws => 2,
        {
            on_complete => sub { $out .= ${ $_[0] } }
        }
    );

    $tasks->add_task(
        echo_ws => 'x',
        {
            on_fail => sub {
                $tasks->add_task(
                    echo_ws => 'p',
                    {
                        on_complete => sub {
                            $out .= ${ $_[0] };
                        },
                        high_priority => 1
                    }
                );
            },
        }
    );

    $tasks->add_task(
        echo_ws => 3,
        {
            on_complete => sub { $out .= ${ $_[0] } }
        }
    );

    $tasks->add_task(
        echo_ws => 4,
        {
            on_complete => sub { $out .= ${ $_[0] } }
        }
    );

    $tasks->add_task(
        echo_ws => 5,
        {
            on_complete => sub { $out .= ${ $_[0] } }
        }
    );

    $tasks->add_task(
        echo_ws => 6,
        {
            on_complete => sub { $out .= ${ $_[0] } }
        }
    );

    $tasks->wait;
    like($out, qr/p.+6/, 'High priority tasks executed in priority order.');

    # We just killed off all but one worker--make sure they get respawned.
    respawn_children([@job_servers]);
};

subtest "job server status", sub {
    my $js_status = $client->get_job_server_status();
    foreach (@{ $client->job_servers() }) {
        isnt($js_status->{$_}->{echo_prefix}->{capable},
            0, 'Correct capable jobs for echo_prefix');
        is($js_status->{$_}->{echo_prefix}->{running},
            0, 'Correct running jobs for echo_prefix');
        is($js_status->{$_}->{echo_prefix}->{queued},
            0, 'Correct queued jobs for echo_prefix');
    } ## end foreach (@{ $client->job_servers...})
};

subtest "job server jobs", sub {
    my $tasks = $client->new_task_set;
    $tasks->add_task('sleep', 1);
    my $js_jobs = $client->get_job_server_jobs();
    is(scalar keys %$js_jobs, 1, 'Correct number of running jobs');
    my $host = (keys %$js_jobs)[0];
    is($js_jobs->{$host}->{'sleep'}->{key}, '', 'Correct key for running job');
    isnt($js_jobs->{$host}->{'sleep'}->{address},
        undef, 'Correct address for running job');
    is($js_jobs->{$host}->{'sleep'}->{listeners},
        1, 'Correct listeners for running job');
    $tasks->wait;
};

subtest "job server clients", sub {
    my $tasks = $client->new_task_set;
    $tasks->add_task('sleep', 1);
    my $js_clients = $client->get_job_server_clients();
    foreach my $js (keys %$js_clients) {
        foreach my $client (keys %{ $js_clients->{$js} }) {
            next unless scalar keys %{ $js_clients->{$js}->{$client} };
            is($js_clients->{$js}->{$client}->{'sleep'}->{key},
                '', 'Correct key for running job via client');
            isnt($js_clients->{$js}->{$client}->{'sleep'}->{address},
                undef, 'Correct address for running job via client');
        } ## end foreach my $client (keys %{...})
    } ## end foreach my $js (keys %$js_clients)
    $tasks->wait;
};

## Test dispatch_background and get_status.
subtest "dispatch background", sub {
    my $handle = $client->dispatch_background(
        long => undef,
        { on_complete => sub { note "complete", ${ $_[0] } }, }
    );

    # wait for job to start being processed:
    sleep 1;

    ok($handle, 'Got a handle back from dispatching background job');
    my $status = $client->get_status($handle);
    isa_ok($status, 'Gearman::JobStatus');
    ok($status->known,   'Job is known');
    ok($status->running, 'Job is still running');
    is($status->percent, .5, 'Job is 50 percent complete');

    do {
        sleep 1;
        $status = $client->get_status($handle);
        note $status->percent;
    } until $status->percent == 1;
};

done_testing();
