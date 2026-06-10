package Plugins::CommunityFirmware::Plugin;

use strict;

use base qw(Slim::Plugin::Base);
use File::Spec::Functions qw(catfile);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Firmware;
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use constant MAX_UPLOAD_SIZE => 1024 * 1024;
use constant MAX_DUMPS => 10;

my $log = logger('player.firmware');
my $cfLog = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.communityfirmware',
	'defaultLevel' => 'ERROR',
	'description'  => 'PLUGIN_COMMUNITY_FIRMWARE_NAME',
});

my $DEFAULT_REPOSITORY;

BEGIN {
	$DEFAULT_REPOSITORY = Slim::Utils::Firmware::BASE();
}

my $prefs = preferences('plugin.communityfirmware');

$prefs->init({
	enable => 1,
	beta   => 0,
});

sub initPlugin {
	if (main::WEBUI) {
		require Plugins::CommunityFirmware::Settings;
		Plugins::CommunityFirmware::Settings->new();
	}

	$prefs->setChange(sub {
		my %seen;

		my $updatesDir = Slim::Utils::OSDetect::dirsFor('updates');

		for my $client ( Slim::Player::Client::clients() ) {
			next if $seen{$client->id}++;
			my $model = $client->model;

			if ( $prefs->get('enable') ) {
				Slim::Utils::Firmware::init_firmware_download($model);
			}
			else {
				Slim::Utils::Misc::deleteFiles($updatesDir, qr/^${model}_\d+\.\d+\.\d+_.*\.bin(\.tmp)?$/i);
				Slim::Utils::Misc::deleteFiles($updatesDir, qr/^$model\.version$/i);

				main::INFOLOG && $log->is_info && $log->info("Removing downloaded firmware from $updatesDir");
			}
		}
	}, 'enable');

	Slim::Web::Pages->addRawFunction("plugins/CommunityFirmware/crashlog", \&handleCrashlog);

	# make sure the falsy value is never undefined, or it would get re-initialised with defaults
	$prefs->setChange(sub {
		my ($pref, $val) = @_;
		$prefs->set($pref, $val || 0);
	}, 'enable', 'beta');

	preferences('server')->set('checkVersion', 1);

	purgeCrashlogs();
}

sub handleCrashlog {
	my ($httpClient, $response) = @_;

	my $request = $response->request;
	my $result = {};

	my $t = Time::HiRes::time();

	main::INFOLOG && $cfLog->is_info && $cfLog->info("Receiving new crashlog. Size: " . formatKB($request->content_length));

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
		eval { $json = from_json($raw) };

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

			main::DEBUGLOG && $cfLog->is_debug && $cfLog->debug("Received crashlog data: " . Data::Dump::dump($json));

			my $logFile = catfile($::logdir || Slim::Utils::OSDetect::dirsFor('log'), 'firmware_crashlog_' . time() . '.json');
			main::INFOLOG && $cfLog->is_info && $cfLog->info("Saving crashlog to $logFile");

			File::Slurp::write_file($logFile, to_json($json));
		}
	}

	$cfLog->error("Firmware Crashlog: " . $result->{error}) if $result->{error};

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
		main::INFOLOG && $cfLog->is_info && $cfLog->info("Purging old crashlogs, keeping " . MAX_DUMPS . " files");
		for my $file (@dumps[0 .. $#dumps - MAX_DUMPS]) {
			main::DEBUGLOG && $cfLog->is_debug && $cfLog->debug("Deleting old crashlog $file");
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


package Slim::Utils::Firmware;

use strict;

use constant COMMUNITY_FIRMWARE_REPOSITORY => 'https://ralph_irving.gitlab.io/lms-community-firmware/update/firmware/';
use constant COMMUNITY_BETA_FIRMWARE_REPOSITORY => 'https://ralph_irving.gitlab.io/lms-community-firmware-beta/update/firmware/';

sub CHECK_INTERVAL {
	return Slim::Utils::Prefs::preferences('server')->get('checkVersionInterval');
}

sub BASE {
	my $hint = shift;

	my $url = ($prefs->get('enable') && (!$hint || $hint =~ /jive|fab4|baby/))
		? ($prefs->get('beta') ? COMMUNITY_BETA_FIRMWARE_REPOSITORY : COMMUNITY_FIRMWARE_REPOSITORY)
		: $DEFAULT_REPOSITORY;

	main::INFOLOG && $log->is_info && $log->info("Firmware check URL: $url");

	return $url;
}

1;
