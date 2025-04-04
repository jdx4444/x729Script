#!/bin/bash
# setup_x729.sh
# This script automates the setup of the Geekworm X729 UPS software,
# including installing the fan and power management services, adding the
# safe shutdown alias, and deploying the AC loss shutdown service.
#
# Note: This script assumes your system already has required packages like git, gpiod, and Python3.
#       It does NOT run "sudo apt update && sudo apt full-upgrade -y".
#
# Usage: sudo bash setup_x729.sh

set -e

# Check if running as root.
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., using sudo)."
  exit 1
fi

echo "Starting Geekworm X729 UPS setup automation..."

###########################
# 1. Clone the Repository #
###########################
# Clone the Geekworm x729-script repository into /opt/x729-script if not already present.
if [ ! -d "/opt/x729-script" ]; then
  echo "Cloning Geekworm x729-script repository..."
  git clone https://github.com/geekworm-com/x729-script /opt/x729-script
else
  echo "Repository already exists in /opt/x729-script. Skipping clone."
fi

###########################################
# 2. Install and Configure UPS Services   #
###########################################

# Fan control service
echo "Installing x729-fan service..."
cp -f /opt/x729-script/x729-fan.sh /usr/local/bin/
chmod +x /usr/local/bin/x729-fan.sh
cp -f /opt/x729-script/x729-fan.service /lib/systemd/system/

# Power management service
echo "Installing x729-pwr service..."
cp -f /opt/x729-script/xPWR.sh /usr/local/bin/
chmod +x /usr/local/bin/xPWR.sh
cp -f /opt/x729-script/x729-pwr.service /lib/systemd/system/

# Safe shutdown script
echo "Installing xSoft.sh..."
cp -f /opt/x729-script/xSoft.sh /usr/local/bin/
chmod +x /usr/local/bin/xSoft.sh

# Add alias for safe shutdown (x729off) if not already present in the current user's .bashrc.
ALIAS_LINE="alias x729off='sudo /usr/local/bin/xSoft.sh 0 26'"
if ! grep -qF "$ALIAS_LINE" ~/.bashrc; then
  echo "$ALIAS_LINE" >> ~/.bashrc
  echo "Added alias 'x729off' to ~/.bashrc."
fi

###############################################
# 3. Deploy AC Loss Shutdown Script & Service #
###############################################

echo "Deploying AC loss shutdown script..."

# Create the AC loss shutdown Python script in /usr/local/bin
cat << 'EOF' > /usr/local/bin/ac_loss_shutdown.py
#!/usr/bin/env python3
"""
ac_loss_shutdown.py

This script monitors the AC loss signal on GPIO6.
When a rising edge (indicating AC power loss) is detected,
it waits for a debounce delay.
If AC remains off after that delay, it triggers a safe shutdown
by calling the xSoft.sh script (equivalent to the x729off alias).
This ensures that the UPS will cut power once the Pi has halted.
"""

import gpiod
import time
import subprocess
import sys

# Configuration constants
GPIO_CHIP = "gpiochip0"      # Default GPIO chip
AC_LOSS_LINE = 6             # GPIO6 (BCM6, physical pin 31) for AC loss detection
DEBOUNCE_DELAY = 5           # Delay in seconds after detecting AC loss

def main():
    try:
        chip = gpiod.Chip(GPIO_CHIP)
    except Exception as e:
        sys.exit(f"Error opening {GPIO_CHIP}: {e}")

    try:
        line = chip.get_line(AC_LOSS_LINE)
    except Exception as e:
        sys.exit(f"Error getting line {AC_LOSS_LINE}: {e}")

    try:
        line.request(consumer="ac_loss_shutdown", type=gpiod.LINE_REQ_EV_BOTH_EDGES)
    except Exception as e:
        sys.exit(f"Error requesting event monitoring: {e}")

    print("AC Loss Shutdown Monitor started. Monitoring GPIO6 for AC power loss events...")

    while True:
        if line.event_wait(5):
            event = line.event_read()
            if event.type == gpiod.LineEvent.RISING_EDGE:
                print("AC power loss detected (rising edge). Waiting for debounce delay...")
                time.sleep(DEBOUNCE_DELAY)
                if line.get_value() == 1:
                    print("AC power still absent. Initiating safe shutdown...")
                    subprocess.run(["sudo", "/usr/local/bin/xSoft.sh", "0", "26"])
                    break
                else:
                    print("AC power restored during debounce delay. Aborting shutdown.")
            elif event.type == gpiod.LineEvent.FALLING_EDGE:
                print("AC power restored (falling edge).")
                
if __name__ == "__main__":
    main()
EOF

# Make the AC loss shutdown script executable.
chmod +x /usr/local/bin/ac_loss_shutdown.py

# Create the systemd service for AC loss shutdown.
echo "Creating systemd service for AC loss shutdown..."
cat << 'EOF' > /lib/systemd/system/ac-loss-shutdown.service
[Unit]
Description=AC Loss Shutdown Monitor for Geekworm X729 UPS
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ac_loss_shutdown.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

##############################
# 4. Enable and Start Services #
##############################

echo "Reloading systemd daemon and enabling services..."
systemctl daemon-reload

echo "Enabling and starting x729-fan.service..."
systemctl enable x729-fan.service
systemctl start x729-fan.service

echo "Enabling and starting x729-pwr.service..."
systemctl enable x729-pwr.service
systemctl start x729-pwr.service

echo "Enabling and starting ac-loss-shutdown.service..."
systemctl enable ac-loss-shutdown.service
systemctl start ac-loss-shutdown.service

echo "Geekworm X729 UPS setup completed successfully!"
echo "Please log out and back in (or run 'source ~/.bashrc') for the alias to take effect."
