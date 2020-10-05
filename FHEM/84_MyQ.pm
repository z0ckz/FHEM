################################################################################
# $Id: 84_MyQ.pm$
#
# FHEM Module for MyQ garage doors
#
# Written by zockz@gmx.net
#
################################################################################
# Changelog:
# 2020-10-04 Initial version
################################################################################

package main;
use strict;
use warnings;
use IO::Socket;
use Time::HiRes qw(gettimeofday);
#use HttpUtils;
use JSON;

# used external global variables from FHEM
use vars qw(%defs %modules %attr %selectlist $readingFnAttributes $init_done);

# global definitions
use constant { false => 0, true => 1 }; 
use constant { 
	MYQ_API_URL => 'https://api.myqdevice.com/api/v5',
	MYQ_API_URL_2 => 'https://api.myqdevice.com/api/v5.1',
	MYQ_R_LOGIN => 'Login',
	MYQ_R_MAIN => 'My?expand=account',
    MYQ_R_ACCOUNT => 'Accounts',
    MYQ_R_DEVICE => 'Devices',
    MYQ_R_ACTION => 'actions',
    MYQ_DEVICE_TYPE => 'garagedooropener',
};

my %MYQ_DEFAULT_TIMER = (
    'timer' => 60,
    'fast_timer' => 5,
    'slow_timer' => 1800,
);

# status definitions
use constant { 
	MYQ_offline => 'offline',
	MYQ_unauthorized => 'unauthorized', 
	MYQ_no_device => 'no_device', 
	MYQ_unknown => 'unknown', 
	MYQ_closed => 'closed', 
	MYQ_open => 'open', 
	MYQ_closing => 'closing', 
	MYQ_opening => 'opening'
}; 

my %MYQ_HEADERS = (
    USER_AGENT => 'User-Agent: myQ/19569 CFNetwork/1107.1 Darwin/19.0.0',
    CONTENT_TYPE => 'Content-Type: application/json',
    APP_ID => 'MyQApplicationId: JVM/G9Nwih5BwKgNCjLxiFUQxQijAebyyg8QUHr7JOrP+tuPb8iHfRHKwTmDzHOu',
    API_VERSION => 'ApiVersion: 5.1'
);

# ----------------------------------------------------------------------------
# FHEM API
# ----------------------------------------------------------------------------

#  Initialize: Initialisation routine called upon start-up of FHEM
sub MyQ_Initialize($) {
    my ($hash) = @_;
    
    my %FUNCTION_MAP = (
        DefFn => 'MyQ_Define',
        UndefFn => 'MyQ_Undef',
        ShutdownFn => 'MyQ_Shutdown',
        GetFn => 'MyQ_Get',
        SetFn => 'MyQ_Set',
        AttrFn => 'MyQ_Attr',
    );
    
    @{$hash}{keys %FUNCTION_MAP} = values %FUNCTION_MAP;
    $hash->{AttrList} = join(' ', ('device', keys(%MYQ_DEFAULT_TIMER), $readingFnAttributes));
}

#  Define: called when defining a device in FHEM
sub MyQ_Define($$) {
    my ($hash, $def) = @_;
    MyQ_log($hash->{NAME}, 4, "MyQ_Define($def)");

    # do we have the right number of arguments?
    my @args = split(/\s+/, $def);
    if (@args < 4 || @args > 5) {
        return "wrong syntax: define <name> MyQ <user> <password> [<device name>]";
    }

    my ($name, $dummy, $user, $password, $device) = @args;
    $hash->{ID} = $name;
    $hash->{username} = $user;
    $hash->{INTERNALS}->{password} = $password;
   	$attr{$name}{'device'} = $device if ($device);

    MyQ_updateStatus($hash, MYQ_offline); # until we know better...

    # initialize readings on 1st define
#    if ($init_done) {
#        readingsBeginUpdate($hash);
#        for my $reading (values %MyQ_readingsMap) {
#            readingsBulkUpdate($hash, $reading, '');
#        }
#        readingsEndUpdate($hash, false);
#    }

    # start the timer for polling the status right now
    InternalTimer(gettimeofday(), \&MyQ_timer, $hash);
    
    return undef;
}

#  Undef: called when deleting a device
sub MyQ_Undef($$) {
    return MyQ_Shutdown(@_);
}

#  Shutdown: called before FHEM shuts down
sub MyQ_Shutdown($$) {
    my ($hash, $dev) = @_;
    RemoveInternalTimer($hash);
    if ($hash->{running_http_req}) {
    	HttpUtils_Close($hash->{running_http_req});
    	delete $hash->{running_http_req};
    }
    return undef;
}

#  Attr: set an attribute
sub MyQ_Attr($$$@) {
    my ($cmd, $name, $attr, @args) = @_;
    my $hash = $defs{$name};
    MyQ_log($name, 5, "MyQ_Attr($cmd, $attr, " . join(', ', @args) . ')');
    
    if (defined $MYQ_DEFAULT_TIMER{$attr}) {
        if (@args != 1 || $args[0] <= 0) {
        	return "cannot set attribute '$attr' to (" . join(', ', @args) . ")";
        } elsif ($attr eq $hash->{current_timer}) {
 	    	MyQ_updateTimer($hash, $args[0]);
   	    }
    } elsif ($attr eq 'device' && @args == 1) {
    	$hash->{device} = undef;
    	MyQ_updateStatus($hash, MYQ_no_device);
    	MyQ_determineNextCommand($hash);
    }
    return undef; 
}

#  Get: perform a get function
sub MyQ_Get($$$@) {
    my ($hash, $name, $opt, @args) = @_;
    MyQ_log($name, 5, "MyQ_Get($opt, @args)");

    if ($opt eq 'status') {
    	MyQ_determineNextCommand($hash);
    } else {
        return "Unknown argument $opt, choose one of status:noArg";
    }

    return undef;
}

#  Set: perform a set function
sub MyQ_Set($@) {
    my ($hash, $name, $cmd, @args) = @_;
    MyQ_log($name, 5, "MyQ_Set($cmd, " . join(', ', @args) . ')');

    if($cmd eq 'open' || $cmd eq 'close') {
    	if(@args != 0) {
            MyQ_log($name, 2, "invalid additional arguments"); 
        } elsif ($hash->{device_id}) {
    	   MyQ_getHttpAsync($hash, $hash->{device_resource} . '/' . $hash->{device_id} . '/' . MYQ_R_ACTION, 
    	       { action_type =>" $cmd" });
    	   MyQ_updateStatus($hash, $cmd eq 'open' ? MYQ_opening : MYQ_closing);
    	} else {
    		MyQ_log($name, 2, "cannot perform command $cmd, no device");
    	}
    } else  {
        return "Unknown argument $cmd, choose one of open:noArg close:noArg";
    }
    
    return undef;
}

# ----------------------------------------------------------------------------
# MyQ internal workings
# ----------------------------------------------------------------------------

sub MyQ_getHttpAsync($$;$) {
    my ($hash, $resource, $data) = @_;
    my $name = $hash->{NAME};

    my $url = MYQ_API_URL;
    # for the device resource, the whole path is different
    if (rindex($resource, MYQ_R_DEVICE) >= 0) {
    	$url = MYQ_API_URL_2;
    }

    my @headers = values(%MYQ_HEADERS);
    if ($hash->{security_token}) {
    	push(@headers, "SecurityToken: $hash->{security_token}");
    }

    if ($data) {
    	$data = to_json($data);
    	MyQ_log($name, 5, "POST data: $data"); 
    }
    
    my $method = $data ? rindex($resource, MYQ_R_ACTION) >= 0 ? 'PUT' : 'POST' : 'GET';
    my $param = {
        url => $url . '/' . $resource,
        hash => $hash,
        timeout => 5,
        resource => $resource,
        method => $method,
        data => $data,
        header => join("\r\n", @headers),
        callback => \&MyQ_parseHttpResponse
    };
    
    MyQ_log($name, 5, "requesting $param->{url}"); 

    $hash->{running_http_req} = $param;
    HttpUtils_NonblockingGet($param); 
}

sub MyQ_parseHttpResponse($) {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    delete $hash->{running_http_req};

    MyQ_log($hash->{NAME}, 5, "received code: $param->{code} response: $data");
    if ($err || $param->{code} >= 400)  {
    	delete $hash->{security_token} if $param->{code} == 401;
        MyQ_log($hash->{NAME}, 3, "error while requesting " . $param->{url} . " - $err ($param->{code})");
        MyQ_updateStatus($hash, MYQ_unknown);
    } elsif ($data) {
    	if (!MyQ_processResponse($hash, $param->{resource}, from_json($data))) {
            MyQ_log($hash->{NAME}, 3, "couldn't handle $param->{url} response: $data");
    	}
    }
}

sub MyQ_processResponse($$$) {
    my ($hash, $resource, $response) = @_;	
    if ($resource eq MYQ_R_LOGIN) {
    	if ($response->{SecurityToken}) {
    		$hash->{security_token} = $response->{SecurityToken};
    		MyQ_determineNextCommand($hash);
    		return true;
    	} else {
            MyQ_updateStatus(MYQ_unauthorized);
    	}
    } elsif ($resource eq MYQ_R_MAIN) {
    	if ($hash->{account_id} = $response->{Account}->{Id}) {
    		$hash->{device_resource} = MYQ_R_ACCOUNT . '/' . $hash->{account_id} . '/' . MYQ_R_DEVICE;
    		MyQ_determineNextCommand($hash);
            return true;
    	}
    } elsif ($resource eq $hash->{device_resource}) {
    	# find the specified device or just take the first garage door opener
    	my $fixed = AttrVal($hash->{NAME}, 'device', undef);
    	foreach my $dev (@{$response->{items}}) {
    		if ($fixed ? $dev->{name} eq $fixed : $dev->{device_type} eq MYQ_DEVICE_TYPE) {
    			$hash->{device_id} = $dev->{serial_number};
    			return MyQ_updateDeviceReadings($hash, $dev);
    		}
    	}
        if ($fixed) {
            MyQ_log($hash->{NAME}, 2, "couldn't find specified device: $fixed");
        } else {
        	MyQ_updateStatus($hash, MYQ_no_device);
        }
    } elsif ($resource eq $hash->{device_resource} . '/' . $hash->{device_id}) {
    	return MyQ_updateDeviceReadings($hash, $response);
    }
    
    return false;
}

sub MyQ_updateDeviceReadings($$) {
	my ($hash, $response) = @_; 
    if ($response->{device_type} ne MYQ_DEVICE_TYPE) {
        MyQ_log($hash->{NAME}, 3, "warning: device type $response->{device_type} may be unsupported");
    }
    my $state = $response->{state}->{door_state};
    if ($state) {
	    MyQ_updateStatus($hash, $state);
	    # TODO extract some readings:
	    return true;
    }
    return false;
}

sub MyQ_determineNextCommand($) {
	my ($hash) = @_;
	if (!$hash->{security_token}) {
		my $login = { UserName => $hash->{username}, Password => $hash->{INTERNALS}->{password} };
        MyQ_getHttpAsync($hash, MYQ_R_LOGIN, $login);
	} elsif (!$hash->{account_id}) {
        MyQ_getHttpAsync($hash, MYQ_R_MAIN);
	} elsif (!$hash->{device_id}) {
		MyQ_getHttpAsync($hash, $hash->{device_resource});
	} else {
        MyQ_getHttpAsync($hash, $hash->{device_resource} . '/' . $hash->{device_id});
	}
}

sub MyQ_updateStatus($$) {
    my ($hash, $status) = @_;
    $hash->{STATE} = $status;
    my $timer = MyQ_whichTimer($status);
    $hash->{current_timer} = $timer;
    my $time = AttrVal($hash->{NAME}, $timer, $MYQ_DEFAULT_TIMER{$timer});
    MyQ_updateTimer($hash, $time, true);
}

sub MyQ_whichTimer($) {
	my ($status) = @_;
	if ($status eq MYQ_offline || $status eq MYQ_unauthorized || $status eq MYQ_no_device) {
        return 'slow_timer';
    } elsif ($status eq MYQ_opening || $status eq MYQ_closing) {
        return 'fast_timer';
    } else {
    	return 'timer';
    }
}

sub MyQ_updateTimer($$;$) {
	my ($hash, $time, $force) = @_;
    # restart the timer only if the new interval is shorter than the remaining time slice 
    my $next = gettimeofday() + $time;
    if (!defined $hash->{'next_timer'} || $hash->{'next_timer'} > $next || $force) {
        RemoveInternalTimer($hash);
        InternalTimer($hash->{'next_timer'} = $next, \&MyQ_timer, $hash);
    }
}
    
# Timer function: update status & retrigger timer
sub MyQ_timer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $status = $hash->{STATE};
    my $now = gettimeofday();

    MyQ_determineNextCommand($hash);
    
    # schedule next timer
    my $timer = MyQ_whichTimer($status);
    $hash->{current_timer} = $timer;
    my $time = AttrVal($name, $timer, $MYQ_DEFAULT_TIMER{$timer});
    MyQ_updateTimer($hash, $time, true);
}

# ----------------------------------------------------------------------------
# Independent helper functions
# ----------------------------------------------------------------------------

# log with escaped non-printable chars
sub MyQ_log($$;$) {
    my $name = shift if (@_ >= 3);
    my ($level, $message) = @_;

    if (defined $name) {
        Log3($name, $level, MyQ_escape($message));
    } else {
        Log($level, MyQ_escape($message));
    }   
}

# replace some non-printable chars
sub MyQ_escape($) {
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
=item summary Control MyQ garage doors
=item summary_DE Steuerung von Garagentoren via MyQ
=begin html
<a name="MyQ"></a>
<h3>MyQ</h3>
<ul>
</ul>
=end html

=begin html_DE
<a name="MyQ"></a>
<h3>MyQ</h3>
<ul>
</ul>
=end html_DE

=cut
