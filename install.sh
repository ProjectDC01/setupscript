#phpIPAM install shell script ver 2.00
NTPSERVER='ntp.nict.jp'
MYSQLROOTPASS='Aa0Bb1.Aa0Bb1'
MYSQLPHPIPAMPASS='Aa0Bb1.Aa0Bb1'
HTTPDSERVERADMIN
HTTPDSERVERNAME

#Step1
dnf upgrade -y

#stop selinux
setenforce 0
sed -i 's/SELINUX=.*/SELINUX=disable/' /etc/selinux/config

#additional repository
dnf -y install epel-release
rpm -ivh http://rpms.remirepo.net/enterprise/remi-release-8.rpm
rpm --import http://rpms.remirepo.net/RPM-GPG-KEY-remi
dnf install -y https://dev.mysql.com/get/mysql80-community-release-el8-4.noarch.rpm
dnf install -y https://pkgs.dyn.su/el8/base/x86_64/raven-release.el8.noarch.rpm

#chrony setup
sed -i "s/pool 2.rocky.pool.ntp.org iburst/pool $NTPSERVER iburst/" /etc/chrony.conf
systemctl enable --now chronyd

#firewall

cp /etc/firewalld/firewalld.conf /etc/firewalld/firewalld.conf.`date +%Y%m%d`

sed -i "s/AllowZoneDrifting=yes/AllowZoneDrifting=no/" /etc/firewalld/firewalld.conf

firewall-cmd --zone=internal --add-port=80/tcp --permanent
firewall-cmd --reload

#LAMP setup
dnf install httpd mysql-server wget zip unzip -y
sed -i "10 s/enabled=0/enabled=1/g" /etc/yum.repos.d/remi.repo
dnf module reset php -y
dnf module enable php:remi-7.4 -y
dnf install -y php php-cli php-common php-gmp php-ldap php-mbstring php-mysqlnd php-pdo \
php-pear php-snmp php-xml php-memcached php-gd

#Mysql setup
dnf install expect -y

cp /etc/my.cnf /etc/my.cnf.bk.`date +%Y%m%d`

sed -i s/"# default-authentication-plugin=mysql_native_password"/"default-authentication-plugin=mysql_native_password"/ /etc/my.cnf

cat << EOF >> /etc/my.cnf
#Additional Setting

character-set-server=utf8
collation-server=utf8_bin

innodb_buffer_pool_size=4G
#innodb_additional_mem_pool_size=20M
innodb_log_buffer_size=64M
innodb_log_file_size=1G
innodb_file_per_table=1

#query_cache_limit=16M
#query_cache_size=512M
#query_cache_type=1

slow_query_log=ON
long_query_time=3
#log-slow-queries=/var/log/slow.log

join_buffer_size=256K
max_allowed_packet=8M
read_buffer_size=1M
read_rnd_buffer_size=2M
sort_buffer_size=4M
max_heap_table_size=16M
tmp_table_size=16M
thread_cache_size=100
EOF

systemctl enable --now mysqld

expect -c '
    set timeout 10;
    spawn mysql_secure_installation;
    expect "Press y|Y for Yes, any other key for No:";
    send "y\n";
    expect "Please enter 0 = LOW, 1 = MEDIUM and 2 = STRONG:";
    send "1\n";
    expect "New password:";
    send "'"$MYSQLROOTPASS"'\n";
    expect "Re-enter new password:";
    send "'"$MYSQLROOTPASS"'\n";
    expect "Do you wish to continue with the password provided?";
    send "y\n";
    expect "Remove anonymous users?";
    send "y\n";
    expect "Disallow root login remotely?";
    send "y\n";
    expect "Remove test database and access to it?";
    send "y\n";
    expect "Reload privilege tables now?";
    send "y\n";
    interact;'

cat << EOF >> auth.tmp
[Client]
user = root
password = $MYSQLROOTPASS
host = localhost
EOF

mysql --defaults-extra-file=auth.tmp -e 'CREATE DATABASE phpipam;'
mysql --defaults-extra-file=auth.tmp -e "CREATE USER phpipam@localhost IDENTIFIED BY '$MYSQLPHPIPAMPASS';"
mysql --defaults-extra-file=auth.tmp -e 'GRANT ALL ON phpipam.* TO phpipam@localhost;'

rm -rf auth.tmp

#httpd setup

cp /etc/httpd/conf/httpd.conf /etc/httpd/conf/httpd.conf.`date +%Y%m%d`

sed -i "s/ServerAdmin root@localhost/ServerAdmin $HTTPDSERVERADMIN/" /etc/httpd/conf/httpd.conf
sed -i "s/#ServerName www.example.com:80/ServerName $HTTPDSERVERNAME/" /etc/httpd/conf/httpd.conf
sed -i "s/Options Indexes FollowSymLinks/Options FollowSymLinks/" /etc/httpd/conf/httpd.conf

cat << EOF >> /etc/httpd/conf/httpd.conf

#Additional setting by startup script
ServerTokens ProductOnly
ServerSignature off
TraceEnable off

Header append X-FRAME-OPTIONS "SAMEORIGIN"
EOF

mv /etc/httpd/conf.d/autoindex.conf /etc/httpd/conf.d/autoindex.conf.old
mv /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/welcome.conf.old
mv /etc/httpd/conf.d/userdir.conf /etc/httpd/conf.d/userdir.conf.old

systemctl enable --now httpd

#php setup

cp /etc/php.ini /etc/php.ini.`date +%Y%m%d`

sed -i "s/expose_php = On/expose_php = Off/" /etc/php.ini
sed -i "s/max_execution_time = 30/max_execution_time = 3600/" /etc/php.ini
sed -i "s/max_input_time = 60/max_input_time = 3600/" /etc/php.ini
sed -i "s/;date.timezone =/date.timezone = Asia\/Tokyo/" /etc/php.ini
sed -i "s/;mbstring.language = Japanese/mbstring.language = Japanese/" /etc/php.ini

#phpipam download

cd /var/www
wget https://jaist.dl.sourceforge.net/project/phpipam/phpipam-1.5.tar
tar -xvf phpipam-1.5.tar phpipam
rm -f phpipam-1.5.tar

sed -i "s/1.5\///" /var/www/phpipam/config.php
sed -i "s/phpipamadmin/$MYSQLPHPIPAMPASS/" /var/www/phpipam/config.php
sed -i "s/phpipam_1.5/phpipam/" /var/www/phpipam/config.php

cat << EOF >> auth.tmp
[Client]
user = root
password = $MYSQLROOTPASS
host = localhost
EOF

mysql --defaults-extra-file=auth.tmp phpipam -e 'source /var/www/phpipam/db/SCHEMA.sql;'

rm -rf auth.tmp

cat << EOF >> /etc/httpd/conf.d/phpipam.conf
<VirtualHost *:80>
    ServerAdmin webmaster@svrop.com
    DocumentRoot "/var/www/phpipam"

    <Directory "/var/www/phpipam">
        Options FollowSymLinks
        AllowOverride all
        Order allow,deny
        Allow from all
    </Directory>

    ErrorLog logs/error_phpipam.log
    CustomLog logs/access_phpipam.log combined
</VirtualHost>
EOF

dnf update -y && reboot
