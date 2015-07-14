#!/usr/local/bin/perl
use strict;
use utf8;
use DBI;    
use Data::Dumper;
use YAML::Tiny;
use Getopt::Long;
use Sys::Hostname;

#options
my ($PW,$DBNM);
my $CHK=0;
my $PORT=3306;
my $HOST="localhost";
my $USER="root";
my $DELDAY=90;
my $INTERVAL=30;
my $SOCK="/var/lib/mysql/mysql.sock";
GetOptions('user=s' =>\$USER,'password=s'=> \$PW,'host=s'=>\$HOST,'check'=>\$CHK,'port=s'=>\$PORT,
	   'db=s'=>\$DBNM,'deletedays=s'=>\$DELDAY,'--execinterval=s'=>\$INTERVAL,'socket=s'=>\$SOCK);

if( !$PW | !$DBNM)
{
	print "[OPTIONS]\n";
	print "--user         Mysql USERNAME[default root]\n";
	print "--password     Mysql PASSWORD[default none]\n";
	print "--db           Mysql DATABASE NAME[default none]\n";
	print "--host         Mysql HOSTNAME[default localhost]\n";
	print "--port         Mysql PORT[default 3306]\n";
	print "--socket       Mysql Socket[default /var/lib/mysql/mysql.sock]\n";
	print "--check        DRY-RUN[default no]\n";
	print "--deletedays   DELETE RETENSION POLICY(day). Execute delete once a day[default 90(days)]\n";
	print "--execinterval Interval to Get Active Session Information from v\$session(Seconds)[default 30]\n";
	exit;
}

#mysql connect info
my $MY_DB_CONF =
    {host=> $HOST,
     port=> $PORT,
     db_name=>  $DBNM,
     db_user=>  $USER,
     db_pass=>  $PW,
     sock=> $SOCK,
    };
#read config
my $CONF=YAML::Tiny->new;
$CONF=YAML::Tiny->read('oracleconf.yaml');
my $yaml=$CONF->[0];
my $HOSTNAME=hostname(); 
my $MYDBH;
my $ORACON;
#query v$session
my $SESSION_SQL=<<EOF;
            SELECT sysdate AS SNAPSHOT_DATE ,ses.* FROM v\$session ses 
			WHERE STATUS = 'ACTIVE'  AND MACHINE<>'$HOSTNAME'
EOF
my $DELCNT=0; #counter for  delete
my $DELEXECCNT=int(86400/$INTERVAL); #delete timing(24*60*$INTERVAL)

#main
pre();
exit if($CHK);
eval{
	CheckTable();
	loop();
};
#error
if($@){
	exit;
}


#connect processing. exec once time
sub pre {
	#mysql
	$MYDBH = My_connect_db();
	print "Connect OK(MYSQL) HOST:$HOST DBNAME:$DBNM\n" if($CHK);
	#oracle
	foreach my $univalue(keys(%$yaml))
	{
		my $oradbh=Ora_connect_db($yaml->{$univalue}->{host}
					 ,$yaml->{$univalue}->{port}
					 ,$yaml->{$univalue}->{db_name}
					 ,$yaml->{$univalue}->{db_user}
					 ,$yaml->{$univalue}->{db_pass});
		$ORACON->{$univalue}=$oradbh;
		print "Connect OK(ORACLE) HOST:$yaml->{$univalue}->{host} SID:$yaml->{$univalue}->{db_name}\n" if($CHK);
	}
}
#create table at mysql. exec once time
sub CheckTable {
	#exists table
	foreach my $univalue(keys(%$yaml))
	{
		my $nm_mytbl=$yaml->{$univalue}->{mysqltable};
		my $sql=<<EOS;
		SHOW TABLES LIKE '$nm_mytbl'
EOS
		my $sth=$MYDBH->prepare($sql);
		my $tbl=$sth->execute ();
		$sth->finish;
		if($tbl eq '0E0')
		{
			print "EXECUTE CREATE TABLE $nm_mytbl\n";
			my $crttbl=&CreateTableMysql($nm_mytbl);
			$MYDBH->do($crttbl) || die DBI->errstr."$!";
			#create index for delete
			$MYDBH->do("alter table $nm_mytbl add index IDX_SNAPSHOTDATE(SNAPSHOT_DATE)") || die DBI->errstr."$!";
		}else{
			print "EXISTS $nm_mytbl\n";
		}
	}
}

#loop function
sub loop {
	#Infinite loop
	while(1)
	{
		#loop for each oracle connections
		foreach my $univalue(keys(%$ORACON))
		{
    			my $sth = $ORACON->{$univalue}->prepare_cached($SESSION_SQL) || die DBI->errstr."$!";
    			$sth->execute || die DBI->errstr."$!";
			#insert into mysql table 
    			while( my $row = $sth->fetchrow_hashref)
    			{
	    			my $mysql=&StatementInsert($yaml->{$univalue}->{mysqltable},$row);
				my $mysth=$MYDBH->do($mysql) || die DBI->errstr."$!";
    			}
			$sth->finish;
			#DELETE
			if($DELCNT%$DELEXECCNT==0)
			{
				$MYDBH->do("DELETE FROM $yaml->{$univalue}->{mysqltable} WHERE SNAPSHOT_DATE < (now() - INTERVAL $DELDAY DAY)" ) || die DBI->errstr."$!";
			}
		}
		#sleep
		sleep $INTERVAL;
		$DELCNT=0 if($DELCNT==$DELEXECCNT);
		$DELCNT++;
	}
}

#oracle connect function
sub Ora_connect_db {
    my $db = join(';',"dbi:Oracle:host=$_[0]","port=$_[1]","sid=$_[2]");
    my $db_uid_passwd = "$_[3]/$_[4]";
    my $ORADBH = DBI->connect($db, $db_uid_passwd, "") or die DBI->errstr;
    return $ORADBH;
}
#mysql connect function
sub My_connect_db {
	my $db="DBI:mysql:$MY_DB_CONF->{db_name};$MY_DB_CONF->{host};$MY_DB_CONF->{port};mysql_socket=$MY_DB_CONF->{sock}";
	my $MYDBH=DBI->connect($db,$MY_DB_CONF->{db_user},$MY_DB_CONF->{db_pass}) or die DBI->errstr;
	return $MYDBH;
}
#create insert statement for mysql
sub StatementInsert {
	my $table=$_[0];
	my $row=$_[1];
    my $statement=<<EOF1;
    INSERT INTO $table VALUES(
    ''
	,'$row->{SNAPSHOT_DATE}'
	,'$row->{SADDR}'
	,'$row->{SID}'
	,'$row->{'SERIAL#'}'
	,'$row->{AUDSID}'
	,'$row->{PADDR}'
	,'$row->{'USER#'}'
	,'$row->{USERNAME}'
	,'$row->{COMMAND}'
	,'$row->{OWNERID}'
	,'$row->{TADDR}'
	,'$row->{LOCKWAIT}'
	,'$row->{STATUS}'
	,'$row->{SERVER}'
	,'$row->{'SCHEMA#'}'
	,'$row->{SCHEMANAME}'
	,'$row->{OSUSER}'
	,'$row->{PROCESS}'
	,'$row->{MACHINE}'
	,'$row->{PORT}'
	,'$row->{TERMINAL}'
	,'$row->{PROGRAM}'
	,'$row->{TYPE}'
	,'$row->{SQL_ADDRESS}'
	,'$row->{SQL_HASH_VALUE}'
	,'$row->{SQL_ID}'
	,'$row->{SQL_CHILD_NUMBER}'
	,'$row->{SQL_EXEC_START}'
	,'$row->{SQL_EXEC_ID}'
	,'$row->{PREV_SQL_ADDR}'
	,'$row->{PREV_HASH_VALUE}'
	,'$row->{PREV_SQL_ID}'
	,'$row->{PREV_CHILD_NUMBER}'
	,'$row->{PREV_EXEC_START}'
	,'$row->{PREV_EXEC_ID}'
	,'$row->{PLSQL_ENTRY_OBJECT_ID}'
	,'$row->{PLSQL_ENTRY_SUBPROGRAM_ID}'
	,'$row->{PLSQL_OBJECT_ID}'
	,'$row->{PLSQL_SUBPROGRAM_ID}'
	,'$row->{MODULE}'
	,'$row->{MODULE_HASH}'
	,'$row->{ACTION}'
	,'$row->{ACTION_HASH}'
	,'$row->{CLIENT_INFO}'
	,'$row->{FIXED_TABLE_SEQUENCE}'
	,'$row->{'ROW_WAIT_OBJ#'}'
	,'$row->{'ROW_WAIT_FILE#'}'
	,'$row->{'ROW_WAIT_BLOCK#'}'
	,'$row->{'ROW_WAIT_ROW#'}'
	,'$row->{'TOP_LEVEL_CALL#'}'
	,'$row->{LOGON_TIME}'
	,'$row->{LAST_CALL_ET}'
	,'$row->{PDML_ENABLED}'
	,'$row->{FAILOVER_TYPE}'
	,'$row->{FAILOVER_METHOD}'
	,'$row->{FAILED_OVER}'
	,'$row->{RESOURCE_CONSUMER_GROUP}'
	,'$row->{PDML_STATUS}'
	,'$row->{PDDL_STATUS}'
	,'$row->{PQ_STATUS}'
	,'$row->{CURRENT_QUEUE_DURATION}'
	,'$row->{CLIENT_IDENTIFIER}'
	,'$row->{BLOCKING_SESSION_STATUS}'
	,'$row->{BLOCKING_INSTANCE}'
	,'$row->{BLOCKING_SESSION}'
	,'$row->{FINAL_BLOCKING_SESSION_STATUS}'
	,'$row->{FINAL_BLOCKING_INSTANCE}'
	,'$row->{FINAL_BLOCKING_SESSION}'
	,'$row->{'SEQ#'}'
	,'$row->{'EVENT#'}'
	,'$row->{EVENT}'
	,'$row->{P1TEXT}'
	,'$row->{P1}'
	,'$row->{P1RAW}'
	,'$row->{P2TEXT}'
	,'$row->{P2}'
	,'$row->{P2RAW}'
	,'$row->{P3TEXT}'
	,'$row->{P3}'
	,'$row->{P3RAW}'
	,'$row->{WAIT_CLASS_ID}'
	,'$row->{'WAIT_CLASS#'}'
	,'$row->{WAIT_CLASS}'
	,'$row->{WAIT_TIME}'
	,'$row->{SECONDS_IN_WAIT}'
	,'$row->{STATE}'
	,'$row->{WAIT_TIME_MICRO}'
	,'$row->{TIME_REMAINING_MICRO}'
	,'$row->{TIME_SINCE_LAST_WAIT_MICRO}'
	,'$row->{SERVICE_NAME}'
	,'$row->{SQL_TRACE}'
	,'$row->{SQL_TRACE_WAITS}'
	,'$row->{SQL_TRACE_BINDS}'
	,'$row->{SQL_TRACE_PLAN_STATS}'
	,'$row->{SESSION_EDITION_ID}'
	,'$row->{CREATOR_ADDR}'
	,'$row->{'CREATOR_SERIAL#'}'
	,'$row->{ECID}'
	)
EOF1
    return $statement;
}
#create table for mysql
sub CreateTableMysql {
	my $statement=<<EOF2;
create table $_[0](
     SNAPSHOT_ID                                        BIGINT NOT NULL AUTO_INCREMENT KEY
    ,SNAPSHOT_DATE                                      DATETIME NOT NULL
    ,SADDR                                              VARCHAR(16)
    ,SID                                                INT
    ,SERIAL_NO                                          INT
    ,AUDSID                                             INT
    ,PADDR                                              VARCHAR(16)
    ,USER_NO                                            INT
    ,USERNAME                                           VARCHAR(30)
    ,COMMAND                                            INT
    ,OWNERID                                            INT
    ,TADDR                                              VARCHAR(16)
    ,LOCKWAIT                                           VARCHAR(16)
    ,STATUS                                             VARCHAR(8)
    ,SERVER                                             VARCHAR(9)
    ,SCHEMA_NO                                          INT
    ,SCHEMANAME                                         VARCHAR(30)
    ,OSUSER                                             VARCHAR(30)
    ,PROCESS                                            VARCHAR(24)
    ,MACHINE                                            VARCHAR(64)
    ,PORT                                               INT
    ,TERMINAL                                           VARCHAR(30)
    ,PROGRAM                                            VARCHAR(48)
    ,TYPE                                               VARCHAR(10)
    ,SQL_ADDRESS                                        VARCHAR(16)
    ,SQL_HASH_VALUE                                     INT
    ,SQL_ID                                             VARCHAR(13)
    ,SQL_CHILD_INT                                      INT
    ,SQL_EXEC_START                                     DATETIME
    ,SQL_EXEC_ID                                        INT
    ,PREV_SQL_ADDR                                      VARCHAR(16)
    ,PREV_HASH_VALUE                                    INT
    ,PREV_SQL_ID                                        VARCHAR(13)
    ,PREV_CHILD_INT                                     INT
    ,PREV_EXEC_START                                    DATETIME
    ,PREV_EXEC_ID                                       INT
    ,PLSQL_ENTRY_OBJECT_ID                              INT
    ,PLSQL_ENTRY_SUBPROGRAM_ID                          INT
    ,PLSQL_OBJECT_ID                                    INT
    ,PLSQL_SUBPROGRAM_ID                                INT
    ,MODULE                                             VARCHAR(64)
    ,MODULE_HASH                                        INT
    ,ACTION                                             VARCHAR(64)
    ,ACTION_HASH                                        INT
    ,CLIENT_INFO                                        VARCHAR(64)
    ,FIXED_TABLE_SEQUENCE                               INT
    ,ROW_WAIT_OBJ_NO                                    INT
    ,ROW_WAIT_FILE_NO                                   INT
    ,ROW_WAIT_BLOCK_NO                                  INT
    ,ROW_WAIT_ROW_NO                                    INT
    ,TOP_LEVEL_CALL_NO                                  INT
    ,LOGON_TIME                                         DATETIME
    ,LAST_CALL_ET                                       INT
    ,PDML_ENABLED                                       VARCHAR(3)
    ,FAILOVER_TYPE                                      VARCHAR(13)
    ,FAILOVER_METHOD                                    VARCHAR(10)
    ,FAILED_OVER                                        VARCHAR(3)
    ,RESOURCE_CONSUMER_GROUP                            VARCHAR(32)
    ,PDML_STATUS                                        VARCHAR(8)
    ,PDDL_STATUS                                        VARCHAR(8)
    ,PQ_STATUS                                          VARCHAR(8)
    ,CURRENT_QUEUE_DURATION                             INT
    ,CLIENT_IDENTIFIER                                  VARCHAR(64)
    ,BLOCKING_SESSION_STATUS                            VARCHAR(11)
    ,BLOCKING_INSTANCE                                  INT
    ,BLOCKING_SESSION                                   INT
    ,FINAL_BLOCKING_SESSION_STATUS                      VARCHAR(11)
    ,FINAL_BLOCKING_INSTANCE                            INT
    ,FINAL_BLOCKING_SESSION                             INT
    ,SEQ_NO                                             INT
    ,EVENT_NO                                           INT
    ,EVENT                                              VARCHAR(64)
    ,P1TEXT                                             VARCHAR(64)
    ,P1                                                 INT
    ,P1RAW                                              VARCHAR(16)
    ,P2TEXT                                             VARCHAR(64)
    ,P2                                                 INT
    ,P2RAW                                              VARCHAR(16)
    ,P3TEXT                                             VARCHAR(64)
    ,P3                                                 INT
    ,P3RAW                                              VARCHAR(16)
    ,WAIT_CLASS_ID                                      INT
    ,WAIT_CLASS_NO                                      INT
    ,WAIT_CLASS                                         VARCHAR(64)
    ,WAIT_TIME                                          INT
    ,SECONDS_IN_WAIT                                    INT
    ,STATE                                              VARCHAR(19)
    ,WAIT_TIME_MICRO                                    INT
    ,TIME_REMAINING_MICRO                               INT
    ,TIME_SINCE_LAST_WAIT_MICRO                         INT
    ,SERVICE_NAME                                       VARCHAR(64)
    ,SQL_TRACE                                          VARCHAR(8)
    ,SQL_TRACE_WAITS                                    VARCHAR(5)
    ,SQL_TRACE_BINDS                                    VARCHAR(5)
    ,SQL_TRACE_PLAN_STATS                               VARCHAR(10)
    ,SESSION_EDITION_ID                                 INT
    ,CREATOR_ADDR                                       VARCHAR(16)
    ,CREATOR_SERIAL_NO                                  INT
    ,ECID                                               VARCHAR(64)
	) ENGINE=InnoDB
EOF2
	return $statement;
}
