package Plugins::CommunityFirmware::Crashlog;

use strict;

use File::Spec::Functions qw(catfile);
use JSON::XS qw(decode_json encode_json);

use Slim::Utils::Log;
use Slim::Utils::OSDetect;
use Slim::Utils::Misc;
use Slim::Player::Client;

use constant MAX_UPLOAD_SIZE => 1024 * 1024;
use constant MAX_DUMPS => 10;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.communityfirmware',
	'defaultLevel' => 'ERROR',
	'description'  => 'PLUGIN_COMMUNITY_FIRMWARE_NAME',
});


sub init {
	Slim::Web::Pages->addRawFunction("plugins/CommunityFirmware/crashlog", \&handleCrashlog);
	purgeCrashlogs();
}

sub handleCrashlog {
	my ($httpClient, $response) = @_;

	my $request = $response->request;
	my $result = {};

	main::INFOLOG && $log->is_info && $log->info("Receiving new crashlog. Size: " . formatKB($request->content_length));

	purgeCrashlogs();

	if ($request->method() ne 'POST') {
		$result = {
			error => 'Invalid request',
			code  => 400,
		};
	}
	elsif ( $request->content_length > MAX_UPLOAD_SIZE ) {
		my $size = formatKB($request->content_length);
		$result = {
			error => "Refused upload of crashlog - too big: $size > " . formatKB(MAX_UPLOAD_SIZE),
			code  => 413,
		};
	}
	else {
		# get the request data (POST for JSON 1.0)
		my $raw = $request->content() || '{}';
		my $json;
		eval { $json = decode_json($raw) };

		if ($@) {
			$result = {
				error => "Failed to parse JSON: $@",
				code  => 400,
			};
		}
		else {
			my $client = Slim::Player::Client::getClient($json->{mac});

			$result = {
				error => sprintf(
					q{name="%s" device="%s" version="%s" mac="%s" uptime="%s" reason="%s"},
					$client && $client->name || "unknown",
					$json->{machine},   # device type: jive, baby, fab4
					$json->{version},
					$json->{mac},
					$json->{uptime} || "unknown",
					$json->{reason} || $json->{failure} || "unknown",
					# $json->{uuid},
					# $json->{logfile},
					# $json->{reqid},
				),
				code => 204,
			};

			main::DEBUGLOG && $log->is_debug && $log->debug("Received crashlog data: " . Data::Dump::dump($json));

			my $logFile = catfile($::logdir || Slim::Utils::OSDetect::dirsFor('log'), 'firmware_crashlog_' . time() . '.json');
			main::INFOLOG && $log->is_info && $log->info("Saving crashlog to $logFile");

			File::Slurp::write_file($logFile, encode_json($json));
		}
	}

	$log->error("Firmware Crashlog: " . $result->{error}) if $result->{error};

	$response->header( 'Content-Length' => 0 );
	$response->code($result->{code} || 204);
	$response->header('Connection' => 'close');
	$response->content_type('text/plain');

	Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \'' );
}

sub purgeCrashlogs {
	my $logDir = $::logdir || Slim::Utils::OSDetect::dirsFor('log');

	my @dumps;
	if ( $logDir && -d $logDir && opendir(DIR, $logDir) ) {
		@dumps = grep { $_ =~ /\/firmware_crashlog_\d+\.json/ && -f $_ && -r _ } map { catfile($logDir, $_) } sort readdir(DIR);
		closedir(DIR);
	}

	# keep the 10 most recent, delete the rest
	if (@dumps > MAX_DUMPS) {
		main::INFOLOG && $log->is_info && $log->info("Purging old crashlogs, keeping " . MAX_DUMPS . " files");
		for my $file (@dumps[0 .. $#dumps - MAX_DUMPS]) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Deleting old crashlog $file");
			unlink $file;
		}
	}
}

sub formatKB {
	my $size = $_[0];

	if ($size < 3200) {
		return "$size Bytes";
	}

	return Slim::Utils::Misc::delimitThousands(int($size / 1024)) . ' KB';
}

1;