#!/bin/bash
#
#
#	OpenUptime Server Monitoring Agent — macOS Install Script
#	Forked from HetrixTools macOS Agent v2.0.0
#	https://github.com/openuptime
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind,
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement.
#	OpenUptime makes no warranty that the Software is free of defects or is suitable for any particular purpose.
#	In no event shall OpenUptime be responsible for loss or damages arising from the installation or use of the Software,
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including,
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses.
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#		END OF DISCLAIMER OF WARRANTY

# Set PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin

# Branch
BRANCH="main"

# Check if first argument is branch or UUID
if [ -n "$1" ] && [[ ! "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
then
	BRANCH=$1
	shift
fi

# Check if install script is run by root
echo "Checking root privileges..."
if [ "$EUID" -ne 0 ]
	then echo "ERROR: Please run the install script as root."
	exit 1
fi
echo "... done."

# Check if this is macOS
echo "Checking operating system..."
if [ "$(uname)" != "Darwin" ]
	then echo "ERROR: This installer is for macOS only."
	exit 1
fi
echo "... done."

# Fetch Server UUID
OPENUPTIME_SERVER_UUID=$1

# Make sure UUID is not empty
echo "Checking Server UUID..."
if [ -z "$OPENUPTIME_SERVER_UUID" ]
	then echo "ERROR: Server UUID parameter missing."
	exit 1
fi
echo "... done."

# Fetch API Key
OPENUPTIME_API_KEY=$2

# Make sure API Key is not empty
echo "Checking API Key..."
if [ -z "$OPENUPTIME_API_KEY" ]
	then echo "ERROR: API Key parameter missing."
	exit 1
fi
echo "... done."

# Fetch Reporting URL
OPENUPTIME_REPORTING_URL=$3

# Make sure Reporting URL is not empty
echo "Checking Reporting URL..."
if [ -z "$OPENUPTIME_REPORTING_URL" ]
	then echo "ERROR: Reporting URL parameter missing."
	exit 1
fi
echo "... done."

# Check if user has selected to run agent as 'root' or not
RUN_AS_ROOT=0
if [ -n "$4" ] && [ "$4" -eq "1" ] 2>/dev/null
then
	RUN_AS_ROOT=1
fi

# Check for required system utilities
echo "Checking system utilities..."
for cmd in curl top vm_stat sysctl netstat df ifconfig; do
	command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required to run this agent." >&2; exit 1; }
done
echo "... done."

# Check if the selected branch exists
echo "Checking branch..."
if curl -sf --head "https://raw.githubusercontent.com/openuptime/agent-macos/$BRANCH/openuptime_agent.sh" > /dev/null 2>&1
then
	echo "Installing from $BRANCH branch..."
else
	echo "ERROR: Branch $BRANCH does not exist."
	exit 1
fi

# Remove old agent (if exists)
echo "Checking if there's any old openuptime agent already installed..."
if [ -d /opt/openuptime ]
then
	echo "Old openuptime agent found, deleting it..."
	rm -rf /opt/openuptime
else
	echo "No old openuptime agent found..."
fi
echo "... done."

# Creating agent folder
echo "Creating the openuptime agent folder..."
mkdir -p /opt/openuptime
echo "... done."

# Fetching the agent
echo "Fetching the agent..."
if ! curl -sf -o /opt/openuptime/openuptime_agent.sh "https://raw.githubusercontent.com/openuptime/agent-macos/$BRANCH/openuptime_agent.sh"
then
	echo "ERROR: Failed to download the agent script from GitHub."
	exit 1
fi
echo "... done."

# Fetching the config file
echo "Fetching the config file..."
if ! curl -sf -o /opt/openuptime/openuptime.cfg "https://raw.githubusercontent.com/openuptime/agent-macos/$BRANCH/openuptime.cfg"
then
	echo "ERROR: Failed to download the agent configuration from GitHub."
	exit 1
fi
echo "... done."

# Fetching the wrapper script
echo "Fetching the wrapper script..."
if ! curl -sf -o /opt/openuptime/run_agent.sh "https://raw.githubusercontent.com/openuptime/agent-macos/$BRANCH/openuptime_run_agent.sh"
then
	echo "ERROR: Failed to download the wrapper script from GitHub."
	exit 1
fi
echo "... done."

# Setting permissions
echo "Setting permissions..."
chmod +x /opt/openuptime/openuptime_agent.sh
chmod +x /opt/openuptime/run_agent.sh
chmod 600 /opt/openuptime/openuptime.cfg
echo "... done."

# Inserting configuration into the agent config
echo "Inserting Server UUID into agent config..."
sed -i '' "s|OPENUPTIME_SERVER_UUID=\"\"|OPENUPTIME_SERVER_UUID=\"$OPENUPTIME_SERVER_UUID\"|" /opt/openuptime/openuptime.cfg
echo "... done."

echo "Inserting Reporting URL into agent config..."
sed -i '' "s|OPENUPTIME_REPORTING_URL=\"\"|OPENUPTIME_REPORTING_URL=\"$OPENUPTIME_REPORTING_URL\"|" /opt/openuptime/openuptime.cfg
echo "... done."

echo "Inserting API Key into agent config..."
sed -i '' "s|OPENUPTIME_API_KEY=\"\"|OPENUPTIME_API_KEY=\"$OPENUPTIME_API_KEY\"|" /opt/openuptime/openuptime.cfg
echo "... done."

# Check if any services are to be monitored
echo "Checking if any services should be monitored..."
if [ -n "$5" ] && [ "$5" != "0" ]
then
	echo "Services found, inserting them into the agent config..."
	sed -i '' "s/CheckServices=\"\"/CheckServices=\"$5\"/" /opt/openuptime/openuptime.cfg
fi
echo "... done."

# Check if software RAID should be monitored
echo "Checking if software RAID should be monitored..."
if [ -n "$6" ] && [ "$6" -eq "1" ] 2>/dev/null
then
	echo "Enabling software RAID monitoring in the agent config..."
	sed -i '' "s/CheckSoftRAID=0/CheckSoftRAID=1/" /opt/openuptime/openuptime.cfg
fi
echo "... done."

# Check if Drive Health should be monitored
echo "Checking if Drive Health should be monitored..."
if [ -n "$7" ] && [ "$7" -eq "1" ] 2>/dev/null
then
	echo "Enabling Drive Health monitoring in the agent config..."
	sed -i '' "s/CheckDriveHealth=0/CheckDriveHealth=1/" /opt/openuptime/openuptime.cfg
fi
echo "... done."

# Check if 'View running processes' should be enabled
echo "Checking if 'View running processes' should be enabled..."
if [ -n "$8" ] && [ "$8" -eq "1" ] 2>/dev/null
then
	echo "Enabling 'View running processes' in the agent config..."
	sed -i '' "s/RunningProcesses=0/RunningProcesses=1/" /opt/openuptime/openuptime.cfg
fi
echo "... done."

# Check if any ports to monitor number of connections on
echo "Checking if any ports to monitor number of connections on..."
if [ -n "$9" ] && [ "$9" != "0" ]
then
	echo "Ports found, inserting them into the agent config..."
	sed -i '' "s/ConnectionPorts=\"\"/ConnectionPorts=\"$9\"/" /opt/openuptime/openuptime.cfg
fi
echo "... done."

# Killing any running openuptime agents
echo "Making sure no openuptime agent scripts are currently running..."
pkill -f openuptime_agent.sh 2>/dev/null
echo "... done."

# Checking if _openuptime user exists (macOS uses underscore prefix for service accounts)
echo "Checking if _openuptime user already exists..."
if id -u _openuptime >/dev/null 2>&1
then
	echo "The _openuptime user already exists, killing its processes..."
	pkill -9 -u _openuptime 2>/dev/null
	echo "Deleting _openuptime user..."
	dscl . -delete /Users/_openuptime 2>/dev/null
fi
if [ "$RUN_AS_ROOT" -ne 1 ]
then
	echo "Creating the _openuptime user..."
	# Find an available UID in the service account range (400-499)
	OUID=400
	while dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -q "^${OUID}$"; do
		OUID=$((OUID + 1))
	done
	dscl . -create /Users/_openuptime
	dscl . -create /Users/_openuptime UniqueID "$OUID"
	dscl . -create /Users/_openuptime PrimaryGroupID 20
	dscl . -create /Users/_openuptime UserShell /usr/bin/false
	dscl . -create /Users/_openuptime NFSHomeDirectory /opt/openuptime
	dscl . -create /Users/_openuptime RealName "OpenUptime Agent"
	# Hide the user from the login window
	dscl . -create /Users/_openuptime IsHidden 1
	echo "Assigning permissions for the _openuptime user..."
	chown -R _openuptime:staff /opt/openuptime
	chmod -R 700 /opt/openuptime
else
	echo "Agent will run as 'root' user..."
	chown -R root:wheel /opt/openuptime
	chmod -R 700 /opt/openuptime
fi
echo "... done."

# Removing old launchd job (if exists)
echo "Removing any old openuptime launchd job, if exists..."
if launchctl list 2>/dev/null | grep -q "com.openuptime.agent"
then
	launchctl unload /Library/LaunchDaemons/com.openuptime.agent.plist 2>/dev/null
fi
rm -f /Library/LaunchDaemons/com.openuptime.agent.plist 2>/dev/null
echo "... done."

# Also remove legacy hetrixtools launchd job if present
if launchctl list 2>/dev/null | grep -q "com.hetrixtools.agent"
then
	launchctl unload /Library/LaunchDaemons/com.hetrixtools.agent.plist 2>/dev/null
	rm -f /Library/LaunchDaemons/com.hetrixtools.agent.plist 2>/dev/null
fi

# Removing old crontab entry (if exists)
echo "Removing any old openuptime crontab entry, if exists..."
crontab -l 2>/dev/null | grep -v 'openuptime' | crontab - 2>/dev/null
echo "... done."

# Setting up the launchd job to run the agent every minute
echo "Setting up the launchd job..."
if [ "$RUN_AS_ROOT" -eq 1 ]
then
	AGENT_USER="root"
else
	AGENT_USER="_openuptime"
fi
cat > /Library/LaunchDaemons/com.openuptime.agent.plist << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.openuptime.agent</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>/opt/openuptime/run_agent.sh</string>
	</array>
	<key>WorkingDirectory</key>
	<string>/opt/openuptime</string>
	<key>UserName</key>
	<string>${AGENT_USER}</string>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Second</key>
		<integer>0</integer>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>AbandonProcessGroup</key>
	<true/>
</dict>
</plist>
PLIST_EOF
launchctl load /Library/LaunchDaemons/com.openuptime.agent.plist 2>/dev/null
echo "... done."

# Cleaning up install file
echo "Cleaning up the installation file..."
if [ -f "$0" ]
then
	rm -f "$0"
fi
echo "... done."

# Start the agent
if [ "$RUN_AS_ROOT" -eq 1 ]
then
	echo "Starting the agent under the 'root' user..."
	bash /opt/openuptime/openuptime_agent.sh > /dev/null 2>&1 &
else
	echo "Starting the agent under the '_openuptime' user..."
	sudo -u _openuptime bash /opt/openuptime/openuptime_agent.sh > /dev/null 2>&1 &
fi
echo "... done."

# All done
echo "OpenUptime agent installation completed."
