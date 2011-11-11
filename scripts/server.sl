#
# -= Armitage Network Attack Collaboration Server =-
#
# This is a separate application. It creates a second interface that Armitage uses
# to collaborate with other network attack clients.
# 
# Features include:
# - Meterpreter multiplexing (writes take ownership of a session, reads are silently ignored
#   for non-owner clients).
# - Upload/download files (allows feature dependent on files to work)
# - Group chat (because everyone loves chatting...)
#
# This is a proof of concept quickly hacked out (do you see how long this code is?)
#
# My goal is to eventually see this technology ported to Metasploit's RPC interface
# so this second instance can be done away with.
#
# Any takers? :)
#

debug(7);

import msf.*;

sub result {
	local('$rv $key $value');
	$rv = [new HashMap];
	foreach $key => $value ($1) {
		[$rv put: "$key", "$value"];
	}
	return $rv;
}

sub event {
	local('$result');
	$result = formatDate("HH:mm:ss") . " $1";
	acquire($poll_lock);
	push(@events, $result);
	release($poll_lock);
}

sub client {
	local('$temp $result $method $eid $sid $args $data $session $index $rv $valid $h $channel $key $value $file');

	#
	# verify the client
	#
	$temp = readObject($handle);
	($method, $args) = $temp;
	if ($method ne "armitage.validate" || $args[0] ne $auth) {
		writeObject($handle, result(%(error => "Invalid")));
		return;
	}
	else {
		($null, $eid) = $args;
	
		if ($motd ne "" && -exists $motd) {
			$temp = openf($motd);
			writeObject($handle, result(%(success => "1", message => readb($temp, -1))));
			closef($temp);
		}
		else {
			writeObject($handle, result(%(success => "1")));
		}
		event("*** $eid joined\n");
	}

	$index = 0;

	#
	# on our merry way processing it...
	#
	while $temp (readObject($handle)) {
		($method, $args) = $temp;

		if ($method eq "session.meterpreter_read") {
			($sid) = $args;
			$result = $null;

			acquire($read_lock);
				if (-isarray $queue[$sid] && size($queue[$sid]) > 0) {
					$result = shift($queue[$sid]);
				}
			release($read_lock);

			if ($result !is $null) {
				writeObject($handle, $result);
			}
			else {
				writeObject($handle, result(%(data => "", encoding => "base64")));
			}
		}
		else if ($method eq "session.meterpreter_write") {
			($sid, $data) = $args;

			#warn("P $sess_lock");
			acquire($sess_lock);
				$session = %sessions[$sid];
			release($sess_lock);
			#warn("V $sess_lock");

			#warn("Write $id -> $sid = " . $data);
			[$session addCommand: $id, $data];

			writeObject($handle, [new HashMap]);
		}
		else if ($method eq "armitage.lock") {
			($sid) = $args;
			acquire($lock_lock);
			$data = %locks[$sid];
			if ($data is $null) {
				%locks[$sid] = $eid;
				$data = $eid;
			}
			release($lock_lock);
			if ($data eq $eid) {
				writeObject($handle, result(%()));
			}
			else {
				writeObject($handle, result(%(error => "$data owns this session.")));
			}
		}
		else if ($method eq "armitage.unlock") {
			($sid) = $args;
			acquire($lock_lock);
			$data = %locks[$sid];
			if ($data is $null || $data eq $eid) {
				%locks[$sid] = $null;
			}
			release($lock_lock);
			writeObject($handle, result(%()));
		}
		else if ($method eq "armitage.log") {
			($data) = $args;
			event("* $eid $data $+ \n");
			writeObject($handle, result(%()));
		}
		else if ($method eq "armitage.push") {
			($null, $data) = $args;
			event("< $+ $[10]eid $+ > " . $data);
			writeObject($handle, result(%()));
		}
		else if ($method eq "armitage.poll") {
			acquire($poll_lock);
			if (size(@events) > $index) {
				$rv = result(%(data => @events[$index], encoding => "base64", prompt => "$eid $+ > "));
				$index++;
			}
			else {
				$rv = result(%(data => "", prompt => "$eid $+ > ", encoding => "base64"));
			}
			release($poll_lock);

			writeObject($handle, $rv);
		}
		else if ($method eq "armitage.upload") {
			($file, $data) = $args;

			$h = openf(">" . getFileName($file));
			writeb($h, $data);
			closef($h);

			deleteOnExit(getFileName($file));

			writeObject($handle, result(%(file => getFileProper($file))));
		}
		else if ($method eq "armitage.download") {
			if (-exists $args[0] && -isFile $args[0]) {
				$h = openf($args[0]);
				$data = readb($h, -1);
				closef($h);
				writeObject($handle, result(%(data => $data)));
				deleteFile($args[0]);
			}
			else {
				writeObject($handle, result(%(error => "file does not exist")));
			}
		}
		else if ($method eq "armitage.download_nodelete") {
			if (-exists $args[0] && -isFile $args[0]) {
				$h = openf($args[0]);
				$data = readb($h, -1);
				closef($h);
				writeObject($handle, result(%(data => $data)));
			}
			else {
				writeObject($handle, result(%(error => "file does not exist")));
			}
		}
		else if ($method eq "armitage.downloads") {
			$response = listDownloads("downloads");
			writeObject($handle, $response);
		}
		else if ($method eq "armitage.write") {
			($sid, $data, $channel) = $args;

			acquire($sess_lock);
				$session = %sessions[$sid];
			release($sess_lock);

			# write the data to our command file
			$h = openf(">command $+ $sid $+ . $+ $channel $+ .txt");
			writeb($h, $data);
			closef($h);
			deleteOnExit("command $+ $sid $+ . $+ $channel $+ .txt");

			writeObject($handle, result(%(file => getFileProper("command $+ $sid $+ . $+ $channel $+ .txt"))) );
		}
		else if ($method eq "armitage.refresh") {
			acquire($cach_lock);
			local('$key $value');
			foreach $key => $value (%cache) {
				$value = $null;
			}
			release($cach_lock);
			writeObject($handle, result(%()));
		}
		else if ($method eq "session.shell_write" || $method eq "session.shell_read") {
			$response = [$client execute: $method, $args];
			writeObject($handle, $response);
		}
		else if ($method eq "db.hosts" || $method eq "db.services" || $method eq "session.list") {
			$response = [$client_cache execute: $method, $args];
			writeObject($handle, $response);
		}	
		else if ("module.*" iswm $method) {
			# never underestimate the power of caching to alleviate load.
			local('$response $time');
			$response = $null;

			acquire($cach_lock);
			if ($method in %cache) {
				$response = %cache[$method];
			}
			release($cach_lock);

			if ($response is $null) {
				$response = [$client execute: $method];

				acquire($cach_lock);
				%cache[$method] = $response;
				release($cach_lock);
			}

			writeObject($handle, $response);
		} 
		else {
			if ($args) {
				$response = [$client execute: $method, $args];
			}
			else {
				$response = [$client execute: $method];
			}
			writeObject($handle, $response);
		}
	}

	event("*** $eid left.\n");

	# cleanup any locked sessions.
	acquire($lock_lock);
	foreach $key => $value (%locks) {
		if ($value eq $eid) {
			remove();
		}
	}
	release($lock_lock);
}

sub main {
	global('$client');
	local('$server %sessions $sess_lock $read_lock $poll_lock $lock_lock %locks %readq $id @events $error $auth %cache $cach_lock $client_cache');

	$auth = unpack("H*", digest(rand() . ticks(), "MD5"))[0];

	#
	# chastise the user if they're wrong...
	#
	if (size(@ARGV) < 5) {
		println("Armitage deconfliction server requires the following arguments:
	armitage --server host port user pass 
		host - the address of this host (where msfrpcd is running as well)
		port - the port msfrpcd is listening on
		user - the username for msfrpcd
		pass - the password for msfprcd");
		[System exit: 0];
	}
	
	local('$host $port $user $pass $ssl');
	($host, $port, $user, $pass, $ssl) = sublist(@_, 1);

	#
	# Connect to Metasploit's RPC Daemon
	#

	$client = [new MsgRpcImpl: $user, $pass, "127.0.0.1", long($port), 1, $null];
	while ($client is $null) {
		sleep(1000);
		$client = [new MsgRpcImpl: $user, $pass, "127.0.0.1", long($port), 1, $null];
	}
	$port += 1;

	# setg ARMITAGE_SERVER host:port/token
	call($client, "core.setg", "ARMITAGE_SERVER", "$host $+ : $+ $port $+ / $+ $auth");

	#
	# setup the client cache
	#
	$client_cache = [new RpcCacheImpl: $client];

	#
	# This lock protects the %sessions variable
	#
	$sess_lock = semaphore(1);
	$read_lock = semaphore(1);
	$poll_lock = semaphore(1);
	$lock_lock = semaphore(1);
	$cach_lock = semaphore(1);

	#
	# create a thread to push console messages to the event queue for all clients.
	#
	fork({
		global('$console $r');
		$console = createConsole($client);
		while (1) {
			$r = call($client, "console.read", $console);
			if ($r["data"] ne "") {
				acquire($poll_lock);
				push(@events, formatDate("HH:mm:ss") . " " . $r["data"]);
				release($poll_lock);
			}
			sleep(2000);
		}
	}, \$client, \$poll_lock, \@events);

	#
	# Create a shared hash that contains a thread for each session...
	#
	%sessions = ohash();
	wait(fork({
		setMissPolicy(%sessions, { 
			warn("Creating a thread for $2");
			local('$session');
			$session = [new MeterpreterSession: $client, $2]; 
			[$session addListener: lambda({
				if ($0 eq "commandTimeout" || $2 is $null) {
					return;
				}

				acquire($read_lock);

				# $2 = string id of handle, $1 = sid
				if (%readq[$2][$1] is $null) {
					%readq[$2][$1] = @();
				}

				#warn("Pushing into $2 -> $1 's read queue");
				#println([$3 get: "data"]);
				push(%readq[$2][$1], $3); 
				release($read_lock);
			})];
			return $session;
		});
	}, \%sessions, \$client, \%readq, \$read_lock));

	#
	# get base directory
	#
	setupBaseDirectory();

	#
	# setup the database
	# 
	try {
		local('$database');
		$database = connectToDatabase();
		[$client setDatabase: $database]; 
	}
	catch $exception {
		println("Could not connect to database: " . [$exception getMessage]);
		[System exit: 0];
	}

	#
	# spit out the details
	#
	println("Use the following connection details to connect your clients:");
	println("\tHost: $host");
	println("\tPort: " . ($port - 1));
	println("\tUser: $user");
	println("\tPass: $pass");
	println("\n" . rand(@("I'm ready to accept you or other clients for who they are",
		"multi-player metasploit... ready to go",
		"hacking is such a lonely thing, until now",
		"feel free to connect now, Armitage is ready for collaboration")));

	$id = 0;
	while (1) {
		$server = listen($port, 0);
		warn("New client: $server $id");

		%readq[$id] = %();
		fork(&client, \$client, $handle => $server, \%sessions, \$read_lock, \$sess_lock, \$poll_lock, $queue => %readq[$id], \$id, \@events, \$auth, \%locks, \$lock_lock, \$cach_lock, \%cache, \$motd, \$client_cache);

		$id++;
	}
}

invoke(&main, @ARGV);
