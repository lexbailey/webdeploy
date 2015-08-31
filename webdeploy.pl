#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use File::stat;
use File::Basename;
use Net::FTP;
use Term::ReadKey;
use Pod::Usage qw(pod2usage);

# Take a wildcard pattern and produce a regex
sub glob2pat {
    my $globstr = shift;
    my %patmap = (
        '*' => '.*',
        '?' => '.',
        '[' => '[',
        ']' => ']',
    );
    $globstr =~ s{(.)} { $patmap{$1} || "\Q$1" }ge;
    return '^' . $globstr . '$';
}

# Test if a file should be excluded
sub fileExcluded{
	my ($filename, @exclude, @globExclude) = @_;
	for (@globExclude, @exclude){
		if ($filename =~ /$_/){
			return 1;
		}
	}
	return 0;
}

# Load a list of excludes from a file
sub getExcludes{
	my ($excludeName) = @_;
	my @excludeList;
	if (-e $excludeName){
		open(EXC, '<', $excludeName) or die "Error. '$excludeName' file exists but cannot be read. $!.\n";
		while (<EXC>) {
			if (not m/^\s*$/ and not m/^\s*#/){
				s/\R//g;
				push (@excludeList, glob2pat($_));
			}
		}
	}
	return @excludeList;
}

# Scan a directory for files to deploy
sub scanDir{

	my ($directory, $exclude, @globExclude) = @_;

	# Get directory specific excludes
	my $excludeFile = "$directory/$exclude";
	my @exclude = getExcludes($excludeFile);

	# Open directory
	opendir (DIR, $directory) or die "$!.\n";

	my @dirs;
	my @files;

	while (my $file = readdir(DIR)) {
		# For each file in the directory, check if we should deploy it (also throw away .. and . )
		if ($file =~ m/^(?!\.\.)/ and not $file =~ m/^\.$/ and not fileExcluded($file, @exclude, @globExclude)){
			# Perhaps we actually found a directory, add it to the dirs list
			if (-d "$directory/$file"){
				push(@dirs, "$directory/$file");
			}
			# If it's just a normal file, add it to the list
			else{
				push(@files, "$directory/$file");
			}
		}
	}

	closedir(DIR);

	# Now check each subdir we need to look in
	for (@dirs){
		@files = (@files, scanDir($_, $exclude, @globExclude));
	}

	return @files;
}

# Get the unix timestamp for a filename on the local machine
sub getLocalFileTime{
	my ($filename) = @_;
	my $t = (stat($filename)->mtime);
	return $t;
}

sub main{

	# Default settings
	my $exclude = '.exclude';
	my $globalExclude = '.globalexclude';
	my $dryrun = '';
	my $ftpdryrun = '';

	my $ftpserver = '';
	my $ftpuser = $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);
	my $ftpport = '21';
	my $isNotFtps = '';

	my $rootdir = '';

	my $help = '';

	my $config = '';

	my %options = (
		'exclude'         => \$exclude,
		'globalexclude'   => \$globalExclude,
		'dry-run'         => \$dryrun,
		'ftp-dry-run'     => \$ftpdryrun,
		'server'          => \$ftpserver,
		'user'            => \$ftpuser,
		'port'            => \$ftpport,
		'no-ftps'         => \$isNotFtps,
		'no-tls'          => \$isNotFtps,
		'server-root'     => \$rootdir,
		'help'            => \$help,
		'config'          => \$config
	);

	# Get user settings from command line
	GetOptions ( \%options, 'exclude=s', 'globalexclude=s', 'dry-run', 'ftp-dry-run', 'server=s', 'user=s', 'port=s', 'no-ftps', 'no-tls', 'server-root=s', 'help', 'config=s')
	or pod2usage(2);
	pod2usage(1) if $help;

	my $configMustExist = 1;

	# Check for a configuration file
	if ($config eq ""){
		# If no config file is specified, use the default
		$config = ".webdeploy_conf";
		# In this case, it isn't a problem if it isn't there
		$configMustExist = 0;

	}

	# If we do have a config file...
	if ( -e $config ){
		# Start reading
		open(CONF, '<', $config) or die "Error. '$config' file exists but cannot be read. $!.\n";
		my $line = 0;
		while (<CONF>) {
			$line ++;
			# Discard any lines that are blank or start with a hash.
			if (not m/^\s*$/ and not m/^\s*#/){
				# All other lines should match this regex for a KVP.
				if ( m/^\s*([^= \n]+)\s*=\s*([^ \n]*.*[^ \n]*)\s*$/ ){
					my $conf_key = $1;
					my $conf_val = $2;
					my $got_conf_opt = 0;
					foreach (keys(%options)){
						# Look at each option, see if this is the one we are specifying (ignore the 'config' option, this is not valid inside a config file.)
						if ($conf_key eq $_ and $conf_key ne "config"){
							# Assign the new value and break the loop
							my $opt_ref = $options{$_};
							${$opt_ref} = $conf_val;
							$got_conf_opt = 1;
							last;
						}
					}
					# If this option wasn't in the list of valid options then error and exit.
					if ($got_conf_opt != 1){
						die("Unknown option in configuration file. ($config: $line) '$conf_key'\n");
					}
				}
				# Line was not a valid KVP.
				else{
					chomp;
					die("Configuration file syntax error. ($config: $line) '$_' expected OPTION=VALUE\n");
				}
			}
		}
	}
	else{
		# If the user specified a config file and we can't find it, error and exit.
		if ( $configMustExist ){
			die ("Configuration file not found ($config)\n");
		}
	}

	# Get the global exclude list
	my @globExclude = getExcludes($globalExclude);

	# Get a list of files to deploy
	my @filesToDeploy = scanDir(".", $exclude, @globExclude);

	# if this is a dry run, just print the files to deploy and exit
	if ($dryrun){
		print "Files to deploy:\n";
		for(@filesToDeploy){
			print"\t$_\n";
		}
		return;
	}

	# Now that we know what we need to put on the server, lets log in.

	# first check we have a valid host name
	if ($ftpserver eq ""){
		die "No host name specified. (--server)\n"
	}

	# Decide if we are going to do TLS or not
	my $tls = 1; if ($isNotFtps){ $tls = 0; }

	# Connect to the server
	my $ftp = Net::FTP->new($ftpserver, Debug => 0, PORT => $ftpport, SSL => $tls) or die "Cannot connect to $ftpserver on port $ftpport: $@\n";
	$ftp->binary;

	# We are now ready for the user to log in, get their password
	print "Enter password for ${ftpuser}\@${ftpserver}: "; ReadMode('noecho'); chomp(my $password = ReadLine(0)); ReadMode('normal');
	print "\n";

	# Log in!
	$ftp->login($ftpuser, $password) or die "Error when logging in as ${ftpuser}\@${ftpserver}: ", $ftp->message, "\n";

	$password = ''; # Discard password

	# Now go to the directory where the user wants their files to be
	$ftp->cwd("/$rootdir") or die "Error selecting root directory: ", $ftp->message, "\n";

	my @filesToUpdate;

	# Of the files we need to deploy, see which ones are new or have changed locally.
	# These are put in a list of files we need to update.
	for (@filesToDeploy){
		my $serverModTime = $ftp->mdtm($_);
		if ($serverModTime){
			my $localModTime = getLocalFileTime($_);
			if ($localModTime > $serverModTime){
				push @filesToUpdate, $_;
				print "File: '$_' needs update.\n" if ($ftpdryrun);
			}
		}
		else{
			push @filesToUpdate, $_;
			print "File: '$_' is new\n" if ($ftpdryrun);
		}
	}

	# If this is just an ftp-dry-run then print which files would have been uploaded and exit.
	if ($ftpdryrun){
		if (@filesToUpdate){
			print("Files will be uploaded to '/$rootdir' when used without --ftp-dry-run\n");
		}
		else{
			print("There are no files that need updating.\n");
		}
		return;
	}

	# Get number of files to update to show progress.
	my $num = @filesToUpdate;
	my $i = 0;

	# Go into auto flush mode
	$| = 1;

	# Upload all files we need to update
	for (@filesToUpdate){
		$i++;
		print ("\rUploading file $i of $num. '$_'");
		my $basename = basename($_);
		my $dirname  = dirname($_);
		my $fullpath = "/$rootdir/$dirname";
		# If we can't change to this dir, we probably need to create it
		if ( ! $ftp->cwd($fullpath) ){
			# Try to create it, if we fail, notify the user.
			$ftp->mkdir($fullpath, 1) or die ("Fatal: Unable to create new directory on server '$fullpath' check permissions.\n");
			$ftp->cwd($fullpath) or die ("Fatal: Unable to create new directory on server '$fullpath' check permissions.\n");
		}
		$ftp->put($_, $basename);
	}

	# Get out of auto flush mode
	$| = 0;
	print ("\n");

	# Task complete, woohoo!
	print ("Done.\n");
	$ftp->quit; # Don't forget to log out nicely
}

main();

__END__

=head1 WebDeploy

webdeploy - Deploy local files to an ftp server.

=head1 SYNOPSIS

webdeploy [options]

Options:

--exclude              Specify the name of the exclude file. (default: '.exclude')

--globalexclude        Specify the name of the global exclude file. (default: '.globalexclude')



--server               Specify the host name or address.

--port                 Specify the port number for the connection. (default: 21)

--server-root          Specify the root folder on the server where files should be uploaded.



--user                 Specify the user name for login. (defaults to current user)



--no-ftps  --no-tls    Disable Transport Layer Security (TLS) to use plain FTP instead of FTPS



--dry-run              Print the list of local files that will be checked for upload, exit without uploading.

--ftp-dry-run          Log in to the FTP server to check which local files are new or out of date, exit without uploading.


--config               Specify configuration file (default: '.webdeploy_conf')


--help                 brief help message


=head1 OPTIONS

=over 4

=item B<--exclude>

Specify the name of an exclude file. Before WebDeploy scans a directory for files to upload, it will read the exclude file.
Any directories listed in the exclude file will not be scanned, any other file in the directory that are listed in the exclude file will not be uploaded.
This happens in each directory that is scanned. An exclude file is uniqe to the directory.
All exclude files must have the same name however. By default, WebDeploy looks for a file called '.exclude'. If the file doesn't exist then nothing will be excluded.
See exclude files section below for more details.

=item B<--globalexclude>

This is much the same as the normal exclude file.
The difference is that this file is only looked for in the root directory (where you ran webdeploy) and all exclusions in this file are applied to every directory scanned.
See exclude files section below for more details.

=item B<--server-root>

This specifies the root directory on the server that will be used for upload.
Any files in your root working direct when you run webdeploy will be uploaded to this folder.
This is always specified relative to '/' on the server.
If you want your files to appear in '/' on the server then you do not need to set this option.
If you set this option, make sure you specify a directory without a leading or trailing slash.

For example, if you want your files uploaded to '/var/www/' on the server, then use the option '--server-root var/www'

=item B<--dry-run>

Print the list of local files that will be checked for upload, exit without uploading.
This is useful for checking that you have set up the exclude files correctly.

=item B<--ftp-dry-run>

Log in to the FTP server to check which local files are new or out of date on the server, exit without uploading.
This is useful for checking which files you have updated or created since the last deploy.
This also shows the directory on the server that will be used as the root directory for upload.
The root directory can be set with --server-root


=back

Note that all options can be specified using any unique abbreviation.
(--conf is the same as --config, however --ser is invalid because it is the start of --server and --server-root)

=head1 DESCRIPTION

B<WebDeploy> will upload files from the current local directory to an FTP server.
Files are only uploaded if the local version is newer than the server version.
Files can be excluded using the 'exclude' and 'globalexclue' options.

=head1 CONFIG FILES

By default, WebDeploy will look for a file called .webdeploy_conf in the current directory. If this file is found then it will load the options from this file.
You can specify a different config file on the command line using the --config option.

All of the options that are available on the command line (except for the --config option) can be specified in a config file.

A config file must consist only of blank lines, comment lines (that start with a '#' symbol) and option lines (which are key-value-pairs).
Option lines take the form of 'KEY = VALUE'.
All characters after the first equals sign (sans leading and trailing blanks) are considered to be part of the value.
A value can therefore contain an equals sign without any special escaping.

Note that no warnings will be issued if an option is specified on both the command line and the config file. In this case, the config file has priority.

Also note that option names (keys) in configuration files cannot be abbreviated like command line options.

Here is an example configuration file:

    # Server connection details
    server = ftp.example.com
    port   = 1234

    # Login user name
    user = daniel

    # Server's public html folder
    server-root = var/www


=head1 EXCLUDE FILES

An exclude file will consist only of blank lines, comment lines (that start with a '#' symbol) and patterns to match files to exclude.

To exclude a file called 'foo' you could use a config file like this:

    # Exclude the file 'foo'
    foo

To exclude all files that end with '.foo' you can use a wildcard pattern like this:

    # Exclude all files with the foo extension.
    *.foo

You can also match against a class of characters:

    # Exclude a.foo and b.foo but not c.foo
    [ab].foo

To exclude a directory, simply name the directory without any leading or trailing slashes:

    # Exclude the 'src' directory
    src

Gotcha: a directory could match a pattern you intended to only apply to regular files

=head1 EXAMPLES

Upload files via a plain ftp connection to ftp.example.com, port 1234 as user 'user@example.com'

    webdeploy --server=ftp.example.com --user=user@example.com --port=1234 --no-tls

See which files need uploading (have changed since the last upload) using the settings in 'my_config.conf'

    webdeploy --config my_config.conf --ftp-dry-run

See what files will be uploaded (perhaps to test a .exclude rule)

    webdeploy --dry-run

=head1 LIMITATIONS

WebDeploy currently doesn't support SFTP (FTP via SSH)

WebDeploy can only be used for uploading content in the current directory. It is not possible to upload content from a different directory without first changing to that directory.

=head1 AUTHOR

WebDeploy was written by Daniel Bailey

Contact: info-d@nielbailey.com

=head1 REPORTING BUGS

Please report bugs via email directly to Daniel Bailey using the email address: webdeploy-bug-d@nielbailey.com

=head1 COPYRIGHT AND LICENSE

Copyright 2015 Daniel Bailey

License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.

This is free software: you are free to change and redistribute it.

There is NO WARRANTY, to the extent permitted by law.

=cut
