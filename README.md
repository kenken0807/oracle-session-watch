# oracle-session-watch
#summary
oracle database SE and SEone are not able to use Oracle ASH.

it takes the place of Oracle ASH.

To keep Active Session Information at regular intervals from v$session to Mysql .

#install mysql
<pre>
yum -y install mysql-server
/etc/init.d/mysqld start
create database oracle_session;
UPDATE mysql.user SET Password= PASSWORD('mysqlpassword') WHERE User= 'root';
FLUSH PRIVILEGES;
</pre>

#install and configuration
#install
<pre>
cpanm DBD::Oracle
cpanm DBD::mysql
cpanm YAML::Tiny
</pre>
##configuration oracle connection information
oracleconf.yaml is possible to specify multiple Oracle databases

vim oracleconf.yaml
<pre>
#Identification name:
#       host:oracle hostname
#       port:port
#       db_name:sid
#       db_user:user name that has select v$session
#       db_pass:password
#       mysqltable:mysql table name if there is not table,the script creates  a new table
</pre>
sample
<pre>
test:
        host: localhost
        port: 1521
        db_name: orcl
        db_user: system
        db_pass: orcl
        mysqltable: test_sess
</pre>

#option
<pre>
[OPTIONS]
--user         Mysql USERNAME[default root]
--password     Mysql PASSWORD[default none]
--db           Mysql DATABASE NAME[default none]
--host         Mysql HOSTNAME[default localhost]
--port         Mysql PORT[default 3306]
--socket       Mysql Socket[default /var/lib/mysql/mysql.sock]
--check        DRY-RUN[default no]
--deletedays   DELETE RETENSION POLICY(day). Execute delete once a day[default 90(days)]
--execinterval Interval to Get Active Session Information from v$session(Seconds)[default 30]
</pre>

#dry-run
<pre>
perl oracle-session-watch.pl --password mysqlpassword --db oracle_session --check
Connect OK(MYSQL) HOST:localhost DBNAME:oracle_session
Connect OK(ORACLE) HOST:localhost SID:orcl
</pre>

#exectute
it will creates table(test_sess).
<pre>
perl oracle-session-watch.pl --password mysqlpassword --db oracle_session &
</pre>

#check
<pre>
mysql -p'mysqlpassword' -e"use oracle_session;show tables;"
+--------------------------+
| Tables_in_oracle_session |
+--------------------------+
| test_sess                |
+--------------------------+
</pre>

#stop
<pre>
ps aux | grep oracle-session-watch.pl
root     22208  0.0  0.1 298260 24056 ?        S    17:41   0:00 perl oracle-session-watch.pl --password mysqlpassword --db oracle_session
kill 22208
</pre>

#querysample
The display of the sum of active session for 10 minutes in the last 7 days  with ORAUSER which is username 
<pre>
 mysql -p'mysqlpassword' -e"use oracle_session;select substr(snapshot_date,1,15),count(*) from test_sess where username='ORAUSER' and snapshot_date >  DATE_SUB( now(), interval 7 day ) group by 1 order by 2 desc limit 30;
 
+----------------------------+----------+
| substr(snapshot_date,1,15) | count(*) |
+----------------------------+----------+
| 2015-07-11 17:3            |     2299 |
| 2015-07-11 17:2            |      422 |
| 2015-07-12 23:5            |      275 |
| 2015-07-09 23:5            |      163 |
| 2015-07-08 23:5            |      148 |
| 2015-07-11 02:0            |      113 |
+----------------------------+----------+
</pre>

To display WaitEvents and Counts in 10 mins
<pre>
mysql -p'mysqlpassword' -e"use oracle_session;select snapshot_date,wait_class,event ,count(*) from test_sess where username='ORAUSER' and snapshot_date between '2015-07-11 17:20:00' and '2015-07-11 17:30:00' group by 1,2,3;"

+---------------------+-------------+-------------------------------+----------+
| snapshot_date       | wait_class  | event                         | count(*) |
+---------------------+-------------+-------------------------------+----------+
| 2015-07-11 17:28:38 | Application | enq: TX - row lock contention |       58 |
| 2015-07-11 17:28:38 | Commit      | log file sync                 |        1 |
| 2015-07-11 17:28:38 | Idle        | SQL*Net message from client   |        1 |
| 2015-07-11 17:28:38 | Network     | SQL*Net message to client     |        2 |
| 2015-07-11 17:29:09 | Application | enq: TX - row lock contention |      116 |
| 2015-07-11 17:29:09 | Network     | SQL*Net message to client     |        3 |
| 2015-07-11 17:29:39 | Application | enq: TX - row lock contention |      194 |
+---------------------+-------------+-------------------------------+----------+
</pre>
