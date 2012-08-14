#!/usr/bin/perl -w

# Distribution Checker
# AJAX Server Module (ajax_srv.pl)
#
# Copyright (C) 2007-2009 The Linux Foundation. All rights reserved.
#
# This program has been developed by ISP RAS for LF.
# The ptyshell tool is originally written by Jiri Dluhos <jdluhos@suse.cz>
# Copyright (C) 2005-2007 SuSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
#   Changlog:
#			07/16/2010,
#			1\ Add a new function 'push_result_back' for pushing the manual result XML back to the testkit side by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			2\ Update the function 'send_reply' for supporting the 'JSON' and 'Whole XML' format by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			3\ Mark the below methods as '@deprecated' by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			          'list_testcase',
#			          'list_case',
#			          'list_subdir',
#			          'list_profiled_subdir',
#			          'list_profiled_caselist',
#			          'save_case_result',
#			          'save_user'.
#			4\ Add a new action 'load_testcase' for querying the detail information of test case by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			5\ Add a new action 'load_manual_testcase' for querying the detail information of manual test case by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			6\ Add a new action 'load_package' for querying the detail information of test package which is a XML root element in 'tests.xml' by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			7\ Add a new action 'load_suit' for querying the detail information of test suit which is a XML element in 'tests.xml' by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			8\ Add a new action 'load_set' for querying the detail information of test set which is a XML element in 'tests.xml' by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			9\ Update the action 'mantest_submit' for saving the manual test result into the new result XML file 'result.tests.xml' by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#			10\ Update the action 'mantest_finish' for re-generating the new format test-report by Tang, Shao-Feng  <shaofeng.tang@intel.com>.
#
#

use Templates;

#use BuildList;
use UserProfile;
use TestStatus;
use Common;
use Error;
use Fcntl qw/:flock :seek/;
use File::Temp qw/tmpnam tempfile/;
use JSON;
use File::Find;
use Data::Dumper;

use TestKitLogger;

autoflush_on();

my $error_text = '';
my $data       = '';
my $isJson     = 0;
my $isWholeXML = 0;
my $wholeXML;
my $hasManual = "False";    # check if still got some manual result
my %manualResult;           # to record manual result
my %autoResult;             # to record auto result
my @uninstall_package_name    = ();
my @uninstall_package_version = ();
my @package_version_latest;
my @package_version_installed;

my $output_xml =
    "HTTP/1.0 200 OK" 
  . CRLF
  . "Content-type: text/xml"
  . CRLF
  . CRLF
  . "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";

sub push_result_back() {
	my ($this_result_path) = @_;
	if ($this_result_path) {
		use ProcessSummary;
		my $paksRef = &getSelectedPackages($this_result_path);
		foreach (@$paksRef) {
			my $push_cmd =
"cp -rf $this_result_path/$_/result.tests.xml /opt/testkit/lite/latest/usr/share/$_/tests.xml.xmlresult";
			$TestKitLogger::logger->log(
				message => "Push the Result File back, CMD: $push_cmd" );
			system($push_cmd);
		}
		no ProcessSummary;
	}
}

# If error happened, returns it as the only AJAX reply, else sends the informative data.
sub send_reply() {
	if ($error_text) {
		$error_text =~ s/]]>/]]>]]&gt;<![CDATA[/g
		  ;    # Escape ]]> that would close CDATA block otherwise
		print $output_xml
		  . "<root>\n<error><![CDATA[$error_text]]></error>\n</root>";
	}
	elsif ($isJson) {
		my $response =
		    "HTTP/1.0 200 OK" 
		  . CRLF
		  . "Content-type: application/json"
		  . CRLF
		  . CRLF . "$data";
		$TestKitLogger::logger->log(
			message => "[ajax_srv.pl]: the response:\n$response" );
		print $response;
	}
	elsif ($isWholeXML) {
		my $output_xml =
		  "HTTP/1.0 200 OK" . CRLF . "Content-type: text/xml" . CRLF . CRLF;
		if ($wholeXML) {
			$wholeXML =~
s/<\?xml version=(\"|\')1.0(\"|\') encoding=(\"|\')(.*)(\"|\')\?>/<\?xml version=\"1.0\" encoding=\"$4\"\?><\?xml-stylesheet type=\"text\/xsl\" href=\"\/resultstyle2.xsl\" \?>/;
			print $output_xml. $wholeXML;
		}
		else {
			print $output_xml
			  . "<?xml version=\"1.0\" encoding=\"utf-8\"?><?xml-stylesheet type=\"text\/xsl\" href=\"/resultstyle2.xsl\" ?>\n"
			  . "<testresults></testresults>";
		}
	}
	else {
		my $response = $output_xml . "<root>\n$data</root>";
		$TestKitLogger::logger->log(
			message => "[ajax_srv.pl]: the response:\n$response" );
		print $response;
	}
}

# Reads the list of user profiles and adds it in XML form into $data variable.
sub list_dir() {
	if ( opendir( DIR, $SERVER_PARAM{'APP_DATA'} . '/profiles/test' ) ) {
		$data .= "<profiles>\n";
		foreach ( sort( grep( !/^[~\.]/, readdir(DIR) ) ) ) {
			$data .= "<name>$_</name>\n";
		}
		$data .= "</profiles>\n";
		closedir(DIR);
	}
	else {
		$error_text = "Could not obtain directory list!<br />($!)";
	}
}

# @deprecated
sub list_testcase($) {
	my ($curr_dir) = @_;

	my $testcase_list = '';
	my $test_case     = '';
	if ( $curr_dir eq '' ) {
		$data .= "<testcase>testcase is empty</testcase>\n";
	}
	else {
		if ( $curr_dir =~ /(.*)\/(.*)/ ) {
			$testcase_list = $1 . '/testinfo.xml';
			$test_case     = $2;

			#		$data .= "<caselist>$testcase_list </caselist>\n";
			#		$data .= "<testcase>$test_case</testcase>\n";
		}
		my $full_path = $SERVER_PARAM{'APP_DATA'} . '/tests/' . $testcase_list;

		#	$data .= "<fullpath>$full_path</fullpath>\n";
		if ( -e $full_path ) {
			if ( !open( MYFILE, $full_path ) ) {
				$error_text =
				  "Could not obtain test case list file!<br />($!) \n";
			}
			else {
				while (<MYFILE>) {
					$_ =~ s/\n//g;
					chomp($_);
					if ( $_ =~ /\<testcase name=\"$test_case\"\>/ ) {
						$data .= "$_\n";
						while ( my $line = <MYFILE> ) {
							chomp($line);
							$data .= "$line\n";
							if ( $line =~ /\<\/testcase\>/ ) {

								#$data .= "<case></case>\n";
								last;
							}
						}

						#last;
					}
				}
			}
			close(MYFILE);
		}
	}
}

# @deprecated
sub list_case($) {
	my ($full_path) = @_;
	my $testcase_list = $full_path;
	$testcase_list .= "/testinfo.xml";
	my $case_name = '';
	if ( !open( MYFILE, $testcase_list ) ) {
		$error_text = "Could not obtain test case list file!<br />($!) \n";
	}
	else {
		while ( my $line = <MYFILE> ) {
			if ( $line =~ /\<testcase name=\"(.*)\"\>/ ) {
				$case_name = $1;
				$data .= "<test>\n";
				$data .= "<name>$case_name</name>\n";
				$data .= "<type>case</type>";
				$data .= "</test>\n";
			}
		}
	}

	closedir(SPEC_DIR);
}

# @deprecated
sub list_subdir($) {
	my ($curr_dir) = @_;
	if ( $curr_dir eq '' ) {
		$data .= "<subdir>subdir is empty</subdir>\n";
	}
	else {
		my $full_path = $SERVER_PARAM{'APP_DATA'} . '/tests/' . $curr_dir;
		if ( opendir( DIR, $full_path ) ) {
			$data .= "<tests>\n";
			foreach ( sort( grep( !/^[\.]/, readdir(DIR) ) ) ) {
				$node_name = $_;
				if ( $node_name =~ /testinfo\.xml/ ) {
					$case_node = 1;
				}
			}
			if ( $case_node == 1 ) {
				list_case($full_path);
			}
			else {
				foreach ( sort( grep( !/^[\.]/, readdir(DIR) ) ) ) {
					$node_name = $_;
					if ( $node_name =~ /Makefile/ ) {
						next;
					}
					$data .= "<test>\n";
					$data .= "<name>$node_name</name>\n";
					$data .= "<type>suit</type>";
					$data .= "</test>\n";
				}
			}
			$data .= "</tests>\n";
			closedir(DIR);
		}
		else {
			$error_text =
			  "Could not obtain directory list! $full_path<br />($!)";
		}
	}

}

# @deprecated
sub list_profiled_subdir($$) {
	my ( $curr_dir, $profile ) = @_;
	if ( ( $curr_dir eq '' ) || ( $profile eq '' ) ) {
		$data .= "<subdir>subdir or profile is empty</subdir>\n";
	}
	else {
		my $full_path = $SERVER_PARAM{'APP_DATA'} . '/tests/' . $curr_dir;
		if ( opendir( DIR, $full_path ) ) {
			$data .= "<tests>\n";
			foreach ( sort( grep( !/^[\.]/, readdir(DIR) ) ) ) {
				my $node_name = $_;
				if ( $node_name =~ /Makefile/ ) {
					next;
				}
				if ( $node_name =~ /testspec|testsource|testbin/ ) {
					list_case($full_path);
					last;
				}
				else {
					my $grepcmd   = "grep $curr_dir/$node_name $profile -c";
					my $inprofile = `$grepcmd`;
					if ( $inprofile > 0 ) {
						$data .= "<test>\n";
						$data .= "<name>$node_name</name>\n";
						$data .= "<type>suit</type>\n";
						$data .= "</test>\n";
					}
				}
			}
			$data .= "</tests>\n";
			closedir(DIR);
		}
		else {
			$error_text = "Could not obtain directory list!<br />($!)";
		}
	}

}

# @deprecated
sub list_profiled_caselist($$) {
	my ( $curr_dir, $profile ) = @_;
	if ( ( $curr_dir eq '' ) || ( $profile eq '' ) ) {
		$data .= "<testcases>subdir or profile is empty</testcases>\n";
	}
	else {
		if ( open( PROFILE, $profile ) ) {
			my $grepcmd   = "grep $curr_dir $profile -c";
			my $inprofile = `$grepcmd`;
			if ( $inprofile > 0 ) {

				$data .= "<testcases> \n";
				while (<PROFILE>) {
					my $line       = $_;
					my $suitname   = '';
					my $casename   = '';
					my $teststatus = '';
					if ( $line =~ /^$curr_dir/ ) {
						if ( $line =~ /(.*)\s+(.*)\s+(PASS|FAIL|BLOCK|NotRun)/ )
						{
							( $suitname, $casename, $teststatus ) =
							  split( /\s+/, $line );
						}
						$data .= "<testcase> \n";
						$data .= "<suitname>$suitname</suitname>\n";
						$data .= "<casename>$casename</casename>\n";
						$data .= "<teststatus>$teststatus</teststatus>\n";
						$data .= "</testcase> \n";
					}
				}
				$data .= "</testcases> \n";
				close(PROFILE);
			}
			else {
				$data .=
"<testcases>no profiled cases in this testsuit $profile</testcases>\n";
			}
		}
		else {
			$error_text =
			  "Could not obtain profiled cases list! $profile<br />($!)";
		}
	}
}

# @deprecated
sub read_manual_result($) {
	my ($manResult_file) = @_;
	my @manResult_arr    = ();
	my $result_file_new  = "/tmp/manual.res";
	unless ( open( FILE, $manResult_file ) ) {
		print "Could not open problem database $manResult_file\n";
		return;
	}

	while (<FILE>) {
		my $line           = $_;
		my $manResult_item = {};
		print NEW_FILE $line;

		if ( $line =~ /(.*)\s+(.*)\s+(PASS|FAIL|BLOCK|NotRun)/ ) {
			my ( $suitname, $casename, $teststatus ) = split( /\s+/, $line );
			$manResult_item->{'suitname'}   = $suitname;
			$manResult_item->{'casename'}   = $casename;
			$manResult_item->{'teststatus'} = $teststatus;
		}
		elsif ( $line =~ /(.*)\s+(.*)/ ) {
			my ( $suitname, $casename ) = split( /\s+/, $line );
			$manResult_item->{'suitname'}   = $suitname;
			$manResult_item->{'casename'}   = $casename;
			$manResult_item->{'teststatus'} = "NotRun";

		}

		push @manResult_arr, $manResult_item;
	}
	return @manResult_arr;
}

# @deprecated
sub save_case_result($$) {
	my ( $result_file, $result_js ) = @_;
	my $json        = new JSON;
	my @full_result = read_manual_result($result_file);
	my $result_file_new =
"/root/testkit/testkit-git/moblin-testkit-bak/manager/webui/public_html/manual.res";

	my $new_result = $json->decode($result_js);
	my $scalar     = @full_result;
	for ( my $i = 0 ; $i < $scalar ; $i++ ) {
		foreach my $result_item (@$new_result) {
			if (
				(
					$full_result[$i]->{'suitname'} eq $result_item->{'suitname'}
				)
				&& ( $full_result[$i]->{'casename'} eq
					$result_item->{'casename'} )
			  )
			{
				$full_result[$i]->{'teststatus'} = $result_item->{'teststatus'};
			}
		}
	}

	if ( open( NEW_FILE, ">$result_file" ) ) {
		foreach my $item (@full_result) {
			print NEW_FILE $item->{'suitname'} . "  ";
			print NEW_FILE $item->{'casename'} . "  ";
			print NEW_FILE $item->{'teststatus'} . "\n";
		}
	}
	close(NEW_FILE);
	$data .= "<man_result>Manual Test Result Save Succeed</man_result>";
}

sub save_profile($$) {
	my ( $profile, $profile_js ) = @_;
	my $json         = new JSON;
	my @auto_tests   = ();
	my @manual_tests = ();

	my $new_result = $json->decode($profile_js);
	foreach my $result_item (@$new_result) {
		push @auto_tests, $result_item;
	}

	if ( open( NEW_FILE, ">$profile" ) ) {
		print NEW_FILE "[Auto]\n";
		foreach my $item (@auto_tests) {
			print NEW_FILE $item . "\n";
		}
		print NEW_FILE "[Manual]\n";
		foreach my $item (@manual_tests) {
			print NEW_FILE $item . "\n";
		}
	}
	close(NEW_FILE);
	$data .= "<profile_result>Profile Save Succeed</profile_result>";
}

sub load_profile($) {
	my ($profile) = @_;
	my @profiled_tests = ();

	unless ( open( FILE, $profile ) ) {
		print "Could not open profile $profile\n";
		return;
	}

	$data .= "<test_packages>";
	while (<FILE>) {
		my $line = $_;
		$TestKitLogger::logger->log(
			message => "[ajax_srv.pl]: Profile line:$line" );
		if ( $line !~ s/(\[Auto\]|\[Manual\])// ) {
			$line =~ s/\n//g;
			$TestKitLogger::logger->log(
				message => "[ajax_srv.pl]: Processed test_package:$line" );
			$data .= "<test_package>$line</test_package>";
		}
	}
	$data .= "</test_packages>";
	$data .= "<profile_result>Profile Load Succeed</profile_result>";
}

# @deprecated
sub save_user($$) {
	my ( $profile, $profile_js ) = @_;
	my $json = new JSON;

	my $new_result = $json->decode($profile_js);
	if ( open( NEW_FILE, ">$profile" ) ) {
		foreach my $user (@$new_result) {
			print NEW_FILE "Name: ";
			print NEW_FILE $user->{'user_name'} . "\n";
			print NEW_FILE "Email: ";
			print NEW_FILE $user->{'email'} . "\n";
			print NEW_FILE "SKU: ";
			print NEW_FILE $user->{'sku'} . "\n";
			print NEW_FILE "Organization: ";
			print NEW_FILE $user->{'organize'} . "\n";
		}
	}
}

# Prepares the output log portion for transferring to client.
# In:  String variable which contents will be replaced by the processed data.
# Out: Size of the source data corresponding to the processed data to be sent.
# List of conversions:
#  a) If text is multi-lined, the last line is cut. Reason: this allows to
#     do more of the conversion on the server side (more efficient).
#  b) Windows-style line endings -> Unix-style.
#  c) 'some text^Mother text' -> 'other text' (CR character starts typing from
#     the beginning of the current line).
#  d) 'x^H' -> '' (backspace character removes the preceding character).
#  e) '^H^H^H...' -> '' (backspaces at the beginning of line are just removed).
#  f) '^A^B^C' -> '...' (other control characters replaced with dots).
#  g) XML CDATA ending block ']]>' is escaped.
sub process_output($) {
	return 0 if ( $_[0] eq '' );
	my $newln_pos = rindex( $_[0], "\n" );
	my $res_size = length( $_[0] );
	if ( $newln_pos != -1 ) {

		# Convert Windows-style line endings to Unix-style
		$_[0] =~ s/\r\n/\n/g;
		my @lines = split( m/^/m, $_[0] );
		for ( my $i = 1 ; $i < scalar(@lines) ; ++$i ) {

   # Make every ^M control character (\x0d) erase all from the beginning of line
			while ( ( $lines[$i] =~ s/^[^\x0d]*\x0d//sg ) > 0 ) { }

# Make every ^H control character (\x08) erase the previous character (if present)
			while ( ( $lines[$i] =~ s/[^\x08]\x08//sg ) > 0 ) { }

# Remove remaining ^H characters in the beginning of line (if there were some excessive)
			$lines[$i] =~ s/^\x08+//s;
		}
		$_[0] = join( '', @lines );
	}
	$_[0] =~ s/[\x00-\x08\x0b-\x0c\x0e-\x1f]/./g
	  ; # Remaining control characters replaced with dots (XML parser cannot stand them)
	$_[0] =~ s/]]>/]]>]]&gt;<![CDATA[/g
	  ;    # Escape ]]> which would close CDATA block otherwise
	$_[0] =~ s/\x0d/]]>&#13;<![CDATA[/g
	  ;    # Escape remaining ^M characters - else they come to browser as ^J
	return $res_size;
}

# Converts the current status information into XML list of values.
sub construct_progress_data($) {
	my ($status) = @_;
	if ( !$status ) {
		return '';
	}
	if ( !$status->{'TEST_SUITES'}
		|| scalar( @{ $status->{'TEST_SUITES'} } ) == 0 )
	{
		return '<progress></progress>';
	}

	my $res          = '<progress>';
	my $current_time = time();
	foreach my $ts_info ( @{ $status->{'TEST_SUITES'} } ) {
		my $id      = ( $ts_info->{'ID'}   or "unnamed" );
		my $ts_name = ( $ts_info->{'NAME'} or $id );
		my $elapsed_time    = 0;
		my $total_time      = 0;
		my $prepare_percent = 0;
		my $current_percent = 0;
		my $ts_status       = $ts_info->{'STATUS'};

		if ( $ts_info->{'STATUS'} eq 'Not started' ) {
			if ( $ts_info->{'ESTIMATE_DURATION'} ) {
				$total_time = $ts_info->{'ESTIMATE_DURATION'};
			}
		}
		elsif ( $ts_info->{'STATUS'} eq 'Preparing' ) {
			if ( $ts_info->{'PREPARE_PERCENT'} ) {
				$prepare_percent = $ts_info->{'PREPARE_PERCENT'};
			}
			$elapsed_time = $current_time - $ts_info->{'START_TIME'};
			if ( $ts_info->{'ESTIMATE_DURATION'} ) {
				$total_time = $ts_info->{'ESTIMATE_DURATION'};
			}
		}
		elsif (( $ts_info->{'STATUS'} eq 'Running' )
			|| ( $ts_info->{'STATUS'} eq 'Making report' ) )
		{
			if ( $ts_info->{'PREPARE_PERCENT'} ) {
				$prepare_percent = $ts_info->{'PREPARE_PERCENT'};
			}
			if ( $ts_info->{'CURRENT_PERCENT'} ) {
				$current_percent = $ts_info->{'CURRENT_PERCENT'};
			}
			$elapsed_time = $current_time - $ts_info->{'START_TIME'};
			if ( $ts_info->{'ESTIMATE_DURATION'} ) {
				$total_time = $ts_info->{'ESTIMATE_DURATION'};
			}
		}
		elsif (( $ts_info->{'STATUS'} eq 'Failed' )
			|| ( $ts_info->{'STATUS'} eq 'Warnings' )
			|| ( $ts_info->{'STATUS'} eq 'Passed' )
			|| ( $ts_info->{'STATUS'} eq 'No verdict' )
			|| ( $ts_info->{'STATUS'} eq 'Incomplete' ) )
		{
			if ( $ts_info->{'PREPARE_PERCENT'} ) {
				$prepare_percent = $ts_info->{'PREPARE_PERCENT'};
			}
			$elapsed_time = $ts_info->{'STOP_TIME'} - $ts_info->{'START_TIME'};
			$total_time   = $elapsed_time;
		}
		elsif ( $ts_info->{'STATUS'} eq 'Crashed' ) {
			if ( $ts_info->{'PREPARE_PERCENT'} ) {
				$prepare_percent = $ts_info->{'PREPARE_PERCENT'};
			}
			if ( $ts_info->{'CURRENT_PERCENT'} ) {
				$current_percent = $ts_info->{'CURRENT_PERCENT'};
			}
			$elapsed_time = $ts_info->{'STOP_TIME'} - $ts_info->{'START_TIME'};
			$total_time   = $elapsed_time;
		}

		$res .=
"<testsuite id=\"$id\"><name>$ts_name</name><status>$ts_status</status><elapsed>$elapsed_time</elapsed><total>$total_time</total><prep_percent>$prepare_percent</prep_percent><percent>$current_percent</percent></testsuite>";
	}
	$res .= '</progress>';
	return $res;
}

sub getUpdateInfoFromNetwork {
	my @package_name = @_;
	my @rpm          = ();
	my $repo         = get_repo();
	my @repo_all     = split( "::", $repo );
	my $repo_type    = $repo_all[0];
	my $repo_url     = $repo_all[1];
	my $GREP_PATH    = $repo_url;
	$GREP_PATH =~ s/\:/\\:/g;
	$GREP_PATH =~ s/\//\\\//g;
	$GREP_PATH =~ s/\./\\\./g;
	$GREP_PATH =~ s/\-/\\\-/g;

	if ( $repo_type =~ /remote/ ) {
		@rpm = `$DOWNLOAD_CMD $repo_url 2>&1 | grep $GREP_PATH.*tests.*rpm`;
	}
	if ( $repo_type =~ /local/ ) {
		@rpm = `find $repo_url | grep $GREP_PATH.*tests.*rpm`;
	}
	my @install_flag;
	my $temp_package_count = 0;
	push( @update_package_flag, "0" );
	for ( my $i = 0 ; $i < @rpm ; $i++ ) {
		$install_flag[$i] = "b";
	}
	if ( @package_name > 0 ) {
		foreach (@package_name) {
			my $temp_rpm_count   = 0;
			my $package_name_tmp = $_;
			my $cmd = "sdb shell 'rpm -qa | grep " . $package_name_tmp . "'";
			my $package_version_installed = `$cmd`;
			my $version                   = "none";
			if ( $package_version_installed =~ /-(\d\.\d\.\d-\d)/ ) {
				$version = $1;
			}
			push( @package_version_installed, $version );
			push( @package_version_latest,    $version );

			foreach (@rpm) {
				my $remote_pacakge_name = $_;
				$remote_pacakge_name =~ s/(.*)$GREP_PATH//g;
				if ( $remote_pacakge_name =~ /$package_name_tmp/ ) {
					$install_flag[$temp_rpm_count] = "a";
					my $version = "none";
					if ( $remote_pacakge_name =~ /-(\d\.\d\.\d-\d)/ ) {
						$version = $1;
					}
					$package_version_latest[$temp_package_count] = $version;
				}
				$temp_rpm_count++;
			}
			$temp_package_count++;
		}
		for ( my $i = 0 ; $i < @rpm ; $i++ ) {
			if ( $install_flag[$i] eq "b" ) {
				my $remote_pacakge_name = $rpm[$i];
				my $package_name        = "none";
				my $version             = "none";
				$remote_pacakge_name =~ s/(.*)$GREP_PATH//g;
				if ( $remote_pacakge_name =~ /\s*(.*)-(\d\.\d\.\d-\d)/ ) {
					$package_name = $1;
					$version      = $2;
				}
				push( @uninstall_package_name,    $package_name );
				push( @uninstall_package_version, $version );
			}
		}
		for ( my $count = 0 ; $count < @package_name ; $count++ ) {
			my $result = compare_version(
				$package_version_installed[$count],
				$package_version_latest[$count]
			);
			if ( $result eq "update" ) {
				$update_package_flag[$count] = "a";
			}
			else {
				$update_package_flag[$count] = "b";
			}
		}
	}
	else {
		for ( my $i = 0 ; $i < @rpm ; $i++ ) {
			if ( $rpm[$i] =~ /tests/ ) {
				my $rpm_temp = $rpm[$i];
				$_ = $rpm_temp;
				s/(.*)$GREP_PATH(.*)\-(.*)\-(.*)/$2/g;
				push( @uninstall_package_name, $_ );
				my $remote_pacakge_name = $rpm[$i];
				my $version             = "none";
				if ( $remote_pacakge_name =~ /-(\d\.\d\.\d-\d)/ ) {
					$version = $1;
				}
				push( @uninstall_package_version, $version );
			}
		}
	}
}

# Rereads the Manifest and constructs the XML reply to be sent to the client
#sub get_manifest_data_reply() {
#	my $res = '';
#	BuildList::init();
#	$res .= "<modlist>\n";
#	my $res_html = generate_modlist();
#	my $res_js = generate_js_init_data();
#	# Cut HTML and JS data into blocks by not more than 4000 symbols.
#	# Reason: in Mandriva 2008 XML parser in Firefox does not allow XML nodes longer than 4096 symbols.
#	my @res_html_arr = split(/\n/, $res_html);
#	my $block = '';
#	my $len = 0;
#	for (my $i=0; $i<scalar(@res_html_arr); $i++) {
#		if (length($res_html_arr[$i]) > 4000) {
#			$error_text = "Internal error: too long HTML line!<br />Please, write at <a href=\"mailto:linux\@ispras.ru\"><u>linux\@ispras.ru</u></a>.";
#			last;
#		}
#		$block .= $res_html_arr[$i]."\n";
#		$len += length($res_html_arr[$i]);
#		if (($i == $#res_html_arr) or (($len + length($res_html_arr[$i + 1])) > 4000)) {
#			$res .= "<html><![CDATA[$block]]></html>\n";
#			$block = '';
#			$len = 0;
#		}
#	}
#	my @res_js_arr = split(/\n/, $res_js);
#	$block = '';
#	$len = 0;
#	for (my $i=0; $i<scalar(@res_js_arr); $i++) {
#		if (length($res_js_arr[$i]) > 4000) {
#			$error_text = "Internal error: too long JS line!<br />Please, write at <a href=\"mailto:linux\@ispras.ru\"><u>linux\@ispras.ru</u></a>.";
#			last;
#		}
#		$block .= $res_js_arr[$i]."\n";
#	$len += length($res_js_arr[$i]);
#		if (($i == $#res_js_arr) or (($len + length($res_js_arr[$i + 1])) > 4000)) {
#			$res .= "<js><![CDATA[$block]]></js>\n";
#			$block = '';
#			$len = 0;
#		}
#	}
#	$res .= "</modlist>\n";
#	return $res;
#}

# Command-line proxy option for dist-checker.pl
my $proxy_option = '';
if ( $SERVER_PARAM{'PROXY'} ) {
	$proxy_option .=
	  ' --proxy=' . $SERVER_PARAM{'PROXY'} . ',' . $SERVER_PARAM{'PROXY_AUTH'};
}
else {
	if ( $SERVER_PARAM{'HTTP_PROXY'} ) {
		$proxy_option .=
		    ' --http-proxy='
		  . $SERVER_PARAM{'HTTP_PROXY'} . ','
		  . $SERVER_PARAM{'HTTP_PROXY_AUTH'};
	}
	if ( $SERVER_PARAM{'FTP_PROXY'} ) {
		$proxy_option .=
		    ' --ftp-proxy='
		  . $SERVER_PARAM{'FTP_PROXY'} . ','
		  . $SERVER_PARAM{'FTP_PROXY_AUTH'};
	}
}

# Start main block of AJAX actions
if ( !$_GET{'action'} ) {
	$error_text = 'Incorrect call parameters!';
}
elsif ( $_GET{'action'} eq 'check_run' ) {  # Check whether test run is possible
	my $full_save_name;
	if ( !-d $SERVER_PARAM{'APP_DATA'} . '/profiles/test' ) {
		system( 'mkdir -p ' . $SERVER_PARAM{'APP_DATA'} . '/profiles/test' );
		if ( !-d $SERVER_PARAM{'APP_DATA'} . '/profiles/test' ) {
			$error_text =
			    'Could not create profile directory:<br />'
			  . $SERVER_PARAM{'APP_DATA'}
			  . '/profiles/test';
		}
	}
	if ( !$error_text ) {
		if ( $_COOKIE{'session_id'} ) {
			$full_save_name =
			    $SERVER_PARAM{'APP_DATA'}
			  . '/profiles/test/~session.'
			  . $SERVER_PARAM{'PEER_IP'} . '.'
			  . $_COOKIE{'session_id'};
		}
		else {
			$error_text =
'Cannot retrieve session ID! Please, allow cookies in your browser.';
		}
	}
	if ( !$error_text ) {
		if ( write_profile( $full_save_name, \%_POST ) ) {
			list_dir();
		}
		else {
			$error_text = $profile_error;
		}
	}
	if ( !$error_text ) {
		$tests_status = read_status();
		if ( defined($tests_status) && $tests_status->{'IS_RUNNING'} ) {
			$error_text =
'Tests are already running!<br />You cannot run another instance before they are finished.<br />You can watch or stop the running tests on the <a href="tests_exec.pl"><u>Execution</u></a> page.';
		}
	}
	if ( !$error_text ) {
		if (
			open( CHK_FILE,
				$CONFIG{'TESTS_DIR'}
				  . "/dist-checker.pl --webui --check-only -f \"$full_save_name\" 3>&1 1>/dev/null 2>&3 |"
			)
		  )
		{    # capture STDERR only
			my $chk_text = '';
			while (<CHK_FILE>) {
				$chk_text .= $_;
			}
			close(CHK_FILE);
			if ( $chk_text =~ m/^Error:/mi ) {
				$chk_text =~ s/^Error:\s*/\n/s;
				$chk_text =~ s/\nFinished\.\n//s;

				$error_text = $chk_text;
				$error_text =~ s/&/&amp;/g;
				$error_text =~ s/</&lt;/g;
				$error_text =~ s/>/&gt;/g;
				$error_text =~ s/\r?\n/<br \/>/sg;
				$error_text .= '<br />';
				$error_text .=
'<br />Please, see the <a href="tests_help.pl#troubleshooting"><u>Troubleshooting</u></a> Help section to find the solution.';
				$error_text .=
'<br />If you could not find any, please, write at <a href="mailto:linux@ispras.ru"><u>linux@ispras.ru</u></a>.';
			}
		}
		else {
			$error_text =
			  "Cannot run dist-checker.pl to check the requirements!<br />$!";
		}
	}

	if ( !$error_text ) {
		$data .= '<testrun_allowed>1</testrun_allowed>';
	}
}

# Start the tests
elsif ( $_GET{'action'} eq 'run_tests' ) {
	if ( !$_GET{'profile'} ) {
		$error_text = 'Incorrect call parameters!';
	}
	else {
		my $status = read_status();

		if ( $status->{'IS_RUNNING'} ) {
			$error_text =
"Tests are already running.<br />You cannot run another instance before they are finished.<br />Start watching the current run?<br /><br /><input type=\"button\" value=\"Yes\" style=\"width: 5em;\" onclick=\"javascript:cert='"
			  . ( $status->{'CERTIFICATION'} ? 'certification' : 'custom' )
			  . "';startTestsPrepareGUI();startRefresh();\" />&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<input type=\"button\" value=\"No\" style=\"width: 5em;\" onclick=\"javascript:err_area.style.display='none';\" />";
		}
		else {
			my $profile_path =
			  $SERVER_PARAM{'APP_DATA'} . '/profiles/test/' . $_GET{'profile'};
			my $tef_stderr = $SERVER_PARAM{'APP_DATA'} . "/log/err";
			my $child      = fork();
			if ( !defined($child) ) {
				$error_text = 'Cannot create child process!';
			}
			elsif ( $child == 0 ) {

				# Child process start
				close(STDOUT);

				#Start 'testkit_lite_start' and exit the child process.
				exec( $CONFIG{'TESTS_DIR'}
					  . "/testkit_lite_start.pl -f '$profile_path' -w 2>$tef_stderr"
				);
			}
			else {

		# Parent process
		# Wait till .pl reports us whether it started or failed to start.
		# If it started, we can't wait till its end (several hours), so we check
		# for the specific control word posted by it into STDERR.
				while (1) {

					#Short (0.3 second) Sleeps
					select( undef, undef, undef, 0.3 );

					$status = read_status();
					my $is_running = is_process_running($child);
					my $tef_reply  = read_file($tef_stderr);
					$TestKitLogger::logger->log( message =>
"[ajax_srv.pl]: The profile = $profile_path tef_stderr=$tef_stderr is_running= $is_running, reply = $tef_reply\n"
					);

					if ( !is_ok($tef_reply) ) {
						next;
					}
					elsif ( $tef_reply =~ m/^Started\./mi ) {

						# .pl reports that it started successfully
						if ( !$status->{'IS_RUNNING'} ) {

							# ...but the STATUS file tells otherwise
							if ($is_running) {
								$error_text =
"Internal error: .pl started but claims it is not running. status="
								  . $status->{'IS_RUNNING'};
							}

							# .pl started and finished immediately.
							else {
								$data .= construct_progress_data($status);
								$TestKitLogger::logger->log( message =>
"[ajax_srv.pl]: started and finished data = $data\n"
								);
								$tid = $status->{'RESULT_DIR'};
								$log_file =
								  $CONFIG{'RESULTS_DIR'} . '/' . $tid . '/log';

								# Read the test log output.
								if ( open( FILE, $log_file ) ) {
									my $file_data = '';
									read( FILE, $file_data, -s $log_file );
									close(FILE);

				  # Escape it, clean from 'backspace' and CR control chars, etc.
									process_output($file_data);

							   # Slice $file_data by 4000-bytes XML CDATA blocks
									my $len   = length($file_data);
									my $b_pos = 0;
									while ( $b_pos < $len ) {
										my $b_len = $len - $b_pos;
										if ( $b_len > 4000 ) {
											$b_len = 4000;
										}
										my $block =
										  substr( $file_data, $b_pos, $b_len );
										$b_pos += $b_len;
										$data .=
"<output><![CDATA[$block]]></output>\n";
									}
								}

			   # Test run has completely finished; redirect to the results page.
								if ( $status->{'STATUS'} eq 'Finished' ) {
									chomp( my $time =
`ls -t ../../../lite | cut -f 1 | sed -n '1,1p'`
									);
									chomp( my $time_all =
										  `ls -l ../../../lite | grep latest` );
									if ( $time_all =~
										/-> \/opt\/testkit\/lite\/(.*)/ )
									{
										$time = $1;
									}
									updateManualState($time);
									if ( $hasManual eq "False" ) {
										$data .= "<redirect>$time</redirect>\n";
									}
									else {
										$data .= "<redirect>$time</redirect>\n";
										$data .=
"<redirect_manual>1</redirect_manual>\n";
									}
								}

				  # Test run was forcibly stopped; show status, do not redirect.
								elsif ( $status->{'STATUS'} eq 'Terminated' ) {
									$data .=
"<tr_status>&lt;span style=\"color: red;\"&gt;The test has been stopped.&lt;/span&gt;</tr_status>\n";
								}

						# Test run has crashed; show status and do not redirect.
								else {
									$data .=
"<tr_status>&lt;span style=\"color: red;\"&gt;The test seems to have crashed.&lt;/span&gt;</tr_status>\n";
								}
							}
						}

				# Everything is fine, send AJAX reply and start watching the log
						else {
							$data .= "<started>1</started>\n";
							$data .= construct_progress_data($status);
							$TestKitLogger::logger->log( message =>
								  "[ajax_srv.pl]: Started data = $data\n" );
						}
						last;
					}

   # .pl reports an error. Check that it finishes (and therefore is not
   # in process of dumping info into STDERR) and if yes, read the error message.
   # If it's not finished, wait a little bit more.
					elsif ( $tef_reply =~ m/^Error:/mi ) {
						if ( !$is_running ) {
							$tef_reply =~ s/\nFinished\.\n//s;
							$error_text = $tef_reply;
							$error_text =~ s/&/&amp;/g;
							$error_text =~ s/</&lt;/g;
							$error_text =~ s/>/&gt;/g;
							$error_text =~ s/\r?\n/<br \/>/g;
							last;
						}
					}

					# .pl terminated unexpectedly.
					elsif ( $tef_reply =~ m/^Finished\./mi ) {
						$error_text =
						  'Internal error: .pl terminated unexpectedly.';
						last;
					}

				# .pl finished without printing any of the expected output line.
					elsif ( !$is_running ) {
						$tef_reply =~ s/&/&amp;/g;
						$tef_reply =~ s/</&lt;/g;
						$tef_reply =~ s/>/&gt;/g;
						$tef_reply =~ s/\r?\n/<br \/>/g;
						$error_text =
'Internal error: .pl returned unexpected output:<br />'
						  . $tef_reply;
						last;
					}
				}

# Either success, or fail, but now we can remove the STDERR file to keep /tmp clean.
				unlink($tef_stderr);
			}
		}
	}
}

# Get next portion of test log output
elsif ( $_GET{'action'} eq 'get_test_log' ) {
	my $start = ( $_GET{'start'} or 0 );
	my $tid   = ( $_GET{'tid'}   or '' );
	if ( ( $start != 0 ) and !$tid ) {
		$error_text = 'Incorrect call parameters!';
	}
	else {

# Block the status file to make sure nothing significant will happen in the meantime
		if ( lock_status() ) {
			my $status = read_status();
			my $log_file;

# Find the log file location: either it was explicitly named via GET argument 'tid',
# or we just take the current test run.
			if ( !$tid ) {
				$tid = $status->{'RESULT_DIR'};
			}
			$log_file = $CONFIG{'RESULTS_DIR'} . '/' . $tid . '/log';
			if ( -f $log_file ) {
				$data .=
				    "<tid>$tid</tid>\n<cert>"
				  . ( $status->{'CERTIFICATION'} ? '1' : '0' )
				  . "</cert>\n";
				$data .= construct_progress_data($status);
				if ( open( FILE, $log_file ) ) {

				   # Read the log file from the start point specified to the end
					seek( FILE, $start, SEEK_SET );
					my $file_data = '';
					my $sz =
					  read( FILE, $file_data, ( -s $log_file ) - $start );
					close(FILE);

				  # Escape it, clean from 'backspace' and CR control chars, etc.
					$start += process_output($file_data);

					# Slice $file_data by 4000-bytes XML CDATA blocks
					my $len   = length($file_data);
					my $b_pos = 0;
					while ( $b_pos < $len ) {
						my $b_len = $len - $b_pos;
						if ( $b_len > 4000 ) {
							$b_len = 4000;
						}
						my $block = substr( $file_data, $b_pos, $b_len );
						$b_pos += $b_len;
						$data .= "<output><![CDATA[$block]]></output>\n";
					}

   # If tests are still running, just send the current position in the log file.
					if ( $status->{'IS_RUNNING'} ) {
						$data .= "<size>$start</size>\n";
					}

					# The test run is finished.
					else {
						if ( $status->{'STATUS'} eq 'Finished' ) {

			   # Test run has completely finished; redirect to the results page.
							chomp( my $time =
`ls -t ../../../lite | cut -f 1 | sed -n '1,1p'`
							);
							chomp( my $time_all =
								  `ls -l ../../../lite | grep latest` );
							if ( $time_all =~ /-> \/opt\/testkit\/lite\/(.*)/ )
							{
								$time = $1;
							}
							updateManualState($time);
							if ( $hasManual eq "False" ) {
								$data .= "<redirect>$time</redirect>\n";
							}
							else {
								$data .= "<redirect>$time</redirect>\n";
								$data .=
								  "<redirect_manual>1</redirect_manual>\n";
							}
						}

				  # Test run was forcibly stopped; show status, do not redirect.
						elsif ( $status->{'STATUS'} eq 'Terminated' ) {
							$data .=
"<tr_status>&lt;span style=\"color: red;\"&gt;The test has been stopped.&lt;/span&gt;</tr_status>\n";
						}

						# Test run has crashed; show status and do not redirect.
						else {
							$data .=
"<tr_status>&lt;span style=\"color: red;\"&gt;The test seems to have crashed.&lt;/span&gt;</tr_status>\n";
						}
					}
				}
				else {
					$error_text =
"Could not open output log &lsquo;$log_file&rsquo;!<br />$!";
				}
			}
			else {
				$error_text = 'No output log found!';
			}
			unlock_status();
		}
		else {
			$error_text = "Error locking the status file!<br />$status_error";
		}
	}
}

elsif ( $_GET{'action'} eq 'update_page_with_uninstall_pkg' ) {
	my @installed_package_list = split /\:/, $_GET{'installed_packages'};
	my $flag_uninstall         = 0;
	my $flag_update            = 0;
	my $check_network          = check_network();
	if ( $check_network =~ /OK/ ) {
		getUpdateInfoFromNetwork(@installed_package_list);
		foreach (@uninstall_package_name) {
			if ( $_ =~ /[a-zA-Z]/ ) {
				$flag_uninstall = 1;
			}
		}
		foreach (@update_package_flag) {
			if ( $_ =~ /a/ ) {
				$flag_update = 1;
			}
		}
		if ( $flag_uninstall || $flag_update ) {
			$data .=
"<uninstall_package_name>@uninstall_package_name</uninstall_package_name>\n";
			$data .=
"<uninstall_package_version>@uninstall_package_version</uninstall_package_version>\n";
			$data .=
"<update_package_flag>@update_package_flag</update_package_flag>\n";
		}
		else {
			$data .=
"<no_package_update_or_install>1</no_package_update_or_install>\n";
		}
	}
	else {
		$data .=
"<network_connection_timeout>$check_network</network_connection_timeout>\n";
	}
}

#install package
elsif ( $_GET{'action'} eq 'install_package' ) {
	my $package_name  = $_GET{'package_name'};
	my $package_count = $_GET{'package_count'};
	my $check_install = install_package($package_name);
	if ( $check_install =~ /OK/ ) {
		my $file_name = $test_definition_dir . $package_name . "/tests.xml";
		my $case_number_temp = 0;
		open FILE, $file_name or die $!;
		while (<FILE>) {
			if ( $_ =~ /<testcase(.*)/ ) {
				$case_number_temp++;
			}
		}
		$data .=
"<install_package_name>SUCCESS_$package_name</install_package_name>\n";
		$data .= "<case_number_temp>$case_number_temp</case_number_temp>\n";
	}
	else {
		$data .=
		  "<install_package_name>$check_install</install_package_name>\n";
	}
	$data .= "<install_package_count>$package_count</install_package_count>\n";
}

#update package
elsif ( $_GET{'action'} eq 'update_package' ) {
	my $package_name  = $_GET{'package_name'};
	my $count         = $_GET{'package_count'};
	my $cmd           = "sdb shell 'rpm -qa | grep " . $package_name . "'";
	my $version_old   = `$cmd`;
	my $version       = $version_old;
	my $flag          = $_GET{'flag'};
	my $check_install = install_package($package_name);
	if ( $version =~ /-(\d\.\d\.\d-\d)/ ) {
		$version = $1;
	}
	if ( $check_install =~ /OK/ ) {
		my $version_new = `$cmd`;
		if ( $version_new =~ /-(\d\.\d\.\d-\d)/ ) {
			$version = $1;
		}
		if ( $version_old ne $version_new ) {

			# remove old version's widget
			my $cmd =
			  "sdb shell 'wrt-launcher -l | grep " . $package_name . "'";
			my @package_items = `$cmd`;
			pop @package_items;
			foreach (@package_items) {
				my $package_id = "none";
				if ( $_ =~ /^\s+(\d+)\s+(\d+)/ ) {
					$package_id = $2;
				}
				if ( $package_id ne "none" ) {
					system(
						"sdb shell wrt-installer -u $package_id 2>&1 >/dev/null"
					);
				}
			}

			$data .=
"<update_package_name>SUCCESS_$package_name</update_package_name>\n";
			$data .=
			  "<update_package_name_flag>$flag</update_package_name_flag>\n";
		}
		else {
			my $error_message = "new version and old version are the same";
			$data .=
			  "<update_package_name>$error_message</update_package_name>\n";
			$data .=
			  "<update_package_name_flag>$flag</update_package_name_flag>\n";
		}
	}
	else {
		$data .= "<update_package_name>$check_install</update_package_name>\n";
		$data .= "<update_package_name_flag>$flag</update_package_name_flag>\n";
	}
	$data .=
"<update_package_latest_version>$version</update_package_latest_version>\n";
	$data .= "<update_package_count>$count</update_package_count>\n";
}

elsif ( $_GET{'action'} eq 'check_profile_isExist' ) {
	my $file;
	my $save_profile;
	my $option                = $_GET{'option'};
	my $profile_name          = $_GET{'profile_name'};
	my $dir_profile_name      = $profile_dir_manager;
	my $check_profile_isExist = 0;
	my $data_isExist;
	my $data_isNotExist;

	opendir DELPROFILE, $dir_profile_name
	  or die "can not open $dir_profile_name";
	foreach $file ( readdir DELPROFILE ) {
		$save_profile = $file;
		if ( $save_profile eq $profile_name ) {
			$check_profile_isExist = 1;
		}
	}
	if ( $option eq "save" ) {
		$data_isExist    = "save" . $profile_name;
		$data_isNotExist = "save";
	}
	else {
		$data_isExist    = "delete";
		$data_isNotExist = "delete" . $profile_name;
	}
	if ($check_profile_isExist) {
		$data .= "<check_profile_name>$data_isExist</check_profile_name>\n";
	}
	else {
		$data .= "<check_profile_name>$data_isNotExist</check_profile_name>\n";
	}
	closedir DELPROFILE;
}

# execute profile
elsif ( $_GET{'action'} eq 'execute_profile' ) {
	my $file;
	my $flag_i = 0;
	my @select_packages;
	my @advanced_value    = split /\*/, $_GET{"advanced"};
	my @checkbox_value    = split /\*/, $_GET{"checkbox"};
	my @auto_count        = split /\:/, $_GET{'auto_count'};
	my @manual_count      = split /\:/, $_GET{'manual_count'};
	my @package_name_flag = split /\*/, $_GET{"pkg_flag"};

	my $dir_profile_name = $profile_dir_manager;

	$advanced_value_architecture   = $advanced_value[0];
	$advanced_value_version        = $advanced_value[1];
	$advanced_value_category       = $advanced_value[2];
	$advanced_value_priority       = $advanced_value[3];
	$advanced_value_status         = $advanced_value[4];
	$advanced_value_execution_type = $advanced_value[5];
	$advanced_value_test_suite     = $advanced_value[6];
	$advanced_value_type           = $advanced_value[7];
	$advanced_value_test_set       = $advanced_value[8];
	$advanced_value_component      = $advanced_value[9];

	open OUT, '>' . $dir_profile_name . "temp_profile";
	print OUT "[Auto]\n";
	while ( $flag_i < @package_name_flag ) {
		if ( $package_name_flag[$flag_i] eq "a" ) {
			if ( $checkbox_value[$flag_i] =~ /select/ ) {
				$_ = $checkbox_value[$flag_i];
				s/selectcheckbox_//g;
				print OUT $_ . "("
				  . $auto_count[$flag_i] . " "
				  . $manual_count[$flag_i] . ")\n";
				push( @select_packages, $checkbox_value[$flag_i] );
			}
		}
		$flag_i++;
	}
	print OUT "[/Auto]\n";

	print OUT "\n[Advanced-feature]\n";
	print OUT "select_arc=" . $advanced_value_architecture . "\n";
	print OUT "select_ver=" . $advanced_value_version . "\n";
	print OUT "select_category=" . $advanced_value_category . "\n";
	print OUT "select_pri=" . $advanced_value_priority . "\n";
	print OUT "select_status=" . $advanced_value_status . "\n";
	print OUT "select_exe=" . $advanced_value_execution_type . "\n";
	print OUT "select_testsuite=" . $advanced_value_test_suite . "\n";
	print OUT "select_type=" . $advanced_value_type . "\n";
	print OUT "select_testset=" . $advanced_value_test_set . "\n";
	print OUT "select_com=" . $advanced_value_component . "\n";

	print OUT "\n";
	foreach (@select_packages) {
		s/selectcheckbox_//g;
		print OUT "[select-packages]: " . $_ . "\n";
	}
	$data .= "<execute_profile_name>temp_profile</execute_profile_name>\n";
}

# save profile
elsif ( $_GET{'action'} eq 'save_profile' ) {
	my $file;
	my $flag_i = 0;
	my @select_packages;
	my $save_profile_name = $_GET{'save_profile_name'};
	my @advanced_value    = split /\*/, $_GET{"advanced"};
	my @checkbox_value    = split /\*/, $_GET{"checkbox"};
	my @auto_count        = split /\:/, $_GET{'auto_count'};
	my @manual_count      = split /\:/, $_GET{'manual_count'};
	my @package_name_flag = split /\*/, $_GET{"pkg_flag"};

	my $dir_profile_name = $profile_dir_manager;

	$advanced_value_architecture   = $advanced_value[0];
	$advanced_value_version        = $advanced_value[1];
	$advanced_value_category       = $advanced_value[2];
	$advanced_value_priority       = $advanced_value[3];
	$advanced_value_status         = $advanced_value[4];
	$advanced_value_execution_type = $advanced_value[5];
	$advanced_value_test_suite     = $advanced_value[6];
	$advanced_value_type           = $advanced_value[7];
	$advanced_value_test_set       = $advanced_value[8];
	$advanced_value_component      = $advanced_value[9];

	open OUT, '>' . $dir_profile_name . $save_profile_name;
	print OUT "[Auto]\n";
	while ( $flag_i < @package_name_flag ) {
		if ( $package_name_flag[$flag_i] eq "a" ) {
			if ( $checkbox_value[$flag_i] =~ /select/ ) {
				$_ = $checkbox_value[$flag_i];
				s/selectcheckbox_//g;
				print OUT $_ . "("
				  . $auto_count[$flag_i] . " "
				  . $manual_count[$flag_i] . ")\n";
				push( @select_packages, $checkbox_value[$flag_i] );
			}
		}
		$flag_i++;
	}
	print OUT "[/Auto]\n";

	print OUT "\n[Advanced-feature]\n";
	print OUT "select_arc=" . $advanced_value_architecture . "\n";
	print OUT "select_ver=" . $advanced_value_version . "\n";
	print OUT "select_category=" . $advanced_value_category . "\n";
	print OUT "select_pri=" . $advanced_value_priority . "\n";
	print OUT "select_status=" . $advanced_value_status . "\n";
	print OUT "select_exe=" . $advanced_value_execution_type . "\n";
	print OUT "select_testsuite=" . $advanced_value_test_suite . "\n";
	print OUT "select_type=" . $advanced_value_type . "\n";
	print OUT "select_testset=" . $advanced_value_test_set . "\n";
	print OUT "select_com=" . $advanced_value_component . "\n";

	print OUT "\n";
	foreach (@select_packages) {
		s/selectcheckbox_//g;
		print OUT "[select-packages]: " . $_ . "\n";
	}
	$data .=
	  "<save_profile_success>$save_profile_name</save_profile_success>\n";
}

elsif ( $_GET{'action'} eq "check_package_isExist" ) {
	my $file;
	my $load_profile_name = $_GET{'load_profile_name'};
	my $dir_profile_name  = $profile_dir_manager;
	my @installed_packages;
	my @packages_need;
	my @packages_isExist_flag;

	opendir LOADPROFILE, $dir_profile_name
	  or die "can not open $dir_profile_name";
	open IN, $profile_dir_manager . $load_profile_name or die $!;
	foreach $file ( readdir LOADPROFILE ) {
		if ( $file =~ /$load_profile_name/ ) {
			my $temp;
			my @temp;
			while (<IN>) {
				if ( $_ =~ /select-packages/ ) {
					$temp = $_;
					@temp = split /:/, $temp;
					my $package_name = $temp[1];
					$package_name =~ s/^\s*//;
					$package_name =~ s/\s*$//;
					push( @packages_need, $package_name );
				}
			}
		}
	}
	for ( my $i = 0 ; $i < @packages_need ; $i++ ) {
		my $cmd  = "sdb shell ls /usr/share/$packages_need[$i]/tests.xml";
		my $temp = `$cmd`;
		if ( $temp !~ /No such file or directory/ ) {
			$packages_isExist_flag[$i] = "1";
		}
		else {
			$packages_isExist_flag[$i] = "0";
		}
	}
	$data .= "<load_profile>1</load_profile>\n";
	$data .= "<profile_name>$load_profile_name</profile_name>\n";
	$data .= "<packages_need>@packages_need</packages_need>\n";
	$data .=
	  "<packages_isExist_flag>@packages_isExist_flag</packages_isExist_flag>\n";
	closedir LOADPROFILE;
}

# delete profile
elsif ( $_GET{'action'} eq "delete_profile" ) {
	my $delete_profile_name = $_GET{'delete_profile_name'};
	my $dir_profile_name    = $profile_dir_manager;
	opendir DELPROFILE, $dir_profile_name
	  or die "can not open $dir_profile_name";

	foreach $file ( readdir DELPROFILE ) {
		if ( $file =~ /\b$delete_profile_name\b/ ) {
			$delete_profile = $file;
			unlink $dir_profile_name . $delete_profile;
			last;
		}
	}
	closedir DELPROFILE;
	$data .=
	  "<delete_profile_success>$delete_profile_name</delete_profile_success>\n";
}

# write manual result back to the file
elsif ( $_GET{'action'} eq 'save_manual' ) {
	my $content     = $_GET{'content'};
	my @temp_1      = split( "::::", $content );
	my $time        = shift(@temp_1);
	my @content_all = split( ":::", shift(@temp_1) );
	foreach (@content_all) {
		my @content     = split( "__", $_ );
		my $package     = shift(@content);
		my $name_result = shift(@content);
		my $testarea    = shift(@content);
		if ( !defined($testarea) ) {
			$testarea = "none";
		}
		my $bugnumber = shift(@content);
		if ( !defined($bugnumber) ) {
			$bugnumber = "none";
		}

		# handle all cases including manual cases to the xml file
		my @temp_2 = split( ":", $name_result );
		my $name   = shift(@temp_2);
		my $result = shift(@temp_2);
		my $auto_case_result_xml =
		  $result_dir_manager . $time . "/" . $package . "_tests.xml";
		$name =~ s/\s/\\ /g;
		my $cmd_getLine =
		  'grep id=\\"' . $name . '\\" ' . $auto_case_result_xml . ' -n';
		my $grepResult = `$cmd_getLine`;

		if ( $grepResult =~ /\s*(\d*)\s*:(.*>)/ ) {
			my $line_number  = $1;
			my $line_content = $2;
			$line_content =~ s/\s/\\ /g;
			if ( $line_content =~ /result=".*"/ ) {
				$line_content =~ s/result=".*"/result="$result"/;
			}
			else {
				$line_content =~
s/execution_type="manual"/execution_type="manual" result="$result"/;
			}

			system( "sed -i '"
				  . $line_number . "c "
				  . $line_content . "' "
				  . $auto_case_result_xml );
		}

		# write result also back to test.result.xml
		my $tests_result_xml =
		  $result_dir_manager . $time . "/tests.result.xml";
		$cmd_getLine =
		  'grep id=\\"' . $name . '\\" ' . $tests_result_xml . ' -n';
		$grepResult = `$cmd_getLine`;

		if ( $grepResult =~ /\s*(\d*)\s*:(.*>)/ ) {
			my $line_number  = $1;
			my $line_content = $2;
			$line_content =~ s/\s/\\ /g;
			if ( $line_content =~ /result=".*"/ ) {
				$line_content =~ s/result=".*"/result="$result"/;
			}
			else {
				$line_content =~
s/execution_type="manual"/execution_type="manual" result="$result"/;
			}

			system( "sed -i '"
				  . $line_number . "c "
				  . $line_content . "' "
				  . $tests_result_xml );
		}

		# record a copy of manual cases, so we can store comment and bug number
		if ( ( $testarea eq "auto" ) && ( $bugnumber eq "auto" ) ) { }
		else {

			#write result back to file
			if (
				!(
					-e $result_dir_manager . $package . "_manual_case_tests.txt"
				)
			  )
			{
				my $manual_result;
				open $manual_result,
				    ">"
				  . $result_dir_manager
				  . $package
				  . "_manual_case_tests.txt"
				  or die $!;
				close $manual_result;
			}

			my $manual_result;
			open $manual_result,
			  ">>" . $result_dir_manager . $package . "_manual_case_tests.txt"
			  or die $!;
			print {$manual_result} $name_result . "\n";
			close $manual_result;

			#write comment and bug number back to file
			if (
				!(
					  -e $result_dir_manager 
					. $package
					. "_manual_case_tests_comment_bug_number.txt"
				)
			  )
			{
				my $manual_result;
				open $manual_result,
				    ">"
				  . $result_dir_manager
				  . $package
				  . "_manual_case_tests_comment_bug_number.txt"
				  or die $!;
				close $manual_result;
			}
			my $manual_result_comment_bug_number;
			my @temp_name = split( ":", $name_result );
			my $name = shift @temp_name;
			open $manual_result_comment_bug_number,
			    ">>"
			  . $result_dir_manager
			  . $package
			  . "_manual_case_tests_comment_bug_number.txt"
			  or die $!;
			print {$manual_result_comment_bug_number} $package . "__" 
			  . $name . "__"
			  . $testarea . "__"
			  . $bugnumber . "\n";
			close $manual_result_comment_bug_number;
		}
	}
	system( 'mv -f '
		  . $result_dir_manager
		  . "*_manual_case_tests.txt "
		  . $result_dir_manager
		  . $time
		  . "/" );
	system( 'mv -f '
		  . $result_dir_manager
		  . "*_manual_case_tests_comment_bug_number.txt "
		  . $result_dir_manager
		  . $time
		  . "/" );
	updateManualState($time);
	updateAutoState($time);

	# create tar file
	my $tar_cmd_delete = "rm -f " . $result_dir_manager . $time . "/*.tgz";
	my $tar_cmd_create =
	    "tar -czPf "
	  . $result_dir_manager
	  . $time . "/"
	  . $time . ".tgz "
	  . $result_dir_manager
	  . $time . "/*";
	system("$tar_cmd_delete");
	system("$tar_cmd_create &>/dev/null");
	$data .= "<save_manual_redirect>1</save_manual_redirect>\n";
	$data .= "<save_manual_time>$time</save_manual_time>\n";
	$data .= "<save_manual_refresh>1</save_manual_refresh>\n";
}
elsif ( $_GET{'action'} eq 'read_result_xml' ) {
	my $result_path = $_GET{'file'};
	use FileHandle;
	my $fh = new FileHandle($result_path);

	my $file_data = "";
	my $filesize  = -s $result_path;
	my $sz        = read( $fh, $file_data, $filesize );
	$isWholeXML = 1;
	$wholeXML .= $file_data;
	no FileHandle;
}

elsif ( $_GET{'action'} eq 'stop_tests' ) {    # Stop the tests
	if ( !$_GET{'tree'} ) {
		$error_text = 'Incorrect call parameters!';
	}
	else {
		my $PID;
		if ( $_GET{'tree'} eq 'tests' ) {
			if ( lock_status() ) {
				my $status = read_status();
				if ( $status->{'IS_RUNNING'} ) {
					if ( kill( 'TERM', $status->{'PID'} ) ) {
						while (1) {
							my $kill_result = `sdb shell killall testkit-lite`;
							if ( $kill_result =~ /no process killed/ ) {
								last;
							}
						}
						while (1) {
							my $kill_result = `sdb shell killall wrt-client`;
							if ( $kill_result =~ /no process killed/ ) {
								last;
							}
						}
						$data .=
						  '<stopped id="' . $_GET{'tree'} . '">1</stopped>';
					}
					else {
						$error_text =
						  "Failed to send SIGTERM to the process:<br />$!";
					}
				}
				else {
					$error_text = "Test has finished already.";
				}
				unlock_status();
			}
			else {
				$error_text =
				  "Error locking the status file!<br />$status_error";
			}
		}
		elsif ( $_GET{'tree'} eq 'server' ) {
			chdir( $CONFIG{'TESTS_DIR'} );
			my $stop_server_output = tmpnam();
			system(
"$CONFIG{'TESTS_DIR'}/stop_server.pl $SERVER_PARAM{'SERVER_PID'} >$stop_server_output 2>&1"
			);
			if ( $? == 0 ) {
				$data .= '<stopped id="' . $_GET{'tree'} . '">1</stopped>';
			}
			else {
				$error_text = read_file($stop_server_output);
				is_ok($error_text) or $error_text = '';
			}
			unlink($stop_server_output);
		}
		else {
			$error_text = 'Incorrect call parameters!';
		}
	}
}

elsif ( $_GET{'action'} eq 'server_control' )
{    # Updates the config file and forces the server to re-read it
	my %server_params = (
		'ProxyServer'         => '',
		'ProxyServerAuth'     => 'basic',
		'HTTPProxyServer'     => '',
		'HTTPProxyServerAuth' => 'basic',
		'FTPProxyServer'      => '',
		'FTPProxyServerAuth'  => 'basic'
	);

	sub combineURI($$) {
		my ( $key, $prefix ) = @_;
		if ( $_POST{ $prefix . '_proxy_host' } ) {
			$server_params{$key} = $_POST{ $prefix . '_proxy_host' };
			if ( $_POST{ $prefix . '_proxy_port' } ) {
				$server_params{$key} .= ':' . $_POST{ $prefix . '_proxy_port' };
			}
			if ( $_POST{ $prefix . '_proxy_user' } ) {
				if ( $_POST{ $prefix . '_proxy_pswd' } ) {
					$server_params{$key} =
					    $_POST{ $prefix . '_proxy_user' } . ':'
					  . $_POST{ $prefix . '_proxy_pswd' } . '@'
					  . $server_params{$key};
				}
				else {
					$server_params{$key} =
					    $_POST{ $prefix . '_proxy_user' } . '@'
					  . $server_params{$key};
				}
			}
			elsif ( $_POST{ $prefix . '_proxy_pswd' } ) {
				$server_params{$key} =
				    'anonymous:'
				  . $_POST{ $prefix . '_proxy_pswd' } . '@'
				  . $server_params{$key};
			}
		}
		$server_params{ $key . 'Auth' } = $_POST{ $prefix . '_proxy_auth' };
		if ( defined( $_POST{ $prefix . '_proxy_auth_notunnel' } ) ) {
			$server_params{ $key . 'Auth' } .= ',notunnel';
		}
	}

	if ( defined( $_POST{'same_proxy_config'} ) ) {
		combineURI( 'ProxyServer', 'http' );
	}
	else {
		combineURI( 'HTTPProxyServer', 'http' );
		combineURI( 'FTPProxyServer',  'ftp' );
	}

	my $updating_file = 0;
	if ( -f $SERVER_PARAM{'CONF_FILE'}
		and open( CONF_FILE, $SERVER_PARAM{'CONF_FILE'} ) )
	{

		# Read the old file and replace the parameters
		flock( CONF_FILE, LOCK_EX );
		$updating_file = 1;
	}
	elsif ( -f $SERVER_PARAM{'CONF_FILE'} . '.default'
		and open( CONF_FILE, $SERVER_PARAM{'CONF_FILE'} . '.default' ) )
	{

# Read the default file and copy it to the config file, replacing the parameters
		flock( CONF_FILE, LOCK_EX );
		$updating_file = 1;
	}
	my $conf_dir = $SERVER_PARAM{'CONF_FILE'};
	$conf_dir =~ s!/[^/]+$!!;
	( my $fh_new, $conf_file_new ) = tempfile( DIR => $conf_dir );
	my %server_params_saved =
	  ();    # To store information which parameters have been saved
	if ($updating_file) {
		while ( my $line = <CONF_FILE> ) {
			my $written = 0;
			foreach my $param ( keys %server_params ) {
				if ( $line =~ m/^\s*$param\b/ ) {
					if ( !$server_params_saved{$param} ) {
						print $fh_new "$param = $server_params{$param}\n";
						$server_params_saved{$param} = 1;
					}
					$written = 1;
					last;
				}
			}
			if ( !$written ) {
				print $fh_new $line;
			}
		}
	}
	foreach my $param ( sort keys %server_params ) {
		if ( !$server_params_saved{$param} ) {
			print $fh_new "$param = $server_params{$param}\n";
		}
	}
	close($fh_new);
	if ( -f $SERVER_PARAM{'CONF_FILE'}
		and !unlink( $SERVER_PARAM{'CONF_FILE'} ) )
	{
		$error_text =
		  "Failed to unlink the old file $SERVER_PARAM{'CONF_FILE'}:<br />$!";
	}
	else {
		if ( !rename( $conf_file_new, $SERVER_PARAM{'CONF_FILE'} ) ) {
			$error_text =
"Failed to rename the new file $conf_file_new to $SERVER_PARAM{'CONF_FILE'}:<br />$!";
		}
	}
	if ($updating_file) {
		flock( CONF_FILE, LOCK_UN );
		close(CONF_FILE);
	}

	if ( !$error_text ) {
		if ( kill( 'HUP', $SERVER_PARAM{'SERVER_PID'} ) ) {
			$data .= '<serverupd>1</serverupd>';
		}
		else {
			$error_text = "Failed to send SIGHUP to the server:<br />$!";
		}
	}
}
elsif ( $_GET{'action'} eq 'check_update' ) {    # Stop the tests
	if ( !$_GET{'version'}
		or ( $_GET{'version'} !~ m/^(\d+)\.(\d+)\.(\d+)-(\d+)$/ ) )
	{
		$error_text = 'Incorrect call parameters!';
	}
	else {
		my @cur_ver = ( $1, $2, $3, $4 );        # Current version details
		system(
"wget -O /tmp/dc-update.$$ http://ftp.linuxfoundation.org/pub/lsb/test_suites/released-3.2.0/binary/runtime/"
		);
		if ($?) {
			$error_text =
'Failed to download information!<br />Please, check your Internet connection.';
		}
		else {
			my $file = read_file("/tmp/dc-update.$$");
			is_ok($file) or $file = '';
			$pkg_name = lc($MTK_BRANCH) . '-dist-checker';
			if ( $file =~ m/href="$pkg_name-(.+)\.([^.]+)\.rpm"/ ) {
				my $ver = $1;
				if ( $ver =~ m/^(\d+)\.(\d+)\.(\d+)-(\d+)$/ ) {
					my @upd_ver = ( $1, $2, $3, $4 );    # FTP version details
					my $update = '0';
					for ( my $i = 0 ; $i < scalar(@cur_ver) ; ++$i ) {
						if ( $cur_ver[$i] > $upd_ver[$i] ) {
							last;
						}
						if ( $cur_ver[$i] < $upd_ver[$i] ) {
							$update = '1';
							last;
						}
					}
					$data .=
					    "<update>$update</update><curver>"
					  . $_GET{'version'}
					  . "</curver><updver>$ver</updver>";
				}
				else {
					$error_text = "Failed to parse version '$ver'.";
				}
			}
			else {
				$error_text = 'Failed to parse the downloaded list.';
			}
		}

		#unlink("/tmp/dc-update.$$");
	}
}
elsif ( $_GET{'action'} eq 'fip' ) {
	if ( $_POST{'result'} && $_GET{'details'} && $_POST{'testcase'} ) {
		my $fips_file =
		  $CONFIG{'RESULTS_DIR'} . '/' . $_GET{'details'} . '/results/fips';
		my $fips_data = {};

		# Read FIPs data from the file
		if ( open( my $fh, '+>>' . $fips_file ) ) {
			flock( $fh, LOCK_EX );
			seek( $fh, 0, SEEK_SET );
			my $testcase = undef;
			while ( my $line = <$fh> ) {
				chomp $line;
				if ( $line =~ m/^TESTCASE:\s*(.*)/ ) {
					$testcase = $1;
				}
				elsif ( $line =~ m/^RESULT:\s*(.*)/ ) {
					$fips_data->{$testcase}{'RESULT'} = $1;
				}
				elsif ( $line =~ m/^COMMENT:\s*(.*)/ ) {
					local $_;
					$_ .= ( defined && "\n" ) . $1
					  for $fips_data->{$testcase}{'COMMENT'};
				}
			}

			# Add the POSTed data
			$testcase = $_POST{'testcase'};
			$fips_data->{$testcase}{'RESULT'} = $_POST{'result'};
			if ( $_POST{'comment'} ) {
				$fips_data->{$testcase}{'COMMENT'} = $_POST{'comment'};
			}

			# Save back
			seek( $fh, 0, SEEK_SET );
			truncate( $fh, 0 );
			foreach my $testcase ( sort keys %$fips_data ) {
				print $fh 'TESTCASE: ' . $testcase . "\n";
				if ( defined $fips_data->{$testcase}{'RESULT'} ) {
					print $fh 'RESULT: '
					  . $fips_data->{$testcase}{'RESULT'} . "\n";
				}
				if ( defined $fips_data->{$testcase}{'COMMENT'} ) {
					my $comment = $fips_data->{$testcase}{'COMMENT'};
					$comment =~ s/\r\n?/\n/g;
					for my $line ( split /\n/, $comment ) {
						print $fh 'COMMENT: ' . $line . "\n";
					}
				}
				print $fh "\n";
			}
			flock( $fh, LOCK_UN );
			close $fh;

			$data .= '<updated/>';
		}
		else {
			$error_text = "Failed to save FIPs status to file '$fips_file'.";
		}

		# Save a JS file
		my $js_file =
		  $CONFIG{'RESULTS_DIR'} . '/' . $_GET{'details'} . '/fips.js';
		if ( open( my $fh, '+>>' . $js_file ) ) {
			flock( $fh, LOCK_EX );
			seek( $fh, 0, SEEK_SET );
			truncate( $fh, 0 );

			print {$fh} "var fip_results = Array();\n";
			print {$fh} "var fip_comments = Array();\n";
			foreach my $testcase ( sort keys %$fips_data ) {
				if ( $fips_data->{$testcase}{'RESULT'} ) {
					my $result = $fips_data->{$testcase}{'RESULT'};
					( $result eq 'pass' || $result eq 'fail' ) or next;
					print {$fh} "fip_results['$testcase'] = \"" . $result
					  . "\";\n";
				}
				if ( $fips_data->{$testcase}{'COMMENT'} ) {
					my $comment = $fips_data->{$testcase}{'COMMENT'};
					$comment =~ s/(?:\r\n?|\n)/\\n/g;
					$comment =~ s/\"/&quot;/g;

					# TODO: better escaping?
					print {$fh} "fip_comments['$testcase'] = \"" . $comment
					  . "\";\n";
				}
			}
			flock( $fh, LOCK_UN );
			close $fh;
		}
		else {
			$error_text = "Failed to save FIPs status to file '$js_file'.";
		}
	}
}
elsif ( $_GET{'action'} eq 'repack' ) {

	# Repack the results tarball
	my $testrun_id = $_GET{'details'};
	if ( $testrun_id && -d $CONFIG{'RESULTS_DIR'} . '/' . $testrun_id ) {
		my $tarball_file =
		    $CONFIG{'RESULTS_DIR'} . '/'
		  . $testrun_id . '/'
		  . $testrun_id . '.tgz';
		if ( -f $tarball_file ) {
			system( 'rm -f ' . shq($tarball_file) );    # Remove the old tarball
		}

		my $tmp_file = extract_filename($tarball_file);
		(
			system(
				    'cd '
				  . shq( $CONFIG{'RESULTS_DIR'} )
				  . ' && tar czf '
				  . shq($tmp_file) . ' '
				  . shq($testrun_id)
				  . ' && mv '
				  . shq($tmp_file) . ' '
				  . shq($tarball_file)
			  ) == 0
		) or $error_text = 'Failed to repack the results.';

		$data .= '<repacked/>';
	}
}
elsif ( $_GET{'action'} eq 'load_child' ) {
	my $tests_node = $_GET{'node'};
	list_subdir($tests_node);

}
elsif ( $_GET{'action'} eq 'load_testcase' ) {
	my $test_case = $_GET{'case'};

	#list_testcase($test_case);
	use QueryTestXml;
	$data .= &query_testcase( $test_case, 0 );
	no QueryTestXml;
	$isJson = 1;
}
elsif ( $_GET{'action'} eq 'load_manual_testcase' ) {
	my $test_case = $_GET{'case'};
	use QueryTestXml;
	$data .= &query_testcase( $test_case, 1 );
	no QueryTestXml;
	$isJson = 1;
}
elsif ( $_GET{'action'} eq 'load_package' ) {
	my $test_package = $_GET{'case'};

	#list_testcase($test_case);
	use QueryTestXml;
	$data .= &query_testpackage($test_package);
	no QueryTestXml;
	$isJson = 1;
}
elsif ( $_GET{'action'} eq 'load_suit' ) {
	my $test_suit = $_GET{'case'};

	#list_testcase($test_case);
	use QueryTestXml;
	$data .= &query_testsuit($test_suit);
	no QueryTestXml;
	$isJson = 1;
}
elsif ( $_GET{'action'} eq 'load_set' ) {
	my $test_set = $_GET{'case'};

	#list_testcase($test_case);
	use QueryTestXml;
	$data .= &query_testset($test_set);
	no QueryTestXml;
	$isJson = 1;
}
elsif ( $_GET{'action'} eq 'load_prochild' ) {
	my $tests_node = $_GET{'node'};
	my $testrun_id = $_GET{'test_run'};
	my $tests_profile =
	  $CONFIG{'RESULTS_DIR'} . '/' . $testrun_id . '/profile.manual';
	list_profiled_subdir( $tests_node, $tests_profile );

}
elsif ( $_GET{'action'} eq 'load_caselist' ) {
	my $tests_node = $_GET{'node'};
	my $testrun_id = $_GET{'test_run'};
	my $tests_profile =
	  $CONFIG{'RESULTS_DIR'} . '/' . $testrun_id . '/profile.manual';
	my $tests_result_dir =
	  $CONFIG{'RESULTS_DIR'} . '/' . $testrun_id . '/results';
	my $tests_result   = $tests_result_dir . '/manualtest.res';
	my @initial_result = ();

	if ( !-s $tests_result_dir ) {
		mkdir( $tests_result_dir, 0755 )
		  || die "could not create directory $tests_result_dir";
	}
	if ( !-e $tests_profile ) {
		my $copycmd =
"cp /tmp/moblin-testkit/profiles/test/~manual_test.profile $tests_profile";
		my $ret = `$copycmd`;
	}

#	if (! -e $tests_result)
#	{
#		my $copy_testcase = "cp /tmp/moblin-testkit/profiles/test/~manual_test.res $tests_result";
#		my $ret = `$copy_testcase`;
#	}
	if ( !-e $tests_result ) {
		open( NEW_FILE, ">$tests_result" )
		  || die "could not create testresult file $tests_result";
		if ( ( open( PROFILE, $tests_profile ) ) ) {
			while (<PROFILE>) {
				my $test_suite = $_;
				$test_suite =~ s/\r//g;
				$test_suite =~ s/\n//g;
				my $full_path =
				    $SERVER_PARAM{'APP_DATA'}
				  . '/tests/'
				  . $test_suite
				  . "/testspec";

			  #			$data .= "<man_result>test suit: ".$full_path."</man_result>";
				if ( opendir( SPEC_DIR, "$full_path" ) ) {
					foreach ( sort( grep( !/^[\.]/, readdir(SPEC_DIR) ) ) ) {
						my $tests = $_;

				#					$data .= "<man_result>test case: ".$tests."</man_result>";
						if ( $tests =~ /(.*)\.xml/ ) {

		#							$data .= "<man_result>Inner test case: ".$tests."</man_result>";
							my $test_case = $1;
							print NEW_FILE $test_suite . "  ";
							print NEW_FILE $test_case . "  ";
							print NEW_FILE "NotRun\n";
						}
					}
				}
			}
		}
		close(NEW_FILE);
	}

	@initial_result = read_manual_result($tests_result);
	if ( open( NEW_FILE, ">$tests_result" ) ) {
		foreach my $item (@initial_result) {
			print NEW_FILE $item->{'suitname'} . "  ";
			print NEW_FILE $item->{'casename'} . "  ";
			print NEW_FILE $item->{'teststatus'} . "\n";
		}
	}
	close(NEW_FILE);
	list_profiled_caselist( $tests_node, $tests_result );
}
elsif ( $_GET{'action'} eq 'mantest_submit' ) {
	my $testrun_id = $_GET{'test_run'};
	my $nodePath   = $_GET{'case'};
	my $caseStatus = $_GET{'teststatus'};

	my @folders = split( "\/\/\/", $nodePath );
	my $packageName = shift @folders;

	if ($nodePath) {
		$nodePath =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
	}

	$TestKitLogger::logger->log( message =>
"\n[ajax_srv.pl]: testrun_id:\n$testrun_id\n NodePath: \n$nodePath\nCaseStatus: $caseStatus\n"
	);

#my $tests_result = $CONFIG{'RESULTS_DIR'}.'/'.$testrun_id.'/results/manualtest.res';
	my $tests_result =
	    $CONFIG{'RESULTS_DIR'} . '/'
	  . $testrun_id . '/'
	  . $packageName
	  . '/result.tests.xml';
	$TestKitLogger::logger->log( message => "Result File: $tests_result" );

	#my $result_jsonStr = $_POST{'jsonStr'};
	#save_case_result($tests_result, $result_jsonStr);
	use QueryTestXml;
	&updateCaseResult( $tests_result, $nodePath, $caseStatus );
	no QueryTestXml;

	$data .= "<man_result>Manual Test Result Save Succeed</man_result>";
}
elsif ( $_GET{'action'} eq 'mantest_finish' ) {
	my $testrun_id = $_GET{'test_run'};

	use ProcessSummary;
	my $na_num =
	  &generateManualSummary( $CONFIG{'RESULTS_DIR'} . '/' . $testrun_id );
	no ProcessSummary;

	my $tests_status =
	  $CONFIG{'RESULTS_DIR'} . '/' . $testrun_id . '/test_status';

	if ( $$na_num == 0 ) {
		if ( open( NEW_FILE, ">$tests_status" ) ) {
			print NEW_FILE "Auto: Finished\nManual: Finished";
			close(NEW_FILE);
		}

		#&push_result_back($CONFIG{'RESULTS_DIR'}.'/'.$testrun_id);

		$data .= "<man_result>test status saved</man_result>";
	}
	else {
		$data .= "<man_result>$na_num manual case is NotRun</man_result>";
	}
}

#elsif ( $_GET{'action'} eq 'save_profile' ) {
#	if ( !-e $SERVER_PARAM{'APP_DATA'} . '/profiles/test/' ) {
#		system("mkdir $SERVER_PARAM{'APP_DATA'}/profiles/test");
#	}
#	my $profile_path =
#	  $SERVER_PARAM{'APP_DATA'} . '/profiles/test/' . $_GET{'profile'};
#	my $profile_js = $_POST{'jsonStr'};
#	save_profile( $profile_path, $profile_js );
#}
#elsif ( $_GET{'action'} eq 'delete_profile' ) {
#	my $profile =
#	  $SERVER_PARAM{'APP_DATA'} . '/profiles/test/"' . $_GET{'profile'} . '"';
#	my $rmcmd = "rm -f $profile";
#	my $ret   = `$rmcmd`;

#	$data .=
#	    "<profile_result>Profile "
#	  . $_GET{'profile'}
#	  . " remove Succeed</profile_result>";

##       $data .= "<profile_result>User ".$rmcmd." delete Succeed</profile_result>";
#}
#elsif ( $_GET{'action'} eq 'load_profile' ) {
#	my $profile_path =
#	  $SERVER_PARAM{'APP_DATA'} . '/profiles/test/' . $_GET{'profile'};
#	load_profile($profile_path);
#}
elsif ( $_GET{'action'} eq 'load_user' ) {
	my $default_user =
	  $SERVER_PARAM{'APP_DATA'} . '/profiles/user/user.profile';
	my $user    = $SERVER_PARAM{'APP_DATA'} . '/profiles/user/' . $_GET{'user'};
	my $copycmd = "cp $user $default_user";
	my $ret     = `$copycmd`;

	$data .= "<profile_result>User Load Succeed</profile_result>";
}
elsif ( $_GET{'action'} eq 'delete_user' ) {
	my $user  = $SERVER_PARAM{'APP_DATA'} . '/profiles/user/' . $_GET{'user'};
	my $rmcmd = "rm -f $user";
	my $ret   = `$rmcmd`;

	$data .=
	    "<profile_result>User "
	  . $_GET{'user'}
	  . " delete Succeed</profile_result>";

   #	$data .= "<profile_result>User ".$rmcmd." delete Succeed</profile_result>";
}
elsif ( $_GET{'action'} eq 'save_user' ) {
	my $default_user =
	  $SERVER_PARAM{'APP_DATA'} . '/profiles/user/user.profile';
	my $user = $SERVER_PARAM{'APP_DATA'} . '/profiles/user/' . $_GET{'user'};
	my $user_jsonStr = $_POST{'jsonStr'};
	save_user( $user, $user_jsonStr );

	my $copycmd = "cp $user $default_user";
	my $ret     = `$copycmd`;

	$data .= "<profile_result>User Save Succeed</profile_result>";
}
else {
	$error_text = 'Incorrect call parameters!';
}

sub updateAutoState {
	my ($time) = @_;
	undef %autoResult;
	find( \&updateAutoState_wanted, $result_dir_manager . $time . "/" );

	open FILE, $result_dir_manager . $time . "/info"
	  or die "Can't open " . $result_dir_manager . $time . "/info";

	my $package_name;
	my $inside;
	my $line = 0;
	while (<FILE>) {
		$line++;
		if ( $_ =~ /Package:(.*)/ ) {
			$inside       = "False";
			$package_name = $1;
			foreach ( keys %autoResult ) {
				if ( $_ eq $package_name ) {
					$inside = "True";
				}
			}
		}
		if ( $_ =~ /Pass\(M\):(\d*)/ ) {
			if ( $inside eq "True" ) {
				my @result_all  = split( ":", $autoResult{$package_name} );
				my $pass_all    = int($1) + int( $result_all[0] );
				my $line_number = $line - 3;
				system( "sed -i '"
					  . $line_number
					  . 'c Pass:'
					  . $pass_all
					  . "' ../../../results/"
					  . $time
					  . '/info' );
				$line_number = $line + 3;
				system( "sed -i '"
					  . $line_number
					  . 'c Pass(A):'
					  . int( $result_all[0] )
					  . "' ../../../results/"
					  . $time
					  . '/info' );
			}
		}
		if ( $_ =~ /Fail\(M\):(\d*)/ ) {
			if ( $inside eq "True" ) {
				my @result_all  = split( ":", $autoResult{$package_name} );
				my $fail_all    = int($1) + int( $result_all[1] );
				my $line_number = $line - 3;
				system( "sed -i '"
					  . $line_number
					  . 'c Fail:'
					  . $fail_all
					  . "' ../../../results/"
					  . $time
					  . '/info' );
				$line_number = $line + 3;
				system( "sed -i '"
					  . $line_number
					  . 'c Fail(A):'
					  . int( $result_all[1] )
					  . "' ../../../results/"
					  . $time
					  . '/info' );
			}
		}
	}
}

sub updateAutoState_wanted {
	my $dir = $File::Find::name;
	if ( $dir =~ /.*\/(.*)_tests.xml$/ ) {
		my $package_name = $1;
		if ( $dir !~ /_manual_case_tests.xml$/ ) {
			my $pass  = 0;
			my $fail  = 0;
			my $block = 0;
			my $total = 0;
			open FILE, $dir
			  or die "Can't open " . $dir;
			while (<FILE>) {

				# just count auto case
				if ( $_ =~ /.*<testcase.*execution_type="auto".*/ ) {
					if ( $_ =~ /result="N\/A"/ ) {
						$block += 1;
					}
					if ( $_ =~ /result="PASS"/ ) {
						$pass += 1;
					}
					if ( $_ =~ /result="FAIL"/ ) {
						$fail += 1;
					}
				}
			}
			$total = $pass + $fail + $block;
			if ( $total > 0 ) {
				$autoResult{$package_name} = $pass . ":" . $fail;
			}
		}
	}
}

sub updateManualState {
	my ($time) = @_;
	undef %manualResult;
	find( \&updateManualState_wanted, $result_dir_manager . $time . "/" );

	open FILE, $result_dir_manager . $time . "/info"
	  or die "Can't open " . $result_dir_manager . $time . "/info";

	my $package_name;
	my $inside;
	my $line = 0;
	while (<FILE>) {
		$line++;
		if ( $_ =~ /Package:(.*)/ ) {
			$inside       = "False";
			$package_name = $1;
			foreach ( keys %manualResult ) {
				if ( $_ eq $package_name ) {
					$inside = "True";
				}
			}
		}
		if ( $_ =~ /Pass\(A\):(\d*)/ ) {
			if ( $inside eq "True" ) {
				my @result_all  = split( ":", $manualResult{$package_name} );
				my $pass_all    = int($1) + int( $result_all[0] );
				my $line_number = $line - 6;
				system( "sed -i '"
					  . $line_number
					  . 'c Pass:'
					  . $pass_all
					  . "' ../../../results/"
					  . $time
					  . '/info' );
				$line_number = $line - 3;
				system( "sed -i '"
					  . $line_number
					  . 'c Pass(M):'
					  . int( $result_all[0] )
					  . "' ../../../results/"
					  . $time
					  . '/info' );
			}
		}
		if ( $_ =~ /Fail\(A\):(\d*)/ ) {
			if ( $inside eq "True" ) {
				my @result_all  = split( ":", $manualResult{$package_name} );
				my $fail_all    = int($1) + int( $result_all[1] );
				my $line_number = $line - 6;
				system( "sed -i '"
					  . $line_number
					  . 'c Fail:'
					  . $fail_all
					  . "' ../../../results/"
					  . $time
					  . '/info' );
				$line_number = $line - 3;
				system( "sed -i '"
					  . $line_number
					  . 'c Fail(M):'
					  . int( $result_all[1] )
					  . "' ../../../results/"
					  . $time
					  . '/info' );
			}
		}
	}
}

sub updateManualState_wanted {
	my $dir = $File::Find::name;
	if ( $dir =~ /.*\/(.*)_manual_case_tests.txt$/ ) {
		my $package_name = $1;
		my $pass         = 0;
		my $fail         = 0;
		my $block        = 0;
		my $total        = 0;
		open FILE, $dir
		  or die "Can't open " . $dir;
		while (<FILE>) {
			if ( $_ =~ /:N\/A/ ) {
				$hasManual = "True";
				$block += 1;
			}
			if ( $_ =~ /:PASS/ ) {
				$pass += 1;
			}
			if ( $_ =~ /:FAIL/ ) {
				$fail += 1;
			}
		}
		$total = $pass + $fail + $block;
		if ( $total > 0 ) {
			$manualResult{$package_name} = $pass . ":" . $fail;
		}
	}
}

send_reply();

