#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_monitoring::snmpmon;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use IO::File;
use xCAT::Utils;


#print "xCAT_monitoring::snmpmon loaded\n";
1;



#-------------------------------------------------------------------------------
=head1  xCAT_monitoring:snmpmon  
=head2    Package Description
  xCAT monitoring plugin package to handle SNMP monitoring. 

=cut
#-------------------------------------------------------------------------------

#--------------------------------------------------------------------------------
=head3    start
      This function gets called by the monitorctrl module
      when xcatd starts. 
    Arguments:
      None.
    Returns:
      (return code, message)      
=cut
#--------------------------------------------------------------------------------
sub start {
  #print "snmpmon::start called\n";

  $noderef=shift;
  if ($noderef =~ /xCAT_monitoring::snmpmon/) {
    $noderef=shift;
  }

  # do not turn it on on the service node
  #if (xCAT::Utils->isServiceNode()) { return (0, "");}

  # unless we are running on linux, exit.
  #unless($^O eq "linux"){      
  #  exit;
  # }

  # check supported snmp package
  my $cmd;
  my @snmpPkg = `/bin/rpm -qa | grep snmp`;
  my $pkginstalled = grep(/net-snmp/, @snmpPkg);

  if ($pkginstalled) {
    my ($ret, $err)=configSNMP();
    if ($ret != 0) { return ($ret, $err);}
  } else {
    return (1, "net-snmp is not installed")
  }

  #enable bmcs if any
  configBMC(1);

  #enable MMAs if any

  return (0, "started")
}

#--------------------------------------------------------------------------------
=head3    configBMC
      This function configures BMC to setup the snmp destination, enable/disable
    PEF policy table entry number 1. 
    Arguments:
      actioon -- 1 enable PEF policy table. 0 disable PEF policy table.
    Returns:
      (return code, message)      
=cut
#--------------------------------------------------------------------------------
sub configBMC {
  my $action=shift;
  my $isSV=xCAT::Utils->isServiceNode();

  #the ips of this node
  my @hostinfo=xCAT::Utils->determinehostname();
  %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}

  my $passtab = xCAT::Table->new('passwd');
  my $ipmiuser;
  my $ipmipass;
  if ($passtab) {
    ($tmp)=$passtab->getAttribs({'key'=>'ipmi'},'username','password');
    if (defined($tmp)) { 
     $ipmiuser = $tmp->{username};
     $ipmipass = $tmp->{password};
    }
    $passtab->close();
  }

  my $nrtab = xCAT::Table->new('noderes');
  my $table=xCAT::Table->new("ipmi");
  if ($table) {
    my @tmp1=$table->getAllNodeAttribs(['node','bmc','username', 'password']);
    if (defined(@tmp1) && (@tmp1 > 0)) {
      foreach(@tmp1) {
        my $node=$_->{node};
        my $bmc=$_->{bmc};
        #print "node=$node, bmc=$bmc, username=$_->{username}, password=$_->{password}\n";

        my $tent  = $nrtab->getNodeAttribs($node,['servicenode']);
        if ($tent and $tent->{servicenode}) { #the node has service node
          if (!$iphash{$tent->{servicenode}}) { next;} # handle its childen only 
        } else { #the node does not have service node
	  if ($isSV) { next; }
        }
        
        #get the master for node
        my $master=xCAT::Utils->GetMasterNodeName($node); #should we use $bmc?
        #print "master=$master\n";
        
        my $nodeuser=$ipmiuser; if ($_->{username}) { $nodeuser=$_->{username};}
        my $nodepass=$ipmipass; if ($_->{password}) { $nodepass=$_->{password};}
        
	if ($action==1) { #enable
          # set the snmp destination
          # suppose all others like username, password, ip, gateway ip are set during the installation
          my @dip = split /\./, $master;
	  my $cmd="ipmitool -I lan -H $bmc -U $nodeuser -P $nodepass raw 0x0c 0x01 0x01 0x13 0x01 0x00 0x00 $dip[0] $dip[1] $dip[2] $dip[3] 0x00 0x00 0x00 0x00 0x00 0x00";
          #print "cmd=$cmd\n";
	  $result=`$cmd 2>&1`;
          if ($?) { print "Setting snmp destination ip address for node $node: $result\n"; }
          #enable PEF policy
          $cmd="ipmitool -I lan -H $_->{bmc} -U $nodeuser -P $nodepass raw 0x04 0x12 0x09 0x01 0x18 0x11 0x00";
	  $result=`$cmd 2>&1`;
          if ($?) { print "Enabling PEF policy for node $node: $result\n"; }
        } else { #disable 
          #disable PEF policy
	  my $cmd="ipmitool -I lan -H $bmc -U $nodeuser  -P $nodepass raw 0x04 0x12 0x09 0x01 0x10 0x11 0x00";
	  $result=`$cmd 2>&1`;
          if ($result) { print "Disabling PEF policy for node $node: $result\n"; }
        }          
      } #foreach 
    }
    $table->close();
  }
  $nrtab->close();
}


#--------------------------------------------------------------------------------
=head3    configSNMP
      This function puts xcat_traphanlder into the snmptrapd.conf file and
      restarts the snmptrapd with the new configuration.
    Arguments:
      none.
    Returns:
      (return code, message)      
=cut
#--------------------------------------------------------------------------------
sub configSNMP {
  my $cmd;
  # now move /usr/share/snmptrapd.conf to /usr/share/snmptrapd.conf.orig
  # if it exists.
  if (-f "/usr/share/snmp/snmptrapd.conf"){
  
    # if the file exists and has references to xcat_traphandler then
    # there is nothing that needs to be done.
    `/bin/grep  xcat_traphandler /usr/share/snmp/snmptrapd.conf > /dev/null`;

    # if the return code is 1, then there is no xcat_traphandler
    # references and we need to put them in.
    if($? >> 8){     
      # back up the original file.
      `/bin/cp -f /usr/share/snmp/snmptrapd.conf /usr/share/snmp/snmptrapd.conf.orig`;

      # if the file exists and does not have  "authCommunity execute public" then add it.
      open(FILE1, "</usr/share/snmp/snmptrapd.conf");
      open(FILE, ">/usr/share/snmp/snmptrapd.conf.tmp");
      my $found=0;
      while (readline(FILE1)) {
	 if (/\s*authCommunity.*public/) {
	   $found=1;
           if (!/\s*authCommunity\s*.*execute.*public/) {
             s/authCommunity\s*(.*)\s* public/authCommunity $1,execute public/;  #modify it to have execute if found
	   }
	 }
	 print FILE $_;
      }

      if (!$found) {
        print FILE "authCommunity execute public\n"; #add new one if not found
      }
 
      # now add the new traphandle commands:
      print FILE "traphandle default $::XCATROOT/sbin/xcat_traphandler\n";

      close($handle);
      close(FILE);
      `mv -f /usr/share/snmp/snmptrapd.conf.tmp /usr/share/snmp/snmptrapd.conf`;
    }
  }
  else {     # The snmptrapd.conf file does not exists
    # create the file:
    open($handle, ">/usr/share/snmp/snmptrapd.conf");
    print $handle "authCommunity execute public\n";
    print $handle "traphandle default $::XCATROOT/sbin/xcat_traphandler\n";
    close($handle);
  }

  # TODO: put the mib files to /usr/share/snmp/mibs

  # get the PID of the currently running snmptrapd if it is running.
  # then stop it and restart it again so that it reads our new
  # snmptrapd.conf configuration file. Then the process
  chomp(my $pid= `/bin/ps -ef | /bin/grep snmptrapd | /bin/grep -v grep | /bin/awk '{print \$2}'`);
  if($pid){
    `/bin/kill -9 $pid`;
  }
  # start it up again!
  system("/usr/sbin/snmptrapd -m ALL");

  # get the PID of the currently running snmpd if it is running.
  # if it's running then we just leave.  Otherwise, if we don't get A PID, then we
  # assume that it isn't running, and start it up again!
  chomp(my $pid= `/bin/ps -ef | /bin/grep snmpd | /bin/grep -v grep | /bin/awk '{print \$2}'`);
  unless($pid){
    # start it up again!
    system("/usr/sbin/snmpd");         
  }

  return (0, "started");
}


#--------------------------------------------------------------------------------
=head3    stop
      This function gets called by the monitorctrl module when
      xcatd stops.
    Arguments:
       none
    Returns:
       (return code, message)
=cut
#--------------------------------------------------------------------------------
sub stop {
  #print "snmpmon::stop called\n";

  # do not turn it on on the service node
  #if (xCAT::Utils->isServiceNode()) { return (0, "");}

  #disable BMC so that it stop senging alerts (PETs) to this node
  configBMC(0);
 
  if (-f "/usr/share/snmp/snmptrapd.conf.orig"){
    # copy back the old one
    `mv -f /usr/share/snmp/snmptrapd.conf.orig /usr/share/snmp/snmptrapd.conf`;
  } else {
    if (-f "/usr/share/snmp/snmptrapd.conf"){ 

      # if the file exists, delete all entries that have xcat_traphandler
      my $cmd = "grep -v  xcat_traphandler /usr/share/snmp/snmptrapd.conf "; 
      $cmd .= "> /usr/share/snmp/snmptrapd.conf.unconfig ";         
      `$cmd`;     

      # move it back to the snmptrapd.conf file.                     
      `mv -f /usr/share/snmp/snmptrapd.conf.unconfig /usr/share/snmp/snmptrapd.conf`; 
    }
  }

  # now check to see if the daemon is running.  If it is then we need to resart or stop?
  # it with the new snmptrapd.conf file that will not forward events to RMC.
  chomp(my $pid= `/bin/ps -ef | /bin/grep snmptrapd | /bin/grep -v grep | /bin/awk '{print \$2}'`);
  #print "pid=$pid\n";
  if($pid){
    `/bin/kill -9 $pid`;
    # start it up again!
    #system("/usr/sbin/snmptrapd");
  }

  return (0, "stopped");
}




#--------------------------------------------------------------------------------
=head3    supportNodeStatusMon
    This function is called by the monitorctrl module to check
    if SNMP can help monitoring and returning the node status.
    SNMP does not support this function.
    
    Arguments:
        none
    Returns:
         1  
=cut
#--------------------------------------------------------------------------------
sub supportNodeStatusMon {
  return 0;
}



#--------------------------------------------------------------------------------
=head3   startNodeStatusMon
    This function is called by the monitorctrl module to tell
    SNMP to start monitoring the node status and feed them back
    to xCAT. SNMP does not have this support.

    Arguments:
       None.
    Returns:
        (return code, message)

=cut
#--------------------------------------------------------------------------------
sub startNodeStatusMon {
  return (1, "This function is not supported.");
}


#--------------------------------------------------------------------------------
=head3   stopNodeStatusMon
    This function is called by the monitorctrl module to tell
    SNMP to stop feeding the node status info back to xCAT. 
    SNMP does not support this function.

    Arguments:
        none
    Returns:
        (return code, message)
=cut
#--------------------------------------------------------------------------------
sub stopNodeStatusMon {
  return (1, "This function is not supported.");
}


#--------------------------------------------------------------------------------
=head3    addNodes
      This function adds the nodes into the  SNMP domain.
    Arguments:
      nodes --nodes to be added. It is a  hash reference keyed by the monitoring server 
        nodes and each value is a ref to an array of [nodes, nodetype, status] arrays  monitored 
        by the server. So the format is:
          {monserver1=>[['node1', 'osi', 'active'], ['node2', 'switch', 'booting']...], ...} 
      verbose -- verbose mode. 1 for yes, 0 for no.
    Returns:
       none
=cut
#--------------------------------------------------------------------------------
sub addNodes {
    
  return 0;
}

#--------------------------------------------------------------------------------
=head3    removeNodes
      This function removes the nodes from the SNMP domain.
    Arguments:
      nodes --nodes to be removed. It is a hash reference keyed by the monitoring server 
        nodes and each value is a ref to an array of [nodes, nodetype, status] arrays  monitored 
        by the server. So the format is:
        {monserver1=>[['node1', 'osi', 'active'], ['node2', 'switch', 'booting']...], ...} 
      verbose -- verbose mode. 1 for yes, 0 for no.
    Returns:
       none
=cut
#--------------------------------------------------------------------------------
sub removeNodes {

  return 0;
}

#--------------------------------------------------------------------------------
=head3    processSettingChanges
      This function gets called when the setting for this monitoring plugin 
      has been changed in the monsetting table.
    Arguments:
       none.
    Returns:
        0 for successful.
        non-0 for not successful.
=cut
#--------------------------------------------------------------------------------
sub processSettingChanges {
  return 0;
}

#--------------------------------------------------------------------------------
=head3    getDiscription
      This function returns the detailed description of the plugin inluding the
     valid values for its settings in the monsetting tabel. 
     Arguments:
        none
    Returns:
        The description.
=cut
#--------------------------------------------------------------------------------
sub getDescription {
  return 
"  Description:
    snmpmon sets up the snmptrapd on the management server to receive SNMP
    traps for different nodes. It also sets the trap destination for Blade 
    Center Management Module, RSA II, IPMIs that are managed by the xCAT cluster. 
    xCAT has categorized some events into different event priorities (critical, 
    warning and informational) based on the MIBs we know such as MM, RSA II and 
    IPMI. All the unknown events are categorized as 'warning'. By default, 
    the xCAT trap handler will log all events into the syslog and only
    email the critical and the warning events to the mail alias called 'alerts'. 
    You can use the settings to override the default behavior.
    Use command 'startmon snmpmon' to star monitoring and 'stopmon snmpmon' 
    to stop it. 
  Settings:
    ignore:  specifies the events that will be ignored. It's a comma separated 
        pairs of oid=value. For example, 
        BLADESPPALT-MIB::spTrapAppType=4,BLADESPPALT-MIB::spTrapAppType=4.
    email:  specifies the events that will get email notification.
    log:    specifies the events that will get logged.
    runcmd: specifies the events that will be passed to the user defined scripts.
    cmds:   specifies the command names that will be invoked for the events 
            specified in the runcmd row.
    
    Special keywords for specifying events:
      All -- all events.
      None -- none of the events.
      Critical -- all critical events.
      Warning -- all warning events.
      Informational -- all informational events.

    For example, you can have the following setting:
      email  CRITICAL,BLADESPPALT-MIB::pTrapPriority=4
      This means send email for all the critical events and the BladeCenter 
      system events.\n"  
}
