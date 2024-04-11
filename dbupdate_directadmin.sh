#! /bin/sh

#Script to update MySQL or MariaDB automatically for DirectAdmin servers.
if [[ ! -f "/usr/local/directadmin/directadmin" ]]; then
    echo -e "This is intended to run on DirectAdmin servers."
    kill -9 $$
else
    :
fi

LOG_FILE="/root/dbms_update_log.log"
truncate -s 0 $LOG_FILE
echo -e "\n========================================================================\nStarting Update process, logs will be saved at $LOG_FILE\n========================================================================\n" | tee -a "$LOG_FILE"

AUTH="-uda_admin -p$(grep -oP 'password="\K[^"]+' /usr/local/directadmin/conf/my.cnf)"
OS_VERSION=$(rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides redhat-release) | cut -d "." -f1)
DATE=$(/usr/bin/date +%s)

#Function to execute and print
exe() {
    echo "\$ $@"
    "$@"
}

#Function to Stop the script
stopp() {
    echo -e "\nErrors have been detected. The script is paused, use "Ctrl + z" to have access to the console. Run fg after you check to resume the script."
    pkill -STOP -P $$
}

#Function to detect exit status
exit_status() {
    e_status="$?"
    if [[ "$e_status" == "0" ]]; then
        :
    else
        stopp
    fi
}

#Functions to stop and restart the DBMS
restart_mysql() {
    (systemctl restart mysql.service 2 &>/dev/null && echo -e "MariaDB has been Restarted") || (systemctl stop mariadb 2 &>/dev/null && echo -e "MariaDB has been Restarted") || (systemctl restart mysqld 2 &>/dev/null && echo -e "MariaDB has been Restarted")
}

stop_mysql() {
    (systemctl stop mysql.service 2 &>/dev/null && echo -e "MariaDB has been stopped") || (systemctl stop mysqld 2 &>/dev/null && echo -e "MariaDB has been stopped") || (systemctl stop mariadb 2 &>/dev/null && echo -e "MariaDB has been stopped")
}

sqlm() {
    if [[ ! -f "/etc/my.cnf.$DATE" ]]; then
        echo -e "\nBacking up the configuration file to my.cnf.$DATE:"
        cp -avr /etc/my.cnf /etc/my.cnf.$DATE
    fi
    echo -e "\n- SQL MODE:"
    (grep -Eq 'sql_mode|sql-mode' /etc/my.cnf &&
    echo -e "\e[1;92m[PASS] \e[0;32mSQL mode is set explicitly.\e(B\e[m\n" || 
    (echo -e "Current effective setting is: sql_mode=\"$(mysql $AUTH -NBe 'select @@sql_mode;')\"\e(B\e[m"
    echo -e "Adding it to my.cnf..."
    sql2=$(mysql $AUTH -NBe 'select @@sql_mode;')
    
    #Adding it under "[mysqld] block"
    line_num=$(awk '/^\[mysqld\]$/ {print NR; exit}' "/etc/my.cnf")
    if [[ -n "$line_num" ]]; then
        sed -i "${line_num}a\\sql_mode=$sql2" /etc/my.cnf
    elif [ ! -n "$line_num" ]; then
        echo "[mysqld]" >> /etc/my.cnf 
        echo "sql_mode=$sql2" >> /etc/my.cnf 
    else 
        :
    fi
    sed -i 's/::ffff:127.0.0.1/127.0.0.1/g' /etc/my.cnf
    sed -i "s/NO_AUTO_CREATE_USER,//g" /etc/my.cnf
    restart_mysql  
    echo -e "Confirming: grep -E 'sql_mode|sql-mode' /etc/my.cnf"
    grep -E 'sql_mode|sql-mode' /etc/my.cnf && echo -e "\nGiving a few secs for MYSQL to start\n" && sleep 3))
}

pre_checks() {
    
    echo -e "\n- Checking for corruption:"
    mychecktemp=$(mysqlcheck $AUTH -Asc)
    echo -e "\nmysqlcheck -Asc"
    if [[ -z "$mychecktemp" ]]; then
        echo -e "\nNo output. All good.\n"
    else
        echo $mychecktemp
        mychecktemp2=$(echo $mychecktemp | grep -iE "corrupt|crashe" )
        if [[ ! -z "$mychecktemp2" ]]; then 
            stopp
	    else 
		    echo -e "\nMinor errors/warnings\n" 
	    fi
    fi
 
    echo -e "- Backups:\n"
    mkdir -p /root/dbms_back
    if [[ ! -d "/root/dbms_back/mysqldumps" ]]; then 
	    mkdir /root/dbms_back/mysqldumps
    fi
    echo "The backup dir is /root/dbms_back/mysqldumps"
    cd /root/dbms_back/mysqldumps
    (set -x; pwd)
    echo -e "\n-Dumping databases:"
    exe eval '(echo "SHOW DATABASES;" | mysql $AUTH -Bs | grep -v '^information_schema$' | while read i ; do echo Dumping $i ; mysqldump $AUTH --single-transaction $i | gzip -c > $i.sql.gz ; done)'
    echo
    error='0'
    count=''
    for f in $(/bin/ls *.sql.gz); do
        if [[ ! $(zgrep -E 'Dump completed on [0-9]{4}-([0-9]{2}-?){2}' ${f}) ]]; then
            echo "Possible error: ${f}"
            error=$((error + 1))
        fi
        count=$((count + 1))
    done
    (
        echo "Error count: ${error}"
        echo "Total DB_dumps: ${count}"
        echo "Total DBs: $(mysql $AUTH -NBe 'SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE schema_name NOT IN ("information_schema");')"
    ) | column -t
    if [[ "$error" != 0 ]]; then
        stopp
    fi    
 
    echo -e "\nRsync data dir:\n"
    ddir=$(mysql $AUTH -e "show variables;" |grep datadir| awk {'print $2'})
    bakdir=("/root/dbms_back/mysql.backup.$(date +%s)/")
    stop_mysql
    sleep 1 && echo
    echo "Path to data dir: $ddir"
    echo "rsync -aHl $ddir $bakdir"
    rsync -aHl $ddir $bakdir
    exit_status
    echo -e "Synced\n" 
    echo "Restarting DBMS..."
    restart_mysql
    sleep 3

    echo -e "\n\n###Checking HTTP status of all domains prior the upgrade:\n"
    (for i in $(grep -h '^domain=' /usr/local/directadmin/data/users/*/domains/*.conf | sed 's/domain=//'); do echo $i; done) | while read i; do
        curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i
        echo $i
    done >/root/dbms_back/mysql_pre_upgrade_http_check
    (set -x; grep -E -v '^(0|2)00 ' /root/dbms_back/mysql_pre_upgrade_http_check)
    echo -e "\n- Plesk Upgrade: MariaDB Upgrade"
}

#Post-check (HTTP status)
post_check() {
    sed -i 's/::ffff:127.0.0.1/127.0.0.1/g' /etc/my.cnf
    sleep 2
    restart_mysql
    mysql_upgrade $AUTH

    (for i in $(grep -h '^domain=' /usr/local/directadmin/data/users/*/domains/*.conf | sed 's/domain=//'); do echo $i; done) | while read i; do
        curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i
        echo $i
    done >/root/dbms_back/mysql_post_upgrade_http_check
    echo -e "\n\nPost check:"
    exe eval 'diff /root/dbms_back/mysql_pre_upgrade_http_check /root/dbms_back/mysql_post_upgrade_http_check'
    echo -e "\nAll set.\n"
}

#Version checking 
get_version() {
    db_ver=$(mysql $AUTH -V | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+" | cut -c1-4) 
    echo -e "\nCurrent version is $db_ver\n"
}

#Function to select the version to install
select_version() {
    read answ2; echo -e "\nSelected: $answ2"
    while true; do
        if [[ "${supported_versions[@]}" =~ "$answ2" ]]; then
            break
        else
            echo "Invalid option, choose again."
            read answ2; echo -e "\nSelected: $answ2"
        fi
    done
}

#MariaDB upgrade function
upgrade_mariadb() {

    echo -e "\n\n###Upgrading MariaDB -"
    sqlm 
    get_version 
    pre_checks
    echo -e "\n-List of available versions:\n\n10.3\n10.4\n10.5\n10.6\n"
    echo -e "\nWhich one are you installing? Only the version: 10.5 or 10.6, etc.)."
    supported_versions=(10.3 10.4 10.5 10.6)
    select_version
    cd /usr/local/directadmin/custombuild
    ./build set mysql_backup no
    ./build set "mariadb" $answ2
    ./build set mysql_inst "mariadb"
    ./build "mariadb"
    exit_status
    if [[ ! -d "/run/mariadb" ]]; then
        mkdir /run/mariadb && chmod 755 /run/mariadb && chown mysql:mysql /run/mariadb
    fi   
    grep -q "run/mariadb" "/usr/lib/tmpfiles.d/mariadb.conf"; exit_code_grep="$?"
    if [[ "$exit_code_grep" == 1 ]]; then
        echo "d /run/mariadb 0755 mysql mysql -" >>  /usr/lib/tmpfiles.d/mariadb.conf
    fi 
    post_check
}

upgrade_mysql() {
    echo -e "\n\n###Upgrading MySQL -"
    sqlm 
    get_version 
    pre_checks
    echo -e "\n-List of available versions:\n\n5.7\n8.0\n"
    echo -e "\nWhich one are you installing? Only the version: 5.7 or 8.0)."
    supported_versions=(5.7 8.0)
    select_version
    cd /usr/local/directadmin/custombuild
    ./build set mysql_backup no
    ./build set "mysql" $answ2
    ./build set mysql_inst "mysql"
    ./build "mysql"
    exit_status
    post_check
}

#Governor upgrade function
upgrade_do_governor() {
    sqlm 
    get_version 
    pre_checks
    if [[ "$gov_package" == 0 ]]; then
        operation=$(echo "update")
    else
        operation=$(echo "install")
    fi
    echo -e "\nThis installation will use the Governor script."
    echo -e "\nTo which version would you like to upgrade?\nOptions:\n\nMYSQL:\nmysql56, mysql57, mysql80\n\nMariaDB:\nmariadb103, mariadb104, mariadb105, mariadb106, mariadb1011\n"
    read answ2; echo -e "\nSelected: $answ2"
    supported_versions=(mysql56 mysql57 mysql80 mariadb103 mariadb104 mariadb105 mariadb106 mariadb1011)
    while true; do
        if [[ "${supported_versions[@]}" =~ "$answ2" ]]; then
            echo -e "\nUpgrading to $answ2 using the MySQL Governor script:"
            exe eval 'yum -y $operation governor-mysql'
            exe eval '/usr/share/lve/dbgovernor/mysqlgovernor.py --mysql-version=$answ2'
            exe eval '/usr/share/lve/dbgovernor/mysqlgovernor.py --install --yes'
            exit_code_gov="$?"
            if [[ "$exit_code_gov" == 1 ]]; then
                echo -e "\nUpgrade failed.\n"
            else 
                post_check 
            fi 
            break
        else
            echo "Invalid option, choose again."
            read answ2
        fi
    done
}

directadmin_options() {
    if [[ "$whichv" == "mariadb"* ]]; then
        upgrade_mariadb
    elif [[ "$whichv" == "mysql"* ]]; then
        upgrade_mysql
    else
        echo "This server does not meet the requirements for this script to run (no MariaDB installed or running MySQL, which is no longer being distributed by Plesk)."
        stopp
    fi 
}

#Main Procedure:
upgrade_do_directadmin() {
    whichv=$(rpm -qa | grep -iEe ^mysql.*-server -iEe ^mariadb.*-server | awk '{print tolower($0)}')
    if [[ "$(cat /etc/redhat-release)" == *"CloudLinux"* ]]; then
        echo "CloudLinux server detected..." 
        gov_package=$(rpm -q governor-mysql &>/dev/null; echo $?)
        dbms_packages=$(rpm -qa| grep -i "cl-mysql\|cl-mariadb" &>/dev/null; echo $?)

        if [[ "$gov_package" == 0 ]] && [[ "$dbms_packages" == 0 ]]; then
            upgrade_do_governor
        else
            echo -e "\nWill you be using the MySQL Governor's script? y/n" 
            read answ ; echo $answ
            if [[ $answ == "yes" || $answ == "Yes" || $answ == "YES" || $answ == "y" ]]; then
                upgrade_do_governor 
            else
                echo "Ok, the regular DirectAdmin method will be used." 
                directadmin_options
            fi
        fi
    fi 
}

upgrade_do_directadmin | tee -a "$LOG_FILE"
