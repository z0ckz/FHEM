################################################################################
# $Id: 83_BUSCH_RADIO.pm$
#
# FHEM Module for Busch-Radio iNet
# Used to interact with Busch-Radio iNet WLAN radio.
#
# Written by zockz@gmx.net
#
################################################################################
# Changelog:
# 2017-11-27 Initial version
# 2017-12-10 Implemented basic functionality
# 2017-12-18 Added documentation
# 2017-12-20 Improved state handling a bit
# 2018-01-18 Added volume_up/down commands
################################################################################

package main;
use strict;
use warnings;
use IO::Socket;
use Time::HiRes qw(gettimeofday);
#use SetExtensions;

# used external global variables from FHEM
use vars qw(%defs %modules %attr %selectlist $readingFnAttributes $init_done);

# global definitions
use constant { true => 1, false => 0};
use constant { on => 'on', off => 'off', online => 'online', offline => 'offline', host_error => 'host_error' };
use constant { 
	DEFAULT_UDP_PORT => 4244, DEFAULT_UDP_LISTEN_PORT => 4242, DEFAULT_BROADCAST_ADDRESS => '255.255.255.255', 
	DEFAULT_TIMER => 60, DEFAULT_FULL_UPDATE_INTERVAL => 60 * 60 * 24, # once a day,
	DEAD_TIMER => 60,
};

# map external command resonse fields (format: <GET-command>:<field>) to internal reading names
my %BUSCH_RADIO_readingsMap = (
    'INFO_BLOCK:NAME' => 'device_name', 
    'INFO_BLOCK:MAC' => 'mac_address', 
    'INFO_BLOCK:SERNO' => 'serial_no', 
    'INFO_BLOCK:SW-VERSION' => 'version', 
    'INFO_BLOCK:IPADDR' => 'ip_address', 
    'INFO_BLOCK:IPMASK' => 'ip_netmask', 
    'INFO_BLOCK:GATEWAY' => 'ip_gateway', 
    'INFO_BLOCK:IPMODE' => 'ip_mode', # ON | OFF
    'INFO_BLOCK:WLAN-FW' => 'wifi_version', 
    'INFO_BLOCK:SSID' => 'wifi_ssid', 
    'INFO_BLOCK:COUNTRY' => 'country', 
    'POWER_STATUS:POWER' => 'power', # ON|OFF
    'POWER_STATUS:ENERGY_MODE' => 'energy_mode', # STANDBY | ECO | PREMIUM
    'VOLUME:VOLUME_SET' => 'volume', # 0..31
    'OPERATING_MODE:MODE' => 'operating_mode', # HOTEL | IP-RADIO
    'PLAYING_MODE:PLAYING' => 'play_mode', # STATION | TUNEIN | UPNP | AUX 
    'PLAYING_MODE:ID_1' => 'play_station', # there are actually 2 ID fields in this response, hence the suffix _1
    'PLAYING_MODE:NAME' => 'play_station_name',
    'PLAYING_MODE:URL' => 'play_url',
    'DISCOVER:IP' => 'ip_address', 
    'DISCOVER:NAME' => 'device_name', 
    'DISCOVER:APP_VERSION' => 'app_version', 
    'ALL_STATION_INFO:NAME' => 'station_1_name',
    'ALL_STATION_INFO:URL' => 'station_1_url',
    'ALL_STATION_INFO:NAME_1' => 'station_2_name',
    'ALL_STATION_INFO:URL_1' => 'station_2_url',
    'ALL_STATION_INFO:NAME_2' => 'station_3_name',
    'ALL_STATION_INFO:URL_2' => 'station_3_url',
    'ALL_STATION_INFO:NAME_3' => 'station_4_name',
    'ALL_STATION_INFO:URL_3' => 'station_4_url',
    'ALL_STATION_INFO:NAME_4' => 'station_5_name',
    'ALL_STATION_INFO:URL_4' => 'station_5_url',
    'ALL_STATION_INFO:NAME_5' => 'station_6_name',
    'ALL_STATION_INFO:URL_5' => 'station_6_url',
    'ALL_STATION_INFO:NAME_6' => 'station_7_name',
    'ALL_STATION_INFO:URL_6' => 'station_7_url',
    'ALL_STATION_INFO:NAME_7' => 'station_8_name',
    'ALL_STATION_INFO:URL_7' => 'station_8_url',
); 

# translate external values to internal
my %readingsValueMaps = (
	'power' => { 'ON' => on, 'OFF' => off },
#	'IP_MODE' => { 'ON' => 'on', 'OFF' => 'off' },
	'play_mode' => { 'STATION' => 'radio', 'TUNEIN' => 'tunein', 'UPNP' => 'upnp', 'AUX_IDCOCK' => 'aux' },
);

# ----------------------------------------------------------------------------
# FHEM API
# ----------------------------------------------------------------------------

#  Initialize: Initialisation routine called upon start-up of FHEM
sub BUSCH_RADIO_Initialize($) {
	my ($hash) = @_;
	
	my %FUNCTION_MAP = (
		DefFn => 'BUSCH_RADIO_Define',
		UndefFn => 'BUSCH_RADIO_Undef',
		ShutdownFn => 'BUSCH_RADIO_Shutdown',
		GetFn => 'BUSCH_RADIO_Get',
		SetFn => 'BUSCH_RADIO_Set',
		AttrFn => 'BUSCH_RADIO_Attr',
		ReadFn => 'BUSCH_RADIO_Read',
	);
	
	@{$hash}{keys %FUNCTION_MAP} = values %FUNCTION_MAP;
	$hash->{AttrList} = "host broadcastAddress UDPPort UDPListenPort timer fullUpdateInterval " . $readingFnAttributes;
}

#  Define: called when defining a device in FHEM
sub BUSCH_RADIO_Define($$) {
	my ($hash, $def) = @_;
	Log3($hash->{NAME}, 4, "BUSCH_RADIO_Define($def)");

	# do we have the right number of arguments?
	my @args = split(/\s+/, $def);
	if ((@args < 2) || (@args > 3)) {
		return "wrong syntax: define <name> BUSCH_RADIO [<server address>]";
	}

	# remove the name and our type
	my $name = shift(@args);
	shift(@args);
	my $address = shift(@args);

	$hash->{ID} = $name;

	BUSCH_RADIO_updateState($hash, offline); # until we know better...

	# initialize readings on 1st define
	if ($init_done) {
		readingsBeginUpdate($hash);
		for my $reading (values %BUSCH_RADIO_readingsMap) {
			readingsBulkUpdate($hash, $reading, '');
		}
		readingsEndUpdate($hash, false);
	}

	# resolve the address if given
	if ($address) {
		$attr{$name}->{'host'} = $address;
		BUSCH_RADIO_setHost($hash, $address);
	}

	# open the UDP listener socket
	BUSCH_RADIO_startListener($hash);
	
	# start the timer for polling the status right now
	InternalTimer(gettimeofday(), \&BUSCH_RADIO_timer, $hash);
	
	return undef;
}

#  Undef: called when deleting a device
sub BUSCH_RADIO_Undef($$) {
	my ($hash, $arg) = @_;
	BUSCH_RADIO_stopListener($hash);
	RemoveInternalTimer($hash);
	return undef;
}

#  Shutdown: called before FHEM shuts down
sub BUSCH_RADIO_Shutdown($$) {
	my ($hash, $dev) = @_;
	BUSCH_RADIO_stopListener($hash);
	RemoveInternalTimer($hash);
	return undef;
}

#  Attr: set an attribute
sub BUSCH_RADIO_Attr($$$@) {
	my ($cmd, $name, $attr, @args) = @_;
	my $hash = $defs{$name};
	Log3($name, 5, "BUSCH_RADIO_Attr($cmd, $attr, " . join(', ', @args) . ')');
	
	if ($attr eq 'host') { # resolve address
		return BUSCH_RADIO_setHost($hash, $args[0]);
	} elsif ($attr eq 'UDPListenPort') { # restart the UDP listener
		BUSCH_RADIO_startListener($hash);
	} elsif ($attr eq 'timer') {
		# restart the timer only if the new interval is shorter than the remaining time slice 
        my $next = gettimeofday() + $args[0];
		if (!defined $hash->{'next_timer'} || $hash->{'next_timer'} > $next) {
			RemoveInternalTimer($hash);
			if ($args[0] > 0) {
			    InternalTimer($hash->{'next_timer'} = $next, \&BUSCH_RADIO_timer, $hash);
			}
		} 
	}
	return undef;
}

#  Get: perform a get function
sub BUSCH_RADIO_Get($$$@) {
	my ($hash, $name, $opt, @args) = @_;
	Log3($name, 5, "BUSCH_RADIO_Get($opt, @args)");

	my @BASIC_UPDATE = ('POWER_STATUS', 'PLAYING_MODE', 'VOLUME');
	my @FULL_UPDATE = (@BASIC_UPDATE, 'INFO_BLOCK', 'ALARM_STATUS', 'TUNEIN_PARTNER_ID', 'OPERATING_MODE', 
		'ALL_STATION_INFO'); 

	if ($opt eq 'status') {
		BUSCH_RADIO_sendCommand($hash, 'GET', $_) foreach (@BASIC_UPDATE); 
	} elsif ($opt eq 'update_info') {
		BUSCH_RADIO_sendCommand($hash, 'GET', $_) foreach (@FULL_UPDATE); 
	} elsif ($opt eq "discover") {
		BUSCH_RADIO_broadcastCommand($hash, 'DISCOVER', '');
	} else {
		return "Unknown argument $opt, choose one of status:noArg update_info:noArg discover:noArg";
	}

	return undef;
}

#  Set: perform a set function
sub BUSCH_RADIO_Set($@) {
	my ($hash, $name, $cmd, @args) = @_;
	Log3($name, 5, "BUSCH_RADIO_Set($cmd, " . join(', ', @args) . ')');

	if($cmd eq "on" || $cmd eq 'power' && $args[0] eq on) {
		if ($hash->{STATE} eq offline) {
			return "Cannot turn on the device while it is offline. Did you set energy mode to PREMIUM?";
		} else {
		    BUSCH_RADIO_sendCommand($hash, 'SET', 'RADIO_ON');
        }  
	} elsif($cmd eq "off" || $cmd eq 'power' && $args[0] eq 'off') {
		BUSCH_RADIO_sendCommand($hash, 'SET', 'RADIO_OFF');
	} elsif($cmd eq "volume") {
		if (defined $args[0] && $args[0] >= 0 && $args[0] <= 100) { 
			BUSCH_RADIO_sendCommand($hash, 'SET', 'VOLUME_ABSOLUTE:' . $args[0]);
		} else {
			return "Invalid argument 'args[0]' for $cmd (valid: <0..100>)";
		}
    } elsif($cmd eq "volume_up" || $cmd eq "volume_down") {
    	my $vol = ReadingsVal($name, 'volume', undef);
    	if (defined $vol) {
            my $step = $cmd eq "volume_up" ? +1 : -1;
            $vol = $vol + $step;
            if ($vol >= 0 && $vol <= 31) {
    	       BUSCH_RADIO_sendCommand($hash, 'SET', 'VOLUME_ABSOLUTE:' . $vol);
            }
    	}
	} elsif($cmd eq "mute") {
		my $cmd = $args[0] eq on ? 'VOLUME_MUTE' : 'VOLUME_UNMUTE';
		BUSCH_RADIO_sendCommand($hash, 'SET', $cmd);
	} elsif($cmd =~ /^play_mode(_x)?$/ && defined $args[0]) {
		my $x = $cmd eq 'play_mode_x';
		if ($args[0] eq 'aux') {
			BUSCH_RADIO_sendCommand($hash, 'PLAY', 'AUX');
		} elsif ($args[0] eq 'upnp') {
			BUSCH_RADIO_sendCommand($hash, 'PLAY', 'UPNP');
		} elsif (!$x && $args[0] eq 'radio') {
			my $s = ReadingsVal($name, 'play_station', 1);
			BUSCH_RADIO_sendCommand($hash, 'PLAY', 'STATION:' . $s);
		} elsif ($x && (my ($s)  = ($args[0] =~ '^station_([1-8])$'))) {
			BUSCH_RADIO_sendCommand($hash, 'PLAY', 'STATION:' . $s);
		} elsif ($args[0] eq 'tunein') {
#			BUSCH_RADIO_sendCommand($hash, 'PLAY', 'TUNEIN_INIT');
			BUSCH_RADIO_playURL($hash, ReadingsVal($name, 'play_url_x', ''));
		} else {
			return "Invalid argument '$args[0]' for $cmd (expected: " .
				($x ? join(' | ', map 'station_' . $_ [1..8]) : 'radio') . ' | upnp | aux | url)';
		}
	} elsif($cmd eq "play_station" && defined $args[0]) {
		if (defined $args[0] && $args[0] =~ /^[1-8]$/) {
			BUSCH_RADIO_sendCommand($hash, 'PLAY', 'STATION:' . $args[0]);
		} else {
			return "Invalid argument '$args[0]' for $cmd (expected: <1..8>)";
		}
	} elsif(($cmd eq "play_url_x") && defined $args[0]) {
		if (!BUSCH_RADIO_playURL($hash, $args[0])) {
			return "Invalid argument '$args[0]' for $cmd (expected: [<name|>]<url>)";
		}
	} elsif(($cmd eq "play_station_name") && defined $args[0]) {
		# this can handle single spaces but FHEM parsing will screw up consecutive spaces 
		my $d = join(' ', @args);
		foreach my $s (1..8) { # find that station
			my $name = ReadingsVal($name, 'station_' . $s . '_name', '');
			if ($name eq $d) {
				BUSCH_RADIO_sendCommand($hash, 'PLAY', 'STATION:' . $s);
				return undef;
			}
		}
		return "Invalid argument '$args[0]' for $cmd (expected: <name>)";
	} else 	{
		my $stations = join(',', map { "station_$_" } (1..8));
		my $station_names = join(',', map { ReadingsVal($name, 'station_' . $_ . '_name', '') } (1..8));
		$station_names =~ s/ /#/g;
		return "Unknown argument $cmd, choose one of power:on,off on:noArg off:noArg volume:slider,0,1,31 mute:on,off "
			. 'volume_up volume_down play_mode:radio,tunein,upnp,aux play_station:1,2,3,4,5,6,7,8 play_url_x '
			. "play_mode_x:tunein,upnp,aux,$stations play_station_name:$station_names";
	}
  	
	return undef;
}

# Read: called from the global loop when the select for hash->{FD} reports data
sub BUSCH_RADIO_Read($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	Log3($hash, 5, "BUSCH_RADIO_Read()");

	my $socket =$hash->{udpSocket};
	my $message;
	$socket->recv($message, 4096);
	BUSCH_RADIO_received($hash, $message)
}

# ----------------------------------------------------------------------------
# Busch-Radio internal workings
# ----------------------------------------------------------------------------

# Update the internal status (according to valid state changes).
# Returns true if the state wa actually set, false otherwise.
sub BUSCH_RADIO_updateState($$) {
	my ($hash, $newState) = @_;
	if ($newState eq online) {
        $hash->{last_ack} = gettimeofday();
	}
    my $oldState = $hash->{STATE};
	# 'online' doesn't overwrite 'on' or 'off', 'host_error' can only be reset by 'offline' state
	if ($oldState ne host_error ? $oldState eq offline || $newState ne online : $newState eq offline) {
		$hash->{STATE} = $newState;
		return true;
	}
	return false;
}

# set the host name / IP address
sub BUSCH_RADIO_setHost($$) {
	my ($hash, $address) = @_;
	my $name = $hash->{NAME};
	if (!$address) { # deleted the host attribute
		BUSCH_RADIO_updateReading($hash, 'ip_address', '', true);
		BUSCH_RADIO_updateState($hash, offline);
		return undef;
	} else {
		my $ip = BUSCH_RADIO_resolve($address);
		if ($ip) {
            BUSCH_RADIO_updateReading($hash, 'ip_address', $ip, true);
			$attr{$name}{'broadcastAddress'} = BUSCH_RADIO_getBroadcastAddress($ip);
			BUSCH_RADIO_updateState($hash, offline);
			return undef;
		} else {
			my $error = "cannot resolve address: $address";
			Log3($name, 2, $error);
			BUSCH_RADIO_updateState($hash, host_error);
			return $error;
		}
	}
}

# send a command to the target radio
sub BUSCH_RADIO_sendCommand($$@) {
	my ($hash) = shift;
	my $name = $hash->{NAME};
	my $target = AttrVal($name, 'host', '');
	if ($hash->{STATE} eq host_error) {
		Log3($name, 2, "cannot send: invalid host: $target.");
	} else {
		$target = ReadingsVal($name, 'ip_address', undef) if !$target;
		if ($target) {
			my $port = AttrVal($name, 'UDPPort', DEFAULT_UDP_PORT);
			my $cmd = BUSCH_RADIO_buildCommand($hash, @_);
			BUSCH_RADIO_sendUDP($target, $port , false, $cmd);
		} else {
			Log3($name, 2, "cannot send: no address defined, must discover first.");
		}
	}
}

# broadcast a command to all radios in the current subnet
sub BUSCH_RADIO_broadcastCommand($$@) {
	my ($hash) = shift;
	my $name = $hash->{NAME};
	my $address = AttrVal($name, 'broadcastAddress', DEFAULT_BROADCAST_ADDRESS);
	my $port = AttrVal($name, 'UDPPort', DEFAULT_UDP_PORT);
	my $cmd = BUSCH_RADIO_buildCommand($hash, @_);
	BUSCH_RADIO_sendUDP($address, $port, true, $cmd); 
}

# create the command structure
sub BUSCH_RADIO_buildCommand($$@) {
	my ($hash, $cmd, @parameters) = @_;
	my $command =  join("\r\n", ("COMMAND:$cmd", @parameters, "ID:$hash->{ID}"), '', '');
	return $command;
}

# play a 'tunein' URL. URL format is [<name>|]<url>
sub BUSCH_RADIO_playURL($$) {
	my ($hash, $urlName) = @_;
	
	my ($x, $name, $url) = $urlName =~ /^(([^|]*)\|)?([^|]+)$/;
	if (!$name) {
		$name = $url;
		$name =~ s&(.*://)?([^/:]+)(:[0-9]+)?(/.*)?$&$2&;
	}
	
	if (!$url) {
		return false;
	} else {
		BUSCH_RADIO_sendCommand($hash, 'PLAY', "TUNEIN_PLAY\r\nURL:" . $url. "\r\nTEXT:" . $name);
		return true;
	}
}

# parse a response packet into a hash
sub BUSCH_RADIO_parseResult($) {
	my ($message) = @_;
	my %values;
	for my $line (split(/\r?\n/, $message)) { 
		my ($d, $key, $value) = $line =~ /^(([^:]+):)?(.+)$/;
		$key = $d ? $key : '_';
		# add suffix _1 in case of duplicate key
		my ($suffix, $i) = ('', 1);
		while (defined $values{$key . $suffix}) {
			$suffix = '_' . $i++;
		}  
		$values{$key. $suffix} = $value;
	}
	return \%values;
}

# called when a message was received
sub BUSCH_RADIO_received($$) {
	my ($hash, $message) = @_;
	my $name = $hash->{NAME};
	BUSCH_RADIO_log($name, 4, "BUSCH_RADIO_received($message)");

	my $values = BUSCH_RADIO_parseResult($message);
	# valid response?
	if ($values && $values->{RESPONSE} eq 'ACK' && (my $cmd = $values->{COMMAND})) {
		if ($cmd eq 'NOTIFICATION') {
			BUSCH_RADIO_processNotification($hash, $values);
		} elsif ($cmd eq 'DISCOVER') {
			BUSCH_RADIO_processDiscover($hash, $values);
		} elsif (!$values->{ID} || $values->{ID} ne $hash->{ID}) {
			return undef; # the response is not for this device 
		} else {
	  	    BUSCH_RADIO_updateState($hash, online);
			if ($cmd eq 'GET') {
				BUSCH_RADIO_updateReadings($hash, $values);
			} elsif ($cmd eq 'SET') {
				BUSCH_RADIO_processSetAck($hash, $values);
			} elsif ($cmd eq 'PLAY') {
				# it's not playing yet so we don't update the readings - there will be a notification shortly
			} 
		}
	}

	#Log3($name, 3, "received unknown packet";
}

# update readings from a device response (hashed format)
sub BUSCH_RADIO_updateReadings($$) {
	my ($hash, $values) = @_;
	my $name = $hash->{NAME};
	my $get = $values->{_};
	
	readingsBeginUpdate($hash);
	my $changed = false;
    my $modeChanged = false;
	my $urlChanged = false;
	while (my ($key, $value) = each %$values) {
		my $reading = $BUSCH_RADIO_readingsMap{$get . ':' . $key};
		if (defined $reading) {
			my $valueMap = $readingsValueMaps{$reading};
			if (defined $valueMap) {
				$value = $valueMap->{$value};
			}
			if ($reading eq 'volume') {
				# also handle mute reading
				$changed |= BUSCH_RADIO_updateVolume($hash, $value);
			} else {
				$changed |= BUSCH_RADIO_updateReading($hash, $reading, $value);
				# update derived readings if necessary
				if ($reading eq 'power') {
					$changed |= BUSCH_RADIO_updateState($hash, $value);
				} elsif ($reading eq 'play_mode' || $reading eq 'play_station') {
					$modeChanged = true;
				} elsif ($reading eq 'play_station_name' || $reading eq 'play_url') {
					$urlChanged = true;
				}
			}
		}
	}

    if ($modeChanged) {
        my $mode = ReadingsVal($name, 'play_mode', '');
        my $x = $mode eq'radio' ? 'station_' . ReadingsVal($name, 'play_station', '') : $mode;   
        $changed |= BUSCH_RADIO_updateReading($hash, 'play_mode_x', $x);
    }

    if ($urlChanged) {
        my $url = ReadingsVal($name, 'play_url', '');
        my $name = ReadingsVal($name, 'play_station_name', '');
        $changed |= BUSCH_RADIO_updateReading($hash, 'play_url_x', $name . '|' . $url);
    }

	readingsEndUpdate($hash, $changed);
	return $changed;
}

# handle volume / mute setting
sub BUSCH_RADIO_updateVolume($$;$) {
	my ($hash, $volume, $notify) = @_;
	my $changed = false;
	readingsBeginUpdate($hash) if (defined $notify);
	if ($volume >= 0) {
		$changed |= BUSCH_RADIO_updateReading($hash, 'volume', $volume);
	}
	$changed |= BUSCH_RADIO_updateReading($hash, 'mute', $volume >= 0 ? off : on);
	readingsEndUpdate($hash, $notify && $changed) if (defined $notify);
	return $changed;
}	

# update readings based on an acknowledged SET command
sub BUSCH_RADIO_processSetAck($$) {
	my ($hash, $values) = @_;
	if (my $cmd = $values->{_}) {
		if ($cmd eq 'RADIO_ON') {
			BUSCH_RADIO_updateState($hash, on);
			BUSCH_RADIO_updateReading($hash, 'power', on, true);
		} elsif ($cmd eq 'RADIO_OFF') {
			BUSCH_RADIO_updateState($hash, off);
            BUSCH_RADIO_updateReading($hash, 'power', off, true);
		} elsif ($cmd eq 'VOLUME_MUTE') {
			BUSCH_RADIO_updateVolume($hash, -1, true);
		} elsif ($cmd eq 'VOLUME_UNMUTE') {
			# set reading to last known volume, but don't notify yet
			my $defaultVol = 16;
			my $vol = ReadingsVal($hash->{NAME}, 'volume', $defaultVol);
			$vol = $defaultVol if $vol < 0; # that could happen if started in mute
			BUSCH_RADIO_updateVolume($hash, $vol, false);
			# get the real new volume in case it has changed 
			BUSCH_RADIO_sendCommand($hash, 'GET', 'VOLUME');
		}
	# VOLUME_SET has a value so needs to be treated separately
	} elsif (defined $values->{'VOLUME_SET'}) {
		BUSCH_RADIO_updateVolume($hash, $values->{'VOLUME_SET'}, true);
	}
}

# update status based on device notification packet
sub BUSCH_RADIO_processNotification($$) {
	my ($hash, $values) = @_;
	my $name = $hash->{NAME};
 	# only process notifications from this radio
 	my $ip = ReadingsVal($name, 'ip_address', '');
 	if ($values->{IP} eq $ip) {
  	    BUSCH_RADIO_updateState($hash, online);
 		my $event = $values->{EVENT};
		if ($event eq 'SYSTEM_BOOTED') {
			# request a status update once
			BUSCH_RADIO_Get($hash, $name, 'status');
		} elsif ($event eq 'POWER_ON') {
            BUSCH_RADIO_updateReading($hash, 'power', on, true);
			BUSCH_RADIO_updateState($hash, on);
		} elsif ($event eq 'POWER_OFF') {
            BUSCH_RADIO_updateReading($hash, 'power', off, true);
			BUSCH_RADIO_updateState($hash, off);
		} elsif ($event eq 'VOLUME_CHANGED') {
            BUSCH_RADIO_updateState($hash, on);
			# get the new volume
			BUSCH_RADIO_sendCommand($hash, 'GET', 'VOLUME');
		} elsif ($event eq 'STATION_CHANGED' || $event eq 'URL_IS_PLAYING')  {
            BUSCH_RADIO_updateState($hash, on);
			BUSCH_RADIO_sendCommand($hash, 'GET', 'PLAYING_MODE');
		} elsif ($event eq 'TUNEIN_INIT_COMPLETE' || $event eq 'TUNEIN_FAVORITE_CMD_FINISHED') {
			# ...
		} else {
			Log3($name, 3, "received unknown NOTIFICATION:$event");
		}
	}
}

# update status based on DISCOVER packet
sub BUSCH_RADIO_processDiscover($$) {
	my ($hash, $values) = @_;
	my $name = $hash->{NAME};
	if ($hash->{STATE} eq host_error) {
		# if the host was unresolvable we cannot tell if this discover packet is really for us 
		Log3($name, 2, "error: received DISCOVER but host is not valid.");
		return;
	}
	# process discover response only if it's for the same IP address or there is no IP address yet, 
	# or if the IP address is different but the name matches (that should support DHCP IP changes)
	my $ip = ReadingsVal($name, 'ip_address', undef);
	my $deviceName = ReadingsVal($name, 'device_name', undef);
	if (!$ip || $values->{IP} eq $ip || $values->{NAME} eq $deviceName) { 
		BUSCH_RADIO_updateState($hash, online);
		$values->{_} = 'DISCOVER'; # make this work with updateReadings
		BUSCH_RADIO_updateReadings($hash, $values);
		if (!$ip) { # update everything once if it's the first discovery
			BUSCH_RADIO_Get($hash, $name, 'update_info');
		}
	}
}

# open and register the UDP listener socket
sub BUSCH_RADIO_startListener($) {
    my ($hash) = @_;
	my $name = $hash->{NAME};
	my $port = AttrVal($name, 'UDPListenPort', DEFAULT_UDP_LISTEN_PORT);

	BUSCH_RADIO_stopListener($hash);

	my $socket = new IO::Socket::INET(LocalPort => $port, Proto => 'udp', Type => SOCK_DGRAM, Reuse => true);
	if (!$socket) {
	    Log3($name, 2, "error opening UDP socket");
	} else {
		$hash->{udpSocket} = $socket; 
		$hash->{FD} = $socket->fileno();
		$selectlist{"$name.UDP"} = $hash;
	    Log3($name, 4, "UDP listener started on port $port");
	}
}

# Close the UDP listener socket
sub BUSCH_RADIO_stopListener($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    my $socket = $hash->{udpSocket};
    if ($socket) {
    	$socket->close();
    	delete $selectlist{"$name.UDP"};
    	$hash->{FD} = undef;
    	$hash->{udpSocket} = undef;
	    Log3($name, 4, "UDP listener stopped");
    }
}

# Timer function: update status & retrigger timer
sub BUSCH_RADIO_timer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $status = $hash->{STATE};

   	my $now = gettimeofday();
    my $timer = AttrVal($name, 'timer', DEFAULT_TIMER);

    if ($status eq offline) {
    	BUSCH_RADIO_Get($hash, $name, 'discover');
    } elsif ($status eq on || $status eq online) {
    	# do a full update every when due, otherwise only status update
        my $lastFullUpdate = $hash->{'last_full_update'}; 
    	my $fullUpdateInterval = AttrVal($name, 'fullUpdateInterval', DEFAULT_FULL_UPDATE_INTERVAL);
    	if ($fullUpdateInterval > 0 && (!defined $lastFullUpdate || $now - $lastFullUpdate >= $fullUpdateInterval)) {
			BUSCH_RADIO_Get($hash, $name, 'update_info');
			$hash->{'last_full_update'} = $now;
    	} else {
			BUSCH_RADIO_Get($hash, $name, 'status');
    	}
    	
        # if the device hasn't replied for one minute it is probably off(line)
        my $lastReply = $hash->{last_ack};
        if (defined $lastReply && $now - $lastReply > DEAD_TIMER) {
            BUSCH_RADIO_updateReading($hash, 'power', off, true);            
            BUSCH_RADIO_updateState($hash, offline);
        }
    } elsif ($status eq 'off') {
    	# nothing. The device will announce itself when powered on.
    }
    
    # schedule next timer
    if ($timer > 0) {
	    InternalTimer($hash->{'next_timer'} = $now + $timer, \&BUSCH_RADIO_timer, $hash);
    }
}


# ----------------------------------------------------------------------------
# Independent helper functions
# ----------------------------------------------------------------------------

# update a reading value (bulk update) only if it has changed
sub BUSCH_RADIO_updateReading($$$;$) {
    my ($hash, $reading, $value, $single) = @_;
    my $name = $hash->{NAME};
    my $old = ReadingsVal($name, $reading, undef);
    if (defined $old ? (!defined $value || $old ne $value) : defined $value) {
    	if ($single) {
            readingsSingleUpdate($hash, $reading, $value, true);
    	} else {   
            readingsBulkUpdate($hash, $reading, $value);
    	}
        return true;
    } else {
        return false;
    }
}

# send an UDP packet
sub BUSCH_RADIO_sendUDP($$$$) {
	my ($addr, $port, $broadcast, $message) = @_;

	BUSCH_RADIO_log(4, "BUSCH_RADIO_sendUDP($addr, $port, $message)");
	my $socket = IO::Socket::INET->new(Proto => 'udp', Type => SOCK_DGRAM, PeerAddr => $addr, PeerPort => $port,
		Broadcast => $broadcast);
	if (!$socket) {
		Log(3, "error opening UDP connection: " . $@);
	} else {
		$socket->send($message);
		$socket->close();
	}
}

# resolve hostname to IP address
sub BUSCH_RADIO_resolve($) {
	my ($host) = @_;
	my $addr = gethostbyname($host);
	return $addr ? join('.', unpack('C4', $addr)) : undef;
}

# get broadcast address for IP address
sub BUSCH_RADIO_getBroadcastAddress($) {
	my ($address) = @_;
	# this is quite far from the truth but will work in many cases (not all though)
	$address =~ s/[0-9]+$/255/;
	return $address;
}

# log with escaped non-printable chars
sub BUSCH_RADIO_log($$;$) {
	my $name;
	if (@_ >= 3) {
		$name = shift;
	}
	my ($level, $message) = @_;

	if (defined $name) {
		Log3($name, $level, BUSCH_RADIO_escape($message));
	} else {
		Log($level, BUSCH_RADIO_escape($message));
	}	
}

# replace some non-printable chars
sub BUSCH_RADIO_escape($) {
	my ($string) = @_;
	$string =~ s/\\/\\\\/g;
	$string =~ s/\r/\\r/g;
	$string =~ s/\n/\\n/g;
	return $string;
}

# ############################################################################
#  No PERL code beyond this line
# ############################################################################
1;

=pod
=item device
=item summary Control Busch-Radio iNet device
=item summary_DE Steuerung von Busch-Radio iNet
=begin html
<a name="BUSCH_RADIO"></a>
<h3>BUSCH_RADIO</h3>
<ul>
    <p><strong>Definition</strong> <code>define &lt;name&gt; BUSCH_RADIO [&lt;address&gt;]</code></p>
    <p>
    	Defines the Busch-Radio device with an optional address.
    	<br>
        Without any parameter this defines a device and broadcasts a <i>discover</i> command to find actual device.
        If you have more than one Radios, this is probably not what you want. In that case you should specify the IP 
        address or host name during definition. Otherwise you will randomly get one (which could change after restart).
        <br>
        If you use dynamic DHCP IP addresses for the devices you should better make sure they don't change.  
    </p> 
    <p>
        Example: <code>define Radio BUSCH_RADIO 192.168.0.10</code>
    </p>
    <p><strong>Set Commands</strong> <code>set &lt;name&gt; &lt;command&gt; [&lt;Parameter&gt;]</code></p>
    <p>
        The following <i>set</i> commands are currently supported:
        <ul>
            <li><strong>power</strong> on|off </li>
            <li><strong>on</strong></li>
            <li><strong>off</strong></li>
            <li><strong>volume</strong> &lt;0..31&gt; </li> 
            <li><strong>volume_up</strong></li> 
            <li><strong>volume_down</strong></li> 
            <li><strong>mute</strong> on|off </li>
			<li><strong>play_mode</strong> radio|tunein|upnp|aux </li> 
			<li><strong>play_mode_x</strong> tunein|upnp|aux|station_&lt;1..8&gt; </li>
			<li><strong>play_station</strong> &lt;1..8&gt; </li>
			<li><strong>play_url_x</strong> [&lt;name&gt;|]&lt;url&gt; </li>
			<li><strong>play_station_name</strong> &lt;name&gt; </li>
        </ul>
    </p>
    <p><strong>Get Command</strong> <code>get &lt;name&gt; &lt;command&gt;</code></p>
    <p>
        The following <i>get</i> commands are supported:
        <ul>
            <li><strong>discover</strong>: discover a device (update IP address)</li>
            <li><strong>status</strong>: retrieve basic status information</li>
            <li><strong>update_info</strong>: update all readings</li>
        </ul>
    </p>
    <p><strong>Attributes</strong></p>
    <p>
        <ul>
            <li><strong>host</strong> host name / IP address </li>
            <li><strong>broadcastAddress</strong> broadcast IP address </li>
            <li><strong>UDPPort</strong> target UDP port (default: 4244) </li>
            <li><strong>UDPListenPort</strong> UDP listener port (default: 4242) </li>
            <li><strong>timer</strong> status poll timer [s] (default: 60s; 0 disables the timer) </li>
            <li><strong>fullUpdateInterval</strong> every n timer ticks a full readings update is triggered 
                (default: 86400 = 24h)</li>
        </ul>
    </p>
    <p>
		Some useful standard attributes:
		<ul>
			<li><code>webCmd = volume:mute:play_mode_x</code></li>
			<li><code>widgetOverride = \ <br>
			volume:knob,min:0,max:31,step:1,width:50,height:50,anglearc:270,angleoffset:225 \ <br>
			mute:iconSwitch,on,rc_MUTE,off,rc_VOLUP \ <br>
			play_mode_x:iconRadio,#808080,station_1,rc_1@green,station_2,rc_2@green,station_3,rc_3@green,station_4,\ <br>
			&nbsp;&nbsp;rc_4@green,station_5,rc_5@green,station_6,rc_6@green,station_7,rc_7@green,station_8,\ <br>
			&nbsp;&nbsp;rc_8@green,tunein,rc_AUDIO@green,upnp,rc_USB@green,aux,rc_AV@green</code></li>
		</ul>
    </p>
</ul>
=end html

=begin html_DE
<a name="BUSCH_RADIO"></a>
<h3>BUSCH_RADIO</h3>
<ul>
    <p><strong>Definition</strong> <code>define &lt;name&gt; BUSCH_RADIO [&lt;address&gt;]</code></p>
    <p>
        Definiert ein Busch-Radio mit optionaler Adresse.
        <br>
        Ohne Parameter wird ein Device definiert und via UDP-Broadcast versucht, das Radio zu finden.
        Wenn man mehrere Radios betreibt, ist nicht klar, welches Radio zuerst antwortet. Daher sollte man in diesem
        Fall besser die IP-Adresse jedes Geräts beim Define angeben.
        <br>
        Das Modul versucht, IP-Adressen zu aktualisieren, wenn sich diese ändern. Sicherer funktioniert es aber, wenn 
        der DHCP-Server so eingestellt wird, dass sich die Adressen der Busch-Radios nicht ändern. 
    </p> 
    <p>
        Beispiel: <code>define Radio BUSCH_RADIO 192.168.0.10</code>
    </p>
    <p><strong>Set-Befehle</strong> <code>set &lt;name&gt; &lt;command&gt; [&lt;Parameter&gt;]</code></p>
    <p>
        Folgende <i>set</i>-Befehle werden derzeit unterstützt:
        <ul>
            <li><strong>power</strong> on|off </li>
            <li><strong>on</strong></li>
            <li><strong>off</strong></li>
            <li><strong>volume</strong> &lt;0..31&gt; </li> 
            <li><strong>volume_up</strong></li> 
            <li><strong>volume_down</strong></li> 
            <li><strong>mute</strong> on|off </li>
            <li><strong>play_mode</strong> radio|tunein|upnp|aux </li> 
            <li><strong>play_mode_x</strong> tunein|upnp|aux|station_&lt;1..8&gt; </li>
            <li><strong>play_station</strong> &lt;1..8&gt; </li>
            <li><strong>play_url_x</strong> [&lt;name&gt;|]&lt;url&gt; </li>
            <li><strong>play_station_name</strong> &lt;name&gt; </li>
        </ul>
    </p>
    <p><strong>Get-Befehle</strong> <code>get &lt;name&gt; &lt;command&gt;</code></p>
    <p>
        Folgende <i>get</i>-Befehle werden unterstützt:
        <ul>
            <li><strong>discover</strong>: Sucht das Gerät und aktualisiert die IP-Adresse</li>
            <li><strong>status</strong>: Holt Status-Informationen</li>
            <li><strong>update_info</strong>: Aktualisiert alle Readings</li>
        </ul>
    </p>
    <p><strong>Attribute</strong></p>
    <p>
        <ul>
            <li><strong>host</strong> Hostname / IP-Adresse </li>
            <li><strong>broadcastAddress</strong> Broadcast IP-Adresse </li>
            <li><strong>UDPPort</strong> Ziel-UDP-Port (Standard: 4244) </li>
            <li><strong>UDPListenPort</strong> UDP-Rückkanal-Port (Standard: 4242) </li>
            <li><strong>timer</strong> Timer für Status-Polling [Sek.] (Standard: 60s; 0 schaltet das Polling ab) </li>
            <li><strong>fullUpdateInterval</strong> Timer für komplettes Update (Standard: 86400s = 24h)</li>
        </ul>
    </p>
    <p>
        Einige nützliche Settings für Standard-Attribute:
        <ul>
            <li><code>webCmd = volume:mute:play_mode_x</code></li>
            <li><code>widgetOverride = \ <br>
            volume:knob,min:0,max:31,step:1,width:50,height:50,anglearc:270,angleoffset:225 \ <br>
            mute:iconSwitch,on,rc_MUTE,off,rc_VOLUP \ <br>
            play_mode_x:iconRadio,#808080,station_1,rc_1@green,station_2,rc_2@green,station_3,rc_3@green,station_4,\ <br>
            &nbsp;&nbsp;rc_4@green,station_5,rc_5@green,station_6,rc_6@green,station_7,rc_7@green,station_8,\ <br>
            &nbsp;&nbsp;rc_8@green,tunein,rc_AUDIO@green,upnp,rc_USB@green,aux,rc_AV@green</code></li>
        </ul>
    </p>
</ul>
=end html_DE

=cut
