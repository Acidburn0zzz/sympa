#!--PERL--

# archived.pl - This script does the web archives building for Sympa
# RCS Identication ; $Revision$ ; $Date$ 
#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

## Options :  F         -> do not detach TTY
##         :  d		-> debug -d is equiv to -dF
## Now, it is impossible to use -dF but you have to write it -d -F

## Change this to point to your Sympa bin directory
use lib '--LIBDIR--';

use List;
use Conf;
use Log;
#use Getopt::Std;
use Getopt::Long;

use wwslib;

#getopts('dF');

## Check options
my %options;
&GetOptions(\%main::options, 'debug|d', 'foreground|F');
$main::options{'debug2'} = 1 if ($main::options{'debug'});

$Version = '0.1';

$wwsympa_conf = "--WWSCONFIG--";
$sympa_conf_file = '--CONFIG--';

$wwsconf = {};
$adrlist = {};

# Load WWSympa configuration
unless ($wwsconf = &wwslib::load_config($wwsympa_conf)) {
    print STDERR 'unable to load config file';
    exit;
}

# Load sympa.conf
unless (Conf::load($sympa_conf_file)) {
    do_log  ('notice',"Unable to load sympa configuration, file $sympa_conf_file has errors.");
   exit(1);
}

## Check databse connectivity
$List::use_db = &List::probe_db();

## Put ourselves in background if not in debug mode. 
unless ($main::options{'debug'} || $main::options{'foreground'}) {
   open(STDERR, ">> /dev/null");
   open(STDOUT, ">> /dev/null");
   if (open(TTY, "/dev/tty")) {
      ioctl(TTY, $TIOCNOTTY, 0);
      close(TTY);
   }
   setpgrp(0, 0);
   if ((my $child_pid = fork) != 0) {
      do_log('debug', "Starting archive daemon, pid $_");

      exit(0);
   }
}

## Create and write the pidfile
&tools::write_pid($wwsconf->{'archived_pidfile'}, $$);

$wwsconf->{'log_facility'}||= $Conf{'syslog'};
do_openlog($wwsconf->{'log_facility'}, $Conf{'log_socket_type'}, 'archived');

## Set the UserID & GroupID for the process
$( = $) = (getpwnam('--GROUP--'))[2];
$< = $> = (getpwnam('--USER--'))[2];


## Sets the UMASK
umask($Conf{'umask'});

## Change to list root
unless (chdir($Conf{'home'})) {
    &message('chdir_error');
    &do_log('info','unable to change directory');
    exit (-1);
}

my $pinfo = &List::_apply_defaults();

do_log('notice', "archived $Version Started");


## Catch SIGTERM, in order to exit cleanly, whenever possible.
$SIG{'TERM'} = 'sigterm';
$end = 0;


$queue = $Conf{'queueoutgoing'};
print "queue : $queue\n";

#if (!chdir($queue)) {
#   fatal_err("Can't chdir to %s: %m", $queue);
#   ## Function never returns.
#}

## infinite loop scanning the queue (unless a sig TERM is received
while (!$end) {

    &List::init_list_cache();
    
   unless (opendir(DIR, $queue)) {
       fatal_err("Can't open dir %s: %m", $queue); ## No return.
   }

   my @files =  (sort grep(!/^\.{1,2}$/, readdir DIR ));
   closedir DIR;

   ## this sleep is important to be raisonably sure that sympa is not currently
   ## writting the file this deamon is openning. 
   sleep 6;

   foreach my $file (@files) {

       last if $end;

       if ($file  =~ /^\.remove\.(.*)\.\d+$/ ) {
	   do_log('debug',"remove found : $file for list $1");

	   unless (open REMOVE, "$queue/$file") {
	        do_log ('notice',"Ignoring file $queue/$file because couldn't read it, archived.pl must use the same uid as sympa");
		   next;
	       }
	   my $msgid = <REMOVE> ;
	   close REMOVE;
	   &remove($1,$msgid);
	   unless (unlink("$queue/$file")) {
	       do_log ('notice',"Ignoring file $queue/$file because couldn't remove it, archived.pl must use the same uid as sympa");
	       next;
	   }
	   
       }elsif ($file  =~ /^\.rebuild\.(.*)$/ ) {
	   do_log('debug',"rebuild found : $file for list $1");
	   &rebuild($1);	
	   unless (unlink("$queue/$file")) {
	       do_log ('notice',"Ignoring file $queue/$file because couldn't remove it, archived.pl must use the same uid as sympa");
	       next;
	   }
       }else{
	   my ($yyyy, $mm, $dd, $min, $ss, $adrlist);
	   
	   if ($file =~ /^(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(.*)$/) {
	       ($yyyy, $mm, $dd, $hh, $min, $ss, $adrlist) = ($1, $2, $3, $4, $5, $6, $7);
	   }elsif ($file =~ /^(.*)\.(\d+)\.(\d+)$/) {
	       $adrlist = $1;
	       my $date = $2;

	       my @now = localtime($date);
	       $yyyy = sprintf '%04d', 1900+$now[5];
	       $mm = sprintf '%02d', $now[4]+1;
	       $dd = sprintf '%02d', $now[3];
	       $hh = sprintf '%02d', $now[2];
	       $min = sprintf '%02d', $now[1];
	       $ss = sprintf '%02d', $now[0];
	       
	   }else {
	       do_log ('notice',"Ignoring file $queue/$file because not to be rebuild or liste archive");
               unlink("$queue/$file");
	       next;
	   }
	   
	   $adrlist =~ /^(.*)\@(.*)$/;
	   my $listname = $1;
	   my $hostname = $2;

	   do_log('debug',"Archiving $file for list $adrlist");      
	   mail2arc ($file, $listname, $hostname, $yyyy, $mm, $dd, $hh, $min, $ss);
	   unless (unlink("$queue/$file")) {
	       do_log ('notice',"Ignoring file $queue/$file because couldn't remove it, archived.pl must use the same uid as sympa");
	       do_log ('notice',"exiting because I don't want to loop until file system is full");
	       last;
	   }
       }
   }
}
do_log('notice', 'archived exited normally due to signal');
unlink("$wwsconf->{'archived_pidfile'}");

exit(0);


## When we catch SIGTERM, just change the value of the loop
## variable.
sub sigterm {
    $end = 1;
}

sub remove {
    my $adrlist = shift;
    my $msgid = shift;

    my $arc ;

    if ($adrlist =~ /^(.*)\.(\d{4}-\d{2})$/) {
	$adrlist = $1;
        $arc = $2;
    }

    do_log('debug',"Removing $msgid in list $adrlist section $2");
  
    $arc =~ /^(\d{4})-(\d{2})$/ ;
    my $yyyy = $1 ;
    my $mm = $2 ;
    
    $msgid =~ s/\$/\\\$/g;
    system "$wwsconf->{'mhonarc'}  -outdir $wwsconf->{'arc_path'}/$adrlist/$yyyy-$mm -rmm $msgid";

}

sub rebuild {

    my $adrlist = shift;
    my $arc ;

    if ($adrlist =~ /^(.*)\.(\d{4}-\d{2})$/) {
	$adrlist = $1;
        $arc = $2;
    }

    $adrlist =~ /^(.*)\@(.*)$/;
    my $listname = $1;
    my $hostname = $2;

    do_log('debug',"Rebuilding $adrlist archive ($2)");

    my $mhonarc_ressources = &get_ressources ($adrlist) ; 

    if ($arc) {
        do_log('debug',"Rebuilding  $arc of $adrlist archive");
	$arc =~ /^(\d{4})-(\d{2})$/ ;
	my $yyyy = $1 ;
	my $mm = $2 ;

	my $cmd = "$wwsconf->{'mhonarc'} -rcfile $mhonarc_ressources -outdir $wwsconf->{'arc_path'}/$adrlist/$yyyy-$mm  -definevars \"listname='$listname' hostname=$hostname yyyy=$yyyy mois=$mm yyyymm=$yyyy-$mm wdir=$wwsconf->{'arc_path'} base=$Conf{'wwsympa_url'}/arc \" -umask $Conf{'umask'} $wwsconf->{'arc_path'}/$adrlist/$arc/arctxt";

	my $exitcode = system($cmd);
	if ($exitcode) {
	    do_log('debug',"Command $cmd failed with exit code $exitcode");
	}
    }else{
        do_log('debug',"Rebuilding $adrlist archive completely");

	if (!opendir(DIR, "$wwsconf->{'arc_path'}/$adrlist" )) {
	    do_log('notice',"unable to open $wwsconf->{'arc_path'}/$adrlist to rebuild archive");
	    return ;
	}
	my @archives = (grep (/^\d{4}-\d{2}/, readdir(DIR)));
	close DIR ; 

	foreach my $arc (@archives) {
	    $arc =~ /^(\d{4})-(\d{2})$/ ;
	    my $yyyy = $1 ;
	    my $mm = $2 ;
	    
	    system "$wwsconf->{'mhonarc'}  -rcfile $mhonarc_ressources -outdir $wwsconf->{'arc_path'}/$adrlist/$yyyy-$mm  -definevars \"listname=$listname hostname=$hostname yyyy=$yyyy mois=$mm yyyymm=$yyyy-$mm wdir=$wwsconf->{'arc_path'} base=$Conf{'wwsympa_url'}/arc \" -umask $Conf{'umask'} $wwsconf->{'arc_path'}/$adrlist/$arc/arctxt";
	}
    }
}


sub mail2arc {

    my ($file, $listname, $hostname, $yyyy, $mm, $dd, $hh, $min, $ss) = @_;
    my $arcpath = $wwsconf->{'arc_path'};
    
    do_log('debug',"mail2arc $file for $listname\@$hostname yyyy:$yyyy, mm:$mm dd:$dd hh:$hh min$min ss:$ss");
    #    chdir($wwsconf->{'arc_path'});
    
    if (! -d "$arcpath/$listname\@$hostname") {
	unless (mkdir ("$arcpath/$listname\@$hostname", 0775)) {
	    &do_log('notice', 'Cannot create directory %s', "$arcpath/$listname\@$hostname");
	    return undef;
	}
	do_log('debug',"mkdir $arcpath/$listname\@$hostname");
    }
    if (! -d "$arcpath/$listname\@$hostname/$yyyy-$mm") {
	unless (mkdir ("$arcpath/$listname\@$hostname/$yyyy-$mm", 0775)) {
	    &do_log('notice', 'Cannot create directory %s', "$arcpath/$listname\@$hostname/$yyyy-$mm");
	    return undef;
	}
	do_log('debug',"mkdir $arcpath/$listname\@$hostname/$yyyy-$mm");
    }
    if (! -d "$arcpath/$listname\@$hostname/$yyyy-$mm/arctxt") {
	unless (mkdir ("$arcpath/$listname\@$hostname/$yyyy-$mm/arctxt", 0775)) {
	    &do_log('notice', 'Cannot create directory %s', "$arcpath/$listname\@$hostname/$yyyy-$mm/arctxt");
	    return undef;
	}
	do_log('debug',"mkdir $arcpath/$listname\@$hostname/$yyyy-$mm/arctxt");
    }
    
    ## copy the file in the arctxt and in "mhonarc -add"
    opendir (DIR, "$arcpath/$listname\@$hostname/$yyyy-$mm/arctxt");
    my @files = (sort { $a <=> $b;}  readdir(DIR)) ;
    $files[$#files]+=1;
    my $newfile = $files[$#files];
#    my $newfile = $files[$#files]+=1;
    
    my $mhonarc_ressources = &get_ressources ($listname . '@' . $hostname) ; 
    
    do_log ('debug',"calling $wwsconf->{'mhonarc'} for list $listname\@$hostname" ) ;
    my $cmd = "$wwsconf->{'mhonarc'} -add -rcfile $mhonarc_ressources -outdir $arcpath/$listname\@$hostname/$yyyy-$mm  -definevars \"listname='$listname' hostname=$hostname yyyy=$yyyy mois=$mm yyyymm=$yyyy-$mm wdir=$wwsconf->{'arc_path'} base=$Conf{'wwsympa_url'}/arc \" -umask $Conf{'umask'} < $queue/$file";
    
    my $exitcode = system($cmd);
    if ($exitcode) {
           do_log('debug',"Command $cmd failed with exit code $exitcode");
    }

    
    open (ORIG, "$queue/$file") || fatal_err("couldn't open file $queue/$file");
    open (DEST, ">$arcpath/$listname\@$hostname/$yyyy-$mm/arctxt/$newfile") || fatal_err("couldn't open file $newfile");
    while (<ORIG>) {
        print DEST $_ ;
    }
    
    close ORIG;  
    close DEST;
}

sub get_ressources {
    my $adrlist = shift;
    my ($mhonarc_ressources, $list);  

    if ($adrlist =~ /^([^@]*)\@[^@]*$/) {
	$adrlist = $1;
    }
    unless ($list = new List ($adrlist)) {
	do_log('notice',"get_ressources : unable to load list $1, continue anyway");
    }  
    
    #$mhonarc_ressources = &tools::get_filename('etc', 'mhonarc-ressources', $robot, $list);
    if (-r "$list->{'dir'}/mhonarc-ressources") {
	$mhonarc_ressources =  "$list->{'dir'}/mhonarc-ressources" ;
    }elsif (-r "$Conf{'etc'}/mhonarc-ressources"){
        $mhonarc_ressources =  "$Conf{'etc'}/mhonarc-ressources" ;
    }elsif (-r "--ETCBINDIR--/mhonarc-ressources"){
        $mhonarc_ressources =  "--ETCBINDIR--/mhonarc-ressources" ;
    }else {
	do_log('notice',"Cannot find any MhOnArc ressource file");
	return undef;
    }
    return  $mhonarc_ressources;
}





