###########################################################
#
# HomeMatic XMLRPC API Device Provider
# Written by Oliver Wagner <owagner@vapor.com>
#
# V0.5
#
###########################################################
#
# This module implements the documented XML-RPC based API
# of the Homematic system software (currently offered as 
# part of the CCU1 and of the LAN config adapter software)
#
# This module operates a http server to receive incoming
# xmlrpc event notifications from the HM software.
#
# Individual devices are then handled by 01_HMDEV.pm
#
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use RPC::XML::Server;
use RPC::XML::Client;
use Dumpvalue;
use HttpUtils;

my $dumper=new Dumpvalue;
$dumper->veryCompact(1);

sub HMRPC_Initialize($)
{
	my ($hash) = @_;

	$hash->{DefFn} = "HMRPC_Define";
	$hash->{ShutdownFn} = "HMRPC_Shutdown";
	$hash->{SetFn} = "HMRPC_Set";
	$hash->{GetFn} = "HMRPC_Get";
	$hash->{Clients} = ":HMDEV:";
}

#####################################
sub
HMRPC_Shutdown($)
{
	my ($hash) = @_;
	# Uninitialize again
	if($hash->{callbackurl})
	{
		Log(2,"HMRPC unitializing callback ".$hash->{callbackurl});
		$hash->{client}->send_request("init",$hash->{callbackurl});
	}
	return undef;
}

#####################################
sub
HMRPC_Define($$)
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);

	if(@a != 4) {
		my $msg = "wrong syntax: define <name> HMRPC remote_host remote_port";
		Log 2, $msg;
		return $msg;
	}

	my $name = $a[0];
	$hash->{serveraddr}=$a[2];
	$hash->{serverport}=$a[3];
	
	$hash->{client}=RPC::XML::Client->new("http://$a[2]:$a[3]/");
	my $callbackport=5400+$hash->{serverport};
	$hash->{server}=RPC::XML::Server->new(no_http=>1);
	if(!ref($hash->{server}))
	{
		# Creating the server failed, perhaps because the port was
		# already in use. Just return the message
		Log 1,"Can't create HMRPC callback server on port $callbackport. Port in use?";
		return $hash->{server};
	}
	
	$hash->{server}->{fhemdef}=$hash;
	
	# Add the XMLRPC methods we do expose
	$hash->{server}->add_method(
		{name=>"event",signature=> ["string string string string int","string string string string double","string string string string boolean","string string string string i4"],code=>\&HMRPC_EventCB}
	);
	$hash->{server}->add_method(
		{name=>"newDevices",signature=>["array string array"],code=>\&HMRPC_NewDevicesCB }
	);
	#
	# Dummy implementation, always return an empty array
	#
	$hash->{server}->add_method(
		{name=>"listDevices",signature=>["array string"],code=>sub{return RPC::XML::array->new()} }
	);
	
	my $link = "HMRPC_$name";
	my $url = "/$link";
	Log3 $name, 3, "Registering HMRPC $name for URL $url...";
	$data{FWEXT}{$url}{deviceName}= $name;
	$data{FWEXT}{$url}{FUNC} = "HMRPC_CGI";


	$hash->{STATE} = "Initialized";
	
	# This will also register the callback
	HMRPC_CheckCallback($hash);

	#
	# All is well
	#
	return 0;
}

sub
HMRPC_CGI() {
	my ($request) = @_;   # /$infix/filename
	
	if($request =~ m,^(/[^/]+)(?:/([^&]*)?(?:&(.*))?)?$,s) {
		my $link    = $1;
		my $filename= $2;
		my $content = $3;
		my $name;

		# get device name
		$name= $data{FWEXT}{$link}{deviceName} if($data{FWEXT}{$link});

		#Debug "link= $link";
		#Debug "filename= $filename";
		#Debug "name= $name";
		#Debug "content= $content";

		my $response;
		# return error if no such device
		if($name eq "") {
			$response = RPC::XML::response->new( RPC::XML::fault->new(404, "No such device") );
		} elsif($content eq "") {
			$response = RPC::XML::response->new( RPC::XML::fault->new(400, "No XML content provided") );
		} else {
			my $hash = $defs{$name};
			$response = $hash->{server}->dispatch($content);
		}

		my $buf;
		utf8::encode($buf = $response->as_string);
		
		return("text/xml", $buf);
	} else {
		return("text/plain; charset=utf-8", "Illegal request: $request");
	}
}   


sub
HMRPC_CheckCallback($)
{
	my ($hash) = @_;
	# We recheck the callback every 15 minutes. If we didn't receive anything
	# inbetween, we re-init just to make sure (CCU reboots etc.)
	InternalTimer(gettimeofday()+(15*60), "HMRPC_CheckCallback", $hash, 0);
	if(!$hash->{lastcallbackts})
	{
		HMRPC_RegisterCallback($hash);
		return;
	}
	my $age=int(gettimeofday()-$hash->{lastcallbackts});
	if($age>(15*60))
	{
		Log 5,"HMRPC Last callback received more than $age seconds ago, re-init-ing"; 
		HMRPC_RegisterCallback($hash);
	}
}

sub
HMRPC_RegisterCallback($)
{
	my ($hash) = @_;
	
	#
	# We need to find out our local address. In order to do so,
	# we establish a dummy connection to the remote xmlrpc server
	# and then look at the local socket address assigned to us.
	#
	my $dummysock=IO::Socket::INET->new(PeerAddr=>$hash->{serveraddr},PeerPort=>$hash->{serverport});
	if(!$dummysock)
	{
		Log(2,"HMRPC unable to connect to ".$hash->{serveraddr}.":".$hash->{serverport}." ($!), will retry later");
		return;
	}
	
	my $name = $hash->{NAME};
	$hash->{callbackurl}="http://".$dummysock->sockhost().":8083/fhem/HMRPC_$name/request";
	$dummysock->close();
	Log(2, "HMRPC callback listening on $hash->{callbackurl}");
	# We need to fork here, as the xmlrpc server will synchronously call us
	if(!fork())
	{
		$hash->{client}->send_request("init",$hash->{callbackurl},"CB1");
		Log(2, "HMRPC callback with URL ".$hash->{callbackurl}." initialized");	
		exit(0);
	}
}

#####################################
# Process device info
sub
HMRPC_NewDevicesCB($$$)
{
	my ($server, $cb, $a) = @_;
	
	my $hash=$server->{fhemdef};
	
	Log(2,"HMRPC received ".scalar(@$a)." device specifications");
	
	# We receive an array of hashes with the device information. We
	# store those hashes again in a hash, keyed by address, for later
	# use by the individual devices
	for my $dev (@$a)
	{
		my $addr=$dev->{ADDRESS};
		$hash->{devicespecs}{$addr}=$dev;
	}
	return RPC::XML::array->new();
}

#####################################
sub
HMRPC_EventCB($$$$$)
{
	my ($server,$cb,$devid,$attr,$val)=@_;
	
	Log(5, "Processing event setting $devid->$attr=$val" );
	Dispatch($server->{fhemdef},"HMDEV $devid $attr $val",undef);
	$server->{fhemdef}->{lastcallbackts}=gettimeofday();
}

################################
#
#
sub
HMRPC_Set($@)
{
	my ($hash, @a) = @_;

	#return "invalid set specification @a" if(@a != 4 && @a != 5);
	
	my $cmd=$a[1];
	
	if($cmd eq "req")
	{
		# Send a raw xmlrpc request and return the result in 
		# text form. This is mainly useful for diagnostics.
		shift @a;
		shift @a;
		my $ret=$hash->{client}->simple_request(@a);
		# We convert using Dumpvalue. As this only prints, we need
		# to temporarily redirect STDOUT
		my $res="";
		open(my $temp,"+>",\$res);
		my $oldout=select($temp);
		$dumper->dumpValue($ret);
		close(select($oldout));
		return $res;
	}
	elsif($cmd eq "?")
	{
		return "Unknown argument $cmd, choose one of req";
	}

	
	my $ret;
	if(@a==5)
	{
		my $paramset={$a[3]=>$a[4]};
		
		$ret=$hash->{client}->simple_request("putParamset",$a[1],$a[2],$paramset);
	}
	else
	{
		$ret=$hash->{client}->simple_request("setValue",$a[1],$a[2],$a[3]);
	}
	
	if($ret)
	{
		return $ret->{faultCode}.": ".$ret->{faultString};		
	}
	else
	{
		return undef;
	}
}

################################
#
#
sub
HMRPC_Get($@)
{
	my ($hash,@a) = @_;
	
	return "Unknown argument ? choose one of " if ($a[1] eq "?");
	
	return "argument missing, usage is <id> <attribute> @a" if(@a!=3);	
	my $ret=$hash->{client}->simple_request("getValue",$a[1],$a[2]);
	if(ref($ret))
	{
		return $ret->{faultCode}.": ".$ret->{faultString};		
	}
	return $ret;
}


1;
