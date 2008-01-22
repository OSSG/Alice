#!/usr/bin/perl -w
# Alice - aliases for existing Jabber-accounts
# Copyright (C) 2007, 2008 Fedor A. Fetisov <faf@ossg.ru>. All Rights Reserved
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;

use Net::Jabber;
use XML::Simple;
use Getopt::Long qw(:config no_ignore_case bundling no_auto_abbrev);
use POSIX;

use constant DEFAULT_PRIORITY => 1;
use constant DEFAULT_CONFIG => 'config.xml';

my $alice;
my $clients = [];
my $connections_ids = {};

my $config;
my $options = {};
GetOptions(
    $options, 'help|?', 'config=s'
) or die "For usage information try: \t$0 --help\n";

if ($options->{'help'}) {
    print <<HELP
ejabberd aliases script
Usage: $0 [--config=<file>]
HELP
;

    exit;
}

$options->{'config'} ||= DEFAULT_CONFIG;
unless (-f $options->{'config'}) {
    print STDERR "Can't find configuration file $options->{'config'}: $!\n";
    exit;
}

$config = eval { XMLin($options->{'config'}, 'ForceArray' => ['connection', 'real_jid'], 'ContentKey' => '-content') };
if ($@) {
    print STDERR "Bad configuration format.\n";
    exit;
}

if (-f $config->{'service'}->{'pid_file'}) {
    print STDERR "Found pid file $config->{'service'}->{'pid_file'}. Alice already running?\n";
    exit;
}

my $pid = fork();
if ($pid) {
    if (open(OUT, '>' . $config->{'service'}->{'pid_file'})) {
	print OUT $pid;
	close OUT;
    }
    else {
	print STDERR "Can't open pid file: $!\n";
    }
    exit;
}
elsif (!defined $pid) {
    print STDERR "Can't fork: $!\n";
    _disconnect();
}


for my $handle (*STDIN, *STDOUT) {
    unless (open($handle, '+<', '/dev/null')) {
	print STDERR "Can't reopen $handle to /dev/null : $!\n";
	_disconnect();
    }
}

unless (open(*STDERR, '>>', $config->{'service'}->{'error_log'})) {
    print STDERR "Can't reopen STDERR to $config->{'service'}->{'error_log'} : $!\n";
    _disconnect();
}

unless (POSIX::setsid()) {
    print STDERR "Can't start a new session: $!\n";
    _disconnect();
}


$SIG{HUP} = $SIG{KILL} = $SIG{TERM} = $SIG{INT} = \&_disconnect;
$SIG{PIPE} = 'IGNORE';

my $reconnect_flag = ($config->{'component_connection'}->{'reconnect'} &&
		    ($config->{'component_connection'}->{'reconnect'} ne 'no')) ? 1 : 0;

foreach (@{$config->{'aliases'}->{'connection'}}) {
    my $i = scalar(@$clients);

    $clients->[$i]->{'jids'} = $_->{'real_jid'};

    $clients->[$i]->{'name'} = $_->{'username'} . '@' . ($_->{'domain'} || $_->{'hostname'});

    $connections_ids->{$clients->[$i]->{'name'}} = $i;
}

my $first_time = 1;
do {

    $alice = new Net::Jabber::Component;

    $alice->SetCallBacks( message => \&_outgoing_message );

    unless ( defined ($alice->Connect(	'hostname'		=> $config->{'component_connection'}->{'host'},
					'port'			=> $config->{'component_connection'}->{'port'},
					'componentname'		=> $config->{'component_connection'}->{'component'},
					'connectiontype'	=> 'tcpip',
					'tls'			=> ($config->{'component_connection'}->{'tls'} &&
								    ($config->{'component_connection'}->{'tls'} ne 'no')) ? 1 : 0 )) ) {

	my $error = $alice->GetErrorCode();
	print STDERR "Can't establish Alice (component) connection: " . ((ref($error) eq 'HASH') ? $error->{'text'} : $error) . "\n";
	if ($first_time) {
	    _disconnect();
	} 
	else {
	    sleep(10);
	}
    }
    else {

	my @result = $alice->AuthSend(	'secret' => $config->{'component_connection'}->{'secret'} );

	unless ($result[0] eq 'ok') {
	    print STDERR "Alice (component) authorization failed: $result[1]\n";
	    _disconnect() if $first_time;
	}
	else {

	    do {
		for (my $i = 0; $i < scalar(@$clients); $i++) {
		    
		    my $status;
		    unless ($first_time || $clients->[$i]->{'bad'} || defined ($status = $clients->[$i]->{'connection'}->Process(0))) {
			print STDERR '[' . localtime(time) . '] Lost connection for ' . ($i+1) . ' alias (' . $config->{'aliases'}->{'connection'}->[$i]->{'username'} . '@' . $config->{'aliases'}->{'connection'}->[$i]->{'hostname'} . ':' . $config->{'aliases'}->{'connection'}->[$i]->{'port'} . ').' . ($reconnect_flag ? ' Attempt to reconnect.' : '') . "\n";
			$clients->[$i]->{'connection'}->Disconnect();
			delete $clients->[$i]->{'connection'};
		    }

		    if ($first_time || !$clients->[$i]->{'bad'} && !defined $status && $reconnect_flag) {

			$clients->[$i]->{'connection'} = new Net::Jabber::Client;
			$clients->[$i]->{'connection'}->SetCallBacks( message => \&_incoming_message );
			$clients->[$i]->{'connection'}->SetPresenceCallBacks( available => \&_incoming_message, unavailable => \&_incoming_message );

			unless ( $clients->[$i]->{'connection'}->Connect(	'hostname'		=> $config->{'aliases'}->{'connection'}->[$i]->{'hostname'},
										'port' 			=> $config->{'aliases'}->{'connection'}->[$i]->{'port'},
										'componentname'		=> $config->{'aliases'}->{'connection'}->[$i]->{'domain'} || $config->{'aliases'}->{'connection'}->[$i]->{'hostname'},
										'connectiontype'	=> 'tcpip',
										'tls' 			=> ($config->{'aliases'}->{'connection'}->[$i]->{'tls'} &&
													    ($config->{'aliases'}->{'connection'}->[$i]->{'tls'} ne 'no')) ? 1 : 0 ) ) {
			    my $error = $clients->[$i]->{'connection'}->GetErrorCode();
			    print STDERR "Can't establish connection for " . ($i+1) . ' alias (' . $config->{'aliases'}->{'connection'}->[$i]->{'hostname'} . ':' . $config->{'aliases'}->{'connection'}->[$i]->{'port'} . '): ' . ((ref($error) eq 'HASH') ? $error->{'text'} : $error) . "\n";
			    if ($first_time) {
				$clients->[$i]->{'bad'} = 1;
			    }

			}
			else {
			    my @result = $clients->[$i]->{'connection'}->AuthSend(	'username' => $config->{'aliases'}->{'connection'}->[$i]->{'username'},
											'password' => $config->{'aliases'}->{'connection'}->[$i]->{'password'},
											'resource' => $config->{'aliases'}->{'connection'}->[$i]->{'resource'} || '');

	    		    unless ($result[0] eq 'ok') {
				print STDERR "Authorization for " . ($i+1) . ' alias (' . $config->{'aliases'}->{'connection'}->[$i]->{'username'} . '@' . ($config->{'aliases'}->{'connection'}->[$i]->{'domain'} || $config->{'aliases'}->{'connection'}->[$i]->{'hostname'}) . ") failed: $result[1]\n";
			    }
			    else {
				$clients->[$i]->{'connection'}->PresenceSend(show => 'online', priority => ($config->{'aliases'}->{'connection'}->[$i]->{'priority'} && ($config->{'aliases'}->{'connection'}->[$i]->{'priority'} =~ /^[0-9]+$/)) ? $config->{'aliases'}->{'connection'}->[$i]->{'priority'} : DEFAULT_PRIORITY);
			    }
			}
		    }

		}

	        $first_time &&= 0;

	    } while (defined (my $status = $alice->Process(1)));

	    print STDERR '[' . localtime(time) . '] Lost Alice (component) connection.' . ($reconnect_flag ? ' Attempt to reconnect.' : '') . "\n";
	    $alice->Disconnect();
	    undef $alice;

	}
    }

} while ($reconnect_flag);

_disconnect();

sub _incoming_message {
    my $sid = shift;
    my $message = shift;

    my $to = $message->GetTo();
    $to =~ s~/.*$~~;
    my $connection_id = $connections_ids->{$to};

    if (defined $connection_id) {
	my $from = $message->GetFrom();
	$from =~ s~/.*$~~;
	$from .= '_for_' . $to;
	$from =~ s/\@/_at_/g;
	$from .= '@' . $config->{'component_connection'}->{'component'};
	$message->SetFrom($from);
	foreach my $jid (@{$clients->[$connection_id]->{'jids'}}) {
	    $message->SetTo($jid);
	    $alice->Send($message);
	}
    }
}

sub _outgoing_message {
    my $sid = shift;
    my $message = shift;

    my $from = $message->GetFrom();
    $from =~ s~/.*$~~;

    my $error = 1;
    my $to = $message->GetTo();
    my $component = $config->{'component_connection'}->{'component'};
# get connection name and rcpt jid from $to
    if ($to =~ m/^(.*)_for_(.*)\@$component$/) {
	my $rcpt = $1;
	my $sender = $2;
	foreach ($rcpt, $sender) {
	    s/_at_/\@/g;
	}
	my $connection_id = $connections_ids->{$sender};
	if (defined $connection_id) {
# does $from corresponding connection name?
	    foreach my $jid (@{$clients->[$connection_id]->{'jids'}}) {
		if ($from eq $jid) {
		    $message->SetFrom('');
		    $message->SetTo($rcpt);
		    $clients->[$connection_id]->{'connection'}->Send($message);
		    $error = 0;
		    last;
		}
	    }
	}
    }

    if ($error) {
	print STDERR "Bad attempt to send message from " . $message->GetFrom() . " to " . $message->GetTo() . "\n";
    }
}

sub _disconnect {
    foreach (@$clients) {
	$_->{'connection'}->Disconnect() if defined $_->{'connection'};
    }
    $alice->Disconnect() if defined $alice;
    unlink($config->{'service'}->{'pid_file'}) if (-f $config->{'service'}->{'pid_file'});
    exit;
}
