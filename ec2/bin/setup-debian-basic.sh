#!/bin/bash
# ==============================================================================

TIMER_START=$(date +"%s")
CURRENT_DATE=$(date +"%Y%m%d")
TIMESTAMP=$(date +"%s")
PROCESS="$$"
STAGE=$1

#export LC_CTYPE=en_US.UTF-8
#export LC_ALL=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive
SLACK_MESSAGE=""

if [ -r /tmp/environment ]; then
	. /tmp/environment
fi

output(){
	OUTPUT_TIMESTAMP=$(date +"%d/%b/%Y %H:%M:%S %Z")
	echo "[${OUTPUT_TIMESTAMP}] $1" | tee --append /var/log/setup.log
}

convertsecs(){
	((h=${1}/3600))
	((m=(${1}%3600)/60))
	((s=${1}%60))
	TIME_ELAPSED=$(printf "%02d hrs %02d mins %02d secs" $h $m $s)
}

# ------------------------------------------------------------------------------
# Stage 1
# ------------------------------------------------------------------------------

if [ "${STAGE}" = "" -o "${STAGE}" = "stage1" ]; then
	output "Stage 1 - restarting script in the background"
	$0 "stage2" &
	exit 0
fi

# ------------------------------------------------------------------------------
# Stage 2
# ------------------------------------------------------------------------------

if [ "${STAGE}" = "stage2" ]; then
	output "Stage 2 - waiting for cloud-config to finish"
	TEMP=""
	COUNT=1
	while [ "${TEMP}" = "" ]; do
		TEMP=$(tail -10 /var/log/cloud-init-output.log | egrep '^Cloud\-init.*finished.*seconds$')
		if [ "${TEMP}" = "" ]; then
			output "Still waiting... ${COUNT}"
			let COUNT=COUNT+1
			sleep 2
		else
			output "cloud-config finished"
			STAGE="stage3"
		fi
	done
fi

# ------------------------------------------------------------------------------
# Stage 3
# ------------------------------------------------------------------------------

output "Stage 3 - setting up the system"

INSTANCE_ID=$(ec2metadata --instance-id)
AVAILABILITY_ZONE=$(ec2metadata --availability-zone)
REGION=$(echo "${AVAILABILITY_ZONE}" | sed 's/[a-z]$//')

output "Instance ID: ${INSTANCE_ID}"
output "Region: ${REGION}"
output "Availability zone: ${AVAILABILITY_ZONE}"

if [ "${SLACK_WEBHOOK}" = "" ]; then
	SLACK_WEBHOOK=$(aws --region ${REGION} ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=slack-webhook" | jq -r '.Tags[].Value')
	if [ ! "${SLACK_WEBHOOK}" = "" ]; then
		TEMP=$(echo "${SLACK_WEBHOOK}" | cut -c 1-6)
		if [ ! "${TEMP}" = "https:" ]; then
			SLACK_WEBHOOK="https://hooks.slack.com${SLACK_WEBHOOK}"
		fi
	fi
fi

if [ ! "${SLACK_WEBHOOK}" = "" ]; then
	if [ ! -d /etc/slack ]; then
		mkdir /etc/slack
	fi
	echo "url.channel.infrastructure = ${SLACK_WEBHOOK}" > /etc/slack/webhooks.cfg
	chmod 750 /etc/slack
	chmod 640 /etc/slack/webhooks.cfg
fi

if [ "${HOSTNAME}" = "" ]; then
	HOSTNAME=$(aws --region ${REGION} ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=route53-resourceRecord" | jq -r '.Tags[].Value')
	if [ "${HOSTNAME}" = "" ]; then
		HOSTNAME=$(aws --region ${REGION} ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=hostname" | jq -r '.Tags[].Value')
	fi
fi

HOSTNAME_LONG=${HOSTNAME}
HOSTNAME_SHORT=$(echo "${HOSTNAME_LONG}" | cut -f 1 -d '.')

PRIVATE_IP_ADDRESS=$(ec2metadata --local-ipv4)
PUBLIC_IP_ADDRESS=$(ec2metadata --public-ip)
if [ ! "${PUBLIC_IP_ADDRESS}" = "" ]; then
	echo "${PUBLIC_IP_ADDRESS} ${HOSTNAME_LONG} ${HOSTNAME_SHORT}" >> /etc/cloud/templates/hosts.debian.tmpl
	echo "${PUBLIC_IP_ADDRESS} ${HOSTNAME_LONG} ${HOSTNAME_SHORT}" >> /etc/hosts
else
	sed -i -e "s/^\(127\.0\.0\.1.*localhost\).*\$/\1 ${HOSTNAME_LONG}/g" /etc/cloud/templates/hosts.debian.tmpl
	sed -i -e "s/^\(127\.0\.0\.1.*localhost\).*\$/\1 ${HOSTNAME_LONG}/g" /etc/hosts
fi
hostnamectl set-hostname ${HOSTNAME_LONG}

if [ ! "${SLACK_WEBHOOK}" = "" ]; then
	SLACK_MESSAGE="[*${HOSTNAME_SHORT}*] Building instance ID *${INSTANCE_ID}* (${AVAILABILITY_ZONE})"
	SLACK_MESSAGE="${SLACK_MESSAGE}\nHost: ${HOSTNAME_LONG}, local IPv4: ${PRIVATE_IP_ADDRESS}"
	if [ ! "${PUBLIC_IP_ADDRESS}" = "" ]; then SLACK_MESSAGE="${SLACK_MESSAGE}, public IPv4: ${PUBLIC_IP_ADDRESS}" ; fi

	curl --silent --fail --request POST --header 'Content-type: application/json' --data "{\"text\":\"${SLACK_MESSAGE}\"}" ${SLACK_WEBHOOK} > /dev/null
fi

# ------------------------------------------------------------------------------

output "Configuring locales"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen --purge en_US.UTF-8 > /dev/null
OUTPUT=$(dpkg-reconfigure --frontend=noninteractive locales 2>&1 > /dev/null)
update-locale LANG=en_US.UTF-8

output "Enabling \"contrib\" and \"non-free\" Debian packages"
sed -i -e 's/ main$/ main contrib non-free/g' /etc/apt/sources.list
apt-get --yes -qq update

output "Removing Debian package \"nano\""
apt-get --yes -qq remove nano > /dev/null

echo "content-disposition = on" >> /etc/wgetrc

# /etc/skel
cat <<EOF > /etc/skel/.bash_aliases
# Alias definitions.
alias ll='ls -Al --color'
alias ..='cd .. ; pwd'
EOF

# /etc/skel
cat <<EOF > /etc/skel/.vimrc
"set mouse="
EOF

VERSION_DEBIAN=$(cat /etc/debian_version)
SYSTEM_UNAME=$(uname -a)
SYSTEM_LSB_DESCRIPTION=$(lsb_release --short --description)

output "Copying files from /etc/skel/ to /home/admin/"
cp --recursive --preserve=all /etc/skel/. /home/admin/
chown -R admin: /home/admin/

output "Extending .bash_aliases for user \"admin\""
echo "alias apt-update='TODAY=\$(date +\"%d/%b/%Y %H:%M:%S\") ; clear ; echo \"Updating repository...\" ; sudo apt -qq update ; sudo apt -uV upgrade ; echo ; echo \"Last update: \${TODAY}\" ; echo'" >> /home/admin/.bash_aliases
chown -R admin: /home/admin

output "Configuring log rotation"
cat /etc/logrotate.d/rsyslog | egrep -v "mail\.log|auth\.log" | tee /etc/logrotate.d/rsyslog.new > /dev/null
mv /etc/logrotate.d/rsyslog.new /etc/logrotate.d/rsyslog

cat <<EOF > /etc/logrotate.d/mail
/var/log/mail.log
{
    rotate 9999
    daily
    dateext
    missingok
    notifempty
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

cat <<EOF > /etc/logrotate.d/auth
/var/log/auth.log
{
    rotate 9999
    daily
    dateext
    missingok
    notifempty
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

# chrony
output "Configuring service \"chrony\""
cat /etc/chrony/chrony.conf | sed 's/^\(pool .*\)$/# \1/g' > /etc/chrony/chrony.conf.new
mv /etc/chrony/chrony.conf.new /etc/chrony/chrony.conf
output "Restarting service \"chrony\""
systemctl restart chrony
echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' > /etc/chrony/sources.d/aws-ntp-server.sources
chronyc reload sources > /dev/null

# Automatic Debian updates
output "Configure automatic Debian updates"

cat <<EOF | debconf-set-selections
apt-listchanges	apt-listchanges/frontend	select	mail
apt-listchanges	apt-listchanges/which	select	both
apt-listchanges	apt-listchanges/no-network	boolean	false
apt-listchanges	apt-listchanges/email-address	string	root
apt-listchanges	apt-listchanges/email-format	select	text
apt-listchanges	apt-listchanges/headers	boolean	false
apt-listchanges	apt-listchanges/reverse	boolean	false
apt-listchanges	apt-listchanges/save-seen	boolean	true
apt-listchanges	apt-listchanges/confirm	boolean	false
EOF

cat /etc/apt/apt.conf.d/50unattended-upgrades | sed 's/^\(\/\/Unattended-Upgrade::Mail[[:space:]].*\)$/\1\nUnattended-Upgrade::Mail "root";/g' > /etc/apt/apt.conf.d/50unattended-upgrades.new
mv /etc/apt/apt.conf.d/50unattended-upgrades.new /etc/apt/apt.conf.d/50unattended-upgrades

cat <<EOF | debconf-set-selections
unattended-upgrades	unattended-upgrades/enable_auto_updates	boolean	true
EOF

# Clean-up
output "Cleaning up Debian repository and downloaded packages"
apt-get --yes autoremove 2>&1 > /dev/null
apt-get --yes purge 2>&1 > /dev/null
apt-get --yes clean 2>&1 > /dev/null
apt-get --yes autoclean 2>&1 > /dev/null

# ------------------------------------------------------------------------------

output "Configuring and mounting volumes into system"

VOLUMES=$(nvme list --output-format=json | jq -r '.Devices[] | (.SerialNumber + "|" + .DevicePath)')
for VOLUME in ${VOLUMES}; do
	VOLUME_ID=$(echo "${VOLUME}" | cut -f 1 -d '|' | sed 's/^vol/vol-/g')
	DEVICE=$(echo "${VOLUME}" | cut -f 2 -d '|')
	MAPPING=$(aws --region ${REGION} ec2 describe-tags --filters "Name=resource-id,Values=${VOLUME_ID}" "Name=key,Values=mapping" | jq -r '.Tags[].Value')
	if [ ! "${MAPPING}" = "" ] ; then
		mkfs.ext4 -q ${DEVICE} > /dev/null 2>/dev/null
		if [ $? -eq 0 ]; then
			UUID=$(blkid --output export ${DEVICE} | egrep '^UUID=')
			MOUNTPOINT=$(echo "${MAPPING}" | jq -r '.mountpoint')
			if [ ! -d "${MOUNTPOINT}" ]; then mkdir --parent "${MOUNTPOINT}" ; fi
			output "${VOLUME_ID} is ${DEVICE} (${UUID}) and will be mounted as ${MOUNTPOINT}"
			echo -e "# ${DEVICE}\n${UUID} ${MOUNTPOINT} ext4 defaults 0 0\n" >> /tmp/fstab
		else
			output "Command mkfs.ext4 failed"
		fi
	else
		output "${VOLUME_ID}: no mapping found"
	fi
done

if [ -r /tmp/fstab ]; then
	cat /tmp/fstab >> /etc/fstab
	rm /tmp/fstab
fi

mount -a

# ------------------------------------------------------------------------------

output "Configuring Amazon EFS"

# Determine EFS ID based on tag "resource-id"
#FILESYSTEM_ID=$(aws --region ${REGION} efs describe-file-systems | jq -r '.FileSystems[] | select((.Tags[]|select(.Key=="resource-id")|.Value) | match("wengfu-fertbook-efs")).FileSystemId')
#output "Filesystem ID: ${FILESYSTEM_ID}"

FILESYSTEM_DNS_NAME=$(aws --region ${REGION} ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=efs-dns-name" | jq -r '.Tags[].Value')

if [ ! "${FILESYSTEM_DNS_NAME}" = "" ]; then
	output "Filesystem DNS name: ${FILESYSTEM_DNS_NAME}"
	if [ ! -d /srv/efs ]; then mkdir --parent /srv/efs ; fi
	cat <<EOF >> /etc/fstab
# Amazon Elastic Filesystem
${FILESYSTEM_DNS_NAME}:/ /srv/efs nfs defaults,_netdev,nofail 0 0
EOF
	mount /srv/efs
fi

# ------------------------------------------------------------------------------

output "System-specific configuration"

# mail aliases
# ...
#newaliases

# postfix
# ...

# set mail name
if [ ! "${MAILNAME}" = "" ]; then
	output "Setting mailname: ${MAILNAME}"
	echo "${MAILNAME}" > /etc/mailname
fi

output "Restarting service \"postfix\""
systemctl restart postfix

# ------------------------------------------------------------------------------

output "Installing and configuring CloudWatch Agent"

wget --quiet -O /tmp/amazon-cloudwatch-agent.deb https://s3.amazonaws.com/amazoncloudwatch-agent/debian/amd64/latest/amazon-cloudwatch-agent.deb
if [ -s /tmp/amazon-cloudwatch-agent.deb ]; then
	dpkg -i -E /tmp/amazon-cloudwatch-agent.deb 2> /dev/null
	RETURN=$?
	if [ ${RETURN} -ne 0 ]; then
		output "Installation failed (return code: ${RETURN})"
	fi
fi

# ------------------------------------------------------------------------------

TIMER_STOP=$(date +"%s")
let TIME_ELAPSED=TIMER_STOP-TIMER_START
convertsecs ${TIME_ELAPSED}
output "Script $0 finished (${TIME_ELAPSED})"

UPTIME=$(echo "($(date +"%s") - $(date +"%s" -d "$(uptime -s)"))" | bc)
convertsecs ${UPTIME}

if [ ! "${SLACK_WEBHOOK}" = "" ]; then
	SLACK_MESSAGE="[*${HOSTNAME_SHORT}*] System build completed (uptime: ${TIME_ELAPSED})"
	curl --silent --fail --request POST --header 'Content-type: application/json' --data "{\"text\":\"${SLACK_MESSAGE}\"}" ${SLACK_WEBHOOK} > /dev/null
fi

# ------------------------------------------------------------------------------
